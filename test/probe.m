// The test probe: an iOS app that reports what the Mac hands it, so an
// install can be judged by effect rather than by exit status. Every line
// goes to Documents/probe.log in the app's home, which after an
// ipa-install-on-mac install is ~/Library/Containers/<bundle id>/Data.
//
//   launch   idiom, screen bounds/native bounds/scale, device model as UIKit
//            and sysctl report it (a spoofed model shows up here)
//   layout   the view and window size on every layout pass (window resizes,
//            a forced resolution)
//   touch    every touch phase with its point and its position as a
//            fraction of the view -- a keymapped key arrives as a touch
//   press    hardware key presses that reach the responder chain
//   text     the text field's contents as typed
//   keychain a generic password added on the first launch and read back on
//            every later one (the installer's keychain shim, or PlayChain)
//   gl       which image dlsym(RTLD_DEFAULT, "glCreateShader") resolves to
//            (the probe links OpenGL ES, so the installer adds its redirect)
//
// Built by test/make-probe-ipa.sh; no Xcode project.
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <OpenGLES/ES2/gl.h>
#include <dlfcn.h>
#include <sys/sysctl.h>

static NSString *logPath;

// From the embedded ProbeKit.framework (test/make-probe-ipa.sh).
extern const char *probekit_hello(void);

static void plog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void plog(NSString *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSString *line = [NSString stringWithFormat:@"%.3f %@\n", NSDate.date.timeIntervalSince1970, msg];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:logPath];
  if (!h) {
    [data writeToFile:logPath atomically:NO];
    return;
  }
  [h seekToEndOfFile];
  [h writeData:data];
  [h closeFile];
}

static NSString *sysctlString(const char *name) {
  size_t len = 0;
  if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return @"?";
  char *buf = malloc(len);
  if (!buf || sysctlbyname(name, buf, &len, NULL, 0) != 0) { free(buf); return @"?"; }
  NSString *s = [NSString stringWithUTF8String:buf];
  free(buf);
  return s ?: @"?";
}

// One generic password: read it back if an earlier launch stored it, else
// store one. A keychain that does not persist logs "add" on every launch.
static void keychainRoundTrip(void) {
  NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                          (__bridge id)kSecAttrService: @"ipa-probe", (__bridge id)kSecAttrAccount: @"probe",
                          (__bridge id)kSecReturnData: @YES};
  CFTypeRef result = NULL;
  OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (rc == errSecSuccess && result) {
    NSString *v = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding];
    plog(@"keychain read=%@", v);
    return;
  }
  NSString *value = [NSString stringWithFormat:@"v-%.0f", NSDate.date.timeIntervalSince1970];
  NSDictionary *item = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: @"ipa-probe", (__bridge id)kSecAttrAccount: @"probe",
                         (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding]};
  plog(@"keychain miss=%d add=%d value=%@", (int)rc, (int)SecItemAdd((__bridge CFDictionaryRef)item, NULL), value);
}

static void glLookup(void) {
  Dl_info info = {0};
  void *p = dlsym(RTLD_DEFAULT, "glCreateShader");
  const char *img = (p && dladdr(p, &info) && info.dli_fname) ? strrchr(info.dli_fname, '/') + 1 : "none";
  // glGetError keeps the OpenGL ES link: the installer adds its redirect
  // only to apps that link it.
  plog(@"gl lookup=%s linked=%p", img, (void *)glGetError);
}

@interface ProbeView : UIView
@property(nonatomic, strong) UITextField *field;
@property(nonatomic, strong) NSMutableArray<NSValue *> *marks;
@end

@implementation ProbeView
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.systemBackgroundColor;
    self.multipleTouchEnabled = YES;
    _marks = [NSMutableArray array];
    _field = [[UITextField alloc] initWithFrame:CGRectMake(24, 60, 320, 36)];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.placeholder = @"type here";
    _field.accessibilityIdentifier = @"probe.field";
    [_field addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
    [self addSubview:_field];
  }
  return self;
}

- (void)textChanged:(UITextField *)f {
  plog(@"text \"%@\"", f.text);
}

- (void)report:(NSString *)phase touches:(NSSet<UITouch *> *)touches {
  CGSize s = self.bounds.size;
  for (UITouch *t in touches) {
    CGPoint p = [t locationInView:self];
    plog(@"touch %@ x=%.1f y=%.1f nx=%.3f ny=%.3f view=%.0fx%.0f", phase, p.x, p.y,
         s.width > 0 ? p.x / s.width : 0, s.height > 0 ? p.y / s.height : 0, s.width, s.height);
    if ([phase isEqualToString:@"began"]) {
      [self.marks addObject:[NSValue valueWithCGPoint:p]];
      if (self.marks.count > 12) [self.marks removeObjectAtIndex:0];
      [self setNeedsDisplay];
    }
  }
}

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"began" touches:t]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"moved" touches:t]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"ended" touches:t]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"cancelled" touches:t]; }

// A crosshair at the centre and a dot per recent touch, so a screenshot is
// evidence too.
- (void)drawRect:(CGRect)rect {
  CGSize s = self.bounds.size;
  [UIColor.systemGrayColor setStroke];
  UIBezierPath *cross = [UIBezierPath bezierPath];
  [cross moveToPoint:CGPointMake(s.width / 2 - 20, s.height / 2)];
  [cross addLineToPoint:CGPointMake(s.width / 2 + 20, s.height / 2)];
  [cross moveToPoint:CGPointMake(s.width / 2, s.height / 2 - 20)];
  [cross addLineToPoint:CGPointMake(s.width / 2, s.height / 2 + 20)];
  [cross stroke];
  [UIColor.systemRedColor setFill];
  for (NSValue *v in self.marks) {
    CGPoint p = v.CGPointValue;
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x - 8, p.y - 8, 16, 16)] fill];
  }
  NSString *size = [NSString stringWithFormat:@"%.0f x %.0f pt", s.width, s.height];
  [size drawAtPoint:CGPointMake(24, 110)
     withAttributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                      NSForegroundColorAttributeName: UIColor.labelColor}];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  plog(@"layout view=%.0fx%.0f window=%@", self.bounds.size.width, self.bounds.size.height,
       NSStringFromCGRect(self.window.frame));
  [self setNeedsDisplay];
}
@end

@interface ProbeViewController : UIViewController
@end

@implementation ProbeViewController
- (void)loadView {
  self.view = [[ProbeView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  for (UIPress *p in presses) {
    plog(@"press began key=\"%@\" usage=%ld", p.key.charactersIgnoringModifiers ?: @"", (long)p.key.keyCode);
  }
  [super pressesBegan:presses withEvent:event];
}
@end

// Scene lifecycle: UIKit traps an app linked against the iOS 27 SDK that
// has not adopted it (_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption),
// on iOS and in a converted app alike once the installer keeps the binary's
// own SDK version.
@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  UIWindowScene *ws = (UIWindowScene *)scene;
  UIScreen *sc = ws.screen;
  plog(@"launch idiom=%ld screen=%.0fx%.0f native=%.0fx%.0f scale=%.2f nativeScale=%.2f model=\"%@\" "
       @"hw.machine=%@ hw.model=%@ bundle=%@ %s",
       (long)UIDevice.currentDevice.userInterfaceIdiom, sc.bounds.size.width, sc.bounds.size.height,
       sc.nativeBounds.size.width, sc.nativeBounds.size.height, sc.scale, sc.nativeScale,
       UIDevice.currentDevice.model, sysctlString("hw.machine"), sysctlString("hw.model"),
       NSBundle.mainBundle.bundleIdentifier, probekit_hello());
  self.window = [[UIWindow alloc] initWithWindowScene:ws];
  self.window.rootViewController = [ProbeViewController new];
  [self.window makeKeyAndVisible];
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
  NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
  [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:NULL];
  logPath = [docs stringByAppendingPathComponent:@"probe.log"];
  keychainRoundTrip();
  glLookup();
  return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
  c.delegateClass = ProbeSceneDelegate.class;
  return c;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
  }
}
