/**
 * FBAudioBroadcastReceiver.m — TCP loopback consumer.
 *
 * Implementation notes:
 *   - POSIX sockets directly (AF_INET, SOCK_STREAM, bound to 127.0.0.1).
 *     GCDAsyncSocket would also work but the read loop is trivially short.
 *   - One serial dispatch queue handles accept + per-client reads. Single
 *     producer (the broadcast extension) so concurrent client handling is
 *     unnecessary.
 *   - SO_REUSEADDR so a stale TIME_WAIT from a prior crash doesn't block bind.
 *   - Backpressure: delegate runs on the read queue. If the delegate blocks,
 *     the kernel buffer fills and the producer's writes will start dropping
 *     (producer is non-blocking). Audio realtime > completeness.
 */

#import "FBAudioBroadcastReceiver.h"
#import "FBLogger.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

const uint16_t FBAudioBroadcastDefaultIPCPort = 9201;

static const NSUInteger FBAudioBroadcastFrameBytes = 1920;     // 960 × Int16 LE
static const NSUInteger FBAudioBroadcastHeaderBytes = 8;       // PTS BE uint64
static const NSUInteger FBAudioBroadcastFrameTotal = 1928;     // header + payload

@interface FBAudioBroadcastReceiver ()
@property (nonatomic, assign, readwrite) uint16_t port;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) int clientFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL stopped;
@end

@implementation FBAudioBroadcastReceiver

+ (uint16_t)resolvedIPCPort
{
  NSString *override = NSProcessInfo.processInfo.environment[@"AUDIO_IPC_PORT"];
  if (override.length > 0) {
    NSInteger value = override.integerValue;
    if (value > 0 && value <= UINT16_MAX) {
      return (uint16_t)value;
    }
  }
  return FBAudioBroadcastDefaultIPCPort;
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
  _queue = dispatch_queue_create("io.gads.wda.audio.receiver", DISPATCH_QUEUE_SERIAL);
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

  // SO_REUSEADDR so a stale TIME_WAIT entry from a prior crash doesn't
  // block bind() during a quick relaunch.
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(self.port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1 only

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
  dispatch_async(self.queue, ^{
    [weakSelf acceptLoop];
  });
  [FBLogger logFmt:@"FBAudioBroadcastReceiver listening on 127.0.0.1:%u", self.port];
  return YES;
}

- (void)stop
{
  self.stopped = YES;
  if (self.clientFD != -1) {
    close(self.clientFD);
    self.clientFD = -1;
  }
  if (self.listenFD != -1) {
    close(self.listenFD);
    self.listenFD = -1;
  }
}

- (void)dealloc
{
  [self stop];
}

#pragma mark - Internals

- (void)acceptLoop
{
  while (!self.stopped && self.listenFD != -1) {
    int client = accept(self.listenFD, NULL, NULL);
    if (client < 0) {
      if (errno == EINTR) { continue; }
      if (self.stopped) { return; }
      [FBLogger logFmt:@"FBAudioBroadcastReceiver accept() failed: %d (%s)", errno, strerror(errno)];
      // Brief pause to avoid spinning on persistent error.
      [NSThread sleepForTimeInterval:0.05];
      continue;
    }

    // New connection supersedes any prior one.
    if (self.clientFD != -1) {
      close(self.clientFD);
    }
    self.clientFD = client;
    [FBLogger log:@"FBAudioBroadcastReceiver: producer connected"];
    [self readLoopOnClient:client];
    [FBLogger log:@"FBAudioBroadcastReceiver: producer disconnected"];
    if (self.clientFD == client) {
      close(client);
      self.clientFD = -1;
    }
  }
}

- (void)readLoopOnClient:(int)client
{
  uint8_t buffer[FBAudioBroadcastFrameTotal];
  while (!self.stopped) {
    NSUInteger have = 0;
    while (have < FBAudioBroadcastFrameTotal) {
      ssize_t n = recv(client, buffer + have, FBAudioBroadcastFrameTotal - have, 0);
      if (n > 0) {
        have += (NSUInteger)n;
        continue;
      }
      if (n == 0) { return; }              // EOF
      if (errno == EINTR) { continue; }    // retry
      [FBLogger logFmt:@"FBAudioBroadcastReceiver recv() error: %d (%s)", errno, strerror(errno)];
      return;
    }

    uint64_t pts = ((uint64_t)buffer[0] << 56) | ((uint64_t)buffer[1] << 48)
                 | ((uint64_t)buffer[2] << 40) | ((uint64_t)buffer[3] << 32)
                 | ((uint64_t)buffer[4] << 24) | ((uint64_t)buffer[5] << 16)
                 | ((uint64_t)buffer[6] << 8)  |  (uint64_t)buffer[7];
    NSData *pcm = [NSData dataWithBytes:buffer + FBAudioBroadcastHeaderBytes
                                 length:FBAudioBroadcastFrameBytes];
    id<FBAudioBroadcastReceiverDelegate> delegate = self.delegate;
    if (delegate != nil) {
      [delegate audioReceiver:self didReceiveFrame:pcm pts:pts];
    }
  }
}

@end
