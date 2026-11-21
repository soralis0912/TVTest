// SPDX-License-Identifier: GPL-2.0-or-later
#import "OSDOverlayView.h"
#import <QuartzCore/QuartzCore.h>

@implementation TVTestOSDOverlayView {
    NSView *_card;
    NSImageView *_logoView;
    NSTextField *_titleLabel;
    NSTextField *_subtitleLabel;
    NSProgressIndicator *_volumeBar;
    NSTimer *_hideTimer;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _osdEnabled = YES;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _card = [[NSView alloc] init];
        _card.wantsLayer = YES;
        _card.layer.backgroundColor = [NSColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.82].CGColor;
        _card.layer.cornerRadius = 10.0;
        _card.layer.borderWidth = 1.0;
        _card.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.18].CGColor;
        _card.alphaValue = 0.0;
        _card.hidden = YES;
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_card];

        _logoView = [[NSImageView alloc] init];
        _logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _logoView.translatesAutoresizingMaskIntoConstraints = NO;
        _logoView.hidden = YES;
        [_logoView.widthAnchor constraintEqualToConstant:44].active = YES;
        [_logoView.heightAnchor constraintEqualToConstant:26].active = YES;

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont boldSystemFontOfSize:16.0];
        _titleLabel.textColor = NSColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [NSTextField labelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:13.0];
        _subtitleLabel.textColor = [NSColor colorWithWhite:0.88 alpha:1.0];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _volumeBar = [[NSProgressIndicator alloc] init];
        _volumeBar.indeterminate = NO;
        _volumeBar.minValue = 0;
        _volumeBar.maxValue = 100;
        _volumeBar.style = NSProgressIndicatorStyleBar;
        _volumeBar.hidden = YES;
        _volumeBar.translatesAutoresizingMaskIntoConstraints = NO;
        [_volumeBar.widthAnchor constraintEqualToConstant:180].active = YES;

        NSStackView *textStack = [NSStackView stackViewWithViews:@[_titleLabel, _subtitleLabel, _volumeBar]];
        textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        textStack.alignment = NSLayoutAttributeLeading;
        textStack.spacing = 4.0;
        textStack.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *row = [NSStackView stackViewWithViews:@[_logoView, textStack]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 10.0;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:20],
            [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
            [_card.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-20],
            [row.topAnchor constraintEqualToAnchor:_card.topAnchor constant:10],
            [row.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-10],
            [row.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:14],
            [row.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-14],
        ]];
    }
    return self;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)presentCardForDuration:(NSTimeInterval)seconds {
    if (!_osdEnabled) {
        return;
    }
    [_hideTimer invalidate];
    _card.hidden = NO;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.14;
        self->_card.animator.alphaValue = 1.0;
    }];
    __weak TVTestOSDOverlayView *weakSelf = self;
    _hideTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(__unused NSTimer *t) {
        TVTestOSDOverlayView *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.35;
            strongSelf->_card.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (strongSelf->_card.alphaValue < 0.05) {
                strongSelf->_card.hidden = YES;
            }
        }];
    }];
}

- (void)showMessage:(NSString *)title subtitle:(nullable NSString *)subtitle {
    _logoView.hidden = YES;
    _volumeBar.hidden = YES;
    _titleLabel.stringValue = title ?: @"";
    _subtitleLabel.stringValue = subtitle ?: @"";
    _subtitleLabel.hidden = (subtitle.length == 0);
    [self presentCardForDuration:2.4];
}

- (void)showService:(NSString *)serviceName
          serviceID:(uint16_t)serviceID
       programTitle:(nullable NSString *)programTitle
          timeRange:(nullable NSString *)timeRange
               logo:(nullable NSImage *)logo {
    _volumeBar.hidden = YES;
    if (logo) {
        _logoView.image = logo;
        _logoView.hidden = NO;
    } else {
        _logoView.hidden = YES;
    }
    _titleLabel.stringValue = [NSString stringWithFormat:@"%@  (SID %u)", serviceName, serviceID];
    if (programTitle.length) {
        _subtitleLabel.stringValue = timeRange.length
            ? [NSString stringWithFormat:@"%@  %@", timeRange, programTitle]
            : programTitle;
        _subtitleLabel.hidden = NO;
    } else {
        _subtitleLabel.hidden = YES;
    }
    [self presentCardForDuration:3.2];
}

- (void)showVolume:(NSInteger)volume muted:(BOOL)muted {
    _logoView.hidden = YES;
    _subtitleLabel.hidden = YES;
    _titleLabel.stringValue = muted
        ? @"ミュート"
        : [NSString stringWithFormat:@"音量  %ld%%", (long)volume];
    _volumeBar.doubleValue = muted ? 0.0 : (double)volume;
    _volumeBar.hidden = NO;
    [self presentCardForDuration:1.8];
}

@end
