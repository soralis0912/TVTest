// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "LiveTunerSession.h"

NS_ASSUME_NONNULL_BEGIN

@protocol TVTestPreferencesDelegate <NSObject>
@optional
- (nullable TVTestLiveTunerSession *)preferencesCurrentLiveSession;
- (void)preferencesDidRequestOpenBonDriverAtURL:(NSURL *)bundleURL;
- (void)preferencesDidSaveScannedChannels:(NSArray<NSDictionary<NSString *, id> *> *)channels
                      forDriverIdentifier:(NSString *)driverIdentifier;
@end

@interface TVTestPreferencesWindowController : NSWindowController
@property (nonatomic, weak, nullable) id<TVTestPreferencesDelegate> delegate;

- (instancetype)init;
- (void)selectCategoryIndex:(NSInteger)index;
- (void)refreshDriverAndScanState;
@end

NS_ASSUME_NONNULL_END
