import Foundation
#if os(macOS)
import CoreServices

/// Watches a folder tree (FSEvents) and calls `onChange` (on a background queue) after a burst of changes settles.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "deepwell.folderwatcher")
    private let handler: Handler

    private final class Handler {
        let onChange: @Sendable () -> Void
        init(_ f: @escaping @Sendable () -> Void) { onChange = f }
    }

    public init(url: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        handler = Handler(onChange)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<Handler>.fromOpaque(info!).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [url.resolvingSymlinksInPath().path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
#endif
