#pragma once
#import <OITCore/OITCore.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL OITIMobileGestaltSetIslandEnabled(BOOL enabled, OITLogger *logger);
void OITIMobileGestaltRepairSuspectBackup(OITLogger *logger);
BOOL OITIMachineHasNativeIsland(NSString *machine);

#ifdef __cplusplus
}
#endif
