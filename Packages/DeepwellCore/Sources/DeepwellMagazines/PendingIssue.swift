import Foundation
import CryptoKit
import DeepwellModel
import DeepwellLibrary

/// The pending-split marker (ticket 20): `issues/<issueID>.pending.json` next to the original. A file in the library,
/// so the Mac sees it through iCloud like everything else. The phone writes it when it hands an issue over; any device
/// that splits (or tries to split) an issue may also write one to carry its `ProcessingClaim`. The Mac deletes it when
/// the issue's articles are written. The phone shows "Splitting on Mac" for every marker whose issue has no articles.
///
/// The split queue itself is still derived from the library (an original with no article carrying its `issue_id`,
/// see `MagazineService`), so a marker that is lost or arrives late changes nothing but the phone's label.
public struct PendingIssue: Codable, Equatable, Sendable {
    public var issueID: String
    /// The original's file name in `issues/`.
    public var file: String
    public var title: String
    public var sharedAt: Date?
    /// Device that handed the issue over (nil: a Mac claimed an issue imported there).
    public var sharedFrom: String?
    public var claim: ProcessingClaim?

    public init(issueID: String, file: String, title: String, sharedAt: Date? = nil, sharedFrom: String? = nil,
                claim: ProcessingClaim? = nil) {
        self.issueID = issueID; self.file = file; self.title = title
        self.sharedAt = sharedAt; self.sharedFrom = sharedFrom; self.claim = claim
    }

    public static let suffix = ".pending.json"

    public static func url(for issueID: String, inLibrary library: URL) -> URL {
        IssueStore.issuesFolder(in: library).appendingPathComponent(issueID + suffix)
    }

    /// Issue id from a marker's file name, also for an evicted iCloud copy (`.<id>.pending.json.icloud`).
    public static func issueID(fromMarker url: URL) -> String? {
        var name = url.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(".icloud".count)) }
        guard name.hasSuffix(suffix) else { return nil }
        let id = String(name.dropLast(suffix.count))
        return id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil ? id : nil
    }

    // MARK: - Reading and writing (coordinated)

    public static func read(_ url: URL) -> PendingIssue? {
        guard let data = try? CoordinatedFile.read(url) else { return nil }
        return try? decoder.decode(PendingIssue.self, from: data)
    }

    public static func read(issueID: String, inLibrary library: URL) -> PendingIssue? {
        read(url(for: issueID, inLibrary: library))
    }

    public func write(inLibrary library: URL) throws {
        try FileManager.default.createDirectory(at: IssueStore.issuesFolder(in: library), withIntermediateDirectories: true)
        try CoordinatedFile.write(try Self.encoder.encode(self), to: Self.url(for: issueID, inLibrary: library))
    }

    public static func remove(issueID: String, inLibrary library: URL) {
        let u = url(for: issueID, inLibrary: library)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        try? CoordinatedFile.delete(u)
    }

    /// Ids of every marker in `issues/`, downloaded or not (the phone may only have the placeholder).
    public static func markerIDs(inLibrary library: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: IssueStore.issuesFolder(in: library),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return Array(Set(files.compactMap(issueID(fromMarker:)))).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id", file, title, sharedAt = "shared_at", sharedFrom = "shared_from"
        case processingBy = "processing_by", processingAt = "processing_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try c.decode(String.self, forKey: .issueID)
        file = try c.decode(String.self, forKey: .file)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? file
        sharedAt = try c.decodeIfPresent(String.self, forKey: .sharedAt).flatMap(Self.iso.date(from:))
        sharedFrom = try c.decodeIfPresent(String.self, forKey: .sharedFrom)
        if let by = try c.decodeIfPresent(String.self, forKey: .processingBy),
           let at = try c.decodeIfPresent(String.self, forKey: .processingAt).flatMap(Self.iso.date(from:)) {
            claim = ProcessingClaim(device: by, at: at)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(issueID, forKey: .issueID)
        try c.encode(file, forKey: .file)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(sharedAt.map(Self.iso.string(from:)), forKey: .sharedAt)
        try c.encodeIfPresent(sharedFrom, forKey: .sharedFrom)
        try c.encodeIfPresent(claim?.device, forKey: .processingBy)
        try c.encodeIfPresent(claim.map { Self.iso.string(from: $0.at) }, forKey: .processingAt)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}

/// The phone's half of the hand-off (ticket 20): put a shared PDF/EPUB into `issues/` with its marker. Never splits,
/// never parses, never needs the network. Idempotent: the same bytes again (a retried ingestion, or the same file shared
/// twice) copy nothing and write no second marker; an issue already split gets no marker at all.
public enum IssueHandOff {
    public struct Outcome: Equatable, Sendable {
        public var issueID: String
        /// The original was copied into `issues/` by this call.
        public var copied: Bool
        /// A marker was written by this call.
        public var markerWritten: Bool
    }

    public static func stage(_ source: URL, title: String? = nil, intoLibrary library: URL, device: String,
                             now: Date = Date(), fileManager fm: FileManager = .default) throws -> Outcome {
        guard IssueFormat(pathExtension: source.pathExtension) != nil else { throw MagazineError.unsupportedFile(source.lastPathComponent) }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? source.deletingPathExtension().lastPathComponent

        var copied = false
        let dest: URL
        if let existing = IssueStore.url(for: id, in: library, fileManager: fm) {
            dest = existing
        } else {
            try fm.createDirectory(at: IssueStore.issuesFolder(in: library), withIntermediateDirectories: true)
            dest = IssueStore.issuesFolder(in: library)
                .appendingPathComponent("\(id)-\(ItemFileWriter.slug(name)).\(source.pathExtension.lowercased())")
            try CoordinatedFile.copy(source, to: dest, fileManager: fm)
            copied = true
        }

        let marker = PendingIssue.url(for: id, inLibrary: library)
        let alreadyMarked = fm.fileExists(atPath: marker.path)
            || fm.fileExists(atPath: marker.deletingLastPathComponent().appendingPathComponent(".\(marker.lastPathComponent).icloud").path)
        guard !alreadyMarked, !IssueStore.isSplit(id, inLibrary: library, fileManager: fm) else {
            return Outcome(issueID: id, copied: copied, markerWritten: false)
        }
        try PendingIssue(issueID: id, file: dest.lastPathComponent, title: name, sharedAt: now, sharedFrom: device)
            .write(inLibrary: library)
        return Outcome(issueID: id, copied: copied, markerWritten: true)
    }

    /// Moves everything the Share Extension queued in `inbox` into the library; a file leaves the inbox only once it is
    /// staged, so an unavailable library just leaves it for the next foreground.
    @discardableResult
    public static func drain(inbox: URL, intoLibrary library: URL, device: String, now: Date = Date()) -> [Outcome] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { IssueFormat(pathExtension: $0.pathExtension) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Outcome] = []
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            let title = stem.range(of: "^[0-9]+-[0-9a-f]{8}-", options: .regularExpression).map { String(stem[$0.upperBound...]) } ?? stem
            guard let o = try? stage(f, title: title, intoLibrary: library, device: device, now: now) else { continue }
            try? fm.removeItem(at: f)
            out.append(o)
        }
        return out
    }
}

extension IssueStore {
    /// An article item (`*.md` at the library root) carries this issue id.
    public static func isSplit(_ issueID: String, inLibrary library: URL, fileManager fm: FileManager = .default) -> Bool {
        splitIDs(inLibrary: library, fileManager: fm).contains(issueID)
    }

    static func splitIDs(inLibrary library: URL, fileManager fm: FileManager = .default) -> Set<String> {
        var done = Set<String>()
        let files = (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "md" {
            if let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? FrontmatterCodec.decode(text),
               let id = doc.item.issueID { done.insert(id) }
        }
        return done
    }
}
