import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class ApplicationActivationTests: XCTestCase {
    private final class FakeApplication: ActivationPolicyControlling {
        var policy: NSApplication.ActivationPolicy
        var acceptsPolicyChange = true
        var policyChanges: [NSApplication.ActivationPolicy] = []
        var activateCount = 0

        init(policy: NSApplication.ActivationPolicy) {
            self.policy = policy
        }

        func activationPolicy() -> NSApplication.ActivationPolicy { policy }

        func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
            policyChanges.append(activationPolicy)
            guard acceptsPolicyChange else { return false }
            policy = activationPolicy
            return true
        }

        func activate() { activateCount += 1 }
    }

    /// `swift run` starts an executable without an Info.plist as `prohibited`; it must become a regular app
    /// before windows appear and then activate itself so typing reaches the editor.
    func testProhibitedExecutableBecomesRegularAndActivatesAfterLaunch() {
        let app = FakeApplication(policy: .prohibited)
        let activation = ApplicationActivation()

        activation.applicationWillFinishLaunching(app)
        XCTAssertEqual(app.policy, .regular)
        XCTAssertEqual(app.policyChanges, [.regular])
        XCTAssertTrue(activation.repairedPolicy)
        XCTAssertEqual(app.activateCount, 0, "Activation waits until launch has finished")

        activation.applicationDidFinishLaunching(app)
        XCTAssertEqual(app.activateCount, 1)
    }

    func testBundledAppKeepsItsPolicyAndIsNotActivatedTwice() {
        for policy in [NSApplication.ActivationPolicy.regular, .accessory] {
            let app = FakeApplication(policy: policy)
            let activation = ApplicationActivation()
            activation.applicationWillFinishLaunching(app)
            activation.applicationDidFinishLaunching(app)
            XCTAssertEqual(app.policy, policy)
            XCTAssertTrue(app.policyChanges.isEmpty, "\(policy) must not be touched")
            XCTAssertFalse(activation.repairedPolicy)
            XCTAssertEqual(app.activateCount, 0, "Launch Services already activates a bundled app")
        }
    }

    func testRefusedPolicyChangeDoesNotActivate() {
        let app = FakeApplication(policy: .prohibited)
        app.acceptsPolicyChange = false
        let activation = ApplicationActivation()
        activation.applicationWillFinishLaunching(app)
        activation.applicationDidFinishLaunching(app)
        XCTAssertEqual(app.policy, .prohibited)
        XCTAssertFalse(activation.repairedPolicy)
        XCTAssertEqual(app.activateCount, 0)
    }

    func testAppDelegateRepairsPolicyThroughLaunchNotifications() {
        let app = FakeApplication(policy: .prohibited)
        let delegate = ExternalDocumentOpenAppDelegate(application: { app })
        _ = NSApplication.shared

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertEqual(app.policy, .regular)
        XCTAssertTrue(delegate.repairedActivationPolicy)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(app.activateCount, 1)
    }
}
