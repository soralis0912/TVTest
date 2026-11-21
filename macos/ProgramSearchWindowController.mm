// SPDX-License-Identifier: GPL-2.0-or-later
#import "ProgramSearchWindowController.h"

@interface TVTestSearchHit : NSObject
@property (nonatomic, copy) NSString *serviceName;
@property (nonatomic, strong) TVTestEPGEvent *event;
@end
@implementation TVTestSearchHit
@end

@interface TVTestProgramSearchWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation TVTestProgramSearchWindowController {
    NSSearchField *_keywordField;
    NSPopUpButton *_genrePopup;
    NSPopUpButton *_servicePopup;
    NSTextField *_countLabel;
    NSTableView *_tableView;
    NSTextView *_detailView;

    NSArray<TVTestEPGServiceEntry *> *_services;
    NSArray<TVTestSearchHit *> *_results;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 780, 540)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"番組検索";
    window.minSize = NSMakeSize(560, 380);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _services = @[];
        _results = @[];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    _keywordField = [[NSSearchField alloc] init];
    _keywordField.placeholderString = @"キーワード（番組名・説明・詳細）";
    _keywordField.delegate = self;
    _keywordField.translatesAutoresizingMaskIntoConstraints = NO;

    _genrePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_genrePopup addItemsWithTitles:@[
        @"すべてのジャンル",
        @"ニュース／報道",
        @"スポーツ",
        @"情報／ワイドショー",
        @"ドラマ",
        @"音楽",
        @"バラエティ",
        @"映画",
        @"アニメ／特撮",
        @"ドキュメンタリー／教養",
        @"劇場／公演",
        @"趣味／教育",
        @"福祉",
    ]];
    _genrePopup.target = self;
    _genrePopup.action = @selector(filterChanged:);
    _genrePopup.translatesAutoresizingMaskIntoConstraints = NO;

    _servicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_servicePopup addItemWithTitle:@"すべてのサービス"];
    _servicePopup.target = self;
    _servicePopup.action = @selector(filterChanged:);
    _servicePopup.translatesAutoresizingMaskIntoConstraints = NO;

    _countLabel = [NSTextField labelWithString:@"0 件"];
    _countLabel.font = [NSFont systemFontOfSize:11.5];
    _countLabel.textColor = NSColor.secondaryLabelColor;
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *bar = [NSStackView stackViewWithViews:@[_keywordField, _genrePopup, _servicePopup, _countLabel]];
    bar.spacing = 8;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:bar];

    NSSplitView *split = [[NSSplitView alloc] init];
    split.vertical = NO;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:split];

    NSScrollView *tScroll = [[NSScrollView alloc] init];
    tScroll.hasVerticalScroller = YES;
    tScroll.borderType = NSBezelBorder;

    _tableView = [[NSTableView alloc] init];
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;

    NSArray<NSArray *> *cols = @[
        @[@"service", @"サービス", @130],
        @[@"date", @"日付", @78],
        @[@"time", @"時間", @100],
        @[@"genre", @"ジャンル", @120],
        @[@"title", @"番組名", @320],
    ];
    for (NSArray *spec in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        col.title = spec[1];
        col.width = [spec[2] doubleValue];
        if ([spec[0] isEqualToString:@"title"]) {
            col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        }
        [_tableView addTableColumn:col];
    }
    tScroll.documentView = _tableView;
    [split addArrangedSubview:tScroll];

    NSScrollView *dScroll = [[NSScrollView alloc] init];
    dScroll.hasVerticalScroller = YES;
    dScroll.borderType = NSBezelBorder;
    _detailView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 740, 140)];
    _detailView.editable = NO;
    _detailView.selectable = YES;
    _detailView.verticallyResizable = YES;
    _detailView.autoresizingMask = NSViewWidthSizable;
    _detailView.textContainer.widthTracksTextView = YES;
    _detailView.textContainerInset = NSMakeSize(10, 8);
    _detailView.font = [NSFont systemFontOfSize:12.5];
    dScroll.documentView = _detailView;
    [split addArrangedSubview:dScroll];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [_keywordField.widthAnchor constraintGreaterThanOrEqualToConstant:200],
        [split.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:10],
        [split.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [split.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [split.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [dScroll.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
}

- (void)updateWithEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services {
    _services = services ?: @[];
    NSString *prevTitle = _servicePopup.titleOfSelectedItem;
    [_servicePopup removeAllItems];
    [_servicePopup addItemWithTitle:@"すべてのサービス"];
    for (TVTestEPGServiceEntry *svc in _services) {
        [_servicePopup addItemWithTitle:[NSString stringWithFormat:@"%@ (SID %u)", svc.serviceName, svc.serviceID]];
    }
    if (prevTitle && [_servicePopup indexOfItemWithTitle:prevTitle] >= 0) {
        [_servicePopup selectItemWithTitle:prevTitle];
    }
    [self runSearch];
}

- (void)filterChanged:(id)sender {
    (void)sender;
    [self runSearch];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    [self runSearch];
}

- (void)runSearch {
    NSString *query = [_keywordField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger genreIdx = _genrePopup.indexOfSelectedItem; // 0 = all, 1..12 -> level1 = idx - 1
    NSInteger svcIdx = _servicePopup.indexOfSelectedItem; // 0 = all, >0 -> _services[svcIdx - 1]

    NSMutableArray<TVTestSearchHit *> *hits = [NSMutableArray array];
    for (NSUInteger i = 0; i < _services.count; ++i) {
        if (svcIdx > 0 && (NSInteger)(i + 1) != svcIdx) {
            continue;
        }
        TVTestEPGServiceEntry *svc = _services[i];
        for (TVTestEPGEvent *ev in svc.events) {
            if (genreIdx > 0 && ev.genreLevel1 != (uint8_t)(genreIdx - 1)) {
                continue;
            }
            if (query.length > 0 &&
                ![ev.title localizedCaseInsensitiveContainsString:query] &&
                ![ev.descriptionText localizedCaseInsensitiveContainsString:query] &&
                ![ev.extendedText localizedCaseInsensitiveContainsString:query]) {
                continue;
            }
            TVTestSearchHit *hit = [[TVTestSearchHit alloc] init];
            hit.serviceName = svc.serviceName;
            hit.event = ev;
            [hits addObject:hit];
        }
    }

    [hits sortUsingComparator:^NSComparisonResult(TVTestSearchHit *a, TVTestSearchHit *b) {
        if (a.event.startEpochSeconds < b.event.startEpochSeconds) return NSOrderedAscending;
        if (a.event.startEpochSeconds > b.event.startEpochSeconds) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    _results = hits;
    _countLabel.stringValue = [NSString stringWithFormat:@"%lu 件", (unsigned long)_results.count];
    [_tableView reloadData];
    if (_results.count > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self showDetailAtRow:0];
    } else {
        _detailView.string = @"一致する番組がありません。";
    }
}

- (void)showDetailAtRow:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= _results.count) {
        _detailView.string = @"";
        return;
    }
    TVTestSearchHit *hit = _results[(NSUInteger)row];
    TVTestEPGEvent *ev = hit.event;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@  |  %@ %@  %@",
                      hit.serviceName, ev.dateText, ev.timeRangeText, ev.title]];
    if (ev.genreText.length) [parts addObject:[NSString stringWithFormat:@"[%@]", ev.genreText]];
    if (ev.descriptionText.length) {
        [parts addObject:@""];
        [parts addObject:ev.descriptionText];
    }
    if (ev.extendedText.length) {
        [parts addObject:@""];
        [parts addObject:ev.extendedText];
    }
    _detailView.string = [parts componentsJoinedByString:@"\n"];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_results.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= _results.count || !tableColumn) {
        return nil;
    }
    NSString *ident = tableColumn.identifier;
    NSTextField *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = ident;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.font = ([ident isEqualToString:@"date"] || [ident isEqualToString:@"time"])
            ? [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular]
            : [NSFont systemFontOfSize:12.0];
    }
    TVTestSearchHit *hit = _results[(NSUInteger)row];
    if ([ident isEqualToString:@"service"]) cell.stringValue = hit.serviceName;
    else if ([ident isEqualToString:@"date"]) cell.stringValue = hit.event.dateText;
    else if ([ident isEqualToString:@"time"]) cell.stringValue = hit.event.timeRangeText;
    else if ([ident isEqualToString:@"genre"]) cell.stringValue = hit.event.genreText;
    else cell.stringValue = hit.event.title;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self showDetailAtRow:_tableView.selectedRow];
}

@end
