import Foundation
import Testing
@testable import ArasoCore

/// A right ⌘ tap pauses Araso in the app (`togglePause`).
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

    @Test func anotherAppResumes() {
        session.togglePause(client: field)
        session.activate(app: "test.other")
        #expect(!session.paused)
    }

    @Test func sameAppKeepsManualPause() {
        session.togglePause(client: field)
        session.activate(app: "test.app")
        #expect(session.paused)
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
        // Switching text fields within the app keeps the user's choice.
        session.activate(app: "test.terminal")
        #expect(!session.paused)
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

    @Test(arguments: [false, true])
    func tabsShareTheAppsManualChoice(startPaused: Bool) {
        let state = AppPauseState()
        let policies = AppPolicies(overrides: ["test.terminal": .init(startPaused: startPaused)])
        let first = InputSession(engine: session.engine, policies: policies, pauseState: state)
        first.activate(app: "test.terminal")
        #expect(first.paused == startPaused)
        first.togglePause(client: field)

        // A newly created tab must not reset the state of the tab it came from.
        let second = InputSession(engine: session.engine, policies: policies, pauseState: state)
        #expect(first.paused == !startPaused)
        second.activate(app: "test.terminal")
        #expect(second.paused == !startPaused)
        type("dkssud ", in: second)
        #expect(field.text == (startPaused ? "안녕 " : "dkssud "))

        second.togglePause(client: field)
        first.activate(app: "test.terminal")
        #expect(first.paused == startPaused)
        // Reading the menu and redundant foreground notifications don't change the choice.
        #expect(state.paused(for: "test.other") == nil)
        state.applicationActivated("test.terminal")
        #expect(state.paused(for: "test.terminal") == startPaused)
    }

    @Test(arguments: [false, true])
    func leavingForAnAppWithoutArasoReappliesTheStartingState(startPaused: Bool) {
        let state = AppPauseState()
        let policies = AppPolicies(overrides: ["test.terminal": .init(startPaused: startPaused)])
        let terminal = InputSession(engine: session.engine, policies: policies, pauseState: state)
        terminal.activate(app: "test.terminal")
        terminal.togglePause(client: field)

        // The other app needn't create a session for the old choice to end.
        state.applicationActivated("test.other")
        #expect(state.paused(for: "test.terminal") == nil)
        terminal.activate(app: "test.terminal")
        #expect(terminal.paused == startPaused)
    }

    @Test func settingsResetAppliesTheNewStartingPolicy() {
        let state = AppPauseState()
        let first = InputSession(engine: session.engine, pauseState: state)
        first.activate(app: "test.terminal")
        state.reset()
        let policies = AppPolicies(overrides: ["test.terminal": .init(startPaused: true)])
        let fresh = InputSession(engine: session.engine, policies: policies, pauseState: state)
        fresh.activate(app: "test.terminal")
        #expect(fresh.paused)
    }

    @Test func unidentifiedClientsDontShareManualPause() {
        let state = AppPauseState()
        let first = InputSession(engine: session.engine, pauseState: state)
        first.activate(app: nil)
        first.togglePause(client: field)
        let second = InputSession(engine: session.engine, pauseState: state)
        second.activate(app: nil)
        #expect(!second.paused)
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
