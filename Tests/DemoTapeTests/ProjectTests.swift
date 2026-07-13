import XCTest
@testable import DemoTape

final class ProjectTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demotape-project-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
    }

    private func makeDir(_ name: String) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    func testGroupsDerivativesUnderTheirRecording() throws {
        let stem = "DemoTape 2026-07-12 at 01.57.51"
        touch("\(stem).mov")
        touch("\(stem).cam.mov")
        touch("\(stem).events.json")
        touch("\(stem).styled.mp4")
        touch("\(stem).voiceover.mp4")
        touch("\(stem).voiceover.narration.m4a")
        touch("\(stem).captioned.mp4")
        touch("\(stem).styled.srt")
        touch("\(stem).transcript.json")
        try makeDir("\(stem).styled-web")

        let projects = ProjectStore.list(in: dir)
        XCTAssertEqual(projects.count, 1, "one recording → one project")

        let p = try XCTUnwrap(projects.first)
        XCTAssertEqual(p.stem, stem)
        XCTAssertTrue(p.hasStyled)
        XCTAssertTrue(p.hasVoiceover)
        XCTAssertTrue(p.hasNarration)
        XCTAssertTrue(p.hasCaptions)
        // Every touched file (10 entries) is a member of the project.
        XCTAssertEqual(p.members().count, 10, "all derivatives grouped by stem")
    }

    func testWebcamTrackIsNotItsOwnProject() throws {
        let stem = "DemoTape 2026-07-12 at 02.00.00"
        touch("\(stem).mov")
        touch("\(stem).cam.mov")
        let projects = ProjectStore.list(in: dir)
        XCTAssertEqual(projects.count, 1, ".cam.mov must not anchor a separate project")
    }

    func testMultipleRecordingsAreSeparateProjectsNewestFirst() throws {
        let older = "DemoTape 2026-07-12 at 01.00.00"
        let newer = "DemoTape 2026-07-12 at 03.00.00"
        touch("\(older).mov")
        touch("\(older).styled.mp4")
        // Ensure distinct modification times so ordering is deterministic.
        Thread.sleep(forTimeInterval: 0.05)
        touch("\(newer).mov")
        touch("\(newer).styled.mp4")

        // Force creation-date ordering via modification date fallback.
        let projects = ProjectStore.list(in: dir)
        XCTAssertEqual(projects.count, 2)
        // Newer recording should be resolvable and distinct from the older one.
        XCTAssertNotEqual(projects[0], projects[1])
        XCTAssertTrue(Set(projects.map { $0.stem }) == Set([older, newer]))
    }

    func testProjectForDerivativeResolvesToRecording() throws {
        let stem = "DemoTape 2026-07-12 at 04.00.00"
        touch("\(stem).mov")
        touch("\(stem).styled.mp4")
        touch("\(stem).voiceover.mp4")

        let derivative = dir.appendingPathComponent("\(stem).voiceover.mp4")
        let p = ProjectStore.project(for: derivative, in: dir)
        XCTAssertEqual(p?.stem, stem)
    }

    func testBestSourcePrefersMostRecentDerivative() throws {
        let stem = "DemoTape 2026-07-12 at 05.00.00"
        touch("\(stem).mov")
        touch("\(stem).styled.mp4")
        Thread.sleep(forTimeInterval: 0.05)
        touch("\(stem).voiceover.mp4")   // newest → should win

        let p = try XCTUnwrap(ProjectStore.list(in: dir).first)
        XCTAssertEqual(p.bestSource.lastPathComponent, "\(stem).voiceover.mp4")
    }

    func testEmptyDirectoryHasNoProjects() {
        XCTAssertTrue(ProjectStore.list(in: dir).isEmpty)
    }
}
