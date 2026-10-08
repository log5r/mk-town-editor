import AppKit

/// The parts of `NSApplication` that launch-time activation touches, so tests can use a stand-in.
@MainActor
protocol ActivationPolicyControlling: AnyObject {
    func activationPolicy() -> NSApplication.ActivationPolicy
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

extension NSApplication: ActivationPolicyControlling {}

/// Makes a bare executable launched by `swift run` (for example through `start.sh`) behave like a bundled app.
///
/// An executable without an application Info.plist starts with the `prohibited` activation policy.
/// Its windows still appear, but the process can never become the active app, so keystrokes and
/// ⌘ shortcuts keep going to the previously active app. Launch Services lists such a process as
/// `type="BackgroundOnly"` in `lsappinfo list`. Switching to `regular` before the first window is
/// created restores the Dock icon, the menu bar, and keyboard focus. A bundled app already runs with
/// `regular`, so nothing changes there.
@MainActor
final class ApplicationActivation {
    /// True when the policy had to be repaired for this process.
    private(set) var repairedPolicy = false

    func applicationWillFinishLaunching(_ application: ActivationPolicyControlling) {
        guard application.activationPolicy() == .prohibited else { return }
        repairedPolicy = application.setActivationPolicy(.regular)
    }

    /// A bundled app is activated by Launch Services on launch; a repaired executable has to ask itself.
    func applicationDidFinishLaunching(_ application: ActivationPolicyControlling) {
        guard repairedPolicy else { return }
        application.activate()
    }
}
