import Foundation
import Observation
import DeepwellIndex
import DeepwellKindle
import DeepwellMenu
import DeepwellModel
import DeepwellTagging

/// Thin glue over DeepwellKindle: settings (UserDefaults), the two secrets (Keychain), when each focus was sent,
/// and the send itself. Packing and SMTP logic live in the package.
@Observable
@MainActor
final class KindleController {
    private static let settingsKey = "kindle.settings"
    private static let sentKey = "kindle.sentFocus"

    var settings: KindleSettings { didSet { saveSettings() } }
    let smtpPassword: APIKeyStore = KeychainAPIKeyStore(service: "com.tejaskale.deepwell.smtp", account: "password")
    let openRouterKey: APIKeyStore = KeychainAPIKeyStore(service: "com.tejaskale.deepwell.openrouter", account: "api-key")
    private(set) var hasPassword: Bool
    private(set) var hasOpenRouterKey: Bool

    private(set) var isSending = false
    private(set) var status: String?
    private(set) var statusIsError = false

    init() {
        let d = UserDefaults.standard
        settings = d.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(KindleSettings.self, from: $0) } ?? KindleSettings()
        hasPassword = smtpPassword.load() != nil
        hasOpenRouterKey = openRouterKey.load() != nil
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    func savePassword(_ s: String) throws { try smtpPassword.save(s); hasPassword = smtpPassword.load() != nil }
    func removePassword() throws { try smtpPassword.delete(); hasPassword = false }
    func saveOpenRouterKey(_ s: String) throws { try openRouterKey.save(s); hasOpenRouterKey = openRouterKey.load() != nil }
    func removeOpenRouterKey() throws { try openRouterKey.delete(); hasOpenRouterKey = false }

    // MARK: Sent log

    /// A focus is identified by when it was picked; re-picking makes a new focus.
    private static func key(_ q: WeekQueue) -> String { ISO8601DateFormatter().string(from: q.pickedAt) }

    func lastSent(_ q: WeekQueue) -> Date? {
        (UserDefaults.standard.dictionary(forKey: Self.sentKey) as? [String: Date])?[Self.key(q)]
    }

    private func markSent(_ q: WeekQueue) {
        var log = (UserDefaults.standard.dictionary(forKey: Self.sentKey) as? [String: Date]) ?? [:]
        log[Self.key(q)] = Date()
        UserDefaults.standard.set(log, forKey: Self.sentKey)
    }

    // MARK: Send

    /// Unfinished articles and magazine articles of the focus, in queue order.
    func articles(in q: WeekQueue, library: LibraryModel) -> [IndexedItem] {
        q.entries.compactMap { library.entry(id: $0.itemID) }
            .filter { [.article, .magazineArticle].contains($0.item.type) && $0.item.status != .done }
    }

    func send(_ q: WeekQueue, library: LibraryModel) {
        guard !isSending else { return }
        if let m = settings.missing { return fail("Set the \(m) in Settings > Kindle first.") }
        guard let password = smtpPassword.load() else { return fail("Set the SMTP password in Settings > Kindle first.") }
        let entries = articles(in: q, library: library)
        guard !entries.isEmpty else { return fail("Nothing to send: this focus has no unfinished articles or magazine articles.") }
        let files = entries.map { library.fileURL(for: $0) }
        let settings = self.settings
        let artist: CoverArtist? = hasOpenRouterKey ? OpenRouterCoverArt(keys: openRouterKey) : nil
        isSending = true
        report("Preparing \(entries.count) article\(entries.count == 1 ? "" : "s") for Kindle…")

        Task {
            do {
                var articles: [KindleArticle] = []
                for url in files {
                    try await ICloudPlaceholder.ensureLocal(url)
                    let doc = try FrontmatterCodec.decode(try String(contentsOf: url, encoding: .utf8))
                    articles.append(KindleArticle(item: doc.item, body: doc.body, fileURL: url))
                }
                let pkg = try await KindlePackager(artist: artist).package(articles: articles, topic: q.topic) { msg in
                    Task { @MainActor in self.report(msg) }
                }
                report("Emailing \(pkg.title) (\(ByteCountFormatter.string(fromByteCount: Int64(pkg.epub.count), countStyle: .file)))…")
                try await KindleSender(settings: settings).send(pkg, password: password)
                markSent(q)
                var done = "Sent \(pkg.chapterCount) article\(pkg.chapterCount == 1 ? "" : "s") to \(settings.kindleAddress)."
                if pkg.droppedImages > 0 { done += " \(pkg.droppedImages) image\(pkg.droppedImages == 1 ? "" : "s") could not be fetched and were left out." }
                if let why = pkg.coverFallbackReason { done += " Plain cover used (\(why))." }
                report(done)
                clearLater()
            } catch {
                switch error {
                case let e as KindleError: fail("Kindle: \(e).")
                case let e as SMTPError: fail("Kindle: \(e).")
                default: fail("Kindle: \(error.localizedDescription)")
                }
            }
            isSending = false
        }
    }

    /// A one-off message in the footer (e.g. "pick a focus first").
    func notify(_ s: String) { fail(s) }

    private var clearTask: Task<Void, Never>?

    private func report(_ s: String) { clearTask?.cancel(); status = s; statusIsError = false }
    private func fail(_ s: String) { report(s); statusIsError = true; clearLater() }

    /// Results and errors fade from the footer after a minute so the tagging status shows again.
    private func clearLater() {
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, !self.isSending else { return }
            self.status = nil
        }
    }
}
