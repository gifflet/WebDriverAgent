/**
 * FBAudioBroadcastRelay
 *
 * TCP loopback producer that re-emits PCM frames received from the
 * FBAudioBroadcastReceiver to a single external consumer (the provider, reached
 * via go-ios USB forward).
 *
 * Wire format identical to the appex→runner channel: `[8 B PTS BE][1920 B PCM
 * Int16 LE]` (1928 B/frame).
 *
 * Why this exists: WDA Runner is an XCTest UI Test bundle; iOS Local Network
 * privacy silently denies its outbound LAN sockets, so `FBAudioWebSocketClient`
 * cannot reach the provider over WiFi. Loopback + USB tunnel is unrestricted.
 *
 * Default port: 9202. Override via env `FB_AUDIO_RELAY_PORT`. Single-consumer:
 * a new connection supersedes any existing one.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const uint16_t FBAudioBroadcastRelayDefaultPort;

@interface FBAudioBroadcastRelay : NSObject

@property (nonatomic, readonly) uint16_t port;

/// Resolves the relay port from the `FB_AUDIO_RELAY_PORT` env var, falling back
/// to `FBAudioBroadcastRelayDefaultPort`.
+ (uint16_t)resolvedRelayPort;

- (instancetype)initWithPort:(uint16_t)port NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Binds and starts accepting consumer connections. Idempotent.
- (BOOL)startListeningWithError:(NSError **)error;

/// Sends a single frame to the connected consumer (if any). Drops on backpressure.
/// Safe to call from any queue (synchronization is internal).
- (void)relayFrame:(NSData *)pcm pts:(uint64_t)pts;

/// Closes the listening socket and any active consumer.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
