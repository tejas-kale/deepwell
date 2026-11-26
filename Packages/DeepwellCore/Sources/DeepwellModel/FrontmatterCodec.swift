import Foundation

public enum FrontmatterError: Error, Equatable {
    case missingFrontmatter
    case unterminatedFrontmatter
    case missingField(String)
    case invalidValue(field: String, value: String)
}

/// Reads and writes the YAML frontmatter of item files. Handles exactly the subset Deepwell
/// emits (scalars, double-quoted strings, flow lists) and is lenient about hand edits
/// (bare or single-quoted strings, block-style tag lists).
public enum FrontmatterCodec {
    // MARK: Encode

    public static func encode(_ doc: ItemDocument) -> String {
        let i = doc.item
        var lines = ["---"]
        lines.append("id: \(quote(i.id))")
        lines.append("type: \(i.type.rawValue)")
        lines.append("title: \(quote(i.title))")
        if let url = i.sourceURL { lines.append("source_url: \(quote(url.absoluteString))") }
        lines.append("author: \(quote(i.author ?? ""))")
        lines.append("captured_at: \(isoString(i.capturedAt))")
        if let w = i.wordCount { lines.append("word_count: \(w)") }
        if let d = i.durationMinutes { lines.append("duration_minutes: \(d)") }
        lines.append("tags: [\(i.tags.map(quote).joined(separator: ", "))]")
        lines.append("status: \(i.status.rawValue)")
        lines.append("progress: \(formatProgress(i.progress))")
        if let finished = i.finishedAt { lines.append("finished_at: \(isoString(finished))") }
        if let issue = i.issueID { lines.append("issue_id: \(quote(issue))") }
        lines.append(contentsOf: i.extraFrontmatter)
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + doc.body.trimmingCharacters(in: .newlines) + "\n"
    }

    // MARK: Decode

    public static func decode(_ text: String) throws -> ItemDocument {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---" else { throw FrontmatterError.missingFrontmatter }
        lines.removeFirst()
        guard let end = lines.firstIndex(of: "---") else { throw FrontmatterError.unterminatedFrontmatter }
        let fmLines = Array(lines[..<end])
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)

        // Group into (key, rawValue, continuationLines)
        struct Entry { var key: String; var raw: String; var cont: [String] }
        var entries: [Entry] = []
        for line in fmLines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- "), !entries.isEmpty {
                entries[entries.count - 1].cont.append(line)
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                entries.append(Entry(key: key, raw: raw, cont: []))
            }
        }

        func entry(_ k: String) -> Entry? { entries.first { $0.key == k } }
        func string(_ k: String) throws -> String? {
            guard let e = entry(k) else { return nil }
            return try parseScalar(e.raw, field: k)
        }
        func required(_ k: String) throws -> String {
            guard let s = try string(k) else { throw FrontmatterError.missingField(k) }
            return s
        }
        func int(_ k: String) throws -> Int? {
            guard let s = try string(k), !s.isEmpty else { return nil }
            guard let v = Int(s) else { throw FrontmatterError.invalidValue(field: k, value: s) }
            return v
        }

        let typeRaw = try required("type")
        guard let type = ItemType(rawValue: typeRaw) else { throw FrontmatterError.invalidValue(field: "type", value: typeRaw) }
        let statusRaw = try string("status") ?? "unread"
        guard let status = ItemStatus(rawValue: statusRaw) else { throw FrontmatterError.invalidValue(field: "status", value: statusRaw) }
        let capturedRaw = try required("captured_at")
        guard let captured = parseDate(capturedRaw) else { throw FrontmatterError.invalidValue(field: "captured_at", value: capturedRaw) }
        let progressRaw = try string("progress") ?? "0"
        guard let progress = Double(progressRaw) else { throw FrontmatterError.invalidValue(field: "progress", value: progressRaw) }
        let finishedAt: Date?
        if let finishedRaw = try string("finished_at") {
            guard let parsed = parseDate(finishedRaw) else {
                throw FrontmatterError.invalidValue(field: "finished_at", value: finishedRaw)
            }
            finishedAt = parsed
        } else {
            finishedAt = nil
        }

        var tags: [String] = []
        if let e = entry("tags") {
            if e.raw.isEmpty {
                tags = try e.cont.map { line in
                    var t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
                    return try parseScalar(t, field: "tags")
                }
            } else {
                tags = try parseFlowList(e.raw, field: "tags")
            }
        }

        let known: Set<String> = ["id", "type", "title", "source_url", "author", "captured_at", "word_count",
                                  "duration_minutes", "tags", "status", "progress", "finished_at", "issue_id"]
        var extras: [String] = []
        for line in fmLines {
            let isCont = line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- ")
            if !isCont, let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                extras.append(known.contains(key) ? "" : line)
            } else if isCont {
                extras.append(extras.last.map { $0.isEmpty ? "" : line } ?? "")
            }
        }
        extras.removeAll { $0.isEmpty }

        let author = try string("author").flatMap { $0.isEmpty ? nil : $0 }
        let source = try string("source_url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let issue = try string("issue_id").flatMap { $0.isEmpty ? nil : $0 }

        let item = Item(
            id: try required("id"), type: type, title: try string("title") ?? "",
            sourceURL: source, author: author, capturedAt: captured,
            wordCount: try int("word_count"), durationMinutes: try int("duration_minutes"),
            tags: tags, status: status, progress: progress, finishedAt: finishedAt, issueID: issue,
            extraFrontmatter: extras)
        return ItemDocument(item: item, body: body)
    }

    // MARK: Scalars

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7f { out += String(format: "\\u%04X", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func parseScalar(_ raw: String, field: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") {
            guard let (value, rest) = readDoubleQuoted(s), rest.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw FrontmatterError.invalidValue(field: field, value: raw)
            }
            return value
        }
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    /// Reads one double-quoted YAML string from the start of `s`; returns the value and the remainder.
    static func readDoubleQuoted(_ s: String) -> (String, Substring)? {
        var out = ""
        let scalars = Array(s.unicodeScalars.dropFirst())
        var idx = 0
        while idx < scalars.count {
            let c = scalars[idx]
            idx += 1
            if c == "\"" {
                let rest = String(String.UnicodeScalarView(scalars[idx...]))
                return (out, Substring(rest))
            }
            if c == "\\", idx < scalars.count {
                let e = scalars[idx]; idx += 1
                switch e {
                case "n": out += "\n"
                case "r": out += "\r"
                case "t": out += "\t"
                case "\"": out += "\""
                case "\\": out += "\\"
                case "/": out += "/"
                case "u":
                    guard idx + 4 <= scalars.count,
                          let v = UInt32(String(String.UnicodeScalarView(scalars[idx..<idx + 4])), radix: 16),
                          let u = Unicode.Scalar(v) else { return nil }
                    out.unicodeScalars.append(u); idx += 4
                default: out += "\\"; out.unicodeScalars.append(e)
                }
            } else {
                out.unicodeScalars.append(c)
            }
        }
        return nil
    }

    static func parseFlowList(_ raw: String, field: String) throws -> [String] {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("["), s.hasSuffix("]") else { throw FrontmatterError.invalidValue(field: field, value: raw) }
        var rest = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        while !rest.isEmpty {
            if rest.hasPrefix("\"") {
                guard let (v, after) = readDoubleQuoted(rest) else { throw FrontmatterError.invalidValue(field: field, value: raw) }
                out.append(v)
                rest = String(after)
            } else {
                let comma = rest.firstIndex(of: ",") ?? rest.endIndex
                out.append(try parseScalar(String(rest[..<comma]), field: field))
                rest = String(rest[comma...])
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix(",") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    // MARK: Dates & numbers

    public static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func formatProgress(_ p: Double) -> String {
        p == p.rounded() ? String(Int(p)) : String(format: "%.4g", p)
    }
}
