import Foundation
import IOKit.pwr_mgt
import KofferCore

/// Keeps the Mac awake while a backup runs.
final class PowerAssertion: PowerKeeping {
    private var assertionID: IOPMAssertionID = 0
    private var active: Bool = false
    private let lock: NSLock = NSLock()

    func begin(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return }
        var newID: IOPMAssertionID = 0
        let result: IOReturn = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
            active = true
        }
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        active = false
    }

    deinit {
        if active {
            IOPMAssertionRelease(assertionID)
        }
    }
}
