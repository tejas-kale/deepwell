import Foundation

/// What one migration run did, by path relative to the old folder.
public struct MigrationReport: Equatable, Sendable {
    /// Copied into the new library, verified, then deleted from the old folder.
    public var moved: [String] = []
    /// An identical copy was already in the new library (an earlier, interrupted run); deleted from the old folder.
    public var alreadyThere: [String] = []
    /// A different file of the same name was already in the new library: kept both. Old name -> new name.
    public var renamed: [String: String] = [:]
    /// Evicted iCloud files whose download was requested; moved on a later run.
    public var pending: [String] = []
    /// Path -> error. The file stays in the old folder.
    public var failed: [String: String] = [:]

    public var isComplete: Bool { pending.isEmpty && failed.isEmpty }
    public init() {}
}

/// One-time move of the old, user-picked library folder (or the local fallback) into the iCloud container.
///
/// Safety rules (docs/storage.md):
/// - every file is copied with coordination (via a temporary name, then a rename), compared byte for byte with the
///   original, and only then deleted from the old folder; nothing is deleted before it has been copied;
/// - an interrupted run leaves each file either only in the old folder, in both (identical), or only in the new one,
///   and a re-run finishes the job: identical copies are recognised, partial temporaries are discarded;
/// - a different file that already has the same name in the new library is never overwritten: the incoming one is
///   kept next to it as `<name> (old library).<ext>`;
/// - when the old folder is empty, `MOVED.txt` is left there explaining where everything went.
public struct LibraryMigration {
    public static let noteName = "MOVED.txt"
    static let partialMarker = ".deepwell-partial-"
    /// Never moved and never counted as content.
    static let ignored: Set<String> = [noteName, ".DS_Store", ".Trash", ".localized", "Icon\r"]

    public let source: URL
    public let destination: URL
    private let fm: FileManager
    private let requestDownload: (URL) -> Void
    private let isDownloaded: (URL) -> Bool
    private let now: () -> Date

    public init(source: URL, destination: URL, fileManager: FileManager = .default,
                requestDownload: @escaping (URL) -> Void = { try? FileManager.default.startDownloadingUbiquitousItem(at: $0) },
                isDownloaded: @escaping (URL) -> Bool = LibraryMigration.isDownloaded,
                now: @escaping () -> Date = Date.init) {
        self.source = source
        self.destination = destination
        self.fm = fileManager
        self.requestDownload = requestDownload
        self.isDownloaded = isDownloaded
        self.now = now
    }

    /// False only for an iCloud file whose data is not on this Mac (a "dataless" file on current macOS). Copying one
    /// would block until it downloads (forever, offline), so the migration requests the download and retries later.
    public static func isDownloaded(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard v?.isUbiquitousItem == true, let status = v?.ubiquitousItemDownloadingStatus else { return true }
        return status != .notDownloaded
    }

    /// True if `folder` holds anything worth moving (MOVED.txt and Finder litter don't count).
    public static func hasItems(in folder: URL, fileManager fm: FileManager = .default) -> Bool {
        contents(of: folder, fileManager: fm) == .hasItems
    }

    public enum Contents: Equatable, Sendable { case hasItems, empty, unreadable }

    /// Like `hasItems`, but tells "empty" from "could not be listed" (which must never be taken as "done").
    public static func contents(of folder: URL, fileManager fm: FileManager = .default) -> Contents {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return .unreadable }
        return names.contains { !ignored.contains($0) && !$0.contains(partialMarker) } ? .hasItems : .empty
    }

    public func run() -> MigrationReport {
        var report = MigrationReport()
        let src = source.standardizedFileURL.resolvingSymlinksInPath()
        let dst = destination.standardizedFileURL.resolvingSymlinksInPath()
        // Refuse overlapping folders: moving a folder into itself would delete what it copies.
        guard src.path != dst.path, !dst.path.hasPrefix(src.path + "/"), !src.path.hasPrefix(dst.path + "/") else {
            report.failed[""] = "old and new library folders overlap"
            return report
        }
        do { try fm.createDirectory(at: dst, withIntermediateDirectories: true) } catch {
            report.failed[""] = error.localizedDescription
            return report
        }
        moveContents(of: src, into: dst, relative: "", report: &report)
        if report.isComplete, !Self.hasItems(in: src, fileManager: fm) {
            try? CoordinatedFile.write(note(report), to: src.appendingPathComponent(Self.noteName))
        }
        return report
    }

    private func moveContents(of dir: URL, into target: URL, relative: String, report: inout MigrationReport) {
        discardPartials(in: target)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            report.failed[relative] = "could not list folder"
            return
        }
        for name in names.sorted() where !Self.ignored.contains(name) {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let from = dir.appendingPathComponent(name)
            if name.contains(Self.partialMarker) { continue }
            if let real = placeholderTarget(name) {
                requestDownload(dir.appendingPathComponent(real))
                report.pending.append(relative.isEmpty ? real : relative + "/" + real)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let to = target.appendingPathComponent(name, isDirectory: true)
                do { try fm.createDirectory(at: to, withIntermediateDirectories: true) } catch {
                    report.failed[rel] = error.localizedDescription
                    continue
                }
                moveContents(of: from, into: to, relative: rel, report: &report)
                // Remove the old directory only once nothing (but litter) is left in it.
                if !Self.hasItems(in: from, fileManager: fm) {
                    for litter in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                        try? fm.removeItem(at: from.appendingPathComponent(litter))
                    }
                    do { try CoordinatedFile.delete(from, fileManager: fm) } catch { report.failed[rel] = error.localizedDescription }
                }
            } else {
                moveFile(from, into: target, name: name, relative: rel, report: &report)
            }
        }
    }

    private func moveFile(_ from: URL, into target: URL, name: String, relative rel: String, report: inout MigrationReport) {
        guard isDownloaded(from) else {
            requestDownload(from)
            report.pending.append(rel)
            return
        }
        do {
            var to = target.appendingPathComponent(name)
            var renamedTo: String?
            if fm.fileExists(atPath: to.path) {
                if fm.contentsEqual(atPath: from.path, andPath: to.path) {
                    try CoordinatedFile.delete(from, fileManager: fm)
                    report.alreadyThere.append(rel)
                    return
                }
                // Different content under the same name: never overwrite, keep both.
                let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
                var n = 1
                repeat {
                    let label = n == 1 ? "old library" : "old library \(n)"
                    let candidate = ext.isEmpty ? "\(stem) (\(label))" : "\(stem) (\(label)).\(ext)"
                    to = target.appendingPathComponent(candidate)
                    renamedTo = candidate
                    n += 1
                    if fm.fileExists(atPath: to.path), fm.contentsEqual(atPath: from.path, andPath: to.path) {
                        try CoordinatedFile.delete(from, fileManager: fm)
                        report.alreadyThere.append(rel)
                        return
                    }
                } while fm.fileExists(atPath: to.path)
            }
            try CoordinatedFile.copy(from, to: to, fileManager: fm)
            guard fm.contentsEqual(atPath: from.path, andPath: to.path) else {
                report.failed[rel] = "copy did not match the original; kept the original"
                return
            }
            try CoordinatedFile.delete(from, fileManager: fm)
            if let renamedTo { report.renamed[rel] = renamedTo } else { report.moved.append(rel) }
        } catch {
            report.failed[rel] = error.localizedDescription
        }
    }

    /// Leftovers of a copy interrupted between writing the temporary file and renaming it.
    private func discardPartials(in dir: URL) {
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.contains(Self.partialMarker) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// `.note.md.icloud` -> `note.md` (evicted file on systems that still use placeholder stubs).
    private func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private func note(_ report: MigrationReport) -> String {
        let f = ISO8601DateFormatter()
        var s = """
        Deepwell moved this library on \(f.string(from: now())) into its own iCloud folder.
        In Finder it is iCloud Drive › Deepwell, the folder with the Deepwell icon; the app reads and writes only there now.

        Every file was copied there, checked against the original, and only then deleted from here.
        This folder is no longer used and can be deleted.

        """
        if !report.renamed.isEmpty {
            s += "\nThese files had a different file of the same name already in the new library, so both were kept:\n"
            for (old, new) in report.renamed.sorted(by: { $0.key < $1.key }) { s += "  \(old) -> \(new)\n" }
        }
        return s
    }
}
