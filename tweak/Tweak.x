#include <substrate.h>
#include <Foundation/Foundation.h>
#include <sys/time.h>

// bunqVoyeur v3 — beobachtet Incode/Sardine/Verification-Traffic von bunq.
// Korrekturen vs. v2:
//   1. Block-Parameter als ECHTE Block-Typen (nicht `id`) -> arm64e ABI ok.
//   2. Log an SSH-sichtbaren absoluten Pfad /var/mobile/Documents/bunqVoyeur/
//      (ueberlebt Crane-Container-Wechsel + bunq-Neuinstallation) UND
//      zusaetzlich in den App-Container als Fallback.
//   3. Heartbeat im ctor beweist Injektion positiv (auch unter Sandbox).

static NSString *now(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return [NSString stringWithFormat:@"%ld.%03ld", (long)tv.tv_sec, (long)tv.tv_usec / 1000];
}

static NSArray<NSString *> *logDirs(void) {
    static NSArray *dirs = nil;
    if (!dirs) {
        NSMutableArray *a = [NSMutableArray arrayWithObject:@"/var/mobile/Documents/bunqVoyeur"];
        NSString *home = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (home) [a addObject:[home stringByAppendingPathComponent:@"bunqVoyeur"]];
        dirs = [a copy];
    }
    return dirs;
}

static void logLine(NSString *file, NSString *line) {
    @try {
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        for (NSString *dir in logDirs()) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *p = [dir stringByAppendingPathComponent:file];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                [d writeToFile:p atomically:NO]; // erste Zeile legt Datei an
                fh = [NSFileHandle fileHandleForWritingAtPath:p];
            }
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

static BOOL interestingURL(NSURL *url) {
    if (!url || !url.absoluteString) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    for (NSString *k in @[@"incode", @"incodesmile", @"sardine", @"identity-verification",
                          @"user-identification", @"deviceservice", @"onboarding"]) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static NSString *bodyDesc(NSData *d) {
    if (!d) return @"<nil>";
    if (d.length > 40000) return [NSString stringWithFormat:@"<%lu bytes truncated>", (unsigned long)d.length];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (s) return s;
    return [NSString stringWithFormat:@"<binary %lu bytes>", (unsigned long)d.length];
}

static void logRequest(NSURLRequest *req, NSString *kind, NSString *extra) {
    logLine(@"requests.log", [NSString stringWithFormat:@"[%@] %@ %@ %@\n  BODY: %@%@\n",
        now(), kind, req.HTTPMethod ?: @"-", req.URL.absoluteString ?: @"-",
        bodyDesc(req.HTTPBody), extra ?: @""]);
}

static void logResponse(NSURLResponse *resp, NSData *data, NSError *err, NSString *prefix) {
    NSString *status = @"";
    if ([resp isKindOfClass:NSHTTPURLResponse.class])
        status = [NSString stringWithFormat:@" status=%ld", (long)((NSHTTPURLResponse *)resp).statusCode];
    logLine(@"responses.log", [NSString stringWithFormat:@"[%@] %@ %@%@ err=%@\n  BODY: %@\n",
        now(), prefix, resp.URL.absoluteString ?: @"-", status, err ?: @"-", bodyDesc(data)]);
}

// ============ NSURLSession dataTaskWithRequest:completionHandler: ============
static NSURLSessionDataTask *(*orig_dataTaskCB)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *hook_dataTaskCB(id self, SEL _cmd, NSURLRequest *req, void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    if (interestingURL(req.URL))
        logRequest(req, @"DATA-CB", nil);
    void (^nc)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (r && interestingURL(r.URL)) logResponse(r, d, e, @"DATA-RESP");
        if (cb) cb(d, r, e);
    };
    return orig_dataTaskCB(self, _cmd, req, nc);
}

// ============ NSURLSession dataTaskWithRequest: (kein Handler) ============
static NSURLSessionDataTask *(*orig_dataTask)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *hook_dataTask(id self, SEL _cmd, NSURLRequest *req) {
    if (interestingURL(req.URL))
        logRequest(req, @"DATA", nil);
    return orig_dataTask(self, _cmd, req);
}

// ============ NSURLSession uploadTask fromData ============
static NSURLSessionUploadTask *(*orig_uploadData)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionUploadTask *hook_uploadData(id self, SEL _cmd, NSURLRequest *req, NSData *body, void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    if (interestingURL(req.URL))
        logRequest(req, @"UPLOAD-DATA", [NSString stringWithFormat:@"\n  UPLOAD: %@", bodyDesc(body)]);
    void (^nc)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (r && interestingURL(r.URL)) logResponse(r, d, e, @"UP-RESP");
        if (cb) cb(d, r, e);
    };
    return orig_uploadData(self, _cmd, req, body, nc);
}

// ============ NSURLSession uploadTask fromFile ============
static NSURLSessionUploadTask *(*orig_uploadFile)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionUploadTask *hook_uploadFile(id self, SEL _cmd, NSURLRequest *req, NSURL *file, void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    if (interestingURL(req.URL)) {
        NSString *sz = @"";
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:file.path error:nil];
        if (a[NSFileSize]) sz = [NSString stringWithFormat:@" file_size=%@", a[NSFileSize]];
        logRequest(req, @"UPLOAD-FILE", sz);
    }
    return orig_uploadFile(self, _cmd, req, file, cb);
}

// ============ NSURLConnection sendAsynchronousRequest ============
static void (*orig_sendAsync)(id, SEL, NSURLRequest *, NSOperationQueue *, void (^)(NSURLResponse *, NSData *, NSError *));
static void hook_sendAsync(id self, SEL _cmd, NSURLRequest *req, NSOperationQueue *q, void (^cb)(NSURLResponse *, NSData *, NSError *)) {
    if (interestingURL(req.URL))
        logRequest(req, @"CONN-ASYNC", nil);
    orig_sendAsync(self, _cmd, req, q, cb);
}

__attribute__((constructor))
static void init(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] ctor bundle=%@", now(), bid ?: @"nil"]);
    if (![bid isEqualToString:@"com.bunq.ios"]) return;
    logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] BUNQ hooking", now()]);

    MSHookMessageEx(NSURLSession.class, @selector(dataTaskWithRequest:completionHandler:),
                    (IMP)hook_dataTaskCB, (IMP *)&orig_dataTaskCB);
    MSHookMessageEx(NSURLSession.class, @selector(dataTaskWithRequest:),
                    (IMP)hook_dataTask, (IMP *)&orig_dataTask);
    MSHookMessageEx(NSURLSession.class, @selector(uploadTaskWithRequest:fromData:completionHandler:),
                    (IMP)hook_uploadData, (IMP *)&orig_uploadData);
    MSHookMessageEx(NSURLSession.class, @selector(uploadTaskWithRequest:fromFile:completionHandler:),
                    (IMP)hook_uploadFile, (IMP *)&orig_uploadFile);
    MSHookMessageEx(NSURLConnection.class, @selector(sendAsynchronousRequest:queue:completionHandler:),
                    (IMP)hook_sendAsync, (IMP *)&orig_sendAsync);
    logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] hooks installiert", now()]);
}