import Foundation

/// Written → spoken replacements for narration, in readcast's `pronunciations.yml` format (`written: spoken`, one per
/// line). The bundled map ships with the app; the user's map lives at the library root so it syncs, and overrides it.
/// Matching is case-insensitive and whole-word; only the spoken text changes, never the article.
public struct PronunciationStore: Sendable {
    public static let fileName = "pronunciations.yml"

    /// The user's file: `<library>/pronunciations.yml`.
    public let url: URL

    public init(libraryFolder: URL) { url = libraryFolder.appendingPathComponent(Self.fileName) }

    /// readcast's map, bundled as a resource.
    public static let bundled: [String: String] = {
        guard let url = Bundle.module.url(forResource: "pronunciations", withExtension: "yml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }()

    /// The user's entries (empty when there is no file).
    public func load() -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return Self.parse(text)
    }

    /// Writes the user's entries, sorted, atomically.
    public func save(_ entries: [String: String]) throws {
        try Self.serialise(entries).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Bundled file overridden by the user's, keyed case-insensitively (the user's spelling wins).
    public func merged() -> [String: String] { Self.merge(Self.bundled, load()) }

    static func merge(_ base: [String: String], _ overrides: [String: String]) -> [String: String] {
        var byFold: [String: (String, String)] = [:]
        for (k, v) in base { byFold[k.lowercased()] = (k, v) }
        for (k, v) in overrides { byFold[k.lowercased()] = (k, v) }
        return Dictionary(byFold.values.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Minimal YAML: a flat mapping of strings

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "---" { continue }
            guard let (key, rest) = scalar(line[...]), let colon = rest.firstIndex(of: ":") ,
                  rest[rest.startIndex..<colon].allSatisfy(\.isWhitespace) else { continue }
            let after = rest[rest.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
            guard let (value, tail) = scalar(after) else { continue }
            let t = tail.trimmingCharacters(in: .whitespaces)
            guard t.isEmpty || t.hasPrefix("#") else { continue }
            let k = key.trimmingCharacters(in: .whitespaces), v = value.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !v.isEmpty { out[k] = v }
        }
        return out
    }

    /// One scalar at the start of `s` (double-quoted, single-quoted or plain) and the remainder.
    private static func scalar(_ s: Substring) -> (String, Substring)? {
        guard let first = s.first else { return nil }
        if first == "\"" {
            var out = "", i = s.index(after: s.startIndex)
            while i < s.endIndex {
                let c = s[i]
                if c == "\\", s.index(after: i) < s.endIndex {
                    i = s.index(after: i); out.append(s[i] == "n" ? "\n" : s[i])
                } else if c == "\"" {
                    return (out, s[s.index(after: i)...])
                } else { out.append(c) }
                i = s.index(after: i)
            }
            return nil
        }
        if first == "'" {
            var out = "", i = s.index(after: s.startIndex)
            while i < s.endIndex {
                if s[i] == "'" {
                    let n = s.index(after: i)
                    if n < s.endIndex, s[n] == "'" { out.append("'"); i = s.index(after: n); continue }
                    return (out, s[n...])
                }
                out.append(s[i]); i = s.index(after: i)
            }
            return nil
        }
        // Plain: up to ": " (keys) or " #" (comments), whichever comes first.
        var end = s.endIndex, i = s.startIndex
        while i < s.endIndex {
            let n = s.index(after: i)
            if s[i] == ":" && (n == s.endIndex || s[n] == " " || s[n] == "\t") { end = i; break }
            if s[i] == "#" && i > s.startIndex && s[s.index(before: i)] == " " { end = i; break }
            i = n
        }
        return (String(s[s.startIndex..<end]), s[end...])
    }

    static func serialise(_ entries: [String: String]) -> String {
        entries.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\(quote($0.key)): \(quote($0.value))\n" }.joined()
    }

    private static func quote(_ s: String) -> String {
        let plainOK = !s.isEmpty && s == s.trimmingCharacters(in: .whitespaces)
            && !s.contains(": ") && !s.contains(" #") && !s.hasSuffix(":")
            && !"\"'#&*!|>%@`{}[],-?".contains(s.first!) && !s.contains("\n")
        if plainOK { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
