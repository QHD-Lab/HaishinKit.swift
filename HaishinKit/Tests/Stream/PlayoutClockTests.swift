import Foundation
import Testing

@testable import HaishinKit

@Suite struct PlayoutClockTests {
    private static let audioLead = 0.05
    private static let tick = 1.0 / 60

    /// Plays 25 fps video and 20 ms audio packets that arrive in 0.4 s bursts until `burstsUntil`, then arrive smoothly
    /// 20 ms after their timestamps, on a 60 Hz display link the way MediaLink does. The first packets arrive only 0.1 s
    /// late (joining in the middle of a burst), so the later bursts, 0.4 s late, must push the delay back.
    private struct Run {
        var videoAt: [Int: TimeInterval] = [:]
        var audioAt: [Int: TimeInterval] = [:]
        var framesPerTick: [(time: TimeInterval, count: Int)] = []
        var audioSlack: [(timestamp: TimeInterval, slack: TimeInterval)] = []
        var maximumDelay: TimeInterval = 0
        var delay: TimeInterval = 0
    }

    private func run(burstsUntil: TimeInterval, until end: TimeInterval) -> Run {
        let host = 1000.0
        func arrival(_ timestamp: TimeInterval) -> TimeInterval {
            timestamp < burstsUntil ? min(floor((timestamp + 0.3) / 0.4) * 0.4 + 0.1, burstsUntil) : timestamp + 0.02
        }
        var events: [(arrival: TimeInterval, timestamp: TimeInterval, isVideo: Bool, index: Int)] = []
        for i in 0..<Int(end * 25) {
            events.append((arrival(Double(i) / 25), Double(i) / 25, true, i))
        }
        for i in 0..<Int(end * 50) {
            events.append((arrival(Double(i) / 50), Double(i) / 50, false, i))
        }
        events.sort { ($0.arrival, $0.timestamp) < ($1.arrival, $1.timestamp) }

        var clock = PlayoutClock()
        var result = Run()
        var pending: [(timestamp: TimeInterval, index: Int)] = []
        var next = 0
        var now = host
        while now < host + end + 1 {
            while next < events.count && host + events[next].arrival <= now {
                let event = events[next]
                if event.isVideo {
                    _ = clock.arrive(event.timestamp, at: host + event.arrival)
                    pending.append((event.timestamp, event.index))
                } else {
                    let playAt = clock.arrive(event.timestamp, at: host + event.arrival, lead: Self.audioLead)
                    result.audioSlack.append((event.timestamp, playAt - Self.audioLead - (host + event.arrival)))
                    if event.index % 50 == 0 {
                        result.audioAt[event.index / 50] = playAt
                    }
                }
                result.maximumDelay = max(result.maximumDelay, clock.delay)
                next += 1
            }
            clock.adjust(at: now)
            let target = now + Self.tick
            var count = 0
            while let first = pending.first, let playAt = clock.hostTime(first.timestamp), playAt <= target {
                if first.index % 25 == 0 {
                    result.videoAt[first.index / 25] = target
                }
                pending.removeFirst()
                count += 1
            }
            result.framesPerTick.append((now - host, count))
            now += Self.tick
        }
        result.delay = clock.delay
        return result
    }

    @Test func burstsArePresentedEvenly() {
        let run = run(burstsUntil: 20, until: 20)
        #expect(run.maximumDelay <= PlayoutClock.maximumDelay)
        // After the first bursts set the delay, no tick presents more than one frame.
        #expect(run.framesPerTick.filter { 2 < $0.time && 1 < $0.count }.isEmpty)
        // And every audio packet reaches the player at least audioLead before it plays.
        #expect(run.audioSlack.filter { 2 < $0.timestamp && $0.slack < -1e-9 }.isEmpty)
    }

    @Test func audioAndVideoMarkersPlayTogether() {
        let run = run(burstsUntil: 20, until: 80)
        for second in 2..<79 {
            guard let video = run.videoAt[second], let audio = run.audioAt[second] else {
                Issue.record("missing marker \(second)")
                continue
            }
            // A frame waits at most one display tick; the delay may have been lowered by one step in between.
            #expect(abs(video - audio) <= Self.tick + PlayoutClock.delayDecreaseStep + 1e-9, "marker \(second)")
        }
    }

    @Test func delayShrinksWhenArrivalSmoothsOut() {
        let run = run(burstsUntil: 20, until: 80)
        #expect(0.3 < run.maximumDelay)
        // Smooth arrival 20 ms late needs audioLead + 20 ms, plus the margin kept above it.
        #expect(run.delay < Self.audioLead + 0.02 + PlayoutClock.delayMargin + PlayoutClock.delayDecreaseStep + 1e-9)
        #expect(run.framesPerTick.filter { 2 < $0.time && 1 < $0.count }.isEmpty)
        #expect(run.audioSlack.filter { 2 < $0.timestamp && $0.slack < -1e-9 }.isEmpty)
    }

    @Test func delayIsCappedAndReset() {
        var clock = PlayoutClock()
        #expect(clock.hostTime(0) == nil)
        _ = clock.arrive(10, at: 100)
        #expect(abs(clock.arrive(10.04, at: 101.5) - (100.04 + PlayoutClock.maximumDelay)) < 1e-9)
        #expect(clock.delay == PlayoutClock.maximumDelay)
        clock.reset()
        #expect(clock.delay == 0)
        #expect(clock.hostTime(10) == nil)
    }
}
