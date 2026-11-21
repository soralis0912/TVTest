// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVTestOSDOverlayView : NSView
@property (nonatomic) BOOL osdEnabled;

- (void)showMessage:(NSString *)title subtitle:(nullable NSString *)subtitle;
- (void)showService:(NSString *)serviceName
          serviceID:(uint16_t)serviceID
       programTitle:(nullable NSString *)programTitle
          timeRange:(nullable NSString *)timeRange
               logo:(nullable NSImage *)logo;
- (void)showVolume:(NSInteger)volume muted:(BOOL)muted;
@end

NS_ASSUME_NONNULL_END
