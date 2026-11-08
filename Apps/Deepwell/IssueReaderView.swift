import SwiftUI
import PDFKit
import WebKit
import DeepwellModel
import DeepwellMagazines
import DeepwellIndex

/// Shows the original issue (PDF or EPUB) opened at the article's position (`issue_start`).
struct IssueReaderView: View {
    let issueID: String
    let libraryFolder: URL
    let startUnit: Int

    @State private var failure: String?
    @State private var source: Source?

    enum Source { case pdf(URL), epub(chapter: URL, root: URL) }

    var body: some View {
        Group {
            if let failure { Text(failure).foregroundStyle(Ayu.red).padding() }
            else if let source {
                switch source {
                case .pdf(let url): PDFIssueView(url: url, page: startUnit)
                case .epub(let chapter, let root): EPUBIssueView(chapter: chapter, root: root)
                }
            } else { ProgressView() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = IssueStore.url(for: issueID, in: libraryFolder) else {
            failure = "The original issue file is missing from the library's issues folder."; return
        }
        do {
            try await ICloudPlaceholder.ensureLocal(file)
            switch IssueFormat(pathExtension: file.pathExtension) {
            case .pdf?: source = .pdf(file)
            case .epub?:
                let zip = try ZipArchive(url: file)
                let pkg = try EPUBPackage.parse(zip)
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Deepwell/epub/\(issueID)", isDirectory: true)
                if !FileManager.default.fileExists(atPath: root.path) { try zip.extractAll(to: root) }
                guard pkg.spinePaths.indices.contains(startUnit) || !pkg.spinePaths.isEmpty else { throw ZipError.missing("spine") }
                let path = pkg.spinePaths.indices.contains(startUnit) ? pkg.spinePaths[startUnit] : pkg.spinePaths[0]
                source = .epub(chapter: root.appendingPathComponent(path), root: root)
            case nil: failure = "Unsupported issue format."
            }
        } catch {
            failure = "Could not open the issue: \(error.localizedDescription)"
        }
    }
}

struct PDFIssueView: NSViewRepresentable {
    let url: URL
    let page: Int
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        if let p = v.document?.page(at: page) { v.go(to: p) }
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}

struct EPUBIssueView: NSViewRepresentable {
    let chapter: URL
    let root: URL
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.loadFileURL(chapter, allowingReadAccessTo: root)
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
