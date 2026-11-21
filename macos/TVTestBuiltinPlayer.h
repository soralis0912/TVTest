// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestPlaybackPlugin.h"

NS_ASSUME_NONNULL_BEGIN

// Built-in native macOS playback engine for TVTest so TVTest runs completely
// standalone without requiring TvtPlay.bundle. Uses runtime-loaded libvlc.dylib
// (e.g. from /Applications/VLC.app) when available, and degrades gracefully to a
// live-tuner/analysis-capable placeholder surface if VLC is not installed.
@interface TVTestBuiltinPlayer : NSObject <TVTestPlaybackPlugin>
@property (nonatomic, readonly) BOOL hasVideoEngine;
@end

NS_ASSUME_NONNULL_END
