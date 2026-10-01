// bunqVoyeur v5 — OHNE libsubstrate (reines ObjC-Runtime-Swizzling).
// Manuell per opainject in den laufenden bunq injizieren (bewiesen funktionierend).
// Loggt NSURLSession/NSURLConnection Traffic an Incode/Sardine/Verification nach
// <bunq-Container>/Documents/bunqVoyeur/
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <sys/time.h>

static NSString *now(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return [NSString stringWithFormat:@"%ld.%03ld", (long)tv.tv_sec, (long)tv.tv_usec / 1000];
}

static NSString *dirPath(void) {
    static NSString *d = nil;
    if (!d) {
        NSString *home = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        d = [home stringByAppendingPathComponent:@"bunqVoyeur"];
    }
    return d;
}

static void logLine(NSString *file, NSString *line) {
    @try {
        NSString *dir = dirPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *p = [dir stringByAppendingPathComponent:file];
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) {
            [data writeToFile:p atomically:NO];
            fh = [NSFileHandle fileHandleForWritingAtPath:p];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

static BOOL interesting(NSURL *u) {
    if (!u || !u.absoluteString) return NO;
    NSString *s = u.absoluteString.lowercaseString;
    for (NSString *k in @[@"incode", @"incodesmile", @"sardine", @"identity-verification",
                          @"user-identification", @"deviceservice", @"onboarding"]) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static NSString *bd(NSData *d) {
    if (!d) return @"<nil>";
    if (d.length > 50000) return [NSString stringWithFormat:@"<%lu bytes tr.>", (unsigned long)d.length];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (s) return s;
    return [NSString stringWithFormat:@"<bin %lu>", (unsigned long)d.length];
}

// ============ dataTaskWithRequest:completionHandler: ============
typedef NSURLSessionDataTask *(*dtfn_t)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static dtfn_t orig_dt = NULL;

static NSURLSessionDataTask *my_dt(id self, SEL _cmd, NSURLRequest *req, void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    if (interesting(req.URL)) {
        logLine(@"requests.log", [NSString stringWithFormat:@"[%@] DATA %@ %@\n  BODY: %@", now(), req.HTTPMethod ?: @"-", req.URL.absoluteString ?: @"-", bd(req.HTTPBody)]);
    }
    void (^nc)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (r && interesting(r.URL)) {
            NSString *st = @"";
            if ([r isKindOfClass:NSHTTPURLResponse.class]) st = [NSString stringWithFormat:@" status=%ld", (long)((NSHTTPURLResponse *)r).statusCode];
            logLine(@"responses.log", [NSString stringWithFormat:@"[%@] DATA-RESP %@%@ err=%@\n  BODY: %@", now(), r.URL.absoluteString ?: @"-", st, e ?: @"-", bd(d)]);
        }
        if (cb) cb(d, r, e);
    };
    return orig_dt(self, _cmd, req, nc);
}

// ============ uploadTaskWithRequest:fromData:completionHandler: ============
typedef NSURLSessionUploadTask *(*upfn_t)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
static upfn_t orig_up = NULL;

static NSURLSessionUploadTask *my_up(id self, SEL _cmd, NSURLRequest *req, NSData *body, void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    if (interesting(req.URL)) {
        logLine(@"requests.log", [NSString stringWithFormat:@"[%@] UPLOAD %@ %@\n  BODY: %@", now(), req.HTTPMethod ?: @"-", req.URL.absoluteString ?: @"-", bd(body)]);
    }
    void (^nc)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (r && interesting(r.URL)) {
            NSString *st = @"";
            if ([r isKindOfClass:NSHTTPURLResponse.class]) st = [NSString stringWithFormat:@" status=%ld", (long)((NSHTTPURLResponse *)r).statusCode];
            logLine(@"responses.log", [NSString stringWithFormat:@"[%@] UP-RESP %@%@ err=%@\n  BODY: %@", now(), r.URL.absoluteString ?: @"-", st, e ?: @"-", bd(d)]);
        }
        if (cb) cb(d, r, e);
    };
    return orig_up(self, _cmd, req, body, nc);
}

// ============ NSURLConnection sendAsynchronousRequest ============
typedef void (*sendfn_t)(id, SEL, NSURLRequest *, NSOperationQueue *, void (^)(NSURLResponse *, NSData *, NSError *));
static sendfn_t orig_send = NULL;

static void my_send(id self, SEL _cmd, NSURLRequest *req, NSOperationQueue *q, void (^cb)(NSURLResponse *, NSData *, NSError *)) {
    if (interesting(req.URL)) {
        logLine(@"requests.log", [NSString stringWithFormat:@"[%@] CONN %@ %@\n  BODY: %@", now(), req.HTTPMethod ?: @"-", req.URL.absoluteString ?: @"-", bd(req.HTTPBody)]);
    }
    orig_send(self, _cmd, req, q, cb);
}

__attribute__((constructor))
static void ctor(void) {
    logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] ctor bundle=%@", now(), NSBundle.mainBundle.bundleIdentifier ?: @"nil"]);

    Method m1 = class_getInstanceMethod(NSURLSession.class, @selector(dataTaskWithRequest:completionHandler:));
    if (m1) {
        orig_dt = (dtfn_t)method_setImplementation(m1, (IMP)my_dt);
        logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] hooked dataTask", now()]);
    }
    Method m2 = class_getInstanceMethod(NSURLSession.class, @selector(uploadTaskWithRequest:fromData:completionHandler:));
    if (m2) {
        orig_up = (upfn_t)method_setImplementation(m2, (IMP)my_up);
        logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] hooked uploadData", now()]);
    }
    Method m3 = class_getInstanceMethod(NSURLConnection.class, @selector(sendAsynchronousRequest:queue:completionHandler:));
    if (m3) {
        orig_send = (sendfn_t)method_setImplementation(m3, (IMP)my_send);
        logLine(@"heartbeat.txt", [NSString stringWithFormat:@"[%@] hooked sendAsync", now()]);
    }
}