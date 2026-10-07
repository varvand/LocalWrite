import AppKit
import LocalWriteCore
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general = "General", models = "Local models", behavior = "Behavior", playground = "Try it out"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: "slider.horizontal.3"; case .models: "cpu"; case .behavior: "cursorarrow.rays"; case .playground: "square.and.pencil" }
    }
    var subtitle: String {
        switch self {
        case .general: "A shortcut between a typo and your next thought."
        case .models: "A little intelligence. Entirely on your Mac."
        case .behavior: "Make LocalWrite feel right for the way you write."
        case .playground: "Give your local model a few words to work with."
        }
    }
}

enum LocalWriteStyle {
    // Keep the indigo accent readable in both appearances; the glass adapts itself.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.65, green: 0.64, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.38, green: 0.33, blue: 0.82, alpha: 1)
    })
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var page: SettingsPage = .general
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let accent = LocalWriteStyle.accent

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $page)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            settingsPage(page)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem {
                Button {
                    page = .playground
                } label: {
                    Label("Try it out", systemImage: "square.and.pencil")
                }
                .help("Try a spelling correction without leaving LocalWrite")
                .disabled(page == .playground)
            }
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 620, idealHeight: 680)
        .background { SettingsWindowGlass().ignoresSafeArea() }
        .tint(accent)
        .onChange(of: page) { _, _ in
            if controller.isRecordingShortcut { controller.setShortcut(nil) }
        }
        .onReceive(refreshTimer) { _ in controller.refreshStatus() }
    }

    private func settingsPage(_ item: SettingsPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.rawValue).font(.system(size: 28, weight: .bold))
                Text(item.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 8)
            Form {
                switch item {
                case .general: general
                case .models: models
                case .behavior: behavior
                case .playground: PlaygroundView(controller: controller, preferences: preferences)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 0.72))
    }

    private var general: some View {
        Group {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: controller.isTrusted ? "checkmark.shield.fill" : "hand.raised.fill")
                        .font(.system(size: 25)).foregroundStyle(controller.isTrusted ? accent : .orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(controller.isTrusted ? "Ready to write" : "One permission, then you’re set").font(.headline)
                        Text(controller.isTrusted ? "LocalWrite corrects your focused text field when you press the shortcut." : "Allow Accessibility so LocalWrite can correct the field you’re typing in. Text is read only when you use the shortcut.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !controller.isTrusted {
                            Button("Allow Accessibility…") { controller.editor.requestPermission() }
                                .buttonStyle(.glassProminent).padding(.top, 5)
                        }
                    }
                }.padding(.vertical, 5)
            }
            Section {
                LabeledContent {
                    ShortcutRecorder(controller: controller, preferences: preferences)
                        .frame(width: 156, height: 34)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Correction shortcut")
                        Text("Click to record a combination.").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .contain)
                if let error = controller.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                Picker("Correct", selection: $preferences.scope) {
                    ForEach(CorrectionScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                }.pickerStyle(.menu)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Accuracy", selection: $preferences.correctionMode) {
                        ForEach(CorrectionMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented)
                    Text(preferences.correctionMode.detail)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            } header: {
                Text("Correction")
            } footer: {
                Text("\(preferences.scope.guidance) Press \(preferences.hotKey.display). No manual selection needed.")
            }
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").font(.system(size: 22)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preferences.provider.title).font(.headline)
                        Text(preferences.provider == .apple ? controller.appleStatus.detail : (preferences.ollamaModel.isEmpty ? "Choose a downloaded local model." : preferences.ollamaModel))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Configure") { page = .models }.buttonStyle(.glass)
                }.padding(.vertical, 4)
            } footer: {
                Text("Only spelling changes. Same language, same tone, same you.")
            }
            if controller.status != "Ready when you are" {
                Section {
                    Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var models: some View {
        Group {
            Section {
                Picker("Correction engine", selection: $preferences.provider) {
                    ForEach(ModelProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if preferences.provider == .apple {
                Section("Apple Intelligence") {
                    Label("Built into your Mac", systemImage: "apple.logo").font(.headline)
                    Text("Uses Apple’s on-device language model. No API key, subscription, or Ollama installation needed.")
                        .font(.callout).foregroundStyle(.secondary)
                    Label(controller.appleStatus.detail, systemImage: controller.appleStatus.available ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.callout).foregroundStyle(controller.appleStatus.available ? accent : .secondary)
                    if !controller.appleStatus.available {
                        Button("Open Apple Intelligence Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!)
                        }.buttonStyle(.glass)
                    }
                }
            } else {
                Section {
                    TextField("Server address", text: $preferences.ollamaAddress).textFieldStyle(.roundedBorder)
                        .onChange(of: preferences.ollamaAddress) { _, _ in controller.localModels = []; controller.modelsStatus = "Refresh models for this address." }
                    HStack {
                        Text("Downloaded model")
                        Spacer()
                        Button(controller.refreshingModels ? "Looking…" : "Refresh") { Task { await controller.refreshModels() } }
                            .buttonStyle(.glass).disabled(controller.refreshingModels)
                    }
                    Picker("Model", selection: $preferences.ollamaModel) {
                        Text("Choose a local model").tag("")
                        if !preferences.ollamaModel.isEmpty && !controller.localModels.contains(where: { $0.name == preferences.ollamaModel }) {
                            Text(preferences.ollamaModel).tag(preferences.ollamaModel)
                        }
                        ForEach(controller.localModels) { model in Text(model.name).tag(model.name) }
                    }.pickerStyle(.menu)
                    Text(controller.modelsStatus).font(.caption).foregroundStyle(.secondary)
                    Link("Ollama setup guide", destination: URL(string: "https://docs.ollama.com/quickstart")!)
                } header: {
                    Text("Ollama")
                } footer: {
                    Text("Install Ollama, download a text model, then refresh. Only downloaded models on this Mac are accepted; cloud models and remote servers are disabled.")
                }.task { await controller.refreshModels() }
            }
            Section {
                Label("No text history. No analytics. No cloud fallback.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var behavior: some View {
        Group {
            UpdateSettingsView(updates: controller.updates, isBusy: controller.isBusy)
            Section {
                Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                if let error = controller.loginError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Toggle("Play a sound after correcting", isOn: $preferences.playSound)
                Toggle("Allow clipboard insertion when needed", isOn: $preferences.clipboardFallback)
            } header: {
                Text("Preferences")
            } footer: {
                Text("Current line and list modes use native Copy and Paste for reliable editor support. The clipboard option controls the advanced paragraph and field modes. LocalWrite restores your clipboard afterward; clipboard history tools can observe temporary text.")
            }
            Section {
                TextEditor(text: $preferences.excludedApps).font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10).frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .accessibilityLabel("Excluded application bundle identifiers")
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Bundle identifiers, one per line. Terminal apps are excluded by default.")
            }
            Section {
                Text("If you keep typing or switch fields while the model works, LocalWrite discards the correction. Undo the last applied correction from the menu bar while the field is unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    private let accent = LocalWriteStyle.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LocalWrite").font(.headline)
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(SettingsPage.allCases) { item in
                        Button {
                            selection = item
                            isFocused = true
                        } label: {
                            Label {
                                Text(item.rawValue).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: item.symbol).foregroundStyle(accent)
                            }
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(selection == item ? .isSelected : [])
                        .anchorPreference(key: SidebarSelectionBounds.self, value: .bounds) {
                            selection == item ? $0 : nil
                        }
                    }
                }
                .backgroundPreferenceValue(SidebarSelectionBounds.self) { anchor in
                    GeometryReader { geometry in
                        if let anchor {
                            let bounds = geometry[anchor]
                            // Move one glass surface instead of transitioning effects between list cells.
                            Color.clear
                                .frame(width: bounds.width, height: bounds.height)
                                .glassEffect(.regular.tint(accent.opacity(0.22)).interactive(),
                                             in: .rect(cornerRadius: 10))
                                .position(x: bounds.midX, y: bounds.midY)
                                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .focusable(interactions: .edit)
                .focusEffectDisabled()
                .focused($isFocused)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
            }
            VStack(alignment: .leading, spacing: 7) {
                Label("On-device", systemImage: "lock.shield").font(.caption)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    private func moveSelection(by offset: Int) {
        let pages = SettingsPage.allCases
        guard let index = pages.firstIndex(of: selection), pages.indices.contains(index + offset) else { return }
        selection = pages[index + offset]
        isFocused = true
    }
}

private struct SidebarSelectionBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct SettingsWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 26
        return glass
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) { }
}

private struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController
    let isBusy: Bool

    var body: some View {
        Section {
            LabeledContent {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .buttonStyle(.glass).disabled(!updates.canCheckForUpdates || isBusy)
            } label: {
                Text("Version \(updates.version)")
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            ))
        } header: {
            Text("App updates")
        } footer: {
            Text(updates.status)
        }
    }
}

private struct PlaygroundView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences
    @State private var text = "I definately recieved your mesage. I’ll get back to you tomorow."
    @State private var result: String?
    @State private var message: String?
    @State private var working = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Group {
            Section {
                TextEditor(text: $text).font(.system(size: 15)).scrollContentBackground(.hidden)
                    .padding(12).frame(height: 160)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                    .accessibilityLabel("Spelling test text")
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(working ? "Correcting…" : "Check spelling") {
                            let input = text
                            let config = preferences.configuration
                            result = nil; message = nil; working = true
                            task = Task {
                                defer { working = false }
                                do {
                                    let corrected = try await CorrectionEngine.correct(input, configuration: config)
                                    try Task.checkCancellation()
                                    result = corrected
                                    message = corrected == input ? "Spelling already looks good." : "Only spelling. Still your words."
                                } catch is CancellationError { }
                                catch { message = error.localizedDescription }
                            }
                        }.buttonStyle(.glassProminent).disabled(working || text.isEmpty)
                        if working {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { task?.cancel() }.buttonStyle(.glass)
                        }
                        Spacer()
                    }
                }.padding(.vertical, 4)
            } header: {
                HStack { Text("Your text"); Spacer(); Text(preferences.provider.title).foregroundStyle(.secondary) }
            }
            if let result {
                Section {
                    Text(result).font(.system(size: 15)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                } header: {
                    Label("Corrected", systemImage: "checkmark.circle").foregroundStyle(LocalWriteStyle.accent)
                }
            }
            if let message {
                Section { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section {
                Text("To test the global shortcut, click in the text above, leave the cursor in place, and press \(preferences.hotKey.display). You’ll need Accessibility enabled.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.onDisappear { task?.cancel() }
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences
    @State private var recording = ShortcutRecordingSession()

    var body: some View {
        Button {
            recording.begin(controller: controller)
        } label: {
            Text(controller.isRecordingShortcut ? "Press shortcut…" : preferences.hotKey.display)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.glass)
        .disabled(controller.isBusy)
        .accessibilityLabel("Correction shortcut: \(controller.isRecordingShortcut ? "Press shortcut" : preferences.hotKey.display)")
        .help("Click to record a shortcut. Press Escape to cancel.")
        .onChange(of: controller.isRecordingShortcut) { _, isRecording in
            if !isRecording { recording.stop() }
        }
        .onDisappear {
            if controller.isRecordingShortcut { controller.setShortcut(nil) }
            recording.stop()
        }
    }
}

@MainActor
private final class ShortcutRecordingSession {
    private weak var controller: AppController?
    private var monitor: Any?
    private var resignObserver: Any?

    func begin(controller: AppController) {
        guard !controller.isBusy else { return }
        if controller.isRecordingShortcut { controller.setShortcut(nil); stop(); return }
        self.controller = controller
        controller.beginRecording()
        NSApp.keyWindow?.makeFirstResponder(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let controller = self.controller, controller.isRecordingShortcut else { return event }
            if event.keyCode == 53 { controller.setShortcut(nil); self.stop(); return nil }
            guard let key = HotKey.from(event) else { NSSound.beep(); return nil }
            controller.setShortcut(key)
            self.stop()
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.controller?.isRecordingShortcut == true else { return }
                self.controller?.setShortcut(nil)
                self.stop()
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
