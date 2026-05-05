# Extension ↔ Runner IPC

The Broadcast Upload Extension and the WDA test-runner process talk over **TCP loopback** (`127.0.0.1:9201`). Same wire format as the runner→provider WebSocket — single framing across the whole chain (KISS).

## Endpoints

| Side | Role | File |
|---|---|---|
| Producer (extension) | `connect()` and write frames | `WebDriverAgentBroadcast/AudioFrameSocketSink.swift` |
| Consumer (runner)   | `bind()`, `listen()`, `accept()`, read frames | `WebDriverAgentLib/Utilities/FBAudioBroadcastReceiver.{h,m}` |

## Transport

- **AF_INET / SOCK_STREAM**, bound to `INADDR_LOOPBACK` (`127.0.0.1`) only.
- **Default port: `9201`** (chosen to avoid clashes with WDA HTTP `8100`, MJPEG `9100`, audio-from-provider `9200`).
- **Override:** `AUDIO_IPC_PORT` environment variable (read by both ends).
- **`SO_REUSEADDR`** on the listener so a stale `TIME_WAIT` from a prior crash doesn't block re-bind.

The producer (extension) is non-blocking; if a write would block (kernel buffer full, runner slow, runner not yet listening), the FD is closed and the next ingest attempts a fresh connect. Audio realtime > completeness.

## Wire format (per frame, 1928 bytes)

```
+----------------------+--------------------------------+
| 8 B PTS, big-endian  | 1920 B PCM (Int16 LE, mono)    |
| µs, monotonic        | 960 samples = 20 ms @ 48 kHz   |
+----------------------+--------------------------------+
```

Identical to the runner→provider WebSocket payload (`AUDIO-PIPELINE-CONTRACT.md` §5.1). The runner therefore does **not** rewrite framing — it forwards the bytes straight through (task #7).

## Lifecycle

1. **Runner startup** (`FBWebServer startServing`) → `initAudioBroadcastReceiverGads` → bind 127.0.0.1:9201 + listen.
2. **Extension start** (`broadcastStarted(withSetupInfo:)`) → `AudioFrameSocketSink.init` reads the port; first `sink(pcm:pts:)` triggers `connect()`.
3. **Streaming**: extension writes 1928-byte frames non-blocking; runner reads exact 1928-byte frames in a loop, fires delegate.
4. **Reconnection**: if the extension restarts (user re-toggles the picker), it `connect()`s again. The runner's `acceptLoop` closes any prior client FD and accepts the new one — single-producer model.
5. **Runner shutdown** (`stopServing`) → `stop` closes both ends.

## Backpressure

- **Producer:** non-blocking `send()`. If the kernel buffer fills (runner is slow), the partial-write branch closes the FD; the next frame attempts a fresh connect. Effectively drops frames on congestion.
- **Consumer:** delegate runs on the receiver's serial queue. If the delegate blocks, the kernel write queue backs up, which propagates to the producer-side drop above. KISS; no explicit ring buffer.

## Memory

- Producer: 1928-byte working buffer per send; no accumulation past one frame.
- Consumer: 1928-byte stack buffer per read; one `NSData` allocation per delivered frame (delegate retains/releases as needed).

Well within the extension's 50 MB hard limit.

## Sandbox / entitlements

**No special entitlements required.** iOS sandbox permits:
- Loopback connections from any process by default.
- Outbound network from broadcast extensions (proven in production by Zoom, Twilio, Discord).

## Removed: App Group dependency (history)

An earlier iteration used a Unix domain socket inside the App Group container `group.io.gads.wda-audio`. Gui's runtime testing confirmed that **XCTest UI Test Bundles do not honor `com.apple.security.application-groups`** — the runner could not see the shared container, so the extension's writes had no listener. Mitigation candidates considered:

- `/tmp` shared path → rejected (`/tmp` is per-process-sandbox on iOS, not cross-process).
- Sidecar app routing through IntegrationApp → rejected (would need its own App Group capability, same problem one hop away).
- TCP loopback → **chosen.** No entitlements, well-trodden in production broadcast extensions.

The migration is internal to WDA: the runner→provider WebSocket framing is unchanged, so the provider has no awareness of the change.
