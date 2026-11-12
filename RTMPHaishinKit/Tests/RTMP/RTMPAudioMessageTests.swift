import AVFoundation
import Foundation
@testable import RTMPHaishinKit
import Testing

@Suite struct RTMPAudioMessageTests {
    /// Messages handled back to back before the decoder reads them: each frame must stay intact.
    @Test func makeAudioBuffer_keepsEachFrame() throws {
        let format = try #require(AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2
        ]))
        let frames = (0..<3).map { i in Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &+ i * 7) }) }
        let messages = try frames.map { frame in
            let source = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: frame.count)
            frame.withUnsafeBytes { source.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
            source.byteLength = UInt32(frame.count)
            return try #require(RTMPAudioMessage(streamId: 1, timestamp: 0, audioBuffer: source))
        }
        let buffers = messages.map { $0.makeAudioBuffer(format) }
        for (frame, buffer) in zip(frames, buffers) {
            #expect(buffer.packetCount == 1)
            #expect(buffer.packetDescriptions?.pointee.mDataByteSize == UInt32(frame.count))
            #expect(Data(bytes: buffer.data, count: Int(buffer.byteLength)) == frame)
        }
    }
}
