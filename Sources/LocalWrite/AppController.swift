import AppKit
import Combine
import LocalWriteCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    let preferences = Preferences()
    let editor = AccessibilityEditor()
    let hotKeys = HotKeyManager()
    let hud = CorrectionHUD()
    let updates = UpdateController()
    @Published var isBusy = false
    @Published var isTrusted = false
    @Published var appleStatus = CorrectionEngine.appleStatus
    @Published var status = "Ready when you are"
    @Published var shortcutError: String?
    @Published var isRecordingShortcut = false
    @Published var localModels: [OllamaModel] = []
    @Published var modelsStatus = "Refresh to find downloaded models."
    @Published var refreshingModels = false
    @Published var lastCorrection: AppliedCorrection?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    var showSettings: (() -> Void)?
    var onStateChange: (() -> Void)?
    private var correctionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init() {
        updates.correctionIsRunning = { [weak self] in self?.isBusy == true }
        refreshStatus()
        hotKeys.onTrigger = { [weak self] in self?.correctFocusedText() }
        do { try hotKeys.register(preferences.hotKey) }
        catch { shortcutError = error.localizedDescription }
    }

    func refreshStatus() {
        isTrusted = editor.isTrusted
        appleStatus = CorrectionEngine.appleStatus
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func correctFocusedText() {
        guard !isBusy, !isRecordingShortcut else { return }
        refreshStatus()
        isBusy = true
        onStateChange?()
        let configuration = preferences.configuration
        let scope = preferences.scope
        let exclusions = preferences.excludedBundleIDs
        let clipboardFallback = preferences.clipboardFallback
        correctionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                editor.finishOperation()
                timeoutTask?.cancel()
                isBusy = false
                correctionTask = nil
                onStateChange?()
                updates.correctionDidFinish()
            }
            do {
                let snapshot = try await editor.capture(scope: scope, excludedApps: exclusions)
                status = "Correcting in \(snapshot.appName)…"
                onStateChange?()
                hud.show(status, symbol: "sparkle", persistent: true)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard !Task.isCancelled else { return }
                    self?.cancelCorrection(message: "The model took too long. Try a shorter passage.")
                }
                let corrected = try await CorrectionEngine.correct(snapshot.target.text, configuration: configuration)
                try Task.checkCancellation()
                if corrected == snapshot.target.text {
                    finish("Spelling looks good", symbol: "checkmark.circle")
                } else {
                    lastCorrection = try await editor.apply(corrected, to: snapshot, clipboardFallback: clipboardFallback)
                    finish("Spelling corrected", symbol: "checkmark.circle.fill")
                    if preferences.playSound { NSSound(named: "Pop")?.play() }
                }
            } catch is CancellationError {
                // Cancel action already explains what happened.
            } catch {
                finish(error.localizedDescription, symbol: "exclamationmark.circle")
                refreshStatus()
                if !isTrusted { showSettings?() }
            }
        }
    }

    func cancelCorrection(message: String = "Correction cancelled") {
        correctionTask?.cancel()
        timeoutTask?.cancel()
        // Stay busy until inference acknowledges cancellation, preventing overlapping writes.
        finish(message, symbol: "xmark.circle")
    }

    func undoLastCorrection() {
        guard !isBusy, let previous = lastCorrection else { return }
        isBusy = true
        onStateChange?()
        Task {
            defer { editor.finishOperation(); isBusy = false; onStateChange?(); updates.correctionDidFinish() }
            do {
                try await editor.undo(previous, clipboardFallback: preferences.clipboardFallback)
                lastCorrection = nil
                finish("Last correction undone", symbol: "arrow.uturn.backward")
            } catch { finish(error.localizedDescription, symbol: "exclamationmark.circle") }
        }
    }

    func beginRecording() {
        guard !isBusy else { return }
        isRecordingShortcut = true
        shortcutError = nil
        hotKeys.suspend()
    }

    func setShortcut(_ shortcut: HotKey?) {
        do {
            try hotKeys.register(shortcut ?? preferences.hotKey)
            if let shortcut { preferences.hotKey = shortcut }
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
            try? hotKeys.register(preferences.hotKey)
        }
        isRecordingShortcut = false
        onStateChange?()
    }

    func refreshModels() async {
        guard !refreshingModels else { return }
        refreshingModels = true
        defer { refreshingModels = false }
        do {
            localModels = try await OllamaClient(address: preferences.ollamaAddress).models()
            modelsStatus = localModels.isEmpty ? "No local models found. Download a model in Ollama first." : "\(localModels.count) downloaded local model\(localModels.count == 1 ? "" : "s")"
            if !localModels.contains(where: { $0.name == preferences.ollamaModel }) {
                preferences.ollamaModel = localModels.first?.name ?? ""
            }
        } catch {
            localModels = []
            modelsStatus = error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow LocalWrite in System Settings → General → Login Items." : nil
        } catch { loginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func finish(_ message: String, symbol: String) {
        status = message
        hud.show(message, symbol: symbol)
        onStateChange?()
    }
}

@MainActor
private final class PassiveHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CorrectionHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, symbol: String, persistent: Bool = false) {
        hideTask?.cancel()
        if panel == nil {
            let panel = PassiveHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 84),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(LocalWriteStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LocalWrite").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(message).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18).frame(width: 400, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .accessibilityHidden(true)
        )
        let size = panel.contentView!.fittingSize
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - 200, y: frame.maxY - size.height - 24, width: 400, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        if !persistent {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(message.count > 70 ? 7 : 3))
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        }
    }
}
