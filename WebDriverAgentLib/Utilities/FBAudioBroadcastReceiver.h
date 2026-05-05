/**
 * FBAudioBroadcastReceiver
 *
 * Listens on TCP loopback (127.0.0.1) for the WebDriverAgentBroadcast Upload
 * Extension. The extension writes 20 ms PCM frames as `[8 bytes PTS BE][1920
 * bytes PCM LE]` (1928 B/frame); this class reassembles them and hands each
 * frame to its delegate.
 *
 * Single-producer model: the extension is the only writer. A new connection
 * supersedes any existing one (covers extension restarts).
 *
 * Default port: 9201 (chosen to avoid existing 8100 WDA HTTP / 9100 MJPEG /
 * 9200 audio-from-provider). Override via env `AUDIO_IPC_PORT`.
 *
 * Why TCP loopback rather than App Group Unix domain socket: XCTest UI Test
 * Bundles do not support `com.apple.security.application-groups`. Loopback
 * networking is permitted by the iOS sandbox by default; broadcast extensions
 * are permitted outbound network access (Zoom/Twilio/Discord all use this).
 *
 * See IPC.md and AUDIO-PIPELINE-CONTRACT.md §5.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Default loopback port the runner binds to and the extension connects to.
extern const uint16_t FBAudioBroadcastDefaultIPCPort;

@class FBAudioBroadcastReceiver;

@protocol FBAudioBroadcastReceiverDelegate <NSObject>
/// Invoked on the receiver's internal serial queue. `pcm` is exactly 1920 bytes
/// (960 × Int16 little-endian); `pts` is the producer's monotonic microsecond timestamp.
- (void)audioReceiver:(FBAudioBroadcastReceiver *)receiver
      didReceiveFrame:(NSData *)pcm
                  pts:(uint64_t)pts;
@end

@interface FBAudioBroadcastReceiver : NSObject

@property (nonatomic, weak, nullable) id<FBAudioBroadcastReceiverDelegate> delegate;
@property (nonatomic, readonly) uint16_t port;

/// Resolves the IPC port from the `AUDIO_IPC_PORT` env var, falling back to
/// `FBAudioBroadcastDefaultIPCPort`.
+ (uint16_t)resolvedIPCPort;

/// Designated initializer. Binds to 127.0.0.1 on the given port.
- (instancetype)initWithPort:(uint16_t)port NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Binds the socket and begins accepting. Idempotent: calling twice is a no-op.
- (BOOL)startListeningWithError:(NSError **)error;

/// Closes the listening socket and any active client connection. Safe to call multiple times.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
