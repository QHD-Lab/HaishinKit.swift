import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

final actor MediaLink {
    static let capacity = 90
    /// Decoded audio is handed to a player outside HaishinKit this long before its playout time, so that it can be scheduled.
    static let audioLead: TimeInterval = 0.05

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
    private var presentationTimeStampOrigin: CMTime = .invalid
    private lazy var displayLink = DisplayLinkChoreographer()
    private weak var audioPlayer: AudioPlayerNode? {
        didSet {
            clock.reset()
        }
    }
    /// Without an audio player video and audio are presented on this clock.
    private var clock = PlayoutClock()

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
        }
        if audioPlayer == nil {
            _ = clock.arrive(sampleBuffer.presentationTimeStamp.seconds, at: CACurrentMediaTime())
        }
        do {
            try storage?.enqueue(sampleBuffer)
        } catch {
            logger.error(error)
        }
    }

    /// The time to play decoded audio at, on the clock the video is presented on, for a player outside HaishinKit.
    /// The result carries the playout host time and the audio's own sample time. With an audio player it is `when` unchanged.
    func playoutTime(_ when: AVAudioTime, sampleRate: Double) -> AVAudioTime {
        guard isRunning, audioPlayer == nil, 0 < sampleRate, when.isSampleTimeValid || when.isHostTimeValid else {
            return when
        }
        let timestamp = when.isSampleTimeValid ? Double(when.sampleTime) / when.sampleRate : AVAudioTime.seconds(forHostTime: when.hostTime)
        let hostTime = clock.arrive(timestamp, at: CACurrentMediaTime(), lead: Self.audioLead)
        return AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: max(0, hostTime)), sampleTime: AVAudioFramePosition(timestamp * sampleRate), atRate: sampleRate)
    }

    func setAudioPlayer(_ audioPlayer: AudioPlayerNode?) {
        self.audioPlayer = audioPlayer
    }
}

extension MediaLink: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        displayLink.startRunning()
        Task {
            for await time in displayLink.updateFrames {
                guard let storage else {
                    continue
                }
                let audioTime = await audioPlayer?.currentTime
                if audioTime == nil {
                    clock.adjust(at: time.timestamp)
                }
                var frameCount = 0
                while !storage.isEmpty {
                    guard let first = storage.head else {
                        break
                    }
                    let isDue: Bool
                    if let audioTime {
                        isDue = first.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds <= audioTime
                    } else {
                        isDue = clock.hostTime(first.presentationTimeStamp.seconds) ?? 0 <= time.targetTimestamp
                    }
                    if isDue {
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
        clock.reset()
        try? storage?.reset()
        isRunning = false
    }
}
