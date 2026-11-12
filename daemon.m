// WiFiRelayD - root daemon
// Watches the primary network interface; probes whether the WiFi/car-hotspot
// actually reaches the internet; if it does not, installs a pf anchor that
// blocks all non-local outbound traffic on that interface (CarPlay local
// subnet stays open), forcing configd to mark the WiFi "no internet" and
// demote it so cellular takes over routing + DNS automatically.
//
// iOS 14+ / roothide. Config: /var/mobile/Documents/WiFiRelay/config.plist
// Log:     /var/mobile/Documents/WiFiRelay/relay.log

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <strings.h>
#import <errno.h>
#import <stdarg.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <sys/ioctl.h>
#import <sys/filio.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <net/if.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>

// Darwin kernel option 25: bind socket to a specific interface
#ifndef IP_BIND_IF
#define IP_BIND_IF 25
#endif

#define WFR_VERSION "0.1.0"
#define WFR_DIR     "/var/mobile/Documents/WiFiRelay"
#define WFR_LOG     WFR_DIR "/relay.log"
#define WFR_ANCHOR  WFR_DIR "/anchor.conf"
#define WFR_CFG     WFR_DIR "/config.plist"
#define WFR_ANCHOR_NAME "com.corpsezhao.wifirelay"

static FILE *g_log = NULL;
static volatile sig_atomic_t g_stop = 0;
static char g_appliedKey[256] = {0};   // "" = not applied
static char g_pfctlPath[128] = {0};

// ---------- logging ----------

static void log_rotate(void) {
    FILE *f = fopen(WFR_LOG, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    if (sz > 512 * 1024) {
        rename(WFR_LOG, WFR_LOG ".old");
    }
}

static void wlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void wlog(const char *fmt, ...) {
    if (!g_log) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    fprintf(g_log, "[%02d-%02d %02d:%02d:%02d] ",
            tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

// ---------- config ----------

static BOOL cfg_enabled(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@WFR_CFG];
    if (!d) return YES;
    NSNumber *e = d[@"Enabled"];
    return e ? [e boolValue] : YES;
}

static int cfg_interval(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@WFR_CFG];
    NSNumber *i = d[@"ProbeIntervalSec"];
    int v = i ? [i intValue] : 5;
    if (v < 2) v = 2;
    if (v > 60) v = 60;
    return v;
}

// ---------- pf ----------

// fork/execl wrapper: pfctl -q -a ANCHOR <a1> <a2>
static int pfctl_run(const char *a1, const char *a2) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 1); dup2(devnull, 2); }
        execl(g_pfctlPath, g_pfctlPath, "-q", "-a", WFR_ANCHOR_NAME, a1, a2, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}

static void find_pfctl(void) {
    static const char *cands[] = { "/sbin/pfctl", "/usr/sbin/pfctl", "/usr/libexec/pfctl", "/bin/pfctl", NULL };
    if (g_pfctlPath[0]) return;
    for (int i = 0; cands[i]; i++) {
        if (access(cands[i], X_OK) == 0) {
            snprintf(g_pfctlPath, sizeof(g_pfctlPath), "%s", cands[i]);
            wlog("pfctl found at %s", g_pfctlPath);
            return;
        }
    }
    wlog("WARN: no pfctl found on this device; cannot enforce firewall");
}

static void clear_anchor(const char *why) {
    if (!g_appliedKey[0]) return;
    if (g_pfctlPath[0]) {
        int rc = pfctl_run("-F", "all");
        wlog("anchor cleared (%s), pfctl rc=%d", why, rc);
    }
    g_appliedKey[0] = 0;
}

static void apply_anchor(const char *ifname, const char *subnet) {
    char key[256];
    snprintf(key, sizeof(key), "%s|%s", ifname, subnet);
    if (strcmp(key, g_appliedKey) == 0) return; // already applied, unchanged

    if (!g_pfctlPath[0]) { find_pfctl(); if (!g_pfctlPath[0]) return; }

    FILE *f = fopen(WFR_ANCHOR, "w");
    if (!f) { wlog("ERROR: cannot write anchor file: %s", strerror(errno)); return; }
    fprintf(f,
        "block drop out quick on %s inet to ! { %s, 224.0.0.0/4, 255.255.255.255 }\n"
        "block drop out quick on %s inet6 to ! { fe80::/10, ff00::/8 }\n",
        ifname, subnet, ifname);
    fclose(f);

    int rc = pfctl_run("-f", WFR_ANCHOR);
    if (rc == 0) {
        wlog("anchor APPLIED: block outbound on %s to ! {%s, multicast} (local/CarPlay allowed)", ifname, subnet);
        snprintf(g_appliedKey, sizeof(g_appliedKey), "%s", key);
    } else {
        wlog("ERROR: pfctl apply failed rc=%d for %s/%s", rc, ifname, subnet);
    }
}

// ---------- probe ----------

// Returns YES only if captive.apple.com answered HTTP 200 with "Success" via ifname.
static BOOL probe_internet_via(const char *ifname, char *detail, size_t detailLen) {
    unsigned ifindex = if_nametoindex(ifname);
    if (!ifindex) {
        snprintf(detail, detailLen, "if_nametoindex(%s)=0 (interface gone)", ifname);
        return NO;
    }

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int grc = getaddrinfo("captive.apple.com", "80", &hints, &res);
    if (grc != 0 || !res) {
        snprintf(detail, detailLen, "DNS resolve failed on %s (getaddrinfo rc=%d)", ifname, grc);
        return NO;
    }

    BOOL ok = NO;
    snprintf(detail, detailLen, "probe via %s (ifindex=%u): ", ifname, ifindex);
    size_t dlen = strlen(detail);

    for (struct addrinfo *ai = res; ai && !ok; ai = ai->ai_next) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) break;
        int ifidx = (int)ifindex;
        setsockopt(s, IPPROTO_IP, IP_BIND_IF, &ifidx, sizeof(ifidx));
        int nb = 1;
        ioctl(s, FIONBIO, &nb);

        struct sockaddr_in *sa = (struct sockaddr_in *)ai->ai_addr;
        char ipstr[64] = {0};
        inet_ntop(AF_INET, &sa->sin_addr, ipstr, sizeof(ipstr));

        int crc = connect(s, ai->ai_addr, ai->ai_addrlen);
        if (crc < 0 && errno != EINPROGRESS) {
            dlen += snprintf(detail + dlen, detailLen - dlen, "tcp %s err=%d; ", ipstr, errno);
            close(s);
            continue;
        }
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(s, &wset);
        struct timeval tv = {4, 0};
        if (select(s + 1, NULL, &wset, NULL, &tv) <= 0) {
            dlen += snprintf(detail + dlen, detailLen - dlen, "tcp %s timeout; ", ipstr);
            close(s);
            continue;
        }
        int soerr = 0; socklen_t slen = sizeof(soerr);
        getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &slen);
        if (soerr != 0) {
            dlen += snprintf(detail + dlen, detailLen - dlen, "tcp %s soerr=%d; ", ipstr, soerr);
            close(s);
            continue;
        }

        const char *req = "GET /hotspot-detect.html HTTP/1.0\r\nHost: captive.apple.com\r\nUser-Agent: WiFiRelay/" WFR_VERSION "\r\nConnection: close\r\n\r\n";
        send(s, req, strlen(req), 0);

        char buf[2048];
        size_t total = 0;
        BOOL status200 = NO;
        BOOL bodyOK = NO;
        for (;;) {
            fd_set rset;
            FD_ZERO(&rset);
            FD_SET(s, &rset);
            struct timeval tv2 = {4, 0};
            int rr = select(s + 1, &rset, NULL, NULL, &tv2);
            if (rr <= 0) break;
            ssize_t n = recv(s, buf, sizeof(buf) - 1, 0);
            if (n <= 0) break;
            buf[n] = 0;
            total += (size_t)n;
            if (!status200 && strstr(buf, "200")) status200 = YES;
            if (strstr(buf, "Success")) bodyOK = YES;
            if (total > 16384) break;
        }
        close(s);
        dlen += snprintf(detail + dlen, detailLen - dlen, "tcp %s ok http200=%d bodySuccess=%d; ", ipstr, status200, bodyOK);
        ok = status200 && bodyOK;
    }
    freeaddrinfo(res);
    return ok;
}

// ---------- primary interface helpers ----------

// SCDynamicStore* are marked unavailable in iOS headers but present in the
// framework binary; load them dynamically.
static CFTypeRef wfr_sc_copy_global_ipv4(void) {
    static void *scLib = NULL;
    static CFTypeRef (*_create)(CFAllocatorRef, CFStringRef, void *, void *) = NULL;
    static CFTypeRef (*_copyValue)(CFTypeRef, CFStringRef) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scLib = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (!scLib) return;
        _create = (void *)dlsym(scLib, "SCDynamicStoreCreate");
        _copyValue = (void *)dlsym(scLib, "SCDynamicStoreCopyValue");
    });
    if (!_create || !_copyValue) return NULL;
    CFTypeRef store = _create(NULL, CFSTR("com.corpsezhao.wifirelay"), NULL, NULL);
    if (!store) return NULL;
    CFTypeRef val = _copyValue(store, CFSTR("State:/Network/Global/IPv4"));
    CFRelease(store);
    return val;
}

static NSString * primary_interface(NSString **routerOut) {
    CFDictionaryRef d = (CFDictionaryRef)wfr_sc_copy_global_ipv4();
    if (!d) return nil;
    NSDictionary *dict = (__bridge NSDictionary *)d;
    NSString *pi = dict[@"PrimaryInterface"];
    NSString *rt = dict[@"Router"];
    if (routerOut) *routerOut = rt;
    CFRelease(d);
    return pi;
}

// find IPv4 addr + netmask of ifname -> "a.b.c.d/nn"
static BOOL iface_subnet(const char *ifname, char *out, size_t outLen) {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *ia = addrs; ia; ia = ia->ifa_next) {
        if (!ia->ifa_addr || strcmp(ia->ifa_name, ifname) != 0) continue;
        if (ia->ifa_addr->sa_family != AF_INET) continue;
        struct sockaddr_in *sa = (struct sockaddr_in *)ia->ifa_addr;
        char a[64];
        inet_ntop(AF_INET, &sa->sin_addr, a, sizeof(a));
        int bits = 0;
        if (ia->ifa_netmask) {
            struct sockaddr_in *sm = (struct sockaddr_in *)ia->ifa_netmask;
            uint32_t mask = ntohl(sm->sin_addr.s_addr);
            while (mask & 0x80000000u) { bits++; mask <<= 1; }
        }
        snprintf(out, outLen, "%s/%d", a, bits);
        found = YES;
        break;
    }
    freeifaddrs(addrs);
    return found;
}

// ---------- signals ----------

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

// ---------- main ----------

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        signal(SIGTERM, on_signal);
        signal(SIGINT, on_signal);
        signal(SIGPIPE, SIG_IGN);

        mkdir(WFR_DIR, 0755);
        log_rotate();
        g_log = fopen(WFR_LOG, "a");
        wlog("WiFiRelayD v%s started, pid=%d uid=%d", WFR_VERSION, getpid(), getuid());

        // default config if missing
        if (access(WFR_CFG, F_OK) != 0) {
            NSString *def = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                "<plist version=\"1.0\">\n<dict>\n"
                "\t<key>Enabled</key><true/>\n"
                "\t<key>ProbeIntervalSec</key><integer>5</integer>\n"
                "</dict>\n</plist>\n";
            [def writeToFile:@WFR_CFG atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            wlog("wrote default config %s", WFR_CFG);
        }
        chown(WFR_DIR, 501, 501);
        chown(WFR_CFG, 501, 501);

        find_pfctl();

        while (!g_stop) {
            @autoreleasepool {
                int interval = cfg_interval();

                if (!cfg_enabled()) {
                    if (g_appliedKey[0]) clear_anchor("disabled via config");
                } else {
                    NSString *router = nil;
                    NSString *pi = primary_interface(&router);
                    if (!pi) {
                        if (g_appliedKey[0]) clear_anchor("no primary interface");
                    } else if ([pi hasPrefix:@"pdp_ip"] || [pi hasPrefix:@"pdp_ip"]) {
                        // cellular is primary -> nothing to fix
                        if (g_appliedKey[0]) clear_anchor("cellular primary");
                    } else {
                        char subnet[64] = {0};
                        if (!iface_subnet(pi.UTF8String, subnet, sizeof(subnet))) {
                            wlog("primary %s but no IPv4 addr yet", pi.UTF8String);
                        } else {
                            char detail[1024] = {0};
                            BOOL hasInet = probe_internet_via(pi.UTF8String, detail, sizeof(detail));
                            if (hasInet) {
                                if (g_appliedKey[0]) clear_anchor("wifi has real internet now");
                            } else {
                                wlog("no internet on primary %s (router=%s, subnet=%s): %s",
                                     pi.UTF8String, router.UTF8String ?: "nil", subnet, detail);
                                apply_anchor(pi.UTF8String, subnet);
                            }
                        }
                    }
                }

                // interruptible sleep
                for (int i = 0; i < interval && !g_stop; i++) sleep(1);
            }
        }

        clear_anchor("daemon exiting");
        wlog("WiFiRelayD stopped");
        if (g_log) fclose(g_log);
    }
    return 0;
}
