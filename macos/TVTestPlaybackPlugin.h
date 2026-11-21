// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#define TVTestPlaybackPluginAPIVersion 4

typedef NS_ENUM(NSInteger, TVTestAudioChannelMode) {
    TVTestAudioChannelModeStereo = 1,
    TVTestAudioChannelModeReverseStereo = 2,
    TVTestAudioChannelModeLeft = 3,
    TVTestAudioChannelModeRight = 4,
};

@protocol TVTestPlaybackPlugin;

@protocol TVTestPlaybackPluginDelegate <NSObject>
@optional
- (void)playbackPluginDidUpdateState:(id<TVTestPlaybackPlugin>)plugin;
@end

// One instance per TVTest window. The host calls this interface on the main thread.
@protocol TVTestPlaybackPlugin <NSObject>
+ (NSUInteger)apiVersion;
+ (nullable instancetype)newWithError:(NSError **)error;

@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly) NSView *videoOverlayView;
@property (nonatomic, weak, nullable) id<TVTestPlaybackPluginDelegate> delegate;

@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isLiveStream;
@property (nonatomic, readonly) int64_t playbackTimeMs;
@property (nonatomic, readonly) int64_t durationMs;
@property (nonatomic, readonly) double playbackPosition;
@property (nonatomic, readonly) float playbackRate;
@property (nonatomic, readonly) NSInteger volume;
@property (nonatomic, readonly) BOOL muted;
@property (nonatomic, readonly) NSSize videoSize;
@property (nonatomic, readonly, copy, nullable) NSString *aspectRatio;
@property (nonatomic, readonly, copy, nullable) NSString *cropGeometry;
@property (nonatomic, readonly, copy, nullable) NSString *deinterlaceMode;
@property (nonatomic, readonly) TVTestAudioChannelMode audioChannelMode;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *audioTracks;
@property (nonatomic, readonly) NSInteger currentAudioTrackID;
@property (nonatomic) BOOL controlsHidden;

- (BOOL)openRecording:(NSURL *)url error:(NSError **)error;
- (BOOL)openRecording:(NSURL *)url
            serviceID:(NSInteger)serviceID
        startPosition:(double)position
                error:(NSError **)error;

// Live TS stream playback fed in real time (e.g. from MacBonDriver + LibISDB).
- (BOOL)openLiveStreamWithServiceID:(NSInteger)serviceID error:(NSError **)error;
- (void)pushLiveTSBytes:(const uint8_t *)bytes length:(NSUInteger)length;
- (void)purgeLiveStream;
- (void)closeLiveStream;

- (void)togglePlayPause;
- (void)stop;
- (void)seekToTimeMs:(int64_t)timeMs;
- (void)seekByMs:(int64_t)deltaMs;
- (void)setPlaybackRate:(float)rate;
- (void)setVolume:(NSInteger)volume;
- (void)setMuted:(BOOL)muted;
- (BOOL)selectAudioTrackID:(NSInteger)trackID;
- (BOOL)setAudioChannelMode:(TVTestAudioChannelMode)mode;
- (void)setAspectRatio:(nullable NSString *)aspectRatio;
- (void)setCropGeometry:(nullable NSString *)cropGeometry;
- (void)setDeinterlaceMode:(nullable NSString *)mode;
- (BOOL)takeSnapshotToURL:(NSURL *)outputURL error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
