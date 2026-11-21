// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVTestProgramInfoWindowController : NSWindowController
- (instancetype)init;
- (void)updateWithSnapshot:(nullable TVTestRecordingSnapshot *)snapshot
          activeServiceID:(uint16_t)serviceID
            recordingName:(nullable NSString *)recordingName;
@end

NS_ASSUME_NONNULL_END
