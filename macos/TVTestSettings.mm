// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestSettings.h"
#import "MacBonDriver.h"

NSNotificationName const TVTestSettingsDidChangeNotification = @"TVTestSettingsDidChangeNotification";

static NSString *SanitizeFilenameComponent(NSString *input) {
    if (!input.length) {
        return @"";
    }
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/:\\*?\"<>|\r\n\t"];
    NSArray<NSString *> *parts = [input componentsSeparatedByCharactersInSet:illegal];
    NSString *joined = [[parts componentsJoinedByString:@"_"]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (joined.length > 80) {
        joined = [joined substringToIndex:80];
    }
    return joined;
}

@implementation TVTestSettings {
    NSUserDefaults *_defaults;
}

+ (instancetype)sharedSettings {
    static TVTestSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = NSUserDefaults.standardUserDefaults;
        NSString *pictures = [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures/TVTest"];
        NSString *movies = [NSHomeDirectory() stringByAppendingPathComponent:@"Movies/TVTest"];
        NSString *bonDrivers = [self.applicationSupportDirectory stringByAppendingPathComponent:@"BonDrivers"];
        NSString *plugIns = [self.applicationSupportDirectory stringByAppendingPathComponent:@"PlugIns"];
        [NSFileManager.defaultManager createDirectoryAtPath:bonDrivers
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        [NSFileManager.defaultManager createDirectoryAtPath:plugIns
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        [_defaults registerDefaults:@{
            @"captureDirectory": pictures,
            @"captureFilenamePattern": @"TVTest_%date%_%time%_%service-name%",
            @"recordingDirectory": movies,
            @"recordingFilenamePattern": @"%date%_%time%_%service-name%_%event-name%",
            @"recordCurrentServiceOnly": @YES,
            @"startupDriverMode": @(TVTestStartupDriverModeNone),
            @"bonDriverDirectory": bonDrivers,
            @"defaultBonDriverPath": @"",
            @"lastBonDriverPath": @"",
            @"bonDriverDeviceIndex": @0,
            @"bonDriverCustomConfigPath": @"",
            @"bonDriverCustomFirmwareDir": @"",
            @"defaultLNBPowerMode": @(MBDLNBPowerOff),
            @"autoTuneOnDriverOpen": @YES,
            @"enableDescramble": @YES,
            @"casReaderMode": @(TVTestCasReaderModeAuto),
            @"casPCSCReaderName": @"",
            @"enableEMMProcess": @NO,
            @"captionsEnabled": @YES,
            @"captionFontSize": @22.0,
            @"captionBackgroundAlpha": @0.72,
            @"osdEnabled": @YES,
            @"alwaysOnTop": @NO,
            @"framelessWindow": @NO,
            @"muteWhenMinimized": @YES,
            @"windowFrameString": @"",
            @"panelVisible": @YES,
            @"panelOnLeft": @NO,
            @"selectedPanelTab": @0,
            @"statusBarVisible": @YES,
            @"controlsHidden": @NO,
            @"defaultAspectRatio": @"",
            @"defaultCropGeometry": @"",
            @"defaultDeinterlaceMode": @"yadif",
            @"defaultAudioChannelMode": @1,
            @"volume": @100,
            @"saveEPGData": @YES,
            @"epgDefaultViewMode": @0,
            @"recentRecordingPaths": @[],
        }];
    }
    return self;
}

- (NSString *)applicationSupportDirectory {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *dir = [base stringByAppendingPathComponent:@"TVTest"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return dir;
}

- (NSString *)epgDataFilePath {
    return [self.applicationSupportDirectory stringByAppendingPathComponent:@"EPGData.dat"];
}

- (NSString *)logoCacheDirectory {
    NSString *dir = [self.applicationSupportDirectory stringByAppendingPathComponent:@"Logos"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return dir;
}

- (NSString *)scannedChannelsDirectory {
    NSString *dir = [self.applicationSupportDirectory stringByAppendingPathComponent:@"Channels"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return dir;
}

- (NSArray<NSString *> *)bonDriverSearchDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *custom = self.bonDriverDirectory;
    if (custom.length) [dirs addObject:custom];
    NSString *appSupportBon = [self.applicationSupportDirectory stringByAppendingPathComponent:@"BonDrivers"];
    if (appSupportBon.length && ![dirs containsObject:appSupportBon]) {
        [dirs addObject:appSupportBon];
    }
    NSString *bundled = [[NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"BonDrivers"] path];
    if (bundled.length && ![dirs containsObject:bundled]) {
        [dirs addObject:bundled];
    }
    return dirs;
}

- (NSString *)captureDirectory { return [_defaults stringForKey:@"captureDirectory"] ?: @""; }
- (void)setCaptureDirectory:(NSString *)v { [_defaults setObject:v forKey:@"captureDirectory"]; }

- (NSString *)captureFilenamePattern { return [_defaults stringForKey:@"captureFilenamePattern"] ?: @"TVTest_%date%_%time%"; }
- (void)setCaptureFilenamePattern:(NSString *)v { [_defaults setObject:v forKey:@"captureFilenamePattern"]; }

- (NSString *)recordingDirectory { return [_defaults stringForKey:@"recordingDirectory"] ?: @""; }
- (void)setRecordingDirectory:(NSString *)v { [_defaults setObject:v forKey:@"recordingDirectory"]; }

- (NSString *)recordingFilenamePattern { return [_defaults stringForKey:@"recordingFilenamePattern"] ?: @"%date%_%time%_%service-name%"; }
- (void)setRecordingFilenamePattern:(NSString *)v { [_defaults setObject:v forKey:@"recordingFilenamePattern"]; }

- (BOOL)recordCurrentServiceOnly { return [_defaults boolForKey:@"recordCurrentServiceOnly"]; }
- (void)setRecordCurrentServiceOnly:(BOOL)v { [_defaults setBool:v forKey:@"recordCurrentServiceOnly"]; }

- (TVTestStartupDriverMode)startupDriverMode { return (TVTestStartupDriverMode)[_defaults integerForKey:@"startupDriverMode"]; }
- (void)setStartupDriverMode:(TVTestStartupDriverMode)v { [_defaults setInteger:v forKey:@"startupDriverMode"]; }

- (NSString *)bonDriverDirectory { return [_defaults stringForKey:@"bonDriverDirectory"] ?: @""; }
- (void)setBonDriverDirectory:(NSString *)v { [_defaults setObject:v forKey:@"bonDriverDirectory"]; }

- (nullable NSString *)defaultBonDriverPath {
    NSString *s = [_defaults stringForKey:@"defaultBonDriverPath"];
    return s.length ? s : nil;
}
- (void)setDefaultBonDriverPath:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"defaultBonDriverPath"]; }

- (nullable NSString *)lastBonDriverPath {
    NSString *s = [_defaults stringForKey:@"lastBonDriverPath"];
    return s.length ? s : nil;
}
- (void)setLastBonDriverPath:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"lastBonDriverPath"]; }

- (NSUInteger)bonDriverDeviceIndex { return (NSUInteger)MAX((NSInteger)0, [_defaults integerForKey:@"bonDriverDeviceIndex"]); }
- (void)setBonDriverDeviceIndex:(NSUInteger)v { [_defaults setInteger:(NSInteger)v forKey:@"bonDriverDeviceIndex"]; }

- (nullable NSString *)bonDriverCustomConfigPath {
    NSString *s = [_defaults stringForKey:@"bonDriverCustomConfigPath"];
    return s.length ? s : nil;
}
- (void)setBonDriverCustomConfigPath:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"bonDriverCustomConfigPath"]; }

- (nullable NSString *)bonDriverCustomFirmwareDir {
    NSString *s = [_defaults stringForKey:@"bonDriverCustomFirmwareDir"];
    return s.length ? s : nil;
}
- (void)setBonDriverCustomFirmwareDir:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"bonDriverCustomFirmwareDir"]; }

- (NSInteger)defaultLNBPowerMode { return [_defaults integerForKey:@"defaultLNBPowerMode"]; }
- (void)setDefaultLNBPowerMode:(NSInteger)v { [_defaults setInteger:v forKey:@"defaultLNBPowerMode"]; }

- (BOOL)autoTuneOnDriverOpen { return [_defaults boolForKey:@"autoTuneOnDriverOpen"]; }
- (void)setAutoTuneOnDriverOpen:(BOOL)v { [_defaults setBool:v forKey:@"autoTuneOnDriverOpen"]; }

- (BOOL)enableDescramble { return [_defaults boolForKey:@"enableDescramble"]; }
- (void)setEnableDescramble:(BOOL)v { [_defaults setBool:v forKey:@"enableDescramble"]; }

- (TVTestCasReaderMode)casReaderMode { return (TVTestCasReaderMode)[_defaults integerForKey:@"casReaderMode"]; }
- (void)setCasReaderMode:(TVTestCasReaderMode)v { [_defaults setInteger:v forKey:@"casReaderMode"]; }

- (nullable NSString *)casPCSCReaderName {
    NSString *s = [_defaults stringForKey:@"casPCSCReaderName"];
    return s.length ? s : nil;
}
- (void)setCasPCSCReaderName:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"casPCSCReaderName"]; }

- (BOOL)enableEMMProcess { return [_defaults boolForKey:@"enableEMMProcess"]; }
- (void)setEnableEMMProcess:(BOOL)v { [_defaults setBool:v forKey:@"enableEMMProcess"]; }

- (BOOL)captionsEnabled { return [_defaults boolForKey:@"captionsEnabled"]; }
- (void)setCaptionsEnabled:(BOOL)v { [_defaults setBool:v forKey:@"captionsEnabled"]; }

- (double)captionFontSize { return MAX(12.0, MIN(48.0, [_defaults doubleForKey:@"captionFontSize"])); }
- (void)setCaptionFontSize:(double)v { [_defaults setDouble:MAX(12.0, MIN(48.0, v)) forKey:@"captionFontSize"]; }

- (double)captionBackgroundAlpha { return MAX(0.0, MIN(1.0, [_defaults doubleForKey:@"captionBackgroundAlpha"])); }
- (void)setCaptionBackgroundAlpha:(double)v { [_defaults setDouble:MAX(0.0, MIN(1.0, v)) forKey:@"captionBackgroundAlpha"]; }

- (BOOL)osdEnabled { return [_defaults boolForKey:@"osdEnabled"]; }
- (void)setOsdEnabled:(BOOL)v { [_defaults setBool:v forKey:@"osdEnabled"]; }

- (BOOL)alwaysOnTop { return [_defaults boolForKey:@"alwaysOnTop"]; }
- (void)setAlwaysOnTop:(BOOL)v { [_defaults setBool:v forKey:@"alwaysOnTop"]; }

- (BOOL)framelessWindow { return [_defaults boolForKey:@"framelessWindow"]; }
- (void)setFramelessWindow:(BOOL)v { [_defaults setBool:v forKey:@"framelessWindow"]; }

- (BOOL)muteWhenMinimized { return [_defaults boolForKey:@"muteWhenMinimized"]; }
- (void)setMuteWhenMinimized:(BOOL)v { [_defaults setBool:v forKey:@"muteWhenMinimized"]; }

- (nullable NSString *)windowFrameString {
    NSString *s = [_defaults stringForKey:@"windowFrameString"];
    return s.length ? s : nil;
}
- (void)setWindowFrameString:(nullable NSString *)v {
    [_defaults setObject:(v ?: @"") forKey:@"windowFrameString"];
}

- (nullable NSDictionary<NSString *, id> *)lastTunedChannelEntry {
    id obj = [_defaults objectForKey:@"lastTunedChannelEntry"];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}
- (void)setLastTunedChannelEntry:(nullable NSDictionary<NSString *, id> *)v {
    if (v) [_defaults setObject:v forKey:@"lastTunedChannelEntry"];
    else [_defaults removeObjectForKey:@"lastTunedChannelEntry"];
}

- (BOOL)panelVisible { return [_defaults boolForKey:@"panelVisible"]; }
- (void)setPanelVisible:(BOOL)v { [_defaults setBool:v forKey:@"panelVisible"]; }

- (BOOL)panelOnLeft { return [_defaults boolForKey:@"panelOnLeft"]; }
- (void)setPanelOnLeft:(BOOL)v { [_defaults setBool:v forKey:@"panelOnLeft"]; }

- (NSInteger)selectedPanelTab { return [_defaults integerForKey:@"selectedPanelTab"]; }
- (void)setSelectedPanelTab:(NSInteger)v { [_defaults setInteger:v forKey:@"selectedPanelTab"]; }

- (BOOL)statusBarVisible { return [_defaults boolForKey:@"statusBarVisible"]; }
- (void)setStatusBarVisible:(BOOL)v { [_defaults setBool:v forKey:@"statusBarVisible"]; }

- (BOOL)controlsHidden { return [_defaults boolForKey:@"controlsHidden"]; }
- (void)setControlsHidden:(BOOL)v { [_defaults setBool:v forKey:@"controlsHidden"]; }

- (nullable NSString *)defaultAspectRatio {
    NSString *s = [_defaults stringForKey:@"defaultAspectRatio"];
    return s.length ? s : nil;
}
- (void)setDefaultAspectRatio:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"defaultAspectRatio"]; }

- (nullable NSString *)defaultCropGeometry {
    NSString *s = [_defaults stringForKey:@"defaultCropGeometry"];
    return s.length ? s : nil;
}
- (void)setDefaultCropGeometry:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"defaultCropGeometry"]; }

- (nullable NSString *)defaultDeinterlaceMode {
    NSString *s = [_defaults stringForKey:@"defaultDeinterlaceMode"];
    return s.length ? s : nil;
}
- (void)setDefaultDeinterlaceMode:(nullable NSString *)v { [_defaults setObject:(v ?: @"") forKey:@"defaultDeinterlaceMode"]; }

- (NSInteger)defaultAudioChannelMode { return MAX((NSInteger)1, MIN((NSInteger)4, [_defaults integerForKey:@"defaultAudioChannelMode"])); }
- (void)setDefaultAudioChannelMode:(NSInteger)v { [_defaults setInteger:MAX((NSInteger)1, MIN((NSInteger)4, v)) forKey:@"defaultAudioChannelMode"]; }

- (NSInteger)volume { return MAX((NSInteger)0, MIN((NSInteger)100, [_defaults integerForKey:@"volume"])); }
- (void)setVolume:(NSInteger)v { [_defaults setInteger:MAX((NSInteger)0, MIN((NSInteger)100, v)) forKey:@"volume"]; }

- (BOOL)saveEPGData { return [_defaults boolForKey:@"saveEPGData"]; }
- (void)setSaveEPGData:(BOOL)v { [_defaults setBool:v forKey:@"saveEPGData"]; }

- (NSInteger)epgDefaultViewMode { return [_defaults integerForKey:@"epgDefaultViewMode"]; }
- (void)setEpgDefaultViewMode:(NSInteger)v { [_defaults setInteger:v forKey:@"epgDefaultViewMode"]; }

- (NSArray<NSString *> *)recentRecordingPaths {
    NSArray *arr = [_defaults stringArrayForKey:@"recentRecordingPaths"];
    return arr ?: @[];
}

- (void)addRecentRecordingURL:(NSURL *)url {
    if (!url.isFileURL || !url.path.length) return;
    NSMutableArray<NSString *> *list = [self.recentRecordingPaths mutableCopy];
    [list removeObject:url.path];
    [list insertObject:url.path atIndex:0];
    if (list.count > 15) [list removeObjectsInRange:NSMakeRange(15, list.count - 15)];
    [_defaults setObject:list forKey:@"recentRecordingPaths"];
}

- (void)clearRecentRecordings {
    [_defaults setObject:@[] forKey:@"recentRecordingPaths"];
}

- (void)notifyChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:TVTestSettingsDidChangeNotification object:self];
}

- (NSDictionary<NSString *, id> *)driverOptionsDictionary {
    NSMutableDictionary<NSString *, id> *opts = [NSMutableDictionary dictionary];
    opts[MBDOptionDeviceIndexKey] = @(self.bonDriverDeviceIndex);
    if (self.bonDriverCustomConfigPath.length) {
        opts[MBDOptionConfigURLKey] = [NSURL fileURLWithPath:self.bonDriverCustomConfigPath];
    }
    if (self.bonDriverCustomFirmwareDir.length) {
        opts[MBDOptionFirmwareDirectoryURLKey] = [NSURL fileURLWithPath:self.bonDriverCustomFirmwareDir];
    }
    return opts;
}

- (NSString *)channelPlistPathForDriverIdentifier:(NSString *)driverIdentifier {
    NSString *safe = SanitizeFilenameComponent(driverIdentifier.length ? driverIdentifier : @"default");
    return [self.scannedChannelsDirectory stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"plist"]];
}

- (BOOL)saveScannedChannels:(NSArray<NSDictionary<NSString *, id> *> *)channels
        forDriverIdentifier:(NSString *)driverIdentifier {
    NSString *path = [self channelPlistPathForDriverIdentifier:driverIdentifier];
    return [channels writeToURL:[NSURL fileURLWithPath:path] error:NULL];
}

- (NSArray<NSDictionary<NSString *, id> *> *)loadScannedChannelsForDriverIdentifier:(NSString *)driverIdentifier {
    NSString *path = [self channelPlistPathForDriverIdentifier:driverIdentifier];
    NSArray *loaded = [NSArray arrayWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL];
    return [loaded isKindOfClass:[NSArray class]] ? loaded : @[];
}

- (NSString *)expandFilenamePattern:(NSString *)pattern
                        serviceName:(nullable NSString *)serviceName
                          eventName:(nullable NSString *)eventName {
    NSDate *now = [NSDate date];
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                           NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                                 fromDate:now];

    NSString *year = [NSString stringWithFormat:@"%04ld", (long)c.year];
    NSString *month = [NSString stringWithFormat:@"%02ld", (long)c.month];
    NSString *day = [NSString stringWithFormat:@"%02ld", (long)c.day];
    NSString *hour = [NSString stringWithFormat:@"%02ld", (long)c.hour];
    NSString *minute = [NSString stringWithFormat:@"%02ld", (long)c.minute];
    NSString *second = [NSString stringWithFormat:@"%02ld", (long)c.second];
    NSString *dateStr = [NSString stringWithFormat:@"%@%@%@", year, month, day];
    NSString *timeStr = [NSString stringWithFormat:@"%@%@%@", hour, minute, second];

    NSMutableString *out = [NSMutableString stringWithString:pattern.length ? pattern : @"TVTest_%date%_%time%"];
    NSDictionary<NSString *, NSString *> *vars = @{
        @"%date%": dateStr,
        @"%year%": year,
        @"%month%": month,
        @"%day%": day,
        @"%time%": timeStr,
        @"%hour%": hour,
        @"%minute%": minute,
        @"%second%": second,
        @"%service-name%": SanitizeFilenameComponent(serviceName ?: @""),
        @"%event-name%": SanitizeFilenameComponent(eventName ?: @""),
    };
    for (NSString *key in vars) {
        [out replaceOccurrencesOfString:key
                             withString:vars[key]
                                options:NSCaseInsensitiveSearch
                                  range:NSMakeRange(0, out.length)];
    }
    while ([out containsString:@"__"]) {
        [out replaceOccurrencesOfString:@"__" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    }
    NSString *trimmed = [out stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"_ "]];
    return trimmed.length ? trimmed : [NSString stringWithFormat:@"TVTest_%@_%@", dateStr, timeStr];
}

@end
