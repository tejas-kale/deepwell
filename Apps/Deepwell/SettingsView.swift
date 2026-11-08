import SwiftUI

/// One Anthropic key: when one is stored it is shown masked with Replace and Remove; otherwise a field to add it.
struct SettingsView: View {
    let tagging: TaggingController
    @State private var draft = ""
    @State private var replacing = false
    @State private var confirmRemove = false
    @State private var error: String?

    private var editing: Bool { !tagging.hasKey || replacing }

    var body: some View {
        Form {
            Section {
                if editing {
                    SecureField("API key", text: $draft, prompt: Text("sk-ant-…"))
                        .onSubmit(save)
                    HStack {
                        Spacer()
                        if replacing { Button("Cancel") { replacing = false; draft = "" } }
                        Button(replacing ? "Replace Key" : "Save Key", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    LabeledContent("API key") {
                        Text(tagging.keyHint ?? "Stored").font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                        Button("Replace…") { replacing = true }
                    }
                }
                if let error { Text(error).foregroundStyle(Ayu.red) }
            } header: {
                Text("Anthropic")
            } footer: {
                Text("Used for tagging, magazine splitting and the weekly menu. Stored only in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .ayuTheme()
        .confirmationDialog("Remove the stored API key?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) {
                do { try tagging.removeKey(); error = nil } catch { self.error = "Keychain error: \(error.localizedDescription)" }
            }
        } message: {
            Text("New captures stay untagged until you add a key again.")
        }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try tagging.saveKey(draft)   // updates the one Keychain item in place
            draft = ""; replacing = false; error = nil
        } catch {
            self.error = "Keychain error: \(error.localizedDescription)"
        }
    }
}
