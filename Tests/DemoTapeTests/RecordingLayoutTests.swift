import XCTest
@testable import DemoTape

final class RecordingLayoutTests: XCTestCase {

    private let base = "DemoTape 2026-07-14 at 21.52.46"

    func testRecordingBaseMatchesDottedTimestamp() {
        XCTAssertEqual(RecordingLayout.recordingBase(of: "\(base).styled.mp4"), base)
        XCTAssertEqual(RecordingLayout.recordingBase(of: "\(base).mov"), base)
        XCTAssertEqual(RecordingLayout.recordingBase(of: "\(base)-web"), base)
        XCTAssertEqual(RecordingLayout.recordingBase(of: "\(base).voiceover.narration.m4a"), base)
    }

    func testRecordingBaseRejectsNonRecordings() {
        XCTAssertNil(RecordingLayout.recordingBase(of: "demotape.log"))
        XCTAssertNil(RecordingLayout.recordingBase(of: "random.txt"))
        XCTAssertNil(RecordingLayout.recordingBase(of: "Screenshot 2026.png"))
    }

    func testSupportClassification() {
        XCTAssertTrue(RecordingLayout.isSupport(remainder: ".mov"))
        XCTAssertTrue(RecordingLayout.isSupport(remainder: ".cam.mov"))
        XCTAssertTrue(RecordingLayout.isSupport(remainder: ".events.json"))
        XCTAssertTrue(RecordingLayout.isSupport(remainder: ".transcript.json"))
        XCTAssertTrue(RecordingLayout.isSupport(remainder: ".srt"))
        XCTAssertFalse(RecordingLayout.isSupport(remainder: ".styled.mp4"))
        XCTAssertFalse(RecordingLayout.isSupport(remainder: "-web"))
        XCTAssertFalse(RecordingLayout.isSupport(remainder: ".voiceover.narration.m4a"))
    }

    func testMigrationPlanRoutesFilesCorrectly() {
        let names = [
            "\(base).mov", "\(base).cam.mov", "\(base).events.json", "\(base).transcript.json",
            "\(base).srt", "\(base).styled.mp4", "\(base)-web", "demotape.log", "random.txt"
        ]
        let plan = Dictionary(uniqueKeysWithValues: RecordingLayout.migrationPlan(
            names: names, directoryNames: ["\(base)-web"]).map { ($0.from, $0.to) })

        XCTAssertEqual(plan["\(base).mov"], "\(base)/.source/\(base).mov")
        XCTAssertEqual(plan["\(base).cam.mov"], "\(base)/.source/\(base).cam.mov")
        XCTAssertEqual(plan["\(base).events.json"], "\(base)/.source/\(base).events.json")
        XCTAssertEqual(plan["\(base).transcript.json"], "\(base)/.source/\(base).transcript.json")
        XCTAssertEqual(plan["\(base).srt"], "\(base)/.source/\(base).srt")
        XCTAssertEqual(plan["\(base).styled.mp4"], "\(base)/\(base).styled.mp4")
        XCTAssertEqual(plan["\(base)-web"], "\(base)/\(base)-web")
        XCTAssertEqual(plan["demotape.log"], ".demotape/demotape.log")
        XCTAssertNil(plan["random.txt"], "unknown files are left untouched")
    }

    func testMigrationSkipsAlreadyMigratedFolder() {
        // A bare directory named exactly the base is an existing recording folder → no move.
        let plan = RecordingLayout.migrationPlan(names: [base], directoryNames: [base])
        XCTAssertTrue(plan.isEmpty)
    }
}

// MARK: - Orphaned temp-file detection
//
// The launch sweep deletes AVFoundation's leftover atomic-write temps. The predicate must catch those
// and NEVER a real output, since it drives a delete.

final class OrphanedTempNameTests: XCTestCase {

    func testMatchesAtomicWriteTemps() {
        XCTAssertTrue(RecordingLayout.isOrphanedTempName("Demo 2026-07-26 at 03.57.05.captioned.mp4.sb-a19e01c2-zmUpGX"))
        XCTAssertTrue(RecordingLayout.isOrphanedTempName("demo-720p.mp4.sb-bff50c00-qsR3Jd"))
    }

    func testNeverMatchesRealOutputs() {
        for name in ["Demo.styled.mp4", "Demo.captioned.mp4", "Demo.es.tight.mp4",
                     "Demo.voiceover.fr.mp4", "recipe.json", "timeline.json", "Demo.mov",
                     "Demo.events.json", "poster.jpg", "demo.gif"] {
            XCTAssertFalse(RecordingLayout.isOrphanedTempName(name), "would wrongly delete \(name)")
        }
    }
}
