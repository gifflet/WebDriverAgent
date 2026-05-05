/**
 * FBAudioBroadcastRelay.m — TCP loopback producer (consumer-facing).
 *
 * Mirrors FBAudioBroadcastReceiver's POSIX socket setup but flips the role:
 * accept() one consumer (provider Go via go-ios USB forward), then write
 * 1928-byte frames to it as they arrive from `relayFrame:pts:`.
 */

#import "FBAudioBroadcastRelay.h"
#import "FBLogger.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

const uint16_t FBAudioBroadcastRelayDefaultPort = 9202;

static const NSUInteger FBRelayFrameBytes = 1920;
static const NSUInteger FBRelayHeaderBytes = 8;
static const NSUInteger FBRelayFrameTotal = 1928;

@interface FBAudioBroadcastRelay ()
@property (nonatomic, assign, readwrite) uint16_t port;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) int clientFD;       // protected by clientLock
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
@property (nonatomic, strong) NSLock *clientLock;
@property (nonatomic, assign) BOOL stopped;
@end

@implementation FBAudioBroadcastRelay

+ (uint16_t)resolvedRelayPort
{
  NSString *override = NSProcessInfo.processInfo.environment[@"FB_AUDIO_RELAY_PORT"];
  if (override.length > 0) {
    NSInteger value = override.integerValue;
    if (value > 0 && value <= UINT16_MAX) {
      return (uint16_t)value;
    }
  }
  return FBAudioBroadcastRelayDefaultPort;
}

- (instancetype)initWithPort:(uint16_t)port
{
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _port = port;
  _listenFD = -1;
  _clientFD = -1;
  _acceptQueue = dispatch_queue_create("io.gads.wda.audio.relay", DISPATCH_QUEUE_SERIAL);
  _clientLock = [NSLock new];
  return self;
}

- (BOOL)startListeningWithError:(NSError **)error
{
  if (self.listenFD != -1) {
    return YES;
  }

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    if (error) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                               userInfo:@{NSLocalizedDescriptionKey: @"socket(AF_INET) failed"}];
    }
    return NO;
  }

  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  // Bind to 127.0.0.1 only — provider reaches us via go-ios USB tunnel which
  // looks like a localhost peer to the device. No LAN exposure needed.
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(self.port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int err = errno;
    close(fd);
    if (error) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err
                               userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"bind(127.0.0.1:%u) failed", self.port]}];
    }
    return NO;
  }

  if (listen(fd, 1) < 0) {
    int err = errno;
    close(fd);
    if (error) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err
                               userInfo:@{NSLocalizedDescriptionKey: @"listen() failed"}];
    }
    return NO;
  }

  self.listenFD = fd;
  self.stopped = NO;

  __weak typeof(self) weakSelf = self;
  dispatch_async(self.acceptQueue, ^{
    [weakSelf acceptLoop];
  });
  [FBLogger logFmt:@"FBAudioBroadcastRelay listening on 127.0.0.1:%u", self.port];
  return YES;
}

- (void)stop
{
  self.stopped = YES;
  [self.clientLock lock];
  if (self.clientFD != -1) {
    close(self.clientFD);
    self.clientFD = -1;
  }
  [self.clientLock unlock];
  if (self.listenFD != -1) {
    close(self.listenFD);
    self.listenFD = -1;
  }
}

- (void)dealloc
{
  [self stop];
}

- (void)relayFrame:(NSData *)pcm pts:(uint64_t)pts
{
  if (pcm.length != FBRelayFrameBytes) {
    return;
  }
  [self.clientLock lock];
  int fd = self.clientFD;
  [self.clientLock unlock];
  if (fd == -1) {
    return;
  }

  uint8_t header[FBRelayHeaderBytes];
  header[0] = (uint8_t)((pts >> 56) & 0xFF);
  header[1] = (uint8_t)((pts >> 48) & 0xFF);
  header[2] = (uint8_t)((pts >> 40) & 0xFF);
  header[3] = (uint8_t)((pts >> 32) & 0xFF);
  header[4] = (uint8_t)((pts >> 24) & 0xFF);
  header[5] = (uint8_t)((pts >> 16) & 0xFF);
  header[6] = (uint8_t)((pts >> 8)  & 0xFF);
  header[7] = (uint8_t)( pts        & 0xFF);

  // Single send: header + payload. Use MSG_NOSIGNAL to avoid SIGPIPE if the
  // consumer hung up; we just close the fd and wait for next accept().
  uint8_t buf[FBRelayFrameTotal];
  memcpy(buf, header, FBRelayHeaderBytes);
  memcpy(buf + FBRelayHeaderBytes, pcm.bytes, FBRelayFrameBytes);

  NSUInteger sent = 0;
  while (sent < FBRelayFrameTotal) {
    ssize_t n = send(fd, buf + sent, FBRelayFrameTotal - sent, 0);
    if (n > 0) {
      sent += (NSUInteger)n;
      continue;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }
    [FBLogger logFmt:@"FBAudioBroadcastRelay send() error: %d (%s)", errno, strerror(errno)];
    [self.clientLock lock];
    if (self.clientFD == fd) {
      close(self.clientFD);
      self.clientFD = -1;
    }
    [self.clientLock unlock];
    return;
  }
}

#pragma mark - Internals

- (void)acceptLoop
{
  while (!self.stopped && self.listenFD != -1) {
    int client = accept(self.listenFD, NULL, NULL);
    if (client < 0) {
      if (errno == EINTR) { continue; }
      if (self.stopped) { return; }
      [FBLogger logFmt:@"FBAudioBroadcastRelay accept() failed: %d (%s)", errno, strerror(errno)];
      [NSThread sleepForTimeInterval:0.05];
      continue;
    }

    [self.clientLock lock];
    if (self.clientFD != -1) {
      close(self.clientFD);
    }
    self.clientFD = client;
    [self.clientLock unlock];
    [FBLogger log:@"FBAudioBroadcastRelay: consumer connected"];
    // Reads from consumer are not expected; we just hold the fd until it
    // disconnects. A trivial read drains any keepalive bytes.
    uint8_t throwaway[64];
    while (!self.stopped) {
      ssize_t n = recv(client, throwaway, sizeof(throwaway), 0);
      if (n <= 0) {
        if (n < 0 && errno == EINTR) { continue; }
        break;
      }
    }
    [FBLogger log:@"FBAudioBroadcastRelay: consumer disconnected"];
    [self.clientLock lock];
    if (self.clientFD == client) {
      close(self.clientFD);
      self.clientFD = -1;
    }
    [self.clientLock unlock];
  }
}

@end
