// SPDX-License-Identifier: GPL-2.0-or-later
#import "ProgramGuideWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <cmath>
#include <limits>

static NSColor *EPGGenreColor(uint8_t level1) {
    // Classic TVTest genre-tinted pastel palette
    switch (level1) {
    case 0x0: return [NSColor colorWithRed:0.78 green:0.93 blue:1.00 alpha:1.0]; // ニュース
    case 0x1: return [NSColor colorWithRed:0.80 green:0.96 blue:0.82 alpha:1.0]; // スポーツ
    case 0x2: return [NSColor colorWithRed:0.98 green:0.91 blue:0.80 alpha:1.0]; // 情報
    case 0x3: return [NSColor colorWithRed:1.00 green:0.84 blue:0.88 alpha:1.0]; // ドラマ
    case 0x4: return [NSColor colorWithRed:0.83 green:0.88 blue:1.00 alpha:1.0]; // 音楽
    case 0x5: return [NSColor colorWithRed:1.00 green:0.97 blue:0.76 alpha:1.0]; // バラエティ
    case 0x6: return [NSColor colorWithRed:0.91 green:0.83 blue:1.00 alpha:1.0]; // 映画
    case 0x7: return [NSColor colorWithRed:1.00 green:0.88 blue:0.75 alpha:1.0]; // アニメ
    case 0x8: return [NSColor colorWithRed:0.84 green:0.95 blue:0.90 alpha:1.0]; // ドキュメンタリー
    case 0x9: return [NSColor colorWithRed:0.96 green:0.85 blue:0.96 alpha:1.0]; // 劇場
    case 0xA: return [NSColor colorWithRed:0.88 green:0.96 blue:0.80 alpha:1.0]; // 趣味/教育
    default:  return [NSColor colorWithWhite:0.95 alpha:1.0];
    }
}

@interface TVTestEPGGridView : NSView
@property (nonatomic, copy) NSArray<TVTestEPGServiceEntry *> *services;
@property (nonatomic, copy, nullable) void (^onSelectEvent)(TVTestEPGEvent *event);
@property (nonatomic, nullable) TVTestEPGEvent *selectedEvent;
@end

@implementation TVTestEPGGridView {
    int64_t _minHourEpoch;
    int64_t _maxHourEpoch;
    CGFloat _rulerWidth;
    CGFloat _headerHeight;
    CGFloat _columnWidth;
    CGFloat _hourHeight;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _services = @[];
        _rulerWidth = 60.0;
        _headerHeight = 32.0;
        _columnWidth = 210.0;
        _hourHeight = 96.0;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setServices:(NSArray<TVTestEPGServiceEntry *> *)services {
    _services = [services copy] ?: @[];
    int64_t minSec = std::numeric_limits<int64_t>::max();
    int64_t maxSec = 0;
    for (TVTestEPGServiceEntry *svc in _services) {
        for (TVTestEPGEvent *ev in svc.events) {
            if (ev.startEpochSeconds <= 0) continue;
            minSec = std::min(minSec, ev.startEpochSeconds);
            int64_t endSec = ev.startEpochSeconds + std::max<int64_t>(ev.durationSeconds, 1800);
            maxSec = std::max(maxSec, endSec);
        }
    }
    if (minSec == std::numeric_limits<int64_t>::max() || maxSec <= minSec) {
        _minHourEpoch = 0;
        _maxHourEpoch = 0;
        self.frame = NSMakeRect(0, 0, 600, 320);
        [self setNeedsDisplay:YES];
        return;
    }
    // Cap span to 48 hours for responsive layout
    _minHourEpoch = (minSec / 3600) * 3600;
    _maxHourEpoch = std::min(((maxSec + 3599) / 3600) * 3600, _minHourEpoch + 48 * 3600);
    NSInteger hours = MAX((NSInteger)1, (NSInteger)((_maxHourEpoch - _minHourEpoch) / 3600));
    CGFloat w = MAX(640.0, _rulerWidth + (CGFloat)_services.count * _columnWidth);
    CGFloat h = _headerHeight + (CGFloat)hours * _hourHeight + 16.0;
    self.frame = NSMakeRect(0, 0, w, h);
    [self setNeedsDisplay:YES];
}

- (NSRect)rectForEvent:(TVTestEPGEvent *)ev columnIndex:(NSUInteger)colIdx {
    if (_maxHourEpoch <= _minHourEpoch || ev.startEpochSeconds < _minHourEpoch ||
        ev.startEpochSeconds >= _maxHourEpoch) {
        return NSZeroRect;
    }
    CGFloat x = _rulerWidth + (CGFloat)colIdx * _columnWidth;
    CGFloat y = _headerHeight + ((CGFloat)(ev.startEpochSeconds - _minHourEpoch) / 3600.0) * _hourHeight;
    CGFloat dur = MAX((CGFloat)ev.durationSeconds, 600.0);
    CGFloat h = MAX(22.0, (dur / 3600.0) * _hourHeight);
    return NSMakeRect(x + 1.0, y + 0.5, _columnWidth - 2.0, h - 1.0);
}

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirtyRect);

    if (_services.count == 0 || _maxHourEpoch <= _minHourEpoch) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13.0],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        };
        [@"グリッド表示する EPG スケジュールがありません。" drawAtPoint:NSMakePoint(24, 24) withAttributes:attrs];
        return;
    }

    NSInteger hours = (NSInteger)((_maxHourEpoch - _minHourEpoch) / 3600);

    // Column headers
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12.0],
        NSForegroundColorAttributeName: NSColor.labelColor,
    };
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, _headerHeight));
    for (NSUInteger i = 0; i < _services.count; ++i) {
        CGFloat x = _rulerWidth + (CGFloat)i * _columnWidth;
        NSRect hRect = NSMakeRect(x + 6, 7, _columnWidth - 12, _headerHeight - 10);
        NSString *hdr = [NSString stringWithFormat:@"%@ (%u)", _services[i].serviceName, _services[i].serviceID];
        [hdr drawInRect:hRect withAttributes:headerAttrs];
        [[NSColor separatorColor] setStroke];
        [NSBezierPath strokeLineFromPoint:NSMakePoint(x, 0) toPoint:NSMakePoint(x, self.bounds.size.height)];
    }

    // Hour ruler & horizontal gridlines
    NSDictionary *rulerAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
    };
    for (NSInteger h = 0; h < hours; ++h) {
        CGFloat y = _headerHeight + (CGFloat)h * _hourHeight;
        int64_t sec = _minHourEpoch + h * 3600;
        int hourOfDay = (int)((sec / 3600) % 24);
        NSString *label = [NSString stringWithFormat:@"%02d:00", hourOfDay];
        [label drawAtPoint:NSMakePoint(8, y + 4) withAttributes:rulerAttrs];
        [[NSColor separatorColor] setStroke];
        [NSBezierPath strokeLineFromPoint:NSMakePoint(0, y) toPoint:NSMakePoint(self.bounds.size.width, y)];
    }

    // Program blocks
    NSDictionary *timeAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.15 alpha:1.0],
    };
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.08 alpha:1.0],
    };

    for (NSUInteger col = 0; col < _services.count; ++col) {
        for (TVTestEPGEvent *ev in _services[col].events) {
            NSRect box = [self rectForEvent:ev columnIndex:col];
            if (NSIsEmptyRect(box) || !NSIntersectsRect(box, dirtyRect)) {
                continue;
            }
            [EPGGenreColor(ev.genreLevel1) setFill];
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3.0 yRadius:3.0];
            [path fill];

            if (ev == _selectedEvent) {
                [NSColor.controlAccentColor setStroke];
                path.lineWidth = 2.0;
            } else {
                [[NSColor colorWithWhite:0.0 alpha:0.22] setStroke];
                path.lineWidth = 0.75;
            }
            [path stroke];

            NSString *timeLine = ev.timeRangeText;
            [timeLine drawInRect:NSMakeRect(box.origin.x + 5, box.origin.y + 2, box.size.width - 10, 14)
                  withAttributes:timeAttrs];
            if (box.size.height > 26) {
                NSRect tRect = NSMakeRect(box.origin.x + 5, box.origin.y + 16,
                                          box.size.width - 10, box.size.height - 18);
                [ev.title drawWithRect:tRect
                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                            attributes:titleAttrs];
            }
        }
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSUInteger col = 0; col < _services.count; ++col) {
        for (TVTestEPGEvent *ev in _services[col].events) {
            NSRect box = [self rectForEvent:ev columnIndex:col];
            if (NSPointInRect(pt, box)) {
                _selectedEvent = ev;
                [self setNeedsDisplay:YES];
                if (_onSelectEvent) {
                    _onSelectEvent(ev);
                }
                return;
            }
        }
    }
}

@end

@interface TVTestProgramGuideWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation TVTestProgramGuideWindowController {
    NSSegmentedControl *_modeControl;
    NSPopUpButton *_servicePopup;
    NSSearchField *_searchField;
    NSTextField *_statusLabel;
    NSButton *_exportJSONButton;

    NSTabView *_contentTabs;
    TVTestEPGGridView *_gridView;
    NSTableView *_tableView;
    NSTextView *_detailTextView;

    NSArray<TVTestEPGServiceEntry *> *_services;
    NSArray<TVTestEPGEvent *> *_filteredEvents;
    uint16_t _selectedServiceID;
    BOOL _scanFinished;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 920, 640)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"番組表 (EPG)";
    window.minSize = NSMakeSize(600, 420);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _services = @[];
        _filteredEvents = @[];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    _modeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"グリッド", @"リスト"]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                           target:self
                                                           action:@selector(modeChanged:)];
    _modeControl.selectedSegment = 0;
    _modeControl.translatesAutoresizingMaskIntoConstraints = NO;

    _servicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _servicePopup.target = self;
    _servicePopup.action = @selector(serviceChanged:);
    _servicePopup.translatesAutoresizingMaskIntoConstraints = NO;

    _searchField = [[NSSearchField alloc] init];
    _searchField.placeholderString = @"番組名・内容を検索";
    _searchField.delegate = self;
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [NSTextField labelWithString:@"EPG データなし"];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.font = [NSFont systemFontOfSize:11.5];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];

    _exportJSONButton = [NSButton buttonWithTitle:@"JSON出力…" target:self action:@selector(exportJSON:)];
    _exportJSONButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[
        _modeControl, _servicePopup, _searchField, _statusLabel, _exportJSONButton
    ]];
    toolbar.spacing = 10;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:toolbar];

    NSSplitView *splitView = [[NSSplitView alloc] init];
    splitView.vertical = NO;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    splitView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:splitView];

    _contentTabs = [[NSTabView alloc] init];
    _contentTabs.tabViewType = NSNoTabsNoBorder;

    // Tab 0: Grid view
    NSTabViewItem *gridTab = [[NSTabViewItem alloc] initWithIdentifier:@"grid"];
    NSScrollView *gridScroll = [[NSScrollView alloc] init];
    gridScroll.hasVerticalScroller = YES;
    gridScroll.hasHorizontalScroller = YES;
    gridScroll.borderType = NSBezelBorder;

    _gridView = [[TVTestEPGGridView alloc] initWithFrame:NSMakeRect(0, 0, 880, 400)];
    __weak TVTestProgramGuideWindowController *weakSelf = self;
    _gridView.onSelectEvent = ^(TVTestEPGEvent *ev) {
        [weakSelf showDetailForEvent:ev];
    };
    gridScroll.documentView = _gridView;
    gridTab.view = gridScroll;
    [_contentTabs addTabViewItem:gridTab];

    // Tab 1: List view
    NSTabViewItem *listTab = [[NSTabViewItem alloc] initWithIdentifier:@"list"];
    NSScrollView *tableScroll = [[NSScrollView alloc] init];
    tableScroll.hasVerticalScroller = YES;
    tableScroll.borderType = NSBezelBorder;

    _tableView = [[NSTableView alloc] init];
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;

    NSTableColumn *dateCol = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    dateCol.title = @"日付";
    dateCol.width = 78;
    [_tableView addTableColumn:dateCol];

    NSTableColumn *timeCol = [[NSTableColumn alloc] initWithIdentifier:@"time"];
    timeCol.title = @"時間";
    timeCol.width = 104;
    [_tableView addTableColumn:timeCol];

    NSTableColumn *genreCol = [[NSTableColumn alloc] initWithIdentifier:@"genre"];
    genreCol.title = @"ジャンル";
    genreCol.width = 132;
    [_tableView addTableColumn:genreCol];

    NSTableColumn *titleCol = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    titleCol.title = @"番組名";
    titleCol.width = 500;
    titleCol.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_tableView addTableColumn:titleCol];

    tableScroll.documentView = _tableView;
    listTab.view = tableScroll;
    [_contentTabs addTabViewItem:listTab];

    [splitView addArrangedSubview:_contentTabs];

    NSScrollView *detailScroll = [[NSScrollView alloc] init];
    detailScroll.hasVerticalScroller = YES;
    detailScroll.borderType = NSBezelBorder;

    _detailTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 880, 150)];
    _detailTextView.editable = NO;
    _detailTextView.selectable = YES;
    _detailTextView.verticallyResizable = YES;
    _detailTextView.autoresizingMask = NSViewWidthSizable;
    _detailTextView.textContainer.widthTracksTextView = YES;
    _detailTextView.textContainerInset = NSMakeSize(10, 8);
    _detailTextView.font = [NSFont systemFontOfSize:12.5];
    detailScroll.documentView = _detailTextView;
    [splitView addArrangedSubview:detailScroll];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [toolbar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [toolbar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [_servicePopup.widthAnchor constraintGreaterThanOrEqualToConstant:160],
        [_searchField.widthAnchor constraintGreaterThanOrEqualToConstant:160],
        [splitView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:10],
        [splitView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [splitView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [splitView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [detailScroll.heightAnchor constraintGreaterThanOrEqualToConstant:130],
    ]];
}

- (void)modeChanged:(NSSegmentedControl *)sender {
    [_contentTabs selectTabViewItemAtIndex:sender.selectedSegment];
}

- (void)resetForNewRecording {
    _services = @[];
    _filteredEvents = @[];
    _selectedServiceID = 0;
    _scanFinished = NO;
    [_servicePopup removeAllItems];
    _gridView.services = @[];
    _statusLabel.stringValue = @"EPG をスキャン中…";
    _detailTextView.string = @"";
    [_tableView reloadData];
}

- (void)updateWithEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
           preferredServiceID:(uint16_t)serviceID
                     finished:(BOOL)finished {
    _services = services ?: @[];
    _scanFinished = finished;

    if (_selectedServiceID == 0 && serviceID != 0) {
        _selectedServiceID = serviceID;
    }

    [_servicePopup removeAllItems];
    NSInteger selectedIdx = 0;
    for (NSUInteger i = 0; i < _services.count; ++i) {
        TVTestEPGServiceEntry *entry = _services[i];
        NSString *itemTitle = [NSString stringWithFormat:@"%@ (SID %u / %lu件)",
                               entry.serviceName, entry.serviceID, (unsigned long)entry.events.count];
        [_servicePopup addItemWithTitle:itemTitle];
        if (entry.serviceID == _selectedServiceID) {
            selectedIdx = (NSInteger)i;
        }
    }
    if (_services.count > 0) {
        [_servicePopup selectItemAtIndex:selectedIdx];
        _selectedServiceID = _services[(NSUInteger)selectedIdx].serviceID;
    }

    _gridView.services = _services;
    [self applyFilter];
}

- (void)serviceChanged:(id)sender {
    (void)sender;
    NSInteger idx = _servicePopup.indexOfSelectedItem;
    if (idx >= 0 && (NSUInteger)idx < _services.count) {
        _selectedServiceID = _services[(NSUInteger)idx].serviceID;
        [self applyFilter];
    }
}

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    if (_searchField.stringValue.length > 0 && _modeControl.selectedSegment == 0) {
        _modeControl.selectedSegment = 1;
        [_contentTabs selectTabViewItemAtIndex:1];
    }
    [self applyFilter];
}

- (void)applyFilter {
    TVTestEPGServiceEntry *current = nil;
    for (TVTestEPGServiceEntry *entry in _services) {
        if (entry.serviceID == _selectedServiceID) {
            current = entry;
            break;
        }
    }
    if (!current) {
        current = _services.firstObject;
    }

    NSString *query = [_searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!current) {
        _filteredEvents = @[];
    } else if (query.length == 0) {
        _filteredEvents = current.events;
    } else {
        NSMutableArray<TVTestEPGEvent *> *matched = [NSMutableArray array];
        for (TVTestEPGEvent *ev in current.events) {
            if ([ev.title localizedCaseInsensitiveContainsString:query] ||
                [ev.descriptionText localizedCaseInsensitiveContainsString:query] ||
                [ev.extendedText localizedCaseInsensitiveContainsString:query] ||
                [ev.genreText localizedCaseInsensitiveContainsString:query]) {
                [matched addObject:ev];
            }
        }
        _filteredEvents = matched;
    }

    NSUInteger totalEvents = 0;
    for (TVTestEPGServiceEntry *s in _services) {
        totalEvents += s.events.count;
    }
    if (_services.count == 0) {
        _statusLabel.stringValue = _scanFinished ? @"EPG 情報なし" : @"スキャン中…";
    } else {
        _statusLabel.stringValue = _scanFinished
            ? [NSString stringWithFormat:@"%lu 局 / %lu 番組", (unsigned long)_services.count, (unsigned long)totalEvents]
            : [NSString stringWithFormat:@"スキャン中… (%lu 番組)", (unsigned long)totalEvents];
    }
    _exportJSONButton.enabled = (_services.count > 0);

    [_tableView reloadData];
    if (_filteredEvents.count > 0) {
        NSInteger row = _tableView.selectedRow;
        if (row < 0 || (NSUInteger)row >= _filteredEvents.count) {
            [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            row = 0;
        }
        [self showDetailForEvent:_filteredEvents[(NSUInteger)row]];
    } else {
        _detailTextView.string = _scanFinished
            ? @"表示する番組情報がありません。"
            : @"録画から EIT スケジュール情報を収集しています…";
    }
}

- (void)showDetailForEvent:(nullable TVTestEPGEvent *)ev {
    if (!ev) {
        _detailTextView.string = @"";
        return;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ %@  %@",
                      ev.dateText, ev.timeRangeText, ev.title.length ? ev.title : @"(タイトルなし)"]];
    if (ev.genreText.length) {
        [parts addObject:[NSString stringWithFormat:@"[%@]", ev.genreText]];
    }
    if (ev.descriptionText.length) {
        [parts addObject:@""];
        [parts addObject:ev.descriptionText];
    }
    if (ev.extendedText.length) {
        [parts addObject:@""];
        [parts addObject:ev.extendedText];
    }
    _detailTextView.string = [parts componentsJoinedByString:@"\n"];
}

- (void)exportJSON:(id)sender {
    (void)sender;
    if (_services.count == 0) {
        return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"EPG を JSON 形式で書き出す";
    panel.nameFieldStringValue = @"TVTest_EPG.json";
    panel.allowedContentTypes = @[UTTypeJSON];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            if (![TVTestRecordingSession exportEPGServices:self->_services toJSONURL:panel.URL error:&err]) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"JSON 出力エラー";
                alert.informativeText = err.localizedDescription ?: @"保存に失敗しました。";
                [alert beginSheetModalForWindow:self.window completionHandler:nil];
            }
        }
    }];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_filteredEvents.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= _filteredEvents.count || !tableColumn) {
        return nil;
    }
    NSString *ident = tableColumn.identifier;
    NSTextField *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = ident;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.font = [ident isEqualToString:@"time"] || [ident isEqualToString:@"date"]
            ? [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular]
            : [NSFont systemFontOfSize:12.0];
    }
    TVTestEPGEvent *ev = _filteredEvents[(NSUInteger)row];
    if ([ident isEqualToString:@"date"]) {
        cell.stringValue = ev.dateText;
    } else if ([ident isEqualToString:@"time"]) {
        cell.stringValue = ev.timeRangeText;
    } else if ([ident isEqualToString:@"genre"]) {
        cell.stringValue = ev.genreText;
    } else {
        cell.stringValue = ev.title;
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && (NSUInteger)row < _filteredEvents.count) {
        [self showDetailForEvent:_filteredEvents[(NSUInteger)row]];
    }
}

@end
