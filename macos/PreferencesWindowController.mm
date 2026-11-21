// SPDX-License-Identifier: GPL-2.0-or-later
#import "PreferencesWindowController.h"
#import "TVTestSettings.h"
#import "TVTestPlaybackPlugin.h"
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TVTestPreferencesWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation TVTestPreferencesWindowController {
    NSTableView *_sidebarTable;
    NSTabView *_pageTabs;
    NSArray<NSString *> *_categoryNames;

    // 0: General
    NSPopUpButton *_startupModePopup;
    NSTextField *_captureDirField;
    NSTextField *_capturePatternField;
    NSTextField *_capturePreviewLabel;

    // 1: View
    NSButton *_osdCheck;
    NSButton *_topMostCheck;
    NSButton *_panelLeftCheck;
    NSButton *_statusBarCheck;
    NSButton *_controlsHiddenCheck;

    // 2: Video
    NSPopUpButton *_aspectPopup;
    NSPopUpButton *_cropPopup;
    NSPopUpButton *_deinterlacePopup;

    // 3: Audio
    NSSlider *_volumeSlider;
    NSTextField *_volumeValueLabel;
    NSPopUpButton *_audioChannelPopup;

    // 4: Driver (MacBonDriver / SQR100)
    NSTableView *_driverTable;
    NSArray<TVTestBonDriverInfo *> *_discoveredDrivers;
    NSTextField *_bonDriverDirField;
    NSTextField *_deviceIndexField;
    NSTextField *_customConfigField;
    NSTextField *_customFirmwareField;
    NSPopUpButton *_lnbPopup;
    NSButton *_autoTuneCheck;
    NSButton *_openSelectedDriverBtn;
    NSButton *_smartCardCheckBtn;
    NSTextField *_driverStatusLabel;

    // 5: Channel Scan
    NSTextField *_scanDriverLabel;
    NSPopUpButton *_scanSpacePopup;
    NSPopUpButton *_scanDwellPopup;
    NSButton *_scanStartStopBtn;
    NSButton *_scanSaveBtn;
    NSProgressIndicator *_scanProgress;
    NSTextField *_scanStatusLabel;
    NSTableView *_scanResultTable;
    NSMutableArray<TVTestChannelScanResult *> *_scanResults;
    BOOL _scanning;

    // 6: Record
    NSTextField *_recordDirField;
    NSTextField *_recordPatternField;
    NSTextField *_recordPreviewLabel;
    NSButton *_recordCurrentServiceCheck;

    // 7: Captions
    NSButton *_captionsDefaultCheck;
    NSSlider *_captionFontSlider;
    NSTextField *_captionFontValueLabel;
    NSSlider *_captionAlphaSlider;
    NSTextField *_captionAlphaValueLabel;
    NSView *_captionPreviewBox;
    NSTextField *_captionPreviewText;

    // 8: EPG
    NSButton *_saveEPGCheck;
    NSPopUpButton *_epgViewModePopup;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 780, 520)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"TVTest 設定";
    window.minSize = NSMakeSize(680, 460);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _categoryNames = @[
            @"一般",
            @"表示",
            @"映像",
            @"音声",
            @"ドライバ",
            @"チャンネルスキャン",
            @"録画",
            @"ARIB 字幕",
            @"EPG / 番組表",
        ];
        _discoveredDrivers = @[];
        _scanResults = [NSMutableArray array];
        [self buildUI];
        [self loadFromSettings];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    NSScrollView *sideScroll = [[NSScrollView alloc] init];
    sideScroll.hasVerticalScroller = YES;
    sideScroll.borderType = NSBezelBorder;
    sideScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:sideScroll];

    _sidebarTable = [[NSTableView alloc] init];
    _sidebarTable.headerView = nil;
    _sidebarTable.rowHeight = 28.0;
    _sidebarTable.dataSource = self;
    _sidebarTable.delegate = self;
    NSTableColumn *catCol = [[NSTableColumn alloc] initWithIdentifier:@"cat"];
    catCol.width = 156;
    [_sidebarTable addTableColumn:catCol];
    sideScroll.documentView = _sidebarTable;

    _pageTabs = [[NSTabView alloc] init];
    _pageTabs.tabViewType = NSNoTabsNoBorder;
    _pageTabs.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_pageTabs];

    [self buildGeneralPage];
    [self buildViewPage];
    [self buildVideoPage];
    [self buildAudioPage];
    [self buildDriverPage];
    [self buildChannelScanPage];
    [self buildRecordPage];
    [self buildCaptionPage];
    [self buildEPGPage];

    [NSLayoutConstraint activateConstraints:@[
        [sideScroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [sideScroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [sideScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [sideScroll.widthAnchor constraintEqualToConstant:168],
        [_pageTabs.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [_pageTabs.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [_pageTabs.leadingAnchor constraintEqualToAnchor:sideScroll.trailingAnchor constant:14],
        [_pageTabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
    ]];

    [_sidebarTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

- (void)selectCategoryIndex:(NSInteger)index {
    NSInteger clamped = MAX((NSInteger)0, MIN((NSInteger)_categoryNames.count - 1, index));
    [_sidebarTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)clamped] byExtendingSelection:NO];
    [_pageTabs selectTabViewItemAtIndex:clamped];
    if (clamped == 4 || clamped == 5) {
        [self refreshDriverAndScanState];
    }
}

#pragma mark - Pages

- (void)buildGeneralPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    NSView *v = [[NSView alloc] init];

    _startupModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_startupModePopup addItemsWithTitles:@[
        @"起動時にドライバを開かない",
        @"前回終了時の MacBonDriver を自動で開く",
        @"「ドライバ」タブで指定したドライバを開く",
    ]];
    _startupModePopup.target = self;
    _startupModePopup.action = @selector(applySettings:);

    _captureDirField = [[NSTextField alloc] init];
    _captureDirField.target = self;
    _captureDirField.action = @selector(applySettings:);
    NSButton *browseCap = [NSButton buttonWithTitle:@"選択…" target:self action:@selector(chooseCaptureDir:)];

    _capturePatternField = [[NSTextField alloc] init];
    _capturePatternField.target = self;
    _capturePatternField.action = @selector(applySettings:);

    _capturePreviewLabel = [NSTextField labelWithString:@""];
    _capturePreviewLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    _capturePreviewLabel.textColor = NSColor.secondaryLabelColor;

    NSButton *clearRecent = [NSButton buttonWithTitle:@"最近開いた録画の履歴を消去"
                                               target:self action:@selector(clearRecent:)];

    NSStackView *capRow = [NSStackView stackViewWithViews:@[_captureDirField, browseCap]];
    capRow.spacing = 8;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"起動時のドライバ:"], _startupModePopup],
        @[[NSTextField labelWithString:@"キャプチャ保存先:"], capRow],
        @[[NSTextField labelWithString:@"キャプチャ書式:"], _capturePatternField],
        @[[NSTextField labelWithString:@"ファイル名例:"], _capturePreviewLabel],
    ]];
    grid.rowSpacing = 12;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    clearRecent.translatesAutoresizingMaskIntoConstraints = NO;

    [v addSubview:grid];
    [v addSubview:clearRecent];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:12],
        [grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [grid.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_captureDirField.widthAnchor constraintGreaterThanOrEqualToConstant:280],
        [_capturePatternField.widthAnchor constraintGreaterThanOrEqualToConstant:340],
        [clearRecent.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:20],
        [clearRecent.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:12],
    ]];

    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildViewPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"view"];
    NSView *v = [[NSView alloc] init];

    _osdCheck = [NSButton checkboxWithTitle:@"OSD（チャンネル・音量・操作通知）を表示する"
                                     target:self action:@selector(applySettings:)];
    _topMostCheck = [NSButton checkboxWithTitle:@"常に最前面に表示する"
                                         target:self action:@selector(applySettings:)];
    _panelLeftCheck = [NSButton checkboxWithTitle:@"サイドパネルを左側に配置する"
                                           target:self action:@selector(applySettings:)];
    _statusBarCheck = [NSButton checkboxWithTitle:@"ステータスバーを表示する"
                                           target:self action:@selector(applySettings:)];
    _controlsHiddenCheck = [NSButton checkboxWithTitle:@"再生コントロールバーを隠す（ミニマル表示）"
                                                target:self action:@selector(applySettings:)];

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        _osdCheck, _topMostCheck, _panelLeftCheck, _statusBarCheck, _controlsHiddenCheck
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    ]];
    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildVideoPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"video"];
    NSView *v = [[NSView alloc] init];

    _aspectPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_aspectPopup addItemsWithTitles:@[@"自動", @"16:9", @"4:3", @"2.35:1"]];
    _aspectPopup.target = self;
    _aspectPopup.action = @selector(applySettings:);

    _cropPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_cropPopup addItemsWithTitles:@[@"なし", @"16:9", @"4:3", @"16:10", @"2.35:1"]];
    _cropPopup.target = self;
    _cropPopup.action = @selector(applySettings:);

    _deinterlacePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_deinterlacePopup addItemsWithTitles:@[@"OFF", @"Blend", @"Bob", @"Linear", @"Yadif", @"Yadif 2x"]];
    _deinterlacePopup.target = self;
    _deinterlacePopup.action = @selector(applySettings:);

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"デフォルトアスペクト比:"], _aspectPopup],
        @[[NSTextField labelWithString:@"パン＆スキャン（クロップ）:"], _cropPopup],
        @[[NSTextField labelWithString:@"インターレース解除:"], _deinterlacePopup],
    ]];
    grid.rowSpacing = 12;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:grid];

    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [grid.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor],
    ]];
    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildAudioPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"audio"];
    NSView *v = [[NSView alloc] init];

    _volumeSlider = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:@selector(applySettings:)];
    _volumeValueLabel = [NSTextField labelWithString:@"100%"];
    _volumeValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular];

    _audioChannelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_audioChannelPopup addItemsWithTitles:@[@"ステレオ", @"反転ステレオ", @"主音声 (左)", @"副音声 (右)"]];
    _audioChannelPopup.target = self;
    _audioChannelPopup.action = @selector(applySettings:);

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"デフォルト音量:"], _volumeSlider, _volumeValueLabel],
        @[[NSTextField labelWithString:@"音声チャンネルモード:"], _audioChannelPopup, [NSView new]],
    ]];
    grid.rowSpacing = 14;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:grid];

    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_volumeSlider.widthAnchor constraintEqualToConstant:220],
    ]];
    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildDriverPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"driver"];
    NSView *v = [[NSView alloc] init];

    NSTextField *title = [NSTextField labelWithString:@"検出された MacBonDriver (.bundle) — デフォルト選択:"];
    title.font = [NSFont boldSystemFontOfSize:12.0];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:title];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:scroll];

    _driverTable = [[NSTableView alloc] init];
    _driverTable.usesAlternatingRowBackgroundColors = YES;
    _driverTable.dataSource = self;
    _driverTable.delegate = self;

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"drvName"];
    nameCol.title = @"ドライバ名";
    nameCol.width = 240;
    [_driverTable addTableColumn:nameCol];

    NSTableColumn *sysCol = [[NSTableColumn alloc] initWithIdentifier:@"drvSys"];
    sysCol.title = @"放送方式";
    sysCol.width = 140;
    [_driverTable addTableColumn:sysCol];

    NSTableColumn *pathCol = [[NSTableColumn alloc] initWithIdentifier:@"drvPath"];
    pathCol.title = @"バンドル";
    pathCol.width = 160;
    pathCol.resizingMask = NSTableColumnAutoresizingMask;
    [_driverTable addTableColumn:pathCol];
    scroll.documentView = _driverTable;

    _openSelectedDriverBtn = [NSButton buttonWithTitle:@"選択したドライバを今すぐ開く"
                                                target:self action:@selector(openSelectedDriverNow:)];
    NSButton *rescanDriversBtn = [NSButton buttonWithTitle:@"再検出"
                                                    target:self action:@selector(refreshDriverAndScanState)];
    _smartCardCheckBtn = [NSButton buttonWithTitle:@"スマートカード確認"
                                            target:self action:@selector(checkSmartCardInPrefs:)];
    NSStackView *actionRow = [NSStackView stackViewWithViews:@[_openSelectedDriverBtn, rescanDriversBtn, _smartCardCheckBtn]];
    actionRow.spacing = 8;
    actionRow.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:actionRow];

    _bonDriverDirField = [[NSTextField alloc] init];
    _bonDriverDirField.target = self;
    _bonDriverDirField.action = @selector(applySettings:);
    NSButton *browseBon = [NSButton buttonWithTitle:@"選択…" target:self action:@selector(chooseBonDriverDir:)];
    NSStackView *bonRow = [NSStackView stackViewWithViews:@[_bonDriverDirField, browseBon]];
    bonRow.spacing = 6;

    _deviceIndexField = [[NSTextField alloc] init];
    _deviceIndexField.target = self;
    _deviceIndexField.action = @selector(applySettings:);

    _customConfigField = [[NSTextField alloc] init];
    _customConfigField.placeholderString = @"空欄でバンドル同梱の .ChSet.plist を使用";
    _customConfigField.target = self;
    _customConfigField.action = @selector(applySettings:);
    NSButton *browseCfg = [NSButton buttonWithTitle:@"選択…" target:self action:@selector(chooseCustomConfig:)];
    NSStackView *cfgRow = [NSStackView stackViewWithViews:@[_customConfigField, browseCfg]];
    cfgRow.spacing = 6;

    _customFirmwareField = [[NSTextField alloc] init];
    _customFirmwareField.placeholderString = @"空欄でバンドル同梱ファームウェアを使用";
    _customFirmwareField.target = self;
    _customFirmwareField.action = @selector(applySettings:);
    NSButton *browseFw = [NSButton buttonWithTitle:@"選択…" target:self action:@selector(chooseCustomFirmwareDir:)];
    NSStackView *fwRow = [NSStackView stackViewWithViews:@[_customFirmwareField, browseFw]];
    fwRow.spacing = 6;

    _lnbPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_lnbPopup addItemsWithTitles:@[@"OFF", @"15V", @"11V", @"自動"]];
    _lnbPopup.target = self;
    _lnbPopup.action = @selector(applySettings:);

    _autoTuneCheck = [NSButton checkboxWithTitle:@"ドライバ接続時に最初のチャンネルを自動選局する"
                                          target:self action:@selector(applySettings:)];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"ドライバフォルダ:"], bonRow],
        @[[NSTextField labelWithString:@"デバイス番号:"], _deviceIndexField],
        @[[NSTextField labelWithString:@"チャンネル定義:"], cfgRow],
        @[[NSTextField labelWithString:@"ファームウェア:"], fwRow],
        @[[NSTextField labelWithString:@"LNB 給電:"], _lnbPopup],
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 8;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    _autoTuneCheck.translatesAutoresizingMaskIntoConstraints = NO;

    _driverStatusLabel = [NSTextField labelWithString:@""];
    _driverStatusLabel.font = [NSFont systemFontOfSize:11.0];
    _driverStatusLabel.textColor = NSColor.secondaryLabelColor;
    _driverStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [v addSubview:grid];
    [v addSubview:_autoTuneCheck];
    [v addSubview:_driverStatusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [scroll.heightAnchor constraintEqualToConstant:110],
        [actionRow.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:8],
        [actionRow.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [grid.topAnchor constraintEqualToAnchor:actionRow.bottomAnchor constant:12],
        [grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [grid.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_bonDriverDirField.widthAnchor constraintGreaterThanOrEqualToConstant:280],
        [_deviceIndexField.widthAnchor constraintEqualToConstant:64],
        [_customConfigField.widthAnchor constraintGreaterThanOrEqualToConstant:280],
        [_customFirmwareField.widthAnchor constraintGreaterThanOrEqualToConstant:280],
        [_autoTuneCheck.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:10],
        [_autoTuneCheck.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4],
        [_driverStatusLabel.topAnchor constraintEqualToAnchor:_autoTuneCheck.bottomAnchor constant:6],
        [_driverStatusLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4],
        [_driverStatusLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    ]];

    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildChannelScanPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"scan"];
    NSView *v = [[NSView alloc] init];

    _scanDriverLabel = [NSTextField labelWithString:@"接続中ドライバ: なし"];
    _scanDriverLabel.font = [NSFont boldSystemFontOfSize:12.5];
    _scanDriverLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_scanDriverLabel];

    _scanSpacePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _scanSpacePopup.translatesAutoresizingMaskIntoConstraints = NO;

    _scanDwellPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_scanDwellPopup addItemsWithTitles:@[@"高速 (0.8秒/ch)", @"標準 (1.5秒/ch)", @"精密 (3.0秒/ch)"]];
    [_scanDwellPopup selectItemAtIndex:1];
    _scanDwellPopup.translatesAutoresizingMaskIntoConstraints = NO;

    _scanStartStopBtn = [NSButton buttonWithTitle:@"スキャン開始" target:self action:@selector(toggleChannelScan:)];
    _scanSaveBtn = [NSButton buttonWithTitle:@"結果を保存" target:self action:@selector(saveChannelScanResults:)];
    _scanSaveBtn.enabled = NO;

    NSStackView *ctrlRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"空間:"], _scanSpacePopup, _scanDwellPopup, _scanStartStopBtn, _scanSaveBtn
    ]];
    ctrlRow.spacing = 8;
    ctrlRow.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:ctrlRow];

    _scanProgress = [[NSProgressIndicator alloc] init];
    _scanProgress.indeterminate = NO;
    _scanProgress.minValue = 0;
    _scanProgress.maxValue = 100;
    _scanProgress.style = NSProgressIndicatorStyleBar;
    _scanProgress.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_scanProgress];

    _scanStatusLabel = [NSTextField labelWithString:@"「スキャン開始」で現在接続中の MacBonDriver のチャンネルを走査します。"];
    _scanStatusLabel.font = [NSFont systemFontOfSize:11.5];
    _scanStatusLabel.textColor = NSColor.secondaryLabelColor;
    _scanStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_scanStatusLabel];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:scroll];

    _scanResultTable = [[NSTableView alloc] init];
    _scanResultTable.usesAlternatingRowBackgroundColors = YES;
    _scanResultTable.dataSource = self;
    _scanResultTable.delegate = self;

    NSArray<NSArray *> *cols = @[
        @[@"scanCh", @"物理CH", @140],
        @[@"scanFreq", @"周波数", @90],
        @[@"scanLock", @"状態", @64],
        @[@"scanCNR", @"CNR", @68],
        @[@"scanSvcs", @"検出サービス", @200],
    ];
    for (NSArray *spec in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        col.title = spec[1];
        col.width = [spec[2] doubleValue];
        if ([spec[0] isEqualToString:@"scanSvcs"]) col.resizingMask = NSTableColumnAutoresizingMask;
        [_scanResultTable addTableColumn:col];
    }
    scroll.documentView = _scanResultTable;

    [NSLayoutConstraint activateConstraints:@[
        [_scanDriverLabel.topAnchor constraintEqualToAnchor:v.topAnchor constant:8],
        [_scanDriverLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [ctrlRow.topAnchor constraintEqualToAnchor:_scanDriverLabel.bottomAnchor constant:10],
        [ctrlRow.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [ctrlRow.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor],
        [_scanProgress.topAnchor constraintEqualToAnchor:ctrlRow.bottomAnchor constant:10],
        [_scanProgress.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_scanProgress.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_scanStatusLabel.topAnchor constraintEqualToAnchor:_scanProgress.bottomAnchor constant:4],
        [_scanStatusLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_scanStatusLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_scanStatusLabel.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
    ]];

    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildRecordPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"record"];
    NSView *v = [[NSView alloc] init];

    _recordDirField = [[NSTextField alloc] init];
    _recordDirField.target = self;
    _recordDirField.action = @selector(applySettings:);
    NSButton *browseRec = [NSButton buttonWithTitle:@"選択…" target:self action:@selector(chooseRecordDir:)];
    NSStackView *recRow = [NSStackView stackViewWithViews:@[_recordDirField, browseRec]];
    recRow.spacing = 8;

    _recordPatternField = [[NSTextField alloc] init];
    _recordPatternField.target = self;
    _recordPatternField.action = @selector(applySettings:);

    _recordPreviewLabel = [NSTextField labelWithString:@""];
    _recordPreviewLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    _recordPreviewLabel.textColor = NSColor.secondaryLabelColor;

    _recordCurrentServiceCheck = [NSButton checkboxWithTitle:@"現在のサービスのみを録画する（LibISDB ServiceSelectorFilter）"
                                                      target:self action:@selector(applySettings:)];

    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"利用可能な変数: %date%, %time%, %year%, %month%, %day%, %service-name%, %event-name%"];
    hint.font = [NSFont systemFontOfSize:11.0];
    hint.textColor = NSColor.secondaryLabelColor;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"録画保存先:"], recRow],
        @[[NSTextField labelWithString:@"ファイル名書式:"], _recordPatternField],
        @[[NSTextField labelWithString:@"ファイル名例:"], _recordPreviewLabel],
    ]];
    grid.rowSpacing = 12;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    _recordCurrentServiceCheck.translatesAutoresizingMaskIntoConstraints = NO;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    [v addSubview:grid];
    [v addSubview:_recordCurrentServiceCheck];
    [v addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [grid.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [grid.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_recordDirField.widthAnchor constraintGreaterThanOrEqualToConstant:280],
        [_recordPatternField.widthAnchor constraintGreaterThanOrEqualToConstant:340],
        [_recordCurrentServiceCheck.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:16],
        [_recordCurrentServiceCheck.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
        [hint.topAnchor constraintEqualToAnchor:_recordCurrentServiceCheck.bottomAnchor constant:12],
        [hint.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
        [hint.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    ]];

    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildCaptionPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"caption"];
    NSView *v = [[NSView alloc] init];

    _captionsDefaultCheck = [NSButton checkboxWithTitle:@"ARIB 字幕を表示する"
                                                 target:self action:@selector(applySettings:)];
    _captionFontSlider = [NSSlider sliderWithValue:22.0 minValue:14.0 maxValue:40.0
                                            target:self action:@selector(applySettings:)];
    _captionFontValueLabel = [NSTextField labelWithString:@"22 pt"];
    _captionFontValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular];

    _captionAlphaSlider = [NSSlider sliderWithValue:0.72 minValue:0.0 maxValue:1.0
                                             target:self action:@selector(applySettings:)];
    _captionAlphaValueLabel = [NSTextField labelWithString:@"72%"];
    _captionAlphaValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"フォントサイズ:"], _captionFontSlider, _captionFontValueLabel],
        @[[NSTextField labelWithString:@"背景の不透明度:"], _captionAlphaSlider, _captionAlphaValueLabel],
    ]];
    grid.rowSpacing = 12;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    _captionPreviewBox = [[NSView alloc] init];
    _captionPreviewBox.wantsLayer = YES;
    _captionPreviewBox.layer.cornerRadius = 8.0;
    _captionPreviewBox.translatesAutoresizingMaskIntoConstraints = NO;

    _captionPreviewText = [NSTextField labelWithString:@"ARIB 字幕プレビュー — ニュース９"];
    _captionPreviewText.textColor = NSColor.whiteColor;
    _captionPreviewText.alignment = NSTextAlignmentCenter;
    _captionPreviewText.translatesAutoresizingMaskIntoConstraints = NO;
    [_captionPreviewBox addSubview:_captionPreviewText];

    NSStackView *stack = [NSStackView stackViewWithViews:@[_captionsDefaultCheck, grid, _captionPreviewBox]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_captionFontSlider.widthAnchor constraintEqualToConstant:240],
        [_captionAlphaSlider.widthAnchor constraintEqualToConstant:240],
        [_captionPreviewBox.widthAnchor constraintGreaterThanOrEqualToConstant:440],
        [_captionPreviewText.topAnchor constraintEqualToAnchor:_captionPreviewBox.topAnchor constant:10],
        [_captionPreviewText.bottomAnchor constraintEqualToAnchor:_captionPreviewBox.bottomAnchor constant:-10],
        [_captionPreviewText.leadingAnchor constraintEqualToAnchor:_captionPreviewBox.leadingAnchor constant:16],
        [_captionPreviewText.trailingAnchor constraintEqualToAnchor:_captionPreviewBox.trailingAnchor constant:-16],
    ]];

    item.view = v;
    [_pageTabs addTabViewItem:item];
}

- (void)buildEPGPage {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"epg"];
    NSView *v = [[NSView alloc] init];

    _saveEPGCheck = [NSButton checkboxWithTitle:@"取得した EPG データを保存する (EPGData.dat)"
                                         target:self action:@selector(applySettings:)];
    _epgViewModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_epgViewModePopup addItemsWithTitles:@[@"タイムテーブル（グリッド）", @"リスト表示"]];
    _epgViewModePopup.target = self;
    _epgViewModePopup.action = @selector(applySettings:);

    NSTextField *pathLabel = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:@"データ保存先: %@", TVTestSettings.sharedSettings.applicationSupportDirectory]];
    pathLabel.font = [NSFont systemFontOfSize:11.0];
    pathLabel.textColor = NSColor.secondaryLabelColor;

    NSButton *clearEPGButton = [NSButton buttonWithTitle:@"EPG キャッシュを削除"
                                                  target:self action:@selector(clearEPGCache:)];

    NSStackView *modeRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"番組表デフォルト表示:"], _epgViewModePopup
    ]];
    modeRow.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[_saveEPGCheck, modeRow, pathLabel, clearEPGButton]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:v.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    ]];

    item.view = v;
    [_pageTabs addTabViewItem:item];
}

#pragma mark - Load / Save

- (void)loadFromSettings {
    TVTestSettings *s = TVTestSettings.sharedSettings;

    [_startupModePopup selectItemAtIndex:(NSInteger)s.startupDriverMode];
    _captureDirField.stringValue = s.captureDirectory;
    _capturePatternField.stringValue = s.captureFilenamePattern;

    _osdCheck.state = s.osdEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _topMostCheck.state = s.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    _panelLeftCheck.state = s.panelOnLeft ? NSControlStateValueOn : NSControlStateValueOff;
    _statusBarCheck.state = s.statusBarVisible ? NSControlStateValueOn : NSControlStateValueOff;
    _controlsHiddenCheck.state = s.controlsHidden ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray<NSString *> *arVals = @[@"", @"16:9", @"4:3", @"235:100"];
    NSUInteger arIdx = [arVals indexOfObject:(s.defaultAspectRatio ?: @"")];
    [_aspectPopup selectItemAtIndex:(arIdx == NSNotFound) ? 0 : (NSInteger)arIdx];

    NSArray<NSString *> *cropVals = @[@"", @"16:9", @"4:3", @"16:10", @"235:100"];
    NSUInteger cropIdx = [cropVals indexOfObject:(s.defaultCropGeometry ?: @"")];
    [_cropPopup selectItemAtIndex:(cropIdx == NSNotFound) ? 0 : (NSInteger)cropIdx];

    NSArray<NSString *> *diVals = @[@"", @"blend", @"bob", @"linear", @"yadif", @"yadif2x"];
    NSUInteger diIdx = [diVals indexOfObject:(s.defaultDeinterlaceMode ?: @"")];
    [_deinterlacePopup selectItemAtIndex:(diIdx == NSNotFound) ? 0 : (NSInteger)diIdx];

    _volumeSlider.integerValue = s.volume;
    _volumeValueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)s.volume];
    [_audioChannelPopup selectItemAtIndex:MAX((NSInteger)0, MIN((NSInteger)3, s.defaultAudioChannelMode - 1))];

    _bonDriverDirField.stringValue = s.bonDriverDirectory;
    _deviceIndexField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)s.bonDriverDeviceIndex];
    _customConfigField.stringValue = s.bonDriverCustomConfigPath ?: @"";
    _customFirmwareField.stringValue = s.bonDriverCustomFirmwareDir ?: @"";
    [_lnbPopup selectItemAtIndex:MAX((NSInteger)0, MIN((NSInteger)3, s.defaultLNBPowerMode))];
    _autoTuneCheck.state = s.autoTuneOnDriverOpen ? NSControlStateValueOn : NSControlStateValueOff;

    _recordDirField.stringValue = s.recordingDirectory;
    _recordPatternField.stringValue = s.recordingFilenamePattern;
    _recordCurrentServiceCheck.state = s.recordCurrentServiceOnly ? NSControlStateValueOn : NSControlStateValueOff;

    _captionsDefaultCheck.state = s.captionsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _captionFontSlider.doubleValue = s.captionFontSize;
    _captionAlphaSlider.doubleValue = s.captionBackgroundAlpha;

    _saveEPGCheck.state = s.saveEPGData ? NSControlStateValueOn : NSControlStateValueOff;
    [_epgViewModePopup selectItemAtIndex:MAX((NSInteger)0, MIN((NSInteger)1, s.epgDefaultViewMode))];

    [self updatePreviews];
    [self refreshDriverAndScanState];
}

- (void)updatePreviews {
    TVTestSettings *s = TVTestSettings.sharedSettings;
    _capturePreviewLabel.stringValue = [[s expandFilenamePattern:_capturePatternField.stringValue
                                                     serviceName:@"NHK総合"
                                                       eventName:@"ニュース9"]
                                        stringByAppendingPathExtension:@"png"];
    _recordPreviewLabel.stringValue = [[s expandFilenamePattern:_recordPatternField.stringValue
                                                    serviceName:@"NHK総合"
                                                      eventName:@"ニュース9"]
                                       stringByAppendingPathExtension:@"ts"];
    _captionFontValueLabel.stringValue = [NSString stringWithFormat:@"%.0f pt", _captionFontSlider.doubleValue];
    _captionAlphaValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", _captionAlphaSlider.doubleValue * 100.0];
    _captionPreviewBox.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:_captionAlphaSlider.doubleValue].CGColor;
    _captionPreviewText.font = [NSFont fontWithName:@"Hiragino Sans W6" size:_captionFontSlider.doubleValue]
        ?: [NSFont boldSystemFontOfSize:_captionFontSlider.doubleValue];
}

- (void)refreshDriverAndScanState {
    TVTestSettings *s = TVTestSettings.sharedSettings;
    _discoveredDrivers = [TVTestLiveTunerSession discoverBonDriversInDirectories:s.bonDriverSearchDirectories];
    [_driverTable reloadData];

    NSInteger defaultRow = -1;
    for (NSUInteger i = 0; i < _discoveredDrivers.count; ++i) {
        if ([_discoveredDrivers[i].bundleURL.path isEqualToString:s.defaultBonDriverPath]) {
            defaultRow = (NSInteger)i;
            break;
        }
    }
    if (defaultRow >= 0) {
        [_driverTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)defaultRow] byExtendingSelection:NO];
    } else if (_discoveredDrivers.count > 0 && _driverTable.selectedRow < 0) {
        [_driverTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }

    TVTestLiveTunerSession *live = [_delegate respondsToSelector:@selector(preferencesCurrentLiveSession)]
        ? [_delegate preferencesCurrentLiveSession] : nil;
    _smartCardCheckBtn.enabled = (live != nil && live.supportsSmartCard);
    _driverStatusLabel.stringValue = live
        ? [NSString stringWithFormat:@"現在接続中: %@ (%lu 空間)", live.tunerName, (unsigned long)live.tuningSpaces.count]
        : [NSString stringWithFormat:@"検出ドライバ: %lu 件（未接続）", (unsigned long)_discoveredDrivers.count];

    [_scanSpacePopup removeAllItems];
    if (live && live.isTunerOpen) {
        _scanDriverLabel.stringValue = [NSString stringWithFormat:@"接続中ドライバ: %@", live.tunerName];
        for (TVTestTunerSpace *sp in live.tuningSpaces) {
            [_scanSpacePopup addItemWithTitle:[NSString stringWithFormat:@"%@ (%lu ch)",
                                               sp.name, (unsigned long)sp.channels.count]];
        }
        _scanStartStopBtn.enabled = (live.tuningSpaces.count > 0);
    } else {
        _scanDriverLabel.stringValue = @"接続中ドライバ: なし（「ドライバ」タブまたはメニューから接続してください）";
        _scanStartStopBtn.enabled = NO;
    }
}

- (void)applySettings:(id)sender {
    (void)sender;
    TVTestSettings *s = TVTestSettings.sharedSettings;
    s.startupDriverMode = (TVTestStartupDriverMode)MAX((NSInteger)0, _startupModePopup.indexOfSelectedItem);
    s.captureDirectory = _captureDirField.stringValue;
    s.captureFilenamePattern = _capturePatternField.stringValue;

    s.osdEnabled = (_osdCheck.state == NSControlStateValueOn);
    s.alwaysOnTop = (_topMostCheck.state == NSControlStateValueOn);
    s.panelOnLeft = (_panelLeftCheck.state == NSControlStateValueOn);
    s.statusBarVisible = (_statusBarCheck.state == NSControlStateValueOn);
    s.controlsHidden = (_controlsHiddenCheck.state == NSControlStateValueOn);

    NSArray<NSString *> *arVals = @[@"", @"16:9", @"4:3", @"235:100"];
    s.defaultAspectRatio = arVals[(NSUInteger)MAX((NSInteger)0, MIN((NSInteger)3, _aspectPopup.indexOfSelectedItem))];

    NSArray<NSString *> *cropVals = @[@"", @"16:9", @"4:3", @"16:10", @"235:100"];
    s.defaultCropGeometry = cropVals[(NSUInteger)MAX((NSInteger)0, MIN((NSInteger)4, _cropPopup.indexOfSelectedItem))];

    NSArray<NSString *> *diVals = @[@"", @"blend", @"bob", @"linear", @"yadif", @"yadif2x"];
    s.defaultDeinterlaceMode = diVals[(NSUInteger)MAX((NSInteger)0, MIN((NSInteger)5, _deinterlacePopup.indexOfSelectedItem))];

    s.volume = _volumeSlider.integerValue;
    _volumeValueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)s.volume];
    s.defaultAudioChannelMode = MAX((NSInteger)0, MIN((NSInteger)3, _audioChannelPopup.indexOfSelectedItem)) + 1;

    s.bonDriverDirectory = _bonDriverDirField.stringValue;
    s.bonDriverDeviceIndex = (NSUInteger)MAX((NSInteger)0, _deviceIndexField.integerValue);
    s.bonDriverCustomConfigPath = _customConfigField.stringValue;
    s.bonDriverCustomFirmwareDir = _customFirmwareField.stringValue;
    s.defaultLNBPowerMode = MAX((NSInteger)0, MIN((NSInteger)3, _lnbPopup.indexOfSelectedItem));
    s.autoTuneOnDriverOpen = (_autoTuneCheck.state == NSControlStateValueOn);

    s.recordingDirectory = _recordDirField.stringValue;
    s.recordingFilenamePattern = _recordPatternField.stringValue;
    s.recordCurrentServiceOnly = (_recordCurrentServiceCheck.state == NSControlStateValueOn);

    s.captionsEnabled = (_captionsDefaultCheck.state == NSControlStateValueOn);
    s.captionFontSize = _captionFontSlider.doubleValue;
    s.captionBackgroundAlpha = _captionAlphaSlider.doubleValue;

    s.saveEPGData = (_saveEPGCheck.state == NSControlStateValueOn);
    s.epgDefaultViewMode = MAX((NSInteger)0, MIN((NSInteger)1, _epgViewModePopup.indexOfSelectedItem));

    [self updatePreviews];
    [s notifyChanged];
}

#pragma mark - Actions

- (void)openSelectedDriverNow:(id)sender {
    (void)sender;
    NSInteger row = _driverTable.selectedRow;
    if (row < 0 || (NSUInteger)row >= _discoveredDrivers.count) return;
    TVTestBonDriverInfo *drv = _discoveredDrivers[(NSUInteger)row];
    TVTestSettings.sharedSettings.defaultBonDriverPath = drv.bundleURL.path;
    if ([_delegate respondsToSelector:@selector(preferencesDidRequestOpenBonDriverAtURL:)]) {
        [_delegate preferencesDidRequestOpenBonDriverAtURL:drv.bundleURL];
    }
    [self refreshDriverAndScanState];
}

- (void)checkSmartCardInPrefs:(id)sender {
    (void)sender;
    TVTestLiveTunerSession *live = [_delegate respondsToSelector:@selector(preferencesCurrentLiveSession)]
        ? [_delegate preferencesCurrentLiveSession] : nil;
    if (!live) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"内蔵スマートカード状態";
    alert.informativeText = [live querySmartCardStatusSummary];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)toggleChannelScan:(id)sender {
    (void)sender;
    TVTestLiveTunerSession *live = [_delegate respondsToSelector:@selector(preferencesCurrentLiveSession)]
        ? [_delegate preferencesCurrentLiveSession] : nil;
    if (!live) return;

    if (_scanning) {
        [live cancelChannelScan];
        _scanStatusLabel.stringValue = @"スキャンを中止しています…";
        return;
    }

    NSInteger spIdx = _scanSpacePopup.indexOfSelectedItem;
    if (spIdx < 0) return;
    double dwell = 1.5;
    if (_scanDwellPopup.indexOfSelectedItem == 0) dwell = 0.8;
    else if (_scanDwellPopup.indexOfSelectedItem == 2) dwell = 3.0;

    _scanning = YES;
    [_scanResults removeAllObjects];
    [_scanResultTable reloadData];
    _scanProgress.doubleValue = 0;
    _scanStartStopBtn.title = @"中止";
    _scanSaveBtn.enabled = NO;
    _scanStatusLabel.stringValue = @"チャンネルスキャンを実行中…";

    __weak TVTestPreferencesWindowController *weakSelf = self;
    [live scanSpace:(NSUInteger)spIdx
       dwellSeconds:dwell
         onProgress:^(NSUInteger completed, NSUInteger total, TVTestChannelScanResult *result) {
        TVTestPreferencesWindowController *s = weakSelf;
        if (!s) return;
        [s->_scanResults addObject:result];
        [s->_scanResultTable reloadData];
        [s->_scanResultTable scrollRowToVisible:(NSInteger)s->_scanResults.count - 1];
        s->_scanProgress.doubleValue = total > 0 ? ((double)completed / (double)total) * 100.0 : 100.0;
        s->_scanStatusLabel.stringValue = [NSString stringWithFormat:@"スキャン中 (%lu / %lu): %@ (CNR %.1f dB)",
                                           (unsigned long)completed, (unsigned long)total,
                                           result.channelName, result.signalCNR];
    }
         completion:^(NSArray<TVTestChannelScanResult *> *results, BOOL cancelled) {
        TVTestPreferencesWindowController *s = weakSelf;
        if (!s) return;
        s->_scanning = NO;
        s->_scanStartStopBtn.title = @"スキャン開始";
        NSUInteger lockedCount = 0;
        for (TVTestChannelScanResult *r in results) {
            if (r.locked) ++lockedCount;
        }
        s->_scanSaveBtn.enabled = (lockedCount > 0);
        s->_scanStatusLabel.stringValue = cancelled
            ? [NSString stringWithFormat:@"スキャン中止（%lu チャンネルでロック検出）", (unsigned long)lockedCount]
            : [NSString stringWithFormat:@"スキャン完了（%lu / %lu チャンネルでロック検出）",
               (unsigned long)lockedCount, (unsigned long)results.count];
    }];
}

- (void)saveChannelScanResults:(id)sender {
    (void)sender;
    TVTestLiveTunerSession *live = [_delegate respondsToSelector:@selector(preferencesCurrentLiveSession)]
        ? [_delegate preferencesCurrentLiveSession] : nil;
    if (!live) return;

    NSMutableArray<NSDictionary<NSString *, id> *> *flat = [NSMutableArray array];
    for (TVTestChannelScanResult *r in _scanResults) {
        if (!r.locked) continue;
        if (r.services.count > 0) {
            [flat addObjectsFromArray:r.services];
        } else {
            [flat addObject:@{
                @"serviceID": @0,
                @"name": r.channelName ?: @"",
                @"space": @(r.spaceIndex),
                @"channel": @(r.channelIndex),
                @"channelName": r.channelName ?: @"",
                @"frequencyKHz": @(r.frequencyKHz),
                @"streamID": @(r.streamID),
            }];
        }
    }
    [TVTestSettings.sharedSettings saveScannedChannels:flat forDriverIdentifier:live.driverIdentifier];
    if ([_delegate respondsToSelector:@selector(preferencesDidSaveScannedChannels:forDriverIdentifier:)]) {
        [_delegate preferencesDidSaveScannedChannels:flat forDriverIdentifier:live.driverIdentifier];
    }
    _scanStatusLabel.stringValue = [NSString stringWithFormat:@"%lu 件のチャンネルを保存しました。", (unsigned long)flat.count];
}

- (void)chooseDirectoryForField:(NSTextField *)field {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp == NSModalResponseOK && panel.URL) {
            field.stringValue = panel.URL.path;
            [self applySettings:field];
            if (field == self->_bonDriverDirField) {
                [self refreshDriverAndScanState];
            }
        }
    }];
}

- (void)chooseCaptureDir:(id)sender { (void)sender; [self chooseDirectoryForField:_captureDirField]; }
- (void)chooseRecordDir:(id)sender { (void)sender; [self chooseDirectoryForField:_recordDirField]; }
- (void)chooseBonDriverDir:(id)sender { (void)sender; [self chooseDirectoryForField:_bonDriverDirField]; }
- (void)chooseCustomFirmwareDir:(id)sender { (void)sender; [self chooseDirectoryForField:_customFirmwareField]; }

- (void)chooseCustomConfig:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePropertyList];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp == NSModalResponseOK && panel.URL) {
            self->_customConfigField.stringValue = panel.URL.path;
            [self applySettings:self->_customConfigField];
        }
    }];
}

- (void)clearEPGCache:(id)sender {
    (void)sender;
    [NSFileManager.defaultManager removeItemAtPath:TVTestSettings.sharedSettings.epgDataFilePath error:NULL];
}

- (void)clearRecent:(id)sender {
    (void)sender;
    [TVTestSettings.sharedSettings clearRecentRecordings];
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _sidebarTable) return (NSInteger)_categoryNames.count;
    if (tableView == _driverTable) return (NSInteger)_discoveredDrivers.count;
    if (tableView == _scanResultTable) return (NSInteger)_scanResults.count;
    return 0;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (!tableColumn || row < 0) return nil;
    NSString *ident = tableColumn.identifier;
    NSTextField *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = ident;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.font = [NSFont systemFontOfSize:12.0];
    }

    if (tableView == _sidebarTable && (NSUInteger)row < _categoryNames.count) {
        cell.stringValue = _categoryNames[(NSUInteger)row];
        return cell;
    }
    if (tableView == _driverTable && (NSUInteger)row < _discoveredDrivers.count) {
        TVTestBonDriverInfo *d = _discoveredDrivers[(NSUInteger)row];
        if ([ident isEqualToString:@"drvName"]) cell.stringValue = d.displayName;
        else if ([ident isEqualToString:@"drvSys"]) cell.stringValue = [d.supportedSystems componentsJoinedByString:@" / "];
        else cell.stringValue = d.bundleURL.lastPathComponent;
        return cell;
    }
    if (tableView == _scanResultTable && (NSUInteger)row < _scanResults.count) {
        TVTestChannelScanResult *r = _scanResults[(NSUInteger)row];
        if ([ident isEqualToString:@"scanCh"]) cell.stringValue = r.channelName;
        else if ([ident isEqualToString:@"scanFreq"]) cell.stringValue = r.frequencyKHz ? [NSString stringWithFormat:@"%.1f MHz", (double)r.frequencyKHz / 1000.0] : @"-";
        else if ([ident isEqualToString:@"scanLock"]) cell.stringValue = r.locked ? @"LOCK" : @"-";
        else if ([ident isEqualToString:@"scanCNR"]) cell.stringValue = r.locked ? [NSString stringWithFormat:@"%.1f dB", r.signalCNR] : @"-";
        else {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSDictionary *svc in r.services) {
                NSString *n = svc[@"name"];
                if (n.length) [names addObject:n];
            }
            cell.stringValue = names.count ? [names componentsJoinedByString:@", "] : (r.locked ? @"(TS検出)" : @"");
        }
        return cell;
    }
    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == _sidebarTable) {
        NSInteger row = _sidebarTable.selectedRow;
        if (row >= 0 && (NSUInteger)row < _categoryNames.count) {
            [_pageTabs selectTabViewItemAtIndex:row];
            if (row == 4 || row == 5) {
                [self refreshDriverAndScanState];
            }
        }
    } else if (notification.object == _driverTable) {
        NSInteger row = _driverTable.selectedRow;
        if (row >= 0 && (NSUInteger)row < _discoveredDrivers.count) {
            TVTestSettings.sharedSettings.defaultBonDriverPath = _discoveredDrivers[(NSUInteger)row].bundleURL.path;
        }
    }
}

@end
