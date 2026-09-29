#include <substrate.h>
#include <Foundation/Foundation.h>
#include <objc/runtime.h>

// ============================================================
// bunqVoyeur v2 — fängt entschlüsselte bunq-JSONs ab
// ------------------------------------------------------------
// Swift's JSONDecoder/Codable geht auf Apple-Plattformen intern
// durch NSJSONSerialization -> wir sehen den Klartext NACH der
// bunq-E2E-Entschlüsselung, genau wenn die App ihn parst.
//
// Log: <bunq-Container>/Documents/bunqvoyeur_log.jsonl
// ============================================================

static NSString *logPath(void) {
    static NSString *p = nil;
    if (!p) {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        p = [doc stringByAppendingPathComponent:@"bunqvoyeur_log.jsonl"];
    }
    return p;
}

static BOOL interesting(NSString *s) {
    if (!s || s.length < 4) return NO;
    static NSArray *markers = nil;
    if (!markers) {
        markers = @[@"identity", @"verification", @"incode", @"selfie", @"liveness",
                    @"rejected", @"approved", @"declined", @"face", @"onboarding",
                    @"user_identification", @"verificationStatus", @"session_status"];
    }
    NSString *low = [s lowercaseString];
    for (NSString *m in markers) {
        if ([low containsString:m]) return YES;
    }
    return NO;
}

static void appendLog(NSString *payload, NSUInteger cap) {
    @try {
        if (payload.length > cap) {
            payload = [payload substringToIndex:cap];
        }
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *ts = [df stringFromDate:[NSDate date]];
        NSString *line = [NSString stringWithFormat:@"%@ | %@\n", ts, payload];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath()];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:logPath() contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:logPath()];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// ---------- Parsen eingehender JSON-Antworten ----------
static id (*orig_JSONObjectWithData)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);
static id hook_JSONObjectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **err) {
    id result = orig_JSONObjectWithData(self, _cmd, data, opt, err);
    if (result && data.length > 2) {
        @try {
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (s && interesting(s)) {
                appendLog([NSString stringWithFormat:@"[JSON-IN len=%lu] %@", (unsigned long)s.length, s], 20000);
            }
        } @catch (NSException *e) {}
    }
    return result;
}

// ---------- Serialisieren ausgehender JSON-Requests ----------
static NSData *(*orig_JSONWithObject)(id, SEL, id, NSJSONWritingOptions, NSError **);
static NSData *hook_JSONWithObject(id self, SEL _cmd, id obj, NSJSONWritingOptions opt, NSError **err) {
    NSData *d = orig_JSONWithObject(self, _cmd, obj, opt, err);
    if (d && d.length > 2) {
        @try {
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (s && interesting(s)) {
                appendLog([NSString stringWithFormat:@"[JSON-OUT len=%lu] %@", (unsigned long)s.length, s], 8000);
            }
        } @catch (NSException *e) {}
    }
    return d;
}

// ---------- NSCoding-Archive ----------
static id (*orig_UnarchiveTop)(id, SEL, NSData *, NSError **);
static id hook_UnarchiveTop(id self, SEL _cmd, NSData *data, NSError **err) {
    id result = orig_UnarchiveTop(self, _cmd, data, err);
    if (result && data.length > 2) {
        @try {
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (s && interesting(s)) {
                appendLog([NSString stringWithFormat:@"[UNARCHIVE len=%lu] %@", (unsigned long)s.length, s], 20000);
            }
        } @catch (NSException *e) {}
    }
    return result;
}

// ---------- URL-Kontext (verification-Endpoints) ----------
// Block-Parameter ist ABI-mäßig ein Pointer -> als id deklariert
static NSURLSessionDataTask *(*orig_dataTask)(id, SEL, NSURLRequest *, id);
static NSURLSessionDataTask *hook_dataTask(id self, SEL _cmd, NSURLRequest *req, id handler) {
    NSString *url = req.URL.absoluteString;
    if (url && ([url containsString:@"identity-verification"] ||
                [url containsString:@"incode"] ||
                [url containsString:@"user-identification"])) {
        appendLog([NSString stringWithFormat:@"[REQ-URL] %@", url], 2000);
    }
    return orig_dataTask(self, _cmd, req, handler);
}

__attribute__((constructor))
static void init(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.bunq.ios"]) return;

    MSHookMessageEx([NSJSONSerialization class],
                    @selector(JSONObjectWithData:options:error:),
                    (IMP)&hook_JSONObjectWithData,
                    (IMP *)&orig_JSONObjectWithData);

    MSHookMessageEx([NSJSONSerialization class],
                    @selector(dataWithJSONObject:options:error:),
                    (IMP)&hook_JSONWithObject,
                    (IMP *)&orig_JSONWithObject);

    MSHookMessageEx([NSKeyedUnarchiver class],
                    @selector(unarchiveTopLevelObjectWithData:error:),
                    (IMP)&hook_UnarchiveTop,
                    (IMP *)&orig_UnarchiveTop);

    MSHookMessageEx([NSURLSession class],
                    @selector(dataTaskWithRequest:completionHandler:),
                    (IMP)&hook_dataTask,
                    (IMP *)&orig_dataTask);
}
