import Foundation

/// The host-time playout clock MediaLink uses without an audio player, shared by video and audio.
///
/// The clock starts at the first sample that arrives. A sample that arrives later than its playout time (network
/// or server bursts) pushes the playout point back by its lateness, up to maximumDelay, so that the samples of a
/// burst are spread out by their timestamps instead of being presented at once. While every sample arrives early
/// the delay slowly shrinks back.
struct PlayoutClock {
    /// The upper bound of the playout delay that absorbs arrival jitter.
    static let maximumDelay: TimeInterval = 0.5
    /// The delay is lowered at most this much per adjustment interval, so that frames are not released in a burst.
    static let delayDecreaseStep: TimeInterval = 0.01
    static let delayAdjustmentInterval: TimeInterval = 1.0
    /// The headroom kept above the measured jitter when the delay is lowered.
    static let delayMargin: TimeInterval = 0.02

    private(set) var delay: TimeInterval = 0.0
    private var origin: (timestamp: TimeInterval, hostTime: TimeInterval)?
    private var minimumSlack: TimeInterval = .infinity
    private var adjustedAt: TimeInterval = 0.0

    /// The host time to present a sample with this timestamp at, or nil before the first sample.
    func hostTime(_ timestamp: TimeInterval) -> TimeInterval? {
        guard let origin else {
            return nil
        }
        return origin.hostTime + timestamp - origin.timestamp + delay
    }

    /// Records a sample arriving at host time `now` that must be handed over `lead` seconds before its playout time,
    /// and returns its playout host time.
    mutating func arrive(_ timestamp: TimeInterval, at now: TimeInterval, lead: TimeInterval = 0.0) -> TimeInterval {
        let origin = self.origin ?? (timestamp, now)
        if self.origin == nil {
            self.origin = origin
            adjustedAt = now
        }
        let slack = origin.hostTime + timestamp - origin.timestamp + delay - lead - now
        if slack < 0 {
            delay = min(delay - slack, Self.maximumDelay)
        } else {
            minimumSlack = min(minimumSlack, slack)
        }
        return origin.hostTime + timestamp - origin.timestamp + delay
    }

    /// Lowers the delay once per adjustment interval when every sample since the last adjustment arrived early.
    mutating func adjust(at now: TimeInterval) {
        guard origin != nil, Self.delayAdjustmentInterval <= now - adjustedAt else {
            return
        }
        if Self.delayMargin < minimumSlack && 0 < delay {
            delay = max(0, delay - min(minimumSlack - Self.delayMargin, Self.delayDecreaseStep))
        }
        minimumSlack = .infinity
        adjustedAt = now
    }

    mutating func reset() {
        self = .init()
    }
}
