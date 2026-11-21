// SPDX-License-Identifier: GPL-2.0-or-later
#import "ProgramInfoWindowController.h"

@implementation TVTestProgramInfoWindowController {
    NSTextField *_headerLabel;
    NSTextField *_metaLabel;
    NSTextView *_textView;
}

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 440)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"番組情報";
    panel.minSize = NSMakeSize(380, 280);
    panel.floatingPanel = NO;
    panel.hidesOnDeactivate = NO;
    [panel center];

    self = [super initWithWindow:panel];
    if (self) {
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    _headerLabel = [NSTextField labelWithString:@"録画が開かれていません"];
    _headerLabel.font = [NSFont boldSystemFontOfSize:14.0];
    _headerLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_headerLabel];

    _metaLabel = [NSTextField labelWithString:@""];
    _metaLabel.font = [NSFont systemFontOfSize:11.5];
    _metaLabel.textColor = NSColor.secondaryLabelColor;
    _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_metaLabel];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scroll];

    _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 340)];
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.verticallyResizable = YES;
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.textContainer.widthTracksTextView = YES;
    _textView.textContainerInset = NSMakeSize(10, 10);
    _textView.font = [NSFont systemFontOfSize:12.5];
    scroll.documentView = _textView;

    [NSLayoutConstraint activateConstraints:@[
        [_headerLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [_headerLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [_headerLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [_metaLabel.topAnchor constraintEqualToAnchor:_headerLabel.bottomAnchor constant:4],
        [_metaLabel.leadingAnchor constraintEqualToAnchor:_headerLabel.leadingAnchor],
        [_metaLabel.trailingAnchor constraintEqualToAnchor:_headerLabel.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_metaLabel.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
    ]];
}

- (void)updateWithSnapshot:(nullable TVTestRecordingSnapshot *)snapshot
          activeServiceID:(uint16_t)serviceID
            recordingName:(nullable NSString *)recordingName {
    if (!snapshot) {
        _headerLabel.stringValue = recordingName ?: @"録画が開かれていません";
        _metaLabel.stringValue = @"";
        _textView.string = @"番組情報を取得できませんでした。";
        return;
    }

    TVTestServiceInfo *active = [snapshot serviceWithID:serviceID];
    _headerLabel.stringValue = active
        ? [NSString stringWithFormat:@"%@ (SID %u)", active.name, active.serviceID]
        : (recordingName ?: @"番組情報");

    NSMutableArray<NSString *> *meta = [NSMutableArray array];
    if (snapshot.totTimeText.length) {
        [meta addObject:[NSString stringWithFormat:@"放送時刻 %@", snapshot.totTimeText]];
    }
    if (snapshot.estimatedBitrateMbps > 0.05) {
        [meta addObject:[NSString stringWithFormat:@"%.2f Mbps", snapshot.estimatedBitrateMbps]];
    }
    if (snapshot.networkName.length) {
        [meta addObject:snapshot.networkName];
    }
    if (active.hasCaptions) {
        [meta addObject:@"ARIB字幕あり"];
    }
    _metaLabel.stringValue = [meta componentsJoinedByString:@"   ·   "];

    NSMutableArray<NSString *> *blocks = [NSMutableArray array];
    if (active) {
        if (active.currentProgram) {
            TVTestProgramInfo *p = active.currentProgram;
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            NSString *timeLine = p.startTimeText.length
                ? (p.endTimeText.length ? [NSString stringWithFormat:@"%@〜%@", p.startTimeText, p.endTimeText]
                                        : p.startTimeText)
                : @"";
            [lines addObject:[NSString stringWithFormat:@"■ 現在の番組%@",
                              timeLine.length ? [NSString stringWithFormat:@"  (%@)", timeLine] : @""]];
            if (p.title.length) {
                [lines addObject:p.title];
            }
            NSMutableArray<NSString *> *specs = [NSMutableArray array];
            if (p.genreText.length) [specs addObject:p.genreText];
            if (p.videoSpecText.length) [specs addObject:p.videoSpecText];
            if (p.audioSpecText.length) [specs addObject:p.audioSpecText];
            if (specs.count) {
                [lines addObject:[NSString stringWithFormat:@"[%@]", [specs componentsJoinedByString:@" / "]]];
            }
            if (p.descriptionText.length) {
                [lines addObject:@""];
                [lines addObject:p.descriptionText];
            }
            if (p.extendedText.length) {
                [lines addObject:@""];
                [lines addObject:p.extendedText];
            }
            [blocks addObject:[lines componentsJoinedByString:@"\n"]];
        } else {
            [blocks addObject:@"■ 現在の番組\n番組情報が含まれていません。"];
        }

        if (active.nextProgram) {
            TVTestProgramInfo *n = active.nextProgram;
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            NSString *timeLine = n.startTimeText.length
                ? (n.endTimeText.length ? [NSString stringWithFormat:@"%@〜%@", n.startTimeText, n.endTimeText]
                                        : n.startTimeText)
                : @"";
            [lines addObject:[NSString stringWithFormat:@"■ 次の番組%@",
                              timeLine.length ? [NSString stringWithFormat:@"  (%@)", timeLine] : @""]];
            if (n.title.length) {
                [lines addObject:n.title];
            }
            if (n.descriptionText.length) {
                [lines addObject:n.descriptionText];
            }
            [blocks addObject:[lines componentsJoinedByString:@"\n"]];
        }

        if (active.audioStreams.count > 0) {
            NSMutableArray<NSString *> *audioLines = [NSMutableArray arrayWithObject:@"■ 音声ストリーム"];
            for (TVTestAudioStreamInfo *a in active.audioStreams) {
                [audioLines addObject:[NSString stringWithFormat:@"• %@ (PID 0x%04X)", a.label, a.pid]];
            }
            [blocks addObject:[audioLines componentsJoinedByString:@"\n"]];
        }
    }

    if (snapshot.services.count > 1) {
        NSMutableArray<NSString *> *otherLines = [NSMutableArray arrayWithObject:@"■ 録画内の全サービス"];
        for (TVTestServiceInfo *svc in snapshot.services) {
            NSString *curTitle = svc.currentProgram.title.length ? svc.currentProgram.title : @"(番組名なし)";
            [otherLines addObject:[NSString stringWithFormat:@"• %@ (SID %u) — %@",
                                   svc.name, svc.serviceID, curTitle]];
        }
        [blocks addObject:[otherLines componentsJoinedByString:@"\n"]];
    }

    _textView.string = blocks.count ? [blocks componentsJoinedByString:@"\n\n────────────────────────\n\n"]
                                    : @"サービス情報を取得できませんでした。";
}

@end
