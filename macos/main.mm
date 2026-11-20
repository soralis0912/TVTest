// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestPlaybackPlugin.h"
#import "RecordingInfo.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TVTestApp : NSObject <NSApplicationDelegate>
@end

@implementation TVTestApp {
    NSWindow *_window;
    id<TVTestPlaybackPlugin> _plugin;
    NSURL *_pendingRecording;
    NSURL *_recording;
    NSProgress *_infoJob;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [menu addItemWithTitle:@"TVTest" action:nil keyEquivalent:@""];
    appItem.submenu = [[NSMenu alloc] initWithTitle:@"TVTest"];
    [appItem.submenu addItemWithTitle:@"TVTest を終了" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *fileItem = [menu addItemWithTitle:@"ファイル" action:nil keyEquivalent:@""];
    fileItem.submenu = [[NSMenu alloc] initWithTitle:@"ファイル"];
    NSMenuItem *open = [fileItem.submenu addItemWithTitle:@"録画を開く…"
                                                    action:@selector(chooseRecording:)
                                             keyEquivalent:@"o"];
    open.target = self;
    NSMenuItem *info = [fileItem.submenu addItemWithTitle:@"番組情報…"
                                                    action:@selector(showRecordingInfo:)
                                             keyEquivalent:@"i"];
    info.target = self;
    NSApp.mainMenu = menu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 580)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                           backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"TVTest";
    _window.contentMinSize = NSMakeSize(560, 300);
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSURL *bundleURL = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"TvtPlay.bundle"];
    NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
    NSError *error = nil;
    if (![bundle loadAndReturnError:&error]) {
        [self showError:error.localizedDescription ?: @"アプリ内に TvtPlay.bundle がありません。"];
        return;
    }

    Class<TVTestPlaybackPlugin> playerClass = bundle.principalClass;
    if (![playerClass conformsToProtocol:@protocol(TVTestPlaybackPlugin)] ||
        [playerClass apiVersion] != TVTestPlaybackPluginAPIVersion) {
        [self showError:@"TvtPlay のプラグイン API バージョンが一致しません。"];
        return;
    }
    _plugin = [playerClass newWithError:&error];
    if (!_plugin) {
        [self showError:error.localizedDescription ?: @"TvtPlay を初期化できませんでした。"];
        return;
    }
    _window.contentView = _plugin.view;

    NSURL *recording = _pendingRecording;
    _pendingRecording = nil;
    if (recording) {
        [self openRecording:recording];
    }
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    NSURL *recording = urls.firstObject;
    if (recording) {
        [self openRecording:recording];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_infoJob cancel];
    _plugin = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    return YES;
}

- (void)chooseRecording:(id)sender {
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
        if (response == NSModalResponseOK) {
            [self openRecording:panel.URL];
        }
    }];
}

- (void)openRecording:(NSURL *)url {
    if (!_window) {
        _pendingRecording = url;
        return;
    }
    NSError *error = nil;
    if (!_plugin || ![_plugin openRecording:url error:&error]) {
        [self showError:error.localizedDescription ?: @"TvtPlay を読み込めませんでした。"];
        return;
    }
    [_infoJob cancel];
    _infoJob = nil;
    _recording = url;
    _window.title = [NSString stringWithFormat:@"%@ — TVTest", url.lastPathComponent];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(showRecordingInfo:)) {
        return _recording && !_infoJob;
    }
    return YES;
}

- (void)showRecordingInfo:(id)sender {
    if (!_recording || _infoJob) {
        return;
    }
    NSURL *recording = _recording;
    NSProgress *job = [NSProgress progressWithTotalUnitCount:0];
    _infoJob = job;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<NSDictionary<NSString *, id> *> *services = TVTestReadRecordingInfo(recording, job, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_infoJob != job) {
                return;
            }
            self->_infoJob = nil;
            if (error) {
                [self showError:error.localizedDescription];
            } else {
                [self presentServices:services forRecording:recording];
            }
        });
    });
}

- (void)presentServices:(NSArray<NSDictionary<NSString *, id> *> *)services forRecording:(NSURL *)recording {
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *service in services) {
        NSString *name = service[@"name"];
        NSString *current = service[@"current"];
        NSString *description = service[@"description"];
        NSString *next = service[@"next"];
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:@"%@ (SID %u)", name.length ? name : @"サービス",
              [service[@"serviceID"] unsignedIntValue]]];
        if (current.length) {
            [lines addObject:[@"現在の番組  " stringByAppendingString:current]];
        }
        if (description.length) {
            [lines addObject:description];
        }
        if (next.length) {
            [lines addObject:[@"次の番組  " stringByAppendingString:next]];
        }
        if (!current.length && !next.length) {
            [lines addObject:@"番組情報が含まれていません。"];
        }
        [sections addObject:[lines componentsJoinedByString:@"\n"]];
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"番組情報";
    alert.informativeText = recording.lastPathComponent;
    [alert addButtonWithTitle:@"閉じる"];
    if (sections.count == 0) {
        alert.informativeText = @"録画の先頭からサービス情報を取得できませんでした。";
    } else {
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 180)];
        scroll.hasVerticalScroller = YES;
        NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
        text.editable = NO;
        text.verticallyResizable = YES;
        text.autoresizingMask = NSViewWidthSizable;
        text.textContainer.widthTracksTextView = YES;
        text.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        text.string = [sections componentsJoinedByString:@"\n\n"];
        scroll.documentView = text;
        alert.accessoryView = scroll;
    }
    [alert beginSheetModalForWindow:_window completionHandler:nil];
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
