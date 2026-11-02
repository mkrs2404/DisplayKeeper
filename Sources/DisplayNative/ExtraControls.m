#import "ExtraControls.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

// No static reference to Apple's private class is linked. Every selector used
// below is checked against the loaded class's actual Objective-C ABI first.
@protocol DKMonitorPanelDisplay <NSObject>
- (instancetype)initWithCGSDisplayID:(int32_t)displayID;
- (int32_t)displayID;
- (BOOL)hasHDRModes;
- (BOOL)preferHDRModes;
- (void)setPreferHDRModes:(BOOL)enabled;
- (BOOL)canChangeOrientation;
- (void)setOrientation:(int32_t)degrees;
@end

static char *DKExtraError(NSString *message) {
    return strdup(message.UTF8String ?: "The display operation failed.");
}

static BOOL DKExtraDisplayIsOnline(uint32_t displayID) {
    // A sentinel such as UINT32_MAX can be accepted by private interfaces, so
    // require actual inventory membership before constructing or mutating it.
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return NO;
    uint32_t *ids = calloc(count, sizeof(*ids));
    if (!ids) return NO;
    uint32_t actual = 0;
    BOOL found = NO;
    if (CGGetOnlineDisplayList(count, ids, &actual) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < MIN(count, actual); i++) {
            if (ids[i] == displayID) { found = YES; break; }
        }
    }
    free(ids);
    return found;
}

static Class DKMonitorPanelClass(void) {
    static Class panelClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep the framework loaded for the lifetime of its Objective-C classes.
        void *handle = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
                              RTLD_LAZY | RTLD_LOCAL);
        if (handle) panelClass = NSClassFromString(@"MPDisplay");
    });
    return panelClass;
}

static BOOL DKMethodMatches(Class cls, SEL selector, const char *returnType,
                            const char *argumentType) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != (argumentType ? 3 : 2)) return NO;
    char *actualReturn = method_copyReturnType(method);
    BOOL matches = actualReturn && strcmp(actualReturn, returnType) == 0;
    free(actualReturn);
    if (matches && argumentType) {
        char *actualArgument = method_copyArgumentType(method, 2);
        matches = actualArgument && strcmp(actualArgument, argumentType) == 0;
        free(actualArgument);
    }
    return matches;
}

static NSObject<DKMonitorPanelDisplay> *DKPanelForDisplay(uint32_t displayID) {
    Class cls = DKMonitorPanelClass();
    if (!DKMethodMatches(cls, @selector(initWithCGSDisplayID:), @encode(id), @encode(int32_t)) ||
        !DKMethodMatches(cls, @selector(displayID), @encode(int32_t), NULL)) return nil;
    NSObject<DKMonitorPanelDisplay> *panel =
        [(NSObject<DKMonitorPanelDisplay> *)[cls alloc] initWithCGSDisplayID:(int32_t)displayID];
#if !__has_feature(objc_arc)
    [panel autorelease];
#endif
    if (!panel || (uint32_t)panel.displayID != displayID) return nil;
    return panel;
}

static BOOL DKHasHDRReadAPI(Class cls) {
    return DKMethodMatches(cls, @selector(hasHDRModes), @encode(BOOL), NULL) &&
        DKMethodMatches(cls, @selector(preferHDRModes), @encode(BOOL), NULL);
}

static BOOL DKHasHDRWriteAPI(Class cls) {
    return DKHasHDRReadAPI(cls) &&
        DKMethodMatches(cls, @selector(setPreferHDRModes:), @encode(void), @encode(BOOL));
}

static BOOL DKHasRotationAPI(Class cls) {
    return DKMethodMatches(cls, @selector(canChangeOrientation), @encode(BOOL), NULL) &&
        DKMethodMatches(cls, @selector(setOrientation:), @encode(void), @encode(int32_t));
}

char *DKSetHDR(uint32_t displayID, bool enabled) {
    @autoreleasepool {
        if (!DKExtraDisplayIsOnline(displayID)) return DKExtraError(@"This display is no longer connected.");
        @try {
            NSObject<DKMonitorPanelDisplay> *panel = DKPanelForDisplay(displayID);
            if (!panel || !DKHasHDRWriteAPI([panel class]))
                return DKExtraError(@"HDR control is unavailable on this version of macOS.");
            if (!panel.hasHDRModes)
                return DKExtraError(@"This display does not support switching HDR in its current mode.");
            if ((bool)panel.preferHDRModes == enabled) return NULL;

            [panel setPreferHDRModes:enabled];
            // The setter returns void. A fresh object avoids trusting only the
            // object on which we set the preference.
            NSObject<DKMonitorPanelDisplay> *updated = DKPanelForDisplay(displayID);
            if (!DKExtraDisplayIsOnline(displayID) || !updated || !DKHasHDRReadAPI([updated class]))
                return DKExtraError(@"HDR was requested, but the display could not be read back. Refresh its settings.");
            if ((bool)updated.preferHDRModes != enabled)
                return DKExtraError(@"HDR was requested, but macOS has not confirmed the requested state. Refresh its settings.");
            return NULL;
        } @catch (NSException *exception) {
            return DKExtraError([NSString stringWithFormat:@"HDR control failed: %@", exception.reason ?: exception.name]);
        }
    }
}

char *DKSetRotation(uint32_t displayID, int degrees) {
    @autoreleasepool {
        if (degrees != 0 && degrees != 90 && degrees != 180 && degrees != 270)
            return DKExtraError(@"Rotation must be 0, 90, 180, or 270 degrees.");
        if (!DKExtraDisplayIsOnline(displayID)) return DKExtraError(@"This display is no longer connected.");
        @try {
            NSObject<DKMonitorPanelDisplay> *panel = DKPanelForDisplay(displayID);
            if (!panel || !DKHasRotationAPI([panel class]))
                return DKExtraError(@"Rotation control is unavailable on this version of macOS.");
            if (![panel canChangeOrientation]) return DKExtraError(@"This display does not support rotation.");
            if (fabs(CGDisplayRotation(displayID) - degrees) < 0.1) return NULL;

            [panel setOrientation:(int32_t)degrees];
            // Verify through the public API, independently of MonitorPanel's
            // cached orientation property. This may also change the mode list.
            if (!DKExtraDisplayIsOnline(displayID))
                return DKExtraError(@"Rotation was requested, but the display disconnected before verification.");
            double actual = CGDisplayRotation(displayID);
            if (!isfinite(actual) || fabs(actual - degrees) >= 0.1)
                return DKExtraError([NSString stringWithFormat:@"Rotation was requested, but macOS still reports %.0f degrees. Refresh its settings.", actual]);
            return NULL;
        } @catch (NSException *exception) {
            return DKExtraError([NSString stringWithFormat:@"Rotation control failed: %@", exception.reason ?: exception.name]);
        }
    }
}

char *DKCopyExtraJSON(uint32_t displayID) {
    @autoreleasepool {
        NSMutableDictionary *result = [@{
            @"hdrSupported": @NO, @"hdrEnabled": @NO,
            @"rotation": @0, @"rotationSupported": @NO
        } mutableCopy];
#if !__has_feature(objc_arc)
        [result autorelease];
#endif
        if (!DKExtraDisplayIsOnline(displayID)) {
            result[@"controlsError"] = @"This display is no longer connected.";
        } else {
            double angle = CGDisplayRotation(displayID);
            if (isfinite(angle)) result[@"rotation"] = @((int)lround(angle));
            @try {
                NSObject<DKMonitorPanelDisplay> *panel = DKPanelForDisplay(displayID);
                Class cls = panel ? [panel class] : Nil;
                if (panel && DKHasHDRReadAPI(cls)) {
                    result[@"hdrEnabled"] = @(panel.preferHDRModes);
                    result[@"hdrSupported"] = [NSNumber numberWithBool:DKHasHDRWriteAPI(cls) && panel.hasHDRModes];
                } else {
                    result[@"controlsError"] = @"HDR control is unavailable on this version of macOS.";
                }
                if (panel && DKHasRotationAPI(cls)) result[@"rotationSupported"] = @([panel canChangeOrientation]);
            } @catch (NSException *exception) {
                result[@"controlsError"] = [NSString stringWithFormat:@"Some display controls are unavailable: %@", exception.reason ?: exception.name];
            }

            ColorSyncProfileRef profile = ColorSyncProfileCreateWithDisplayID(displayID);
            if (profile) {
                CFStringRef name = ColorSyncProfileCopyDescriptionString(profile);
                if (name) {
                    result[@"profileName"] = (__bridge NSString *)name;
                    CFRelease(name);
                }
                CFRelease(profile);
            }
        }
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
        if (!data) return DKExtraError(@"{\"hdrSupported\":false,\"hdrEnabled\":false,\"rotation\":0,\"rotationSupported\":false,\"controlsError\":\"Could not serialize display controls.\"}");
        char *json = malloc(data.length + 1);
        if (json) {
            memcpy(json, data.bytes, data.length);
            json[data.length] = '\0';
        }
        return json;
    }
}
