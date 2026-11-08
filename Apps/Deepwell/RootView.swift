import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .needsFolder:
            FirstLaunchView(model: model)
        case .ready(let folder):
            VStack(alignment: .leading, spacing: 12) {
                Label(folder.path, systemImage: "folder").font(.callout).foregroundStyle(.secondary)
                Text("Saved this session").font(.headline)
                if model.recentSaves.isEmpty {
                    Text("Press the Deepwell button in Safari to save a page.").foregroundStyle(.secondary)
                } else {
                    List(model.recentSaves, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            .padding()
        }
    }
}

struct FirstLaunchView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 44))
            Text("Welcome to Deepwell").font(.title2.bold())
            Text("Pick the folder where your saved items live as Markdown files.\nThe default is iCloud Drive/Deepwell.")
                .multilineTextAlignment(.center)
            Button("Choose Library Folder…") { model.chooseFolder() }
                .keyboardShortcut(.defaultAction)
            if let msg = model.errorMessage { Text(msg).foregroundStyle(.red) }
        }
        .padding(32)
    }
}
