// Keep an ad-hoc signed iOS app's calls off CallKit, which cannot serve it.
//
// Why: callservicesd keys every CallKit client by its application
// identifier, and an ad-hoc signature has none (only a provisioning profile
// grants one; claiming it ad-hoc makes AMFI refuse to spawn the app). So the
// daemon refuses the app's provider at every launch ("Not accepting
// connection ... callsourcehost because a CXXPCCallSource couldn't be
// created"), and when the app places a call its CXStartCallAction arrives
// "for connection with identifier: (null)" and callservicesd itself dies on
// -[__NSDictionaryM setObject:forKeyedSubscript:] with a nil key. The call
// never reaches audio, camera or network. Measured 2026-11-11 on macOS 27.3
// with WhatsApp 26.42.77 (Watusi build), voice and video alike.
//
// What: an app with its own non-CallKit call path asks itself, per call,
// whether to use CallKit. Each such question listed in kRules is answered
// "no CallKit" in every class of the app's own images loaded at launch that
// implements it, found by selector so a renamed class does not matter (a
// framework the app dlopens later is not scanned; nor is a second class of
// the same name, objc_getClass answering the first). A selector an app
// does not have changes nothing, so the library is safe in any app that links
// CallKit; an app with no fallback path gains nothing, and its calls stay as
// broken as CallKit leaves them.
//
// WhatsApp, measured the same day: 11 methods in WACallManager,
// WACallManagerBase and WACallProviderDelegate; with them answered, a voice
// call connected (audio through WhatsApp's own session, no callservicesd
// involvement) where it had crashed callservicesd before.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <string.h>

static const struct { const char *sel; BOOL answer; } kRules[] = {
    // WhatsApp (WACallManager, WACallManagerBase, WACallProviderDelegate)
    { "isCallKitSupported", NO },
    { "isCallKitDisabled", YES },
    { "callDataManagerRequestShouldUseCallKitForCall:", NO },
    { "shouldUseCallKitForVoiceChatReRings", NO },
    { "shouldUseCallKitForCallWithVideo:isGroupCall:groupJID:isGroupCallUpgradedBeforeConnected:isBot:isVoiceChat:isRering:", NO },
    { "shouldUseCallKitForCallWithVideo:isGroupCall:groupJID:isGroupCallUpgradedBeforeConnected:isPushed:isBot:isVoiceChat:isRering:", NO },
};
#define NRULES (sizeof kRules / sizeof kRules[0])

// The replacements read nothing past self and _cmd, so one function serves
// every arity: on arm64 the remaining arguments sit in registers the callee
// simply ignores.
static BOOL answer_no(id self, SEL _cmd) { return NO; }
static BOOL answer_yes(id self, SEL _cmd) { return YES; }

static int answer_in(Class cls, NSMutableArray<NSString *> *done) {
    int n = 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);   // the class's own, not inherited
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        for (size_t r = 0; r < NRULES; r++) {
            if (strcmp(name, kRules[r].sel) != 0) continue;
            char ret[8];
            method_getReturnType(methods[i], ret, sizeof ret);
            if (strcmp(ret, "B") != 0 && strcmp(ret, "c") != 0) continue;   // not a BOOL question
            method_setImplementation(methods[i], (IMP)(kRules[r].answer ? answer_yes : answer_no));
            [done addObject:[NSString stringWithFormat:@"%c[%s %s]",
                             class_isMetaClass(cls) ? '+' : '-', class_getName(cls), name]];
            n++;
        }
    }
    free(methods);
    return n;
}

// Classes are registered for every image loaded at launch before any
// initializer runs, so the app's own classes are all visible here.
__attribute__((constructor)) static void ipa_callkit_init(void) {
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundlePath];
        if (!bundle) return;
        NSMutableArray<NSString *> *done = [NSMutableArray array];
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *path = _dyld_get_image_name(i);
            if (!path || ![@(path) hasPrefix:bundle]) continue;   // the app's own code only
            unsigned int count = 0;
            const char **names = objc_copyClassNamesForImage(path, &count);
            for (unsigned int c = 0; c < count; c++) {
                Class cls = objc_getClass(names[c]);
                if (!cls) continue;
                answer_in(cls, done);
                answer_in(object_getClass(cls), done);
            }
            free(names);
        }
        if (done.count)
            NSLog(@"ipacallkit: %lu CallKit checks now answer no-CallKit: %@",
                  (unsigned long)done.count, [done componentsJoinedByString:@", "]);
    }
}
