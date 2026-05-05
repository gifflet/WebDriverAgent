// AudioFrameSocketSink.swift
// WebDriverAgentBroadcast
//
// Producer side of the runner↔extension IPC. Connects to the listener hosted
// by FBAudioBroadcastReceiver inside the WDA runner over TCP loopback
// (127.0.0.1:9201) and writes each 20 ms frame as `[8 bytes PTS BE][1920 bytes
// PCM LE]` (1928 B total).
//
// Backpressure model: writes are non-blocking; if the kernel buffer is full
// (i.e., the runner is slow) the frame is dropped. Audio realtime > completeness.
// Reconnection: on any write error, mark the socket dead; the next ingest call
// attempts a fresh connect. KISS — no exponential backoff inside the extension
// (the runner is local, and ReplayKit will tear down the extension if anything's
// genuinely wrong).
//
// Why TCP loopback rather than App Group Unix socket: XCTest UI Test Bundles
// don't honor `com.apple.security.application-groups`. iOS sandbox permits
// loopback connections by default; broadcast extensions are allowed outbound
// network access (proven in Zoom / Twilio / Discord production paths).

import Darwin
import Foundation

final class AudioFrameSocketSink {

    static let host: String = "127.0.0.1"
    static let defaultPort: UInt16 = 9201

    private var fd: Int32 = -1
    private let port: UInt16

    init() {
        if let envValue = ProcessInfo.processInfo.environment["AUDIO_IPC_PORT"],
           let parsed = UInt16(envValue), parsed > 0 {
            self.port = parsed
        } else {
            self.port = AudioFrameSocketSink.defaultPort
        }
    }

    deinit {
        closeFD()
    }

    /// Sink closure compatible with `AudioFrameProducer.AudioFrameSink`.
    func sink(pcm: Data, ptsMicroseconds: UInt64) {
        guard ensureConnected() else { return }

        var header = Data(count: 8)
        // Big-endian PTS, matching AUDIO-PIPELINE-CONTRACT.md §5.1.
        header[0] = UInt8((ptsMicroseconds >> 56) & 0xFF)
        header[1] = UInt8((ptsMicroseconds >> 48) & 0xFF)
        header[2] = UInt8((ptsMicroseconds >> 40) & 0xFF)
        header[3] = UInt8((ptsMicroseconds >> 32) & 0xFF)
        header[4] = UInt8((ptsMicroseconds >> 24) & 0xFF)
        header[5] = UInt8((ptsMicroseconds >> 16) & 0xFF)
        header[6] = UInt8((ptsMicroseconds >> 8)  & 0xFF)
        header[7] = UInt8( ptsMicroseconds        & 0xFF)

        let total = header + pcm
        let written = total.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ssize_t in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fd, base, raw.count, 0)
        }
        if written != total.count {
            // EAGAIN / disconnected / partial write -- treat as broken pipe and reset.
            NSLog("[GADSAudio.appex] send returned %ld (expected %d) errno=%d; closing fd", written, total.count, errno)
            closeFD()
        }
    }

    func close() {
        closeFD()
    }

    // MARK: -

    private func ensureConnected() -> Bool {
        if fd != -1 { return true }

        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 {
            NSLog("[GADSAudio.appex] socket() failed errno=%d", errno)
            return false
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian          // htons
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian  // 127.0.0.1

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(s, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            NSLog("[GADSAudio.appex] socket connect failed errno=%d", errno)
            Darwin.close(s)
            return false
        }

        // Non-blocking writes so a stalled runner can't block the extension producer.
        let flags = fcntl(s, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        }

        fd = s
        return true
    }

    private func closeFD() {
        if fd != -1 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
