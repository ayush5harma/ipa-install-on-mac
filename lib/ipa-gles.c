// ipa-gles: OpenGL ES function lookups in an iOS app converted to Mac Catalyst
// answer with OpenGL ES, as they would on iOS.
//
// WHY (measured 2026-09-16, macOS 27.0, Google Photos 7.92 and a probe app)
//   A converted app's own GL calls are fine: they are bound, two-level, to
//   /System/iOSSupport/.../OpenGLES.framework, a Metal-backed OpenGL ES
//   ("OpenGL ES 2.0 Metal - 102") that works -- glCreateShader returns 1 with
//   an EAGLContext current, and 0, harmlessly, with no context current. But every Catalyst
//   process also has macOS's desktop OpenGL.framework loaded, and it comes
//   first in the global search order, so dlsym(RTLD_DEFAULT, "glCreateShader")
//   returns desktop libGL's glCreateShader -- whose dispatch goes through the
//   CGL current context, which EAGL never sets (it stays NULL throughout). A
//   GL library that resolves its entry points at run time (Google's Ion,
//   under the Ink drawing engine behind Google Photos' editor) therefore calls
//   desktop GL and dies at the first call: EXC_BAD_ACCESS at 0x1298 inside
//   libGL's glCreateShader. On iOS that search could only ever find OpenGL ES.
//
// WHAT
//   dlsym is interposed. dlsym(RTLD_DEFAULT, "gl...") answers OpenGL ES's
//   symbol when OpenGL ES has one, NULL when only desktop GL does (iOS has no
//   such symbol either), and everything else -- other handles, other names,
//   "glob" -- is the real dlsym, reached by a guaranteed tail call so that it
//   still sees the ORIGINAL caller's return address: RTLD_NEXT and RTLD_SELF
//   are resolved relative to the caller, and a normal call from here would
//   make every such lookup relative to this library instead.
//
// Build (ipa-install-on-mac does this at install time, for apps that link
// OpenGLES):
//   xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
//     -O2 -Wall -dynamiclib -install_name @executable_path/Frameworks/libipagles.dylib \
//     -o libipagles.dylib ipa-gles.c

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static void *g_gles, *g_desktop;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void open_libraries(void) {
    // The iOS path; dyld maps it to the iOSSupport copy in a Catalyst process.
    // RTLD_FIRST: a lookup through these handles searches that image only,
    // not its dependencies -- without it "glob" resolved through OpenGLES's
    // libSystem dependency instead of reaching the real dlsym.
    g_gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST);
    // Already loaded in every Catalyst process; NOLOAD so this never loads it.
    g_desktop = dlopen("/System/Library/Frameworks/OpenGL.framework/Versions/A/Libraries/libGL.dylib",
                       RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
}

// The real dlsym: calls from this image are not interposed by its own tuple.
static void *real_dlsym(void *handle, const char *name) {
    return dlsym(handle, name);
}

// True when this lookup is one iOS would have answered on its own, with the
// answer in *found: OpenGL ES's symbol, or NULL for an entry point that only
// desktop GL has and iOS never did. False means "not ours, ask the real dlsym".
static bool gles_answers(const char *name, void **found) {
    *found = NULL;
    pthread_once(&g_once, open_libraries);
    if (!g_gles) return false;
    void *p = real_dlsym(g_gles, name);
    if (p) { *found = p; return true; }
    return g_desktop && real_dlsym(g_desktop, name);
}

static void *ipa_dlsym(void *handle, const char *name) {
    if (handle == RTLD_DEFAULT && name && name[0] == 'g' && name[1] == 'l') {
        void *found;
        if (gles_answers(name, &found)) return found;
    }
    __attribute__((musttail)) return dlsym(handle, name);
}

DYLD_INTERPOSE(ipa_dlsym, dlsym)
