// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import "MacBonDriver.h"
#import "TSRecordingSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVTestBonDriverInfo : NSObject
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *driverIdentifier;
@property (nonatomic, readonly, copy) NSArray<NSString *> *supportedSystems;
@end

@interface TVTestTunerChannel : NSObject
@property (nonatomic, readonly) NSUInteger spaceIndex;
@property (nonatomic, readonly) NSUInteger channelIndex;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint32_t frequencyKHz;
@property (nonatomic, readonly) uint16_t streamID;
@end

@interface TVTestTunerSpace : NSObject
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSArray<TVTestTunerChannel *> *channels;
@end

@interface TVTestChannelScanResult : NSObject
@property (nonatomic, readonly) NSUInteger spaceIndex;
@property (nonatomic, readonly) NSUInteger channelIndex;
@property (nonatomic, readonly, copy) NSString *channelName;
@property (nonatomic, readonly) uint32_t frequencyKHz;
@property (nonatomic, readonly) uint16_t streamID;
@property (nonatomic, readonly) BOOL locked;
@property (nonatomic, readonly) float signalCNR;
@property (nonatomic, readonly, copy) NSArray<NSDictionary<NSString *, id> *> *services;
@end

@class TVTestLiveTunerSession;

@protocol TVTestLiveTunerSessionDelegate <NSObject>
@optional
// Called on the streaming thread for zero-copy live playback forwarding.
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
        didReceiveTSBytes:(const uint8_t *)bytes
                   length:(NSUInteger)length;
// Called on the main queue when snapshot / signal / bitrate / stats update.
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
       didUpdateSnapshot:(TVTestRecordingSnapshot *)snapshot
             signalLevel:(float)cnrDB
                  locked:(BOOL)locked
             bitrateMbps:(double)bitrateMbps
                   stats:(TVTestStreamStats *)stats;
// Called on the main queue when a live ARIB caption arrives.
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
       didReceiveCaption:(TVTestCaptionCue *)cue
           languageTags:(NSArray<NSNumber *> *)languageTags;
// Called on the main queue when live EPG entries update.
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
            didUpdateEPG:(NSArray<TVTestEPGServiceEntry *> *)epgServices;
// Called on the main queue for hotplug / error events from MacBonDriverDelegate.
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
         didReceiveEvent:(MBDEventType)event
                 message:(NSString *)message;
@end

@interface TVTestLiveTunerSession : NSObject <MacBonDriverDelegate>
@property (nonatomic, weak, nullable) id<TVTestLiveTunerSessionDelegate> delegate;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly, copy) NSString *driverIdentifier;
@property (nonatomic, readonly, copy) NSString *tunerName;
@property (nonatomic, readonly, getter=isTunerOpen) BOOL tunerOpen;
@property (nonatomic, readonly) NSUInteger currentSpace;
@property (nonatomic, readonly) NSUInteger currentChannel;
@property (nonatomic, readonly) float signalLevel;
@property (nonatomic, readonly, copy) NSArray<TVTestTunerSpace *> *tuningSpaces;

@property (nonatomic, readonly) BOOL supportsLNBPower;
@property (nonatomic, readonly) MBDLNBPowerMode currentLNBPowerMode;
@property (nonatomic, readonly) BOOL supportsTSMF;
@property (nonatomic, readonly) uint16_t currentStreamID;
@property (nonatomic, readonly) BOOL supportsSmartCard;
@property (nonatomic, readonly, copy, nullable) NSString *cardReaderName;

// CAS / B-CAS (TvCas) runtime state
@property (nonatomic, readonly) BOOL isCasOpen;
@property (nonatomic, readonly, copy) NSString *casReaderName;
@property (nonatomic, readonly, copy) NSString *casCardIDText;
@property (nonatomic, readonly) uint64_t casDescrambledPackets;
@property (nonatomic, readonly) uint64_t casUndescrambledPackets;
@property (nonatomic, readonly) uint64_t casEcmCount;
@property (nonatomic, readonly) uint64_t casEcmErrorCount;
@property (nonatomic, readonly, copy, nullable) NSString *casLastError;

@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly, nullable) NSURL *recordingURL;
@property (nonatomic, readonly) uint64_t recordedBytes;
@property (nonatomic, readonly) NSTimeInterval recordingDuration;

+ (NSArray<TVTestBonDriverInfo *> *)discoverBonDriversInDirectories:(NSArray<NSString *> *)directories;

+ (nullable instancetype)sessionWithBundleURL:(NSURL *)bundleURL
                                      options:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                                        error:(NSError **)error;

- (BOOL)openTunerWithEPGDataPath:(nullable NSString *)epgDataPath
                    logoCacheDir:(nullable NSString *)logoCacheDir
                           error:(NSError **)error;
- (void)closeTuner;

- (BOOL)tuneToSpace:(NSUInteger)space
            channel:(NSUInteger)channel
           streamID:(uint16_t)streamID
              error:(NSError **)error;

- (void)setActiveServiceID:(uint16_t)serviceID;

- (BOOL)setLNBPowerMode:(MBDLNBPowerMode)mode error:(NSError **)error;
- (BOOL)reopenCasCardWithError:(NSError **)error;
- (NSString *)querySmartCardStatusSummary;

// Live TS recording using LibISDB::ServiceSelectorFilter + FileStreamPOSIX.
- (BOOL)startRecordingToURL:(NSURL *)outputURL
                  serviceID:(uint16_t)serviceID
                      error:(NSError **)error;
- (void)stopRecording;

// Asynchronous channel scan across all channels in a tuning space.
- (void)scanSpace:(NSUInteger)spaceIndex
     dwellSeconds:(double)dwellSeconds
       onProgress:(void (^)(NSUInteger completed, NSUInteger total, TVTestChannelScanResult *result))onProgress
       completion:(void (^)(NSArray<TVTestChannelScanResult *> *results, BOOL cancelled))completion;
- (void)cancelChannelScan;

// Cycles across unique physical channels in scannedChannels to populate EPGData.dat.
- (void)acquireEPGForScannedChannels:(NSArray<NSDictionary<NSString *, id> *> *)channels
                        dwellSeconds:(double)dwellSeconds
                          onProgress:(void (^)(NSUInteger completed, NSUInteger total, NSString *channelName))onProgress
                          completion:(void (^)(BOOL cancelled))completion;
- (void)cancelEPGAcquisition;

- (NSArray<TVTestEPGServiceEntry *> *)currentEPGServices;
- (NSArray<TVTestCaptionCue *> *)allCaptionCuesForLanguageTag:(uint8_t)languageTag;
- (nullable NSData *)logoPNGDataForServiceID:(uint16_t)serviceID;
@end

NS_ASSUME_NONNULL_END
