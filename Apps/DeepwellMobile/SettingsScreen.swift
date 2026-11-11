import SwiftUI
import DeepwellNarration

/// iPhone tab / iPad sidebar row (ticket 16): the synced keys (set or not, never shown in full), the tagging model,
/// and the Listen model and voice (ticket 17 plays with these). Models and voice are per device for now.
struct SettingsScreen: View {
    @Environment(MobileAppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                KeyRow(title: "Anthropic", prompt: "sk-ant-…", account: settings.anthropic)
                KeyRow(title: "OpenRouter", prompt: "sk-or-…", account: settings.openRouter)
            } header: {
                Text("API keys")
            } footer: {
                Text("Stored in iCloud Keychain and shared with Deepwell on your Mac: enter a key once on any device. Anthropic tags what you save here; OpenRouter is for Listen.")
            }

            Section {
                Picker("Model", selection: $settings.taggingModel) {
                    ForEach(MobileSettings.taggingModels, id: \.1) { name, id in Text(name).tag(id) }
                    if !MobileSettings.taggingModels.contains(where: { $0.1 == settings.taggingModel }) {
                        Text(settings.taggingModel).tag(settings.taggingModel)
                    }
                }
                if let status = app.tagger.lastStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Tagging")
            } footer: {
                Text("Items saved on this device are tagged here, the same way the Mac does it. Items that already have tags are left alone.")
            }

            Section {
                Picker("Model", selection: Binding(get: { settings.narration.model }, set: { m in
                    settings.narration = NarrationSettings(model: m, voice: NarrationSettings.defaultVoice(for: m))
                })) {
                    ForEach(NarrationSettings.voicesByModel, id: \.model) { Text($0.name).tag($0.model) }
                    if !NarrationSettings.voicesByModel.contains(where: { $0.model == settings.narration.model }) {
                        Text(settings.narration.model).tag(settings.narration.model)
                    }
                }
                let voices = NarrationSettings.voicesByModel.first { $0.model == settings.narration.model }?.voices ?? []
                Picker("Voice", selection: $settings.narration.voice) {
                    ForEach(voices, id: \.self) { Text($0.components(separatedBy: ":").first ?? $0).tag($0) }
                    if !voices.contains(settings.narration.voice) { Text(settings.narration.voice).tag(settings.narration.voice) }
                }
                TextField("Voice ID", text: $settings.narration.voice)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Listen")
            } footer: {
                Text("Speech model and voice on this device. Any OpenRouter speech voice ID can be typed in.")
            }
        }
        .navigationTitle("Settings")
        .onAppear { settings.reloadKeys() }
    }
}

/// Set / not set with a masked hint; Replace opens a secure field, Remove asks first.
private struct KeyRow: View {
    let title: String
    let prompt: String
    let account: KeyAccount
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmRemove = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title) {
                if account.hasKey {
                    Text(account.hint ?? "Set").font(.body.monospaced()).foregroundStyle(.secondary)
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            if editing || !account.hasKey {
                SecureField("API key", text: $draft, prompt: Text(prompt))
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editing { Button("Cancel", role: .cancel) { editing = false; draft = "" } }
                }
                .buttonStyle(.borderless)
            } else {
                HStack {
                    Button("Replace") { editing = true }
                    Spacer()
                    Button("Remove", role: .destructive) { confirmRemove = true }
                }
                .buttonStyle(.borderless)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .confirmationDialog("Remove the \(title) key from all your devices?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do { try account.remove(); error = nil } catch { self.error = "Keychain error: \(error.localizedDescription)" }
            }
        } message: {
            Text("It is an iCloud Keychain item, so your Mac loses it too.")
        }
    }

    private func save() {
        do {
            try account.save(draft)
            draft = ""; editing = false; error = nil
        } catch {
            self.error = "Keychain error: \(error.localizedDescription)"
        }
    }
}
