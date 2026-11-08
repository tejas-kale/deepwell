import Foundation

/// Reader-time tidy-up of extracted article Markdown (the file on disk is left untouched):
/// - the text right after an image becomes its caption; trailing "Credit...Name" bylines are shortened to "Name";
/// - stand-alone "Credit...", "Listen", "· 19:52 min", "Published … Updated …" boilerplate and empty "Image" labels are dropped.
enum ArticleCleaner {
    static func clean(_ blocks: [MarkdownBody.Block]) -> [MarkdownBody.Block] {
        var out: [MarkdownBody.Block] = []
        var afterImage = false
        for block in blocks {
            guard case .paragraph(let raw) = block else {
                afterImage = { if case .image = block { return true } else { return false } }()
                out.append(block); continue
            }
            let (text, credit) = splitCredit(raw.trimmingCharacters(in: .whitespaces))
            if afterImage {
                afterImage = false
                if text.isEmpty, let credit { out.append(.caption("Photo: \(credit)")); continue }
                if !text.isEmpty && text.count < 400 && !isBoilerplate(text) {
                    out.append(.caption(credit.map { "\(text) (\($0))" } ?? text)); continue
                }
            }
            if text.isEmpty || isBoilerplate(text) { continue }
            out.append(.paragraph(text))
        }
        return out
    }

    /// "Caption.Credit...Jim Wilson/The New York Times" -> ("Caption.", "Jim Wilson/The New York Times").
    static func splitCredit(_ s: String) -> (String, String?) {
        guard let r = s.range(of: "Credit...") else { return (s, nil) }
        let credit = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (s[..<r.lowerBound].trimmingCharacters(in: .whitespaces), credit.isEmpty ? nil : credit)
    }

    static func isBoilerplate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["Listen", "Image", "Advertisement", "Supported by", "Share", "Save"].contains(t) { return true }
        if t.firstMatch(of: /^·?\s*\d{1,3}(:\d{2})+\s*(min|minutes)?$/) != nil { return true }   // "· 19:52 min"
        if t.firstMatch(of: /^Published\b.*\bUpdated\b.*$/) != nil, t.count < 80 { return true }
        return false
    }
}
