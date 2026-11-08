import SwiftUI
import DeepwellKindle

/// One Anthropic key: when one is stored it is shown masked with Replace and Remove; otherwise a field to add it.
struct SettingsView: View {
    let tagging: TaggingController
    let kindle: KindleController

    var body: some View {
        TabView {
            AnthropicSettingsView(tagging: tagging).tabItem { Label("Anthropic", systemImage: "sparkles") }
            KindleSettingsView(kindle: kindle).tabItem { Label("Kindle", systemImage: "book") }
        }
        .ayuTheme()
    }
}

private struct AnthropicSettingsView: View {
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

/// Kindle delivery: addresses and SMTP server (UserDefaults), SMTP password and OpenRouter key (Keychain).
private struct KindleSettingsView: View {
    @Bindable var kindle: KindleController

    var body: some View {
        Form {
            Section {
                TextField("Kindle address", text: $kindle.settings.kindleAddress, prompt: Text("name@kindle.com"))
                TextField("Sender", text: $kindle.settings.sender, prompt: Text("you@gmail.com"))
            } header: {
                Text("Send to Kindle")
            } footer: {
                Text("Add the sender to Amazon's Approved Personal Document E-mail List (Manage Your Content and Devices > Preferences).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("SMTP server") {
                TextField("Server", text: $kindle.settings.smtp.host)
                Picker("Security", selection: Binding(get: { kindle.settings.smtp.security }, set: { s in
                    kindle.settings.smtp.security = s
                    kindle.settings.smtp.port = s == .startTLS ? 587 : 465
                })) {
                    Text("STARTTLS").tag(SMTPSettings.Security.startTLS)
                    Text("SSL/TLS").tag(SMTPSettings.Security.implicitTLS)
                }
                TextField("Port", value: $kindle.settings.smtp.port, format: .number.grouping(.never))
                TextField("Username", text: $kindle.settings.smtp.username, prompt: Text("same as sender"))
                SecretRow(label: "Password", prompt: "Gmail app password", stored: kindle.hasPassword,
                          save: kindle.savePassword, remove: kindle.removePassword)
            }
            Section {
                SecretRow(label: "OpenRouter key", prompt: "sk-or-…", stored: kindle.hasOpenRouterKey,
                          save: kindle.saveOpenRouterKey, remove: kindle.removeOpenRouterKey)
            } header: {
                Text("Cover art")
            } footer: {
                Text("Optional. Without a key, or if image generation fails, a plain cover is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A Keychain secret: a field to add it, or "Stored" with Replace and Remove.
private struct SecretRow: View {
    let label: String
    let prompt: String
    let stored: Bool
    let save: (String) throws -> Void
    let remove: () throws -> Void
    @State private var draft = ""
    @State private var replacing = false
    @State private var error: String?

    var body: some View {
        if stored && !replacing {
            LabeledContent(label) {
                HStack {
                    Text("Stored in Keychain").foregroundStyle(.secondary)
                    Button("Replace") { replacing = true }
                    Button("Remove", role: .destructive) { run { try remove() } }
                }
            }
        } else {
            HStack {
                SecureField(label, text: $draft, prompt: Text(prompt)).onSubmit(commit)
                if replacing { Button("Cancel") { replacing = false; draft = "" } }
                Button("Save", action: commit).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if let error { Text(error).foregroundStyle(Ayu.red) }
    }

    private func commit() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run { try save(draft); draft = ""; replacing = false }
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); error = nil } catch { self.error = "Keychain error: \(error.localizedDescription)" }
    }
}
