import XCTest
@testable import LMUXCore

final class AgentMirrorPolicyTests: XCTestCase {
    typealias E = AgentMirrorPolicy.ExportInputs
    typealias I = AgentMirrorPolicy.ImportInputs

    // MARK: Export

    func testExportPushFreshFile() {
        let action = AgentMirrorPolicy.exportAction(
            E(localSize: 100, localMTime: 5, mirrorExists: false, mirrorSize: 0,
              lastExportFingerprint: nil, lastImportSize: nil)
        )
        XCTAssertEqual(action, .copyToMirror)
    }

    func testExportAppendTailWhenMirrorIsPrefix() {
        let action = AgentMirrorPolicy.exportAction(
            E(localSize: 100, localMTime: 9, mirrorExists: true, mirrorSize: 60,
              lastExportFingerprint: "60,5", lastImportSize: nil)
        )
        XCTAssertEqual(action, .appendToMirror)
    }

    func testExportSkipWhenUnchangedSinceLastExport() {
        let action = AgentMirrorPolicy.exportAction(
            E(localSize: 100, localMTime: 9, mirrorExists: true, mirrorSize: 60,
              lastExportFingerprint: "100,9", lastImportSize: nil)
        )
        XCTAssertEqual(action, .skip)
    }

    func testExportLoopGuardAfterPullBack() {
        // File was pulled from the mirror (lastImportSize == 60) and has not
        // grown beyond it — pushing it back would ping-pong.
        let action = AgentMirrorPolicy.exportAction(
            E(localSize: 60, localMTime: 7, mirrorExists: true, mirrorSize: 60,
              lastExportFingerprint: nil, lastImportSize: 60)
        )
        XCTAssertEqual(action, .skip)
    }

    func testExportWholeCopyWhenMirrorNotPrefix() {
        // Mirror is longer than local (different machine grew it) → whole
        // replace, never append.
        let action = AgentMirrorPolicy.exportAction(
            E(localSize: 80, localMTime: 9, mirrorExists: true, mirrorSize: 120,
              lastExportFingerprint: "80,3", lastImportSize: nil)
        )
        XCTAssertEqual(action, .copyToMirror)
    }

    func testExportPushAfterLocalGrowthPastPulledSize() {
        // Pulled at 60, then this machine kept working (80). Loop guard must
        // NOT suppress this: 80 > 60.
        let action = AgentMirrorPolicy.exportAction(
            E(localSize: 80, localMTime: 9, mirrorExists: true, mirrorSize: 60,
              lastExportFingerprint: "60,6", lastImportSize: 60)
        )
        XCTAssertEqual(action, .appendToMirror)
    }

    // MARK: Import

    func testImportCopyWholeWhenLocalMissing() {
        let action = AgentMirrorPolicy.importAction(
            I(localExists: false, localSize: 0, lastImportSize: nil, remoteSize: 200)
        )
        XCTAssertEqual(action, .copyToLocal)
    }

    func testImportAppendWhenLocalUnchangedAndMirrorGrew() {
        let action = AgentMirrorPolicy.importAction(
            I(localExists: true, localSize: 60, lastImportSize: 60, remoteSize: 200)
        )
        XCTAssertEqual(action, .appendToLocal)
    }

    func testImportConflictWhenBothGrew() {
        // Local kept writing (80 > last pull 60) and mirror also grew (200) —
        // ambiguous two-way change, keep local.
        let action = AgentMirrorPolicy.importAction(
            I(localExists: true, localSize: 80, lastImportSize: 60, remoteSize: 200)
        )
        XCTAssertEqual(action, .conflictKeepLocal)
    }

    func testImportConflictWhenLocalGrewAndNoPullRecord() {
        // Local wrote but we have no import record (e.g. always-local file that
        // also exists on the mirror with new content) → conflict, keep local.
        let action = AgentMirrorPolicy.importAction(
            I(localExists: true, localSize: 100, lastImportSize: nil, remoteSize: 120)
        )
        XCTAssertEqual(action, .conflictKeepLocal)
    }

    func testImportSkipWhenLocalNewerOrEqual() {
        let equal = AgentMirrorPolicy.importAction(
            I(localExists: true, localSize: 100, lastImportSize: 100, remoteSize: 100)
        )
        XCTAssertEqual(equal, .skip)
        let newer = AgentMirrorPolicy.importAction(
            I(localExists: true, localSize: 100, lastImportSize: nil, remoteSize: 80)
        )
        XCTAssertEqual(newer, .skip)
    }
}
