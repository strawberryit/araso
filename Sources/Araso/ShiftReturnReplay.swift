import Cocoa

/// The original modified key, sent only to the app that had focus when it was pressed.
/// Text insertion APIs cannot preserve a web editor's Shift+Return command.
struct ShiftReturnReplay {
    private static let marker: Int64 = 0x415241534F52544E
    let target: pid_t
    let down: CGEvent
    let up: CGEvent

    init?(event: NSEvent, target: pid_t) {
        guard event.isShiftReturn,
              let down = event.cgEvent?.copy() ?? CGEvent(keyboardEventSource: nil, virtualKey: event.keyCode, keyDown: true),
              let up = down.copy() else { return nil }
        self.target = target
        self.down = down
        self.up = up
        down.type = .keyDown
        up.type = .keyUp
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        for key in [down, up] {
            key.flags = flags
            key.setIntegerValueField(.keyboardEventKeycode, value: Int64(event.keyCode))
            key.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        }
        down.setIntegerValueField(.keyboardEventAutorepeat, value: event.isARepeat ? 1 : 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    }

    static func matches(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// No permission prompt or unmodified-Return fallback: the user grants posting access first.
    @MainActor func post(authorized: () -> Bool = { CGPreflightPostEventAccess() },
                         deliver: (CGEvent, pid_t) -> Void = { event, pid in event.postToPid(pid) }) -> Bool {
        guard authorized() else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        down.timestamp = now
        up.timestamp = now + 1
        deliver(down, target)
        deliver(up, target)
        return true
    }
}
