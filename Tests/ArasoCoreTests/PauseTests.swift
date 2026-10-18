import Foundation
import Testing
@testable import ArasoCore

/// A right ⌘ tap pauses Araso in the text field (`togglePause`).
@MainActor @Suite struct PauseTests {
    let field = FakeTextField()
    let session: InputSession

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-pause-\(UUID().uuidString).json")
        session = InputSession(engine: DictionaryEngine(base: sharedEngine, storeURL: url))
        session.activate(app: "test.app")
    }

    /// Types letters and spaces; keys the session passes on are typed by the field.
    func type(_ s: String, in target: InputSession? = nil) {
        let session = target ?? self.session
        for ch in s {
            let key: InputSession.Key = ch.isLetter ? .letter(ch) : .printable(ch)
            if !session.handle(key, client: field) { field.insertText(String(ch), replacing: nil) }
        }
    }

    @Test func pausedKeysGoThroughAsTyped() {
        session.togglePause(client: field)
        type("jjkkhl dkssud")
        #expect(field.text == "jjkkhl dkssud")
        #expect(field.marked.location == NSNotFound)
    }

    @Test func pausingCommitsTheWordInProgress() {
        type("dkssud")
        session.togglePause(client: field)
        #expect(field.text == "안녕")
        #expect(field.marked.location == NSNotFound)
    }

    @Test func secondTapResumes() {
        session.togglePause(client: field)
        type("jk ")
        session.togglePause(client: field)
        type("dkssud ")
        #expect(field.text == "jk 안녕 ")
    }

    @Test func anotherTextFieldResumes() {
        session.togglePause(client: field)
        session.activate(app: "test.other")
        #expect(!session.paused)
    }

    @Test func selectedAppStartsPausedAndCanResume() {
        let policies = AppPolicies(overrides: ["test.terminal": .init(startPaused: true)])
        let session = InputSession(engine: self.session.engine, policies: policies)
        session.activate(app: "test.terminal")
        #expect(session.policy.enabled)
        #expect(session.paused)
        type("dkssud ", in: session)
        #expect(field.text == "dkssud ")
        #expect(field.marked.location == NSNotFound)

        session.togglePause(client: field)
        #expect(!session.paused)
        type("dkssud ", in: session)
        #expect(field.text == "dkssud 안녕 ")
        // Returning to the same app/text field reapplies its starting state.
        session.activate(app: "test.terminal")
        #expect(session.paused)
        session.activate(app: "test.other")
        #expect(!session.paused)
        session.activate(app: "test.terminal")
        #expect(session.paused)
    }

    @Test func defaultStartingStateCanBeOverridden() {
        let policies = AppPolicies(overrides: ["*": .init(startPaused: true),
                                               "test.active": .init(startPaused: false)])
        let session = InputSession(engine: self.session.engine, policies: policies)
        #expect(session.paused)
        session.activate(app: nil)
        #expect(session.paused)
        session.activate(app: "test.active")
        #expect(!session.paused)
    }

    @Test func disabledAppStaysDisabledAfterPauseToggle() {
        let policies = AppPolicies(overrides: ["test.off": .init(enabled: false, startPaused: true)])
        let session = InputSession(engine: self.session.engine, policies: policies)
        session.activate(app: "test.off")
        session.togglePause(client: field)
        #expect(!session.paused)
        #expect(!session.handle(.letter("d"), client: field))
        #expect(field.text.isEmpty)
    }
}

/// An app set to Strict keeps short commands as typed but still splits mixed words.
@MainActor @Suite struct StrictSplitTests {
    @Test func strictStillSplitsMixedWords() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("araso-strict-\(UUID().uuidString).json")
        let policies = AppPolicies(overrides: ["test.terminal": .init(conversionThreshold: AppPolicy.strictThreshold)])
        let session = InputSession(engine: DictionaryEngine(base: splitting, storeURL: url), policies: policies)
        session.activate(app: "test.terminal")
        let field = FakeTextField()
        for ch in "ciw gst githubdp xdp hellodnjfem " {
            let key: InputSession.Key = ch.isLetter ? .letter(ch) : .printable(ch)
            if !session.handle(key, client: field) { field.insertText(String(ch), replacing: nil) }
        }
        #expect(field.text == "ciw gst github에 x에 hello월드 ")
    }
}
