import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct AudioCodecTests {
    @Test func aac_44100hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 44100)
    }

    @Test func aac_48000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(48000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 48000)
    }

    @Test func aac_24000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(24000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 24000)
    }

    @Test func aac_16000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(16000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 16000)
    }

    @Test func aac_8000hz_step_256() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(8000.0, numSamples: 256) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 8000)
    }

    @Test func aac_8000hz_step_960() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(8000.0, numSamples: 960) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 8000)
    }

    @Test func aac_44100hz_step_1224() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1224) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
    }

    @Test func aac_1_channel_to_2_channel() {
        let encoder = HaishinKit.AudioCodec()
        encoder.settings = .init(downmix: false, channelMap: [0, 0])
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.channelCount == 2)
    }

    @Test func aac_44100_any_steps() {
        let numSamples: [Int] = [1024, 1024, 1028, 1024, 1028, 1028, 962, 962, 960, 2237, 2236]
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for numSample in numSamples {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: numSample) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 44100)
    }

    @Test func test3Channel_withoutCrash() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        if let sampleBuffer = CMAudioSampleBufferFactory.makeSilence(44100, numSamples: 256, channels: 3) {
            encoder.append(sampleBuffer)
        }
    }

    @Test func pcm_dropsMalformedFramesWithoutCrash() throws {
        // Shorter than an ADTS header, and longer than any AAC frame.
        let decoder = try Self.decoder()
        decoder.append(try Self.aacSampleBuffer(channels: 1, sampleSizes: [3, 4096]))
    }

    @Test func pcm_acceptsStereoFrameOver1024BytesWithoutCrash() throws {
        let decoder = try Self.decoder()
        decoder.append(try Self.aacSampleBuffer(channels: 2, sampleSizes: [1500]))
    }

    @Test func compressedBufferCopy_refusesLargerBuffer() throws {
        let format = AVAudioFormat(cmAudioFormatDescription: try Self.aacFormatDescription(channels: 1))
        let source = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 4096)
        source.byteLength = 4096
        let destination = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 1024)
        #expect(!destination.copy(source))
    }

    /// One MPEG-TS PES carries several ADTS frames under one 90 kHz timestamp: each decoded frame must play 1024 samples
    /// at 48 kHz after the previous one, so that a player scheduling by time neither overlaps nor drops them.
    @Test func pcm_timesEachFrameOfAPESBySampleRate() async throws {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        let encoded = encoder.outputStream
        for _ in 0..<20 {
            if let buffer = AVAudioPCMBufferFactory.makeSinWave(48000, numSamples: 1024) {
                encoder.append(buffer, when: .init())
            }
        }
        encoder.stopRunning()
        var frames: [Data] = []
        for await (buffer, _) in encoded {
            guard let buffer = buffer as? AVAudioCompressedBuffer, buffer.packetCount == 1 else {
                continue
            }
            frames.append(Data(bytes: buffer.data, count: Int(buffer.byteLength)))
        }
        let count = 8
        try #require(count <= frames.count)

        let decoder = try Self.decoder()
        let decoded = decoder.outputStream
        let start = CMTime(value: 900_000, timescale: 90_000)
        decoder.append(try Self.aacSampleBuffer(frames: Array(frames.prefix(count)), sampleFrequencyIndex: 3, presentationTimeStamp: start))
        decoder.stopRunning()
        var output: [(time: Double, duration: Double)] = []
        for await (buffer, when) in decoded {
            guard let buffer = buffer as? AVAudioPCMBuffer else {
                continue
            }
            output.append((Double(when.sampleTime) / when.sampleRate, Double(buffer.frameLength) / buffer.format.sampleRate))
        }
        #expect(output.count == count)
        for (i, frame) in output.enumerated() {
            #expect(abs(frame.time - (10 + Double(i) * 1024 / 48000)) < 1e-9, "frame \(i)")
        }
        for i in 1..<output.count {
            #expect(abs(output[i].time - (output[i - 1].time + output[i - 1].duration)) < 1e-9, "frame \(i)")
        }
    }

    private static func decoder() throws -> HaishinKit.AudioCodec {
        let decoder = HaishinKit.AudioCodec()
        decoder.settings.format = .pcm
        decoder.startRunning()
        return decoder
    }

    /// ADTS header of AAC LC; sampling frequency index 4 is 44.1 kHz, 3 is 48 kHz.
    private static func adtsHeader(channels: UInt8, sampleFrequencyIndex: UInt8 = 4) -> Data {
        Data([0xFF, 0xF1, 0x40 | sampleFrequencyIndex << 2, channels << 6, 0x00, 0x1F, 0xFC])
    }

    private static func aacFormatDescription(channels: UInt8, sampleFrequencyIndex: UInt8 = 4) throws -> CMFormatDescription {
        try #require(ADTSHeader(data: adtsHeader(channels: channels, sampleFrequencyIndex: sampleFrequencyIndex)).makeFormatDescription())
    }

    /// Mono ADTS frames in one sample buffer with one timestamp, the way a PES arrives from MPEG-TS.
    private static func aacSampleBuffer(frames: [Data], sampleFrequencyIndex: UInt8, presentationTimeStamp: CMTime) throws -> CMSampleBuffer {
        let header = adtsHeader(channels: 1, sampleFrequencyIndex: sampleFrequencyIndex)
        var sampleSizes = frames.map { header.count + $0.count }
        let blockBuffer = try #require(frames.reduce(into: Data()) { $0 += header + $1 }.makeBlockBuffer())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try aacFormatDescription(channels: 1, sampleFrequencyIndex: sampleFrequencyIndex),
            sampleCount: frames.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: sampleSizes.count,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        #expect(status == noErr)
        return try #require(sampleBuffer)
    }

    private static func aacSampleBuffer(channels: UInt8, sampleSizes: [Int]) throws -> CMSampleBuffer {
        var sampleSizes = sampleSizes
        let blockBuffer = try #require(Data(count: sampleSizes.reduce(0, +)).makeBlockBuffer())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try aacFormatDescription(channels: channels),
            sampleCount: sampleSizes.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: sampleSizes.count,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        #expect(status == noErr)
        return try #require(sampleBuffer)
    }
}
