// The probe for test/call-shims.sh's CallKit checks: linked against
// libipacallkit, whose constructor scans this binary's classes at load. The
// classes below have the shapes WhatsApp's call manager has (instance and
// class methods, a many-argument selector), plus two the library must leave
// alone: a selector it knows that does not return BOOL, and a BOOL method it
// does not know. Each answer is printed as NAME=0/1 for the script to read.

#import <Foundation/Foundation.h>
#include <stdio.h>

@interface ProbeCallManager : NSObject
- (BOOL)isCallKitSupported;
+ (BOOL)isCallKitSupported;
- (BOOL)isCallKitDisabled;
- (BOOL)callDataManagerRequestShouldUseCallKitForCall:(id)call;
- (BOOL)shouldUseCallKitForCallWithVideo:(BOOL)video isGroupCall:(BOOL)group groupJID:(id)jid
        isGroupCallUpgradedBeforeConnected:(BOOL)upgraded isBot:(BOOL)bot isVoiceChat:(BOOL)chat isRering:(BOOL)rering;
- (BOOL)isMuted;
@end
@implementation ProbeCallManager
- (BOOL)isCallKitSupported { return YES; }
+ (BOOL)isCallKitSupported { return YES; }
- (BOOL)isCallKitDisabled { return NO; }
- (BOOL)callDataManagerRequestShouldUseCallKitForCall:(id)call { return YES; }
- (BOOL)shouldUseCallKitForCallWithVideo:(BOOL)video isGroupCall:(BOOL)group groupJID:(id)jid
        isGroupCallUpgradedBeforeConnected:(BOOL)upgraded isBot:(BOOL)bot isVoiceChat:(BOOL)chat isRering:(BOOL)rering { return YES; }
- (BOOL)isMuted { return YES; }
@end

@interface ProbeOther : NSObject
- (id)isCallKitSupported;   // same name, not a BOOL: not the library's to answer
@end
@implementation ProbeOther
- (id)isCallKitSupported { return @"untouched"; }
@end

int main(void) {
    @autoreleasepool {
        ProbeCallManager *m = [ProbeCallManager new];
        printf("supported=%d\n", [m isCallKitSupported]);
        printf("class_supported=%d\n", [ProbeCallManager isCallKitSupported]);
        printf("disabled=%d\n", [m isCallKitDisabled]);
        printf("request=%d\n", [m callDataManagerRequestShouldUseCallKitForCall:nil]);
        printf("per_call=%d\n", [m shouldUseCallKitForCallWithVideo:YES isGroupCall:NO groupJID:nil
                                     isGroupCallUpgradedBeforeConnected:NO isBot:NO isVoiceChat:NO isRering:NO]);
        printf("unrelated=%d\n", [m isMuted]);
        printf("non_bool=%s\n", [[[ProbeOther new] isCallKitSupported] UTF8String]);
    }
    return 0;
}
