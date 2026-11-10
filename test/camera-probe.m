// The probe for test/call-shims.sh's camera checks. A real camera needs a
// camera permission prompt, so the library's source is compiled in and its
// wrapper is applied to stand-ins with the same shape: a device whose active
// format has given frame-rate ranges, and a subclass whose setter calls
// super, as AVFoundation's concrete classes may. Each result is printed as
// NAME=value for the script to read.

#include "../lib/ipa-camera.m"
#include <stdio.h>

@interface ProbeRange : NSObject
@property CMTime minFrameDuration, maxFrameDuration;
@end
@implementation ProbeRange
@end

@interface ProbeFormat : NSObject
@property NSArray *videoSupportedFrameRateRanges;
@end
@implementation ProbeFormat
@end

static CMTime last_set;
static int base_calls, sub_calls;

@interface ProbeDevice : NSObject
@property ProbeFormat *activeFormat;
@property NSString *localizedName;
@end
@implementation ProbeDevice
- (void)setActiveVideoMaxFrameDuration:(CMTime)d { base_calls++; last_set = d; }
@end

@interface ProbeSubDevice : ProbeDevice
@end
@implementation ProbeSubDevice
- (void)setActiveVideoMaxFrameDuration:(CMTime)d { sub_calls++; [super setActiveVideoMaxFrameDuration:d]; }
@end

static ProbeRange *range(int min_fps, int max_fps) {
    ProbeRange *r = [ProbeRange new];
    r.minFrameDuration = CMTimeMake(1, max_fps);
    r.maxFrameDuration = CMTimeMake(1, min_fps);
    return r;
}

static void set_fps(ProbeDevice *d, const char *label, int fps) {
    base_calls = sub_calls = 0;
    [d setActiveVideoMaxFrameDuration:fps ? CMTimeMake(1, fps) : kCMTimeInvalid];
    if (!CMTIME_IS_VALID(last_set)) printf("%s=invalid calls=%d/%d\n", label, sub_calls, base_calls);
    else printf("%s=%g calls=%d/%d\n", label, 1.0 / CMTimeGetSeconds(last_set), sub_calls, base_calls);
}

int main(void) {
    @autoreleasepool {
        wrap(@"ProbeDevice", @selector(setActiveVideoMaxFrameDuration:));
        wrap(@"ProbeSubDevice", @selector(setActiveVideoMaxFrameDuration:));
        ProbeFormat *fixed = [ProbeFormat new];
        fixed.videoSupportedFrameRateRanges = @[ range(30, 30) ];
        ProbeSubDevice *d = [ProbeSubDevice new];
        d.activeFormat = fixed;
        d.localizedName = @"probe 30-30";
        set_fps(d, "fixed_10", 10);       // WhatsApp's request on the Lenovo webcam
        set_fps(d, "fixed_30", 30);
        set_fps(d, "fixed_reset", 0);
        ProbeFormat *wide = [ProbeFormat new];
        wide.videoSupportedFrameRateRanges = @[ range(5, 30) ];
        d.activeFormat = wide;
        set_fps(d, "wide_10", 10);
        set_fps(d, "wide_60", 60);
        ProbeFormat *two = [ProbeFormat new];
        two.videoSupportedFrameRateRanges = @[ range(15, 15), range(60, 60) ];
        d.activeFormat = two;
        set_fps(d, "two_50", 50);
    }
    return 0;
}
