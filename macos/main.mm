// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestPlaybackPlugin.h"
#import "TVTestBuiltinPlayer.h"
#import "TVTestSettings.h"
#import "TSRecordingSession.h"
#import "LiveTunerSession.h"
#import "CaptionOverlayView.h"
#import "OSDOverlayView.h"
#import "SidePanelViewController.h"
#import "ProgramInfoWindowController.h"
#import "ProgramGuideWindowController.h"
#import "ProgramSearchWindowController.h"
#import "StreamInfoWindowController.h"
#import "PreferencesWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cmath>

static BOOL IsSupportedRecordingURL(NSURL *url) {
    if (!url.isFileURL) {
        return NO;
    }
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"m2ts", @"m2t", @"ts", @"mts"] containsObject:ext];
}

static NSString *AudioChannelModeTitle(TVTestAudioChannelMode mode) {
    switch (mode) {
    case TVTestAudioChannelModeLeft:         return @"主音声 (左)";
    case TVTestAudioChannelModeRight:        return @"副音声 (右)";
    case TVTestAudioChannelModeReverseStereo:return @"反転ステレオ";
    case TVTestAudioChannelModeStereo:
    default:                                 return @"ステレオ";
    }
}

@interface TVTestDropView : NSView
@property (nonatomic, copy, nullable) void (^onDropURL)(NSURL *url);
@end

@implementation TVTestDropView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSURL *url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
    return IsSupportedRecordingURL(url) ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSURL *url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
    if (IsSupportedRecordingURL(url) && _onDropURL) {
        _onDropURL(url);
        return YES;
    }
    return NO;
}

@end

@interface TVTestApp : NSObject <
    NSApplicationDelegate,
    NSWindowDelegate,
    TVTestPlaybackPluginDelegate,
    TVTestSidePanelDelegate,
    TVTestLiveTunerSessionDelegate,
    TVTestProgramGuideDelegate,
    TVTestPreferencesDelegate,
    NSMenuDelegate
>
@end

@implementation TVTestApp {
    NSWindow *_window;
    NSSplitView *_mainSplitView;
    NSView *_videoPane;
    TVTestSidePanelViewController *_sidePanelController;
    NSBox *_statusSeparator;
    NSView *_statusBar;
    NSLayoutConstraint *_statusBarHeightConstraint;

    id<TVTestPlaybackPlugin> _plugin;
    TVTestCaptionOverlayView *_captionOverlay;
    TVTestOSDOverlayView *_osdOverlay;
    NSTextField *_statusLeft;
    NSStackView *_statusRightStack;
    NSButton *_statusRecBtn;
    NSButton *_statusSignalBtn;
    NSButton *_statusCasBtn;
    NSButton *_statusCaptionBtn;
    NSButton *_statusVolumeBtn;
    BOOL _mutedByMinimize;
    BOOL _epgAcquiring;

    NSMenu *_recentMenu;
    NSMenu *_driverMenu;
    NSMenu *_channelMenu;
    NSMenu *_serviceMenu;
    NSMenu *_audioMenu;
    NSMenu *_captionLangMenu;

    NSURL *_pendingRecording;
    NSURL *_recording;
    TVTestRecordingSession *_session;
    TVTestLiveTunerSession *_liveSession;
    float _liveSignalCNR;
    BOOL _liveSignalLocked;
    TVTestRecordingSnapshot *_currentSnapshot;
    TVTestStreamStats *_currentStats;
    NSArray<TVTestEPGServiceEntry *> *_persistedEPGServices;
    uint16_t _activeServiceID;
    uint8_t _selectedCaptionLanguage;
    NSArray<NSNumber *> *_availableCaptionLanguages;

    BOOL _probeInFlight;
    BOOL _epgScanFinished;
    double _lastAnalyzedPosition;
    CFAbsoluteTime _lastProbeTimestamp;

    TVTestProgramInfoWindowController *_infoWindowController;
    TVTestProgramGuideWindowController *_guideWindowController;
    TVTestProgramSearchWindowController *_searchWindowController;
    TVTestStreamInfoWindowController *_streamInfoWindowController;
    TVTestPreferencesWindowController *_preferencesWindowController;
    dispatch_queue_t _probeQueue;
    id _eventMonitor;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _availableCaptionLanguages = @[];
        _persistedEPGServices = @[];
        _lastAnalyzedPosition = -1.0;
        _probeQueue = dispatch_queue_create("jp.tvtest.native.probe", DISPATCH_QUEUE_SERIAL);
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(settingsDidChange:)
                                                   name:TVTestSettingsDidChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _eventMonitor = nil;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self buildMenus];
}

- (void)buildMenus {
    NSMenu *menu = [[NSMenu alloc] init];

    // App menu
    NSMenuItem *appItem = [menu addItemWithTitle:@"TVTest" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"TVTest"];
    appItem.submenu = appMenu;
    NSMenuItem *prefsItem = [appMenu addItemWithTitle:@"環境設定…"
                                               action:@selector(showPreferences:)
                                        keyEquivalent:@","];
    prefsItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"TVTest を終了" action:@selector(terminate:) keyEquivalent:@"q"];

    // File menu
    NSMenuItem *fileItem = [menu addItemWithTitle:@"ファイル" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"ファイル"];
    fileItem.submenu = fileMenu;

    NSMenuItem *open = [fileMenu addItemWithTitle:@"録画を開く…"
                                           action:@selector(chooseRecording:)
                                    keyEquivalent:@"o"];
    open.target = self;

    NSMenuItem *openDriver = [fileMenu addItemWithTitle:@"MacBonDriver (.bundle) を開く…"
                                                 action:@selector(chooseBonDriver:)
                                          keyEquivalent:@"O"];
    openDriver.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    openDriver.target = self;

    NSMenuItem *recentItem = [fileMenu addItemWithTitle:@"最近開いた録画" action:nil keyEquivalent:@""];
    _recentMenu = [[NSMenu alloc] initWithTitle:@"最近開いた録画"];
    _recentMenu.delegate = self;
    recentItem.submenu = _recentMenu;

    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *recToggle = [fileMenu addItemWithTitle:@"録画開始／停止"
                                                action:@selector(toggleLiveRecording:)
                                         keyEquivalent:@"r"];
    recToggle.target = self;

    NSMenuItem *exportTS = [fileMenu addItemWithTitle:@"現在のサービスを TS 書き出し…"
                                               action:@selector(exportCurrentServiceTS:)
                                        keyEquivalent:@"S"];
    exportTS.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    exportTS.target = self;

    // Driver menu (MacBonDriver)
    NSMenuItem *driverItem = [menu addItemWithTitle:@"ドライバ" action:nil keyEquivalent:@""];
    _driverMenu = [[NSMenu alloc] initWithTitle:@"ドライバ"];
    _driverMenu.delegate = self;
    driverItem.submenu = _driverMenu;

    // Channel menu (MacBonDriver tuning spaces & channels)
    NSMenuItem *channelItem = [menu addItemWithTitle:@"チャンネル" action:nil keyEquivalent:@""];
    _channelMenu = [[NSMenu alloc] initWithTitle:@"チャンネル"];
    _channelMenu.delegate = self;
    channelItem.submenu = _channelMenu;

    // Playback menu
    NSMenuItem *playItem = [menu addItemWithTitle:@"再生" action:nil keyEquivalent:@""];
    NSMenu *playMenu = [[NSMenu alloc] initWithTitle:@"再生"];
    playItem.submenu = playMenu;

    NSMenuItem *playPause = [playMenu addItemWithTitle:@"再生／一時停止"
                                                action:@selector(togglePlayPause:)
                                         keyEquivalent:@" "];
    playPause.keyEquivalentModifierMask = 0;
    playPause.target = self;

    NSMenuItem *stopItem = [playMenu addItemWithTitle:@"停止"
                                               action:@selector(stopPlayback:)
                                        keyEquivalent:@"."];
    stopItem.target = self;

    [playMenu addItem:[NSMenuItem separatorItem]];

    unichar leftArrow = NSLeftArrowFunctionKey;
    NSMenuItem *back10 = [playMenu addItemWithTitle:@"10 秒戻る"
                                             action:@selector(seekBackward10:)
                                      keyEquivalent:[NSString stringWithCharacters:&leftArrow length:1]];
    back10.keyEquivalentModifierMask = 0;
    back10.target = self;

    unichar rightArrow = NSRightArrowFunctionKey;
    NSMenuItem *fwd30 = [playMenu addItemWithTitle:@"30 秒進む"
                                            action:@selector(seekForward30:)
                                     keyEquivalent:[NSString stringWithCharacters:&rightArrow length:1]];
    fwd30.keyEquivalentModifierMask = 0;
    fwd30.target = self;

    NSMenuItem *back60 = [playMenu addItemWithTitle:@"1 分戻る"
                                             action:@selector(seekBackward60:)
                                      keyEquivalent:[NSString stringWithCharacters:&leftArrow length:1]];
    back60.keyEquivalentModifierMask = NSEventModifierFlagOption;
    back60.target = self;

    NSMenuItem *fwd60 = [playMenu addItemWithTitle:@"1 分進む"
                                            action:@selector(seekForward60:)
                                     keyEquivalent:[NSString stringWithCharacters:&rightArrow length:1]];
    fwd60.keyEquivalentModifierMask = NSEventModifierFlagOption;
    fwd60.target = self;

    [playMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *rateItem = [playMenu addItemWithTitle:@"再生速度" action:nil keyEquivalent:@""];
    NSMenu *rateMenu = [[NSMenu alloc] initWithTitle:@"再生速度"];
    rateItem.submenu = rateMenu;
    for (NSNumber *r in @[@0.5, @0.75, @1.0, @1.25, @1.5, @2.0]) {
        NSMenuItem *ri = [rateMenu addItemWithTitle:[NSString stringWithFormat:@"%.2gx", r.doubleValue]
                                             action:@selector(selectPlaybackRate:)
                                      keyEquivalent:@""];
        ri.target = self;
        ri.representedObject = r;
    }

    [playMenu addItem:[NSMenuItem separatorItem]];

    unichar upArrow = NSUpArrowFunctionKey;
    NSMenuItem *volUp = [playMenu addItemWithTitle:@"音量を上げる"
                                            action:@selector(volumeUp:)
                                     keyEquivalent:[NSString stringWithCharacters:&upArrow length:1]];
    volUp.keyEquivalentModifierMask = 0;
    volUp.target = self;

    unichar downArrow = NSDownArrowFunctionKey;
    NSMenuItem *volDown = [playMenu addItemWithTitle:@"音量を下げる"
                                              action:@selector(volumeDown:)
                                       keyEquivalent:[NSString stringWithCharacters:&downArrow length:1]];
    volDown.keyEquivalentModifierMask = 0;
    volDown.target = self;

    NSMenuItem *muteItem = [playMenu addItemWithTitle:@"ミュート"
                                               action:@selector(toggleMute:)
                                        keyEquivalent:@"m"];
    muteItem.target = self;

    // Service menu
    NSMenuItem *serviceItem = [menu addItemWithTitle:@"サービス" action:nil keyEquivalent:@""];
    _serviceMenu = [[NSMenu alloc] initWithTitle:@"サービス"];
    _serviceMenu.delegate = self;
    serviceItem.submenu = _serviceMenu;

    // Video menu (Zoom / Aspect / Crop / Deinterlace)
    NSMenuItem *videoItem = [menu addItemWithTitle:@"映像" action:nil keyEquivalent:@""];
    NSMenu *videoMenu = [[NSMenu alloc] initWithTitle:@"映像"];
    videoItem.submenu = videoMenu;

    NSMenuItem *zoomItem = [videoMenu addItemWithTitle:@"表示倍率" action:nil keyEquivalent:@""];
    NSMenu *zoomMenu = [[NSMenu alloc] initWithTitle:@"表示倍率"];
    zoomItem.submenu = zoomMenu;
    for (NSNumber *pct in @[@50, @75, @100, @150, @200]) {
        NSMenuItem *zi = [zoomMenu addItemWithTitle:[NSString stringWithFormat:@"%ld%%", (long)pct.integerValue]
                                             action:@selector(applyZoomPercent:)
                                      keyEquivalent:@""];
        zi.target = self;
        zi.tag = pct.integerValue;
    }

    NSMenuItem *aspectItem = [videoMenu addItemWithTitle:@"アスペクト比" action:nil keyEquivalent:@""];
    NSMenu *aspectMenu = [[NSMenu alloc] initWithTitle:@"アスペクト比"];
    aspectItem.submenu = aspectMenu;
    NSArray<NSArray *> *aspects = @[
        @[@"自動", @""],
        @[@"16:9", @"16:9"],
        @[@"4:3", @"4:3"],
        @[@"2.35:1", @"235:100"],
    ];
    for (NSArray *spec in aspects) {
        NSMenuItem *ai = [aspectMenu addItemWithTitle:spec[0] action:@selector(selectAspectRatio:) keyEquivalent:@""];
        ai.target = self;
        ai.representedObject = spec[1];
    }

    NSMenuItem *cropItem = [videoMenu addItemWithTitle:@"パン＆スキャン（クロップ）" action:nil keyEquivalent:@""];
    NSMenu *cropMenu = [[NSMenu alloc] initWithTitle:@"パン＆スキャン（クロップ）"];
    cropItem.submenu = cropMenu;
    NSArray<NSArray *> *crops = @[
        @[@"なし", @""],
        @[@"16:9", @"16:9"],
        @[@"4:3", @"4:3"],
        @[@"16:10", @"16:10"],
        @[@"2.35:1", @"235:100"],
    ];
    for (NSArray *spec in crops) {
        NSMenuItem *ci = [cropMenu addItemWithTitle:spec[0] action:@selector(selectCropGeometry:) keyEquivalent:@""];
        ci.target = self;
        ci.representedObject = spec[1];
    }

    NSMenuItem *deintItem = [videoMenu addItemWithTitle:@"インターレース解除" action:nil keyEquivalent:@""];
    NSMenu *deintMenu = [[NSMenu alloc] initWithTitle:@"インターレース解除"];
    deintItem.submenu = deintMenu;
    NSArray<NSArray *> *deints = @[
        @[@"OFF", @""],
        @[@"Blend", @"blend"],
        @[@"Bob", @"bob"],
        @[@"Linear", @"linear"],
        @[@"Yadif", @"yadif"],
        @[@"Yadif 2x", @"yadif2x"],
    ];
    for (NSArray *spec in deints) {
        NSMenuItem *di = [deintMenu addItemWithTitle:spec[0] action:@selector(selectDeinterlaceMode:) keyEquivalent:@""];
        di.target = self;
        di.representedObject = spec[1];
    }

    // Audio menu
    NSMenuItem *audioItem = [menu addItemWithTitle:@"音声" action:nil keyEquivalent:@""];
    _audioMenu = [[NSMenu alloc] initWithTitle:@"音声"];
    _audioMenu.delegate = self;
    audioItem.submenu = _audioMenu;

    // View menu
    NSMenuItem *viewItem = [menu addItemWithTitle:@"表示" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"表示"];
    viewItem.submenu = viewMenu;

    NSMenuItem *panelToggle = [viewMenu addItemWithTitle:@"サイドパネルを表示"
                                                  action:@selector(toggleSidePanel:)
                                           keyEquivalent:@"l"];
    panelToggle.target = self;

    NSMenuItem *panelTabsItem = [viewMenu addItemWithTitle:@"パネルタブ" action:nil keyEquivalent:@""];
    NSMenu *panelTabsMenu = [[NSMenu alloc] initWithTitle:@"パネルタブ"];
    panelTabsItem.submenu = panelTabsMenu;
    NSArray<NSString *> *tabNames = @[@"情報", @"チャンネル", @"番組", @"字幕"];
    for (NSUInteger i = 0; i < tabNames.count; ++i) {
        NSMenuItem *ti = [panelTabsMenu addItemWithTitle:tabNames[i]
                                                  action:@selector(selectSidePanelTab:)
                                           keyEquivalent:@""];
        ti.target = self;
        ti.tag = (NSInteger)i;
    }

    NSMenuItem *statusToggle = [viewMenu addItemWithTitle:@"ステータスバーを表示"
                                                   action:@selector(toggleStatusBar:)
                                            keyEquivalent:@""];
    statusToggle.target = self;

    NSMenuItem *controlsToggle = [viewMenu addItemWithTitle:@"再生コントロールを隠す"
                                                     action:@selector(toggleControlsHidden:)
                                              keyEquivalent:@"b"];
    controlsToggle.target = self;

    NSMenuItem *topMostToggle = [viewMenu addItemWithTitle:@"常に最前面に表示"
                                                    action:@selector(toggleAlwaysOnTop:)
                                             keyEquivalent:@"t"];
    topMostToggle.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    topMostToggle.target = self;

    NSMenuItem *fullScreenItem = [viewMenu addItemWithTitle:@"フルスクリーン切替"
                                                     action:@selector(toggleFullScreen:)
                                              keyEquivalent:@"f"];
    fullScreenItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;

    [viewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *captionToggle = [viewMenu addItemWithTitle:@"ARIB 字幕を表示"
                                                    action:@selector(toggleCaptions:)
                                             keyEquivalent:@"t"];
    captionToggle.target = self;

    NSMenuItem *captionLangItem = [viewMenu addItemWithTitle:@"字幕言語" action:nil keyEquivalent:@""];
    _captionLangMenu = [[NSMenu alloc] initWithTitle:@"字幕言語"];
    _captionLangMenu.delegate = self;
    captionLangItem.submenu = _captionLangMenu;

    NSMenuItem *osdToggle = [viewMenu addItemWithTitle:@"OSD を表示"
                                                action:@selector(toggleOSD:)
                                         keyEquivalent:@""];
    osdToggle.target = self;

    [viewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *infoItem = [viewMenu addItemWithTitle:@"番組情報…"
                                               action:@selector(showRecordingInfo:)
                                        keyEquivalent:@"i"];
    infoItem.target = self;

    NSMenuItem *guideItem = [viewMenu addItemWithTitle:@"番組表 (EPG)…"
                                                action:@selector(showProgramGuide:)
                                         keyEquivalent:@"e"];
    guideItem.target = self;

    NSMenuItem *searchItem = [viewMenu addItemWithTitle:@"番組検索…"
                                                 action:@selector(showProgramSearch:)
                                          keyEquivalent:@"f"];
    searchItem.target = self;

    // Tools menu
    NSMenuItem *toolsItem = [menu addItemWithTitle:@"ツール" action:nil keyEquivalent:@""];
    NSMenu *toolsMenu = [[NSMenu alloc] initWithTitle:@"ツール"];
    toolsItem.submenu = toolsMenu;

    NSMenuItem *snapSave = [toolsMenu addItemWithTitle:@"静止画キャプチャを保存"
                                                action:@selector(captureSnapshotToFile:)
                                         keyEquivalent:@"s"];
    snapSave.target = self;

    NSMenuItem *snapCopy = [toolsMenu addItemWithTitle:@"静止画をクリップボードにコピー"
                                                action:@selector(captureSnapshotToClipboard:)
                                         keyEquivalent:@"C"];
    snapCopy.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    snapCopy.target = self;

    [toolsMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *streamInfo = [toolsMenu addItemWithTitle:@"ストリーム情報…"
                                                  action:@selector(showStreamInfo:)
                                           keyEquivalent:@"i"];
    streamInfo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    streamInfo.target = self;

    NSMenuItem *exportCap = [toolsMenu addItemWithTitle:@"字幕を SRT / テキストで保存…"
                                                 action:@selector(exportCaptionsToFile:)
                                          keyEquivalent:@""];
    exportCap.target = self;

    NSApp.mainMenu = menu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1220, 680)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"TVTest";
    _window.contentMinSize = NSMakeSize(680, 380);
    _window.delegate = self;
    NSString *savedFrame = TVTestSettings.sharedSettings.windowFrameString;
    if (savedFrame.length) {
        [_window setFrameFromString:savedFrame];
    } else {
        [_window center];
    }
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Optional TvtPlay.bundle plugin (prefer Application Support PlugIns, fall back to app bundle PlugIns);
    // otherwise fall back seamlessly to TVTest's built-in playback engine.
    NSArray<NSURL *> *pluginCandidates = @[
        [NSURL fileURLWithPath:[TVTestSettings.sharedSettings.applicationSupportDirectory
                                stringByAppendingPathComponent:@"PlugIns/TvtPlay.bundle"]],
        [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"TvtPlay.bundle"],
    ];
    for (NSURL *bundleURL in pluginCandidates) {
        if (![NSFileManager.defaultManager fileExistsAtPath:bundleURL.path]) {
            continue;
        }
        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
        NSError *loadErr = nil;
        if (bundle && [bundle loadAndReturnError:&loadErr]) {
            Class<TVTestPlaybackPlugin> playerClass = bundle.principalClass;
            if ([playerClass conformsToProtocol:@protocol(TVTestPlaybackPlugin)] &&
                [playerClass apiVersion] == TVTestPlaybackPluginAPIVersion) {
                id<TVTestPlaybackPlugin> candidate = [playerClass newWithError:&loadErr];
                if (candidate) {
                    _plugin = candidate;
                    break;
                }
            }
        }
    }
    if (!_plugin) {
        NSError *builtinErr = nil;
        _plugin = [TVTestBuiltinPlayer newWithError:&builtinErr];
    }
    _plugin.delegate = self;

    TVTestDropView *root = [[TVTestDropView alloc] initWithFrame:_window.contentView.bounds];
    __weak TVTestApp *weakSelf = self;
    root.onDropURL = ^(NSURL *url) {
        [weakSelf openRecording:url];
    };

    _mainSplitView = [[NSSplitView alloc] init];
    _mainSplitView.vertical = YES;
    _mainSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    _mainSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_mainSplitView];

    _videoPane = _plugin.view;
    _videoPane.translatesAutoresizingMaskIntoConstraints = NO;
    [_videoPane.widthAnchor constraintGreaterThanOrEqualToConstant:440].active = YES;

    _sidePanelController = [[TVTestSidePanelViewController alloc] init];
    _sidePanelController.delegate = self;
    _sidePanelController.logoLookupBlock = ^NSData * _Nullable(uint16_t sid) {
        TVTestApp *s = weakSelf;
        if (!s) return nil;
        return [s->_liveSession logoPNGDataForServiceID:sid] ?: [s->_session logoPNGDataForServiceID:sid];
    };
    NSView *panelView = _sidePanelController.view;
    [panelView.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    [panelView.widthAnchor constraintLessThanOrEqualToConstant:440].active = YES;

    [self rebuildMainSplitOrder];

    _statusSeparator = [[NSBox alloc] init];
    _statusSeparator.boxType = NSBoxSeparator;
    _statusSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_statusSeparator];

    _statusBar = [[NSView alloc] init];
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_statusBar];

    _statusLeft = [NSTextField labelWithString:@"⌘O で録画を開く / ドライバメニューから TV 視聴"];
    _statusLeft.font = [NSFont systemFontOfSize:11.5];
    _statusLeft.lineBreakMode = NSLineBreakByTruncatingTail;
    _statusLeft.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_statusLeft];

    auto makeStatusBtn = ^NSButton *(NSString *title, SEL act) {
        NSButton *b = [NSButton buttonWithTitle:title target:self action:act];
        b.bordered = NO;
        b.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];
        b.contentTintColor = NSColor.secondaryLabelColor;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
        return b;
    };
    _statusRecBtn = makeStatusBtn(@"", @selector(toggleLiveRecording:));
    _statusRecBtn.hidden = YES;
    _statusSignalBtn = makeStatusBtn(@"LibISDB 待機中", @selector(showStreamInfo:));
    _statusCasBtn = makeStatusBtn(@"", @selector(showSmartCardStatus:));
    _statusCasBtn.hidden = YES;
    _statusCaptionBtn = makeStatusBtn(@"字幕: ON", @selector(toggleCaptions:));
    _statusVolumeBtn = makeStatusBtn(@"🔊 100%", @selector(toggleMute:));

    _statusRightStack = [NSStackView stackViewWithViews:@[
        _statusRecBtn, _statusSignalBtn, _statusCasBtn, _statusCaptionBtn, _statusVolumeBtn
    ]];
    _statusRightStack.spacing = 10;
    _statusRightStack.alignment = NSLayoutAttributeCenterY;
    _statusRightStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_statusRightStack];

    _statusBarHeightConstraint = [_statusBar.heightAnchor constraintEqualToConstant:26];

    [NSLayoutConstraint activateConstraints:@[
        [_mainSplitView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_mainSplitView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_mainSplitView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_statusSeparator.topAnchor constraintEqualToAnchor:_mainSplitView.bottomAnchor],
        [_statusSeparator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_statusSeparator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_statusBar.topAnchor constraintEqualToAnchor:_statusSeparator.bottomAnchor],
        [_statusBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_statusBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_statusBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        _statusBarHeightConstraint,
        [_statusLeft.leadingAnchor constraintEqualToAnchor:_statusBar.leadingAnchor constant:12],
        [_statusLeft.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
        [_statusRightStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:_statusLeft.trailingAnchor constant:12],
        [_statusRightStack.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor constant:-12],
        [_statusRightStack.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
    ]];

    _window.contentView = root;

    // Attach ARIB caption overlay & PseudoOSD overlay above VLC video surface.
    NSView *overlayHost = _plugin.videoOverlayView;
    _captionOverlay = [[TVTestCaptionOverlayView alloc] initWithFrame:NSZeroRect];
    _captionOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [overlayHost addSubview:_captionOverlay];

    _osdOverlay = [[TVTestOSDOverlayView alloc] initWithFrame:NSZeroRect];
    _osdOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [overlayHost addSubview:_osdOverlay];

    [NSLayoutConstraint activateConstraints:@[
        [_captionOverlay.topAnchor constraintEqualToAnchor:overlayHost.topAnchor],
        [_captionOverlay.bottomAnchor constraintEqualToAnchor:overlayHost.bottomAnchor],
        [_captionOverlay.leadingAnchor constraintEqualToAnchor:overlayHost.leadingAnchor],
        [_captionOverlay.trailingAnchor constraintEqualToAnchor:overlayHost.trailingAnchor],
        [_osdOverlay.topAnchor constraintEqualToAnchor:overlayHost.topAnchor],
        [_osdOverlay.bottomAnchor constraintEqualToAnchor:overlayHost.bottomAnchor],
        [_osdOverlay.leadingAnchor constraintEqualToAnchor:overlayHost.leadingAnchor],
        [_osdOverlay.trailingAnchor constraintEqualToAnchor:overlayHost.trailingAnchor],
    ]];

    [self applySettingsToUI];
    [self installWindowsTVTestInteractionMonitor];

    // Load persisted EPGData.dat if present
    TVTestSettings *settings = TVTestSettings.sharedSettings;
    if (settings.saveEPGData) {
        _persistedEPGServices = [TVTestRecordingSession loadPersistedEPGFromPath:settings.epgDataFilePath];
        if (_persistedEPGServices.count > 0) {
            [_sidePanelController updateEPGServices:_persistedEPGServices activeServiceID:0];
        }
    }

    NSURL *recording = _pendingRecording;
    _pendingRecording = nil;
    if (recording) {
        [self openRecording:recording];
    } else if (settings.startupDriverMode == TVTestStartupDriverModeLastUsed && settings.lastBonDriverPath.length) {
        if ([NSFileManager.defaultManager fileExistsAtPath:settings.lastBonDriverPath]) {
            [self openBonDriverAtURL:[NSURL fileURLWithPath:settings.lastBonDriverPath]];
        }
    } else if (settings.startupDriverMode == TVTestStartupDriverModeSpecified && settings.defaultBonDriverPath.length) {
        if ([NSFileManager.defaultManager fileExistsAtPath:settings.defaultBonDriverPath]) {
            [self openBonDriverAtURL:[NSURL fileURLWithPath:settings.defaultBonDriverPath]];
        }
    }
}

- (void)rebuildMainSplitOrder {
    if (!_mainSplitView || !_videoPane || !_sidePanelController) {
        return;
    }
    NSView *panelView = _sidePanelController.view;
    for (NSView *sub in [_mainSplitView.arrangedSubviews copy]) {
        [_mainSplitView removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }
    if (TVTestSettings.sharedSettings.panelOnLeft) {
        [_mainSplitView addArrangedSubview:panelView];
        [_mainSplitView addArrangedSubview:_videoPane];
    } else {
        [_mainSplitView addArrangedSubview:_videoPane];
        [_mainSplitView addArrangedSubview:panelView];
    }
    panelView.hidden = !TVTestSettings.sharedSettings.panelVisible;
    [_mainSplitView adjustSubviews];
}

- (void)settingsDidChange:(NSNotification *)note {
    (void)note;
    [self applySettingsToUI];
}

- (void)applySettingsToUI {
    TVTestSettings *s = TVTestSettings.sharedSettings;
    _window.level = s.alwaysOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;

    // Frameless (titlebar hidden) mode matching Windows TVTest
    if (s.framelessWindow) {
        _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        _window.titlebarAppearsTransparent = YES;
        _window.titleVisibility = NSWindowTitleHidden;
        _window.movableByWindowBackground = YES;
        [_window standardWindowButton:NSWindowCloseButton].hidden = YES;
        [_window standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
        [_window standardWindowButton:NSWindowZoomButton].hidden = YES;
    } else {
        _window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
        _window.titlebarAppearsTransparent = NO;
        _window.titleVisibility = NSWindowTitleVisible;
        _window.movableByWindowBackground = NO;
        [_window standardWindowButton:NSWindowCloseButton].hidden = NO;
        [_window standardWindowButton:NSWindowMiniaturizeButton].hidden = NO;
        [_window standardWindowButton:NSWindowZoomButton].hidden = NO;
    }

    _captionOverlay.captionsEnabled = s.captionsEnabled;
    _captionOverlay.fontSize = s.captionFontSize;
    _captionOverlay.backgroundAlpha = s.captionBackgroundAlpha;
    _osdOverlay.osdEnabled = s.osdEnabled;
    _plugin.controlsHidden = s.controlsHidden;
    [_plugin setAspectRatio:s.defaultAspectRatio];
    [_plugin setCropGeometry:s.defaultCropGeometry];
    [_plugin setDeinterlaceMode:s.defaultDeinterlaceMode];
    [_plugin setAudioChannelMode:(TVTestAudioChannelMode)s.defaultAudioChannelMode];
    [_plugin setVolume:s.volume];

    _statusBar.hidden = !s.statusBarVisible;
    _statusSeparator.hidden = !s.statusBarVisible;
    _statusBarHeightConstraint.constant = s.statusBarVisible ? 26.0 : 0.0;

    _sidePanelController.selectedTab = (TVTestSidePanelTab)s.selectedPanelTab;
    [self rebuildMainSplitOrder];
    [self refreshMetadataUI];
}

- (void)toggleFramelessWindow:(id)sender {
    (void)sender;
    TVTestSettings *s = TVTestSettings.sharedSettings;
    s.framelessWindow = !s.framelessWindow;
    [self applySettingsToUI];
    [_osdOverlay showMessage:(s.framelessWindow ? @"タイトルバー: 非表示" : @"タイトルバー: 表示") subtitle:nil];
}

#pragma mark - NSWindowDelegate (Frame Persistence & Minimize Auto-Mute)

- (void)windowDidMove:(NSNotification *)notification {
    (void)notification;
    if (!(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        TVTestSettings.sharedSettings.windowFrameString = _window.stringWithSavedFrame;
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    if (!(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        TVTestSettings.sharedSettings.windowFrameString = _window.stringWithSavedFrame;
    }
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
    (void)notification;
    if (TVTestSettings.sharedSettings.muteWhenMinimized && _plugin && !_plugin.muted) {
        _mutedByMinimize = YES;
        [_plugin setMuted:YES];
        [self refreshMetadataUI];
    }
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
    (void)notification;
    if (_mutedByMinimize) {
        _mutedByMinimize = NO;
        [_plugin setMuted:NO];
        [self refreshMetadataUI];
    }
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    NSURL *recording = urls.firstObject;
    if (recording) {
        [self openRecording:recording];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (_window && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        TVTestSettings.sharedSettings.windowFrameString = _window.stringWithSavedFrame;
    }
    [_liveSession closeTuner];
    _liveSession = nil;
    [_session cancel];
    _session = nil;
    [_plugin closeLiveStream];
    _plugin = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return YES;
}

#pragma mark - Opening & Session Management

- (void)chooseRecording:(id)sender {
    (void)sender;
    if (!_plugin) {
        [self showError:@"TvtPlay を読み込めませんでした。"];
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"録画を開く";
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"m2ts" conformingToType:UTTypeData],
        [UTType typeWithFilenameExtension:@"m2t" conformingToType:UTTypeData],
        [UTType typeWithFilenameExtension:@"ts" conformingToType:UTTypeData],
        [UTType typeWithFilenameExtension:@"mts" conformingToType:UTTypeData],
    ];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) {
            [self openRecording:panel.URL];
        }
    }];
}

- (void)openRecording:(NSURL *)url {
    if (!_window) {
        _pendingRecording = url;
        return;
    }
    if (_liveSession) {
        [_liveSession closeTuner];
        _liveSession = nil;
        [_plugin closeLiveStream];
    }
    NSError *error = nil;
    if (!_plugin || ![_plugin openRecording:url error:&error]) {
        [self showError:error.localizedDescription ?: @"録画を開けませんでした。"];
        return;
    }
    [TVTestSettings.sharedSettings addRecentRecordingURL:url];

    [_session cancel];
    _session = nil;
    _currentSnapshot = nil;
    _currentStats = nil;
    _activeServiceID = 0;
    _selectedCaptionLanguage = 0;
    _availableCaptionLanguages = @[];
    _epgScanFinished = NO;
    _lastAnalyzedPosition = 0.0;
    _lastProbeTimestamp = CFAbsoluteTimeGetCurrent();
    _captionOverlay.currentCue = nil;

    _recording = url;
    _window.title = [NSString stringWithFormat:@"%@ — TVTest", url.lastPathComponent];
    _statusLeft.stringValue = [NSString stringWithFormat:@"%@ を解析中…", url.lastPathComponent];
    _statusSignalBtn.title = @"LibISDB 解析中";
    [_guideWindowController resetForNewRecording];
    [_sidePanelController updateCaptions:@[]];

    TVTestSettings *settings = TVTestSettings.sharedSettings;
    NSString *epgPath = settings.saveEPGData ? settings.epgDataFilePath : nil;
    NSString *logoDir = settings.logoCacheDirectory;

    __weak TVTestApp *weakSelf = self;
    dispatch_async(_probeQueue, ^{
        NSError *sessionError = nil;
        TVTestRecordingSession *session = [TVTestRecordingSession sessionWithURL:url error:&sessionError];
        dispatch_async(dispatch_get_main_queue(), ^{
            TVTestApp *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_recording isEqual:url]) {
                return;
            }
            if (!session) {
                strongSelf->_statusLeft.stringValue = url.lastPathComponent;
                strongSelf->_statusSignalBtn.title = @"ISDB 情報なし";
                return;
            }
            strongSelf->_session = session;
            strongSelf->_currentSnapshot = session.initialSnapshot;
            strongSelf->_currentStats = session.initialSnapshot.streamStats;
            TVTestServiceInfo *firstSvc = session.initialSnapshot.services.firstObject;
            strongSelf->_activeServiceID = firstSvc.serviceID;
            [strongSelf refreshMetadataUI];
            [strongSelf presentServiceOSDForService:firstSvc];

            [session startBackgroundIndexForServiceID:strongSelf->_activeServiceID
                                          epgDataPath:epgPath
                                         logoCacheDir:logoDir
                                      onCaptionUpdate:^(NSArray<NSNumber *> *languageTags) {
                TVTestApp *inner = weakSelf;
                if (!inner || inner->_session != session) {
                    return;
                }
                inner->_availableCaptionLanguages = languageTags;
                if (languageTags.count > 0 && ![languageTags containsObject:@(inner->_selectedCaptionLanguage)]) {
                    inner->_selectedCaptionLanguage = (uint8_t)languageTags.firstObject.unsignedIntValue;
                }
                [inner->_sidePanelController updateCaptions:
                    [session allCaptionCuesForLanguageTag:inner->_selectedCaptionLanguage]];
                [inner refreshMetadataUI];
            }
                                          onEPGUpdate:^(NSArray<TVTestEPGServiceEntry *> *epgServices, BOOL finished) {
                TVTestApp *inner = weakSelf;
                if (!inner || inner->_session != session) {
                    return;
                }
                inner->_epgScanFinished = finished;
                NSArray<TVTestEPGServiceEntry *> *effective = epgServices.count
                    ? epgServices
                    : inner->_persistedEPGServices;
                [inner->_guideWindowController updateWithEPGServices:effective
                                                  preferredServiceID:inner->_activeServiceID
                                                            finished:finished];
                [inner->_searchWindowController updateWithEPGServices:effective];
                [inner->_sidePanelController updateEPGServices:effective
                                               activeServiceID:inner->_activeServiceID];
            }
                                        onStatsUpdate:^(TVTestStreamStats *stats) {
                TVTestApp *inner = weakSelf;
                if (!inner || inner->_session != session) {
                    return;
                }
                inner->_currentStats = stats;
                [inner refreshMetadataUI];
            }];
        });
    });
}

- (void)presentServiceOSDForService:(nullable TVTestServiceInfo *)service {
    if (!service) {
        return;
    }
    NSData *logoData = [_session logoPNGDataForServiceID:service.serviceID];
    NSImage *logo = logoData ? [[NSImage alloc] initWithData:logoData] : nil;
    NSString *timeRange = @"";
    if (service.currentProgram.startTimeText.length && service.currentProgram.endTimeText.length) {
        timeRange = [NSString stringWithFormat:@"%@〜%@",
                     service.currentProgram.startTimeText,
                     service.currentProgram.endTimeText];
    }
    [_osdOverlay showService:service.name
                   serviceID:service.serviceID
                programTitle:service.currentProgram.title
                   timeRange:timeRange
                        logo:logo];
}

#pragma mark - Live Playback Updates

- (void)playbackPluginDidUpdateState:(id<TVTestPlaybackPlugin>)plugin {
    if (!_session) {
        return;
    }

    int64_t timeMs = plugin.playbackTimeMs;
    if (timeMs >= 0) {
        if (_captionOverlay.captionsEnabled) {
            TVTestCaptionCue *cue = [_session captionAtTimeMs:timeMs languageTag:_selectedCaptionLanguage];
            _captionOverlay.currentCue = cue;
        } else {
            _captionOverlay.currentCue = nil;
        }
        [_sidePanelController highlightCaptionAtTimeMs:timeMs];
    } else {
        _captionOverlay.currentCue = nil;
    }

    double pos = plugin.playbackPosition;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL movedSignificantly = fabs(pos - _lastAnalyzedPosition) >= 0.025;
    BOOL periodicRefresh = (now - _lastProbeTimestamp) >= 15.0 && fabs(pos - _lastAnalyzedPosition) >= 0.002;
    if (!_probeInFlight && (movedSignificantly || periodicRefresh)) {
        _probeInFlight = YES;
        _lastAnalyzedPosition = pos;
        _lastProbeTimestamp = now;

        TVTestRecordingSession *session = _session;
        __weak TVTestApp *weakSelf = self;
        dispatch_async(_probeQueue, ^{
            NSError *probeErr = nil;
            TVTestRecordingSnapshot *snap = [session analyzeSnapshotAtPosition:pos error:&probeErr];
            dispatch_async(dispatch_get_main_queue(), ^{
                TVTestApp *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                strongSelf->_probeInFlight = NO;
                if (strongSelf->_session == session && snap && snap.services.count > 0) {
                    strongSelf->_currentSnapshot = snap;
                    [strongSelf refreshMetadataUI];
                }
            });
        });
    }
}

- (void)refreshMetadataUI {
    TVTestServiceInfo *active = [_currentSnapshot serviceWithID:_activeServiceID];
    if (active) {
        NSString *prog = active.currentProgram.title;
        if (prog.length) {
            _statusLeft.stringValue = [NSString stringWithFormat:@"%@  │  %@", active.name, prog];
            _window.title = [NSString stringWithFormat:@"%@ — %@ — TVTest", prog, active.name];
        } else {
            _statusLeft.stringValue = [NSString stringWithFormat:@"%@ (SID %u)", active.name, active.serviceID];
            _window.title = [NSString stringWithFormat:@"%@ — TVTest",
                             _liveSession ? _liveSession.tunerName : (_recording.lastPathComponent ?: @"TVTest")];
        }
    } else if (_liveSession) {
        _statusLeft.stringValue = [NSString stringWithFormat:@"%@ — 選局中", _liveSession.tunerName];
    } else if (_recording) {
        _statusLeft.stringValue = _recording.lastPathComponent;
    }

    TVTestStreamStats *st = _currentStats ?: _currentSnapshot.streamStats;

    if (_liveSession.isRecording) {
        int64_t sec = (int64_t)_liveSession.recordingDuration;
        double mb = (double)_liveSession.recordedBytes / (1024.0 * 1024.0);
        _statusRecBtn.title = [NSString stringWithFormat:@"● REC %02lld:%02lld:%02lld (%.1f MB)",
                               sec / 3600, (sec / 60) % 60, sec % 60, mb];
        _statusRecBtn.contentTintColor = NSColor.systemRedColor;
        _statusRecBtn.hidden = NO;
    } else if (_liveSession) {
        _statusRecBtn.title = @"○ 録画";
        _statusRecBtn.contentTintColor = NSColor.secondaryLabelColor;
        _statusRecBtn.hidden = NO;
    } else {
        _statusRecBtn.hidden = YES;
    }

    NSMutableArray<NSString *> *sigParts = [NSMutableArray array];
    if (_liveSession) {
        [sigParts addObject:[NSString stringWithFormat:@"CNR %.1f dB%@",
                             _liveSignalCNR, _liveSignalLocked ? @"" : @" (未ロック)"]];
    }
    if (_currentSnapshot.totTimeText.length) {
        [sigParts addObject:_currentSnapshot.totTimeText];
    }
    if (_currentSnapshot.estimatedBitrateMbps > 0.05) {
        [sigParts addObject:[NSString stringWithFormat:@"%.1f Mbps", _currentSnapshot.estimatedBitrateMbps]];
    }
    if (st && st.totalPackets > 0) {
        [sigParts addObject:[NSString stringWithFormat:@"D:%llu/E:%llu",
                             st.continuityErrorPackets,
                             st.formatErrorPackets + st.transportErrorPackets]];
    }
    if (_plugin.audioChannelMode != TVTestAudioChannelModeStereo) {
        [sigParts addObject:AudioChannelModeTitle(_plugin.audioChannelMode)];
    }
    _statusSignalBtn.title = sigParts.count ? [sigParts componentsJoinedByString:@" · "] : @"LibISDB 待機中";

    if (_liveSession) {
        _statusCasBtn.hidden = NO;
        if (_liveSession.isCasOpen) {
            _statusCasBtn.title = [NSString stringWithFormat:@"CAS: ON (%llu)", _liveSession.casDescrambledPackets];
            _statusCasBtn.contentTintColor = NSColor.systemGreenColor;
        } else {
            _statusCasBtn.title = @"CAS: OFF";
            _statusCasBtn.contentTintColor = NSColor.secondaryLabelColor;
        }
    } else {
        _statusCasBtn.hidden = YES;
    }

    if (_captionOverlay.captionsEnabled) {
        _statusCaptionBtn.title = (_availableCaptionLanguages.count > 0 || active.hasCaptions)
            ? @"字幕: ON" : @"字幕: 待機";
    } else {
        _statusCaptionBtn.title = @"字幕: OFF";
    }

    if (_plugin.muted) {
        _statusVolumeBtn.title = @"🔇 ミュート";
    } else {
        _statusVolumeBtn.title = [NSString stringWithFormat:@"🔊 %ld%%", (long)_plugin.volume];
    }

    [_sidePanelController updateSnapshot:_currentSnapshot
                         activeServiceID:_activeServiceID
                               videoSize:_plugin.videoSize
                                   stats:st
                                 session:_session];
    [_infoWindowController updateWithSnapshot:_currentSnapshot
                              activeServiceID:_activeServiceID
                                recordingName:(_liveSession ? _liveSession.tunerName : _recording.lastPathComponent)];
    [_streamInfoWindowController updateWithSnapshot:_currentSnapshot stats:st];
}

#pragma mark - SidePanelDelegate

- (void)sidePanelDidSelectServiceID:(uint16_t)serviceID {
    [self switchToServiceID:serviceID];
}

- (void)sidePanelDidSelectScannedChannel:(NSDictionary<NSString *, id> *)channelEntry {
    [self tuneScannedChannelEntry:channelEntry];
}

- (void)refreshSidePanelLiveChannels {
    if (!_liveSession) {
        [_sidePanelController updateLiveChannels:@[]
                                      spaceNames:@[]
                                    currentSpace:NSUIntegerMax
                                  currentChannel:NSUIntegerMax
                                 activeServiceID:_activeServiceID];
        return;
    }
    NSArray<NSDictionary<NSString *, id> *> *scanned =
        [TVTestSettings.sharedSettings loadScannedChannelsForDriverIdentifier:_liveSession.driverIdentifier];
    NSMutableArray<NSString *> *spaceNames = [NSMutableArray array];
    for (TVTestTunerSpace *sp in _liveSession.tuningSpaces) {
        [spaceNames addObject:sp.name ?: @""];
    }
    [_sidePanelController updateLiveChannels:scanned
                                  spaceNames:spaceNames
                                currentSpace:_liveSession.currentSpace
                              currentChannel:_liveSession.currentChannel
                             activeServiceID:_activeServiceID];
}

- (NSArray<NSDictionary<NSString *, id> *> *)scannedChannelsInCurrentSpace {
    if (!_liveSession) return @[];
    NSArray<NSDictionary<NSString *, id> *> *all =
        [TVTestSettings.sharedSettings loadScannedChannelsForDriverIdentifier:_liveSession.driverIdentifier];
    NSMutableArray<NSDictionary<NSString *, id> *> *inSpace = [NSMutableArray array];
    NSUInteger curSpace = _liveSession.currentSpace;
    for (NSDictionary<NSString *, id> *e in all) {
        if ([e[@"space"] unsignedIntegerValue] == curSpace) {
            [inSpace addObject:e];
        }
    }
    return inSpace.count > 0 ? inSpace : all;
}

- (void)stepScannedChannelBy:(NSInteger)delta {
    NSArray<NSDictionary<NSString *, id> *> *list = [self scannedChannelsInCurrentSpace];
    if (list.count == 0) return;
    NSInteger curIdx = -1;
    for (NSUInteger i = 0; i < list.count; ++i) {
        NSDictionary *e = list[i];
        uint16_t sid = [e[@"serviceID"] unsignedShortValue];
        if ([e[@"space"] unsignedIntegerValue] == _liveSession.currentSpace &&
            [e[@"channel"] unsignedIntegerValue] == _liveSession.currentChannel &&
            (sid == 0 || sid == _activeServiceID)) {
            curIdx = (NSInteger)i;
            break;
        }
    }
    NSInteger nextIdx = (curIdx < 0)
        ? 0
        : ((curIdx + delta) % (NSInteger)list.count + (NSInteger)list.count) % (NSInteger)list.count;
    [self tuneScannedChannelEntry:list[(NSUInteger)nextIdx]];
}

- (void)selectRemoteChannelIndex:(NSUInteger)index {
    NSArray<NSDictionary<NSString *, id> *> *list = [self scannedChannelsInCurrentSpace];
    if (index < list.count) {
        [self tuneScannedChannelEntry:list[index]];
    }
}

- (NSMenu *)buildVideoContextMenu {
    NSMenu *ctx = [[NSMenu alloc] initWithTitle:@"TVTest"];

    // 1. Channel submenu (same as top-level チャンネル menu)
    [self menuNeedsUpdate:_channelMenu];
    NSMenuItem *chItem = [ctx addItemWithTitle:@"チャンネル" action:nil keyEquivalent:@""];
    chItem.submenu = [_channelMenu copy];

    // 2. Service submenu
    [self menuNeedsUpdate:_serviceMenu];
    NSMenuItem *svcItem = [ctx addItemWithTitle:@"サービス" action:nil keyEquivalent:@""];
    svcItem.submenu = [_serviceMenu copy];

    // 3. Audio submenu
    [self menuNeedsUpdate:_audioMenu];
    NSMenuItem *audItem = [ctx addItemWithTitle:@"音声" action:nil keyEquivalent:@""];
    audItem.submenu = [_audioMenu copy];

    [ctx addItem:[NSMenuItem separatorItem]];

    // 4. Quick actions matching Windows TVTest right-click menu
    NSMenuItem *recItem = [ctx addItemWithTitle:(_liveSession.isRecording ? @"● 録画停止" : @"録画開始")
                                         action:@selector(toggleLiveRecording:)
                                  keyEquivalent:@""];
    recItem.target = self;
    recItem.enabled = (_liveSession != nil);

    NSMenuItem *capImg = [ctx addItemWithTitle:@"静止画キャプチャ (スナップショット)"
                                        action:@selector(captureSnapshotToFile:)
                                 keyEquivalent:@""];
    capImg.target = self;

    NSMenuItem *subToggle = [ctx addItemWithTitle:@"ARIB 字幕を表示"
                                           action:@selector(toggleCaptions:)
                                    keyEquivalent:@""];
    subToggle.target = self;
    subToggle.state = _captionOverlay.captionsEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *muteItem = [ctx addItemWithTitle:@"ミュート"
                                          action:@selector(toggleMute:)
                                   keyEquivalent:@""];
    muteItem.target = self;
    muteItem.state = _plugin.muted ? NSControlStateValueOn : NSControlStateValueOff;

    [ctx addItem:[NSMenuItem separatorItem]];

    NSMenuItem *epgItem = [ctx addItemWithTitle:@"EPG 番組表…"
                                         action:@selector(showProgramGuide:)
                                  keyEquivalent:@""];
    epgItem.target = self;

    NSMenuItem *panelItem = [ctx addItemWithTitle:@"サイドパネルを表示"
                                           action:@selector(toggleSidePanel:)
                                    keyEquivalent:@""];
    panelItem.target = self;
    panelItem.state = TVTestSettings.sharedSettings.panelVisible ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *topItem = [ctx addItemWithTitle:@"常に手前に表示"
                                         action:@selector(toggleAlwaysOnTop:)
                                  keyEquivalent:@""];
    topItem.target = self;
    topItem.state = TVTestSettings.sharedSettings.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *frameItem = [ctx addItemWithTitle:@"タイトルバーを隠す（フレームレス）"
                                           action:@selector(toggleFramelessWindow:)
                                    keyEquivalent:@""];
    frameItem.target = self;
    frameItem.state = TVTestSettings.sharedSettings.framelessWindow ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *fsItem = [ctx addItemWithTitle:@"フルスクリーン切替"
                                        action:@selector(toggleFullScreen:)
                                 keyEquivalent:@""];
    fsItem.target = _window;

    [ctx addItem:[NSMenuItem separatorItem]];

    [self menuNeedsUpdate:_driverMenu];
    NSMenuItem *drvItem = [ctx addItemWithTitle:@"ドライバ" action:nil keyEquivalent:@""];
    drvItem.submenu = [_driverMenu copy];

    NSMenuItem *infoItem = [ctx addItemWithTitle:@"ストリーム情報…"
                                          action:@selector(showStreamInfo:)
                                   keyEquivalent:@""];
    infoItem.target = self;

    NSMenuItem *prefsItem = [ctx addItemWithTitle:@"設定…"
                                           action:@selector(showPreferences:)
                                    keyEquivalent:@""];
    prefsItem.target = self;

    return ctx;
}

- (void)installWindowsTVTestInteractionMonitor {
    __weak TVTestApp *weakSelf = self;
    NSEventMask mask = NSEventMaskRightMouseDown | NSEventMaskLeftMouseDown |
                       NSEventMaskScrollWheel | NSEventMaskKeyDown;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent * _Nullable(NSEvent *event) {
        TVTestApp *self = weakSelf;
        if (!self || event.window != self->_window) {
            return event;
        }

        // Right-click inside video pane -> Windows TVTest context menu
        if (event.type == NSEventTypeRightMouseDown) {
            NSPoint ptInVideo = [self->_videoPane convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(ptInVideo, self->_videoPane.bounds)) {
                NSMenu *menu = [self buildVideoContextMenu];
                [NSMenu popUpContextMenu:menu withEvent:event forView:self->_videoPane];
                return nil;
            }
            return event;
        }

        // Left-click: double-click video -> Fullscreen; single-click status bar -> Channel menu / Stream info
        if (event.type == NSEventTypeLeftMouseDown) {
            NSPoint ptInVideo = [self->_videoPane convertPoint:event.locationInWindow fromView:nil];
            if (event.clickCount == 2 && NSPointInRect(ptInVideo, self->_videoPane.bounds)) {
                [self->_window toggleFullScreen:nil];
                return nil;
            }
            NSPoint ptInStatus = [self->_statusBar convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(ptInStatus, self->_statusBar.bounds)) {
                NSPoint ptInLeft = [self->_statusLeft convertPoint:event.locationInWindow fromView:nil];
                if (NSPointInRect(ptInLeft, self->_statusLeft.bounds) && self->_liveSession) {
                    [self menuNeedsUpdate:self->_channelMenu];
                    [self->_channelMenu popUpMenuPositioningItem:nil
                                                      atLocation:NSMakePoint(ptInStatus.x, self->_statusBar.bounds.size.height + 2)
                                                          inView:self->_statusBar];
                    return nil;
                }
            }
            return event;
        }

        // Scroll wheel inside video pane -> Volume up/down (Shift+Wheel -> Channel up/down)
        if (event.type == NSEventTypeScrollWheel) {
            NSPoint ptInVideo = [self->_videoPane convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(ptInVideo, self->_videoPane.bounds) && fabs(event.scrollingDeltaY) >= 1.0) {
                if (event.modifierFlags & NSEventModifierFlagShift) {
                    [self stepScannedChannelBy:(event.scrollingDeltaY > 0 ? -1 : 1)];
                } else {
                    NSInteger cur = self->_plugin.volume;
                    NSInteger next = MAX((NSInteger)0, MIN((NSInteger)100, cur + (event.scrollingDeltaY > 0 ? 5 : -5)));
                    [self->_plugin setVolume:next];
                    TVTestSettings.sharedSettings.volume = next;
                    [self->_osdOverlay showMessage:[NSString stringWithFormat:@"音量  %ld%%", (long)next] subtitle:nil];
                }
                return nil;
            }
            return event;
        }

        // Single-key Windows TVTest shortcuts when no text input has focus
        if (event.type == NSEventTypeKeyDown) {
            NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
            if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) {
                return event;
            }
            NSResponder *fr = self->_window.firstResponder;
            if ([fr isKindOfClass:[NSTextView class]] || [fr isKindOfClass:[NSTextField class]]) {
                return event;
            }
            NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
            if (chars.length == 1) {
                unichar ch = [chars characterAtIndex:0];
                if (ch >= '1' && ch <= '9') {
                    [self selectRemoteChannelIndex:(NSUInteger)(ch - '1')];
                    return nil;
                }
                if (ch == '0') {
                    [self selectRemoteChannelIndex:9];
                    return nil;
                }
                if (ch == NSPageUpFunctionKey || ch == '[') {
                    [self stepScannedChannelBy:-1];
                    return nil;
                }
                if (ch == NSPageDownFunctionKey || ch == ']') {
                    [self stepScannedChannelBy:1];
                    return nil;
                }
                if (ch == 'm') { [self toggleMute:nil]; return nil; }
                if (ch == 's') { [self toggleSidePanel:nil]; return nil; }
                if (ch == 'c') { [self toggleCaptions:nil]; return nil; }
                if (ch == 'e' || ch == 'g') { [self showProgramGuide:nil]; return nil; }
                if (ch == 'r') { [self toggleLiveRecording:nil]; return nil; }
                if (ch == 'p') { [self captureSnapshotToFile:nil]; return nil; }
                if (ch == 'f') { [self->_window toggleFullScreen:nil]; return nil; }
                if (ch == 't') { [self toggleAlwaysOnTop:nil]; return nil; }
            }
        }
        return event;
    }];
}

- (void)sidePanelDidRequestSeekToTimeMs:(int64_t)timeMs {
    [_plugin seekToTimeMs:timeMs];
    int64_t sec = MAX((int64_t)0, timeMs) / 1000;
    [_osdOverlay showMessage:[NSString stringWithFormat:@"シーク  %02lld:%02lld", sec / 60, sec % 60]
                    subtitle:nil];
}

- (void)sidePanelDidRequestExportCaptions {
    [self exportCaptionsToFile:nil];
}

- (void)sidePanelDidChangeSelectedTab:(TVTestSidePanelTab)tab {
    TVTestSettings.sharedSettings.selectedPanelTab = (NSInteger)tab;
}

#pragma mark - Menus & Actions

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == _driverMenu) {
        [menu removeAllItems];
        NSMenuItem *openItem = [menu addItemWithTitle:@"MacBonDriver (.bundle) を開く…"
                                               action:@selector(chooseBonDriver:)
                                        keyEquivalent:@""];
        openItem.target = self;

        NSArray<TVTestBonDriverInfo *> *drivers =
            [TVTestLiveTunerSession discoverBonDriversInDirectories:TVTestSettings.sharedSettings.bonDriverSearchDirectories];
        if (drivers.count > 0) {
            [menu addItem:[NSMenuItem separatorItem]];
            for (TVTestBonDriverInfo *drv in drivers) {
                NSString *sys = drv.supportedSystems.count
                    ? [NSString stringWithFormat:@" [%@]", [drv.supportedSystems componentsJoinedByString:@"/"]]
                    : @"";
                NSMenuItem *di = [menu addItemWithTitle:[drv.displayName stringByAppendingString:sys]
                                                 action:@selector(openDiscoveredBonDriver:)
                                          keyEquivalent:@""];
                di.target = self;
                di.representedObject = drv.bundleURL;
                di.state = (_liveSession && [_liveSession.bundleURL isEqual:drv.bundleURL])
                    ? NSControlStateValueOn : NSControlStateValueOff;
            }
        }

        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *closeItem = [menu addItemWithTitle:@"ドライバを閉じる"
                                                action:@selector(closeBonDriver:)
                                         keyEquivalent:@""];
        closeItem.target = self;
        closeItem.enabled = (_liveSession != nil);

        if (_liveSession.supportsLNBPower) {
            NSMenuItem *lnbRoot = [menu addItemWithTitle:@"LNB 電源" action:nil keyEquivalent:@""];
            NSMenu *lnbMenu = [[NSMenu alloc] initWithTitle:@"LNB 電源"];
            lnbRoot.submenu = lnbMenu;
            NSArray<NSArray *> *modes = @[
                @[@"OFF", @(MBDLNBPowerOff)],
                @[@"15V", @(MBDLNBPower15V)],
                @[@"11V", @(MBDLNBPower11V)],
                @[@"自動", @(MBDLNBPowerAuto)],
            ];
            for (NSArray *spec in modes) {
                NSMenuItem *li = [lnbMenu addItemWithTitle:spec[0] action:@selector(selectLNBPower:) keyEquivalent:@""];
                li.target = self;
                li.tag = [spec[1] integerValue];
                li.state = (_liveSession.currentLNBPowerMode == (MBDLNBPowerMode)li.tag)
                    ? NSControlStateValueOn : NSControlStateValueOff;
            }
        }

        if (_liveSession.supportsSmartCard) {
            NSMenuItem *scItem = [menu addItemWithTitle:@"内蔵スマートカード状態…"
                                                 action:@selector(showSmartCardStatus:)
                                          keyEquivalent:@""];
            scItem.target = self;
        }
        return;
    } else if (menu == _channelMenu) {
        [menu removeAllItems];
        if (!_liveSession) {
            NSMenuItem *empty = [menu addItemWithTitle:@"MacBonDriver 未接続" action:nil keyEquivalent:@""];
            empty.enabled = NO;
            return;
        }
        NSArray<NSDictionary<NSString *, id> *> *scanned =
            [TVTestSettings.sharedSettings loadScannedChannelsForDriverIdentifier:_liveSession.driverIdentifier];
        if (scanned.count > 0) {
            // Windows TVTest style: show only scanned channels directly, grouped by tuning space.
            NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary<NSString *, id> *> *> *bySpace = [NSMutableDictionary dictionary];
            for (NSDictionary<NSString *, id> *entry in scanned) {
                NSNumber *spKey = entry[@"space"] ?: @0;
                NSMutableArray *arr = bySpace[spKey];
                if (!arr) {
                    arr = [NSMutableArray array];
                    bySpace[spKey] = arr;
                }
                [arr addObject:entry];
            }
            NSArray<NSNumber *> *sortedSpaces = [bySpace.allKeys sortedArrayUsingSelector:@selector(compare:)];
            for (NSNumber *spKey in sortedSpaces) {
                NSUInteger spIdx = spKey.unsignedIntegerValue;
                NSString *spName = (spIdx < _liveSession.tuningSpaces.count)
                    ? _liveSession.tuningSpaces[spIdx].name
                    : [NSString stringWithFormat:@"空間 %lu", (unsigned long)spIdx];
                NSMenuItem *spItem = [menu addItemWithTitle:spName action:nil keyEquivalent:@""];
                spItem.state = (_liveSession.currentSpace == spIdx)
                    ? NSControlStateValueOn : NSControlStateValueOff;
                NSMenu *targetMenu = [[NSMenu alloc] initWithTitle:spName];
                spItem.submenu = targetMenu;
                for (NSDictionary<NSString *, id> *entry in bySpace[spKey]) {
                    NSString *title = [NSString stringWithFormat:@"%@ (%@)",
                                       entry[@"name"] ?: @"", entry[@"channelName"] ?: @""];
                    NSMenuItem *si = [targetMenu addItemWithTitle:title
                                                           action:@selector(selectScannedChannel:)
                                                    keyEquivalent:@""];
                    si.target = self;
                    si.representedObject = entry;
                    uint16_t sid = [entry[@"serviceID"] unsignedShortValue];
                    BOOL isCurrent = (_liveSession.currentSpace == [entry[@"space"] unsignedIntegerValue] &&
                                      _liveSession.currentChannel == [entry[@"channel"] unsignedIntegerValue] &&
                                      (sid == 0 || sid == _activeServiceID));
                    si.state = isCurrent ? NSControlStateValueOn : NSControlStateValueOff;
                }
            }
        } else {
            NSMenuItem *hint = [menu addItemWithTitle:@"未スキャン（下の「チャンネルスキャン…」を実行してください）"
                                               action:nil
                                        keyEquivalent:@""];
            hint.enabled = NO;
        }
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *scanMenuItem = [menu addItemWithTitle:@"チャンネルスキャン…"
                                                   action:@selector(showChannelScan:)
                                            keyEquivalent:@""];
        scanMenuItem.target = self;

        // Keep raw physical channels accessible under a secondary submenu for manual tuning
        NSMenuItem *rawRoot = [menu addItemWithTitle:@"全物理チャンネル（手動選局）" action:nil keyEquivalent:@""];
        NSMenu *rawMenu = [[NSMenu alloc] initWithTitle:@"全物理チャンネル（手動選局）"];
        rawRoot.submenu = rawMenu;
        for (TVTestTunerSpace *space in _liveSession.tuningSpaces) {
            NSMenuItem *spItem = [rawMenu addItemWithTitle:space.name action:nil keyEquivalent:@""];
            NSMenu *spMenu = [[NSMenu alloc] initWithTitle:space.name];
            spItem.submenu = spMenu;
            for (TVTestTunerChannel *ch in space.channels) {
                NSString *label = ch.frequencyKHz > 0
                    ? [NSString stringWithFormat:@"%@ (%.1f MHz)", ch.name, (double)ch.frequencyKHz / 1000.0]
                    : ch.name;
                NSMenuItem *ci = [spMenu addItemWithTitle:label
                                                   action:@selector(selectTunerChannel:)
                                            keyEquivalent:@""];
                ci.target = self;
                ci.representedObject = ch;
                ci.state = (_liveSession.currentSpace == ch.spaceIndex &&
                            _liveSession.currentChannel == ch.channelIndex)
                    ? NSControlStateValueOn : NSControlStateValueOff;
            }
        }
        return;
    } else if (menu == _recentMenu) {
        [menu removeAllItems];
        NSArray<NSString *> *paths = TVTestSettings.sharedSettings.recentRecordingPaths;
        if (paths.count == 0) {
            NSMenuItem *empty = [menu addItemWithTitle:@"履歴なし" action:nil keyEquivalent:@""];
            empty.enabled = NO;
            return;
        }
        for (NSString *path in paths) {
            NSMenuItem *item = [menu addItemWithTitle:path.lastPathComponent
                                               action:@selector(openRecentRecording:)
                                        keyEquivalent:@""];
            item.target = self;
            item.representedObject = [NSURL fileURLWithPath:path];
            item.toolTip = path;
        }
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *clearItem = [menu addItemWithTitle:@"履歴を消去"
                                                action:@selector(clearRecentRecordings:)
                                         keyEquivalent:@""];
        clearItem.target = self;
    } else if (menu == _serviceMenu) {
        [menu removeAllItems];
        NSArray<TVTestServiceInfo *> *services = _currentSnapshot.services ?: @[];
        if (services.count == 0) {
            NSMenuItem *empty = [menu addItemWithTitle:@"サービスなし" action:nil keyEquivalent:@""];
            empty.enabled = NO;
            return;
        }
        for (NSUInteger idx = 0; idx < services.count; ++idx) {
            TVTestServiceInfo *svc = services[idx];
            NSString *title = svc.currentProgram.title.length
                ? [NSString stringWithFormat:@"%@ (SID %u) — %@", svc.name, svc.serviceID, svc.currentProgram.title]
                : [NSString stringWithFormat:@"%@ (SID %u)", svc.name, svc.serviceID];
            NSString *keyEq = (idx < 9) ? [NSString stringWithFormat:@"%lu", (unsigned long)(idx + 1)] : @"";
            NSMenuItem *item = [menu addItemWithTitle:title
                                               action:@selector(selectService:)
                                        keyEquivalent:keyEq];
            item.target = self;
            item.tag = svc.serviceID;
            item.state = (svc.serviceID == _activeServiceID) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    } else if (menu == _audioMenu) {
        [menu removeAllItems];
        NSArray<NSDictionary<NSString *, id> *> *tracks = _plugin.audioTracks ?: @[];
        NSInteger currentID = _plugin.currentAudioTrackID;
        TVTestServiceInfo *active = [_currentSnapshot serviceWithID:_activeServiceID];
        if (tracks.count == 0) {
            NSMenuItem *empty = [menu addItemWithTitle:@"音声トラックなし" action:nil keyEquivalent:@""];
            empty.enabled = NO;
        } else {
            NSUInteger validIndex = 0;
            for (NSDictionary<NSString *, id> *tr in tracks) {
                NSInteger trackID = [tr[@"id"] integerValue];
                NSString *vlcName = tr[@"name"] ?: @"Audio";
                NSString *label = vlcName;
                if (trackID >= 0) {
                    if (validIndex < active.audioStreams.count) {
                        NSString *isdbLabel = active.audioStreams[validIndex].label;
                        if (isdbLabel.length) {
                            label = [NSString stringWithFormat:@"%@ (%@)", isdbLabel, vlcName];
                        }
                    }
                    ++validIndex;
                }
                NSMenuItem *item = [menu addItemWithTitle:label
                                                   action:@selector(selectAudioTrack:)
                                            keyEquivalent:@""];
                item.target = self;
                item.tag = trackID;
                item.state = (trackID == currentID) ? NSControlStateValueOn : NSControlStateValueOff;
            }
        }
        [menu addItem:[NSMenuItem separatorItem]];
        NSArray<NSNumber *> *modes = @[
            @(TVTestAudioChannelModeStereo),
            @(TVTestAudioChannelModeLeft),
            @(TVTestAudioChannelModeRight),
            @(TVTestAudioChannelModeReverseStereo),
        ];
        TVTestAudioChannelMode curMode = _plugin.audioChannelMode;
        for (NSNumber *m in modes) {
            TVTestAudioChannelMode mode = (TVTestAudioChannelMode)m.integerValue;
            NSMenuItem *mi = [menu addItemWithTitle:AudioChannelModeTitle(mode)
                                             action:@selector(selectAudioChannelMode:)
                                      keyEquivalent:@""];
            mi.target = self;
            mi.tag = mode;
            mi.state = (mode == curMode) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    } else if (menu == _captionLangMenu) {
        [menu removeAllItems];
        if (_availableCaptionLanguages.count == 0) {
            NSMenuItem *empty = [menu addItemWithTitle:@"字幕データなし" action:nil keyEquivalent:@""];
            empty.enabled = NO;
            return;
        }
        for (NSNumber *tagNum in _availableCaptionLanguages) {
            uint8_t tag = (uint8_t)tagNum.unsignedIntValue;
            NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"字幕言語 %u", tag + 1]
                                               action:@selector(selectCaptionLanguage:)
                                        keyEquivalent:@""];
            item.target = self;
            item.tag = tag;
            item.state = (tag == _selectedCaptionLanguage) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL act = item.action;
    TVTestSettings *s = TVTestSettings.sharedSettings;

    if (act == @selector(toggleMute:)) {
        item.state = _plugin.muted ? NSControlStateValueOn : NSControlStateValueOff;
        return _recording != nil;
    }
    if (act == @selector(selectPlaybackRate:)) {
        float targetRate = [item.representedObject floatValue];
        item.state = fabsf(_plugin.playbackRate - targetRate) < 0.05f
            ? NSControlStateValueOn : NSControlStateValueOff;
        return _recording != nil;
    }
    if (act == @selector(selectAspectRatio:)) {
        NSString *cur = _plugin.aspectRatio ?: @"";
        item.state = [cur isEqualToString:(item.representedObject ?: @"")]
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(selectCropGeometry:)) {
        NSString *cur = _plugin.cropGeometry ?: @"";
        item.state = [cur isEqualToString:(item.representedObject ?: @"")]
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(selectDeinterlaceMode:)) {
        NSString *cur = _plugin.deinterlaceMode ?: @"";
        item.state = [cur isEqualToString:(item.representedObject ?: @"")]
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleSidePanel:)) {
        item.state = s.panelVisible ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(selectSidePanelTab:)) {
        item.state = ((NSInteger)_sidePanelController.selectedTab == item.tag)
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleStatusBar:)) {
        item.state = s.statusBarVisible ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleControlsHidden:)) {
        item.state = _plugin.controlsHidden ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleAlwaysOnTop:)) {
        item.state = s.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleCaptions:)) {
        item.state = _captionOverlay.captionsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleOSD:)) {
        item.state = _osdOverlay.osdEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (act == @selector(toggleLiveRecording:)) {
        item.title = _liveSession.isRecording ? @"録画停止" : @"録画開始";
        return _liveSession != nil;
    }
    if (act == @selector(showRecordingInfo:) || act == @selector(showStreamInfo:) ||
        act == @selector(togglePlayPause:) || act == @selector(stopPlayback:) ||
        act == @selector(captureSnapshotToFile:) || act == @selector(captureSnapshotToClipboard:) ||
        act == @selector(exportCaptionsToFile:)) {
        return (_recording != nil || _liveSession != nil);
    }
    if (act == @selector(seekBackward10:) || act == @selector(seekForward30:) ||
        act == @selector(seekBackward60:) || act == @selector(seekForward60:) ||
        act == @selector(exportCurrentServiceTS:)) {
        return _recording != nil;
    }
    return YES;
}

- (void)openRecentRecording:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) {
        [self openRecording:url];
    }
}

- (void)clearRecentRecordings:(id)sender {
    (void)sender;
    [TVTestSettings.sharedSettings clearRecentRecordings];
}

- (void)togglePlayPause:(id)sender {
    (void)sender;
    [_plugin togglePlayPause];
    [_osdOverlay showMessage:(_plugin.isPlaying ? @"再生" : @"一時停止") subtitle:nil];
}

- (void)stopPlayback:(id)sender {
    (void)sender;
    [_plugin stop];
    [_osdOverlay showMessage:@"停止" subtitle:nil];
}

- (void)seekBackward10:(id)sender {
    (void)sender;
    [_plugin seekByMs:-10000];
    [_osdOverlay showMessage:@"⏪ -10 秒" subtitle:nil];
}

- (void)seekForward30:(id)sender {
    (void)sender;
    [_plugin seekByMs:30000];
    [_osdOverlay showMessage:@"⏩ +30 秒" subtitle:nil];
}

- (void)seekBackward60:(id)sender {
    (void)sender;
    [_plugin seekByMs:-60000];
    [_osdOverlay showMessage:@"⏪ -1 分" subtitle:nil];
}

- (void)seekForward60:(id)sender {
    (void)sender;
    [_plugin seekByMs:60000];
    [_osdOverlay showMessage:@"⏩ +1 分" subtitle:nil];
}

- (void)selectPlaybackRate:(NSMenuItem *)sender {
    float rate = [sender.representedObject floatValue];
    [_plugin setPlaybackRate:rate];
    [_osdOverlay showMessage:[NSString stringWithFormat:@"再生速度  %.2gx", rate] subtitle:nil];
}

- (void)volumeUp:(id)sender {
    (void)sender;
    NSInteger v = MIN((NSInteger)100, _plugin.volume + 5);
    [_plugin setVolume:v];
    TVTestSettings.sharedSettings.volume = v;
    [_osdOverlay showVolume:v muted:_plugin.muted];
}

- (void)volumeDown:(id)sender {
    (void)sender;
    NSInteger v = MAX((NSInteger)0, _plugin.volume - 5);
    [_plugin setVolume:v];
    TVTestSettings.sharedSettings.volume = v;
    [_osdOverlay showVolume:v muted:_plugin.muted];
}

- (void)toggleMute:(id)sender {
    (void)sender;
    BOOL m = !_plugin.muted;
    [_plugin setMuted:m];
    [_osdOverlay showVolume:_plugin.volume muted:m];
}

- (void)selectService:(NSMenuItem *)sender {
    [self switchToServiceID:(uint16_t)sender.tag];
}

- (void)switchToServiceID:(uint16_t)sid {
    if (sid == 0 || sid == _activeServiceID) {
        return;
    }
    if (_liveSession) {
        _activeServiceID = sid;
        [_liveSession setActiveServiceID:sid];
        NSError *err = nil;
        [_plugin openLiveStreamWithServiceID:sid error:&err];
        _captionOverlay.currentCue = nil;
        [self refreshMetadataUI];
        [self presentServiceOSDForService:[_currentSnapshot serviceWithID:sid]];
        [_sidePanelController updateEPGServices:[_liveSession currentEPGServices] activeServiceID:sid];
        return;
    }
    if (!_recording) {
        return;
    }
    _activeServiceID = sid;
    double pos = _plugin.playbackPosition;
    NSError *error = nil;
    if (![_plugin openRecording:_recording serviceID:sid startPosition:pos error:&error]) {
        [self showError:error.localizedDescription ?: @"サービスを切り替えられませんでした。"];
        return;
    }
    _captionOverlay.currentCue = nil;
    [self refreshMetadataUI];
    [self presentServiceOSDForService:[_currentSnapshot serviceWithID:sid]];
    [_sidePanelController updateEPGServices:[_session currentEPGServices] activeServiceID:sid];

    TVTestRecordingSession *session = _session;
    __weak TVTestApp *weakSelf = self;
    [session reindexCaptionsForServiceID:sid onUpdate:^(NSArray<NSNumber *> *languageTags) {
        TVTestApp *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_session != session) {
            return;
        }
        strongSelf->_availableCaptionLanguages = languageTags;
        if (languageTags.count > 0 && ![languageTags containsObject:@(strongSelf->_selectedCaptionLanguage)]) {
            strongSelf->_selectedCaptionLanguage = (uint8_t)languageTags.firstObject.unsignedIntValue;
        }
        [strongSelf->_sidePanelController updateCaptions:
            [session allCaptionCuesForLanguageTag:strongSelf->_selectedCaptionLanguage]];
        [strongSelf refreshMetadataUI];
    }];
}

- (void)applyZoomPercent:(NSMenuItem *)sender {
    NSInteger pct = sender.tag;
    NSSize base = _plugin.videoSize;
    if (base.width <= 0 || base.height <= 0) {
        base = NSMakeSize(1280, 720);
    }
    CGFloat targetW = round(base.width * ((CGFloat)pct / 100.0));
    CGFloat targetH = round(base.height * ((CGFloat)pct / 100.0));
    if (TVTestSettings.sharedSettings.panelVisible) {
        targetW += _sidePanelController.view.frame.size.width;
    }
    if (!_plugin.controlsHidden) {
        targetH += 64.0;
    }
    if (TVTestSettings.sharedSettings.statusBarVisible) {
        targetH += 27.0;
    }
    [_window setContentSize:NSMakeSize(MAX(680.0, targetW), MAX(380.0, targetH))];
    [_osdOverlay showMessage:[NSString stringWithFormat:@"表示倍率  %ld%%", (long)pct] subtitle:nil];
}

- (void)selectAspectRatio:(NSMenuItem *)sender {
    NSString *ar = sender.representedObject;
    [_plugin setAspectRatio:ar];
    TVTestSettings.sharedSettings.defaultAspectRatio = ar;
    [_osdOverlay showMessage:[NSString stringWithFormat:@"アスペクト比: %@", sender.title] subtitle:nil];
}

- (void)selectCropGeometry:(NSMenuItem *)sender {
    NSString *crop = sender.representedObject;
    [_plugin setCropGeometry:crop];
    [_osdOverlay showMessage:[NSString stringWithFormat:@"クロップ: %@", sender.title] subtitle:nil];
}

- (void)selectDeinterlaceMode:(NSMenuItem *)sender {
    NSString *mode = sender.representedObject;
    [_plugin setDeinterlaceMode:mode];
    TVTestSettings.sharedSettings.defaultDeinterlaceMode = mode;
    [_osdOverlay showMessage:[NSString stringWithFormat:@"インターレース解除: %@", sender.title] subtitle:nil];
}

- (void)selectAudioTrack:(NSMenuItem *)sender {
    [_plugin selectAudioTrackID:sender.tag];
    [_osdOverlay showMessage:[NSString stringWithFormat:@"音声: %@", sender.title] subtitle:nil];
}

- (void)selectAudioChannelMode:(NSMenuItem *)sender {
    TVTestAudioChannelMode mode = (TVTestAudioChannelMode)sender.tag;
    [_plugin setAudioChannelMode:mode];
    [self refreshMetadataUI];
    [_osdOverlay showMessage:[NSString stringWithFormat:@"音声モード: %@", AudioChannelModeTitle(mode)] subtitle:nil];
}

- (void)toggleSidePanel:(id)sender {
    (void)sender;
    BOOL next = !TVTestSettings.sharedSettings.panelVisible;
    TVTestSettings.sharedSettings.panelVisible = next;
    _sidePanelController.view.hidden = !next;
    [_mainSplitView adjustSubviews];
}

- (void)selectSidePanelTab:(NSMenuItem *)sender {
    if (!TVTestSettings.sharedSettings.panelVisible) {
        TVTestSettings.sharedSettings.panelVisible = YES;
        _sidePanelController.view.hidden = NO;
        [_mainSplitView adjustSubviews];
    }
    _sidePanelController.selectedTab = (TVTestSidePanelTab)sender.tag;
    TVTestSettings.sharedSettings.selectedPanelTab = sender.tag;
}

- (void)toggleStatusBar:(id)sender {
    (void)sender;
    TVTestSettings.sharedSettings.statusBarVisible = !TVTestSettings.sharedSettings.statusBarVisible;
    [self applySettingsToUI];
}

- (void)toggleControlsHidden:(id)sender {
    (void)sender;
    BOOL next = !_plugin.controlsHidden;
    _plugin.controlsHidden = next;
    TVTestSettings.sharedSettings.controlsHidden = next;
}

- (void)toggleAlwaysOnTop:(id)sender {
    (void)sender;
    BOOL next = !TVTestSettings.sharedSettings.alwaysOnTop;
    TVTestSettings.sharedSettings.alwaysOnTop = next;
    _window.level = next ? NSFloatingWindowLevel : NSNormalWindowLevel;
    [_osdOverlay showMessage:(next ? @"常に最前面: ON" : @"常に最前面: OFF") subtitle:nil];
}

- (void)toggleCaptions:(id)sender {
    (void)sender;
    BOOL next = !_captionOverlay.captionsEnabled;
    _captionOverlay.captionsEnabled = next;
    TVTestSettings.sharedSettings.captionsEnabled = next;
    if (!next) {
        _captionOverlay.currentCue = nil;
    }
    [self refreshMetadataUI];
    [_osdOverlay showMessage:(next ? @"ARIB 字幕: ON" : @"ARIB 字幕: OFF") subtitle:nil];
}

- (void)selectCaptionLanguage:(NSMenuItem *)sender {
    _selectedCaptionLanguage = (uint8_t)sender.tag;
    _captionOverlay.currentCue = nil;
    if (_session) {
        [_sidePanelController updateCaptions:[_session allCaptionCuesForLanguageTag:_selectedCaptionLanguage]];
    }
    [_osdOverlay showMessage:[NSString stringWithFormat:@"字幕言語 %u", _selectedCaptionLanguage + 1] subtitle:nil];
}

- (void)toggleOSD:(id)sender {
    (void)sender;
    BOOL next = !_osdOverlay.osdEnabled;
    _osdOverlay.osdEnabled = next;
    TVTestSettings.sharedSettings.osdEnabled = next;
    if (next) {
        [_osdOverlay showMessage:@"OSD 表示: ON" subtitle:nil];
    }
}

#pragma mark - Capture & Export Tools

- (void)captureSnapshotToFile:(id)sender {
    (void)sender;
    TVTestSettings *s = TVTestSettings.sharedSettings;
    TVTestServiceInfo *active = [_currentSnapshot serviceWithID:_activeServiceID];
    NSString *stem = [s expandFilenamePattern:s.captureFilenamePattern
                                  serviceName:active.name
                                    eventName:active.currentProgram.title];
    NSURL *dirURL = [NSURL fileURLWithPath:s.captureDirectory];
    NSURL *outURL = [[dirURL URLByAppendingPathComponent:stem] URLByAppendingPathExtension:@"png"];

    NSError *err = nil;
    if ([_plugin takeSnapshotToURL:outURL error:&err]) {
        [_osdOverlay showMessage:@"キャプチャを保存しました" subtitle:outURL.lastPathComponent];
    } else {
        [self showError:err.localizedDescription ?: @"キャプチャの保存に失敗しました。"];
    }
}

- (void)captureSnapshotToClipboard:(id)sender {
    (void)sender;
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tvtest_clipboard_snap.png"];
    NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];
    NSError *err = nil;
    if (![_plugin takeSnapshotToURL:tmpURL error:&err]) {
        [self showError:err.localizedDescription ?: @"キャプチャに失敗しました。"];
        return;
    }
    NSImage *img = [[NSImage alloc] initWithContentsOfURL:tmpURL];
    [NSFileManager.defaultManager removeItemAtURL:tmpURL error:NULL];
    if (img) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard writeObjects:@[img]];
        [_osdOverlay showMessage:@"静止画をクリップボードにコピーしました" subtitle:nil];
    }
}

- (void)exportCurrentServiceTS:(id)sender {
    (void)sender;
    if (!_session) {
        return;
    }
    TVTestSettings *s = TVTestSettings.sharedSettings;
    TVTestServiceInfo *active = [_currentSnapshot serviceWithID:_activeServiceID];
    NSString *stem = [s expandFilenamePattern:s.recordingFilenamePattern
                                  serviceName:active.name
                                    eventName:active.currentProgram.title];

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = [NSString stringWithFormat:@"サービス「%@ (SID %u)」を TS 書き出し",
                   active.name ?: @"現在のサービス", _activeServiceID];
    panel.directoryURL = [NSURL fileURLWithPath:s.recordingDirectory];
    panel.nameFieldStringValue = [stem stringByAppendingPathExtension:@"ts"];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"ts" conformingToType:UTTypeData]];

    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse resp) {
        if (resp != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSURL *destURL = panel.URL;
        uint16_t sid = self->_activeServiceID;
        TVTestRecordingSession *session = self->_session;
        [self->_osdOverlay showMessage:@"TS 書き出しを開始しました…" subtitle:destURL.lastPathComponent];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *exportErr = nil;
            BOOL ok = [session exportServiceID:sid toURL:destURL progress:nil error:&exportErr];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    [self->_osdOverlay showMessage:@"TS 書き出しが完了しました" subtitle:destURL.lastPathComponent];
                } else {
                    [self showError:exportErr.localizedDescription ?: @"TS 書き出しに失敗しました。"];
                }
            });
        });
    }];
}

- (void)exportCaptionsToFile:(nullable id)sender {
    (void)sender;
    NSArray<TVTestCaptionCue *> *cues = _liveSession
        ? [_liveSession allCaptionCuesForLanguageTag:_selectedCaptionLanguage]
        : [_session allCaptionCuesForLanguageTag:_selectedCaptionLanguage];
    if (cues.count == 0) {
        [self showError:@"書き出し可能な ARIB 字幕データがありません。"];
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"ARIB 字幕を保存 (.srt / .txt)";
    NSString *stem = _liveSession
        ? (_liveSession.tunerName ?: @"TVTest_Live")
        : ([_recording.lastPathComponent stringByDeletingPathExtension] ?: @"TVTest");
    panel.nameFieldStringValue = [stem stringByAppendingPathExtension:@"srt"];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse resp) {
        if (resp != NSModalResponseOK || !panel.URL) {
            return;
        }
        BOOL isTxt = [panel.URL.pathExtension.lowercaseString isEqualToString:@"txt"];
        NSString *content = isTxt
            ? [TVTestRecordingSession formatPlainTextFromCues:cues]
            : [TVTestRecordingSession formatSRTFromCues:cues];
        NSError *err = nil;
        if ([content writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
            [self->_osdOverlay showMessage:@"字幕ファイルを保存しました" subtitle:panel.URL.lastPathComponent];
        } else {
            [self showError:err.localizedDescription ?: @"字幕ファイルの保存に失敗しました。"];
        }
    }];
}

#pragma mark - MacBonDriver Live Reception & Recording

- (void)chooseBonDriver:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"MacBonDriver (.bundle) を選択";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"bundle" conformingToType:UTTypeBundle]];
    panel.treatsFilePackagesAsDirectories = NO;
    NSString *defaultDir = TVTestSettings.sharedSettings.bonDriverDirectory;
    if (defaultDir.length) {
        panel.directoryURL = [NSURL fileURLWithPath:defaultDir];
    }
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse resp) {
        if (resp == NSModalResponseOK && panel.URL) {
            [self openBonDriverAtURL:panel.URL];
        }
    }];
}

- (void)openDiscoveredBonDriver:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) {
        [self openBonDriverAtURL:url];
    }
}

- (void)openBonDriverAtURL:(NSURL *)bundleURL {
    [_session cancel];
    _session = nil;
    _recording = nil;
    [_liveSession closeTuner];
    _liveSession = nil;
    [_plugin closeLiveStream];

    NSError *err = nil;
    TVTestSettings *s = TVTestSettings.sharedSettings;
    TVTestLiveTunerSession *live = [TVTestLiveTunerSession sessionWithBundleURL:bundleURL
                                                                        options:[s driverOptionsDictionary]
                                                                          error:&err];
    if (!live) {
        [self showError:err.localizedDescription ?: @"MacBonDriver を読み込めませんでした。"];
        return;
    }
    live.delegate = self;

    if (![live openTunerWithEPGDataPath:(s.saveEPGData ? s.epgDataFilePath : nil)
                           logoCacheDir:s.logoCacheDirectory
                                  error:&err]) {
        [self showError:err.localizedDescription ?: @"チューナーを開けませんでした。"];
        return;
    }

    if (live.supportsLNBPower && s.defaultLNBPowerMode != MBDLNBPowerOff) {
        [live setLNBPowerMode:(MBDLNBPowerMode)s.defaultLNBPowerMode error:NULL];
    }

    _liveSession = live;
    _currentSnapshot = nil;
    _currentStats = nil;
    _activeServiceID = 0;
    _liveSignalCNR = 0.0f;
    _liveSignalLocked = NO;
    _captionOverlay.currentCue = nil;
    s.lastBonDriverPath = bundleURL.path;

    NSArray<NSDictionary<NSString *, id> *> *scanned =
        [s loadScannedChannelsForDriverIdentifier:live.driverIdentifier];
    NSDictionary<NSString *, id> *lastEntry = s.lastTunedChannelEntry;
    NSDictionary<NSString *, id> *firstScanned = nil;
    if (lastEntry) {
        NSUInteger sp = [lastEntry[@"space"] unsignedIntegerValue];
        NSUInteger ch = [lastEntry[@"channel"] unsignedIntegerValue];
        if (sp < live.tuningSpaces.count && ch < live.tuningSpaces[sp].channels.count) {
            firstScanned = lastEntry;
        }
    }
    if (!firstScanned) {
        firstScanned = scanned.firstObject;
    }
    TVTestTunerChannel *firstCh = live.tuningSpaces.firstObject.channels.firstObject;

    NSString *tunedLabel = @"チューナー接続完了";
    if (s.autoTuneOnDriverOpen && firstScanned) {
        NSUInteger sp = [firstScanned[@"space"] unsignedIntegerValue];
        NSUInteger ch = [firstScanned[@"channel"] unsignedIntegerValue];
        uint16_t streamID = [firstScanned[@"streamID"] unsignedShortValue];
        uint16_t sid = [firstScanned[@"serviceID"] unsignedShortValue];
        _activeServiceID = sid;
        [live setActiveServiceID:sid];
        [live tuneToSpace:sp channel:ch streamID:streamID error:NULL];
        if (![_plugin openLiveStreamWithServiceID:sid error:&err]) {
            [self showError:err.localizedDescription ?: @"ライブ再生を開始できませんでした。"];
            return;
        }
        tunedLabel = firstScanned[@"name"] ?: firstScanned[@"channelName"] ?: @"選局完了";
    } else {
        if (s.autoTuneOnDriverOpen && firstCh) {
            [live tuneToSpace:firstCh.spaceIndex channel:firstCh.channelIndex streamID:firstCh.streamID error:NULL];
            tunedLabel = firstCh.name;
        }
        if (![_plugin openLiveStreamWithServiceID:0 error:&err]) {
            [self showError:err.localizedDescription ?: @"ライブ再生を開始できませんでした。"];
            return;
        }
    }

    _window.title = [NSString stringWithFormat:@"%@ — TVTest", live.tunerName];
    [_osdOverlay showMessage:live.tunerName subtitle:tunedLabel];
    [_preferencesWindowController refreshDriverAndScanState];
    [self refreshSidePanelLiveChannels];
    [self refreshMetadataUI];
}

- (void)closeBonDriver:(id)sender {
    (void)sender;
    if (!_liveSession) {
        return;
    }
    NSString *name = _liveSession.tunerName;
    [_liveSession closeTuner];
    _liveSession = nil;
    [_plugin closeLiveStream];
    _currentSnapshot = nil;
    _currentStats = nil;
    _activeServiceID = 0;
    _captionOverlay.currentCue = nil;
    _window.title = @"TVTest";
    _statusLeft.stringValue = @"⌘O で録画を開く / ⇧⌘O で MacBonDriver を開く";
    _statusSignalBtn.title = @"LibISDB 待機中";
    _statusRecBtn.hidden = YES;
    _statusCasBtn.hidden = YES;
    [self refreshSidePanelLiveChannels];
    [_osdOverlay showMessage:@"ドライバを閉じました" subtitle:name];
}

- (void)selectTunerChannel:(NSMenuItem *)sender {
    TVTestTunerChannel *ch = sender.representedObject;
    if (!_liveSession || !ch) {
        return;
    }
    NSError *err = nil;
    if (![_liveSession tuneToSpace:ch.spaceIndex channel:ch.channelIndex streamID:ch.streamID error:&err]) {
        [self showError:err.localizedDescription ?: @"選局に失敗しました。"];
        return;
    }
    _activeServiceID = 0;
    _captionOverlay.currentCue = nil;
    [_plugin openLiveStreamWithServiceID:0 error:NULL];
    [self refreshSidePanelLiveChannels];
    [_osdOverlay showMessage:ch.name
                    subtitle:(ch.frequencyKHz > 0 ? [NSString stringWithFormat:@"%.1f MHz", (double)ch.frequencyKHz / 1000.0] : nil)];
}

- (void)selectLNBPower:(NSMenuItem *)sender {
    if (!_liveSession) return;
    NSError *err = nil;
    if ([_liveSession setLNBPowerMode:(MBDLNBPowerMode)sender.tag error:&err]) {
        [_osdOverlay showMessage:[NSString stringWithFormat:@"LNB 電源: %@", sender.title] subtitle:nil];
    } else {
        [self showError:err.localizedDescription ?: @"LNB 電源を設定できませんでした。"];
    }
}

- (void)showSmartCardStatus:(id)sender {
    (void)sender;
    if (!_liveSession) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"内蔵スマートカード情報";
    alert.informativeText = [_liveSession querySmartCardStatusSummary];
    [alert beginSheetModalForWindow:_window completionHandler:nil];
}

- (void)toggleLiveRecording:(id)sender {
    (void)sender;
    if (!_liveSession) {
        return;
    }
    if (_liveSession.isRecording) {
        NSURL *recURL = _liveSession.recordingURL;
        [_liveSession stopRecording];
        [_osdOverlay showMessage:@"録画を停止しました" subtitle:recURL.lastPathComponent];
        [self refreshMetadataUI];
        return;
    }

    TVTestSettings *s = TVTestSettings.sharedSettings;
    TVTestServiceInfo *active = [_currentSnapshot serviceWithID:_activeServiceID];
    NSString *stem = [s expandFilenamePattern:s.recordingFilenamePattern
                                  serviceName:active.name ?: _liveSession.tunerName
                                    eventName:active.currentProgram.title];
    NSURL *outURL = [[[NSURL fileURLWithPath:s.recordingDirectory]
                      URLByAppendingPathComponent:stem]
                     URLByAppendingPathExtension:@"ts"];
    NSError *err = nil;
    uint16_t recServiceID = s.recordCurrentServiceOnly ? _activeServiceID : 0;
    if ([_liveSession startRecordingToURL:outURL serviceID:recServiceID error:&err]) {
        [_osdOverlay showMessage:@"● 録画を開始しました" subtitle:outURL.lastPathComponent];
        [self refreshMetadataUI];
    } else {
        [self showError:err.localizedDescription ?: @"録画を開始できませんでした。"];
    }
}

#pragma mark - TVTestLiveTunerSessionDelegate

- (void)liveTunerSession:(TVTestLiveTunerSession *)session
       didReceiveTSBytes:(const uint8_t *)bytes
                  length:(NSUInteger)length {
    (void)session;
    [_plugin pushLiveTSBytes:bytes length:length];
}

- (void)liveTunerSession:(TVTestLiveTunerSession *)session
       didUpdateSnapshot:(TVTestRecordingSnapshot *)snapshot
             signalLevel:(float)cnrDB
                  locked:(BOOL)locked
             bitrateMbps:(double)bitrateMbps
                   stats:(TVTestStreamStats *)stats {
    (void)bitrateMbps;
    if (session != _liveSession) return;
    _liveSignalCNR = cnrDB;
    _liveSignalLocked = locked;
    _currentSnapshot = snapshot;
    _currentStats = stats;
    if (_activeServiceID == 0 && snapshot.services.count > 0) {
        TVTestServiceInfo *preferred = nil;
        for (TVTestServiceInfo *svc in snapshot.services) {
            if (svc.videoESCount > 0) {
                preferred = svc;
                break;
            }
        }
        if (!preferred) {
            preferred = snapshot.services.firstObject;
        }
        _activeServiceID = preferred.serviceID;
        [_liveSession setActiveServiceID:_activeServiceID];
        [_plugin openLiveStreamWithServiceID:_activeServiceID error:NULL];
    }
    [self refreshMetadataUI];
}

- (void)liveTunerSession:(TVTestLiveTunerSession *)session
       didReceiveCaption:(TVTestCaptionCue *)cue
            languageTags:(NSArray<NSNumber *> *)languageTags {
    if (session != _liveSession) return;
    _availableCaptionLanguages = languageTags;
    if (languageTags.count > 0 && ![languageTags containsObject:@(_selectedCaptionLanguage)]) {
        _selectedCaptionLanguage = (uint8_t)languageTags.firstObject.unsignedIntValue;
    }
    if (cue.languageTag == _selectedCaptionLanguage) {
        _captionOverlay.currentCue = cue.text.length ? cue : nil;
    }
    [_sidePanelController updateCaptions:[session allCaptionCuesForLanguageTag:_selectedCaptionLanguage]];
}

- (void)liveTunerSession:(TVTestLiveTunerSession *)session
            didUpdateEPG:(NSArray<TVTestEPGServiceEntry *> *)epgServices {
    if (session != _liveSession) return;
    NSArray<TVTestEPGServiceEntry *> *effective = epgServices.count ? epgServices : _persistedEPGServices;
    [_guideWindowController updateWithEPGServices:effective preferredServiceID:_activeServiceID finished:NO];
    [_searchWindowController updateWithEPGServices:effective];
    [_sidePanelController updateEPGServices:effective activeServiceID:_activeServiceID];
}

- (void)liveTunerSession:(TVTestLiveTunerSession *)session
         didReceiveEvent:(MBDEventType)event
                 message:(NSString *)message {
    (void)event;
    if (session != _liveSession) return;
    [_osdOverlay showMessage:session.tunerName subtitle:message];
}

#pragma mark - Auxiliary Windows

- (void)showRecordingInfo:(id)sender {
    (void)sender;
    if (!_infoWindowController) {
        _infoWindowController = [[TVTestProgramInfoWindowController alloc] init];
    }
    [_infoWindowController updateWithSnapshot:_currentSnapshot
                              activeServiceID:_activeServiceID
                                recordingName:_recording.lastPathComponent];
    [_infoWindowController showWindow:nil];
}

- (void)showProgramGuide:(id)sender {
    (void)sender;
    if (!_guideWindowController) {
        _guideWindowController = [[TVTestProgramGuideWindowController alloc] init];
        _guideWindowController.delegate = self;
    }
    NSArray<TVTestEPGServiceEntry *> *epg = _liveSession
        ? [_liveSession currentEPGServices]
        : [_session currentEPGServices];
    if (epg.count == 0) {
        epg = _persistedEPGServices;
    }
    [_guideWindowController updateWithEPGServices:epg
                               preferredServiceID:_activeServiceID
                                         finished:(_liveSession ? NO : (_session ? _epgScanFinished : YES))];
    [_guideWindowController showWindow:nil];
}

#pragma mark - TVTestProgramGuideDelegate

- (void)programGuideDidRequestTuneServiceID:(uint16_t)serviceID {
    if (_liveSession) {
        NSArray<NSDictionary<NSString *, id> *> *scanned =
            [TVTestSettings.sharedSettings loadScannedChannelsForDriverIdentifier:_liveSession.driverIdentifier];
        for (NSDictionary<NSString *, id> *entry in scanned) {
            if ([entry[@"serviceID"] unsignedShortValue] == serviceID) {
                [self tuneScannedChannelEntry:entry];
                return;
            }
        }
    }
    [self switchToServiceID:serviceID];
}

- (void)programGuideDidRequestAcquireEPG {
    if (!_liveSession) {
        [self showError:@"EPG 取得には MacBonDriver への接続が必要です。"];
        return;
    }
    if (_epgAcquiring) {
        [_liveSession cancelEPGAcquisition];
        [_guideWindowController setEPGAcquisitionStatus:@"EPG 取得を中止しています…" acquiring:YES];
        return;
    }
    NSArray<NSDictionary<NSString *, id> *> *scanned =
        [TVTestSettings.sharedSettings loadScannedChannelsForDriverIdentifier:_liveSession.driverIdentifier];
    if (scanned.count == 0) {
        [self showError:@"先にチャンネルスキャンを実行してください。"];
        return;
    }
    _epgAcquiring = YES;
    [_guideWindowController setEPGAcquisitionStatus:@"EPG 取得を開始しています…" acquiring:YES];
    [_osdOverlay showMessage:@"EPG 取得開始" subtitle:@"各チャンネルを巡回して番組表を取得します"];

    __weak TVTestApp *weakSelf = self;
    [_liveSession acquireEPGForScannedChannels:scanned
                                  dwellSeconds:6.0
                                    onProgress:^(NSUInteger completed, NSUInteger total, NSString *channelName) {
        TVTestApp *s = weakSelf;
        if (!s) return;
        NSString *msg = [NSString stringWithFormat:@"EPG 取得中 (%lu / %lu): %@",
                         (unsigned long)completed, (unsigned long)total, channelName];
        [s->_guideWindowController setEPGAcquisitionStatus:msg acquiring:YES];
        [s->_osdOverlay showMessage:@"EPG 取得中" subtitle:msg];
    }
                                    completion:^(BOOL cancelled) {
        TVTestApp *s = weakSelf;
        if (!s) return;
        s->_epgAcquiring = NO;
        NSString *doneMsg = cancelled ? @"EPG 取得を中止しました" : @"EPG 取得が完了しました";
        [s->_guideWindowController setEPGAcquisitionStatus:doneMsg acquiring:NO];
        [s->_osdOverlay showMessage:doneMsg subtitle:nil];
        if (s->_liveSession) {
            [s->_plugin openLiveStreamWithServiceID:s->_activeServiceID error:NULL];
            NSArray<TVTestEPGServiceEntry *> *epg = [s->_liveSession currentEPGServices];
            [s->_guideWindowController updateWithEPGServices:epg preferredServiceID:s->_activeServiceID finished:YES];
        }
    }];
}

- (void)showProgramSearch:(id)sender {
    (void)sender;
    if (!_searchWindowController) {
        _searchWindowController = [[TVTestProgramSearchWindowController alloc] init];
    }
    NSArray<TVTestEPGServiceEntry *> *epg = _liveSession
        ? [_liveSession currentEPGServices]
        : [_session currentEPGServices];
    if (epg.count == 0) {
        epg = _persistedEPGServices;
    }
    [_searchWindowController updateWithEPGServices:epg];
    [_searchWindowController showWindow:nil];
}

- (void)showStreamInfo:(id)sender {
    (void)sender;
    if (!_streamInfoWindowController) {
        _streamInfoWindowController = [[TVTestStreamInfoWindowController alloc] init];
    }
    [_streamInfoWindowController updateWithSnapshot:_currentSnapshot stats:_currentStats];
    [_streamInfoWindowController showWindow:nil];
}

- (void)tuneScannedChannelEntry:(NSDictionary<NSString *, id> *)entry {
    if (!_liveSession || !entry) return;
    NSUInteger sp = [entry[@"space"] unsignedIntegerValue];
    NSUInteger ch = [entry[@"channel"] unsignedIntegerValue];
    uint16_t streamID = [entry[@"streamID"] unsignedShortValue];
    uint16_t sid = [entry[@"serviceID"] unsignedShortValue];
    NSError *err = nil;
    if (![_liveSession tuneToSpace:sp channel:ch streamID:streamID error:&err]) {
        [self showError:err.localizedDescription ?: @"選局に失敗しました。"];
        return;
    }
    _activeServiceID = sid;
    TVTestSettings.sharedSettings.lastTunedChannelEntry = entry;
    [_liveSession setActiveServiceID:sid];
    [_plugin openLiveStreamWithServiceID:sid error:NULL];
    _captionOverlay.currentCue = nil;
    [self refreshSidePanelLiveChannels];
    [_osdOverlay showMessage:(entry[@"name"] ?: entry[@"channelName"] ?: @"選局")
                    subtitle:entry[@"channelName"]];
}

- (void)selectScannedChannel:(NSMenuItem *)sender {
    [self tuneScannedChannelEntry:sender.representedObject];
}

- (void)showChannelScan:(id)sender {
    (void)sender;
    if (!_preferencesWindowController) {
        _preferencesWindowController = [[TVTestPreferencesWindowController alloc] init];
        _preferencesWindowController.delegate = self;
    }
    [_preferencesWindowController selectCategoryIndex:5];
    [_preferencesWindowController showWindow:nil];
}

#pragma mark - TVTestPreferencesDelegate

- (nullable TVTestLiveTunerSession *)preferencesCurrentLiveSession {
    return _liveSession;
}

- (void)preferencesDidRequestOpenBonDriverAtURL:(NSURL *)bundleURL {
    [self openBonDriverAtURL:bundleURL];
}

- (void)preferencesDidSaveScannedChannels:(NSArray<NSDictionary<NSString *, id> *> *)channels
                      forDriverIdentifier:(NSString *)driverIdentifier {
    (void)driverIdentifier;
    [self refreshSidePanelLiveChannels];
    [_osdOverlay showMessage:@"チャンネルスキャン結果を保存しました"
                    subtitle:[NSString stringWithFormat:@"%lu チャンネル", (unsigned long)channels.count]];
}

- (void)showPreferences:(id)sender {
    (void)sender;
    if (!_preferencesWindowController) {
        _preferencesWindowController = [[TVTestPreferencesWindowController alloc] init];
        _preferencesWindowController.delegate = self;
    }
    [_preferencesWindowController refreshDriverAndScanState];
    [_preferencesWindowController showWindow:nil];
}

- (void)showError:(NSString *)message {
    NSLog(@"TVTest: %@", message);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"TVTest";
    alert.informativeText = message;
    [alert beginSheetModalForWindow:_window completionHandler:nil];
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        __attribute__((objc_precise_lifetime)) TVTestApp *delegate = [[TVTestApp alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        if (argc == 2) {
            NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:argv[1]
                                                                                         length:strlen(argv[1])];
            [delegate application:app openURLs:@[[NSURL fileURLWithPath:path]]];
        }
        [app run];
    }
    return 0;
}
