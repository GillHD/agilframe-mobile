import Foundation

// MARK: - Limits

/// Stage 3b large-room profile: one room up to 200 participants.
public enum AgilLargeRoom {
    /// Maximum participants tracked for one room.
    public static let maxParticipants = 200
    /// Minimum churn (ids added + removed) before a resync snapshot is sent.
    public static let resyncMin = 32
    /// Minimum fraction of the room that must change before a resync snapshot.
    public static let resyncRatio = 0.5
}

/// Validated large-room limits used by ``AgilParticipantDigest``.
public struct AgilLargeRoomLimits: Equatable, Sendable {
    public let maxParticipants: Int
    public let resyncMin: Int
    public let resyncRatio: Double

    public init(
        maxParticipants: Int = AgilLargeRoom.maxParticipants,
        resyncMin: Int = AgilLargeRoom.resyncMin,
        resyncRatio: Double = AgilLargeRoom.resyncRatio
    ) {
        // Clamp instead of throwing: this is an SDK-side buffer limit, not a
        // server contract. The 200-participant profile is the hard ceiling.
        self.maxParticipants = min(AgilLargeRoom.maxParticipants, max(2, maxParticipants))
        self.resyncMin = min(10_000, max(1, resyncMin))
        self.resyncRatio = min(1, max(0, resyncRatio.isFinite ? resyncRatio : AgilLargeRoom.resyncRatio))
    }
}

// MARK: - Participant digest

public enum AgilParticipantUpdateKind: String, Equatable, Sendable {
    case snapshot
    case delta
    case summary
}

/// One compact participant update delivered to the host.
///
/// The widget's `agil:state` carries the full `participantIds` array; the SDK
/// keeps the canonical set and emits a single bounded `snapshot` per load plus
/// `delta` updates after that, never a 200-id payload on every tick.
public struct AgilParticipantUpdate: Equatable, Sendable {
    public let kind: AgilParticipantUpdateKind
    public let count: Int
    public let revision: Int
    public let added: [String]
    public let removed: [String]
    /// Present for `snapshot`: the full bounded id set.
    public let ids: [String]?
    /// True when the widget sent more ids than `maxParticipants`.
    public let truncated: Bool

    public init(
        kind: AgilParticipantUpdateKind,
        count: Int,
        revision: Int,
        added: [String] = [],
        removed: [String] = [],
        ids: [String]? = nil,
        truncated: Bool = false
    ) {
        self.kind = kind
        self.count = count
        self.revision = revision
        self.added = added
        self.removed = removed
        self.ids = ids
        self.truncated = truncated
    }
}

/// Stateful participant digest. Use one instance per document load.
public struct AgilParticipantDigest: Sendable {
    private let limits: AgilLargeRoomLimits
    private var orderedIds: [String] = []
    private var idSet: Set<String> = []
    private var count = 0
    private var revision = 0
    private var initialized = false

    public init(limits: AgilLargeRoomLimits = AgilLargeRoomLimits()) {
        self.limits = limits
    }

    public var participantCount: Int { count }
    public var currentRevision: Int { revision }
    public var ids: [String] { orderedIds }

    public mutating func reset() {
        orderedIds = []
        idSet = []
        count = 0
        revision = 0
        initialized = false
    }

    /// Applies one widget snapshot; returns `nil` when nothing changed.
    public mutating func apply(participantIds: [String]?, count explicitCount: Int?) -> AgilParticipantUpdate? {
        guard let rawIds = participantIds else {
            guard let explicitCount, explicitCount >= 0 else {
                return nil
            }
            if initialized && explicitCount == count {
                return nil
            }
            initialized = true
            count = explicitCount
            revision += 1
            return AgilParticipantUpdate(
                kind: .summary,
                count: explicitCount,
                revision: revision
            )
        }

        var nextOrdered: [String] = []
        var nextSet: Set<String> = []
        var truncated = false
        for raw in rawIds {
            if nextOrdered.count >= limits.maxParticipants {
                truncated = true
                break
            }
            guard let normalized = Self.normalizeId(raw), !nextSet.contains(normalized) else {
                continue
            }
            nextSet.insert(normalized)
            nextOrdered.append(normalized)
        }
        let nextCount = explicitCount ?? nextOrdered.count

        if !initialized {
            initialized = true
            orderedIds = nextOrdered
            idSet = nextSet
            count = nextCount
            revision = 1
            return AgilParticipantUpdate(
                kind: .snapshot,
                count: nextCount,
                revision: revision,
                added: nextOrdered,
                ids: nextOrdered,
                truncated: truncated
            )
        }

        var added: [String] = []
        var removed: [String] = []
        for id in nextOrdered where !idSet.contains(id) {
            added.append(id)
        }
        for id in orderedIds where !nextSet.contains(id) {
            removed.append(id)
        }
        if added.isEmpty && removed.isEmpty && nextCount == count && !truncated {
            return nil
        }

        let changed = added.count + removed.count
        let baseline = max(orderedIds.count, nextOrdered.count, 1)
        let shouldResync = changed >= limits.resyncMin
            && Double(changed) / Double(baseline) >= limits.resyncRatio

        orderedIds = nextOrdered
        idSet = nextSet
        count = nextCount
        revision += 1

        if shouldResync {
            return AgilParticipantUpdate(
                kind: .snapshot,
                count: nextCount,
                revision: revision,
                added: nextOrdered,
                ids: nextOrdered,
                truncated: truncated
            )
        }
        return AgilParticipantUpdate(
            kind: .delta,
            count: nextCount,
            revision: revision,
            added: added,
            removed: removed,
            truncated: truncated
        )
    }

    private static func normalizeId(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else {
            return nil
        }
        guard !AgilValidation.hasControlCharacters(trimmed) else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Connection digest

public enum AgilConnectionState: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnected
    case offline
    case closed
    case failed
    case unknown
}

/// Deduplicated connection/reconnect transition delivered to the host.
public struct AgilConnectionUpdate: Equatable, Sendable {
    public let state: AgilConnectionState
    public let previous: AgilConnectionState?
    public let reconnecting: Bool
    public let attempt: Int?
    public let delayMs: Int?

    public init(
        state: AgilConnectionState,
        previous: AgilConnectionState? = nil,
        reconnecting: Bool? = nil,
        attempt: Int? = nil,
        delayMs: Int? = nil
    ) {
        self.state = state
        self.previous = previous
        self.reconnecting = reconnecting ?? (state == .reconnecting)
        self.attempt = attempt
        self.delayMs = delayMs
    }

    /// Normalizes widget wire values (`open`/`new`/`reconnect`, ...).
    public static func normalize(_ value: String?) -> AgilConnectionState? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return nil
        case "idle": return .idle
        case "connecting", "new": return .connecting
        case "connected", "open": return .connected
        case "reconnecting", "reconnect": return .reconnecting
        case "disconnected": return .disconnected
        case "offline": return .offline
        case "closed": return .closed
        case "failed": return .failed
        default: return .unknown
        }
    }
}

public struct AgilConnectionDigest: Sendable {
    private var state: AgilConnectionState?
    private var attempt: Int?
    private var delayMs: Int?

    public init() {}

    public var currentState: AgilConnectionState? { state }

    public mutating func reset() {
        state = nil
        attempt = nil
        delayMs = nil
    }

    public mutating func apply(
        state rawState: String?,
        attempt rawAttempt: Int?,
        delayMs rawDelayMs: Int?
    ) -> AgilConnectionUpdate? {
        guard let next = AgilConnectionUpdate.normalize(rawState) else {
            return nil
        }
        let nextAttempt = rawAttempt.flatMap { $0 >= 0 ? $0 : nil }
        let nextDelay = rawDelayMs.flatMap { $0 >= 0 ? $0 : nil }
        if next == state && nextAttempt == attempt && nextDelay == delayMs {
            return nil
        }
        let previous = state
        state = next
        attempt = nextAttempt
        delayMs = nextDelay
        return AgilConnectionUpdate(
            state: next,
            previous: previous,
            attempt: nextAttempt,
            delayMs: nextDelay
        )
    }
}

// MARK: - Snapshot compaction

extension AgilCallSnapshot {
    /// Returns a copy with `participantIds` replaced. The view passes the
    /// bounded ids for the single snapshot and `[]` (known: false) for deltas.
    public func replacingParticipantIds(
        _ ids: [String],
        known: Bool = true,
        count: Int? = nil,
        revision: Int? = nil
    ) -> AgilCallSnapshot {
        return AgilCallSnapshot(
            phase: phase,
            participants: participants,
            participantIds: ids,
            qualityTier: qualityTier,
            qualityScore: qualityScore,
            connectionState: connectionState,
            recording: recording,
            minimized: minimized,
            chatMode: chatMode,
            fullscreen: fullscreen,
            layoutMode: layoutMode,
            microphoneEnabled: microphoneEnabled,
            cameraEnabled: cameraEnabled,
            screenSharing: screenSharing,
            blurMode: blurMode,
            panel: panel,
            participantCount: count,
            participantRevision: revision,
            hasParticipantIds: known,
            raw: raw
        )
    }

    /// Applies the shared compact-state convention to one widget snapshot.
    ///
    /// The compact state never carries ids, even for the single snapshot: hosts
    /// read the bounded set from `.participants`. The authoritative count and
    /// digest revision travel as `participantCount` / `participantRevision`,
    /// matching the JS `compactCallState` contract.
    public func compacting(participantUpdate update: AgilParticipantUpdate?) -> AgilCallSnapshot {
        return replacingParticipantIds(
            [],
            known: false,
            count: update?.count,
            revision: update?.revision
        )
    }
}
