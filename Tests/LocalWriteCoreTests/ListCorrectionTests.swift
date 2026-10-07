import Foundation
import Testing
@testable import LocalWriteCore

private func listTarget(_ text: String, after prefix: String) throws -> TextTarget {
    try TextTarget(fullText: text, selection: .init(location: prefix.utf16.count, length: 0), scope: .list)
}

@Test func currentListIncludesEverySiblingFromAnyPoint() throws {
    let list = "- frist point\n- secnod point\n- thidr point"
    let text = "Introduction.\n\n" + list + "\n\nUnrelated mesage."
    for fragment in ["- frist", "- frist point\n- secnod", list] {
        let target = try listTarget(text, after: "Introduction.\n\n" + fragment)
        #expect(target.text == list + "\n")
        let corrected = try SpellingEdits.apply([
            .init(original: "frist", replacement: "first"),
            .init(original: "secnod", replacement: "second"),
            .init(original: "thidr", replacement: "third")
        ], to: target.text, mode: .rescue)
        #expect(target.replacing(with: corrected) == "Introduction.\n\n- first point\n- second point\n- third point\n\nUnrelated mesage.")
    }
}

@Test func nestedSublistExcludesParentsAndOtherSublists() throws {
    let firstParent = "- Parent mesage\n  - frist child\n    - nested mesage\n  - secnod child\n"
    let text = firstParent + "- Other parent\n  - unrelated mesage"
    let target = try listTarget(text, after: "- Parent mesage\n  - frist child\n    - nested mesage\n  - secnod")
    #expect(target.text == "  - frist child\n    - nested mesage\n  - secnod child\n")
    let inner = try listTarget(text, after: "- Parent mesage\n  - frist child\n    - nested")
    #expect(inner.text == "    - nested mesage\n")
    let parent = try listTarget(text, after: "- Parent")
    #expect(parent.text == text)
}

@Test func numberedCheckboxAndUnicodeListsKeepTheirMarkers() throws {
    for list in ["1. frist\n2. secnod", "1) frist\n2) secnod", "- [ ] frist\n- [x] secnod",
                 "* frist\n* secnod", "+ frist\n+ secnod", "• frist\n• secnod", "▪ frist\n▪ secnod"] {
        let target = try listTarget(list, after: list)
        #expect(target.text == list)
        #expect(try SpellingEdits.apply([.init(original: "frist", replacement: "first"),
                                        .init(original: "secnod", replacement: "second")], to: target.text)
                == list.replacingOccurrences(of: "frist", with: "first").replacingOccurrences(of: "secnod", with: "second"))
    }
}

@Test func continuationAndLooseListItemsBelongToTheList() throws {
    let list = "- frist point\n  a long mesage\n  with more detials\n\n- secnod point\n"
    let text = list + "\nUnrelated paragraph."
    let target = try listTarget(text, after: "- frist point\n  a long mesage\n  with more")
    #expect(target.text == list)
    #expect(try listTarget(text, after: "- frist point\n  a long mesage\n  with more detials\n\n- secnod").text == list)
}

@Test func listBoundariesDoNotCrossProseHeadingsOrListKinds() throws {
    #expect(try listTarget("- frist\nHeading\n- secnod", after: "- frist").text == "- frist\n")
    #expect(try listTarget("- frist\n\n# Heading\n\n- secnod", after: "- frist").text == "- frist\n")
    #expect(try listTarget("- frist\n1. secnod\n2. thidr", after: "- frist\n1. secnod").text == "1. secnod\n2. thidr")
    #expect(try listTarget("- frist\n---\n- secnod", after: "- frist").text == "- frist\n")
}

@Test func tabsEmojiAndCRLFHaveExactListRanges() throws {
    let prefix = "👩🏽‍💻 Introduction\r\n- parent\r\n"
    let list = "\t- Un mesaggio\r\n\t- Caffè 👩🏽‍💻\r\n"
    let target = try listTarget(prefix + list + "- another parent", after: prefix + "\t- Un mesaggio")
    #expect(target.range.location == prefix.utf16.count)
    #expect(target.text == list)
    #expect(target.replacing(with: list.replacingOccurrences(of: "mesaggio", with: "messaggio"))
            == prefix + list.replacingOccurrences(of: "mesaggio", with: "messaggio") + "- another parent")
}

@Test func codeAndNonListCursorPositionsAreRejected() {
    for text in ["Ordinary paragraph", "- first\n\n", "---", "```markdown\n- mesage\n```", "~~~\n- mesage\n~~~"] {
        let cursor = text.contains("mesage") ? (text as NSString).range(of: "mesage").location + 2 : text.utf16.count
        #expect(throws: CorrectionError.self) {
            try TextTarget(fullText: text, selection: .init(location: cursor, length: 0), scope: .list)
        }
    }
    let text = "```\n- code point\n```\n\n- frist\n- secnod"
    #expect((try? listTarget(text, after: text).text) == "- frist\n- secnod")
}

@Test func emptyFinalBulletStillIncludesEarlierPoints() throws {
    let text = "- frist point\n- secnod point\n- "
    #expect(try listTarget(text, after: text).text == text)
}

@Test func oversizedListsAreRejectedWithoutTargetingSurroundingText() {
    let text = "- " + String(repeating: "mesage ", count: 600)
    #expect(throws: CorrectionError.self) { try listTarget(text, after: "- mesage") }
}

@Test func listCaretTracksChangesOnBothSides() throws {
    let text = "Intro\n- a mesage\n- thsi 👩🏽‍💻 word\n- a mesage"
    let prefix = "Intro\n- a mesage\n- thsi 👩🏽‍💻"
    let target = try listTarget(text, after: prefix)
    let correction = "- a message\n- this 👩🏽‍💻 word\n- a message"
    #expect(target.caret(after: correction).location == "Intro\n- a message\n- this 👩🏽‍💻".utf16.count)
    let join = try listTarget("- some thing here\n- mesage", after: "- some thing")
    #expect(join.caret(after: "- something here\n- message").location == "- something".utf16.count)
}

@Test func listCorrectionUsesOneRequestWithEveryPointAsContext() async throws {
    let input = "- frist point\n- secnod mesage\n  - thidr `mesage` https://example.com/mesage\n- [x] a mesage"
    let output = try await CorrectionEngine.correct(input, configuration: .init(provider: .apple, mode: .rescue)) { prompt, _ in
        #expect(prompt.contains("<text>\n\(input)\n</text>"))
        #expect(prompt.contains("check every point"))
        return [.init(original: "frist", replacement: "first"), .init(original: "secnod", replacement: "second"),
                .init(original: "thidr", replacement: "third"), .init(original: "mesage", replacement: "message")]
    }
    #expect(output == "- first point\n- second message\n  - third `mesage` https://example.com/mesage\n- [x] a message")
}

@Test func taskStateAndFencedCodeCannotBecomeSpellingEdits() throws {
    let input = "- [x] mesage\n- [X] mesage\n- [ ] mesage\n  ~~~\n  mesage\n  ~~~"
    let edits: [WordEdit] = [.init(original: "x", replacement: "a"), .init(original: "X", replacement: "A"),
                             .init(original: "mesage", replacement: "message")]
    #expect(try SpellingEdits.apply(edits, to: input, mode: .rescue)
            == "- [x] message\n- [X] message\n- [ ] message\n  ~~~\n  mesage\n  ~~~")
}
