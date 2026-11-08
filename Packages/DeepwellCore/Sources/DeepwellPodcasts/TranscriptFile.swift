import Foundation
import DeepwellTranscription

/// Parses a publisher-supplied transcript (WebVTT, SRT, Podcasting 2.0 JSON, or plain text) into timed cues.
public enum TranscriptFile {
    public static func parse(_ data: Data, type: String?) -> [TimedWord] {
        let text = String(decoding: data, as: UTF8.self)
        let t = (type ?? "").lowercased()
        if t.contains("json") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            let cues = parseJSON(data)
            if !cues.isEmpty { return cues }
        }
        if text.contains("-->") { return parseTimed(text) }
        return []   // plain/HTML transcripts have no timestamps; callers fall back to on-device transcription
    }

    /// WebVTT and SRT share the "start --> end" cue shape.
    static func parseTimed(_ text: String) -> [TimedWord] {
        var cues: [TimedWord] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }),
                  let start = timestamp(String(lines[i].components(separatedBy: "-->")[0])) else { continue }
            let body = lines[(i + 1)...].map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { cues.append(TimedWord(start: start, text: body)) }
        }
        return cues
    }

    /// {"segments":[{"startTime":1.5,"body":"…","speaker":"…"}]}
    static func parseJSON(_ data: Data) -> [TimedWord] {
        struct Doc: Decodable { struct Seg: Decodable { var startTime: Double?; var body: String? }; var segments: [Seg]? }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return [] }
        return (doc.segments ?? []).compactMap { s in
            guard let t = s.startTime, let b = s.body?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return nil }
            return TimedWord(start: t, text: b)
        }
    }

    /// "00:01:02.500", "01:02,500" or "1:02".
    static func timestamp(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: " ")[0]
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}
