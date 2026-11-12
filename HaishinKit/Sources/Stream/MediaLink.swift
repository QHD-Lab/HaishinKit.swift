import CoreMedia
import Foundation

final actor MediaLink {
    static let capacity = 90
    static let duration: TimeInterval = 0.0
    /// The upper bound of the playout delay that absorbs arrival jitter.
    static let maximumDelay: TimeInterval = 0.5
    /// The delay is lowered at most this much per adjustment interval, so that frames are not released in a burst.
    static let delayDecreaseStep: TimeInterval = 0.01
    static let delayAdjustmentInterval: TimeInterval = 1.0
    /// The headroom kept above the measured jitter when the delay is lowered.
    static let delayMargin: TimeInterval = 0.02

    var dequeue: AsyncStream<CMSampleBuffer> {
        AsyncStream { continutation in
            self.continutation = continutation
        }
    }
    private(set) var isRunning = false
    private var storage: TypedBlockQueue<CMSampleBuffer>?
    private var continutation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var duration: TimeInterval = MediaLink.duration
    private var presentationTimeStampOrigin: CMTime = .invalid
    private lazy var displayLink = DisplayLinkChoreographer()
    private weak var audioPlayer: AudioPlayerNode? {
        didSet {
            delay = 0.0
        }
    }
    /// Without an audio player frames are presented on a free-running clock that starts at the first frame.
    /// Frames arriving late (network or server bursts) push the playout point back by their lateness, up to
    /// maximumDelay, so that the frames of a burst are spread out by their timestamps instead of being
    /// presented at once. While every frame arrives early the delay slowly shrinks back.
    private var delay: TimeInterval = 0.0
    private var minimumSlack: TimeInterval = .infinity
    private var delayAdjustedAt: TimeInterval = 0.0

    init() {
        do {
            storage = try .init(capacity: Self.capacity, handlers: .outputPTSSortedSampleBuffers)
        } catch {
            logger.error(error)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        if presentationTimeStampOrigin == .invalid {
            presentationTimeStampOrigin = sampleBuffer.presentationTimeStamp
            if audioPlayer == nil {
                duration = 0.0
                delayAdjustedAt = 0.0
            }
        }
        if audioPlayer == nil {
            let slack = sampleBuffer.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds + delay - duration
            if slack < 0 {
                delay = min(delay - slack, Self.maximumDelay)
            } else {
                minimumSlack = min(minimumSlack, slack)
            }
        }
        do {
            try storage?.enqueue(sampleBuffer)
        } catch {
            logger.error(error)
        }
    }

    func setAudioPlayer(_ audioPlayer: AudioPlayerNode?) {
        self.audioPlayer = audioPlayer
    }

    private func getCurrentTime(_ timestamp: TimeInterval) async -> TimeInterval {
        defer {
            duration += timestamp
        }
        return await audioPlayer?.currentTime ?? duration
    }
}

extension MediaLink: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        duration = 0.0
        displayLink.startRunning()
        Task {
            for await currentTime in displayLink.updateFrames {
                guard let storage else {
                    continue
                }
                let currentTime = await getCurrentTime(currentTime.targetTimestamp - currentTime.timestamp)
                if Self.delayAdjustmentInterval <= currentTime - delayAdjustedAt {
                    if Self.delayMargin < minimumSlack && 0 < delay {
                        delay = max(0, delay - min(minimumSlack - Self.delayMargin, Self.delayDecreaseStep))
                    }
                    minimumSlack = .infinity
                    delayAdjustedAt = currentTime
                }
                var frameCount = 0
                while !storage.isEmpty {
                    guard let first = storage.head else {
                        break
                    }
                    if first.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds + delay <= currentTime {
                        continutation?.yield(first)
                        frameCount += 1
                        _ = storage.dequeue()
                    } else {
                        if 2 < frameCount {
                            logger.info("droppedFrame: \(frameCount)")
                        }
                        break
                    }
                }
            }
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        continutation = nil
        displayLink.stopRunning()
        presentationTimeStampOrigin = .invalid
        delay = 0.0
        minimumSlack = .infinity
        try? storage?.reset()
        isRunning = false
    }
}
