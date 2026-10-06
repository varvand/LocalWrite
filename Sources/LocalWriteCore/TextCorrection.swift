import Foundation

public enum CorrectionScope: String, Codable, CaseIterable, Sendable {
    case line, paragraph, field
    public var title: String {
        switch self {
        case .line: "Current line before cursor"
        case .paragraph: "Current paragraph"
        case .field: "Entire text field"
        }
    }
}

public enum CorrectionMode: String, Codable, CaseIterable, Sendable {
    case careful, rescue

    public var title: String {
        switch self {
        case .careful: "Careful"
        case .rescue: "Rescue"
        }
    }

    public var detail: String {
        switch self {
        case .careful:
            "One model pass for ordinary typos. Only single-word corrections are accepted."
        case .rescue:
            "One model pass with broader dictionary candidates for heavily mistyped text. Also repairs short split or joined words."
        }
    }
}

public enum CorrectionError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

/// Accessibility uses UTF-16 offsets, not Swift character offsets.
public struct TextTarget: Equatable, Sendable {
    public let fullText: String
    public let selection: NSRange
    public let range: NSRange
    public let text: String

    public init(fullText: String, selection: NSRange, scope: CorrectionScope) throws {
        let value = fullText as NSString
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, selection.location <= value.length,
              selection.length <= value.length - selection.location else {
            throw CorrectionError.message("This editor returned an invalid cursor position.")
        }
        let range: NSRange
        if selection.length > 0 {
            range = selection
        } else if scope == .field {
            range = NSRange(location: 0, length: value.length)
        } else if scope == .line {
            let paragraph = value.paragraphRange(for: selection)
            range = NSRange(location: paragraph.location, length: selection.location - paragraph.location)
        } else {
            range = value.paragraphRange(for: selection)
        }
        let text = value.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionError.message("There’s no text to correct at the cursor.")
        }
        guard text.contains(where: { $0.isLetter }) else {
            throw CorrectionError.message("There are no words in this paragraph. Put the cursor in the paragraph you want to correct.")
        }
        guard text.utf16.count <= 4_000 else {
            throw CorrectionError.message("This passage is too long. Use Current paragraph, or select fewer than 4,000 characters.")
        }
        self.fullText = fullText
        self.selection = selection
        self.range = range
        self.text = text
    }

    public func replacing(with correction: String) -> String {
        (fullText as NSString).replacingCharacters(in: range, with: correction)
    }

    public func caret(after correction: String) -> NSRange {
        // Keep the cursor relative to the unchanged suffix whenever possible.
        let oldEnd = NSMaxRange(range)
        let newLength = (correction as NSString).length
        let offset: Int
        if selection.length > 0 {
            offset = range.location + newLength
        } else if selection.location >= oldEnd {
            offset = selection.location + newLength - range.length
        } else {
            let oldPrefix = (text as NSString).substring(to: selection.location - range.location)
            let oldSuffix = (text as NSString).substring(from: selection.location - range.location)
            if correction.hasSuffix(oldSuffix) {
                offset = range.location + newLength - (oldSuffix as NSString).length
            } else if correction.hasPrefix(oldPrefix) {
                offset = selection.location
            } else {
                offset = range.location + min(selection.location - range.location, newLength)
            }
        }
        return NSRange(location: max(0, offset), length: 0)
    }
}

public enum CorrectionValidation {
    public static func validate(_ output: String, original: String) throws -> String {
        let trimmedInput = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            throw CorrectionError.message("The model returned no text. Your writing was left unchanged.")
        }
        let inputChars = Array(trimmedInput)
        let outputChars = Array(trimmedOutput)
        let limit = max(2, Int(Double(inputChars.count) * 0.30))
        guard abs(inputChars.count - outputChars.count) <= limit,
              editDistance(inputChars, outputChars, limit: limit) <= limit else {
            throw CorrectionError.message("The model changed too much for a spelling correction. Your writing was left unchanged.")
        }
        guard lineBreaks(trimmedInput) == lineBreaks(trimmedOutput),
              protectedTokens(trimmedInput) == protectedTokens(trimmedOutput) else {
            throw CorrectionError.message("The model changed formatting, a number, or a link. Your writing was left unchanged.")
        }
        // Never let a model remove indentation or trailing whitespace/newlines.
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + trimmedOutput + trailing
    }

    private static func lineBreaks(_ text: String) -> [String] {
        text.filter { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.map(String.init)
    }

    private static func protectedTokens(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"https?://[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|\d+(?:[.,:/-]\d+)*|`[^`]*`"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = Array(repeating: limit + 1, count: b.count + 1)
            row[0] = i
            let start = max(1, i - limit)
            let end = min(b.count, i + limit)
            guard start <= end else { return limit + 1 }
            for j in start...end {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if row.min()! > limit { return limit + 1 }
            previous = row
        }
        return previous[b.count]
    }
}

public struct WordEdit: Codable, Sendable, Equatable {
    public let original: String
    public let replacement: String
    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}

public struct TextReplacement: Equatable, Sendable {
    public let range: NSRange
    public let text: String

    public static func minimal(original: String, corrected: String, offset: Int = 0) -> TextReplacement {
        let before = Array(original)
        let after = Array(corrected)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let start = String(before.prefix(prefix)).utf16.count
        let oldMiddle = String(before[prefix..<(before.count - suffix)])
        return .init(range: NSRange(location: offset + start, length: oldMiddle.utf16.count),
                     text: String(after[prefix..<(after.count - suffix)]))
    }
}

/// Compose the final passage locally, so an LLM never needs to reproduce an
/// editor's Markdown, hidden characters, indentation or paragraph separators.
public enum SpellingEdits {
    public static func apply(_ edits: [WordEdit], to text: String, mode: CorrectionMode = .careful) throws -> String {
        guard edits.count <= 100 else { throw CorrectionError.message("The model returned too many edits. Try a shorter paragraph.") }
        let ns = text as NSString
        let wordPattern = #"[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*"#
        let token = try! NSRegularExpression(pattern: "^" + wordPattern + "$")
        let phrase = try! NSRegularExpression(pattern: "^" + wordPattern + "(?:[ \\t]+" + wordPattern + "){0,2}$")
        let protected = try! NSRegularExpression(pattern: #"```[\s\S]*?```|`[^`]*`|https?://[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?<!\w)[#@][\p{L}\p{M}\p{N}_-]+"#)
        let protectedRanges = protected.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var changes: [(NSRange, String)] = []
        var seen: [String: String] = [:]
        for edit in edits {
            if edit.original == edit.replacement { continue }
            let old = edit.original as NSString
            let new = edit.replacement as NSString
            let validPattern = mode == .rescue ? phrase : token
            guard (1...96).contains(old.length), (1...96).contains(new.length),
                  validPattern.firstMatch(in: edit.original, range: NSRange(location: 0, length: old.length)) != nil,
                  validPattern.firstMatch(in: edit.replacement, range: NSRange(location: 0, length: new.length)) != nil else {
                // Ignore commentary and sentence rewrites. Rescue mode permits
                // only a short exact phrase for split/join repairs.
                continue
            }
            let limit = mode == .rescue
                ? max(3, min(10, (edit.original.count * 2) / 3))
                : max(2, min(6, edit.original.count / 2))
            guard CorrectionValidation.editDistance(Array(edit.original), Array(edit.replacement), limit: limit) <= limit else { continue }
            if let prior = seen[edit.original] {
                guard prior == edit.replacement else { throw CorrectionError.message("The model gave conflicting spellings for a word. Your text was left unchanged.") }
                continue
            }
            seen[edit.original] = edit.replacement
            let pattern = #"(?<![\p{L}\p{M}\p{N}_'’\-])"# + NSRegularExpression.escapedPattern(for: edit.original) + #"(?![\p{L}\p{M}\p{N}_'’\-])"#
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                changes.append((match.range, edit.replacement))
            }
        }
        var result = text
        // Prefer a specific phrase edit over overlapping word edits. All offsets
        // refer to the original string, and edits are never cascaded.
        var accepted: [(NSRange, String)] = []
        for change in changes.sorted(by: {
            if $0.0.length != $1.0.length { return $0.0.length > $1.0.length }
            return $0.0.location < $1.0.location
        }) where !accepted.contains(where: { NSIntersectionRange($0.0, change.0).length > 0 }) {
            accepted.append(change)
        }
        for (range, replacement) in accepted.sorted(by: { $0.0.location > $1.0.location }) {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }
}
