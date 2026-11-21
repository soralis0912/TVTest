// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVTestAudioStreamInfo : NSObject
@property (nonatomic, readonly) uint16_t pid;
@property (nonatomic, readonly) uint8_t streamType;
@property (nonatomic, readonly) uint8_t componentTag;
@property (nonatomic, readonly, copy) NSString *label;
@end

@interface TVTestESDetail : NSObject
@property (nonatomic, readonly) uint16_t pid;
@property (nonatomic, readonly) uint8_t streamType;
@property (nonatomic, readonly, copy) NSString *streamTypeName;
@property (nonatomic, readonly, copy) NSString *category;
@end

@interface TVTestProgramInfo : NSObject
@property (nonatomic, readonly) uint16_t eventID;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *descriptionText;
@property (nonatomic, readonly, copy) NSString *extendedText;
@property (nonatomic, readonly, copy) NSString *startTimeText;
@property (nonatomic, readonly, copy) NSString *endTimeText;
@property (nonatomic, readonly) uint32_t durationSeconds;
@property (nonatomic, readonly) uint8_t genreLevel1;
@property (nonatomic, readonly, copy) NSString *genreText;
@property (nonatomic, readonly, copy) NSString *videoSpecText;
@property (nonatomic, readonly, copy) NSString *audioSpecText;
@end

@interface TVTestServiceInfo : NSObject
@property (nonatomic, readonly) uint16_t serviceID;
@property (nonatomic, readonly) uint16_t pmtPID;
@property (nonatomic, readonly) uint16_t pcrPID;
@property (nonatomic, readonly) uint8_t serviceType;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *providerName;
@property (nonatomic, readonly) NSUInteger videoESCount;
@property (nonatomic, readonly, copy) NSArray<TVTestAudioStreamInfo *> *audioStreams;
@property (nonatomic, readonly, copy) NSArray<TVTestESDetail *> *elementaryStreams;
@property (nonatomic, readonly) BOOL hasCaptions;
@property (nonatomic, readonly, nullable) TVTestProgramInfo *currentProgram;
@property (nonatomic, readonly, nullable) TVTestProgramInfo *nextProgram;
@end

@interface TVTestPIDStat : NSObject
@property (nonatomic, readonly) uint16_t pid;
@property (nonatomic, readonly, copy) NSString *label;
@property (nonatomic, readonly) uint64_t packetCount;
@property (nonatomic, readonly) uint64_t continuityErrorCount;
@property (nonatomic, readonly) uint64_t scrambledCount;
@end

@interface TVTestStreamStats : NSObject
@property (nonatomic, readonly) uint64_t totalPackets;
@property (nonatomic, readonly) uint64_t formatErrorPackets;
@property (nonatomic, readonly) uint64_t transportErrorPackets;
@property (nonatomic, readonly) uint64_t continuityErrorPackets;
@property (nonatomic, readonly) uint64_t scrambledPackets;
@property (nonatomic, readonly, copy) NSArray<TVTestPIDStat *> *pidStats;
@end

@interface TVTestRecordingSnapshot : NSObject
@property (nonatomic, readonly) uint16_t networkID;
@property (nonatomic, readonly) uint16_t transportStreamID;
@property (nonatomic, readonly, copy) NSString *networkName;
@property (nonatomic, readonly, copy) NSString *tsName;
@property (nonatomic, readonly, copy) NSString *totTimeText;
@property (nonatomic, readonly) double estimatedBitrateMbps;
@property (nonatomic, readonly) double analyzedPosition;
@property (nonatomic, readonly, copy) NSArray<TVTestServiceInfo *> *services;
@property (nonatomic, readonly) TVTestStreamStats *streamStats;

- (nullable TVTestServiceInfo *)serviceWithID:(uint16_t)serviceID;
@end

@interface TVTestCaptionFormatRun : NSObject
@property (nonatomic, readonly) NSUInteger utf8ByteOffset;
@property (nonatomic, readonly) uint8_t charColorIndex;
@property (nonatomic, readonly) uint8_t backColorIndex;
@property (nonatomic, readonly) NSInteger charSize;
@end

@interface TVTestCaptionCue : NSObject
@property (nonatomic, readonly) int64_t timeMs;
@property (nonatomic, readonly) uint8_t languageTag;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) BOOL clearsScreen;
@property (nonatomic, readonly, copy) NSArray<TVTestCaptionFormatRun *> *formatRuns;
@end

@interface TVTestEPGEvent : NSObject
@property (nonatomic, readonly) uint16_t networkID;
@property (nonatomic, readonly) uint16_t transportStreamID;
@property (nonatomic, readonly) uint16_t serviceID;
@property (nonatomic, readonly) uint16_t eventID;
@property (nonatomic, readonly) int64_t startEpochSeconds;
@property (nonatomic, readonly, copy) NSString *dateText;
@property (nonatomic, readonly, copy) NSString *timeRangeText;
@property (nonatomic, readonly) uint32_t durationSeconds;
@property (nonatomic, readonly) uint8_t genreLevel1;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *descriptionText;
@property (nonatomic, readonly, copy) NSString *extendedText;
@property (nonatomic, readonly, copy) NSString *genreText;
@end

@interface TVTestEPGServiceEntry : NSObject
@property (nonatomic, readonly) uint16_t networkID;
@property (nonatomic, readonly) uint16_t transportStreamID;
@property (nonatomic, readonly) uint16_t serviceID;
@property (nonatomic, readonly, copy) NSString *serviceName;
@property (nonatomic, readonly, copy) NSArray<TVTestEPGEvent *> *events;
@end

@interface TVTestRecordingSession : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) uint64_t fileSize;
@property (nonatomic, readonly) NSUInteger packetStride;
@property (nonatomic, readonly) uint64_t packetOffset;
@property (nonatomic, readonly) TVTestRecordingSnapshot *initialSnapshot;

+ (nullable instancetype)sessionWithURL:(NSURL *)url error:(NSError **)error;

// Analyzes a window around the normalized file position [0.0, 1.0] for position-synced EIT/TOT.
- (nullable TVTestRecordingSnapshot *)analyzeSnapshotAtPosition:(double)position
                                                          error:(NSError **)error;

// Scans the recording asynchronously to populate EPGDatabase, PTS-synced ARIB captions,
// packet/PID statistics, and broadcaster PNG logos via LogoDownloaderFilter.
- (void)startBackgroundIndexForServiceID:(uint16_t)serviceID
                           epgDataPath:(nullable NSString *)epgDataPath
                       logoCacheDir:(nullable NSString *)logoCacheDir
                         onCaptionUpdate:(void (^)(NSArray<NSNumber *> *languageTags))captionUpdate
                             onEPGUpdate:(void (^)(NSArray<TVTestEPGServiceEntry *> *epgServices, BOOL finished))epgUpdate
                           onStatsUpdate:(nullable void (^)(TVTestStreamStats *stats))statsUpdate;

// Backward-compatible convenience wrapper
- (void)startBackgroundIndexForServiceID:(uint16_t)serviceID
                         onCaptionUpdate:(void (^)(NSArray<NSNumber *> *languageTags))captionUpdate
                             onEPGUpdate:(void (^)(NSArray<TVTestEPGServiceEntry *> *epgServices, BOOL finished))epgUpdate;

// Re-scans ARIB captions when switching the active service in a multi-service recording.
- (void)reindexCaptionsForServiceID:(uint16_t)serviceID
                           onUpdate:(void (^)(NSArray<NSNumber *> *languageTags))onUpdate;

// Thread-safe lookup of the active ARIB caption cue at playback timeMs.
- (nullable TVTestCaptionCue *)captionAtTimeMs:(int64_t)timeMs languageTag:(uint8_t)languageTag;

// Thread-safe copy of all decoded non-empty caption cues for Caption Side Panel & SRT export.
- (NSArray<TVTestCaptionCue *> *)allCaptionCuesForLanguageTag:(uint8_t)languageTag;

// Thread-safe snapshot of currently indexed EPG services & full-file stream statistics.
- (NSArray<TVTestEPGServiceEntry *> *)currentEPGServices;
- (TVTestStreamStats *)currentStreamStats;
- (nullable NSData *)logoPNGDataForServiceID:(uint16_t)serviceID;

// Exports a single service (or full TS if serviceID == 0) using LibISDB::ServiceSelectorFilter.
- (BOOL)exportServiceID:(uint16_t)serviceID
                  toURL:(NSURL *)outputURL
               progress:(nullable void (^)(double fraction))progress
                  error:(NSError **)error;

// Loads persisted EPGData.dat via LibISDB::EPGDataFile.
+ (NSArray<TVTestEPGServiceEntry *> *)loadPersistedEPGFromPath:(NSString *)epgDataPath;

// Exports EPG entries to JSON.
+ (BOOL)exportEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
                toJSONURL:(NSURL *)outputURL
                    error:(NSError **)error;

// Subtitle export formatters.
+ (NSString *)formatSRTFromCues:(NSArray<TVTestCaptionCue *> *)cues;
+ (NSString *)formatPlainTextFromCues:(NSArray<TVTestCaptionCue *> *)cues;

// Cancels any active background scan.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
