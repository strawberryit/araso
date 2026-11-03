import ArasoCore
import Carbon
import Cocoa
import InputMethodKit
import Testing
@testable import Araso

/// Models key-callback buffering and asynchronous composition commits. A replay that arrives
/// before the commit replaces the marked word. This fixture does not reproduce every IMK layer.
private final class DeferredInput: NSObject, IMKTextInput {
    var text = "prefix "
    var mark = NSRange(location: NSNotFound, length: 0)
    var pending = ""
    var reportsMark = true
    var insertions: [String] = []
    var handlingKey = true
    var submitted = false
    var delaysCommit = false
    var pendingCommit: (String, NSRange)?

    func insertText(_ string: Any!, replacementRange range: NSRange) {
        let sent = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        insertions.append(sent)
        if sent == "\n" { submitted = true } // a chat client interprets plain Return as Send
        if range.location == NSNotFound, handlingKey {
            pending += sent
        } else {
            let target = range.location != NSNotFound ? range : mark.location != NSNotFound ? mark : selectedRange()
            if delaysCommit { pendingCommit = (sent, target) }
            else { replace(sent, target) }
        }
    }

    func finishShiftReturn() {
        handlingKey = false
        if pending.isEmpty { return }
        let target = mark.location == NSNotFound ? selectedRange() : mark
        replace(pending, target)
        pending = ""
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let string = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let range = mark.location == NSNotFound ? NSRange(location: (text as NSString).length, length: 0) : mark
        text = (text as NSString).replacingCharacters(in: range, with: string)
        mark = NSRange(location: range.location, length: (string as NSString).length)
    }

    func appShiftReturn() {
        // A key that arrives before composition ends replaces the marked word.
        replace("\n", mark.location == NSNotFound ? selectedRange() : mark)
    }

    func applyCommit() {
        guard let (string, range) = pendingCommit else { return }
        pendingCommit = nil
        replace(string, range)
    }

    func replace(_ string: String, _ range: NSRange) {
        text = (text as NSString).replacingCharacters(in: range, with: string)
        mark = NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: (text as NSString).length, length: 0) }
    func markedRange() -> NSRange { reportsMark ? mark : NSRange(location: NSNotFound, length: NSNotFound) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard NSMaxRange(range) <= (text as NSString).length else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func length() -> Int { (text as NSString).length }
    func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ mode: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "test.deferred" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { true }
    func uniqueClientIdentifierString() -> String! { "test.deferred" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        actualRange?.pointee = range
        return attributedSubstring(from: range)?.string
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

@MainActor @Suite struct ShiftReturnTests {
    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func session(onlyConfirm: Bool = true, hold: Bool = false) -> InputSession {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("araso-shift-return-\(UUID().uuidString).json")
        return InputSession(engine: DictionaryEngine(base: HeuristicEngine(), storeURL: store),
                            policies: AppPolicies(overrides: [AppPolicies.defaultKey: .init(holdSpace: hold)]),
                            returnConfirmsOnly: onlyConfirm)
    }

    @Test(arguments: [true, false], [("hello", "hello"), ("dkssud", "안녕")])
    func sendsTheWordAndLineBreakSeparatelyAfterTheKey(onlyConfirm: Bool, word: (String, String)) async {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session(onlyConfirm: onlyConfirm)
        for ch in word.0 { session.handle(.letter(ch), client: client) }
        var completed = false
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: { input.appShiftReturn() }, afterCommit: { $0() }, completion: { completed = true })
        #expect(input.insertions.isEmpty)
        #expect(session.keys == word.0)
        input.finishShiftReturn()
        #expect(input.mark.location != NSNotFound)
        await nextTurn()
        #expect(completed)
        #expect(input.insertions == [word.1])
        #expect(input.text == "prefix " + word.1 + "\n")
        #expect(input.mark.location == NSNotFound && session.keys.isEmpty)
        #expect(!input.submitted)
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func replayPreservesShiftKeyCodeAndTargetWithoutPostingRealEvents(keyCode: UInt16) {
        let original = event(keyCode, flags: [.shift, .capsLock])
        let replay = ShiftReturnReplay(event: original, target: 42)!
        var sent: [(CGEvent, pid_t)] = []
        #expect(replay.post(authorized: { true }, deliver: { sent.append(($0, $1)) }))
        #expect(sent.count == 2)
        #expect(sent.map { $0.1 } == [42, 42])
        #expect(sent.map { $0.0.type } == [.keyDown, .keyUp])
        for (event, _) in sent {
            #expect(event.flags.contains(.maskShift))
            #expect(event.flags.contains(.maskAlphaShift))
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode))
            #expect(ShiftReturnReplay.matches(NSEvent(cgEvent: event)!))
        }
        #expect(!ShiftReturnReplay.matches(original))
        #expect(ShiftReturnReplay(event: event(keyCode, flags: []), target: 42) == nil)
    }

    @Test func permissionDenialNeverPostsAnUnmodifiedReturn() {
        let replay = ShiftReturnReplay(event: event(), target: 42)!
        var posted = false
        #expect(!replay.post(authorized: { false }, deliver: { _, _ in posted = true }))
        #expect(!posted)
    }

    @Test func aBlockedReplayStillKeepsTheWord() async {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session()
        for ch in "hello" { session.handle(.letter(ch), client: client) }
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: {}, afterCommit: { $0() }, completion: {})
        input.finishShiftReturn()
        await nextTurn()
        #expect(input.text == "prefix hello" && input.mark.location == NSNotFound)
        #expect(!input.submitted)
    }

    @Test func aContextChangeCancelsTheDeferredInsertion() async {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session()
        for ch in "hello" { session.handle(.letter(ch), client: client) }
        var current = true
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { current }, forward: { Issue.record("A stale context must not receive a key") }, afterCommit: { $0() }, completion: {})
        input.finishShiftReturn()
        current = false
        await nextTurn()
        #expect(input.insertions.isEmpty)
        #expect(session.keys == "hello") // the old context still owns its composition
    }

    @Test func repeatedShiftReturnsKeepBothLineBreaks() async {
        let input = DeferredInput()
        let session = session()
        let first = IMKClient(input), second = IMKClient(input)
        for ch in "hello" { session.handle(.letter(ch), client: first) }
        first.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: { input.appShiftReturn() }, afterCommit: { $0() }, completion: {})
        second.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: { input.appShiftReturn() }, afterCommit: { $0() }, completion: {})
        input.finishShiftReturn()
        await nextTurn()
        #expect(input.insertions == ["hello"])
        #expect(input.text == "prefix hello\n\n")
    }

    private func event(_ key: UInt16 = 36, flags: NSEvent.ModifierFlags = .shift) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: key)!
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func shiftReturnIsDistinctFromPlainReturn(keyCode: UInt16) {
        #expect(InputController.key(for: event(keyCode), policy: .standard) == .other)
        #expect(InputController.key(for: event(keyCode, flags: []), policy: .standard) == .enter)
        #expect(event(keyCode, flags: [.shift, .capsLock, .numericPad]).isShiftReturn)
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(!event(keyCode, flags: [.shift, modifier]).isShiftReturn)
        }
        #expect(!event(49).isShiftReturn)
    }

    @Test func ordinaryCommitsKeepTheirExistingDelivery() {
        let input = DeferredInput()
        let client = IMKClient(input)
        client.setMarkedText("hello")
        client.insertText("hello", replacing: nil)
        #expect(input.pending == "hello")
        #expect(input.insertions == ["hello"])
    }

    @Test func aHeldSpaceAndCapsLockSurviveTheDeferredCommit() async {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session(hold: true)
        for ch in "hello" { session.handle(.letter(ch), client: client, capsLock: true) }
        #expect(session.handle(.printable(" "), client: client, capsLock: true))
        client.deferShiftReturn(in: session, capsLock: true, ifCurrent: { true }, forward: { input.appShiftReturn() }, afterCommit: { $0() }, completion: {})
        input.finishShiftReturn()
        await nextTurn()
        #expect(input.insertions == ["HELLO "])
        #expect(input.text == "prefix HELLO \n")
    }

    @Test func nothingIsInsertedWhenThereIsNoCompositionOrArasoIsPaused() {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session()
        let key = InputController.key(for: event(), policy: session.policy)
        #expect(!session.handle(key, client: client))
        session.togglePause(client: client)
        #expect(!session.handle(key, client: client))
        #expect(input.text == "prefix " && input.insertions.isEmpty)
    }

    @Test func committingDoesNotDependOnDocumentAccess() async {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session()
        for ch in "hello" { session.handle(.letter(ch), client: client) }
        input.reportsMark = false
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: { input.appShiftReturn() }, afterCommit: { $0() }, completion: {})
        input.finishShiftReturn()
        await nextTurn()
        #expect(input.text == "prefix hello\n")
    }

    @Test func replayWaitsUntilTheClientAppliesItsCommit() async {
        let input = DeferredInput()
        input.delaysCommit = true
        let client = IMKClient(input)
        let session = session()
        for ch in "hello" { session.handle(.letter(ch), client: client) }
        var scheduled: [@MainActor () -> Void] = []
        var completed = false
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: {
            input.appShiftReturn()
        }, afterCommit: { scheduled.append($0) }, completion: { completed = true })
        input.finishShiftReturn()
        await nextTurn()
        #expect(input.pendingCommit != nil && !completed)
        #expect(scheduled.count == 1)
        scheduled.removeFirst()() // the client still reports the word as composing
        #expect(!completed && input.text == "prefix hello")
        #expect(scheduled.count == 1)
        input.applyCommit()
        scheduled.removeFirst()()
        #expect(completed && scheduled.isEmpty)
        #expect(input.text == "prefix hello\n" && !input.submitted)
    }

    @Test func aStalledClientNeverReceivesTheReplay() async {
        let input = DeferredInput()
        input.delaysCommit = true
        let client = IMKClient(input)
        let session = session()
        for ch in "hello" { session.handle(.letter(ch), client: client) }
        var scheduled: [@MainActor () -> Void] = []
        var completed = false
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { true }, forward: {
            Issue.record("Do not replace a composition that has not ended")
        }, afterCommit: { scheduled.append($0) }, completion: { completed = true })
        input.finishShiftReturn()
        await nextTurn()
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        #expect(completed && input.text == "prefix hello")
        input.applyCommit()
        #expect(input.mark.location == NSNotFound)
    }

    @Test(arguments: [true, false])
    func aContextChangeOrNewWordCancelsAnAlreadyCommittedReplay(changeContext: Bool) async {
        let input = DeferredInput()
        let client = IMKClient(input)
        let session = session()
        for ch in "hello" { session.handle(.letter(ch), client: client) }
        var scheduled: [@MainActor () -> Void] = []
        var current = true
        client.deferShiftReturn(in: session, capsLock: false, ifCurrent: { current }, forward: {
            Issue.record("The delayed key no longer belongs in this context")
        }, afterCommit: { scheduled.append($0) }, completion: {})
        input.finishShiftReturn()
        await nextTurn()
        #expect(input.insertions == ["hello"] && scheduled.count == 1)
        if changeContext { current = false }
        else { session.handle(.letter("a"), client: client) }
        scheduled.removeFirst()()
        #expect(input.text == (changeContext ? "prefix hello" : "prefix helloa"))
    }
}
