#ifndef DISPLAY_KEEPER_EXTRA_CONTROLS_H
#define DISPLAY_KEEPER_EXTRA_CONTROLS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Setters return NULL on verified success, otherwise a caller-owned error string.
// The caller releases returned strings with free() or DKFree().
// These functions change display settings only when explicitly called.
char *DKSetHDR(uint32_t displayID, bool enabled);
char *DKSetRotation(uint32_t displayID, int degrees);

// Returns a caller-owned JSON object. Always includes hdrSupported, hdrEnabled,
// rotation, and rotationSupported. profileName and controlsError are optional.
// Unsupported private interfaces are reported without invoking their methods.
char *DKCopyExtraJSON(uint32_t displayID);

#ifdef __cplusplus
}
#endif
#endif
