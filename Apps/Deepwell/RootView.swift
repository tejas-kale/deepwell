import SwiftUI
import DeepwellMagazines

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .needsFolder:
            FirstLaunchView(model: model)
        case .ready(let folder):
            LibraryView(folder: folder, tagging: model.tagging).id(folder)
                .dropDestination(for: URL.self) { urls, _ in
                    let mags = urls.filter { $0.isFileURL && IssueFormat(pathExtension: $0.pathExtension) != nil }
                    guard !mags.isEmpty else { return false }
                    model.importMagazines(mags)
                    return true
                }
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
