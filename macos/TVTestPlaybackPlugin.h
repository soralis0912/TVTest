// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#define TVTestPlaybackPluginAPIVersion 1

// One instance per TVTest window. The host calls this interface on the main thread.
@protocol TVTestPlaybackPlugin <NSObject>
+ (NSUInteger)apiVersion;
+ (nullable instancetype)newWithError:(NSError **)error;
@property (nonatomic, readonly) NSView *view;
- (BOOL)openRecording:(NSURL *)url error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
