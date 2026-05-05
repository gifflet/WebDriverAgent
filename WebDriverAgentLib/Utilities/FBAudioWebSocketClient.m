/**
 * FBAudioWebSocketClient.m
 */

#import "FBAudioWebSocketClient.h"
#import "FBLogger.h"

static const NSUInteger FBAudioWSMaxReconnectAttempts = 5;
static const NSTimeInterval FBAudioWSMaxBackoff = 30.0;

@interface FBAudioWebSocketClient () <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionWebSocketTask *task;
@property (nonatomic, copy, nullable) NSString *host;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) NSUInteger reconnectAttempt;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FBAudioWebSocketClient

+ (instancetype)sharedClient
{
  static FBAudioWebSocketClient *sharedInstance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[FBAudioWebSocketClient alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init
{
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _queue = dispatch_queue_create("io.gads.wda.audio.ws", DISPATCH_QUEUE_SERIAL);
  NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  config.timeoutIntervalForRequest = 10.0;
  _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
  return self;
}

- (void)connectToHost:(NSString *)host port:(uint16_t)port
{
  dispatch_async(self.queue, ^{
    [self _cancelTaskKeepingEndpoint];
    self.host = [host copy];
    self.port = port;
    self.reconnectAttempt = 0;
    [self _openTask];
  });
}

- (void)disconnect
{
  dispatch_async(self.queue, ^{
    self.host = nil;
    self.port = 0;
    self.reconnectAttempt = 0;
    [self _cancelTaskKeepingEndpoint];
  });
}

- (void)sendFrame:(NSData *)pcmFrame pts:(uint64_t)pts
{
  if (!self.connected || self.task == nil) {
    return;
  }

  NSMutableData *payload = [NSMutableData dataWithCapacity:8 + pcmFrame.length];
  uint8_t header[8];
  header[0] = (uint8_t)((pts >> 56) & 0xFF);
  header[1] = (uint8_t)((pts >> 48) & 0xFF);
  header[2] = (uint8_t)((pts >> 40) & 0xFF);
  header[3] = (uint8_t)((pts >> 32) & 0xFF);
  header[4] = (uint8_t)((pts >> 24) & 0xFF);
  header[5] = (uint8_t)((pts >> 16) & 0xFF);
  header[6] = (uint8_t)((pts >> 8)  & 0xFF);
  header[7] = (uint8_t)( pts        & 0xFF);
  [payload appendBytes:header length:sizeof(header)];
  [payload appendData:pcmFrame];

  NSURLSessionWebSocketMessage *message =
    [[NSURLSessionWebSocketMessage alloc] initWithData:payload];

  __weak typeof(self) weakSelf = self;
  [self.task sendMessage:message completionHandler:^(NSError * _Nullable error) {
    if (error != nil) {
      [FBLogger logFmt:@"FBAudioWebSocketClient: send error: %@", error.localizedDescription];
      [weakSelf _handleDisconnect];
    }
  }];
}

#pragma mark - Internals

- (void)_openTask
{
  if (self.host.length == 0 || self.port == 0) {
    return;
  }
  NSURLComponents *components = [[NSURLComponents alloc] init];
  components.scheme = @"ws";
  components.host = self.host;
  components.port = @(self.port);
  components.path = @"/";
  NSURL *url = components.URL;
  if (url == nil) {
    [FBLogger logFmt:@"FBAudioWebSocketClient: cannot build URL for %@:%d", self.host, self.port];
    return;
  }

  self.task = [self.session webSocketTaskWithURL:url];
  self.connected = NO;
  [self.task resume];
  [FBLogger logFmt:@"FBAudioWebSocketClient: connecting to %@", url.absoluteString];
}

- (void)_cancelTaskKeepingEndpoint
{
  self.connected = NO;
  if (self.task != nil) {
    [self.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.task = nil;
  }
}

- (void)_handleDisconnect
{
  dispatch_async(self.queue, ^{
    self.connected = NO;
    [self _cancelTaskKeepingEndpoint];
    if (self.host.length == 0) {
      return; // explicit disconnect
    }
    if (self.reconnectAttempt >= FBAudioWSMaxReconnectAttempts) {
      [FBLogger logFmt:@"FBAudioWebSocketClient: giving up after %lu reconnect attempts",
       (unsigned long)self.reconnectAttempt];
      return;
    }
    NSTimeInterval delay = MIN(FBAudioWSMaxBackoff, pow(2.0, (double)self.reconnectAttempt));
    self.reconnectAttempt += 1;
    [FBLogger logFmt:@"FBAudioWebSocketClient: reconnecting in %.1fs (attempt %lu)",
     delay, (unsigned long)self.reconnectAttempt];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   self.queue, ^{
      if (self.host.length > 0) {
        [self _openTask];
      }
    });
  });
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
    webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol
{
  dispatch_async(self.queue, ^{
    if (webSocketTask != self.task) { return; }
    self.connected = YES;
    self.reconnectAttempt = 0;
    [FBLogger log:@"FBAudioWebSocketClient: connected"];
  });
}

- (void)URLSession:(NSURLSession *)session
    webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
           reason:(NSData *)reason
{
  [FBLogger logFmt:@"FBAudioWebSocketClient: closed (code=%ld)", (long)closeCode];
  [self _handleDisconnect];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
  if (error != nil) {
    [FBLogger logFmt:@"FBAudioWebSocketClient: task completed with error: %@",
     error.localizedDescription];
    [self _handleDisconnect];
  }
}

@end
