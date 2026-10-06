import AppKit
import ApplicationServices
import LocalWriteCore
import SwiftUI

@main
@MainActor
struct LocalWriteApp {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--check-model") {
            Task { @MainActor in
                let status = CorrectionEngine.appleStatus
                print("Apple Intelligence: \(status.detail)")
                print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
                if CommandLine.arguments.contains("--check-model") {
                    do {
                        let arguments = CommandLine.arguments
                        let modelIndex = arguments.firstIndex(of: "--ollama-model")
                        let configuration: EngineConfiguration
                        if let modelIndex {
                            guard arguments.indices.contains(modelIndex + 1), !arguments[modelIndex + 1].hasPrefix("--") else {
                                throw CorrectionError.message("Pass a downloaded model name after --ollama-model.")
                            }
                            configuration = .init(provider: .ollama, ollamaModel: arguments[modelIndex + 1], mode: .rescue)
                        } else {
                            configuration = .init(provider: .apple, mode: .rescue)
                        }
                        let text = "heldlo mxy namea is vincent"
                        print("Testing: \(configuration.provider.title)\(configuration.ollamaModel.isEmpty ? "" : " · " + configuration.ollamaModel)")
                        let started = ContinuousClock.now
                        let result = try await CorrectionEngine.correct(text, configuration: configuration)
                        let elapsed = started.duration(to: .now).components
                        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                        print("Correction time: \(String(format: "%.2f", seconds))s")
                        print("Input: \(text)")
                        print("Output: \(result)")
                        guard result.lowercased() == "hello my name is vincent" else {
                            print("Model smoke test: unexpected output")
                            exit(2)
                        }
                        print("Model smoke test: passed")
                    } catch {
                        print("Model smoke test: \(error.localizedDescription)")
                        exit(1)
                    }
                }
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var controller: AppController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate()
            NSApp.terminate(nil)
            return
        }
        controller = AppController()
        controller.showSettings = { [weak self] in self?.openSettings() }
        controller.onStateChange = { [weak self] in self?.refreshIcon() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        installMainMenu()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--settings") {
            openSettings()
            UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LocalWrite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LocalWrite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu?.addItem(.separator())
        let correct = edit.submenu?.addItem(withTitle: "Correct Spelling with LocalWrite", action: #selector(correctFromMenu), keyEquivalent: "")
        correct?.target = self
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "LocalWrite", action: nil, keyEquivalent: "")
        heading.attributedTitle = NSAttributedString(string: "LocalWrite", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        menu.addItem(heading)
        let state = NSMenuItem(title: controller.isBusy ? "Correcting…" : controller.preferences.provider.title + " · On device", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let instruction = NSMenuItem(title: "Correct spelling  \(controller.preferences.hotKey.display)", action: nil, keyEquivalent: "")
        instruction.isEnabled = false
        menu.addItem(instruction)
        if controller.isBusy {
            let cancel = menu.addItem(withTitle: "Cancel correction", action: #selector(cancelCorrection), keyEquivalent: "")
            cancel.target = self
        }
        let undo = menu.addItem(withTitle: "Undo last correction", action: #selector(undoCorrection), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = controller.lastCorrection != nil && !controller.isBusy
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = controller.updates.canCheckForUpdates && !controller.isBusy
        menu.addItem(withTitle: "Quit LocalWrite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func refreshIcon() {
        let symbol = controller.isBusy ? "ellipsis.circle" : "text.badge.checkmark"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LocalWrite")
        statusItem?.button?.toolTip = "LocalWrite — \(controller.preferences.hotKey.display) to correct spelling"
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 610),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "LocalWrite"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 790, height: 640)
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller, preferences: controller.preferences))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        controller.refreshStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func cancelCorrection() { controller.cancelCorrection() }
    @objc private func undoCorrection() { controller.undoLastCorrection() }
    @objc private func checkForUpdates() { controller.updates.checkForUpdates() }
    @objc private func correctFromMenu() {
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            controller.correctFocusedText()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if controller.isRecordingShortcut { controller.setShortcut(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
