import XCTest
@testable import AgilCallsSDK

final class AgilLargeRoomTests: XCTestCase {
    private func ids(_ count: Int, prefix: String = "p") -> [String] {
        return (0..<count).map { "\(prefix)-\($0)" }
    }

    func testLimitsDefaultTo200AndClamp() {
        XCTAssertEqual(AgilLargeRoom.maxParticipants, 200)
        XCTAssertEqual(AgilLargeRoomLimits().maxParticipants, 200)
        XCTAssertEqual(AgilLargeRoomLimits(maxParticipants: 5_000).maxParticipants, 200)
        XCTAssertEqual(AgilLargeRoomLimits(maxParticipants: 1).maxParticipants, 2)
    }

    func testFirstSnapshotThenDeltas() {
        var digest = AgilParticipantDigest()
        let snapshot = digest.apply(participantIds: ids(200), count: 200)
        XCTAssertEqual(snapshot?.kind, .snapshot)
        XCTAssertEqual(snapshot?.ids?.count, 200)
        XCTAssertEqual(snapshot?.revision, 1)

        let delta = digest.apply(participantIds: ids(199) + ["newcomer"], count: 200)
        XCTAssertEqual(delta?.kind, .delta)
        XCTAssertEqual(delta?.added, ["newcomer"])
        XCTAssertEqual(delta?.removed, ["p-199"])
        XCTAssertNil(digest.apply(participantIds: ids(199) + ["newcomer"], count: 200))
    }

    func testLargeChurnResyncsAndOversizedInputTruncates() {
        var digest = AgilParticipantDigest()
        _ = digest.apply(participantIds: ids(40), count: 40)
        let resync = digest.apply(participantIds: ids(20) + ids(20, prefix: "q"), count: 40)
        XCTAssertEqual(resync?.kind, .snapshot)
        XCTAssertEqual(resync?.ids?.count, 40)

        var oversized = AgilParticipantDigest()
        let update = oversized.apply(participantIds: ids(260), count: 260)
        XCTAssertEqual(update?.ids?.count, 200)
        XCTAssertEqual(update?.truncated, true)
        XCTAssertEqual(update?.count, 260)
    }

    func testCountOnlySnapshotIsSummary() {
        var digest = AgilParticipantDigest()
        let first = digest.apply(participantIds: nil, count: 180)
        XCTAssertEqual(first?.kind, .summary)
        XCTAssertNil(digest.apply(participantIds: nil, count: 180))
        XCTAssertEqual(digest.apply(participantIds: nil, count: 179)?.count, 179)
    }

    func testConnectionDigestDeduplicatesReconnect() {
        var digest = AgilConnectionDigest()
        XCTAssertEqual(digest.apply(state: "connected", attempt: nil, delayMs: nil)?.state, .connected)
        let reconnecting = digest.apply(state: "reconnecting", attempt: 2, delayMs: 1_000)
        XCTAssertEqual(reconnecting?.reconnecting, true)
        XCTAssertEqual(reconnecting?.attempt, 2)
        XCTAssertNil(digest.apply(state: "reconnecting", attempt: 2, delayMs: 1_000))
        let back = digest.apply(state: "connected", attempt: nil, delayMs: nil)
        XCTAssertEqual(back?.previous, .reconnecting)
        XCTAssertEqual(AgilConnectionUpdate.normalize("OPEN"), .connected)
    }

    func testSnapshotCompactionCanDropParticipantIds() {
        let snapshot = AgilCallSnapshot(phase: "joined", participants: 200, participantIds: ids(200), hasParticipantIds: true)
        var digest = AgilParticipantDigest()
        let first = digest.apply(participantIds: ids(200), count: 200)
        let compact = snapshot.compacting(participantUpdate: first)
        XCTAssertTrue(compact.participantIds.isEmpty)
        XCTAssertFalse(compact.hasParticipantIds)
        XCTAssertEqual(compact.participants, 200)
        XCTAssertEqual(compact.participantCount, 200)
        XCTAssertEqual(compact.participantRevision, 1)

        let delta = digest.apply(participantIds: ids(199) + ["newcomer"], count: 200)
        let deltaState = snapshot.compacting(participantUpdate: delta)
        XCTAssertTrue(deltaState.participantIds.isEmpty)
        XCTAssertEqual(deltaState.participantCount, 200)
        XCTAssertEqual(deltaState.participantRevision, 2)

        let unchanged = digest.apply(participantIds: ids(199) + ["newcomer"], count: 200)
        XCTAssertNil(unchanged)
        let unchangedState = snapshot.compacting(participantUpdate: unchanged)
        XCTAssertNil(unchangedState.participantCount)
        XCTAssertNil(unchangedState.participantRevision)
    }

    func testConfigurationValidatesAndPreservesMaxParticipants() throws {
        let config = try AgilCallConfiguration(
            serverURL: "https://calls.example.com",
            roomId: "large-room",
            joinToken: "token-1",
            identityToken: "identity-1",
            maxParticipants: 200
        )
        XCTAssertEqual(config.maxParticipants, 200)
        XCTAssertEqual(config.joinToken, "token-1")
        XCTAssertEqual(config.identityToken, "identity-1")
        XCTAssertEqual(config.widgetOrigin, "https://calls.example.com")

        XCTAssertThrowsError(try AgilCallConfiguration(
            serverURL: "https://calls.example.com",
            roomId: "large-room",
            maxParticipants: 201
        ))
        XCTAssertThrowsError(try AgilCallConfiguration(
            serverURL: "https://calls.example.com",
            roomId: "large-room",
            maxParticipants: 1
        ))
    }
}
