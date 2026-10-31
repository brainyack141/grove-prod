import XCTest
@testable import Grove

final class AppShellChromePolicyTests: XCTestCase {
    func testTabRootKeepsTheBarAndItsScanActionUnlessTheKeyboardIsUp() {
        XCTAssertTrue(
            AppShellChromePolicy.showsPrimaryAction(
                isKeyboardVisible: false,
                isAtTabRoot: true
            )
        )
        XCTAssertFalse(
            AppShellChromePolicy.showsPrimaryAction(
                isKeyboardVisible: true,
                isAtTabRoot: true
            )
        )
    }

    func testDrillInsTakeTheFullHeightSoThePageOwnsTheBottomEdge() {
        // A plant page is a drill-in. It docks its own check-in and "not
        // tonight" actions, so the shell's raised centre action — and the bar it
        // sits in — must step aside rather than collide with that bar.
        XCTAssertFalse(
            AppShellChromePolicy.showsPrimaryAction(
                isKeyboardVisible: false,
                isAtTabRoot: false
            )
        )
        XCTAssertFalse(
            AppShellChromePolicy.showsPrimaryAction(
                isKeyboardVisible: true,
                isAtTabRoot: false
            )
        )
    }
}
