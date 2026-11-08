import Foundation

public struct SMTPSettings: Equatable, Sendable, Codable {
    public enum Security: String, Codable, Sendable, CaseIterable {
        /// Plain TCP, then STARTTLS before anything else (port 587).
        case startTLS
        /// TLS from the first byte (port 465).
        case implicitTLS
    }
    public var host: String
    public var port: Int
    public var security: Security
    public var username: String

    public init(host: String = "smtp.gmail.com", port: Int = 587, security: Security = .startTLS, username: String = "") {
        self.host = host; self.port = port; self.security = security; self.username = username
    }
}

public enum SMTPError: Error, Equatable, CustomStringConvertible {
    case unexpectedReply(step: String, code: Int, text: String)
    case connectionClosed(step: String)
    case missingPassword
    case authenticationFailed(String)

    public var description: String {
        switch self {
        case .unexpectedReply(let step, let code, let text): "mail server refused \(step) (\(code) \(text))"
        case .connectionClosed(let step): "mail server closed the connection during \(step)"
        case .missingPassword: "no SMTP password set"
        case .authenticationFailed(let text): "mail server rejected the login (\(text)). For Gmail use an app password"
        }
    }
}

/// Byte stream to a mail server. Production: `StreamTaskSMTPConnection`; tests: a scripted fake.
public protocol SMTPConnection: AnyObject, Sendable {
    func open() async throws
    func write(_ data: Data) async throws
    /// One line without the trailing CRLF. Throws `SMTPError.connectionClosed` at EOF.
    func readLine() async throws -> String
    func startTLS() async throws
    func close()
}

/// The SMTP dialogue (RFC 5321) with AUTH PLAIN. Never logs the password.
public struct SMTPClient: Sendable {
    let settings: SMTPSettings
    let makeConnection: @Sendable (SMTPSettings) -> SMTPConnection

    public init(settings: SMTPSettings, makeConnection: @escaping @Sendable (SMTPSettings) -> SMTPConnection = { StreamTaskSMTPConnection(settings: $0) }) {
        self.settings = settings; self.makeConnection = makeConnection
    }

    public func send(_ message: Data, from: String, to: [String], password: String) async throws {
        let c = makeConnection(settings)
        defer { c.close() }
        try await c.open()
        try await expect(c, [220], step: "greeting")
        try await ehlo(c)
        if settings.security == .startTLS {
            try await command(c, "STARTTLS", [220], step: "STARTTLS")
            try await c.startTLS()
            try await ehlo(c)
        }
        let user = settings.username.isEmpty ? from : settings.username
        let token = Data("\0\(user)\0\(password)".utf8).base64EncodedString()
        let (code, text) = try await command(c, "AUTH PLAIN \(token)", nil, step: "AUTH")
        guard code == 235 else { throw SMTPError.authenticationFailed("\(code) \(text)") }
        try await command(c, "MAIL FROM:<\(from)>", [250], step: "MAIL FROM")
        for r in to { try await command(c, "RCPT TO:<\(r)>", [250, 251], step: "RCPT TO") }
        try await command(c, "DATA", [354], step: "DATA")
        try await c.write(Self.dotStuffed(message))
        try await expect(c, [250], step: "message")
        _ = try? await command(c, "QUIT", nil, step: "QUIT")
    }

    private func ehlo(_ c: SMTPConnection) async throws {
        try await command(c, "EHLO deepwell.local", [250], step: "EHLO")
    }

    @discardableResult
    private func command(_ c: SMTPConnection, _ line: String, _ ok: Set<Int>?, step: String) async throws -> (Int, String) {
        try await c.write(Data((line + "\r\n").utf8))
        return try await expect(c, ok, step: step)
    }

    /// Reads one (possibly multi-line, "250-...") reply.
    @discardableResult
    private func expect(_ c: SMTPConnection, _ ok: Set<Int>?, step: String) async throws -> (Int, String) {
        var lines: [String] = []
        var code = 0
        while true {
            let line = try await c.readLine()
            code = Int(line.prefix(3)) ?? 0
            lines.append(String(line.dropFirst(4)))
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { break }
        }
        let text = lines.joined(separator: " ")
        if let ok, !ok.contains(code) { throw SMTPError.unexpectedReply(step: step, code: code, text: text) }
        return (code, text)
    }

    /// Lines starting with "." get another "." (RFC 5321 4.5.2), then the terminating CRLF.CRLF.
    static func dotStuffed(_ message: Data) -> Data {
        var s = String(decoding: message, as: UTF8.self)
        if s.hasPrefix(".") { s = "." + s }
        s = s.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if !s.hasSuffix("\r\n") { s += "\r\n" }
        return Data((s + ".\r\n").utf8)
    }
}

/// MIME message with one attachment (RFC 2045/2046), CRLF line endings, base64 wrapped at 76 columns.
public enum MailMessage {
    public static func build(from: String, to: String, subject: String, text: String,
                             attachmentName: String, attachment: Data, contentType: String = "application/epub+zip",
                             date: Date = Date(), boundary: String = "deepwell-\(UUID().uuidString)") -> Data {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = from.split(separator: "@").last.map(String.init) ?? "deepwell.local"
        let safeName = attachmentName.replacingOccurrences(of: "\"", with: "'")
        var lines = [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(encodeHeader(subject))",
            "Date: \(df.string(from: date))",
            "Message-ID: <\(UUID().uuidString)@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            text,
            "",
            "--\(boundary)",
            "Content-Type: \(contentType); name=\"\(encodeHeader(safeName))\"",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"\(encodeHeader(safeName))\"",
            "",
        ]
        lines.append(attachment.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
        lines.append("--\(boundary)--")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// RFC 2047 encoded-word for non-ASCII header text.
    static func encodeHeader(_ s: String) -> String {
        s.allSatisfy(\.isASCII) ? s : "=?utf-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}

/// `URLSessionStreamTask` gives a TCP stream that can be upgraded to TLS mid-conversation (STARTTLS) and works
/// inside the app sandbox with only the network-client entitlement.
public final class StreamTaskSMTPConnection: SMTPConnection, @unchecked Sendable {
    private let settings: SMTPSettings
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionStreamTask?
    private var buffer = Data()
    private let timeout: TimeInterval = 60

    public init(settings: SMTPSettings) { self.settings = settings }

    public func open() async throws {
        let t = session.streamTask(withHostName: settings.host, port: settings.port)
        task = t
        t.resume()
        if settings.security == .implicitTLS { t.startSecureConnection() }
    }

    public func write(_ data: Data) async throws {
        guard let task else { throw SMTPError.connectionClosed(step: "write") }
        try await task.write(data, timeout: timeout)
    }

    public func readLine() async throws -> String {
        guard let task else { throw SMTPError.connectionClosed(step: "read") }
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer[buffer.startIndex..<r.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 65536, timeout: timeout)
            if let data { buffer.append(data) }
            if eof && (data?.isEmpty ?? true) { throw SMTPError.connectionClosed(step: "read") }
        }
    }

    public func startTLS() async throws {
        buffer.removeAll()
        task?.startSecureConnection()
    }

    public func close() {
        task?.closeWrite()
        task?.cancel()
        session.invalidateAndCancel()
    }
}
