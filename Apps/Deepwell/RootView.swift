import SwiftUI
import DeepwellUI
import DeepwellMagazines
import DeepwellLibrary

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .opening, .migrating:
            OpeningView(migrating: model.phase == .migrating)
        case .ready(let location):
            VStack(spacing: 0) {
                if let banner = model.banner { StorageBannerView(banner: banner, model: model) }
                LibraryView(location: location, tagging: model.tagging, kindle: model.kindle).id(location)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let mags = urls.filter { $0.isFileURL && IssueFormat(pathExtension: $0.pathExtension) != nil }
                guard !mags.isEmpty else { return false }
                model.importMagazines(mags)
                return true
            }
        }
    }
}

/// Shown while the iCloud container resolves and, on the first launch after ticket 13, while the old library moves in.
struct OpeningView: View {
    let migrating: Bool

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(migrating ? "Moving your library into iCloud Drive › Deepwell…" : "Opening your library…").font(.title3)
            if migrating {
                Text("Each file is copied, checked, and only then removed from the old folder. This happens once.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StorageBannerView: View {
    let banner: StorageBanner
    let model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: banner.kind == .signedOut ? "icloud.slash" : "exclamationmark.triangle")
            Text(banner.message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if banner.kind == .oldFolderUnreachable {
                Button("Locate Old Library…") { model.locateOldLibrary() }
            }
            if let msg = model.errorMessage { Text(msg).foregroundStyle(Ayu.red) }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Ayu.accent.opacity(0.15))
    }
}
