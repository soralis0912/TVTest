// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestPlaybackPlugin.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TVTestApp : NSObject <NSApplicationDelegate>
@end

@implementation TVTestApp {
    NSWindow *_window;
    id<TVTestPlaybackPlugin> _plugin;
    NSURL *_pendingRecording;
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
    _window.title = [NSString stringWithFormat:@"%@ — TVTest", url.lastPathComponent];
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
