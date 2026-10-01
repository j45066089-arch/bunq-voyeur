// bunqVoyeurHB — minimaler Heartbeat-Test, OHNE libsubstrate.
// Beweist ob Injektion+Filter grundsaetzlich funktionieren.
#import <Foundation/Foundation.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>

static void w(const char *path, const char *s) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { write(fd, s, strlen(s)); close(fd); }
}

__attribute__((constructor))
static void ctor(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";
    char line[640];
    snprintf(line, sizeof(line), "[%ld.%03ld] ctor bundle=%s\n",
             (long)tv.tv_sec, (long)tv.tv_usec / 1000, bid.UTF8String);

    mkdir("/var/mobile/Documents/bunqVoyeur", 0755);
    w("/var/mobile/Documents/bunqVoyeur/heartbeat.txt", line);

    NSString *home = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (home) {
        NSString *dir = [home stringByAppendingPathComponent:@"bunqVoyeur"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *p = [dir stringByAppendingPathComponent:@"heartbeat.txt"];
        w(p.fileSystemRepresentation, line);
    }
}