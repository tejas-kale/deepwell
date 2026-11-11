import Foundation
import Observation
import DeepwellLibrary

/// Finds the library: the iCloud container's `Documents/`, resolved off the main thread. There is no local fallback
/// on iOS (spec): signed out of iCloud, or iCloud Drive off for Deepwell, means a clear empty state and no library.
@Observable
@MainActor
final class MobileAppModel {
    enum Phase: Equatable { case opening, signedOut, ready }

    private(set) var phase = Phase.opening
    private(set) var library: FocusLibrary?

    @ObservationIgnored private let store = LibraryFolderStore()
    @ObservationIgnored private var identityObserver: NSObjectProtocol?
    @ObservationIgnored private var opening: Task<Void, Never>?

    init() {
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.open() }
        }
        open()
    }

    /// Resolves the container (blocking, so detached) and opens or closes the library to match.
    func open() {
        opening?.cancel()
        let store = store
        opening = Task {
            let location = await Task.detached { store.resolveContainer() }.value
            guard !Task.isCancelled else { return }
            guard let location else {
                library?.stop()
                library = nil
                phase = .signedOut
                return
            }
            if library?.location != location {
                library?.stop()
                library = FocusLibrary(location: location)
            }
            phase = .ready
        }
    }

    /// Back in the foreground: iCloud may have been signed in or out meanwhile, and files may have changed.
    func becameActive() {
        if phase == .ready, let library { library.refresh() } else { open() }
    }
}
