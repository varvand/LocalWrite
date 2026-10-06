import AppKit
import LocalWriteCore
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
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

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences
    @State private var page: SettingsPage = .general
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let green = Color(red: 0.16, green: 0.43, blue: 0.34)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.checkmark").font(.system(size: 25, weight: .medium)).foregroundStyle(green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LocalWrite").font(.system(size: 17, weight: .semibold))
                        Text("SPELLING, SIMPLIFIED").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1.1).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 19).padding(.top, 34).padding(.bottom, 34)
                ForEach(SettingsPage.allCases) { item in
                    Button {
                        if controller.isRecordingShortcut { controller.setShortcut(nil) }
                        page = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(page == item ? green.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(page == item ? green : .primary)
                    }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 3)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label("On-device by design", systemImage: "lock.shield").font(.system(size: 11, weight: .medium))
                    Text("Your writing stays with you.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Version \(controller.updates.version) · Made for your Mac").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 6)
                }.padding(20)
            }.frame(width: 205).background(.quaternary.opacity(0.3))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(page.rawValue).font(.system(size: 27, weight: .bold))
                    Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.horizontal, 30).padding(.top, 32).padding(.bottom, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .general: general
                        case .models: models
                        case .behavior: behavior
                        case .playground: PlaygroundView(controller: controller, preferences: preferences)
                        }
                    }.padding(.horizontal, 30).padding(.bottom, 28)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 790, idealWidth: 790, minHeight: 610, idealHeight: 610)
        .tint(green)
        .onReceive(refreshTimer) { _ in controller.refreshStatus() }
    }

    private var general: some View {
        Group {
            card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: controller.isTrusted ? "checkmark.shield.fill" : "hand.raised.fill")
                        .font(.system(size: 22)).foregroundStyle(controller.isTrusted ? green : .orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(controller.isTrusted ? "Ready to write" : "One permission, then you’re set").font(.headline)
                        Text(controller.isTrusted ? "LocalWrite can read and correct your focused text field when you press the shortcut." : "Allow Accessibility so LocalWrite can correct the field you’re typing in. Text is read only when you use the shortcut.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !controller.isTrusted {
                            Button("Allow Accessibility…") { controller.editor.requestPermission() }.buttonStyle(.borderedProminent).padding(.top, 5)
                        }
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Correction shortcut").font(.headline)
                            Text("Click to record your own combination.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShortcutRecorder(controller: controller, preferences: preferences).frame(width: 158, height: 36)
                    }
                    if let error = controller.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                    Divider()
                    Picker("Correct", selection: $preferences.scope) {
                        ForEach(CorrectionScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                    }
                    Text("Put the cursor after what you’ve written and press \(preferences.hotKey.display). Current line mode corrects from the editor’s line start up to the cursor, leaving everything after it untouched. No manual selection needed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Picker("Accuracy", selection: $preferences.correctionMode) {
                        ForEach(CorrectionMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented)
                    Text(preferences.correctionMode.detail)
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").font(.system(size: 22)).foregroundStyle(green)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preferences.provider.title).font(.headline)
                        Text(preferences.provider == .apple ? controller.appleStatus.detail : (preferences.ollamaModel.isEmpty ? "Choose a downloaded local model." : preferences.ollamaModel))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Configure") { page = .models }
                }
            }
            Text("Only spelling changes. Same language, same tone, same you.").font(.system(size: 12)).foregroundStyle(.secondary)
            if controller.status != "Ready when you are" {
                Text(controller.status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var models: some View {
        Group {
            Picker("Correction engine", selection: $preferences.provider) {
                ForEach(ModelProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
            }.pickerStyle(.segmented)
            if preferences.provider == .apple {
                card {
                    VStack(alignment: .leading, spacing: 15) {
                        Label("Built into your Mac", systemImage: "apple.logo").font(.headline)
                        Text("Uses Apple’s on-device language model. No API key, subscription, or Ollama installation needed.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Divider()
                        Label(controller.appleStatus.detail, systemImage: controller.appleStatus.available ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(controller.appleStatus.available ? green : .secondary)
                        if !controller.appleStatus.available {
                            Button("Open Apple Intelligence Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!)
                            }
                        }
                    }
                }
            } else {
                card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connect to Ollama").font(.headline)
                        TextField("Server address", text: $preferences.ollamaAddress).textFieldStyle(.roundedBorder)
                            .onChange(of: preferences.ollamaAddress) { _, _ in controller.localModels = []; controller.modelsStatus = "Refresh models for this address." }
                        HStack {
                            Text("Downloaded model").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button(controller.refreshingModels ? "Looking…" : "Refresh") { Task { await controller.refreshModels() } }.disabled(controller.refreshingModels)
                        }
                        Picker("Model", selection: $preferences.ollamaModel) {
                            Text("Choose a local model").tag("")
                            if !preferences.ollamaModel.isEmpty && !controller.localModels.contains(where: { $0.name == preferences.ollamaModel }) {
                                Text(preferences.ollamaModel).tag(preferences.ollamaModel)
                            }
                            ForEach(controller.localModels) { model in Text(model.name).tag(model.name) }
                        }.labelsHidden()
                        Text(controller.modelsStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider()
                        Text("Install Ollama, download a text model, then refresh. Only downloaded models on this Mac are accepted; cloud models and remote servers are disabled.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Link("Ollama setup guide ↗", destination: URL(string: "https://docs.ollama.com/quickstart")!)
                    }
                }.task { await controller.refreshModels() }
            }
            Label("No text history. No analytics. No cloud fallback.", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var behavior: some View {
        Group {
            UpdateSettingsView(updates: controller.updates, isBusy: controller.isBusy)
            card {
                VStack(alignment: .leading, spacing: 17) {
                    Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                    if let error = controller.loginError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    Toggle("Play a sound after correcting", isOn: $preferences.playSound)
                    Divider()
                    Toggle("Allow clipboard insertion when needed", isOn: $preferences.clipboardFallback)
                    Text("Current line mode uses native Copy and Paste for reliable editor support. This option controls the advanced paragraph and field modes. LocalWrite restores your clipboard afterward; clipboard history tools can observe temporary text.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Excluded apps").font(.headline)
                    Text("Bundle identifiers, one per line. Terminal apps are excluded by default.").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextEditor(text: $preferences.excludedApps).font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(8).frame(height: 88)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("If you keep typing or switch fields while the model works, LocalWrite discards the correction. Undo the last applied correction from the menu bar while the field is unchanged.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
    }
}

private struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App updates").font(.headline)
                Spacer()
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates || isBusy)
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            ))
            Text(updates.status).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
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
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("YOUR TEXT").font(.system(size: 10, weight: .semibold)).tracking(1.1); Spacer(); Text(preferences.provider.title).font(.caption) }.foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 15)).scrollContentBackground(.hidden)
                .padding(12).frame(height: 145).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
                .accessibilityLabel("Spelling test text")
            HStack {
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
                }.buttonStyle(.borderedProminent).disabled(working || text.isEmpty)
                if working { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel() } }
                Spacer()
            }
            if let result {
                VStack(alignment: .leading, spacing: 10) {
                    Label("CORRECTED", systemImage: "checkmark.circle").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Text(result).font(.system(size: 15)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(17).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider().padding(.vertical, 3)
            Text("To test the global shortcut, click in the text above, leave the cursor in place, and press \(preferences.hotKey.display). You’ll need Accessibility enabled.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.onDisappear { task?.cancel() }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    var controller: AppController
    var preferences: Preferences

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.controller = controller
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        button.target = button
        button.action = #selector(RecorderButton.begin)
        return button
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.title = controller.isRecordingShortcut ? "Press shortcut…" : preferences.hotKey.display
        view.setAccessibilityLabel("Correction shortcut: \(view.title)")
        if !controller.isRecordingShortcut { view.stop() }
    }

    @MainActor
    final class RecorderButton: NSButton {
        weak var controller: AppController?
        private var monitor: Any?
        private var resignObserver: Any?

        @objc func begin() {
            guard let controller, !controller.isBusy else { return }
            if controller.isRecordingShortcut { controller.setShortcut(nil); stop(); return }
            controller.beginRecording()
            window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let controller = self.controller, controller.isRecordingShortcut else { return event }
                if event.keyCode == 53 { controller.setShortcut(nil); self.stop(); return nil }
                guard let key = HotKey.from(event) else { NSSound.beep(); return nil }
                controller.setShortcut(key)
                self.stop()
                return nil
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
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

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, controller?.isRecordingShortcut == true { controller?.setShortcut(nil); stop() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
