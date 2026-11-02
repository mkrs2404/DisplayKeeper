#import "DisplayNative.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// These private interfaces were checked against the installed runtime. Every
// Objective-C call below checks its ABI before use; unsupported OS versions
// expose no connection controls. No mode is constructed from a packed number.
static CFUUIDRef (*DKCreateDisplayUUID)(CGDirectDisplayID);
static int (*DKGetBrightness)(CGDirectDisplayID, float *);
static int (*DKPutBrightness)(CGDirectDisplayID, float);
static bool (*DKCanChangeBrightness)(CGDirectDisplayID);

static void DKLoadInterfaces(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        DKCreateDisplayUUID = dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
        if (!DKCreateDisplayUUID && skyLight) DKCreateDisplayUUID = dlsym(skyLight, "CGDisplayCreateUUIDFromDisplayID");
        void *services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
        if (services) {
            DKGetBrightness = dlsym(services, "DisplayServicesGetBrightness");
            DKPutBrightness = dlsym(services, "DisplayServicesSetBrightness");
            DKCanChangeBrightness = dlsym(services, "DisplayServicesCanChangeBrightness");
        }
    });
}

static char *DKError(NSString *message) { return strdup(message.UTF8String ?: "Unknown display error"); }
static char *DKCopyData(NSData *data) {
    if (!data) return NULL;
    char *result = malloc(data.length + 1);
    if (!result) return NULL;
    memcpy(result, data.bytes, data.length); result[data.length] = '\0';
    return result;
}
static NSString *DKCGError(NSString *operation, CGError error) {
    return [NSString stringWithFormat:@"%@ failed (CoreGraphics %d).", operation, (int)error];
}
static NSString *DKUUID(CGDirectDisplayID displayID) {
    if (!DKCreateDisplayUUID) return nil;
    CFUUIDRef uuid = DKCreateDisplayUUID(displayID);
    if (!uuid) return nil;
    CFStringRef value = CFUUIDCreateString(NULL, uuid);
    NSString *result = value ? [NSString stringWithString:(__bridge NSString *)value] : nil;
    if (value) CFRelease(value);
    CFRelease(uuid);
    return result;
}

static BOOL DKHasMethod(id object, NSString *name, const char *returnType, const char *argumentType) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, returnType) != 0 ||
        signature.numberOfArguments != (argumentType ? 3 : 2)) return NO;
    return !argumentType || strcmp([signature getArgumentTypeAtIndex:2], argumentType) == 0;
}
static id DKObject(id object, NSString *name) {
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static uint64_t DKUnsigned(id object, NSString *name) {
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static BOOL DKBool(id object, NSString *name) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static double DKDouble(id object, NSString *name) {
    return ((double (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static NSString *DKString(id object, NSString *name) {
    id value = DKObject(object, name);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSArray<NSNumber *> *DKOnlineIDs(NSString **error) {
    uint32_t count = 0;
    CGError status = CGGetOnlineDisplayList(0, NULL, &count);
    if (status != kCGErrorSuccess) { if (error) *error = DKCGError(@"Read online displays", status); return nil; }
    if (count == 0) return @[];
    CGDirectDisplayID *ids = calloc(count, sizeof(*ids));
    if (!ids) { if (error) *error = @"Unable to allocate the display list."; return nil; }
    uint32_t actual = 0;
    status = CGGetOnlineDisplayList(count, ids, &actual);
    if (status != kCGErrorSuccess) {
        free(ids); if (error) *error = DKCGError(@"Read online displays", status); return nil;
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:actual];
    for (uint32_t i = 0; i < actual; i++) [result addObject:@(ids[i])];
    free(ids);
    return result;
}

static NSString *DKValidateOnline(CGDirectDisplayID displayID) {
    NSString *error = nil;
    NSArray *online = DKOnlineIDs(&error);
    if (!online) return error;
    if (![online containsObject:@(displayID)] || !CGDisplayIsOnline(displayID)) return @"The display is no longer connected.";
    if (!DKUUID(displayID).length) return @"A stable display identity is unavailable; the change was not sent.";
    return nil;
}
static NSString *DKValidateExternal(CGDirectDisplayID displayID) {
    NSString *error = DKValidateOnline(displayID);
    if (error) return error;
    return CGDisplayIsBuiltin(displayID) ? @"Connection format control is restricted to external displays." : nil;
}

static id DKFindCADisplay(CGDirectDisplayID displayID, NSString **error) {
    Class cls = NSClassFromString(@"CADisplay");
    if (!DKHasMethod(cls, @"displays", "@", NULL)) {
        if (error) *error = @"Connection controls are unavailable on this macOS version (CADisplay).";
        return nil;
    }
    // On the inspected runtime this class method only clears an internal cache
    // flag (store-byte-zero, return). It does not call a display mode setter.
    if (!DKHasMethod(cls, @"updateDisplays", "v", NULL)) {
        if (error) *error = @"The connection display cache cannot be refreshed on this macOS version.";
        return nil;
    }
    ((void (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"updateDisplays"));
    id list = DKObject(cls, @"displays");
    if (![list isKindOfClass:NSArray.class]) { if (error) *error = @"macOS returned an invalid connection display list."; return nil; }
    id found = nil;
    for (id display in list) {
        if (!DKHasMethod(display, @"displayId", "I", NULL)) continue;
        uint32_t candidate = ((uint32_t (*)(id, SEL))objc_msgSend)(display, NSSelectorFromString(@"displayId"));
        if (candidate != displayID) continue;
        if (found) { if (error) *error = @"The connection display identity is ambiguous."; return nil; }
        found = display;
    }
    if (found) {
        // Observed implementation only marks the mode cache dirty. A global
        // list refresh alone does not guarantee fresh per-display color data.
        if (!DKHasMethod(found, @"_invalidate", "v", NULL)) {
            if (error) *error = @"The current connection format cannot be refreshed on this macOS version.";
            return nil;
        }
        ((void (*)(id, SEL))objc_msgSend)(found, NSSelectorFromString(@"_invalidate"));
    }
    if (!found && error) *error = @"The connection display is not available yet.";
    return found;
}

static BOOL DKModeABI(id mode) {
    for (NSString *key in @[@"width", @"height", @"bitDepth", @"internalRepresentation"])
        if (!DKHasMethod(mode, key, "Q", NULL)) return NO;
    for (NSString *key in @[@"colorMode", @"hdrMode", @"colorGamut"])
        if (!DKHasMethod(mode, key, "@", NULL)) return NO;
    for (NSString *key in @[@"isVRR", @"isVirtual"])
        if (!DKHasMethod(mode, key, "B", NULL)) return NO;
    return DKHasMethod(mode, @"refreshRate", "d", NULL);
}

// Application enums, not undocumented IORegistry bit fields. Raw strings are
// retained and are the canonical format identity; unfamiliar strings stay -1.
static NSDictionary *DKModeJSON(id mode, NSString *currentID, NSString *preferredID) {
    if (!DKModeABI(mode)) return nil;
    uint64_t width = DKUnsigned(mode, @"width"), height = DKUnsigned(mode, @"height");
    double refresh = DKDouble(mode, @"refreshRate");
    if (!width || !height || width > INT32_MAX || height > INT32_MAX || !isfinite(refresh) || refresh <= 0) return nil;
    NSString *color = DKString(mode, @"colorMode"), *hdr = DKString(mode, @"hdrMode"), *gamut = DKString(mode, @"colorGamut");
    if (!color || !hdr || !gamut) return nil;
    NSString *identifier = [NSString stringWithFormat:@"%llu", (unsigned long long)DKUnsigned(mode, @"internalRepresentation")];
    NSDictionary *encodings = @{@"RGBFullRange": @0, @"RGBLimitedRange": @0,
                               @"YCbCr444LimitedRange": @3, @"YCbCr422LimitedRange": @2, @"YCbCr420LimitedRange": @6,
                               @"HDR10_RGBFullRange": @0, @"HDR10_444LimitedRange": @3,
                               @"HDR10_422LimitedRange": @2, @"HDR10_420LimitedRange": @6};
    NSNumber *encoding = encodings[color] ?: @(-1);
    NSInteger range = -1;
    if ([encoding integerValue] >= 0) range = [color hasSuffix:@"FullRange"] ? 0 : ([color hasSuffix:@"LimitedRange"] ? 1 : -1);
    NSInteger eotf = [hdr isEqualToString:@"SDR"] ? 0 : ([hdr isEqualToString:@"HDR10"] ? 2 : -1);
    NSInteger colorimetry = [gamut isEqualToString:@"gamut_SRGB"] ? 0 : ([gamut isEqualToString:@"gamut_P3"] ? 1 : -1);
    return @{@"id": identifier, @"width": @(width), @"height": @(height), @"refreshRate": @(refresh),
             @"bitDepth": @(DKUnsigned(mode, @"bitDepth")), @"pixelEncoding": encoding,
             @"dynamicRange": @(range), @"eotf": @(eotf), @"colorimetry": @(colorimetry),
             @"rawColorMode": color, @"rawHDRMode": hdr, @"rawColorGamut": gamut,
             @"isVRR": @(DKBool(mode, @"isVRR")),
             @"isCurrent": @([identifier isEqualToString:currentID]), @"isPreferred": @([identifier isEqualToString:preferredID])};
}

static void DKConnections(CGDirectDisplayID displayID, NSMutableDictionary *item) {
    NSString *error = nil;
    id display = DKFindCADisplay(displayID, &error);
    item[@"connectionModes"] = @[];
    item[@"currentConnection"] = NSNull.null;
    if (!display) { item[@"error"] = error; return; }
    for (NSString *key in @[@"availableModes", @"currentMode", @"preferredMode"]) {
        if (!DKHasMethod(display, key, "@", NULL)) { item[@"error"] = @"Connection mode getters are incompatible with this macOS version."; return; }
    }
    if (!DKHasMethod(display, @"setCurrentMode:", "v", "@")) {
        item[@"error"] = @"Connection mode setter is incompatible with this macOS version."; return;
    }
    id current = DKObject(display, @"currentMode"), preferred = DKObject(display, @"preferredMode");
    NSDictionary *currentJSON = DKModeJSON(current, nil, nil), *preferredJSON = DKModeJSON(preferred, nil, nil);
    if (!currentJSON) { item[@"error"] = @"The display has no readable current connection mode yet."; return; }
    NSString *currentID = currentJSON[@"id"], *preferredID = preferredJSON[@"id"];
    item[@"currentConnection"] = DKModeJSON(current, currentID, preferredID);
    id modes = DKObject(display, @"availableModes");
    if (![modes isKindOfClass:NSArray.class]) { item[@"error"] = @"macOS returned an invalid connection mode list."; return; }
    NSMutableArray *result = [NSMutableArray array];
    for (id mode in modes) {
        if (!DKModeABI(mode)) { item[@"error"] = @"A connection mode has an unsupported runtime interface."; item[@"connectionModes"] = @[]; return; }
        if (DKBool(mode, @"isVirtual")) continue;
        NSDictionary *json = DKModeJSON(mode, currentID, preferredID);
        if (json) [result addObject:json];
    }
    item[@"connectionModes"] = result;
}

static NSArray *DKDesktopModes(CGDirectDisplayID displayID) {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    if (!modes) return @[];
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
    uint32_t currentID = current ? (uint32_t)CGDisplayModeGetIODisplayModeID(current) : UINT32_MAX;
    NSMutableArray *result = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        uint32_t modeID = (uint32_t)CGDisplayModeGetIODisplayModeID(mode);
        double rate = CGDisplayModeGetRefreshRate(mode);
        [result addObject:@{@"id": @(modeID), @"width": @(CGDisplayModeGetWidth(mode)), @"height": @(CGDisplayModeGetHeight(mode)),
                            @"pixelWidth": @(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight": @(CGDisplayModeGetPixelHeight(mode)),
                            @"refreshRate": @(isfinite(rate) ? rate : 0), @"isCurrent": [NSNumber numberWithBool:modeID == currentID]}];
    }
    if (current) CGDisplayModeRelease(current);
    CFRelease(modes);
    return result;
}

char *DKCopySnapshotJSON(void) {
    @autoreleasepool { @try {
        DKLoadInterfaces();
        NSString *error = nil;
        NSArray *ids = DKOnlineIDs(&error);
        NSMutableDictionary *root = [NSMutableDictionary dictionary];
        NSMutableArray *displays = [NSMutableArray array];
        root[@"displays"] = displays;
        if (error) root[@"error"] = error;
        else if (!ids.count) root[@"error"] = @"No displays are visible in this process. Launch DisplayKeeper in your logged-in desktop session.";
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
            if (number && screen.localizedName.length) names[number] = screen.localizedName;
        }
        for (NSNumber *number in ids) {
            CGDirectDisplayID displayID = number.unsignedIntValue;
            NSString *uuid = DKUUID(displayID);
            NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:@{@"id": number, @"uuid": uuid ?: @"", @"name": names[number] ?: [NSString stringWithFormat:@"Display %u", displayID],
                                          @"vendorID": @(CGDisplayVendorNumber(displayID)), @"productID": @(CGDisplayModelNumber(displayID)),
                                          @"builtIn": [NSNumber numberWithBool:CGDisplayIsBuiltin(displayID)], @"isMain": [NSNumber numberWithBool:CGDisplayIsMain(displayID)],
                                          @"brightness": NSNull.null, @"desktopModes": DKDesktopModes(displayID)}];
            DKConnections(displayID, item);
            if (!uuid.length) { item[@"error"] = @"A stable display UUID is unavailable. Automatic protection is disabled."; item[@"connectionModes"] = @[]; }
            if (DKCanChangeBrightness && DKGetBrightness && DKCanChangeBrightness(displayID)) {
                float brightness = 0;
                if (DKGetBrightness(displayID, &brightness) == 0 && isfinite(brightness) && brightness >= 0 && brightness <= 1) item[@"brightness"] = @(brightness);
            }
            [displays addObject:item];
        }
        NSError *jsonError = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingSortedKeys error:&jsonError];
        if (!data) return DKError(@"{\"displays\":[],\"error\":\"Could not encode display state.\"}");
        return DKCopyData(data);
    } @catch (NSException *exception) {
        NSDictionary *root = @{@"displays": @[], @"error": [NSString stringWithFormat:@"Display inspection failed: %@", exception.reason ?: exception.name]};
        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
        return data ? DKCopyData(data) : DKError(@"{\"displays\":[],\"error\":\"Display inspection failed.\"}");
    } }
}

char *DKSetConnectionMode(uint32_t displayID, const char *modeID) {
    @autoreleasepool { @try {
        DKLoadInterfaces();
        if (!modeID || !*modeID || strlen(modeID) > 20) return DKError(@"Invalid connection mode identifier.");
        for (const char *p = modeID; *p; p++) if (*p < '0' || *p > '9') return DKError(@"Invalid connection mode identifier.");
        errno = 0; char *end = NULL; unsigned long long wanted = strtoull(modeID, &end, 10);
        if (errno == ERANGE || !end || *end) return DKError(@"Invalid connection mode identifier.");
        NSString *error = DKValidateExternal(displayID);
        if (error) return DKError(error);
        NSString *uuid = DKUUID(displayID);
        id display = DKFindCADisplay(displayID, &error);
        if (!display) return DKError(error);
        if (!DKHasMethod(display, @"availableModes", "@", NULL) || !DKHasMethod(display, @"currentMode", "@", NULL) || !DKHasMethod(display, @"setCurrentMode:", "v", "@"))
            return DKError(@"Connection mode control is incompatible with this macOS version.");
        id modes = DKObject(display, @"availableModes");
        if (![modes isKindOfClass:NSArray.class]) return DKError(@"The display mode list is unavailable.");
        id selected = nil;
        for (id mode in modes) {
            if (!DKModeABI(mode)) return DKError(@"A connection mode has an unsupported runtime interface.");
            if (DKBool(mode, @"isVirtual") || DKUnsigned(mode, @"internalRepresentation") != wanted) continue;
            if (!DKModeJSON(mode, nil, nil)) return DKError(@"The requested connection mode is invalid.");
            if (selected) return DKError(@"The requested connection mode is ambiguous.");
            selected = mode;
        }
        if (!selected) return DKError(@"That connection mode is no longer available on this display.");
        id current = DKObject(display, @"currentMode");
        if (!DKModeABI(current)) return DKError(@"The current connection mode cannot be verified.");
        if (DKUnsigned(current, @"internalRepresentation") == wanted) return NULL;
        error = DKValidateExternal(displayID);
        if (error) return DKError(error);
        if (![uuid isEqualToString:DKUUID(displayID)]) return DKError(@"The display identity changed; retry after reconnecting.");
        ((void (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"setCurrentMode:"), selected);
        // The private setter returns void. NULL means submitted, not verified.
        return NULL;
    } @catch (NSException *exception) { return DKError(exception.reason ?: @"Connection mode request failed."); } }
}

char *DKSetDesktopMode(uint32_t displayID, uint32_t modeID) {
    @autoreleasepool { @try {
        DKLoadInterfaces();
        NSString *error = DKValidateOnline(displayID);
        if (error) return DKError(error);
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
        if (!modes) return DKError(@"The desktop mode list is unavailable.");
        CGDisplayModeRef selected = NULL;
        for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            if ((uint32_t)CGDisplayModeGetIODisplayModeID(mode) == modeID && CGDisplayModeIsUsableForDesktopGUI(mode)) { selected = mode; break; }
        }
        if (!selected) { CFRelease(modes); return DKError(@"That desktop mode is no longer available on this display."); }
        CGDisplayConfigRef configuration = NULL;
        CGError status = CGBeginDisplayConfiguration(&configuration);
        if (status == kCGErrorSuccess) {
            status = CGConfigureDisplayWithDisplayMode(configuration, displayID, selected, NULL);
            if (status == kCGErrorSuccess) status = CGCompleteDisplayConfiguration(configuration, kCGConfigurePermanently);
            else CGCancelDisplayConfiguration(configuration);
        }
        CFRelease(modes);
        return status == kCGErrorSuccess ? NULL : DKError(DKCGError(@"Change desktop mode", status));
    } @catch (NSException *exception) { return DKError(exception.reason ?: @"Desktop mode request failed."); } }
}

char *DKSetBrightness(uint32_t displayID, float value) {
    @autoreleasepool { @try {
        DKLoadInterfaces();
        if (!isfinite(value) || value < 0 || value > 1) return DKError(@"Brightness must be between 0 and 1.");
        NSString *error = DKValidateOnline(displayID);
        if (error) return DKError(error);
        if (!DKGetBrightness || !DKPutBrightness || !DKCanChangeBrightness || !DKCanChangeBrightness(displayID))
            return DKError(@"This display does not expose native brightness control.");
        float before = 0;
        if (DKGetBrightness(displayID, &before) != 0 || !isfinite(before) || before < 0 || before > 1)
            return DKError(@"The display brightness cannot be read safely.");
        int status = DKPutBrightness(displayID, value);
        if (status != 0) return DKError([NSString stringWithFormat:@"Brightness request failed (DisplayServices %d).", status]);
        float after = 0;
        if (DKGetBrightness(displayID, &after) != 0 || !isfinite(after) || fabsf(after - value) > 0.02f)
            return DKError(@"Brightness was requested, but the display has not confirmed the value.");
        return NULL;
    } @catch (NSException *exception) { return DKError(exception.reason ?: @"Brightness request failed."); } }
}

char *DKSetMainDisplay(uint32_t displayID) {
    @autoreleasepool { @try {
        DKLoadInterfaces();
        NSString *error = DKValidateOnline(displayID);
        if (error) return DKError(error);
        if (CGDisplayIsMain(displayID)) return NULL;
        if (!CGDisplayIsActive(displayID) || CGDisplayIsInMirrorSet(displayID)) return DKError(@"Choose an active, unmirrored display as the main display.");
        NSArray *ids = DKOnlineIDs(&error);
        if (!ids) return DKError(error);
        CGPoint offset = CGDisplayBounds(displayID).origin;
        NSMutableArray *origins = [NSMutableArray array];
        for (NSNumber *number in ids) {
            CGDirectDisplayID other = number.unsignedIntValue;
            if (!CGDisplayIsActive(other)) continue;
            CGRect bounds = CGDisplayBounds(other);
            double x = bounds.origin.x - offset.x, y = bounds.origin.y - offset.y;
            if (!isfinite(x) || !isfinite(y) || x < INT32_MIN || x > INT32_MAX || y < INT32_MIN || y > INT32_MAX)
                return DKError(@"The display arrangement cannot be represented safely.");
            [origins addObject:@{@"id": number, @"x": @((int32_t)x), @"y": @((int32_t)y)}];
        }
        CGDisplayConfigRef configuration = NULL;
        CGError status = CGBeginDisplayConfiguration(&configuration);
        if (status != kCGErrorSuccess) return DKError(DKCGError(@"Begin main display change", status));
        for (NSDictionary *origin in origins) {
            status = CGConfigureDisplayOrigin(configuration, [origin[@"id"] unsignedIntValue], [origin[@"x"] intValue], [origin[@"y"] intValue]);
            if (status != kCGErrorSuccess) { CGCancelDisplayConfiguration(configuration); return DKError(DKCGError(@"Move display origin", status)); }
        }
        status = CGCompleteDisplayConfiguration(configuration, kCGConfigurePermanently);
        return status == kCGErrorSuccess ? NULL : DKError(DKCGError(@"Save main display change", status));
    } @catch (NSException *exception) { return DKError(exception.reason ?: @"Main display request failed."); } }
}

void DKFree(char *value) { free(value); }
