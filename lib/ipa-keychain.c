// ipa-keychain: a file-backed keychain for ad-hoc signed Mac Catalyst apps.
//
// WHY
// An app installed by ipa-install-on-mac is signed ad-hoc, so it has no
// application-identifier and no keychain-access-groups (AMFI refuses to
// spawn a process that claims them without a provisioning profile; measured
// 2026-09-06). Mac Catalyst apps always use the data protection keychain
// (TN3137), which needs exactly those, so every SecItemAdd answers -34018
// errSecMissingEntitlement and a login never survives a relaunch. PlayCover's
// PlayTools solves this with PlayChain, a replacement keychain; this is the
// same idea in 300 lines of C with no dependencies: the four SecItem entry
// points are interposed (dyld __interpose, honoured for a dylib linked into
// the app, which is how ipa-install-on-mac loads it) and generic/internet
// password items live in a binary plist inside the app's own sandbox
// container, mode 0600. Other item classes (keys, certificates, identities)
// pass through to the real implementation unchanged, so an app that expects a
// SecKeyRef gets one or the real error, never a dictionary.
//
// WHAT IT IS NOT
// Not the keychain's security: items rest on disk protected by the sandbox
// container and file permissions, not by the login password or the Secure
// Enclave. A token stolen from ~/Library/Containers/<bundle id>/Data is a
// token; the same is true of PlayChain.
//
// SEMANTICS KEPT (enough for GTMAppAuth / Google Sign-In and most apps)
//   - matching: every attribute key present in the query must be CFEqual to
//     the item's; kSecReturn*, kSecMatch*, kSecUse*, access group, sync,
//     accessibility and access control are ignored
//   - SecItemAdd refuses a duplicate on the class's primary keys
//     (account+service for generic passwords; account+server+protocol+
//     authentication type+port+path+security domain for internet passwords)
//   - kSecReturnData / kSecReturnAttributes / kSecReturnPersistentRef /
//     kSecMatchLimit are honoured; kSecReturnRef returns the attributes
//     dictionary (no real SecKeychainItemRef exists for these items)
//   - kSecValuePersistentRef in a query finds the item it was returned for
//   - accessibility and sync are stored and returned (never matched on), and
//     an item that never set them answers the keychain's defaults, as a real
//     keychain does; see stored_key() for the crash that taught this
//   - every item carries kSecAttrAccessGroup, the caller's if it gave one, else
//     a synthetic "<seed>.<bundle id>" whose 10-character seed is stable per
//     bundle id and shaped like a team identifier. Google's SSO layer opens
//     with a "bundleSeedID" probe: add an item, read its attributes back, take
//     the text before the first dot as the team seed, and build the shared
//     account group from it. Measured 2026-09-06 on a real tweaked app: with
//     no access group returned the seed was empty and "Sign in" showed
//     nothing, while a keychain-fix tweak whose probe FAILED outright made the
//     app fall back to a no-SSO path that did show the selector. A real
//     keychain never answers that probe without a group, so neither does
//     this one.
//
// Build (ipa-install-on-mac does this at install time):
//   xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
//     -O2 -Wall -dynamiclib -framework CoreFoundation -framework Security \
//     -install_name @executable_path/Frameworks/libipakeychain.dylib -o libipakeychain.dylib ipa-keychain.c

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <pthread.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <unistd.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableArrayRef g_items = NULL;   // CFMutableDictionaryRef per item
static char g_path[PATH_MAX];
static CFStringRef kIdKey = CFSTR("_ipa_keychain_id");

// ── Optional logging (diagnosis) ────────────────────────────────────────────
// On when IPA_KEYCHAIN_LOG is set, or when a file named DEBUG sits beside the
// store (touch it in the app's container to trace without relaunching a shell).
// One line per call: op, class, account, service, whether a secret was carried,
// how many items matched, and the return code. Never the secret bytes.
static void store_path(void);
static CFStringRef access_group(void);
static char g_log[PATH_MAX];
static int g_log_on = -1;

static void klog(const char *fmt, ...) {
    if (g_log_on < 0) {
        store_path();
        g_log_on = getenv("IPA_KEYCHAIN_LOG") ? 1 : 0;
        char dbg[PATH_MAX]; strlcpy(dbg, g_path, sizeof dbg);
        char *slash = strrchr(dbg, '/');
        if (slash) { strlcpy(slash + 1, "DEBUG", sizeof dbg - (size_t)(slash + 1 - dbg)); struct stat st; if (stat(dbg, &st) == 0) g_log_on = 1; }
        strlcpy(g_log, g_path, sizeof g_log);
        slash = strrchr(g_log, '/'); if (slash) strlcpy(slash + 1, "log.txt", sizeof g_log - (size_t)(slash + 1 - g_log));
    }
    if (g_log_on <= 0) return;
    struct stat st;
    if (stat(g_log, &st) == 0 && st.st_size > 256 * 1024) { char old[PATH_MAX]; snprintf(old, sizeof old, "%s.1", g_log); rename(g_log, old); }
    FILE *f = fopen(g_log, "a"); if (!f) return;
    fchmod(fileno(f), 0600);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

// A query attribute as a C string, for the log only (svce/acct are CFStrings).
static void cfstr(CFDictionaryRef d, CFStringRef key, char *out, size_t n) {
    out[0] = 0;
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, out, (CFIndex)n, kCFStringEncodingUTF8);
    else if (v) strlcpy(out, "<non-string>", n);
}
// The query's key NAMES (never values), for the trace: which attributes a
// caller asked for is what explains a crash on a returned dictionary.
static void keys_of(CFDictionaryRef d, char *out, size_t n) {
    out[0] = 0;
    if (!d) return;
    CFIndex c = CFDictionaryGetCount(d);
    const void **keys = malloc(sizeof(void *) * (size_t)(c ? c : 1));
    CFDictionaryGetKeysAndValues(d, keys, NULL);
    for (CFIndex i = 0; i < c; i++) {
        char k[64] = "?";
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) CFStringGetCString(keys[i], k, sizeof k, kCFStringEncodingUTF8);
        if (out[0]) strlcat(out, ",", n);
        strlcat(out, k, n);
    }
    free(keys);
}

static const char *cls_of(CFDictionaryRef d) {
    CFTypeRef c = d ? CFDictionaryGetValue(d, kSecClass) : NULL;
    if (!c) return "genp?";
    if (CFEqual(c, kSecClassGenericPassword)) return "genp";
    if (CFEqual(c, kSecClassInternetPassword)) return "inet";
    return "other";
}

// ── Storage ─────────────────────────────────────────────────────────────────

static void ensure_dir(const char *file) {
    char dir[PATH_MAX]; strlcpy(dir, file, sizeof dir);
    char *slash = strrchr(dir, '/'); if (!slash) return; *slash = 0;
    // mkdir -p for the two levels we may need (Library/Application Support)
    char *p = dir + 1;
    for (;;) {
        char *next = strchr(p, '/');
        if (next) *next = 0;
        mkdir(dir, 0700);
        if (!next) break;
        *next = '/'; p = next + 1;
    }
}

static void store_path(void) {
    if (g_path[0]) return;
    CFURLRef home = CFCopyHomeDirectoryURL();   // the sandbox container's Data dir
    char base[PATH_MAX] = "/tmp";
    if (home) { CFURLGetFileSystemRepresentation(home, true, (UInt8 *)base, sizeof base); CFRelease(home); }
    snprintf(g_path, sizeof g_path, "%s/Library/Application Support/ipa-keychain/items.plist", base);
}

static bool plist_value(CFTypeRef v) {
    CFTypeID t = CFGetTypeID(v);
    return t == CFStringGetTypeID() || t == CFDataGetTypeID() || t == CFNumberGetTypeID()
        || t == CFBooleanGetTypeID() || t == CFDateGetTypeID();
}

static void load_items(void) {
    if (g_items) return;
    store_path();
    g_items = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    FILE *f = fopen(g_path, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0 || n > 64 * 1024 * 1024) { fclose(f); return; }
    UInt8 *buf = malloc((size_t)n);
    size_t got = fread(buf, 1, (size_t)n, f); fclose(f);
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buf, (CFIndex)got, kCFAllocatorMalloc);
    CFPropertyListRef pl = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (pl && CFGetTypeID(pl) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(pl);
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef e = CFArrayGetValueAtIndex(pl, i);
            if (CFGetTypeID(e) != CFDictionaryGetTypeID()) continue;
            CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, e);
            CFArrayAppendValue(g_items, m); CFRelease(m);
        }
    }
    if (pl) CFRelease(pl);
}

static void copy_plistable(const void *key, const void *value, void *ctx) {
    if (CFGetTypeID(key) == CFStringGetTypeID() && plist_value(value))
        CFDictionarySetValue((CFMutableDictionaryRef)ctx, key, value);
}

static void save_items(void) {
    CFIndex count = CFArrayGetCount(g_items);
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; i++) {
        CFMutableDictionaryRef clean = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryApplyFunction(CFArrayGetValueAtIndex(g_items, i), copy_plistable, clean);
        CFArrayAppendValue(out, clean); CFRelease(clean);
    }
    CFDataRef data = CFPropertyListCreateData(kCFAllocatorDefault, out, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(out);
    if (!data) return;
    ensure_dir(g_path);
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s.tmp", g_path);
    FILE *f = fopen(tmp, "wb");
    if (f) {
        fchmod(fileno(f), 0600);
        fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), f);
        fclose(f);
        rename(tmp, g_path);
    }
    CFRelease(data);
}

// ── Matching ────────────────────────────────────────────────────────────────

static bool is_password_class(CFDictionaryRef q) {
    CFTypeRef c = CFDictionaryGetValue(q, kSecClass);
    if (!c) return true;                       // Security's default is generic password
    return CFEqual(c, kSecClassGenericPassword) || CFEqual(c, kSecClassInternetPassword);
}

static CFStringRef item_class(CFDictionaryRef q) {
    CFTypeRef c = CFDictionaryGetValue(q, kSecClass);
    return c ? (CFStringRef)c : kSecClassGenericPassword;
}

// Keys in a query that do not describe the item.
static bool ignored_key(CFTypeRef key) {
    static CFTypeRef ignore[64]; static int n = -1;
    if (n < 0) {
        n = 0;
        CFTypeRef list[] = { kSecClass, kSecReturnData, kSecReturnAttributes, kSecReturnRef, kSecReturnPersistentRef,
            kSecMatchLimit, kSecMatchCaseInsensitive, kSecMatchPolicy, kSecMatchItemList, kSecMatchSearchList,
            kSecMatchIssuers, kSecMatchEmailAddressIfPresent, kSecMatchSubjectContains, kSecMatchTrustedOnly,
            kSecMatchValidOnDate, kSecUseAuthenticationUI, kSecUseAuthenticationContext, kSecUseDataProtectionKeychain,
            CFSTR("u_OpPrompt"), CFSTR("u_ItemList"), CFSTR("m_DiacriticInsensitive"), CFSTR("m_WidthInsensitive"),
            kSecAttrAccessGroup, kSecAttrSynchronizable, kSecAttrAccessible, kSecAttrAccessControl,
            kSecValueData, kSecValueRef, kSecValuePersistentRef, kSecAttrCreationDate, kSecAttrModificationDate, kIdKey };
        for (size_t i = 0; i < sizeof list / sizeof list[0] && n < 64; i++) if (list[i]) ignore[n++] = list[i];
    }
    for (int i = 0; i < n; i++) if (CFEqual(key, ignore[i])) return true;
    return false;
}

// Keys an item KEEPS: everything that describes it, the secret, and the two
// attributes a real keychain stores on every item and always returns --
// accessibility (pdmn) and sync -- even though matching ignores both. Google's
// SSO layer reads an item back with kSecReturnAttributes and CFEquals its
// accessibility against the class it wants; with none stored that is
// CFEqual(NULL, ...) and the app traps on its second launch (measured
// 2026-09-16, Google Photos 7.92: signed in fine, then EXC_BREAKPOINT on
// com.google.ssoauth.KeychainOperationQueue at every relaunch).
static bool stored_key(CFTypeRef key, CFTypeRef value) {
    if (CFEqual(key, kSecValueData)) return true;
    if (CFEqual(key, kSecAttrAccessible)) return CFGetTypeID(value) == CFStringGetTypeID();
    if (CFEqual(key, kSecAttrSynchronizable))
        return CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID();
    return !ignored_key(key);
}

// What a real keychain answers for an item that never set them: the default
// accessibility, kSecAttrAccessibleWhenUnlocked, and not synchronizable.
static void add_defaults(CFMutableDictionaryRef out) {
    if (!CFDictionaryContainsKey(out, kSecAttrAccessible))
        CFDictionarySetValue(out, kSecAttrAccessible, kSecAttrAccessibleWhenUnlocked);
    if (!CFDictionaryContainsKey(out, kSecAttrSynchronizable)) {
        int zero = 0;
        CFNumberRef z = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
        CFDictionarySetValue(out, kSecAttrSynchronizable, z);
        CFRelease(z);
    }
}

struct match_ctx { CFDictionaryRef item; bool ok; };
static void match_key(const void *key, const void *value, void *ctx) {
    struct match_ctx *m = ctx;
    if (!m->ok || ignored_key(key)) return;
    CFTypeRef have = CFDictionaryGetValue(m->item, key);
    if (!have || !CFEqual(have, value)) m->ok = false;
}

static bool item_matches(CFDictionaryRef item, CFDictionaryRef query) {
    if (!CFEqual(item_class(item), item_class(query))) return false;
    CFTypeRef pref = CFDictionaryGetValue(query, kSecValuePersistentRef);
    if (pref) {
        CFTypeRef id = CFDictionaryGetValue(item, kIdKey);
        if (!id || CFGetTypeID(pref) != CFDataGetTypeID()) return false;
        CFStringRef s = CFStringCreateFromExternalRepresentation(kCFAllocatorDefault, pref, kCFStringEncodingUTF8);
        bool same = s && CFEqual(s, id); if (s) CFRelease(s);
        if (!same) return false;
    }
    struct match_ctx m = { item, true };
    CFDictionaryApplyFunction(query, match_key, &m);
    return m.ok;
}

static CFMutableArrayRef find_matches(CFDictionaryRef query) {
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFIndex count = CFArrayGetCount(g_items);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef it = CFArrayGetValueAtIndex(g_items, i);
        if (item_matches(it, query)) CFArrayAppendValue(out, it);
    }
    return out;
}

// Primary keys per class: two items are the same item when these agree
// (absent on both sides counts as agreeing, as the keychain's empty string).
static bool same_primary(CFDictionaryRef a, CFDictionaryRef b) {
    CFStringRef cls = item_class(a);
    if (!CFEqual(cls, item_class(b))) return false;
    CFTypeRef genp[] = { kSecAttrAccount, kSecAttrService, NULL };
    CFTypeRef inet[] = { kSecAttrAccount, kSecAttrServer, kSecAttrProtocol, kSecAttrAuthenticationType,
                         kSecAttrPort, kSecAttrPath, kSecAttrSecurityDomain, NULL };
    CFTypeRef *keys = CFEqual(cls, kSecClassInternetPassword) ? inet : genp;
    for (int i = 0; keys[i]; i++) {
        CFTypeRef x = CFDictionaryGetValue(a, keys[i]), y = CFDictionaryGetValue(b, keys[i]);
        if (!x && !y) continue;
        if (!x || !y || !CFEqual(x, y)) return false;
    }
    return true;
}

// ── Result formatting ───────────────────────────────────────────────────────

static bool flag(CFDictionaryRef q, CFStringRef key) {
    CFTypeRef v = CFDictionaryGetValue(q, key);
    return v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v);
}

static CFDataRef persistent_ref(CFDictionaryRef item) {
    CFTypeRef id = CFDictionaryGetValue(item, kIdKey);
    if (!id) return NULL;
    return CFStringCreateExternalRepresentation(kCFAllocatorDefault, id, kCFStringEncodingUTF8, 0);
}

static CFTypeRef format_item(CFDictionaryRef item, CFDictionaryRef q) {
    bool wantData = flag(q, kSecReturnData), wantAttrs = flag(q, kSecReturnAttributes);
    bool wantRef = flag(q, kSecReturnRef), wantPRef = flag(q, kSecReturnPersistentRef);
    CFTypeRef data = CFDictionaryGetValue(item, kSecValueData);
    if (wantData && !wantAttrs && !wantRef && !wantPRef) return data ? CFRetain(data) : NULL;
    if (wantPRef && !wantAttrs && !wantRef && !wantData) return persistent_ref(item);
    CFMutableDictionaryRef out = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, item);
    CFDictionaryRemoveValue(out, kIdKey);
    if (!CFDictionaryContainsKey(out, kSecAttrAccessGroup)) CFDictionarySetValue(out, kSecAttrAccessGroup, access_group());
    add_defaults(out);
    if (!wantData) CFDictionaryRemoveValue(out, kSecValueData);
    if (wantPRef) { CFDataRef p = persistent_ref(item); if (p) { CFDictionarySetValue(out, kSecValuePersistentRef, p); CFRelease(p); } }
    return out;
}

// ── Access group ────────────────────────────────────────────────────────────
static CFStringRef g_group = NULL;
static CFStringRef access_group(void) {
    if (g_group) return g_group;
    CFBundleRef mb = CFBundleGetMainBundle();
    CFStringRef bid = mb ? CFBundleGetIdentifier(mb) : NULL;
    char id[512] = "app";
    if (bid) CFStringGetCString(bid, id, sizeof id, kCFStringEncodingUTF8);
    unsigned long long h = 1469598103934665603ULL;            // FNV-1a over the bundle id
    for (const char *c = id; *c; c++) { h ^= (unsigned char)*c; h *= 1099511628211ULL; }
    static const char alpha[] = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    char seed[11];
    for (int i = 0; i < 10; i++) { seed[i] = alpha[h % 32]; h /= 32; }
    seed[10] = 0;
    char buf[600]; snprintf(buf, sizeof buf, "%s.%s", seed, id);
    g_group = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
    return g_group;
}

// ── The four entry points ───────────────────────────────────────────────────

static OSStatus ipa_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!query || !is_password_class(query)) return SecItemCopyMatching(query, result);
    pthread_mutex_lock(&g_lock);
    load_items();
    CFMutableArrayRef hits = find_matches(query);
    { char a[256], sv[256]; cfstr(query, kSecAttrAccount, a, sizeof a); cfstr(query, kSecAttrService, sv, sizeof sv);
      char ks[512]; keys_of(query, ks, sizeof ks);
      klog("copy  %s acct=%s svce=%s keys=%s -> %ld match(es)", cls_of(query), a, sv, ks, (long)CFArrayGetCount(hits)); }
    OSStatus rc = errSecItemNotFound;
    if (CFArrayGetCount(hits) > 0) {
        rc = errSecSuccess;
        if (result) {
            CFTypeRef limit = CFDictionaryGetValue(query, kSecMatchLimit);
            if (limit && CFEqual(limit, kSecMatchLimitAll)) {
                CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
                for (CFIndex i = 0; i < CFArrayGetCount(hits); i++) {
                    CFTypeRef f = format_item(CFArrayGetValueAtIndex(hits, i), query);
                    if (f) { CFArrayAppendValue(arr, f); CFRelease(f); }
                }
                *result = arr;
            } else {
                *result = format_item(CFArrayGetValueAtIndex(hits, 0), query);
            }
        }
    }
    CFRelease(hits);
    pthread_mutex_unlock(&g_lock);
    return rc;
}

static OSStatus ipa_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!attributes || !is_password_class(attributes)) return SecItemAdd(attributes, result);
    pthread_mutex_lock(&g_lock);
    load_items();
    CFMutableDictionaryRef item = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    // keep the attributes and the secret, drop the request flags
    CFIndex n = CFDictionaryGetCount(attributes);
    const void **keys = malloc(sizeof(void *) * (size_t)n), **vals = malloc(sizeof(void *) * (size_t)n);
    CFDictionaryGetKeysAndValues(attributes, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        if (CFEqual(keys[i], kSecClass) || stored_key(keys[i], vals[i]))
            CFDictionarySetValue(item, keys[i], vals[i]);
    }
    free(keys); free(vals);
    CFDictionarySetValue(item, kSecClass, item_class(attributes));
    {
        CFTypeRef g = CFDictionaryGetValue(attributes, kSecAttrAccessGroup);
        CFDictionarySetValue(item, kSecAttrAccessGroup,
            (g && CFGetTypeID(g) == CFStringGetTypeID()) ? g : (CFTypeRef)access_group());
    }
    OSStatus rc = errSecSuccess;
    for (CFIndex i = 0; i < CFArrayGetCount(g_items); i++)
        if (same_primary(CFArrayGetValueAtIndex(g_items, i), item)) { rc = errSecDuplicateItem; break; }
    { char a[256], sv[256]; cfstr(attributes, kSecAttrAccount, a, sizeof a); cfstr(attributes, kSecAttrService, sv, sizeof sv);
      klog("add   %s acct=%s svce=%s data=%s -> %s", cls_of(attributes), a, sv,
           CFDictionaryGetValue(attributes, kSecValueData) ? "yes" : "no", rc == errSecSuccess ? "ok" : "dup"); }
    if (rc == errSecSuccess) {
        CFDateRef now = CFDateCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent());
        CFDictionarySetValue(item, kSecAttrCreationDate, now);
        CFDictionarySetValue(item, kSecAttrModificationDate, now);
        CFRelease(now);
        CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
        CFStringRef id = CFUUIDCreateString(kCFAllocatorDefault, uuid);
        CFDictionarySetValue(item, kIdKey, id); CFRelease(id); CFRelease(uuid);
        CFArrayAppendValue(g_items, item);
        save_items();
        if (result) *result = format_item(item, attributes);
    }
    CFRelease(item);
    pthread_mutex_unlock(&g_lock);
    return rc;
}

static void apply_update(const void *key, const void *value, void *ctx) {
    if (stored_key(key, value)) CFDictionarySetValue((CFMutableDictionaryRef)ctx, key, value);
}

static OSStatus ipa_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef update) {
    if (!query || !update || !is_password_class(query)) return SecItemUpdate(query, update);
    pthread_mutex_lock(&g_lock);
    load_items();
    CFMutableArrayRef hits = find_matches(query);
    { char a[256], sv[256]; cfstr(query, kSecAttrAccount, a, sizeof a); cfstr(query, kSecAttrService, sv, sizeof sv);
      klog("update %s acct=%s svce=%s -> %ld match(es)", cls_of(query), a, sv, (long)CFArrayGetCount(hits)); }
    OSStatus rc = errSecItemNotFound;
    if (CFArrayGetCount(hits) > 0) {
        CFDateRef now = CFDateCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent());
        for (CFIndex i = 0; i < CFArrayGetCount(hits); i++) {
            CFMutableDictionaryRef it = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(hits, i);
            CFDictionaryApplyFunction(update, apply_update, it);
            CFDictionarySetValue(it, kSecAttrModificationDate, now);
        }
        CFRelease(now);
        save_items();
        rc = errSecSuccess;
    }
    CFRelease(hits);
    pthread_mutex_unlock(&g_lock);
    return rc;
}

static OSStatus ipa_SecItemDelete(CFDictionaryRef query) {
    if (!query || !is_password_class(query)) return SecItemDelete(query);
    pthread_mutex_lock(&g_lock);
    load_items();
    OSStatus rc = errSecItemNotFound;
    for (CFIndex i = CFArrayGetCount(g_items) - 1; i >= 0; i--) {
        if (item_matches(CFArrayGetValueAtIndex(g_items, i), query)) { CFArrayRemoveValueAtIndex(g_items, i); rc = errSecSuccess; }
    }
    { char a[256], sv[256]; cfstr(query, kSecAttrAccount, a, sizeof a); cfstr(query, kSecAttrService, sv, sizeof sv);
      klog("delete %s acct=%s svce=%s -> %s", cls_of(query), a, sv, rc == errSecSuccess ? "ok" : "none"); }
    if (rc == errSecSuccess) save_items();
    pthread_mutex_unlock(&g_lock);
    return rc;
}

DYLD_INTERPOSE(ipa_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(ipa_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(ipa_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(ipa_SecItemDelete, SecItemDelete)
