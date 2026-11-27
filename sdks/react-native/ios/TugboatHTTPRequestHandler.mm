#import <React/RCTBridgeModule.h>
#import <React/RCTURLRequestDelegate.h>
#import <React/RCTURLRequestHandler.h>
#import <ReactCommon/RCTTurboModule.h>

#import <mutex>

#if __has_include(<TugboatReactNative/TugboatReactNative-Swift.h>)
#import <TugboatReactNative/TugboatReactNative-Swift.h>
#else
#import "TugboatReactNative-Swift.h"
#endif

// React Native's HTTP handler (RCTHTTPRequestHandler) makes its NSURLSession
// with itself as delegate, so the Swift host's instrumented session cannot wrap
// it. This handler does the same work with `Tugboat.instrumentedSession`: it
// outranks the default handler, and handles a request only while
// `captureNetwork` is on (after `Tugboat.start`), so each request is recorded
// once, and an app's own session configuration provider or request interceptor
// (RCTSetCustomNSURLSessionConfigurationProvider, RCTSetCustomHTTPRequestInterceptor)
// is bypassed only then.
@interface TugboatHTTPRequestHandler : NSObject <RCTURLRequestHandler, RCTInvalidating, NSURLSessionDataDelegate, RCTTurboModule>
@end

@implementation TugboatHTTPRequestHandler {
  NSMapTable *_delegates;
  NSURLSession *_session;
  std::mutex _mutex;
}

@synthesize moduleRegistry = _moduleRegistry;

RCT_EXPORT_MODULE()

- (float)handlerPriority
{
  return 1;
}

- (void)invalidate
{
  std::lock_guard<std::mutex> lock(_mutex);
  [_session invalidateAndCancel];
  _session = nil;
}

// Needs the lock. A nil session with delegates means invalidated.
- (BOOL)isValid
{
  return (_session != nil) || (_delegates == nil);
}

// React Native's image loader (RCTImageLoader) sends its downloads through the
// same handlers as fetch, and tags each request with the NSURLProtocol property
// "trackingName" = "RCTImageLoader" (React Native sets that value nowhere else;
// fetch never sets a tracking name and React Native's own Image code never
// calls XMLHttpRequest.setTrackingName, so only an app that passes that exact
// name from JS opts a request out). Flutter's Image.network and
// Android record nothing for image loads, so these are left to React Native's
// default handler, unrecorded. A JS fetch or XHR of an image URL carries no
// such tag and is still recorded.
+ (BOOL)isImageLoaderRequest:(NSURLRequest *)request
{
  return [[NSURLProtocol propertyForKey:@"trackingName" inRequest:request] isEqual:@"RCTImageLoader"];
}

- (BOOL)canHandleRequest:(NSURLRequest *)request
{
  NSString *scheme = request.URL.scheme.lowercaseString;
  return TugboatRN.capturesNetwork && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
      ![TugboatHTTPRequestHandler isImageLoaderRequest:request];
}

- (NSURLSessionDataTask *)sendRequest:(NSURLRequest *)request withDelegate:(id<RCTURLRequestDelegate>)delegate
{
  std::lock_guard<std::mutex> lock(_mutex);
  if (_session == nil && [self isValid]) {
    NSOperationQueue *callbackQueue = [NSOperationQueue new];
    callbackQueue.maxConcurrentOperationCount = 1;
    callbackQueue.underlyingQueue = [[_moduleRegistry moduleForName:"Networking"] methodQueue];
    // The configuration of RCTHTTPRequestHandler without a custom provider.
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSNumber *useWifiOnly = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"ReactNetworkForceWifiOnly"];
    if (useWifiOnly != nil) {
      configuration.allowsCellularAccess = ![useWifiOnly boolValue];
    }
    [configuration setHTTPShouldSetCookies:YES];
    [configuration setHTTPCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    [configuration setHTTPCookieStorage:[NSHTTPCookieStorage sharedHTTPCookieStorage]];
    _session = [TugboatRN instrumentedSessionWithConfiguration:configuration delegate:self queue:callbackQueue];
    _delegates = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                           valueOptions:NSPointerFunctionsStrongMemory
                                               capacity:0];
  }
  NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
  [_delegates setObject:delegate forKey:task];
  [task resume];
  return task;
}

- (void)cancelRequest:(NSURLSessionDataTask *)task
{
  {
    std::lock_guard<std::mutex> lock(_mutex);
    [_delegates removeObjectForKey:task];
  }
  [task cancel];
}

#pragma mark - NSURLSession delegate (as RCTHTTPRequestHandler)

- (id<RCTURLRequestDelegate>)delegateForTask:(NSURLSessionTask *)task remove:(BOOL)remove
{
  std::lock_guard<std::mutex> lock(_mutex);
  id<RCTURLRequestDelegate> delegate = [_delegates objectForKey:task];
  if (remove) {
    [_delegates removeObjectForKey:task];
  }
  return delegate;
}

- (void)URLSession:(NSURLSession *)session
                        task:(NSURLSessionTask *)task
             didSendBodyData:(int64_t)bytesSent
              totalBytesSent:(int64_t)totalBytesSent
    totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
  [[self delegateForTask:task remove:NO] URLRequest:task didSendDataWithProgress:totalBytesSent];
}

- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler
{
  // Cookies are reset on redirect: React Native does not let iOS handle them itself.
  NSMutableURLRequest *nextRequest = [request mutableCopy];
  NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:request.URL];
  nextRequest.allHTTPHeaderFields = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
  completionHandler(nextRequest);
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
  [[self delegateForTask:task remove:NO] URLRequest:task didReceiveResponse:response];
  completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
  [[self delegateForTask:task remove:NO] URLRequest:task didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
  [[self delegateForTask:task remove:YES] URLRequest:task didCompleteWithError:error];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return nullptr;
}

@end
