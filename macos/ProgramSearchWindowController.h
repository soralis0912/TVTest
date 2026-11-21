// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVTestProgramSearchWindowController : NSWindowController
- (instancetype)init;
- (void)updateWithEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services;
@end

NS_ASSUME_NONNULL_END
