/**
 * FBAudioWebSocketClient
 *
 * WebSocket client that forwards 20 ms PCM frames from the broadcast extension
 * (via FBAudioBroadcastReceiver) to the GADS provider. The provider encodes
 * Opus and pushes to the WebRTC track.
 *
 * Wire format (matches Android, AUDIO-PIPELINE-CONTRACT.md §5.1):
 *
 *     [8 bytes PTS big-endian µs][1920 bytes PCM little-endian]
 *
 * Sent as a single binary WebSocket message.
 *
 * Implementation: built on `NSURLSessionWebSocketTask` (iOS 13+) — zero
 * external dependencies. Reconnect with exponential backoff (1s → 30s, capped
 * at 5 attempts). Frames sent while disconnected are dropped — audio realtime
 * > completeness, matching the rest of the pipeline.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBAudioWebSocketClient : NSObject

/// Process-wide instance. The audio path is single-producer single-consumer so
/// a singleton is the right shape here.
+ (instancetype)sharedClient;

/// Connect to `ws://host:port/`. Idempotent: a second call with new endpoint
/// disconnects the prior task and starts again.
- (void)connectToHost:(NSString *)host port:(uint16_t)port;

/// Build `[PTS BE 8B][pcmFrame]` and ship as a binary message. No-op if not connected.
- (void)sendFrame:(NSData *)pcmFrame pts:(uint64_t)pts;

/// Cancel the current task and clear the endpoint. Future `sendFrame:` calls drop.
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
