#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <dispatch/dispatch.h>
#include <string.h>
#include "DisplayEvents.h"

// All state and callbacks are serialized on the main queue. The refcons do not
// own per-service objects, so releasing a notifier never leaves a dangling one.
static IONotificationPortRef DKEventPort;
static io_iterator_t DKFirstMatchIterator;
static io_iterator_t DKTerminatedIterator;
static NSMutableDictionary<NSNumber *, NSNumber *> *DKInterestTokens;
static DKDisplayEventCallback DKEventCallback;
static void *DKEventContext;
static BOOL DKEventsRunning;
static NSString *DKInitialRegistrationError;

static NSString *DKIOError(NSString *operation, IOReturn status) {
    return [NSString stringWithFormat:@"%@: IOKit status 0x%08x", operation, (unsigned)status];
}

static BOOL DKIsExternalProxy(io_service_t service) {
    CFTypeRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), NULL, 0);
    BOOL external = location && CFGetTypeID(location) == CFStringGetTypeID()
        && CFEqual(location, CFSTR("External"));
    if (location) CFRelease(location);
    return external;
}

static void DKDeliverEvent(uint64_t registryID, uint32_t messageType) {
    if (DKEventsRunning && DKEventCallback) DKEventCallback(registryID, messageType, DKEventContext);
}

static void DKProxyInterest(void *context, io_service_t service, natural_t messageType, void *argument) {
    @autoreleasepool {
        if (!DKEventsRunning) return;
        uint64_t registryID = 0;
        if (IORegistryEntryGetRegistryEntryID(service, &registryID) != KERN_SUCCESS) {
            // The service may already be disappearing. A fresh inventory still
            // matters; the ID is advisory and never used to select a display.
            DKDeliverEvent(0, messageType);
            return;
        }
        if (DKInterestTokens[@(registryID)]) DKDeliverEvent(registryID, messageType);
    }
}

static void DKProxyAppeared(void *context, io_iterator_t iterator) {
    @autoreleasepool {
        if (iterator != DKFirstMatchIterator) return;
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            uint64_t registryID = 0;
            IOReturn status = IORegistryEntryGetRegistryEntryID(service, &registryID);
            if (status == KERN_SUCCESS && DKIsExternalProxy(service) && !DKInterestTokens[@(registryID)]) {
                io_object_t token = IO_OBJECT_NULL;
                status = IOServiceAddInterestNotification(DKEventPort, service, kIOGeneralInterest,
                                                          DKProxyInterest, NULL, &token);
                if (status == KERN_SUCCESS) {
                    DKInterestTokens[@(registryID)] = @(token);
                    DKDeliverEvent(registryID, 0);
                } else {
                    if (token) IOObjectRelease(token);
                    NSString *error = DKIOError(@"Cannot observe external display changes", status);
                    if (!DKEventsRunning) DKInitialRegistrationError = error;
                    else NSLog(@"DisplayKeeper: %@ (registry ID %llu)", error, registryID);
                }
            } else if (status != KERN_SUCCESS && !DKEventsRunning) {
                DKInitialRegistrationError = DKIOError(@"Cannot identify external display service", status);
            }
            IOObjectRelease(service);
        }
    }
}

static void DKProxyTerminated(void *context, io_iterator_t iterator) {
    @autoreleasepool {
        if (iterator != DKTerminatedIterator) return;
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            uint64_t registryID = 0;
            if (IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS) {
                NSNumber *token = DKInterestTokens[@(registryID)];
                if (token) {
                    IOObjectRelease(token.unsignedIntValue);
                    [DKInterestTokens removeObjectForKey:@(registryID)];
                    DKDeliverEvent(registryID, kIOMessageServiceIsTerminated);
                }
            }
            IOObjectRelease(service);
        }
    }
}

static CFMutableDictionaryRef DKExternalProxyMatching(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("DCPAVServiceProxy");
    if (!matching) return NULL;
    NSDictionary *properties = @{@"Location": @"External"};
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)properties);
    return matching;
}

static void DKStopEventsOnMain(void) {
    DKEventsRunning = NO;
    DKEventCallback = NULL;
    DKEventContext = NULL;
    for (NSNumber *token in DKInterestTokens.allValues) IOObjectRelease(token.unsignedIntValue);
    DKInterestTokens = nil;
    if (DKFirstMatchIterator) IOObjectRelease(DKFirstMatchIterator);
    if (DKTerminatedIterator) IOObjectRelease(DKTerminatedIterator);
    DKFirstMatchIterator = IO_OBJECT_NULL;
    DKTerminatedIterator = IO_OBJECT_NULL;
    if (DKEventPort) IONotificationPortDestroy(DKEventPort);
    DKEventPort = NULL;
    DKInitialRegistrationError = nil;
}

void DKStopDisplayEvents(void) {
    if (NSThread.isMainThread) DKStopEventsOnMain();
    else dispatch_sync(dispatch_get_main_queue(), ^{ DKStopEventsOnMain(); });
}

char *DKStartDisplayEvents(DKDisplayEventCallback callback, void *context) {
    @autoreleasepool {
        if (!NSThread.isMainThread) return strdup("Display event registration must run on the main thread.");
        if (!callback) return strdup("A display event callback is required.");
        if (DKEventPort) return strdup("Display event observation is already running.");
        DKInterestTokens = [NSMutableDictionary dictionary];
        DKEventCallback = callback;
        DKEventContext = context;
        DKEventPort = IONotificationPortCreate(kIOMainPortDefault);
        if (!DKEventPort) {
            DKStopEventsOnMain();
            return strdup("Cannot create the display event notification port.");
        }
        IONotificationPortSetDispatchQueue(DKEventPort, dispatch_get_main_queue());
        CFMutableDictionaryRef matching = DKExternalProxyMatching();
        IOReturn status = matching ? IOServiceAddMatchingNotification(DKEventPort, kIOFirstMatchNotification,
            matching, DKProxyAppeared, NULL, &DKFirstMatchIterator) : kIOReturnNoMemory;
        if (status == KERN_SUCCESS) {
            // Draining arms the notification and attaches currently present services.
            DKProxyAppeared(NULL, DKFirstMatchIterator);
            matching = DKExternalProxyMatching();
            status = matching ? IOServiceAddMatchingNotification(DKEventPort, kIOTerminatedNotification,
                matching, DKProxyTerminated, NULL, &DKTerminatedIterator) : kIOReturnNoMemory;
            if (status == KERN_SUCCESS) DKProxyTerminated(NULL, DKTerminatedIterator);
        }
        if (status != KERN_SUCCESS || DKInitialRegistrationError) {
            NSString *error = DKInitialRegistrationError ?: DKIOError(@"Cannot register external display events", status);
            char *result = strdup(error.UTF8String);
            DKStopEventsOnMain();
            return result;
        }
        DKEventsRunning = YES;
        return NULL;
    }
}
