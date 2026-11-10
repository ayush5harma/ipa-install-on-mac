// Keep an iOS app's camera frame-rate requests inside what a Mac camera does.
//
// Why: iPhone cameras offer variable frame-rate ranges (1-30 fps and the
// like), so iOS apps set activeVideoMinFrameDuration and
// activeVideoMaxFrameDuration freely. Many Mac webcams offer one fixed rate
// per format, and AVFoundation throws NSInvalidArgumentException for any
// duration outside the active format's ranges. Measured 2026-11-11 on macOS
// 27.3, WhatsApp 26.42.77 video call on a Lenovo FHD Webcam (1280x720
// '420v', {30-30 fps}): "Unsupported frame duration - Supported ranges:
// 30 - 30, tried to set minFrameRate to 10", uncaught, SIGABRT. The throw
// happens inside AVFoundation's own dispatch_barrier_sync on the device's
// state queue, so catching it in the app would unwind through libdispatch
// with that queue still held; the request is corrected before it gets there.
//
// What: both setters are wrapped on AVCaptureDevice and its two concrete
// classes, each of which implements them itself (measured on macOS 27.3). A
// duration inside one of the active format's ranges, or kCMTimeInvalid (the
// documented "reset to the default"), passes through untouched; anything else
// becomes the nearest bound of the nearest range. Each wrapper calls its own
// method's original, so a subclass setter that calls super does not loop.
// With it, the same WhatsApp video call ran at 30 fps.

#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdatomic.h>

// A call sets these a few times; the cap only bounds an app that loops.
#define MAX_LOG_LINES 20
static atomic_int logged;

static CMTime supported_duration(AVCaptureDevice *device, CMTime wanted) {
    if (!CMTIME_IS_VALID(wanted)) return wanted;
    CMTime best = wanted;
    double best_gap = INFINITY;
    for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
        CMTime lo = range.minFrameDuration, hi = range.maxFrameDuration;
        if (CMTimeCompare(wanted, lo) >= 0 && CMTimeCompare(wanted, hi) <= 0) return wanted;
        CMTime edge = CMTimeCompare(wanted, lo) < 0 ? lo : hi;
        double gap = fabs(CMTimeGetSeconds(edge) - CMTimeGetSeconds(wanted));
        if (gap < best_gap) { best_gap = gap; best = edge; }
    }
    return best;
}

// Returns how many methods it wrapped: 0 when the class is gone or no longer
// implements the setter itself, which the load-time log line makes visible.
static int wrap(NSString *class_name, SEL sel) {
    Class cls = NSClassFromString(class_name);
    if (!cls) return 0;
    int wrapped = 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);   // the class's own, not inherited
    for (unsigned int i = 0; i < count; i++) {
        if (!sel_isEqual(method_getName(methods[i]), sel)) continue;
        void (*original)(id, SEL, CMTime) = (void (*)(id, SEL, CMTime))method_getImplementation(methods[i]);
        IMP wrapper = imp_implementationWithBlock(^(AVCaptureDevice *device, CMTime wanted) {
            CMTime use = supported_duration(device, wanted);
            if (CMTimeCompare(use, wanted) != 0 && atomic_fetch_add(&logged, 1) < MAX_LOG_LINES)
                NSLog(@"ipacamera: %s on %@: %.2f fps is outside the active format, using %.2f fps",
                      sel_getName(sel), device.localizedName,
                      1.0 / CMTimeGetSeconds(wanted), 1.0 / CMTimeGetSeconds(use));
            original(device, sel, use);
        });
        method_setImplementation(methods[i], wrapper);
        wrapped++;
    }
    free(methods);
    return wrapped;
}

__attribute__((constructor)) static void ipa_camera_init(void) {
    @autoreleasepool {
        int wrapped = 0;
        for (NSString *name in @[ @"AVCaptureDevice", @"AVCaptureFigVideoDevice", @"AVCaptureDALDevice" ]) {
            wrapped += wrap(name, @selector(setActiveVideoMinFrameDuration:));
            wrapped += wrap(name, @selector(setActiveVideoMaxFrameDuration:));
        }
        // 6 on macOS 27.3: both setters on each of the three classes.
        NSLog(@"ipacamera: wrapped %d frame-duration setters", wrapped);
    }
}
