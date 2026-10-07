import AppKit
@preconcurrency import ApplicationServices
import Carbon
import LocalWriteCore

struct EditorSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let target: TextTarget
    var lineActivity: UserActivityStamp? = nil
    var listActivity: UInt64? = nil
}

struct UserActivityStamp: Equatable {
    let keys: UInt32
    let clicks: UInt32
    let rightClicks: UInt32
    static func current() -> Self {
        .init(keys: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown),
              clicks: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown),
              rightClicks: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown))
    }
}

struct AppliedCorrection {
    let before: EditorSnapshot
    let corrected: String
    let fullTextAfter: String
}

@MainActor
final class AccessibilityEditor {
    private static let editingEventTag: Int64 = 0x4C5752495445
    private var listInputGeneration: UInt64 = 0
    private var globalInputMonitor: Any?
    private var localInputMonitor: Any?
    var isTrusted: Bool { AXIsProcessTrusted() }

    private func startListInputTracking() throws {
        finishOperation()
        listInputGeneration = 0
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown]
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.observeListInput(event) }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.observeListInput(event) }
            return event
        }
        guard globalInputMonitor != nil, localInputMonitor != nil else {
            finishOperation()
            throw fail("macOS couldn’t watch for input during correction. Try the shortcut again.")
        }
    }

    private func observeListInput(_ event: NSEvent) {
        // Count input without retaining keys or text. OS event counters include
        // posted navigation keys, so exclude our explicitly tagged events.
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.editingEventTag else { return }
        listInputGeneration &+= 1
    }

    func finishOperation() {
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        globalInputMonitor = nil
        localInputMonitor = nil
    }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func capture(scope: CorrectionScope, excludedApps: Set<String>) async throws -> EditorSnapshot {
        guard isTrusted else { throw fail("Allow LocalWrite in System Settings → Privacy & Security → Accessibility first.") }
        guard !IsSecureEventInputEnabled() else { throw fail("Secure keyboard input is active. Focus a regular text field and try again.") }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw fail("Click inside a text field first.") }
        guard !excludedApps.contains(app.bundleIdentifier ?? "") else { throw fail("LocalWrite is disabled for this app. You can change excluded apps in Settings.") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.5)
        // Electron apps (including Obsidian, Slack and VS Code) do not have
        // "Electron" in their bundle ID. Ask every app to expose its accessibility
        // tree; native apps simply return attributeUnsupported for these hints.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var resolved: AXUIElement?
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(120 * attempt)) }
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw fail("The focused app changed. Try the shortcut again.")
            }
            if let element = focusedElement(pid: app.processIdentifier) { resolved = element; break }
        }
        guard let element = resolved else {
            if !isTrusted { throw fail("macOS rejected this build’s Accessibility permission. Remove the old LocalWrite entry, then add the installed app in Applications.") }
            throw fail("Couldn’t find the focused editor in \(app.localizedName ?? "this app"). Click inside its text and retry. If this started after an update, remove and re-add LocalWrite in Accessibility.")
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == app.processIdentifier else { throw fail("The focused app changed. Try the shortcut again.") }
        guard isEditable(element), !isSecure(element) else {
            throw fail("Focus an editable text field. Password fields and non-text controls are skipped.")
        }
        if scope == .line {
            // The editor itself decides the start of its current line. This is
            // intentionally independent of AXSelectedTextRange, which CodeMirror
            // often exposes as stale or in a different coordinate space.
            let prefix = try await readLinePrefix(pid: pid)
            let target = try TextTarget(fullText: prefix, selection: NSRange(location: prefix.utf16.count, length: 0), scope: .field)
            return .init(element: element, pid: pid, appName: app.localizedName ?? "App", target: target,
                         lineActivity: .current())
        }
        if scope == .list {
            try startListInputTracking()
            let activity = listInputGeneration
            let document = try await readDocumentAtCursor(pid: pid)
            guard activity == listInputGeneration else {
                throw fail("You typed or moved the cursor while reading the list. Try the shortcut again.")
            }
            return .init(element: element, pid: pid, appName: app.localizedName ?? "App",
                         target: try TextTarget(fullText: document.text, selection: document.caret, scope: .list),
                         listActivity: activity)
        }
        guard let text = text(element), let selection = selection(element) else {
            throw fail("This editor doesn’t expose its text and cursor position. LocalWrite can’t safely correct it.")
        }
        guard text.utf16.count <= 1_000_000 else {
            throw fail("This editor doesn’t support safe text replacement.")
        }
        return .init(element: element, pid: pid, appName: app.localizedName ?? "App",
                     target: try TextTarget(fullText: text, selection: selection, scope: scope))
    }

    func apply(_ corrected: String, to snapshot: EditorSnapshot, clipboardFallback: Bool) async throws -> AppliedCorrection {
        try Task.checkCancellation()
        if let activity = snapshot.listActivity {
            guard activity == listInputGeneration, isFocused(snapshot) else {
                throw fail("You typed or changed focus while correcting. Try the shortcut again.")
            }
            try await replaceList(corrected, snapshot: snapshot, finalSelection: snapshot.target.caret(after: corrected))
            return AppliedCorrection(before: snapshot, corrected: corrected, fullTextAfter: snapshot.target.replacing(with: corrected))
        }
        if let activity = snapshot.lineActivity {
            guard activity == UserActivityStamp.current(), isFocused(snapshot) else {
                throw fail("You typed or changed focus while correcting. Try the shortcut again.")
            }
            try await replaceLinePrefix(expected: snapshot.target.text, corrected: corrected, snapshot: snapshot)
            return AppliedCorrection(before: snapshot, corrected: corrected, fullTextAfter: text(snapshot.element) ?? corrected)
        }
        try validate(snapshot, expectedText: snapshot.target.fullText, expectedSelection: snapshot.target.selection)
        let change = TextReplacement.minimal(original: snapshot.target.text, corrected: corrected, offset: snapshot.target.range.location)
        try await replace(snapshot: snapshot, range: change.range, expectedText: snapshot.target.fullText,
                          replacement: change.text, finalSelection: snapshot.target.caret(after: corrected),
                          clipboardFallback: clipboardFallback)
        return AppliedCorrection(before: snapshot, corrected: corrected, fullTextAfter: snapshot.target.replacing(with: corrected))
    }

    func undo(_ correction: AppliedCorrection, clipboardFallback: Bool) async throws {
        let snapshot = correction.before
        guard let app = NSRunningApplication(processIdentifier: snapshot.pid) else { throw fail("The original app has closed.") }
        app.activate()
        try await Task.sleep(for: .milliseconds(180))
        if snapshot.listActivity != nil {
            guard isFocused(snapshot) else { throw fail("The original field is no longer focused.") }
            try startListInputTracking()
            let activity = listInputGeneration
            let document = try await readDocumentAtCursor(pid: snapshot.pid)
            guard document.text == correction.fullTextAfter, activity == listInputGeneration else {
                throw fail("The original field has changed. Undo was skipped to preserve your newer writing.")
            }
            let current = EditorSnapshot(element: snapshot.element, pid: snapshot.pid, appName: snapshot.appName,
                                         target: try TextTarget(fullText: document.text, selection: document.caret, scope: .list),
                                         listActivity: activity)
            guard current.target.text == correction.corrected else {
                throw fail("The original list has changed. Undo was skipped to preserve your newer writing.")
            }
            try await replaceList(snapshot.target.text, snapshot: current, finalSelection: snapshot.target.selection)
            return
        }
        if snapshot.lineActivity != nil {
            guard isFocused(snapshot), text(snapshot.element) == correction.fullTextAfter else {
                throw fail("The original field has changed. Undo was skipped to preserve your newer writing.")
            }
            try await replaceLinePrefix(expected: correction.corrected, corrected: snapshot.target.text, snapshot: snapshot)
            return
        }
        try validate(snapshot, expectedText: correction.fullTextAfter, expectedSelection: nil)
        let change = TextReplacement.minimal(original: correction.corrected, corrected: snapshot.target.text, offset: snapshot.target.range.location)
        try await replace(snapshot: snapshot, range: change.range, expectedText: correction.fullTextAfter,
                          replacement: change.text, finalSelection: snapshot.target.selection,
                          clipboardFallback: clipboardFallback)
    }

    private func replace(snapshot: EditorSnapshot, range: NSRange, expectedText: String, replacement: String,
                         finalSelection: NSRange, clipboardFallback: Bool) async throws {
        let element = snapshot.element
        let oldSelection = selection(element)
        let expectedAfter = (expectedText as NSString).replacingCharacters(in: range, with: replacement)
        let requestedSelection = setSelection(range, element)
        guard requestedSelection || clipboardFallback else { throw fail("This editor needs clipboard insertion. Enable it in Settings → Behavior.") }
        do {
            // Electron and WebKit acknowledge AXSelectedTextRange before their
            // renderer has applied it. A synchronous read can still return the
            // original caret, which must not be mistaken for user movement.
            for _ in 0..<(requestedSelection ? 20 : 0) {
                if selection(element) == range { break }
                try validate(snapshot, expectedText: expectedText, expectedSelection: nil)
                try await Task.sleep(for: .milliseconds(25))
            }
            if clipboardFallback {
                try validate(snapshot, expectedText: expectedText, expectedSelection: nil)
                try await paste(replacement, snapshot: snapshot, range: range, expectedText: expectedText, originalSelection: oldSelection)
            } else {
                guard selection(element) == range else {
                    throw fail("This editor needs keyboard insertion. Enable clipboard insertion in Settings → Behavior.")
                }
                try validate(snapshot, expectedText: expectedText, expectedSelection: range)
                guard isSettable(element, kAXSelectedTextAttribute),
                      AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
                    throw fail("This editor needs clipboard insertion. Enable it in Settings → Behavior.")
                }
            }
            for _ in 0..<20 {
                if text(element) == expectedAfter { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard text(element) == expectedAfter else {
                throw fail("The editor didn’t confirm the replacement. Check your text before trying again.")
            }
            // Do not move the cursor if the user already moved it after insertion.
            let insertionEnd = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            if isFocused(snapshot), let current = selection(element), current == insertionEnd || current == range {
                _ = setSelection(finalSelection, element)
                if clipboardFallback, finalSelection.length == 0 {
                    for _ in 0..<8 {
                        if selection(element) == finalSelection { break }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    if isFocused(snapshot), text(element) == expectedAfter, selection(element) == insertionEnd {
                        let start = min(insertionEnd.location, finalSelection.location)
                        let distance = abs(insertionEnd.location - finalSelection.location)
                        let steps = (expectedAfter as NSString).substring(with: NSRange(location: start, length: distance)).count
                        let key = finalSelection.location >= insertionEnd.location ? kVK_RightArrow : kVK_LeftArrow
                        for index in 0..<steps {
                            try postKey(UInt16(key), snapshot: snapshot)
                            if index % 16 == 15 { try await Task.sleep(for: .milliseconds(8)) }
                        }
                    }
                }
            }
        } catch {
            if text(element) == expectedText, isFocused(snapshot), selection(element) == range, let oldSelection {
                _ = setSelection(oldSelection, element)
            }
            throw error
        }
    }

    private func paste(_ replacement: String, snapshot: EditorSnapshot, range: NSRange,
                       expectedText: String, originalSelection: NSRange?) async throws {
        let clipboard = NSPasteboard.general
        // Materialize all types before replacing the pasteboard, including non-text content.
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        var ourChange = clipboard.changeCount
        defer {
            // A clipboard copied by the user during correction always wins.
            if clipboard.changeCount == ourChange {
                clipboard.clearContents()
                let items = saved.map { representations in
                    let item = NSPasteboardItem()
                    for (type, data) in representations { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { clipboard.writeObjects(items) }
            }
        }
        let originalFragment = (expectedText as NSString).substring(with: range)
        if selection(snapshot.element) != range {
            guard let originalSelection, selection(snapshot.element) == originalSelection else {
                throw fail("The editor didn’t expose a stable selection. Your text was left unchanged.")
            }
            try await selectUsingKeyboard(range, from: originalSelection, text: expectedText, snapshot: snapshot)
        }
        try validate(snapshot, expectedText: expectedText, expectedSelection: nil)
        // A real Copy verifies what Chromium/CodeMirror actually selected, even
        // when its AXSelectedTextRange cache lags behind the visible selection.
        if range.length > 0 {
            clipboard.clearContents()
            let beforeCopy = clipboard.changeCount
            ourChange = beforeCopy
            try postKey(8, flags: .maskCommand, snapshot: snapshot)
            for _ in 0..<30 {
                if clipboard.changeCount != beforeCopy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard clipboard.changeCount != beforeCopy, clipboard.string(forType: .string) == originalFragment else {
                throw fail("The editor selected different text than expected. Nothing was replaced.")
            }
            ourChange = clipboard.changeCount
        } else {
            // A missing letter is an insertion, so there is nothing to Copy.
            guard selection(snapshot.element) == range else { throw fail("The editor didn’t confirm the insertion point.") }
        }
        try validate(snapshot, expectedText: expectedText, expectedSelection: nil)
        clipboard.clearContents()
        clipboard.setString(replacement, forType: .string)
        ourChange = clipboard.changeCount
        try postKey(9, flags: .maskCommand, snapshot: snapshot)
        // Let the target app consume the pasteboard before restoring its prior contents.
        try await Task.sleep(for: .milliseconds(350))
    }

    private func selectUsingKeyboard(_ range: NSRange, from current: NSRange, text: String, snapshot: EditorSnapshot) async throws {
        if range == current { return }
        if range.location == 0, range.length == (text as NSString).length {
            try postKey(UInt16(kVK_ANSI_A), flags: .maskCommand, snapshot: snapshot)
        } else {
            let value = text as NSString
            if current.length > 0 { try postKey(UInt16(kVK_LeftArrow), snapshot: snapshot) }
            let start = min(range.location, current.location)
            let distance = abs(current.location - range.location)
            let movements = value.substring(with: NSRange(location: start, length: distance)).count
            let direction = current.location >= range.location ? kVK_LeftArrow : kVK_RightArrow
            let selected = value.substring(with: range).count
            for index in 0..<movements {
                try postKey(UInt16(direction), snapshot: snapshot)
                if index % 16 == 15 { try await Task.sleep(for: .milliseconds(8)) }
            }
            for index in 0..<selected {
                try postKey(UInt16(kVK_RightArrow), flags: .maskShift, snapshot: snapshot)
                if index % 16 == 15 { try await Task.sleep(for: .milliseconds(8)) }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func postKey(_ code: UInt16, flags: CGEventFlags = [], snapshot: EditorSnapshot) throws {
        try postKey(code, flags: flags, pid: snapshot.pid)
    }

    private func postKey(_ code: UInt16, flags: CGEventFlags = [], pid: pid_t) throws {
        if globalInputMonitor != nil, listInputGeneration != 0 {
            throw fail("You typed or moved the cursor while correcting. Your newer writing was left unchanged.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else {
            throw fail("The focused app changed. Nothing else was replaced.")
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw fail("macOS couldn’t create the editing event.")
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.editingEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.editingEventTag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Select back to the editor's line start, Copy, then collapse right to the
    /// original insertion point. No numeric cursor offsets and no arrow loops.
    private func readLinePrefix(pid: pid_t) async throws -> String {
        let clipboard = ClipboardTransaction()
        defer { clipboard.restore() }
        var selected = false
        try postKey(UInt16(kVK_LeftArrow), flags: [.maskCommand, .maskShift], pid: pid)
        selected = true
        try await Task.sleep(for: .milliseconds(90))
        do {
            let prefix = try await copySelection(pid: pid, clipboard: clipboard)
            try postKey(UInt16(kVK_RightArrow), pid: pid)
            selected = false
            try await Task.sleep(for: .milliseconds(90))
            guard prefix.contains(where: { $0.isLetter }) else {
                throw fail("There are no words before the cursor on this line.")
            }
            return prefix
        } catch {
            // Collapse without editing if the editor couldn't provide a copy.
            if selected { try? postKey(UInt16(kVK_RightArrow), pid: pid) }
            throw error
        }
    }

    private func replaceLinePrefix(expected: String, corrected: String, snapshot: EditorSnapshot) async throws {
        guard isFocused(snapshot) else { throw fail("The editor focus changed. Your text was left unchanged.") }
        let clipboard = ClipboardTransaction()
        defer { clipboard.restore() }
        var selected = false
        do {
            try postKey(UInt16(kVK_LeftArrow), flags: [.maskCommand, .maskShift], pid: snapshot.pid)
            selected = true
            try await Task.sleep(for: .milliseconds(90))
            let current = try await copySelection(pid: snapshot.pid, clipboard: clipboard)
            guard current == expected, isFocused(snapshot) else {
                throw fail("The text before your cursor changed. Your newer writing was left unchanged.")
            }
            clipboard.write(corrected)
            try postKey(UInt16(kVK_ANSI_V), flags: .maskCommand, pid: snapshot.pid)
            selected = false
            try await Task.sleep(for: .milliseconds(180))
            guard isFocused(snapshot) else { return }
            // Verify by copying the actual editor selection, not an AX cache.
            try postKey(UInt16(kVK_LeftArrow), flags: [.maskCommand, .maskShift], pid: snapshot.pid)
            selected = true
            try await Task.sleep(for: .milliseconds(70))
            let applied = try await copySelection(pid: snapshot.pid, clipboard: clipboard)
            try postKey(UInt16(kVK_RightArrow), pid: snapshot.pid)
            selected = false
            try await Task.sleep(for: .milliseconds(70))
            guard applied == corrected else { throw fail("The editor didn’t confirm the paste. Check the current line before retrying.") }
        } catch {
            if selected, isFocused(snapshot) { try? postKey(UInt16(kVK_RightArrow), pid: snapshot.pid) }
            throw error
        }
    }

    /// Copy native document selections rather than trusting CodeMirror's AX
    /// coordinate space. Include one known character in the suffix selection so
    /// Copy is never empty at the document end (some editors copy a whole line
    /// when there is no selection).
    private func readDocumentAtCursor(pid: pid_t) async throws -> (text: String, caret: NSRange) {
        let clipboard = ClipboardTransaction()
        defer { clipboard.restore() }
        var collapse: UInt16?
        var stepBack = false
        do {
            try postKey(UInt16(kVK_UpArrow), flags: [.maskCommand, .maskShift], pid: pid)
            collapse = UInt16(kVK_RightArrow)
            try await Task.sleep(for: .milliseconds(30))
            let prefix = try await copySelection(pid: pid, clipboard: clipboard)
            guard !prefix.isEmpty, prefix.utf16.count <= 1_000_000, let anchor = prefix.last else {
                throw fail("Put the cursor after a word in the list you want corrected.")
            }
            try postKey(UInt16(kVK_RightArrow), pid: pid)
            collapse = nil
            try postKey(UInt16(kVK_LeftArrow), pid: pid)
            stepBack = true
            try postKey(UInt16(kVK_DownArrow), flags: [.maskCommand, .maskShift], pid: pid)
            collapse = UInt16(kVK_LeftArrow)
            try await Task.sleep(for: .milliseconds(30))
            let suffix = try await copySelection(pid: pid, clipboard: clipboard)
            try postKey(UInt16(kVK_LeftArrow), pid: pid)
            collapse = nil
            try postKey(UInt16(kVK_RightArrow), pid: pid)
            stepBack = false
            try await Task.sleep(for: .milliseconds(20))
            guard suffix.first == anchor, prefix.utf16.count + suffix.utf16.count <= 1_000_001 else {
                throw fail("This editor didn’t provide consistent list text. Put the cursor after a word in a list point and retry.")
            }
            return (prefix + suffix.dropFirst(), NSRange(location: prefix.utf16.count, length: 0))
        } catch {
            if let collapse { try? postKey(collapse, pid: pid) }
            if stepBack { try? postKey(UInt16(kVK_RightArrow), pid: pid) }
            throw error
        }
    }

    private func moveCharacters(_ count: Int, key: UInt16, flags: CGEventFlags = [], snapshot: EditorSnapshot) async throws {
        for index in 0..<count {
            try Task.checkCancellation()
            if let activity = snapshot.listActivity, activity != listInputGeneration {
                throw fail("You typed or moved the cursor while correcting. Your newer writing was left unchanged.")
            }
            try postKey(key, flags: flags, snapshot: snapshot)
            if index % 16 == 15 { try await Task.sleep(for: .milliseconds(8)) }
        }
    }

    private func replaceList(_ corrected: String, snapshot: EditorSnapshot, finalSelection: NSRange) async throws {
        let clipboard = ClipboardTransaction()
        defer { clipboard.restore() }
        let target = snapshot.target
        let beforeCursor = (target.fullText as NSString).substring(with:
            NSRange(location: target.range.location, length: target.selection.location - target.range.location)).count
        let afterCursor = target.text.count - beforeCursor
        let entireField = target.range.location == 0 && target.range.length == target.fullText.utf16.count
        var selected = false
        var pasted = false
        do {
            // Select from the nearest edge. At the usual end-of-list caret,
            // this avoids traversing the entire list before selecting it.
            if entireField {
                try postKey(UInt16(kVK_ANSI_A), flags: .maskCommand, snapshot: snapshot)
            } else if beforeCursor <= afterCursor {
                try await moveCharacters(beforeCursor, key: UInt16(kVK_LeftArrow), snapshot: snapshot)
                try await moveCharacters(target.text.count, key: UInt16(kVK_RightArrow), flags: .maskShift, snapshot: snapshot)
            } else {
                try await moveCharacters(afterCursor, key: UInt16(kVK_RightArrow), snapshot: snapshot)
                try await moveCharacters(target.text.count, key: UInt16(kVK_LeftArrow), flags: .maskShift, snapshot: snapshot)
            }
            selected = true
            try await Task.sleep(for: .milliseconds(30))
            let actual = try await copySelection(pid: snapshot.pid, clipboard: clipboard)
            guard actual == target.text, isFocused(snapshot), snapshot.listActivity == listInputGeneration else {
                throw fail("The list changed or the editor selected different text. Nothing was replaced.")
            }
            try Task.checkCancellation()
            clipboard.write(corrected)
            try postKey(UInt16(kVK_ANSI_V), flags: .maskCommand, snapshot: snapshot)
            pasted = true
            selected = false
            try await Task.sleep(for: .milliseconds(180))
            guard isFocused(snapshot), snapshot.listActivity == listInputGeneration else { return }
            if entireField {
                try postKey(UInt16(kVK_ANSI_A), flags: .maskCommand, snapshot: snapshot)
            } else {
                try await moveCharacters(corrected.count, key: UInt16(kVK_LeftArrow), flags: .maskShift, snapshot: snapshot)
            }
            selected = true
            try await Task.sleep(for: .milliseconds(30))
            let applied = try await copySelection(pid: snapshot.pid, clipboard: clipboard)
            guard applied == corrected else {
                throw fail("The editor didn’t confirm the list paste. Check the list before retrying.")
            }
            let relative = finalSelection.location - target.range.location
            let steps = (corrected as NSString).substring(to: max(0, min(relative, corrected.utf16.count))).count
            let remaining = corrected.count - steps
            if steps <= remaining {
                try postKey(UInt16(kVK_LeftArrow), snapshot: snapshot)
                selected = false
                try await moveCharacters(steps, key: UInt16(kVK_RightArrow), snapshot: snapshot)
            } else {
                try postKey(UInt16(kVK_RightArrow), snapshot: snapshot)
                selected = false
                try await moveCharacters(remaining, key: UInt16(kVK_LeftArrow), snapshot: snapshot)
            }
        } catch {
            if selected, isFocused(snapshot), snapshot.listActivity == listInputGeneration {
                try? postKey(UInt16(kVK_LeftArrow), snapshot: snapshot)
                if !pasted { try? await moveCharacters(beforeCursor, key: UInt16(kVK_RightArrow), snapshot: snapshot) }
            }
            throw error
        }
    }

    private func copySelection(pid: pid_t, clipboard: ClipboardTransaction) async throws -> String {
        let before = clipboard.clear()
        try postKey(UInt16(kVK_ANSI_C), flags: .maskCommand, pid: pid)
        for _ in 0..<30 {
            if NSPasteboard.general.changeCount != before, let value = NSPasteboard.general.string(forType: .string) {
                clipboard.claimCurrent()
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw fail("There is no selected text to copy. Put the cursor after the words you want corrected.")
    }

    private func validate(_ snapshot: EditorSnapshot, expectedText: String, expectedSelection: NSRange?) throws {
        guard !IsSecureEventInputEnabled(), !isSecure(snapshot.element) else {
            throw fail("Secure input became active. Your text was left unchanged.")
        }
        guard isFocused(snapshot) else {
            let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
            throw fail("Editor focus changed during correction (\(snapshot.appName) → \(currentApp)). Try again in the original field.")
        }
        guard let currentText = text(snapshot.element) else {
            throw fail("The editor temporarily stopped exposing its text. Try the shortcut again.")
        }
        guard currentText == expectedText else {
            throw fail("The text changed during correction. Your newer text was left unchanged.")
        }
        if let expectedSelection {
            guard let currentSelection = selection(snapshot.element) else {
                throw fail("The editor stopped exposing the cursor position. Your text was left unchanged.")
            }
            guard currentSelection == expectedSelection else {
                throw fail("The text selection changed during correction. Try the shortcut again.")
            }
        }
    }

    private func isFocused(_ snapshot: EditorSnapshot) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              let focused = focusedElement(pid: snapshot.pid) else { return false }
        return CFEqual(focused, snapshot.element)
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        // App-level focus is more reliable than system-wide focus in Electron
        // and on recent macOS versions. Normalize nested editor elements.
        for owner in [app, AXUIElementCreateSystemWide()] {
            if let focused = elementAttribute(owner, kAXFocusedUIElementAttribute) {
                var actualPID: pid_t = 0
                AXUIElementGetPid(focused, &actualPID)
                if actualPID == pid, let editor = editableAncestorOrDescendant(focused) { return editor }
            }
        }
        // Some apps expose focus only below their focused window. Traverse a
        // bounded tree looking for AXFocused; never choose an arbitrary text box.
        if let window = elementAttribute(app, kAXFocusedWindowAttribute) {
            var queue = [window]
            var visited = 0
            while !queue.isEmpty, visited < 250 {
                let item = queue.removeFirst()
                visited += 1
                if (attribute(item, kAXFocusedAttribute) as? Bool) == true,
                   let editor = editableAncestorOrDescendant(item) { return editor }
                queue.append(contentsOf: children(item))
            }
        }
        return nil
    }

    private func editableAncestorOrDescendant(_ focused: AXUIElement) -> AXUIElement? {
        if isSecure(focused) { return nil }
        if isEditable(focused) { return focused }
        if let inner = elementAttribute(focused, kAXFocusedUIElementAttribute), isEditable(inner), !isSecure(inner) { return inner }
        // CodeMirror/contenteditable can report an inner text or group node.
        var parent = elementAttribute(focused, kAXParentAttribute)
        for _ in 0..<6 {
            guard let item = parent, !isSecure(item) else { break }
            if isEditable(item) { return item }
            if string(item, kAXRoleAttribute) == kAXWindowRole { break }
            parent = elementAttribute(item, kAXParentAttribute)
        }
        for child in children(focused) {
            if isEditable(child), (attribute(child, kAXFocusedAttribute) as? Bool) == true, !isSecure(child) { return child }
        }
        return nil
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) { return true }
        return (attribute(element, "AXEditable") as? Bool) == true && isSettable(element, kAXSelectedTextRangeAttribute)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let node = current else { break }
            if string(node, kAXSubroleAttribute) == kAXSecureTextFieldSubrole || (attribute(node, "AXProtectedContent") as? Bool) == true { return true }
            if let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                current = (parent as! AXUIElement)
            } else { break }
        }
        return false
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    private func text(_ element: AXUIElement) -> String? {
        if let value = string(element, kAXValueAttribute) { return value }
        if let value = attribute(element, kAXValueAttribute) as? NSAttributedString { return value.string }
        guard let length = attribute(element, kAXNumberOfCharactersAttribute) as? Int, (0...1_000_000).contains(length) else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &result) == .success else { return nil }
        return result as? String
    }

    private func selection(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    @discardableResult private func setSelection(_ range: NSRange, _ element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private func fail(_ message: String) -> CorrectionError { .message(message) }
}

@MainActor
private final class ClipboardTransaction {
    private let saved: [[NSPasteboard.PasteboardType: Data]]
    private var ownChange: Int
    init() {
        saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        ownChange = NSPasteboard.general.changeCount
    }
    @discardableResult func clear() -> Int {
        NSPasteboard.general.clearContents()
        ownChange = NSPasteboard.general.changeCount
        return ownChange
    }
    func claimCurrent() { ownChange = NSPasteboard.general.changeCount }
    func write(_ text: String) {
        clear()
        NSPasteboard.general.setString(text, forType: .string)
        claimCurrent()
    }
    func restore() {
        guard NSPasteboard.general.changeCount == ownChange else { return }
        NSPasteboard.general.clearContents()
        let items = saved.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            return item
        }
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }
}
