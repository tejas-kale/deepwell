import Foundation

/// File-coordinated reads and writes (NSFileCoordinator), so iCloud and other processes (the iOS app's copy via
/// iCloud, Finder) never see a half-written item file and our writes never race a download. Every write to an item
/// file goes through here (see docs/storage.md). Never nest these calls for the same file: one coordination per
/// operation.
public enum CoordinatedFile {
    /// Thrown when a coordinated block fails before running (the coordinator's own error).
    private static func coordinate(_ run: (inout NSError?) -> Void) throws {
        var error: NSError?
        run(&error)
        if let error { throw error }
    }

    /// Writes `text` to `url`, replacing anything there.
    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        var inner: Error?
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
                do { try data.write(to: u, options: .atomic) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    /// Reads `url` (downloading it first if iCloud has evicted it).
    public static func read(_ url: URL) throws -> Data {
        var out: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { u in
                out = Result { try Data(contentsOf: u) }
            }
        }
        return try out.get()
    }

    public static func readString(_ url: URL) throws -> String {
        guard let s = String(data: try read(url), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return s
    }

    /// Read-modify-write under one coordinated write: `transform` gets the current text and returns the new text,
    /// or nil to leave the file untouched. Returns what `transform` returned.
    @discardableResult
    public static func update(_ url: URL, _ transform: (String) throws -> String?) throws -> String? {
        var out: Result<String?, Error> = .success(nil)
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &err) { u in
                out = Result {
                    guard let text = String(data: try Data(contentsOf: u), encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    let new = try transform(text)
                    if let new, new != text { try Data(new.utf8).write(to: u, options: .atomic) }
                    return new
                }
            }
        }
        return try out.get()
    }

    /// Copies `source` to `destination` (which must not exist) under coordination of both, via a temporary sibling
    /// and a rename, so `destination` is either absent or complete.
    public static func copy(_ source: URL, to destination: URL, fileManager fm: FileManager = .default) throws {
        var inner: Error?
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], writingItemAt: destination,
                                                             options: .forReplacing, error: &err) { src, dst in
                do {
                    let tmp = dst.deletingLastPathComponent()
                        .appendingPathComponent(".\(dst.lastPathComponent).deepwell-partial-\(UUID().uuidString.prefix(8))")
                    try? fm.removeItem(at: tmp)
                    try fm.copyItem(at: src, to: tmp)
                    do { try fm.moveItem(at: tmp, to: dst) } catch { try? fm.removeItem(at: tmp); throw error }
                } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    /// Runs `body` inside a coordinated write of `url` (e.g. to remove conflict versions).
    public static func coordinateWriting(_ url: URL, _ body: (URL) throws -> Void) throws {
        var inner: Error?
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &err) { u in
                do { try body(u) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    /// Read-modify-write of a data file that may not exist yet, under one coordinated write. `transform` gets the
    /// current bytes (nil when there is no file) and returns what to write, or nil to leave the file untouched.
    public static func updateData(_ url: URL, _ transform: (Data?) throws -> Data?) throws {
        var inner: Error?
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &err) { u in
                do {
                    let current = FileManager.default.fileExists(atPath: u.path) ? try Data(contentsOf: u) : nil
                    if let new = try transform(current), new != current { try new.write(to: u, options: .atomic) }
                } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    /// Deletes `url` under coordination.
    public static func delete(_ url: URL, fileManager fm: FileManager = .default) throws {
        var inner: Error?
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                do { try fm.removeItem(at: u) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    /// Moves `url` to the Trash under coordination (recoverable, unlike `delete`).
    public static func trash(_ url: URL, fileManager fm: FileManager = .default) throws {
        var inner: Error?
        try coordinate { err in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                do { try fm.trashItem(at: u, resultingItemURL: nil) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }
}
