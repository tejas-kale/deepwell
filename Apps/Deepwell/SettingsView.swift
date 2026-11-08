import SwiftUI

struct SettingsView: View {
    let tagging: TaggingController
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Anthropic API key") {
                SecureField("sk-ant-…", text: $draft)
                HStack {
                    Button("Save to Keychain") {
                        do { try tagging.saveKey(draft); draft = ""; error = nil }
                        catch { self.error = "Keychain error: \(error.localizedDescription)" }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if tagging.hasKey {
                        Button("Remove key") { try? tagging.removeKey() }
                    }
                }
                Text(tagging.hasKey ? "A key is stored in the Keychain." : "No key stored. New items will stay untagged until you add one.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = tagging.lastStatus { Text(status).font(.caption) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
