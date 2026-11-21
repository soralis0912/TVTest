// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVTestProgramGuideWindowController : NSWindowController
- (instancetype)init;
- (void)updateWithEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
           preferredServiceID:(uint16_t)serviceID
                     finished:(BOOL)finished;
- (void)resetForNewRecording;
@end

NS_ASSUME_NONNULL_END
