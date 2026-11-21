// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@protocol TVTestProgramGuideDelegate <NSObject>
@optional
- (void)programGuideDidRequestTuneServiceID:(uint16_t)serviceID;
- (void)programGuideDidRequestAcquireEPG;
@end

@interface TVTestProgramGuideWindowController : NSWindowController
@property (nonatomic, weak, nullable) id<TVTestProgramGuideDelegate> delegate;

- (instancetype)init;
- (void)updateWithEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
           preferredServiceID:(uint16_t)serviceID
                     finished:(BOOL)finished;
- (void)setEPGAcquisitionStatus:(nullable NSString *)status acquiring:(BOOL)acquiring;
- (void)resetForNewRecording;
@end

NS_ASSUME_NONNULL_END
