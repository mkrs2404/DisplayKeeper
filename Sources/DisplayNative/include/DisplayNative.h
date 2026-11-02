#ifndef DISPLAY_NATIVE_H
#define DISPLAY_NATIVE_H
#include <stdint.h>
#include "ExtraControls.h"
#include "DisplayEvents.h"
// Returned strings are owned by the caller; release with DKFree.
char *DKCopySnapshotJSON(void);
char *DKSetConnectionMode(uint32_t displayID, const char *modeID);
char *DKSetDesktopMode(uint32_t displayID, uint32_t modeID);
char *DKSetBrightness(uint32_t displayID, float value);
char *DKSetMainDisplay(uint32_t displayID);
void DKFree(char *value);
#endif
