import Foundation

/// "This device is working on it" (ticket 20), so two Macs sharing a library don't split the same issue or transcribe
/// the same item twice. Written into the thing being processed: an item's frontmatter (`processing_by: <device>` and
/// `processing_at: <ISO 8601>`, via `extraFrontmatter`) or an issue's `.pending.json` sidecar (same two keys).
///
/// A claim lapses `lifetime` (1 hour) after `at`, so a Mac that quit or crashed mid-job never blocks the others for
/// long. The claiming device clears it when it finishes (the item's `needs_transcript` goes with it) or gives up.
/// Claims are advisory: two Macs claiming within iCloud's sync delay can still both run, which at worst repeats the work.
public struct ProcessingClaim: Equatable, Sendable, Codable {
    public static let byKey = "processing_by"
    public static let atKey = "processing_at"
    public static let lifetime: TimeInterval = 3600

    public var device: String
    public var at: Date

    public init(device: String, at: Date) {
        self.device = ProcessingClaim.clean(device)
        self.at = at
    }

    /// Still in force at `now` (claims from a clock running ahead count until `at + lifetime`).
    public func isLive(at now: Date) -> Bool { now < at.addingTimeInterval(Self.lifetime) }

    /// Another device holds a live claim: `device` must leave the job alone.
    public func blocks(_ device: String, at now: Date) -> Bool {
        self.device != Self.clean(device) && isLive(at: now)
    }

    /// One line, plain YAML-safe: no colons, quotes or line breaks from a device name.
    static func clean(_ name: String) -> String {
        let kept = name.unicodeScalars.map { s -> Character in
            CharacterSet.alphanumerics.contains(s) || " -_.()'’".unicodeScalars.contains(s) ? Character(s) : " "
        }
        let out = String(kept).split(separator: " ").joined(separator: " ")
        return out.isEmpty ? "device" : out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s.trimmingCharacters(in: .whitespaces)) }
    static func string(_ d: Date) -> String { iso.string(from: d) }

    // Sidecar JSON uses the same keys as frontmatter.
    enum CodingKeys: String, CodingKey { case device = "processing_by", at = "processing_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(String.self, forKey: .device)
        let raw = try c.decode(String.self, forKey: .at)
        guard let d = Self.date(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "not ISO 8601: \(raw)")
        }
        at = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(device, forKey: .device)
        try c.encode(Self.string(at), forKey: .at)
    }
}

extension Item {
    /// The claim in this item's frontmatter, if both keys are present and readable.
    public var processingClaim: ProcessingClaim? {
        get {
            func value(_ key: String) -> String? {
                extraFrontmatter.lazy.compactMap { line -> String? in
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return parts.count == 2 && parts[0] == key ? parts[1] : nil
                }.first
            }
            guard let device = value(ProcessingClaim.byKey), !device.isEmpty,
                  let raw = value(ProcessingClaim.atKey), let at = ProcessingClaim.date(raw) else { return nil }
            return ProcessingClaim(device: device, at: at)
        }
        set {
            extraFrontmatter.removeAll { line in
                let key = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
                return key == ProcessingClaim.byKey || key == ProcessingClaim.atKey
            }
            if let c = newValue {
                extraFrontmatter.append("\(ProcessingClaim.byKey): \(c.device)")
                extraFrontmatter.append("\(ProcessingClaim.atKey): \(ProcessingClaim.string(c.at))")
            }
        }
    }
}
