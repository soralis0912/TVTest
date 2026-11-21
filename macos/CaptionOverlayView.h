// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVTestCaptionOverlayView : NSView
@property (nonatomic) BOOL captionsEnabled;
@property (nonatomic) double fontSize;
@property (nonatomic) double backgroundAlpha;
@property (nonatomic, nullable) TVTestCaptionCue *currentCue;
@end

NS_ASSUME_NONNULL_END
