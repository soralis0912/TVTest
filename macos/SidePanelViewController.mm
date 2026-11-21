// SPDX-License-Identifier: GPL-2.0-or-later
#import "SidePanelViewController.h"

@interface TVTestSidePanelViewController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation TVTestSidePanelViewController {
    NSSegmentedControl *_tabControl;
    NSTabView *_tabView;

    // Tab 0: Info
    NSTextView *_infoTextView;

    // Tab 1: Channels (Windows TVTest style: space selector + scanned channels in live mode, or TS services)
    NSPopUpButton *_spacePopup;
    NSTableView *_channelTable;
    NSArray<TVTestServiceInfo *> *_services;
    NSArray<NSDictionary<NSString *, id> *> *_allScannedChannels;
    NSArray<NSDictionary<NSString *, id> *> *_visibleScannedChannels;
    NSArray<NSNumber *> *_availableSpaceIndices;
    NSArray<NSString *> *_spaceNames;
    NSUInteger _selectedSpaceFilter;
    NSUInteger _currentLiveSpace;
    NSUInteger _currentLiveChannel;
    uint16_t _activeServiceID;
    __weak TVTestRecordingSession *_session;

    // Tab 2: Program List
    NSTableView *_programTable;
    NSTextView *_programDetailView;
    NSArray<TVTestEPGEvent *> *_serviceEvents;

    // Tab 3: Caption Log
    NSSearchField *_captionSearch;
    NSTableView *_captionTable;
    NSArray<TVTestCaptionCue *> *_allCaptions;
    NSArray<TVTestCaptionCue *> *_filteredCaptions;
    NSInteger _lastHighlightedCaptionRow;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _services = @[];
        _allScannedChannels = @[];
        _visibleScannedChannels = @[];
        _availableSpaceIndices = @[];
        _spaceNames = @[];
        _selectedSpaceFilter = NSUIntegerMax;
        _currentLiveSpace = NSUIntegerMax;
        _currentLiveChannel = NSUIntegerMax;
        _serviceEvents = @[];
        _allCaptions = @[];
        _filteredCaptions = @[];
        _lastHighlightedCaptionRow = -1;
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 310, 540)];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    self.view = root;

    _tabControl = [NSSegmentedControl segmentedControlWithLabels:@[@"情報", @"チャンネル", @"番組", @"字幕"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self
                                                          action:@selector(tabChanged:)];
    _tabControl.segmentStyle = NSSegmentStyleRounded;
    _tabControl.selectedSegment = 0;
    _tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_tabControl];

    _tabView = [[NSTabView alloc] init];
    _tabView.tabViewType = NSNoTabsNoBorder;
    _tabView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_tabView];

    [self buildInfoTab];
    [self buildChannelTab];
    [self buildProgramListTab];
    [self buildCaptionTab];

    [NSLayoutConstraint activateConstraints:@[
        [_tabControl.topAnchor constraintEqualToAnchor:root.topAnchor constant:8],
        [_tabControl.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:8],
        [_tabControl.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-8],
        [_tabView.topAnchor constraintEqualToAnchor:_tabControl.bottomAnchor constant:8],
        [_tabView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_tabView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_tabView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
}

- (void)buildInfoTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"info"];
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;

    _infoTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 290, 480)];
    _infoTextView.editable = NO;
    _infoTextView.selectable = YES;
    _infoTextView.verticallyResizable = YES;
    _infoTextView.autoresizingMask = NSViewWidthSizable;
    _infoTextView.textContainer.widthTracksTextView = YES;
    _infoTextView.textContainerInset = NSMakeSize(10, 8);
    _infoTextView.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    _infoTextView.string = @"録画を開くとストリーム・番組情報を表示します。";
    scroll.documentView = _infoTextView;
    item.view = scroll;
    [_tabView addTabViewItem:item];
}

- (void)buildChannelTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"channel"];
    NSView *container = [[NSView alloc] init];

    _spacePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _spacePopup.controlSize = NSControlSizeSmall;
    _spacePopup.target = self;
    _spacePopup.action = @selector(spaceFilterChanged:);
    _spacePopup.hidden = YES;
    _spacePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_spacePopup];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:scroll];

    _channelTable = [[NSTableView alloc] init];
    _channelTable.usesAlternatingRowBackgroundColors = YES;
    _channelTable.rowHeight = 40.0;
    _channelTable.headerView = nil;
    _channelTable.dataSource = self;
    _channelTable.delegate = self;
    _channelTable.target = self;
    _channelTable.action = @selector(channelClicked:);
    _channelTable.doubleAction = @selector(channelDoubleClicked:);

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"channel"];
    col.width = 280;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_channelTable addTableColumn:col];

    scroll.documentView = _channelTable;

    [NSLayoutConstraint activateConstraints:@[
        [_spacePopup.topAnchor constraintEqualToAnchor:container.topAnchor constant:4],
        [_spacePopup.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [_spacePopup.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:_spacePopup.bottomAnchor constant:4],
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    item.view = container;
    [_tabView addTabViewItem:item];
}

- (void)buildProgramListTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"programs"];
    NSSplitView *split = [[NSSplitView alloc] init];
    split.vertical = NO;
    split.dividerStyle = NSSplitViewDividerStyleThin;

    NSScrollView *listScroll = [[NSScrollView alloc] init];
    listScroll.hasVerticalScroller = YES;
    _programTable = [[NSTableView alloc] init];
    _programTable.usesAlternatingRowBackgroundColors = YES;
    _programTable.rowHeight = 36.0;
    _programTable.headerView = nil;
    _programTable.dataSource = self;
    _programTable.delegate = self;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"prog"];
    col.width = 280;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_programTable addTableColumn:col];
    listScroll.documentView = _programTable;
    [split addArrangedSubview:listScroll];

    NSScrollView *detailScroll = [[NSScrollView alloc] init];
    detailScroll.hasVerticalScroller = YES;
    _programDetailView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 290, 140)];
    _programDetailView.editable = NO;
    _programDetailView.selectable = YES;
    _programDetailView.verticallyResizable = YES;
    _programDetailView.autoresizingMask = NSViewWidthSizable;
    _programDetailView.textContainer.widthTracksTextView = YES;
    _programDetailView.textContainerInset = NSMakeSize(8, 6);
    _programDetailView.font = [NSFont systemFontOfSize:11.5];
    detailScroll.documentView = _programDetailView;
    [split addArrangedSubview:detailScroll];
    [detailScroll.heightAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;

    item.view = split;
    [_tabView addTabViewItem:item];
}

- (void)buildCaptionTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"caption"];
    NSView *container = [[NSView alloc] init];

    _captionSearch = [[NSSearchField alloc] init];
    _captionSearch.placeholderString = @"字幕を検索";
    _captionSearch.delegate = self;
    _captionSearch.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *copyBtn = [NSButton buttonWithTitle:@"コピー" target:self action:@selector(copyCaptions:)];
    copyBtn.controlSize = NSControlSizeSmall;
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *exportBtn = [NSButton buttonWithTitle:@"保存…" target:self action:@selector(exportCaptions:)];
    exportBtn.controlSize = NSControlSizeSmall;
    exportBtn.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *bar = [NSStackView stackViewWithViews:@[_captionSearch, copyBtn, exportBtn]];
    bar.spacing = 6;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:bar];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:scroll];

    _captionTable = [[NSTableView alloc] init];
    _captionTable.usesAlternatingRowBackgroundColors = YES;
    _captionTable.rowHeight = 28.0;
    _captionTable.dataSource = self;
    _captionTable.delegate = self;
    _captionTable.target = self;
    _captionTable.doubleAction = @selector(captionDoubleClicked:);

    NSTableColumn *tCol = [[NSTableColumn alloc] initWithIdentifier:@"capTime"];
    tCol.title = @"時刻";
    tCol.width = 58;
    tCol.minWidth = 50;
    [_captionTable addTableColumn:tCol];

    NSTableColumn *textCol = [[NSTableColumn alloc] initWithIdentifier:@"capText"];
    textCol.title = @"字幕 (ダブルクリックでシーク)";
    textCol.width = 220;
    textCol.resizingMask = NSTableColumnAutoresizingMask;
    [_captionTable addTableColumn:textCol];

    scroll.documentView = _captionTable;

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:container.topAnchor constant:2],
        [bar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [bar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    item.view = container;
    [_tabView addTabViewItem:item];
}

- (TVTestSidePanelTab)selectedTab {
    return (TVTestSidePanelTab)_tabControl.selectedSegment;
}

- (void)setSelectedTab:(TVTestSidePanelTab)selectedTab {
    NSInteger idx = MAX((NSInteger)0, MIN((NSInteger)3, (NSInteger)selectedTab));
    _tabControl.selectedSegment = idx;
    [_tabView selectTabViewItemAtIndex:idx];
}

- (void)tabChanged:(NSSegmentedControl *)sender {
    [_tabView selectTabViewItemAtIndex:sender.selectedSegment];
    if ([_delegate respondsToSelector:@selector(sidePanelDidChangeSelectedTab:)]) {
        [_delegate sidePanelDidChangeSelectedTab:(TVTestSidePanelTab)sender.selectedSegment];
    }
}

- (void)updateSnapshot:(nullable TVTestRecordingSnapshot *)snapshot
       activeServiceID:(uint16_t)serviceID
             videoSize:(NSSize)videoSize
                 stats:(nullable TVTestStreamStats *)stats
               session:(nullable TVTestRecordingSession *)session {
    _session = session;
    _activeServiceID = serviceID;
    _services = snapshot.services ?: @[];
    [_channelTable reloadData];

    if (!snapshot) {
        _infoTextView.string = @"録画が開かれていません。";
        return;
    }

    TVTestServiceInfo *active = [snapshot serviceWithID:serviceID];
    TVTestStreamStats *st = stats ?: snapshot.streamStats;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (active) {
        [lines addObject:[NSString stringWithFormat:@"サービス: %@ (SID %u)", active.name, active.serviceID]];
    }
    if (snapshot.networkName.length || snapshot.networkID != 0) {
        [lines addObject:[NSString stringWithFormat:@"ネットワーク: %@ (NID 0x%04X / TSID 0x%04X)",
                          snapshot.networkName.length ? snapshot.networkName : @"-",
                          snapshot.networkID, snapshot.transportStreamID]];
    }
    if (videoSize.width > 0 && videoSize.height > 0) {
        [lines addObject:[NSString stringWithFormat:@"映像サイズ: %.0f x %.0f", videoSize.width, videoSize.height]];
    }
    if (active.currentProgram.videoSpecText.length) {
        [lines addObject:[NSString stringWithFormat:@"映像種別: %@", active.currentProgram.videoSpecText]];
    }
    if (active.currentProgram.audioSpecText.length) {
        [lines addObject:[NSString stringWithFormat:@"音声種別: %@", active.currentProgram.audioSpecText]];
    }
    if (snapshot.totTimeText.length) {
        [lines addObject:[NSString stringWithFormat:@"放送時刻: %@", snapshot.totTimeText]];
    }
    if (snapshot.estimatedBitrateMbps > 0.05) {
        [lines addObject:[NSString stringWithFormat:@"ビットレート: %.2f Mbps", snapshot.estimatedBitrateMbps]];
    }
    if (st) {
        [lines addObject:[NSString stringWithFormat:@"パケット: %llu / Drop: %llu / Err: %llu / Scr: %llu",
                          st.totalPackets, st.continuityErrorPackets,
                          st.formatErrorPackets + st.transportErrorPackets,
                          st.scrambledPackets]];
    }
    [lines addObject:@""];
    if (active.currentProgram) {
        TVTestProgramInfo *p = active.currentProgram;
        [lines addObject:@"【現在の番組】"];
        if (p.startTimeText.length) {
            [lines addObject:[NSString stringWithFormat:@"%@〜%@", p.startTimeText, p.endTimeText]];
        }
        if (p.title.length) [lines addObject:p.title];
        if (p.descriptionText.length) {
            [lines addObject:@""];
            [lines addObject:p.descriptionText];
        }
    }
    if (active.nextProgram) {
        TVTestProgramInfo *n = active.nextProgram;
        [lines addObject:@""];
        [lines addObject:@"【次の番組】"];
        if (n.startTimeText.length) {
            [lines addObject:[NSString stringWithFormat:@"%@〜%@", n.startTimeText, n.endTimeText]];
        }
        if (n.title.length) [lines addObject:n.title];
    }

    _infoTextView.string = [lines componentsJoinedByString:@"\n"];
}

- (void)updateEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
          activeServiceID:(uint16_t)serviceID {
    TVTestEPGServiceEntry *matched = nil;
    for (TVTestEPGServiceEntry *e in services) {
        if (e.serviceID == serviceID) {
            matched = e;
            break;
        }
    }
    if (!matched) {
        matched = services.firstObject;
    }
    _serviceEvents = matched.events ?: @[];
    [_programTable reloadData];
    if (_serviceEvents.count > 0) {
        [self showProgramDetailAtRow:0];
    } else {
        _programDetailView.string = @"番組表データがありません。";
    }
}

- (void)updateCaptions:(NSArray<TVTestCaptionCue *> *)cues {
    _allCaptions = cues ?: @[];
    _lastHighlightedCaptionRow = -1;
    [self applyCaptionFilter];
}

- (void)applyCaptionFilter {
    NSString *q = [_captionSearch.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        _filteredCaptions = _allCaptions;
    } else {
        NSMutableArray<TVTestCaptionCue *> *m = [NSMutableArray array];
        for (TVTestCaptionCue *c in _allCaptions) {
            if ([c.text localizedCaseInsensitiveContainsString:q]) {
                [m addObject:c];
            }
        }
        _filteredCaptions = m;
    }
    [_captionTable reloadData];
}

- (void)highlightCaptionAtTimeMs:(int64_t)timeMs {
    if (timeMs < 0 || _filteredCaptions.count == 0 || _captionSearch.stringValue.length > 0) {
        return;
    }
    NSInteger match = -1;
    NSInteger lo = 0;
    NSInteger hi = (NSInteger)_filteredCaptions.count - 1;
    while (lo <= hi) {
        NSInteger mid = lo + (hi - lo) / 2;
        if (_filteredCaptions[(NSUInteger)mid].timeMs <= timeMs) {
            match = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if (match >= 0 && match != _lastHighlightedCaptionRow) {
        _lastHighlightedCaptionRow = match;
        [_captionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)match] byExtendingSelection:NO];
        if (self.selectedTab == TVTestSidePanelTabCaption) {
            [_captionTable scrollRowToVisible:match];
        }
    }
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == _captionSearch) {
        [self applyCaptionFilter];
    }
}

- (void)updateLiveChannels:(NSArray<NSDictionary<NSString *, id> *> *)scannedChannels
                spaceNames:(NSArray<NSString *> *)spaceNames
              currentSpace:(NSUInteger)space
            currentChannel:(NSUInteger)channel
           activeServiceID:(uint16_t)serviceID {
    _allScannedChannels = [scannedChannels copy] ?: @[];
    _spaceNames = [spaceNames copy] ?: @[];
    _currentLiveSpace = space;
    _currentLiveChannel = channel;
    _activeServiceID = serviceID;

    NSMutableSet<NSNumber *> *spSet = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *e in _allScannedChannels) {
        [spSet addObject:(e[@"space"] ?: @0)];
    }
    _availableSpaceIndices = [[spSet allObjects] sortedArrayUsingSelector:@selector(compare:)];

    [_spacePopup removeAllItems];
    if (_availableSpaceIndices.count > 0) {
        _spacePopup.hidden = NO;
        for (NSNumber *spNum in _availableSpaceIndices) {
            NSUInteger idx = spNum.unsignedIntegerValue;
            NSString *title = (idx < _spaceNames.count)
                ? _spaceNames[idx]
                : [NSString stringWithFormat:@"空間 %lu", (unsigned long)idx];
            [_spacePopup addItemWithTitle:title];
        }
        if (_selectedSpaceFilter == NSUIntegerMax ||
            ![_availableSpaceIndices containsObject:@(_selectedSpaceFilter)]) {
            _selectedSpaceFilter = [_availableSpaceIndices containsObject:@(space)]
                ? space
                : _availableSpaceIndices.firstObject.unsignedIntegerValue;
        }
        NSUInteger popIdx = [_availableSpaceIndices indexOfObject:@(_selectedSpaceFilter)];
        if (popIdx != NSNotFound) {
            [_spacePopup selectItemAtIndex:(NSInteger)popIdx];
        }
        [self rebuildVisibleScannedChannels];
    } else {
        _spacePopup.hidden = YES;
        _visibleScannedChannels = @[];
        [_channelTable reloadData];
    }
}

- (void)rebuildVisibleScannedChannels {
    NSMutableArray<NSDictionary<NSString *, id> *> *filtered = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *e in _allScannedChannels) {
        if ([e[@"space"] unsignedIntegerValue] == _selectedSpaceFilter) {
            [filtered addObject:e];
        }
    }
    _visibleScannedChannels = filtered;
    [_channelTable reloadData];
}

- (void)spaceFilterChanged:(NSPopUpButton *)sender {
    NSInteger idx = sender.indexOfSelectedItem;
    if (idx >= 0 && (NSUInteger)idx < _availableSpaceIndices.count) {
        _selectedSpaceFilter = _availableSpaceIndices[(NSUInteger)idx].unsignedIntegerValue;
        [self rebuildVisibleScannedChannels];
    }
}

- (void)channelClicked:(id)sender {
    (void)sender;
    NSInteger row = _channelTable.clickedRow;
    if (row < 0) return;
    if (_visibleScannedChannels.count > 0 && (NSUInteger)row < _visibleScannedChannels.count) {
        if ([_delegate respondsToSelector:@selector(sidePanelDidSelectScannedChannel:)]) {
            [_delegate sidePanelDidSelectScannedChannel:_visibleScannedChannels[(NSUInteger)row]];
        }
    }
}

- (void)channelDoubleClicked:(id)sender {
    (void)sender;
    NSInteger row = _channelTable.selectedRow;
    if (_visibleScannedChannels.count > 0 && row >= 0 && (NSUInteger)row < _visibleScannedChannels.count) {
        if ([_delegate respondsToSelector:@selector(sidePanelDidSelectScannedChannel:)]) {
            [_delegate sidePanelDidSelectScannedChannel:_visibleScannedChannels[(NSUInteger)row]];
        }
        return;
    }
    if (row >= 0 && (NSUInteger)row < _services.count) {
        if ([_delegate respondsToSelector:@selector(sidePanelDidSelectServiceID:)]) {
            [_delegate sidePanelDidSelectServiceID:_services[(NSUInteger)row].serviceID];
        }
    }
}

- (void)captionDoubleClicked:(id)sender {
    (void)sender;
    NSInteger row = _captionTable.selectedRow;
    if (row >= 0 && (NSUInteger)row < _filteredCaptions.count) {
        if ([_delegate respondsToSelector:@selector(sidePanelDidRequestSeekToTimeMs:)]) {
            [_delegate sidePanelDidRequestSeekToTimeMs:_filteredCaptions[(NSUInteger)row].timeMs];
        }
    }
}

- (void)copyCaptions:(id)sender {
    (void)sender;
    NSString *text = [TVTestRecordingSession formatPlainTextFromCues:_filteredCaptions];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

- (void)exportCaptions:(id)sender {
    (void)sender;
    if ([_delegate respondsToSelector:@selector(sidePanelDidRequestExportCaptions)]) {
        [_delegate sidePanelDidRequestExportCaptions];
    }
}

- (void)showProgramDetailAtRow:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= _serviceEvents.count) {
        _programDetailView.string = @"";
        return;
    }
    TVTestEPGEvent *ev = _serviceEvents[(NSUInteger)row];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ %@  %@", ev.dateText, ev.timeRangeText, ev.title]];
    if (ev.genreText.length) [parts addObject:[NSString stringWithFormat:@"[%@]", ev.genreText]];
    if (ev.descriptionText.length) [parts addObject:ev.descriptionText];
    if (ev.extendedText.length) [parts addObject:ev.extendedText];
    _programDetailView.string = [parts componentsJoinedByString:@"\n\n"];
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _channelTable) {
        return (_visibleScannedChannels.count > 0)
            ? (NSInteger)_visibleScannedChannels.count
            : (NSInteger)_services.count;
    }
    if (tableView == _programTable) return (NSInteger)_serviceEvents.count;
    if (tableView == _captionTable) return (NSInteger)_filteredCaptions.count;
    return 0;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (tableView == _channelTable && _visibleScannedChannels.count > 0 &&
        row >= 0 && (NSUInteger)row < _visibleScannedChannels.count) {
        NSDictionary<NSString *, id> *entry = _visibleScannedChannels[(NSUInteger)row];
        NSUInteger sp = [entry[@"space"] unsignedIntegerValue];
        NSUInteger ch = [entry[@"channel"] unsignedIntegerValue];
        uint16_t sid = [entry[@"serviceID"] unsignedShortValue];
        BOOL isCurrent = (sp == _currentLiveSpace && ch == _currentLiveChannel &&
                          (sid == 0 || sid == _activeServiceID));

        NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 270, 40)];
        NSTextField *title = [NSTextField labelWithString:
            [NSString stringWithFormat:@"%@%@", isCurrent ? @"▶ " : @"", entry[@"name"] ?: @""]];
        title.font = isCurrent
            ? [NSFont boldSystemFontOfSize:12.5]
            : [NSFont systemFontOfSize:12.5];
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.translatesAutoresizingMaskIntoConstraints = NO;

        NSString *subText = entry[@"channelName"] ?: @"";
        if (isCurrent) {
            for (TVTestServiceInfo *svc in _services) {
                if (svc.serviceID == sid && svc.currentProgram.title.length) {
                    subText = svc.currentProgram.title;
                    break;
                }
            }
        }
        NSTextField *sub = [NSTextField labelWithString:subText];
        sub.font = [NSFont systemFontOfSize:11.0];
        sub.textColor = NSColor.secondaryLabelColor;
        sub.lineBreakMode = NSLineBreakByTruncatingTail;
        sub.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *vStack = [NSStackView stackViewWithViews:@[title, sub]];
        vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        vStack.alignment = NSLayoutAttributeLeading;
        vStack.spacing = 1;
        vStack.translatesAutoresizingMaskIntoConstraints = NO;

        NSData *logoData = _logoLookupBlock ? _logoLookupBlock(sid) : [_session logoPNGDataForServiceID:sid];
        NSImage *logoImg = logoData ? [[NSImage alloc] initWithData:logoData] : nil;
        if (logoImg) {
            NSImageView *iv = [[NSImageView alloc] init];
            iv.image = logoImg;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [iv.widthAnchor constraintEqualToConstant:36].active = YES;
            [iv.heightAnchor constraintEqualToConstant:22].active = YES;
            NSStackView *h = [NSStackView stackViewWithViews:@[iv, vStack]];
            h.spacing = 6;
            h.alignment = NSLayoutAttributeCenterY;
            h.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:h];
            [NSLayoutConstraint activateConstraints:@[
                [h.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
                [h.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
                [h.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        } else {
            [cell addSubview:vStack];
            [NSLayoutConstraint activateConstraints:@[
                [vStack.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
                [vStack.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
                [vStack.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
        return cell;
    }

    if (tableView == _channelTable && row >= 0 && (NSUInteger)row < _services.count) {
        TVTestServiceInfo *svc = _services[(NSUInteger)row];
        NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 270, 42)];

        NSTextField *title = [NSTextField labelWithString:
            [NSString stringWithFormat:@"%@%@ (SID %u)",
             svc.serviceID == _activeServiceID ? @"▶ " : @"",
             svc.name, svc.serviceID]];
        title.font = (svc.serviceID == _activeServiceID)
            ? [NSFont boldSystemFontOfSize:12.5]
            : [NSFont systemFontOfSize:12.5];
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *sub = [NSTextField labelWithString:svc.currentProgram.title ?: @""];
        sub.font = [NSFont systemFontOfSize:11.0];
        sub.textColor = NSColor.secondaryLabelColor;
        sub.lineBreakMode = NSLineBreakByTruncatingTail;
        sub.translatesAutoresizingMaskIntoConstraints = NO;

        NSData *logoData = _logoLookupBlock ? _logoLookupBlock(svc.serviceID) : [_session logoPNGDataForServiceID:svc.serviceID];
        NSImage *logoImg = logoData ? [[NSImage alloc] initWithData:logoData] : nil;

        NSStackView *vStack = [NSStackView stackViewWithViews:@[title, sub]];
        vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        vStack.alignment = NSLayoutAttributeLeading;
        vStack.spacing = 1;
        vStack.translatesAutoresizingMaskIntoConstraints = NO;

        if (logoImg) {
            NSImageView *iv = [[NSImageView alloc] init];
            iv.image = logoImg;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [iv.widthAnchor constraintEqualToConstant:36].active = YES;
            [iv.heightAnchor constraintEqualToConstant:22].active = YES;
            NSStackView *h = [NSStackView stackViewWithViews:@[iv, vStack]];
            h.spacing = 6;
            h.alignment = NSLayoutAttributeCenterY;
            h.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:h];
            [NSLayoutConstraint activateConstraints:@[
                [h.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
                [h.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
                [h.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        } else {
            [cell addSubview:vStack];
            [NSLayoutConstraint activateConstraints:@[
                [vStack.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
                [vStack.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
                [vStack.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
        return cell;
    }

    if (tableView == _programTable && row >= 0 && (NSUInteger)row < _serviceEvents.count) {
        TVTestEPGEvent *ev = _serviceEvents[(NSUInteger)row];
        NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 270, 36)];
        NSTextField *t = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ %@", ev.dateText, ev.timeRangeText]];
        t.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        t.textColor = NSColor.secondaryLabelColor;
        t.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *name = [NSTextField labelWithString:ev.title ?: @""];
        name.font = [NSFont systemFontOfSize:12.0];
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        name.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *v = [NSStackView stackViewWithViews:@[t, name]];
        v.orientation = NSUserInterfaceLayoutOrientationVertical;
        v.alignment = NSLayoutAttributeLeading;
        v.spacing = 1;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [v.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [v.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [v.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        return cell;
    }

    if (tableView == _captionTable && row >= 0 && (NSUInteger)row < _filteredCaptions.count && tableColumn) {
        TVTestCaptionCue *cue = _filteredCaptions[(NSUInteger)row];
        NSString *ident = tableColumn.identifier;
        NSTextField *lbl = [tableView makeViewWithIdentifier:ident owner:self];
        if (!lbl) {
            lbl = [NSTextField labelWithString:@""];
            lbl.identifier = ident;
            lbl.lineBreakMode = NSLineBreakByTruncatingTail;
        }
        if ([ident isEqualToString:@"capTime"]) {
            int64_t sec = MAX((int64_t)0, cue.timeMs) / 1000;
            lbl.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];
            lbl.textColor = NSColor.secondaryLabelColor;
            lbl.stringValue = [NSString stringWithFormat:@"%02lld:%02lld", sec / 60, sec % 60];
        } else {
            lbl.font = [NSFont systemFontOfSize:12.0];
            lbl.textColor = NSColor.labelColor;
            lbl.stringValue = [cue.text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        }
        return lbl;
    }

    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == _programTable) {
        [self showProgramDetailAtRow:_programTable.selectedRow];
    }
}

@end
