// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const TVTestSettingsDidChangeNotification;

typedef NS_ENUM(NSInteger, TVTestStartupDriverMode) {
    TVTestStartupDriverModeNone = 0,
    TVTestStartupDriverModeLastUsed = 1,
    TVTestStartupDriverModeSpecified = 2,
};

typedef NS_ENUM(NSInteger, TVTestCasReaderMode) {
    TVTestCasReaderModeAuto = 0,          // Built-in MacBonDriver reader first, fallback to PC/SC
    TVTestCasReaderModeDriverBuiltIn = 1, // Built-in MacBonDriverSmartCard only (e.g. XIT-SQR100)
    TVTestCasReaderModePCSC = 2,          // macOS PCSC.framework USB smart card reader
};

@interface TVTestSettings : NSObject
+ (instancetype)sharedSettings;

// General / Paths
@property (nonatomic, copy) NSString *captureDirectory;
@property (nonatomic, copy) NSString *captureFilenamePattern;
@property (nonatomic, copy) NSString *recordingDirectory;
@property (nonatomic, copy) NSString *recordingFilenamePattern;
@property (nonatomic) BOOL recordCurrentServiceOnly;

// Driver (MacBonDriver / SQR100)
@property (nonatomic) TVTestStartupDriverMode startupDriverMode;
@property (nonatomic, copy) NSString *bonDriverDirectory;
@property (nonatomic, copy, nullable) NSString *defaultBonDriverPath;
@property (nonatomic, copy, nullable) NSString *lastBonDriverPath;
@property (nonatomic) NSUInteger bonDriverDeviceIndex;
@property (nonatomic, copy, nullable) NSString *bonDriverCustomConfigPath;
@property (nonatomic, copy, nullable) NSString *bonDriverCustomFirmwareDir;
@property (nonatomic) NSInteger defaultLNBPowerMode;
@property (nonatomic) BOOL autoTuneOnDriverOpen;

// CAS / B-CAS (TvCas)
@property (nonatomic) BOOL enableDescramble;
@property (nonatomic) TVTestCasReaderMode casReaderMode;
@property (nonatomic, copy, nullable) NSString *casPCSCReaderName;
@property (nonatomic) BOOL enableEMMProcess;

// View / Video / Audio
@property (nonatomic) BOOL osdEnabled;
@property (nonatomic) BOOL alwaysOnTop;
@property (nonatomic) BOOL framelessWindow;
@property (nonatomic) BOOL muteWhenMinimized;
@property (nonatomic, copy, nullable) NSString *windowFrameString;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *lastTunedChannelEntry;
@property (nonatomic) BOOL panelVisible;
@property (nonatomic) BOOL panelOnLeft;
@property (nonatomic) NSInteger selectedPanelTab;
@property (nonatomic) BOOL statusBarVisible;
@property (nonatomic) BOOL controlsHidden;
@property (nonatomic, copy, nullable) NSString *defaultAspectRatio;
@property (nonatomic, copy, nullable) NSString *defaultCropGeometry;
@property (nonatomic, copy, nullable) NSString *defaultDeinterlaceMode;
@property (nonatomic) NSInteger defaultAudioChannelMode;
@property (nonatomic) NSInteger volume;

// Captions
@property (nonatomic) BOOL captionsEnabled;
@property (nonatomic) double captionFontSize;
@property (nonatomic) double captionBackgroundAlpha;

// EPG
@property (nonatomic) BOOL saveEPGData;
@property (nonatomic) NSInteger epgDefaultViewMode; // 0=Grid, 1=List

// Derived paths & collections
@property (nonatomic, readonly, copy) NSString *applicationSupportDirectory;
@property (nonatomic, readonly, copy) NSString *epgDataFilePath;
@property (nonatomic, readonly, copy) NSString *logoCacheDirectory;
@property (nonatomic, readonly, copy) NSString *scannedChannelsDirectory;
@property (nonatomic, readonly, copy) NSArray<NSString *> *bonDriverSearchDirectories;
@property (nonatomic, readonly, copy) NSArray<NSString *> *recentRecordingPaths;

- (void)addRecentRecordingURL:(NSURL *)url;
- (void)clearRecentRecordings;
- (void)notifyChanged;

// Builds MacBonDriver initialization options dictionary from current driver settings.
- (NSDictionary<NSString *, id> *)driverOptionsDictionary;

// Persists / loads channel scan results per driver identifier.
- (BOOL)saveScannedChannels:(NSArray<NSDictionary<NSString *, id> *> *)channels
        forDriverIdentifier:(NSString *)driverIdentifier;
- (NSArray<NSDictionary<NSString *, id> *> *)loadScannedChannelsForDriverIdentifier:(NSString *)driverIdentifier;

// Expands TVTest-style variables (%date%, %year%, %month%, %day%, %time%,
// %hour%, %minute%, %second%, %service-name%, %event-name%) into a safe filename stem.
- (NSString *)expandFilenamePattern:(NSString *)pattern
                        serviceName:(nullable NSString *)serviceName
                          eventName:(nullable NSString *)eventName;
@end

NS_ASSUME_NONNULL_END
