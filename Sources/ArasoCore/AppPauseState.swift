/// Temporary pause state shared by the text clients of the app in front.
@MainActor
public final class AppPauseState {
    private var app: String?
    public private(set) var paused: Bool

    public init(paused: Bool = false) {
        self.paused = paused
    }

    func activate(app: String?, startPaused: Bool) {
        // An unidentified client must not inherit another client's manual choice.
        if app == nil || self.app != app { paused = startPaused }
        self.app = app
    }

    func toggle() { paused.toggle() }

    /// Read without activating a session or committing its composition (the input menu).
    public func paused(for app: String?) -> Bool? {
        guard let app, self.app == app else { return nil }
        return paused
    }

    /// A different foreground app ends the choice, even if it uses another input method.
    public func applicationActivated(_ app: String?) {
        if self.app != app { reset() }
    }

    /// Settings changes reapply the app's starting policy on the next session activation.
    public func reset() {
        app = nil
        paused = false
    }
}
