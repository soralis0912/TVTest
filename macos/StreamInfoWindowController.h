// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVTestStreamInfoWindowController : NSWindowController
- (instancetype)init;
- (void)updateWithSnapshot:(nullable TVTestRecordingSnapshot *)snapshot
                     stats:(nullable TVTestStreamStats *)stats;
@end

NS_ASSUME_NONNULL_END
