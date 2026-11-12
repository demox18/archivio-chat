import XCTest
@testable import ArchivioCore

final class MergeTests: XCTestCase {
    private var nextID: Int64 = 0

    private func ex(_ ts: Int64, _ who: Int64, _ kind: MessageKind = .text, _ text: String = "",
                    name: String? = nil, hasFile: Bool = false, edited: Bool = false) -> Merger.Existing {
        nextID += 1
        return Merger.Existing(id: nextID, ts: ts, participantKey: who, kind: kind, text: text,
                               attachmentName: name, hasFile: hasFile, edited: edited)
    }

    private func inc(_ ts: Int64, _ who: Int64, _ kind: MessageKind = .text, _ text: String = "",
                     name: String? = nil, sourceHasFile: Bool = false, edited: Bool = false) -> Merger.Incoming {
        Merger.Incoming(ts: ts, participantKey: who, kind: kind, text: text,
                        attachmentName: name, sourceHasFile: sourceHasFile, edited: edited)
    }

    func testIdenticalRepeatsAreCountedByOccurrence() {
        let e = [ex(10, 1, .text, "ok"), ex(10, 1, .text, "ok"), ex(10, 1, .text, "ok")]
        let three = Merger.decide(existing: e, incoming: Array(repeating: inc(10, 1, .text, "ok"), count: 3))
        XCTAssertEqual(three, [.present(existingID: 1), .present(existingID: 2), .present(existingID: 3)])

        let four = Merger.decide(existing: e, incoming: Array(repeating: inc(10, 1, .text, "ok"), count: 4))
        XCTAssertEqual(Array(four.prefix(3)), [.present(existingID: 1), .present(existingID: 2), .present(existingID: 3)])
        XCTAssertEqual(four[3], .insert(possibleDuplicate: false))
    }

    func testSameTextDifferentSecondIsNew() {
        let d = Merger.decide(existing: [ex(10, 1, .text, "ciao")], incoming: [inc(11, 1, .text, "ciao")])
        XCTAssertEqual(d, [.insert(possibleDuplicate: false)])
    }

    func testDifferentSenderIsNew() {
        let d = Merger.decide(existing: [ex(10, 1, .text, "ciao")], incoming: [inc(10, 2, .text, "ciao")])
        XCTAssertEqual(d, [.insert(possibleDuplicate: false)])
    }

    func testTrailingWhitespaceIsIgnored() {
        let d = Merger.decide(existing: [ex(10, 1, .text, "ciao")], incoming: [inc(10, 1, .text, "ciao  ")])
        XCTAssertEqual(d, [.present(existingID: 1)])
    }

    func testCaseDifferenceIsPossibleDuplicate() {
        let d = Merger.decide(existing: [ex(10, 1, .text, "Ciao  come va")], incoming: [inc(10, 1, .text, "ciao come va")])
        XCTAssertEqual(d, [.insert(possibleDuplicate: true)])
    }

    func testEditedVersionIsPossibleDuplicate() {
        let d = Merger.decide(existing: [ex(10, 1, .text, "ci vediamo alle 8")],
                              incoming: [inc(10, 1, .text, "ci vediamo alle 9", edited: true)])
        XCTAssertEqual(d, [.insert(possibleDuplicate: true)])
    }

    func testDifferentTextSameSecondIsPlainNew() {
        let d = Merger.decide(existing: [ex(10, 1, .text, "uno")], incoming: [inc(10, 1, .text, "due")])
        XCTAssertEqual(d, [.insert(possibleDuplicate: false)])
    }

    func testOmittedPlaceholderGetsLinked() {
        let d = Merger.decide(existing: [ex(10, 1, .photo)],
                              incoming: [inc(10, 1, .photo, name: "a.jpg", sourceHasFile: true)])
        XCTAssertEqual(d, [.link(existingID: 1)])
    }

    func testNamedWithoutFileGetsLinkedWhenFileArrives() {
        let d = Merger.decide(existing: [ex(10, 1, .photo, name: "a.jpg", hasFile: false)],
                              incoming: [inc(10, 1, .photo, name: "a.jpg", sourceHasFile: true)])
        XCTAssertEqual(d, [.link(existingID: 1)])
    }

    func testNamedWithFileIsPresent() {
        let d = Merger.decide(existing: [ex(10, 1, .photo, name: "a.jpg", hasFile: true)],
                              incoming: [inc(10, 1, .photo, name: "a.jpg", sourceHasFile: true)])
        XCTAssertEqual(d, [.present(existingID: 1)])
    }

    func testTwoDifferentNamedInSameSecond() {
        let d = Merger.decide(existing: [ex(10, 1, .photo, name: "a.jpg", hasFile: true)],
                              incoming: [inc(10, 1, .photo, name: "a.jpg", sourceHasFile: true),
                                         inc(10, 1, .photo, name: "b.jpg", sourceHasFile: true)])
        XCTAssertEqual(d, [.present(existingID: 1), .insert(possibleDuplicate: false)])
    }

    func testOmittedIncomingMatchesExistingNamed() {
        let d = Merger.decide(existing: [ex(10, 1, .video, name: "v.mp4", hasFile: true)],
                              incoming: [inc(10, 1, .video)])
        XCTAssertEqual(d, [.present(existingID: 1)])
    }

    func testNamedAndOmittedTogetherReimported() {
        // Nello stesso secondo: una foto con file e una omessa. Reimportando non cambia nulla.
        let e = [ex(10, 1, .photo, name: "a.jpg", hasFile: true), ex(10, 1, .photo)]
        let d = Merger.decide(existing: e, incoming: [inc(10, 1, .photo, name: "a.jpg", sourceHasFile: true),
                                                      inc(10, 1, .photo)])
        XCTAssertEqual(d, [.present(existingID: 1), .present(existingID: 2)])
    }

    func testDifferentMediaKindsDoNotMatch() {
        let d = Merger.decide(existing: [ex(10, 1, .photo)],
                              incoming: [inc(10, 1, .video, name: "v.mp4", sourceHasFile: true)])
        XCTAssertEqual(d, [.insert(possibleDuplicate: false)])
    }

    func testOrderOfDecisionsFollowsIncoming() {
        let e = [ex(10, 1, .text, "a"), ex(20, 2, .text, "b")]
        let d = Merger.decide(existing: e, incoming: [inc(20, 2, .text, "b"), inc(15, 1, .text, "x"), inc(10, 1, .text, "a")])
        XCTAssertEqual(d, [.present(existingID: 2), .insert(possibleDuplicate: false), .present(existingID: 1)])
    }
}
