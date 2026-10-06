import Foundation
import Testing
@testable import LocalWriteCore

@Test func modelInstructionsDescribeSelectedAccuracyMode() {
    #expect(CorrectionEngine.instructions(for: .careful).contains("single-word spelling edits"))
    #expect(CorrectionEngine.instructions(for: .rescue).contains("heavily mistyped"))
    #expect(!CorrectionEngine.instructions(for: .rescue).contains("modeInstructions"))
}

@Test func typoCandidateRankingRecognizesTranspositionsAndNeighborKeys() {
    #expect(CorrectionEngine.typoScore(from: "teh", to: "the") < CorrectionEngine.typoScore(from: "teh", to: "ten"))
    #expect(CorrectionEngine.typoScore(from: "jello", to: "hello") < CorrectionEngine.typoScore(from: "jello", to: "cello"))
}

@Test func paragraphAtCursorPreservesOtherParagraphs() throws {
    let text = "First paragraph.\nA mesage here.\nThird paragraph."
    let target = try TextTarget(fullText: text, selection: NSRange(location: 24, length: 0), scope: .paragraph)
    #expect(target.text == "A mesage here.\n")
    #expect(target.replacing(with: "A message here.\n") == "First paragraph.\nA message here.\nThird paragraph.")
}

@Test func selectedTextTakesPriority() throws {
    let target = try TextTarget(fullText: "A mesage here", selection: NSRange(location: 2, length: 6), scope: .field)
    #expect(target.text == "mesage")
    #expect(target.replacing(with: "message") == "A message here")
}

@Test func emojiAndNonLatinTextUseUTF16() throws {
    let text = "👩🏽‍💻 Caffè\nUn mesaggio."
    let target = try TextTarget(fullText: text, selection: NSRange(location: (text as NSString).length, length: 0), scope: .paragraph)
    #expect(target.text == "Un mesaggio.")
    #expect(target.replacing(with: "Un messaggio.") == "👩🏽‍💻 Caffè\nUn messaggio.")
    #expect(target.caret(after: "Un messaggio.").location == (text as NSString).length + 1)
}

@Test func boundaryAndEmptyParagraphs() throws {
    #expect(try TextTarget(fullText: "hello\nworld", selection: .init(location: 6, length: 0), scope: .paragraph).text == "world")
    #expect(try TextTarget(fullText: "hello\nworld", selection: .init(location: 5, length: 0), scope: .paragraph).text == "hello\n")
    #expect(throws: CorrectionError.self) { try TextTarget(fullText: "hello\n", selection: .init(location: 6, length: 0), scope: .paragraph) }
    #expect(throws: CorrectionError.self) { try TextTarget(fullText: "", selection: .init(location: 0, length: 0), scope: .field) }
}

@Test func invalidRangesAndOversizeInputAreRejected() {
    for range in [NSRange(location: NSNotFound, length: 0), .init(location: -1, length: 0), .init(location: 1, length: Int.max), .init(location: 100, length: 0)] {
        #expect(throws: CorrectionError.self) { try TextTarget(fullText: "hello", selection: range, scope: .paragraph) }
    }
    #expect(throws: CorrectionError.self) { try TextTarget(fullText: String(repeating: "x", count: 4_001), selection: .init(location: 0, length: 0), scope: .field) }
}

@Test func conservativeCorrectionPreservesWhitespace() throws {
    #expect(try CorrectionValidation.validate("I received your message.", original: "  I recieved your mesage.\n") == "  I received your message.\n")
    #expect(try CorrectionValidation.validate("hello", original: "helo") == "hello")
    #expect(try CorrectionValidation.validate(" \tHello.\r\n", original: " \tHello.\r\n") == " \tHello.\r\n")
}

@Test func rejectsDestructiveModelOutput() {
    let original = "Please send 42 files to me at a@example.com."
    for output in ["", "Certainly! Here is an improved version of your message: Please send the documents.",
                   "Please send 43 files to me at a@example.com.", "Please send 42 files to me at b@example.com.",
                   "Please send 42 files\nto me at a@example.com."] {
        #expect(throws: CorrectionError.self) { try CorrectionValidation.validate(output, original: original) }
    }
    #expect(throws: CorrectionError.self) { try CorrectionValidation.validate("Visit https://example.org now.", original: "Visit https://example.com now.") }
    #expect(throws: CorrectionError.self) { try CorrectionValidation.validate("Use `message` here.", original: "Use `mesage` here.") }
}

@Test func caretTracksCorrectionsBeforeIt() throws {
    let target = try TextTarget(fullText: "helo world", selection: .init(location: 5, length: 0), scope: .paragraph)
    #expect(target.caret(after: "hello world") == .init(location: 6, length: 0))
}

@Test func localAddressesOnly() throws {
    for address in ["http://127.0.0.1:11434", "http://localhost:11434/", "http://[::1]:11434"] {
        #expect(try OllamaClient.validatedBaseURL(address).host != nil)
    }
    for address in ["https://example.com", "http://127.0.0.1.evil.com", "http://localhost@evil.com", "http://user:pass@localhost", "file:///tmp/ollama", "http://localhost/api", "http://192.168.1.2:11434", "http://localhost?url=remote"] {
        #expect(throws: CorrectionError.self) { try OllamaClient.validatedBaseURL(address) }
    }
}

@Test func cloudModelsCannotMasqueradeAsLocal() throws {
    let json = #"[{"name":"llama3.2:3b"},{"name":"gpt:cloud"},{"name":"renamed-local","remote_host":"https://ollama.com","remote_model":"remote"}]"#
    let models = try JSONDecoder().decode([OllamaModel].self, from: Data(json.utf8))
    #expect(models.filter(\.isLocal).map(\.name) == ["llama3.2:3b"])
}

@Test func wordEditsPreserveObsidianMarkdownAndHiddenCharacters() throws {
    let input = "\u{200B}\n> Distrubutional semanitc models  \n\n**recieved** a mesage. #mesage https://example.com/mesage `mesage`"
    let edits = [WordEdit(original: "Distrubutional", replacement: "Distributional"),
                 .init(original: "semanitc", replacement: "semantic"),
                 .init(original: "recieved", replacement: "received"),
                 .init(original: "mesage", replacement: "message")]
    #expect(try SpellingEdits.apply(edits, to: input) == "\u{200B}\n> Distributional semantic models  \n\n**received** a message. #mesage https://example.com/mesage `mesage`")
}

@Test func wordEditsAllowDenseTyposWithoutRewriting() throws {
    #expect(try SpellingEdits.apply([.init(original: "teh", replacement: "the")], to: "teh teh teh") == "the the the")
    #expect(try SpellingEdits.apply([.init(original: "A sentence", replacement: "A rewritten paragraph")], to: "A sentence") == "A sentence")
    #expect(try SpellingEdits.apply([.init(original: "cat", replacement: "elephant")], to: "cat") == "cat")
}

@Test func rescueModeRepairsBadlyBotchedSentence() throws {
    let edits = [WordEdit(original: "heldlo", replacement: "hello"),
                 .init(original: "mxy", replacement: "my"),
                 .init(original: "namea", replacement: "name")]
    #expect(try SpellingEdits.apply(edits, to: "heldlo mxy namea is vincent", mode: .rescue) == "hello my name is vincent")
}

@Test func rescueModeAllowsOnlyShortSplitAndJoinRepairs() throws {
    #expect(try SpellingEdits.apply([.init(original: "alot", replacement: "a lot")], to: "Thanks alot", mode: .rescue) == "Thanks a lot")
    #expect(try SpellingEdits.apply([.init(original: "in to", replacement: "into")], to: "log in to the app", mode: .rescue) == "log into the app")
    #expect(try SpellingEdits.apply([.init(original: "A sentence", replacement: "A rewritten paragraph")], to: "A sentence", mode: .rescue) == "A sentence")
    #expect(try SpellingEdits.apply([.init(original: "alot", replacement: "a lot")], to: "Thanks alot", mode: .careful) == "Thanks alot")
}

@Test func overlappingRescueEditsPreferExactPhrase() throws {
    let edits = [WordEdit(original: "some thing", replacement: "something"),
                 .init(original: "thing", replacement: "think")]
    #expect(try SpellingEdits.apply(edits, to: "some thing", mode: .rescue) == "something")
}

@Test func wordEditsDoNotReplaceSubstringsOrCascade() throws {
    let edits = [WordEdit(original: "teh", replacement: "the"), .init(original: "the", replacement: "they")]
    #expect(try SpellingEdits.apply(edits, to: "teh the tehran") == "the they tehran")
    #expect(try SpellingEdits.apply([.init(original: "mesage", replacement: "message")], to: "mesage@mesage.com mesage") == "mesage@mesage.com message")
}

@Test func invisibleEditorParagraphIsNotSentToModel() {
    #expect(throws: CorrectionError.self) { try TextTarget(fullText: "\u{200B}", selection: .init(location: 0, length: 0), scope: .paragraph) }
}

@Test func minimalReplacementSelectsOnlyChangedLetters() {
    let change = TextReplacement.minimal(original: "thsi is a test", corrected: "this is a test", offset: 100)
    #expect(change.range == NSRange(location: 102, length: 2))
    #expect(change.text == "is")
    let insertion = TextReplacement.minimal(original: "a mesage here", corrected: "a message here")
    #expect(insertion.range == NSRange(location: 5, length: 0))
    #expect(insertion.text == "s")
    let emoji = TextReplacement.minimal(original: "👩🏽‍💻 thsi", corrected: "👩🏽‍💻 this")
    #expect(emoji.range.location == ("👩🏽‍💻 th" as NSString).length)
    #expect(emoji.range.length == 2)
}

@Test func lineModeOnlyIncludesTextBeforeTheCursor() throws {
    let input = "First line.\nthsi is a test AFTER CURSOR"
    let caret = ("First line.\nthsi is a test" as NSString).length
    let target = try TextTarget(fullText: input, selection: .init(location: caret, length: 0), scope: .line)
    #expect(target.text == "thsi is a test")
    #expect(target.replacing(with: "this is a test") == "First line.\nthis is a test AFTER CURSOR")
}
