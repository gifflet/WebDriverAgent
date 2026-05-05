// AudioFrameProducer.swift
// WebDriverAgentBroadcast
//
// Resamples ReplayKit AudioApp sample buffers to 48 kHz mono signed 16-bit
// little-endian PCM, packs into 20 ms (960-sample / 1920-byte) frames, and
// emits each frame to a sink closure with a monotonic microsecond PTS.
//
// Isolated from ReplayKit so it can be unit-tested by feeding raw AVAudioPCMBuffers.
//
// Wire format target — AUDIO-PIPELINE-CONTRACT.md §5.2:
//   48 000 Hz, mono, 16-bit signed PCM, little-endian, 960 samples / 1920 B per frame.

import AVFoundation
import CoreMedia
import QuartzCore

/// Sink for completed 20 ms PCM frames.
/// `pcm` is exactly 1920 bytes (960 × Int16 LE).
/// `ptsMicroseconds` is a monotonic timestamp in microseconds for the first sample of the frame.
typealias AudioFrameSink = (_ pcm: Data, _ ptsMicroseconds: UInt64) -> Void

final class AudioFrameProducer {

    // MARK: Constants

    static let outputSampleRate: Double = 48_000
    static let outputChannels: UInt32 = 1
    static let samplesPerFrame: Int = 960          // 20 ms at 48 kHz
    static let bytesPerFrame: Int = samplesPerFrame * MemoryLayout<Int16>.size  // 1920

    // MARK: State

    private let sink: AudioFrameSink
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat
    /// Accumulates LE Int16 samples until we have ≥ samplesPerFrame to emit.
    private var accumulator = Data()
    /// PTS in microseconds for the *next* sample sitting at the head of `accumulator`.
    private var nextFramePTS: UInt64 = 0

    // MARK: Init

    init(sink: @escaping AudioFrameSink) {
        self.sink = sink
        self.outputFormat = AudioFrameProducer.makeOutputFormat()
    }

    // MARK: Lifecycle

    func reset() {
        accumulator.removeAll(keepingCapacity: true)
        converter = nil
        sourceFormat = nil
        nextFramePTS = 0
    }

    // MARK: Public ingest

    /// Feed an AudioApp `CMSampleBuffer` from `processSampleBuffer:withType:`.
    /// Safe to call from the ReplayKit delivery thread; not reentrant.
    func ingest(sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = AudioFrameProducer.makePCMBuffer(from: sampleBuffer) else { return }
        ingest(pcmBuffer: pcmBuffer)
    }

    /// Test seam — feed an AVAudioPCMBuffer directly (skips CMSampleBuffer extraction).
    func ingest(pcmBuffer: AVAudioPCMBuffer) {
        guard ensureConverter(for: pcmBuffer.format) else { return }
        guard let converter = converter else { return }

        // Output capacity sized for worst-case upsample ratio (48000/8000 = 6×) plus slack.
        let ratio = outputFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return pcmBuffer
        }

        guard status == .haveData || status == .inputRanDry else {
            // .endOfStream / .error — keep going; ReplayKit will deliver more buffers.
            return
        }

        appendOutput(outputBuffer)
        emitReadyFrames()
    }

    // MARK: - Internals

    private static func makeOutputFormat() -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            // Note: absence of kAudioFormatFlagIsBigEndian == little-endian on all Apple platforms.
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        // Force-unwrap is fine: ASBD above is valid Linear PCM.
        return AVAudioFormat(streamDescription: &asbd)!
    }

    private func ensureConverter(for incoming: AVAudioFormat) -> Bool {
        if let existing = sourceFormat, formatsEqual(existing, incoming), converter != nil {
            return true
        }
        guard let converter = AVAudioConverter(from: incoming, to: outputFormat) else {
            return false
        }
        self.converter = converter
        self.sourceFormat = incoming
        return true
    }

    private func formatsEqual(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        let aDesc = a.streamDescription.pointee
        let bDesc = b.streamDescription.pointee
        return aDesc.mSampleRate == bDesc.mSampleRate
            && aDesc.mChannelsPerFrame == bDesc.mChannelsPerFrame
            && aDesc.mBitsPerChannel == bDesc.mBitsPerChannel
            && aDesc.mFormatFlags == bDesc.mFormatFlags
            && aDesc.mFormatID == bDesc.mFormatID
    }

    private func appendOutput(_ buffer: AVAudioPCMBuffer) {
        guard let int16 = buffer.int16ChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        // Channel 0 only — outputFormat is mono.
        let byteCount = frames * MemoryLayout<Int16>.size
        accumulator.append(Data(bytes: int16[0], count: byteCount))
    }

    private func emitReadyFrames() {
        let bytesPerFrame = AudioFrameProducer.bytesPerFrame
        while accumulator.count >= bytesPerFrame {
            // Sample PTS at the moment we're about to emit. Drift between capture
            // and emit is bounded by accumulator depth (< 1 frame = 20 ms).
            let pts: UInt64
            if nextFramePTS == 0 {
                pts = currentMonotonicMicroseconds()
            } else {
                pts = nextFramePTS
            }
            nextFramePTS = pts &+ 20_000  // 20 ms in µs, monotonic step.

            let frame = accumulator.prefix(bytesPerFrame)
            sink(Data(frame), pts)
            accumulator.removeFirst(bytesPerFrame)
        }
    }

    private func currentMonotonicMicroseconds() -> UInt64 {
        // CACurrentMediaTime() is mach_absolute_time scaled to seconds; monotonic.
        UInt64(CACurrentMediaTime() * 1_000_000)
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }
        return buffer
    }
}
