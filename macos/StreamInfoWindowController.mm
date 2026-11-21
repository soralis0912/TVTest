// SPDX-License-Identifier: GPL-2.0-or-later
#import "StreamInfoWindowController.h"

@interface TVTestStreamInfoWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation TVTestStreamInfoWindowController {
    NSTextField *_summaryLabel;
    NSTextView *_servicesTextView;
    NSTableView *_pidTable;
    NSArray<TVTestPIDStat *> *_pidStats;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 620, 480)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"ストリーム情報";
    window.minSize = NSMakeSize(480, 340);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _pidStats = @[];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    _summaryLabel = [NSTextField labelWithString:@"ストリーム情報なし"];
    _summaryLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_summaryLabel];

    NSTabView *tabs = [[NSTabView alloc] init];
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:tabs];

    // Tab 1: Services & ES PIDs
    NSTabViewItem *svcTab = [[NSTabViewItem alloc] initWithIdentifier:@"services"];
    svcTab.label = @"サービス・PID 構成";
    NSScrollView *svcScroll = [[NSScrollView alloc] init];
    svcScroll.hasVerticalScroller = YES;
    svcScroll.borderType = NSBezelBorder;
    _servicesTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 580, 360)];
    _servicesTextView.editable = NO;
    _servicesTextView.selectable = YES;
    _servicesTextView.verticallyResizable = YES;
    _servicesTextView.autoresizingMask = NSViewWidthSizable;
    _servicesTextView.textContainer.widthTracksTextView = YES;
    _servicesTextView.textContainerInset = NSMakeSize(10, 8);
    _servicesTextView.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    svcScroll.documentView = _servicesTextView;
    svcTab.view = svcScroll;
    [tabs addTabViewItem:svcTab];

    // Tab 2: Per-PID Packet Stats
    NSTabViewItem *pidTab = [[NSTabViewItem alloc] initWithIdentifier:@"pids"];
    pidTab.label = @"PID 別パケット統計";
    NSScrollView *pidScroll = [[NSScrollView alloc] init];
    pidScroll.hasVerticalScroller = YES;
    pidScroll.borderType = NSBezelBorder;

    _pidTable = [[NSTableView alloc] init];
    _pidTable.usesAlternatingRowBackgroundColors = YES;
    _pidTable.dataSource = self;
    _pidTable.delegate = self;

    NSArray<NSArray *> *cols = @[
        @[@"pid", @"PID", @76],
        @[@"label", @"種別", @230],
        @[@"packets", @"パケット数", @100],
        @[@"drops", @"ドロップ", @80],
        @[@"scrambled", @"スクランブル", @90],
    ];
    for (NSArray *spec in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        col.title = spec[1];
        col.width = [spec[2] doubleValue];
        [_pidTable addTableColumn:col];
    }

    pidScroll.documentView = _pidTable;
    pidTab.view = pidScroll;
    [tabs addTabViewItem:pidTab];

    [NSLayoutConstraint activateConstraints:@[
        [_summaryLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [_summaryLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [_summaryLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [tabs.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:10],
        [tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [tabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [tabs.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
    ]];
}

- (void)updateWithSnapshot:(nullable TVTestRecordingSnapshot *)snapshot
                     stats:(nullable TVTestStreamStats *)stats {
    TVTestStreamStats *st = stats ?: snapshot.streamStats;
    _pidStats = st.pidStats ?: @[];
    [_pidTable reloadData];

    if (!snapshot) {
        _summaryLabel.stringValue = @"録画が開かれていません";
        _servicesTextView.string = @"";
        return;
    }

    _summaryLabel.stringValue = [NSString stringWithFormat:
        @"NID: 0x%04X (%@)  |  TSID: 0x%04X  |  総パケット: %llu  |  ドロップ: %llu  |  エラー: %llu  |  スクランブル: %llu",
        snapshot.networkID,
        snapshot.networkName.length ? snapshot.networkName : @"-",
        snapshot.transportStreamID,
        st.totalPackets,
        st.continuityErrorPackets,
        st.formatErrorPackets + st.transportErrorPackets,
        st.scrambledPackets];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (TVTestServiceInfo *svc in snapshot.services) {
        [lines addObject:[NSString stringWithFormat:@"■ %@  (SID: %u / 0x%04X, PMT: 0x%04X, PCR: 0x%04X)",
                          svc.name, svc.serviceID, svc.serviceID, svc.pmtPID, svc.pcrPID]];
        for (TVTestESDetail *es in svc.elementaryStreams) {
            [lines addObject:[NSString stringWithFormat:@"   • PID 0x%04X  [%@]  0x%02X (%@)",
                              es.pid, es.category, es.streamType, es.streamTypeName]];
        }
        [lines addObject:@""];
    }
    _servicesTextView.string = lines.count ? [lines componentsJoinedByString:@"\n"] : @"サービス情報がありません。";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_pidStats.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= _pidStats.count || !tableColumn) {
        return nil;
    }
    NSString *ident = tableColumn.identifier;
    NSTextField *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = ident;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.font = [ident isEqualToString:@"label"]
            ? [NSFont systemFontOfSize:11.5]
            : [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    }
    TVTestPIDStat *st = _pidStats[(NSUInteger)row];
    if ([ident isEqualToString:@"pid"]) {
        cell.stringValue = [NSString stringWithFormat:@"0x%04X", st.pid];
    } else if ([ident isEqualToString:@"label"]) {
        cell.stringValue = st.label;
    } else if ([ident isEqualToString:@"packets"]) {
        cell.stringValue = [NSString stringWithFormat:@"%llu", st.packetCount];
    } else if ([ident isEqualToString:@"drops"]) {
        cell.stringValue = [NSString stringWithFormat:@"%llu", st.continuityErrorCount];
    } else {
        cell.stringValue = [NSString stringWithFormat:@"%llu", st.scrambledCount];
    }
    return cell;
}

@end
