#ifndef DISPLAY_EVENTS_H
#define DISPLAY_EVENTS_H
#include <stdint.h>

// Delivered on the main queue. messageType is the unmodified IOKit interest
// message, or 0 when an external proxy first appears. registryID identifies the
// IORegistry service, not a CG display; callers should refresh their inventory.
typedef void (*DKDisplayEventCallback)(uint64_t registryID, uint32_t messageType, void *context);

// Call on the main thread. One process-wide subscription is supported. A NULL
// result means registration succeeded (including when no external display is
// present). Free an error result with DKFree. No display settings are changed.
char *DKStartDisplayEvents(DKDisplayEventCallback callback, void *context);
// Stops delivery and releases registrations. Safe to call repeatedly.
void DKStopDisplayEvents(void);
#endif
