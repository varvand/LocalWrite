import AppKit
import Carbon
import Combine
import LocalWriteCore

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let standard = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")

    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    static func from(_ event: NSEvent) -> HotKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let labels: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        guard let label = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty else { return nil }
        return HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var provider: ModelProvider { didSet { defaults.set(provider.rawValue, forKey: "provider") } }
    @Published var scope: CorrectionScope { didSet { defaults.set(scope.rawValue, forKey: "scope") } }
    @Published var ollamaAddress: String { didSet { defaults.set(ollamaAddress, forKey: "ollamaAddress") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    @Published var clipboardFallback: Bool { didSet { defaults.set(clipboardFallback, forKey: "clipboardFallback") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published var hotKey: HotKey { didSet { defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey") } }

    init() {
        defaults.register(defaults: ["clipboardFallback": true, "excludedApps": "com.apple.Terminal\ncom.googlecode.iterm2"])
        provider = ModelProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .apple
        if !defaults.bool(forKey: "cursorPrefixModeV1") {
            defaults.set(CorrectionScope.line.rawValue, forKey: "scope")
            defaults.set(true, forKey: "cursorPrefixModeV1")
        }
        scope = CorrectionScope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .line
        ollamaAddress = defaults.string(forKey: "ollamaAddress") ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? ""
        clipboardFallback = defaults.bool(forKey: "clipboardFallback")
        playSound = defaults.bool(forKey: "playSound")
        excludedApps = defaults.string(forKey: "excludedApps") ?? ""
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? .standard
    }

    var configuration: EngineConfiguration {
        .init(provider: provider, ollamaAddress: ollamaAddress, ollamaModel: ollamaModel)
    }

    var excludedBundleIDs: Set<String> {
        Set(excludedApps.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
    }
}
