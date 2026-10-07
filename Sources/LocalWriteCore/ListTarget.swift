import Foundation

/// A list at the cursor's indentation level, bounded by parent items or prose.
/// All returned offsets are UTF-16, including original line terminators.
enum ListTarget {
    private struct Line {
        let range: NSRange
        let indent: Int
        let marker: Marker?
        let blank: Bool
        let code: Bool
    }

    private struct Marker {
        let ordered: Bool
    }

    static func range(in text: String, at cursor: Int) throws -> NSRange {
        let lines = parse(text)
        guard let current = lines.lastIndex(where: { $0.range.location <= cursor }),
              !lines[current].code, !lines[current].blank else { throw noList() }
        var item = current
        if lines[item].marker == nil {
            // An indented continuation belongs to its nearest preceding item.
            guard lines[item].indent > 0 else { throw noList() }
            while item > 0 {
                item -= 1
                if let _ = lines[item].marker, lines[item].indent < lines[current].indent { break }
                if !lines[item].blank, lines[item].indent < lines[current].indent { throw noList() }
            }
        }
        guard let marker = lines[item].marker else { throw noList() }
        let indent = lines[item].indent
        func belongs(_ line: Line) -> Bool {
            if line.blank { return true }
            if let other = line.marker {
                return line.indent > indent || (line.indent == indent && other.ordered == marker.ordered)
            }
            return line.indent > indent
        }
        var first = item
        var index = item - 1
        while index >= 0, belongs(lines[index]) {
            if lines[index].marker != nil, lines[index].indent == indent { first = index }
            index -= 1
        }
        var last = item
        index = item + 1
        while index < lines.count, belongs(lines[index]) {
            if !lines[index].blank { last = index }
            index += 1
        }
        return NSRange(location: lines[first].range.location,
                       length: NSMaxRange(lines[last].range) - lines[first].range.location)
    }

    private static func noList() -> CorrectionError {
        .message("Put the cursor after a word in a bulleted, numbered, or task list.")
    }

    private static func parse(_ text: String) -> [Line] {
        let value = text as NSString
        let bullet = try! NSRegularExpression(pattern: #"^[ \t]*(?:([-+*•◦▪‣])|([0-9]{1,9}[.)]))(?:[ \t]+|$)"#)
        let rule = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
        var result: [Line] = []
        var location = 0
        var fence: (Character, Int)?
        while location < value.length {
            var start = 0, end = 0, contentEnd = 0
            value.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                               for: NSRange(location: location, length: 0))
            let content = value.substring(with: NSRange(location: start, length: contentEnd - start))
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let whitespace = content.prefix { $0 == " " || $0 == "\t" }
            let indent = whitespace.reduce(0) { $1 == "\t" ? (($0 / 4) + 1) * 4 : $0 + 1 }
            var code = fence != nil
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix { $0 == character }.count
                if let active = fence {
                    if character == active.0, count >= active.1,
                       trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else if count >= 3 {
                    fence = (character, count)
                    code = true
                }
            }
            let contentRange = NSRange(location: 0, length: content.utf16.count)
            let match = code || rule.firstMatch(in: content, range: contentRange) != nil
                ? nil : bullet.firstMatch(in: content, range: contentRange)
            result.append(.init(range: NSRange(location: start, length: end - start), indent: indent,
                                marker: match.map { .init(ordered: $0.range(at: 2).location != NSNotFound) },
                                blank: trimmed.isEmpty, code: code))
            location = end
        }
        if value.length == 0 || text.last?.isNewline == true {
            result.append(.init(range: NSRange(location: value.length, length: 0), indent: 0,
                                marker: nil, blank: true, code: false))
        }
        return result
    }
}
