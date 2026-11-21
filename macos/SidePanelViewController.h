// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TVTestSidePanelTab) {
    TVTestSidePanelTabInfo = 0,
    TVTestSidePanelTabChannel = 1,
    TVTestSidePanelTabProgramList = 2,
    TVTestSidePanelTabCaption = 3,
};

@protocol TVTestSidePanelDelegate <NSObject>
@optional
- (void)sidePanelDidSelectServiceID:(uint16_t)serviceID;
- (void)sidePanelDidRequestSeekToTimeMs:(int64_t)timeMs;
- (void)sidePanelDidRequestExportCaptions;
- (void)sidePanelDidChangeSelectedTab:(TVTestSidePanelTab)tab;
@end

@interface TVTestSidePanelViewController : NSViewController
@property (nonatomic, weak, nullable) id<TVTestSidePanelDelegate> delegate;
@property (nonatomic) TVTestSidePanelTab selectedTab;

- (void)updateSnapshot:(nullable TVTestRecordingSnapshot *)snapshot
       activeServiceID:(uint16_t)serviceID
             videoSize:(NSSize)videoSize
                 stats:(nullable TVTestStreamStats *)stats
               session:(nullable TVTestRecordingSession *)session;
- (void)updateEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
          activeServiceID:(uint16_t)serviceID;
- (void)updateCaptions:(NSArray<TVTestCaptionCue *> *)cues;
- (void)highlightCaptionAtTimeMs:(int64_t)timeMs;
@end

NS_ASSUME_NONNULL_END
