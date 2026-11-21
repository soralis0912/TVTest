// SPDX-License-Identifier: GPL-2.0-or-later
#import "CaptionOverlayView.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *ARIBColorForIndex(uint8_t index) {
    // ARIB STD-B24 standard palette (0..7)
    switch (index & 0x07) {
    case 0: return [NSColor colorWithWhite:0.15 alpha:1.0];
    case 1: return [NSColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
    case 2: return [NSColor colorWithRed:0.35 green:1.0 blue:0.45 alpha:1.0];
    case 3: return [NSColor colorWithRed:1.0 green:0.95 blue:0.35 alpha:1.0];
    case 4: return [NSColor colorWithRed:0.45 green:0.70 blue:1.0 alpha:1.0];
    case 5: return [NSColor colorWithRed:1.0 green:0.45 blue:1.0 alpha:1.0];
    case 6: return [NSColor colorWithRed:0.35 green:0.95 blue:1.0 alpha:1.0];
    case 7:
    default:
        return NSColor.whiteColor;
    }
}

static NSUInteger UTF16OffsetForUTF8Offset(NSString *string, NSUInteger utf8ByteOffset) {
    const char *utf8 = string.UTF8String;
    if (!utf8) {
        return 0;
    }
    const size_t totalBytes = strlen(utf8);
    const size_t clamped = MIN((size_t)utf8ByteOffset, totalBytes);
    if (clamped == 0) {
        return 0;
    }
    NSString *prefix = [[NSString alloc] initWithBytes:utf8 length:clamped encoding:NSUTF8StringEncoding];
    if (prefix) {
        return prefix.length;
    }
    return MIN(string.length, clamped);
}

@implementation TVTestCaptionOverlayView {
    NSView *_backdrop;
    NSTextField *_label;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _captionsEnabled = YES;
        _fontSize = 22.0;
        _backgroundAlpha = 0.72;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _backdrop = [[NSView alloc] init];
        _backdrop.wantsLayer = YES;
        _backdrop.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:_backgroundAlpha].CGColor;
        _backdrop.layer.cornerRadius = 8.0;
        _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
        _backdrop.hidden = YES;
        [self addSubview:_backdrop];

        _label = [NSTextField wrappingLabelWithString:@""];
        _label.alignment = NSTextAlignmentCenter;
        _label.maximumNumberOfLines = 4;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        _label.drawsBackground = NO;
        _label.textColor = NSColor.whiteColor;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [_backdrop addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [_backdrop.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-22],
            [_backdrop.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:24],
            [_backdrop.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-24],
            [_label.topAnchor constraintEqualToAnchor:_backdrop.topAnchor constant:8],
            [_label.bottomAnchor constraintEqualToAnchor:_backdrop.bottomAnchor constant:-8],
            [_label.leadingAnchor constraintEqualToAnchor:_backdrop.leadingAnchor constant:16],
            [_label.trailingAnchor constraintEqualToAnchor:_backdrop.trailingAnchor constant:-16],
        ]];
    }
    return self;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)setCaptionsEnabled:(BOOL)captionsEnabled {
    if (_captionsEnabled == captionsEnabled) {
        return;
    }
    _captionsEnabled = captionsEnabled;
    [self refreshDisplay];
}

- (void)setFontSize:(double)fontSize {
    _fontSize = MAX(12.0, MIN(48.0, fontSize));
    [self refreshDisplay];
}

- (void)setBackgroundAlpha:(double)backgroundAlpha {
    _backgroundAlpha = MAX(0.0, MIN(1.0, backgroundAlpha));
    _backdrop.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:_backgroundAlpha].CGColor;
}

- (void)setCurrentCue:(nullable TVTestCaptionCue *)currentCue {
    if (_currentCue == currentCue) {
        return;
    }
    _currentCue = currentCue;
    [self refreshDisplay];
}

- (void)refreshDisplay {
    if (!_captionsEnabled || !_currentCue || _currentCue.text.length == 0) {
        _backdrop.hidden = YES;
        _label.stringValue = @"";
        return;
    }

    NSString *text = _currentCue.text;
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    para.lineSpacing = 3.0;

    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.92];
    shadow.shadowOffset = NSMakeSize(1.0, -1.0);
    shadow.shadowBlurRadius = 2.0;

    NSFont *baseFont = [NSFont fontWithName:@"Hiragino Sans W6" size:_fontSize]
        ?: [NSFont boldSystemFontOfSize:_fontSize];

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
        initWithString:text
            attributes:@{
                NSFontAttributeName: baseFont,
                NSForegroundColorAttributeName: NSColor.whiteColor,
                NSParagraphStyleAttributeName: para,
                NSShadowAttributeName: shadow,
            }];

    NSArray<TVTestCaptionFormatRun *> *runs = _currentCue.formatRuns;
    for (NSUInteger i = 0; i < runs.count; ++i) {
        TVTestCaptionFormatRun *run = runs[i];
        NSUInteger start = UTF16OffsetForUTF8Offset(text, run.utf8ByteOffset);
        NSUInteger end = (i + 1 < runs.count)
            ? UTF16OffsetForUTF8Offset(text, runs[i + 1].utf8ByteOffset)
            : text.length;
        if (start >= text.length || end <= start) {
            continue;
        }
        NSRange range = NSMakeRange(start, MIN(end, text.length) - start);
        NSColor *fg = ARIBColorForIndex(run.charColorIndex);
        [attr addAttribute:NSForegroundColorAttributeName value:fg range:range];

        if (run.charSize == 0 || run.charSize == 1 || run.charSize == 3) {
            CGFloat smallSize = MAX(11.0, _fontSize * 0.75);
            NSFont *smallFont = [NSFont fontWithName:@"Hiragino Sans W6" size:smallSize]
                ?: [NSFont boldSystemFontOfSize:smallSize];
            [attr addAttribute:NSFontAttributeName value:smallFont range:range];
        }
    }

    _label.attributedStringValue = attr;
    _backdrop.hidden = NO;
}

@end
