//
//  SampleHandler.swift
//  WebDriverAgentBroadcast
//
//  Created by Guilherme Silva Sousa on 27/04/26.
//  Copyright © 2026 Facebook. All rights reserved.
//
//  Broadcast Upload Extension principal class. Filters AudioApp sample buffers,
//  hands them to AudioFrameProducer (resample → 48 kHz mono LE → 20 ms frames),
//  and sends each frame to the WDA runner via TCP loopback (127.0.0.1:9201).
//
//  PRD §RF01, AUDIO-PIPELINE-CONTRACT.md §5.

import Darwin
import ReplayKit

/// Must match `FBGadsAudioBroadcastShouldStopNotification` in FBGadsCommands.m.
private let broadcastShouldStopNotification = "io.gads.wda.audio.broadcastShouldStop"

class SampleHandler: RPBroadcastSampleHandler {

    private var producer: AudioFrameProducer?
    private var socketSink: AudioFrameSocketSink?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let sink = AudioFrameSocketSink()
        self.socketSink = sink
        producer = AudioFrameProducer { pcm, pts in
            sink.sink(pcm: pcm, ptsMicroseconds: pts)
        }

        // Listen for the runner's stop signal and end the broadcast cleanly.
        // Darwin notifications are global (not gated by App Groups) -- they're
        // the only public way to wake an extension from another process.
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            me,
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                NSLog("[GADSAudio.appex] received broadcastShouldStop; calling finishBroadcastWithError")
                DispatchQueue.main.async {
                    handler.finishBroadcastWithError(NSError(
                        domain: "io.gads.wda.audio",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "GADS session ended"]
                    ))
                }
            },
            broadcastShouldStopNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    override func broadcastPaused() {
        // Drop in-flight frames; converter state can stay so we don't reallocate on resume.
    }

    override func broadcastResumed() {
        // No-op.
    }

    override func broadcastFinished() {
        NSLog("[GADSAudio.appex] broadcastFinished")
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            me,
            CFNotificationName(broadcastShouldStopNotification as CFString),
            nil
        )
        producer?.reset()
        producer = nil
        socketSink?.close()
        socketSink = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            producer?.ingest(sampleBuffer: sampleBuffer)
        case .audioMic, .video:
            // v1: AudioApp only (PRD §RF01).
            break
        @unknown default:
            break
        }
    }
}
