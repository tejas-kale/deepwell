import SwiftUI
import DeepwellUI
import AVFoundation
import DeepwellKindle
import DeepwellMenu
import DeepwellNarration

/// The Mac's Settings window: General, AI (both API keys), Weekly Menu, Kindle, Listen.
struct SettingsView: View {
    let tagging: TaggingController
    let kindle: KindleController
    let preferences: Preferences
    /// Library root, for the pronunciation map (nil while the library is still opening).
    let libraryFolder: URL?

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences).tabItem { Label("General", systemImage: "gearshape") }
            AISettingsView(tagging: tagging, openRouter: OpenRouterAccount.shared).tabItem { Label("AI", systemImage: "sparkles") }
            MenuSettingsView(preferences: preferences).tabItem { Label("Weekly Menu", systemImage: "square.stack") }
            KindleSettingsView(kindle: kindle).tabItem { Label("Kindle", systemImage: "book") }
            ListenSettingsView(preferences: preferences, libraryFolder: libraryFolder).tabItem { Label("Listen", systemImage: "headphones") }
        }
        .ayuTheme()
    }
}

private struct GeneralSettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Bring Deepwell to the front", isOn: $preferences.bringToFrontOnSave)
            } header: {
                Text("When you save from Safari or the Share menu")
            } footer: {
                Text("Off: the item is saved in the background and you stay where you are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How Build Menu / Rebuild works: model, effort, prompt and sizing, which apply to the next build. Also the reading
/// nudge switch and time, which apply at the next nudge check on the Mac and the iPhone.
private struct MenuSettingsView: View {
    @Bindable var preferences: Preferences
    private static let models = [("Opus 5.5", "claude-opus-5-5"), ("Sonnet 5.5", "claude-sonnet-5-5"), ("Haiku 5.5", "claude-haiku-5-5")]

    var body: some View {
        let z = preferences.menu
        Form {
            Section {
                Picker("Model", selection: $preferences.menu.model) {
                    ForEach(Self.models, id: \.1) { name, id in Text(name).tag(id) }
                    if !Self.models.contains(where: { $0.1 == z.model }) { Text(z.model).tag(z.model) }   // set elsewhere
                }
                Picker("Effort", selection: $preferences.menu.effort) {
                    ForEach(MenuSettings.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Thinking shares the 16k-token reply budget: high or max effort can run out before the answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                NumberRow("Longest bundle", value: $preferences.menu.maxBundleMinutes,
                          in: max(15, z.minBundleMinutes)...1200, unit: "min")
                NumberRow("Shortest bundle", value: $preferences.menu.minBundleMinutes,
                          in: 15...z.maxBundleMinutes, unit: "min")
                NumberRow("Fewest items per bundle", value: $preferences.menu.minItems, in: 1...50, unit: "items")
                NumberRow("Most bundles to choose from", value: $preferences.menu.maxBundles, in: 1...10, unit: "bundles")
            } header: {
                Text("Bundle size")
            } footer: {
                Text("Bundles over the maximum lose their deepest items; bundles under either minimum are dropped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Library") {
                NumberRow("Reading speed", value: $preferences.menu.wordsPerMinute, in: 50...1000, unit: "words/min")
                NumberRow("Items sent to the model", value: $preferences.menu.maxCandidates, in: 10...2000, unit: "newest")
                NumberRow("Recent topics to avoid", value: $preferences.menu.recentPicks, in: 0...52, unit: "picks")
            }

            Section {
                TextEditor(text: $preferences.menu.promptTemplate)
                    .font(.body.monospaced())
                    .frame(height: 180)
                HStack {
                    Spacer()
                    Button("Restore Default Prompt") { preferences.menu.promptTemplate = MenuPrompt.defaultTemplate }
                        .disabled(z.promptTemplate == MenuPrompt.defaultTemplate)
                }
            } header: {
                Text("Prompt")
            } footer: {
                Text("{max_minutes}, {min_minutes}, {min_items} and {max_bundles} are filled in from the sizes above. "
                     + "The item list and recently picked topics are sent after it. Replies are always JSON.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Nudge me when I fall behind", isOn: $preferences.nudge.enabled)
                DatePicker("Nudge time", selection: nudgeTime, displayedComponents: .hourAndMinute)
                    .disabled(!preferences.nudge.enabled)
            } header: {
                Text("Nudges")
            } footer: {
                Text("One evening notification when the current focus falls behind the week's pace. "
                     + "Your iPhone follows these settings through iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore All Defaults") {
                    preferences.menu = MenuSettings()
                    preferences.nudge = NudgeSettings()
                }
                .disabled(z == MenuSettings() && preferences.nudge == NudgeSettings())
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    /// The nudge time (minutes after midnight) as a time of day today, for the picker.
    private var nudgeTime: Binding<Date> {
        Binding(
            get: {
                let m = preferences.nudge.minuteOfDay
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                preferences.nudge.minuteOfDay = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// The AI tab: the Anthropic and OpenRouter keys, both synced iCloud Keychain items (docs/tagging.md, Keys).
/// One tab since ticket 18; each key behaves exactly as it did in its own tab.
private struct AISettingsView: View {
    let tagging: TaggingController
    let openRouter: OpenRouterAccount

    var body: some View {
        Form {
            AnthropicKeySection(tagging: tagging)
            OpenRouterKeySection(account: openRouter)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .ayuTheme()
    }
}

/// One Anthropic key: when one is stored it is shown masked with Replace and Remove; otherwise a field to add it.
private struct AnthropicKeySection: View {
    let tagging: TaggingController
    @State private var draft = ""
    @State private var replacing = false
    @State private var confirmRemove = false
    @State private var error: String?

    private var editing: Bool { !tagging.hasKey || replacing }

    var body: some View {
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
            Text("Used for tagging, magazine splitting and the weekly menu. Stored in iCloud Keychain, so your iPhone and iPad have it too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { tagging.refreshKey() }
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

/// Kindle delivery: addresses and SMTP server (UserDefaults) and SMTP password (Keychain).
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
                LabeledContent("OpenRouter key", value: OpenRouterAccount.shared.hasKey ? "Set" : "Not set")
            } header: {
                Text("Cover art")
            } footer: {
                Text("Optional. Uses the OpenRouter key in Settings > AI. Without one, or if image generation fails, a plain cover is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label, a short right-aligned number field and its unit. Typed values are clamped to `range` when committed
/// (Return or leaving the field).
private struct NumberRow: View {
    let label: String
    let value: Binding<Int>
    let range: ClosedRange<Int>
    let unit: String

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, unit: String) {
        self.label = label; self.value = value; self.range = range; self.unit = unit
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: Binding(get: { value.wrappedValue },
                                                set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text(unit).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            }
        }
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

/// The one OpenRouter key: Kindle cover art and Listen.
private struct OpenRouterKeySection: View {
    let account: OpenRouterAccount

    var body: some View {
        Section {
            SecretRow(label: "API key", prompt: "sk-or-…", stored: account.hasKey, save: account.save, remove: account.remove)
        } header: {
            Text("OpenRouter")
        } footer: {
            Text("Used for Listen (text to speech) and Kindle cover art. Stored in iCloud Keychain, so your iPhone and iPad have it too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { account.reload() }
    }
}

/// Listen: speech model and voice, and the pronunciation map.
private struct ListenSettingsView: View {
    @Bindable var preferences: Preferences
    let libraryFolder: URL?

    private var voices: [String] {
        NarrationSettings.voicesByModel.first { $0.model == preferences.narration.model }?.voices ?? []
    }

    var body: some View {
        let n = preferences.narration
        Form {
            Section {
                Picker("Model", selection: Binding(get: { n.model }, set: { m in
                    preferences.narration = NarrationSettings(model: m, voice: NarrationSettings.defaultVoice(for: m))
                })) {
                    ForEach(NarrationSettings.voicesByModel, id: \.model) { Text($0.name).tag($0.model) }
                    if !NarrationSettings.voicesByModel.contains(where: { $0.model == n.model }) { Text(n.model).tag(n.model) }
                }
                Picker("Voice", selection: $preferences.narration.voice) {
                    ForEach(voices, id: \.self) { Text($0.components(separatedBy: ":").first ?? $0).tag($0) }
                    if !voices.contains(n.voice) { Text(n.voice).tag(n.voice) }
                }
                TextField("Voice ID", text: $preferences.narration.voice)
                    .font(.body.monospaced())
            } header: {
                Text("Voice")
            } footer: {
                Text("Any OpenRouter speech voice ID can be typed in. Changing the voice re-narrates articles as you listen to them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if let libraryFolder {
                    PronunciationEditor(store: PronunciationStore(libraryFolder: libraryFolder), settings: n)
                } else {
                    Text("The library is still opening.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Pronunciations")
            } footer: {
                Text("Whole words, any case. Saved as pronunciations.yml in the library (readcast's format), so it syncs. "
                     + "Built-in entries are greyed out; overriding one copies it to your list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
    }
}

/// Written → Spoken table over the user's pronunciations.yml, with the bundled entries shown greyed out.
private struct PronunciationEditor: View {
    let store: PronunciationStore
    let settings: NarrationSettings

    struct Row: Identifiable, Equatable { let id = UUID(); var written: String; var spoken: String }

    @State private var rows: [Row] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var previewing: UUID?
    @State private var audio: AVAudioPlayer?

    private var userKeys: Set<String> { Set(rows.map { $0.written.lowercased() }) }
    private func matches(_ w: String, _ s: String) -> Bool {
        search.isEmpty || w.localizedCaseInsensitiveContains(search) || s.localizedCaseInsensitiveContains(search)
    }
    private var bundled: [(String, String)] {
        PronunciationStore.bundled.filter { !userKeys.contains($0.key.lowercased()) && matches($0.key, $0.value) }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $search, prompt: Text("Search pronunciations"))
                Button { rows.insert(Row(written: "", spoken: ""), at: 0); search = "" } label: { Label("Add", systemImage: "plus") }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Written").font(.caption).foregroundStyle(.secondary)
                    Text("Spoken").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 1, height: 1)
                }
                ForEach($rows) { $row in
                    if matches(row.written, row.spoken) || row.written.isEmpty {
                        GridRow {
                            TextField("Written", text: $row.written, prompt: Text("beehiiv")).labelsHidden()
                            TextField("Spoken", text: $row.spoken, prompt: Text("beehive")).labelsHidden()
                            HStack(spacing: 4) {
                                previewButton(row.id, row.spoken)
                                Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove")
                            }
                        }
                    }
                }
                ForEach(bundled, id: \.0) { w, s in
                    GridRow {
                        Text(w).foregroundStyle(.tertiary)
                        Text(s).foregroundStyle(.tertiary)
                        HStack(spacing: 4) {
                            previewButton(nil, s)
                            Button("Override") { rows.insert(Row(written: w, spoken: s), at: 0) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Ayu.red).font(.caption) }
        }
        .onAppear {
            guard !loaded else { return }
            rows = store.load().sorted { $0.key.lowercased() < $1.key.lowercased() }.map { Row(written: $0.key, spoken: $0.value) }
            loaded = true
        }
        .onChange(of: rows) { save() }
    }

    private func previewButton(_ id: UUID?, _ spoken: String) -> some View {
        Button { preview(id, spoken) } label: {
            if previewing == id && previewing != nil { ProgressView().controlSize(.mini) } else { Image(systemName: "play.circle") }
        }
        .buttonStyle(.borderless)
        .disabled(spoken.trimmingCharacters(in: .whitespaces).isEmpty || !OpenRouterAccount.shared.hasKey)
        .help(OpenRouterAccount.shared.hasKey ? "Hear it in the current voice" : "Add an OpenRouter key to preview")
    }

    private func preview(_ id: UUID?, _ spoken: String) {
        previewing = id ?? UUID()
        Task {
            defer { previewing = nil }
            do {
                let data = try await previewSpeech(spoken, settings: settings, keys: OpenRouterAccount.shared.keys)
                audio = try AVAudioPlayer(data: data)
                audio?.play()
                error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Complete rows only; the last spelling of a repeated word wins.
    private func save() {
        var entries: [String: String] = [:]
        for r in rows {
            let w = r.written.trimmingCharacters(in: .whitespaces), s = r.spoken.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty && !s.isEmpty { entries[w] = s }
        }
        guard entries != store.load() else { return }
        do { try store.save(entries); error = nil } catch { self.error = "Could not save pronunciations.yml: \(error.localizedDescription)" }
    }
}
