// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestBuiltinPlayer.h"

#import <dlfcn.h>
#import <os/lock.h>
#import <pthread.h>
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace {

// Minimal LibVLC 3.x C ABI declarations loaded dynamically via dlsym.
struct libvlc_instance_t;
struct libvlc_media_t;
struct libvlc_media_player_t;
struct libvlc_track_description_t {
    int i_id;
    char *psz_name;
    libvlc_track_description_t *p_next;
};

using libvlc_time_t = int64_t;
using libvlc_media_open_cb = int (*)(void *opaque, void **datap, uint64_t *sizep);
using libvlc_media_read_cb = ssize_t (*)(void *opaque, unsigned char *buf, size_t len);
using libvlc_media_seek_cb = int (*)(void *opaque, uint64_t offset);
using libvlc_media_close_cb = void (*)(void *opaque);

constexpr int kVLCStatePlaying = 3;

struct LibVLCApi {
    void *handle = nullptr;
    bool loaded = false;

    libvlc_instance_t *(*v_new)(int, const char *const *) = nullptr;
    void (*v_release)(libvlc_instance_t *) = nullptr;
    void (*v_log_set_file)(libvlc_instance_t *, FILE *) = nullptr;
    libvlc_media_player_t *(*mp_new)(libvlc_instance_t *) = nullptr;
    void (*mp_release)(libvlc_media_player_t *) = nullptr;
    void (*mp_set_nsobject)(libvlc_media_player_t *, void *) = nullptr;
    void (*mp_set_media)(libvlc_media_player_t *, libvlc_media_t *) = nullptr;
    int (*mp_play)(libvlc_media_player_t *) = nullptr;
    void (*mp_pause)(libvlc_media_player_t *) = nullptr;
    void (*mp_stop)(libvlc_media_player_t *) = nullptr;
    int (*mp_get_state)(libvlc_media_player_t *) = nullptr;
    libvlc_time_t (*mp_get_time)(libvlc_media_player_t *) = nullptr;
    void (*mp_set_time)(libvlc_media_player_t *, libvlc_time_t) = nullptr;
    libvlc_time_t (*mp_get_length)(libvlc_media_player_t *) = nullptr;
    float (*mp_get_position)(libvlc_media_player_t *) = nullptr;
    void (*mp_set_position)(libvlc_media_player_t *, float) = nullptr;
    float (*mp_get_rate)(libvlc_media_player_t *) = nullptr;
    int (*mp_set_rate)(libvlc_media_player_t *, float) = nullptr;

    libvlc_media_t *(*m_new_path)(libvlc_instance_t *, const char *) = nullptr;
    libvlc_media_t *(*m_new_location)(libvlc_instance_t *, const char *) = nullptr;
    libvlc_media_t *(*m_new_callbacks)(libvlc_instance_t *,
                                       libvlc_media_open_cb,
                                       libvlc_media_read_cb,
                                       libvlc_media_seek_cb,
                                       libvlc_media_close_cb,
                                       void *) = nullptr;
    void (*m_add_option)(libvlc_media_t *, const char *) = nullptr;
    void (*m_release)(libvlc_media_t *) = nullptr;

    int (*a_get_volume)(libvlc_media_player_t *) = nullptr;
    int (*a_set_volume)(libvlc_media_player_t *, int) = nullptr;
    int (*a_get_mute)(libvlc_media_player_t *) = nullptr;
    void (*a_set_mute)(libvlc_media_player_t *, int) = nullptr;
    libvlc_track_description_t *(*a_get_track_description)(libvlc_media_player_t *) = nullptr;
    int (*a_get_track)(libvlc_media_player_t *) = nullptr;
    int (*a_set_track)(libvlc_media_player_t *, int) = nullptr;
    void (*track_desc_release)(libvlc_track_description_t *) = nullptr;
    int (*a_set_channel)(libvlc_media_player_t *, int) = nullptr;

    int (*vid_get_size)(libvlc_media_player_t *, unsigned, unsigned *, unsigned *) = nullptr;
    void (*vid_set_aspect_ratio)(libvlc_media_player_t *, const char *) = nullptr;
    void (*vid_set_crop_geometry)(libvlc_media_player_t *, const char *) = nullptr;
    void (*vid_set_deinterlace)(libvlc_media_player_t *, const char *) = nullptr;
    int (*vid_take_snapshot)(libvlc_media_player_t *, unsigned, const char *, unsigned, unsigned) = nullptr;

    bool Load() {
        if (loaded) return true;

        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *appFrameworks = NSBundle.mainBundle.privateFrameworksPath;
        if (appFrameworks.length) {
            [candidates addObject:[appFrameworks stringByAppendingPathComponent:@"libvlc.dylib"]];
        }
        [candidates addObjectsFromArray:@[
            @"/Applications/VLC.app/Contents/MacOS/lib/libvlc.dylib",
            @"/opt/homebrew/lib/libvlc.dylib",
            @"/usr/local/lib/libvlc.dylib",
        ]];

        for (NSString *path in candidates) {
            if ([NSFileManager.defaultManager isReadableFileAtPath:path]) {
                NSString *dir = [path stringByDeletingLastPathComponent];
                NSString *pluginsDir = [[dir stringByDeletingLastPathComponent]
                    stringByAppendingPathComponent:@"plugins"];
                if ([NSFileManager.defaultManager fileExistsAtPath:pluginsDir]) {
                    setenv("VLC_PLUGIN_PATH", pluginsDir.fileSystemRepresentation, 1);
                }
                // Preload libvlccore from the same directory if present
                NSString *core = [dir stringByAppendingPathComponent:@"libvlccore.dylib"];
                if ([NSFileManager.defaultManager isReadableFileAtPath:core]) {
                    dlopen(core.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
                }
                handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
                if (handle) {
                    break;
                }
            }
        }
        if (!handle) {
            return false;
        }

#define LOAD_SYM(field, name)                                                  \
    do {                                                                       \
        field = reinterpret_cast<decltype(field)>(dlsym(handle, name));        \
        if (!field) return false;                                              \
    } while (0)

        LOAD_SYM(v_new, "libvlc_new");
        LOAD_SYM(v_release, "libvlc_release");
        v_log_set_file = reinterpret_cast<decltype(v_log_set_file)>(dlsym(handle, "libvlc_log_set_file"));
        LOAD_SYM(mp_new, "libvlc_media_player_new");
        LOAD_SYM(mp_release, "libvlc_media_player_release");
        LOAD_SYM(mp_set_nsobject, "libvlc_media_player_set_nsobject");
        LOAD_SYM(mp_set_media, "libvlc_media_player_set_media");
        LOAD_SYM(mp_play, "libvlc_media_player_play");
        LOAD_SYM(mp_pause, "libvlc_media_player_pause");
        LOAD_SYM(mp_stop, "libvlc_media_player_stop");
        LOAD_SYM(mp_get_state, "libvlc_media_player_get_state");
        LOAD_SYM(mp_get_time, "libvlc_media_player_get_time");
        LOAD_SYM(mp_set_time, "libvlc_media_player_set_time");
        LOAD_SYM(mp_get_length, "libvlc_media_player_get_length");
        LOAD_SYM(mp_get_position, "libvlc_media_player_get_position");
        LOAD_SYM(mp_set_position, "libvlc_media_player_set_position");
        LOAD_SYM(mp_get_rate, "libvlc_media_player_get_rate");
        LOAD_SYM(mp_set_rate, "libvlc_media_player_set_rate");

        LOAD_SYM(m_new_path, "libvlc_media_new_path");
        LOAD_SYM(m_new_location, "libvlc_media_new_location");
        LOAD_SYM(m_new_callbacks, "libvlc_media_new_callbacks");
        LOAD_SYM(m_add_option, "libvlc_media_add_option");
        LOAD_SYM(m_release, "libvlc_media_release");

        LOAD_SYM(a_get_volume, "libvlc_audio_get_volume");
        LOAD_SYM(a_set_volume, "libvlc_audio_set_volume");
        LOAD_SYM(a_get_mute, "libvlc_audio_get_mute");
        LOAD_SYM(a_set_mute, "libvlc_audio_set_mute");
        LOAD_SYM(a_get_track_description, "libvlc_audio_get_track_description");
        LOAD_SYM(a_get_track, "libvlc_audio_get_track");
        LOAD_SYM(a_set_track, "libvlc_audio_set_track");
        LOAD_SYM(track_desc_release, "libvlc_track_description_list_release");
        LOAD_SYM(a_set_channel, "libvlc_audio_set_channel");

        LOAD_SYM(vid_get_size, "libvlc_video_get_size");
        LOAD_SYM(vid_set_aspect_ratio, "libvlc_video_set_aspect_ratio");
        LOAD_SYM(vid_set_crop_geometry, "libvlc_video_set_crop_geometry");
        LOAD_SYM(vid_set_deinterlace, "libvlc_video_set_deinterlace");
        LOAD_SYM(vid_take_snapshot, "libvlc_video_take_snapshot");
#undef LOAD_SYM

        loaded = true;
        return true;
    }
};

static LibVLCApi &SharedVLC() {
    static LibVLCApi api;
    return api;
}

static constexpr size_t kLiveRingCapacity = 4 * 1024 * 1024;

static NSError *BuiltinPlayerError(NSString *msg) {
    return [NSError errorWithDomain:@"jp.tvtest.macos.player"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

} // namespace

@interface TVTestBuiltinLiveRingBuffer : NSObject
- (void)pushBytes:(const uint8_t *)bytes length:(size_t)length;
- (ssize_t)readBytes:(unsigned char *)buf maxLength:(size_t)len;
- (void)purge;
- (void)close;
@end

@implementation TVTestBuiltinLiveRingBuffer {
    uint8_t *_buf;
    size_t _capacity;
    size_t _head;
    size_t _tail;
    size_t _size;
    BOOL _closed;
    pthread_mutex_t _lock;
    pthread_cond_t _cond;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _capacity = kLiveRingCapacity;
        _buf = static_cast<uint8_t *>(std::malloc(_capacity));
        pthread_mutex_init(&_lock, nullptr);
        pthread_cond_init(&_cond, nullptr);
    }
    return self;
}

- (void)dealloc {
    pthread_mutex_destroy(&_lock);
    pthread_cond_destroy(&_cond);
    std::free(_buf);
}

- (void)pushBytes:(const uint8_t *)bytes length:(size_t)length {
    if (!bytes || length == 0 || !_buf) return;
    pthread_mutex_lock(&_lock);
    if (_closed) {
        pthread_mutex_unlock(&_lock);
        return;
    }
    if (length >= _capacity) {
        const size_t keep = (_capacity / 188) * 188;
        std::memcpy(_buf, bytes + (length - keep), keep);
        _head = 0;
        _tail = keep % _capacity;
        _size = keep;
    } else {
        if (_size + length > _capacity) {
            size_t drop = ((_size + length - _capacity + 187) / 188) * 188;
            if (drop > _size) drop = _size;
            _head = (_head + drop) % _capacity;
            _size -= drop;
        }
        const size_t first = std::min(_capacity - _tail, length);
        std::memcpy(_buf + _tail, bytes, first);
        if (length > first) {
            std::memcpy(_buf, bytes + first, length - first);
        }
        _tail = (_tail + length) % _capacity;
        _size += length;
    }
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_lock);
}

- (ssize_t)readBytes:(unsigned char *)buf maxLength:(size_t)len {
    if (!buf || len == 0 || !_buf) return 0;
    pthread_mutex_lock(&_lock);
    while (_size == 0 && !_closed) {
        pthread_cond_wait(&_cond, &_lock);
    }
    if (_size == 0 && _closed) {
        pthread_mutex_unlock(&_lock);
        return 0;
    }
    const size_t toRead = std::min(_size, len);
    const size_t first = std::min(_capacity - _head, toRead);
    std::memcpy(buf, _buf + _head, first);
    if (toRead > first) {
        std::memcpy(buf + first, _buf, toRead - first);
    }
    _head = (_head + toRead) % _capacity;
    _size -= toRead;
    pthread_mutex_unlock(&_lock);
    return static_cast<ssize_t>(toRead);
}

- (void)purge {
    pthread_mutex_lock(&_lock);
    _head = 0;
    _tail = 0;
    _size = 0;
    pthread_mutex_unlock(&_lock);
}

- (void)close {
    pthread_mutex_lock(&_lock);
    _closed = YES;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_lock);
}

@end

static int BuiltinLiveOpenCB(void *opaque, void **datap, uint64_t *sizep) {
    TVTestBuiltinLiveRingBuffer *ring = (__bridge TVTestBuiltinLiveRingBuffer *)opaque;
    if (!ring) return -1;
    *datap = (void *)CFBridgingRetain(ring);
    *sizep = UINT64_MAX;
    return 0;
}

static ssize_t BuiltinLiveReadCB(void *opaque, unsigned char *buf, size_t len) {
    TVTestBuiltinLiveRingBuffer *ring = (__bridge TVTestBuiltinLiveRingBuffer *)opaque;
    return ring ? [ring readBytes:buf maxLength:len] : 0;
}

static void BuiltinLiveCloseCB(void *opaque) {
    if (opaque) {
        CFBridgingRelease(opaque);
    }
}

@interface TVTestBuiltinOverlayContainer : NSView
@end

@implementation TVTestBuiltinOverlayContainer
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

@implementation TVTestBuiltinPlayer {
    libvlc_instance_t *_engine;
    libvlc_media_player_t *_player;
    NSView *_view;
    NSView *_video;
    NSView *_videoOverlay;
    NSTextField *_placeholderLabel;
    NSTimer *_timer;
    os_unfair_lock _liveBufferLock;
    TVTestBuiltinLiveRingBuffer *_liveBuffer;
    BOOL _hasMedia;
    BOOL _isLiveStream;
    BOOL _controlsHidden;
    double _pendingSeekPosition;
    float _desiredRate;
    NSInteger _desiredVolume;
    BOOL _desiredMuted;
    NSString *_aspectRatio;
    NSString *_cropGeometry;
    NSString *_deinterlaceMode;
    TVTestAudioChannelMode _audioChannelMode;
}

@synthesize delegate = _delegate;

+ (NSUInteger)apiVersion {
    return TVTestPlaybackPluginAPIVersion;
}

+ (nullable instancetype)newWithError:(NSError **)error {
    return [[self alloc] initWithError:error];
}

- (instancetype)initWithError:(NSError **)error {
    (void)error;
    self = [super init];
    if (!self) return nil;

    _pendingSeekPosition = -1.0;
    _desiredRate = 1.0f;
    _desiredVolume = 100;
    _audioChannelMode = TVTestAudioChannelModeStereo;
    _liveBufferLock = OS_UNFAIR_LOCK_INIT;

    [self buildView];

    if (SharedVLC().Load()) {
        const BOOL verbose = [NSProcessInfo.processInfo.environment[@"TVTEST_VLC_VERBOSE"] isEqualToString:@"1"];
        const char *opts[] = {"--ignore-config", "--no-video-title-show", "--verbose=2"};
        _engine = SharedVLC().v_new(verbose ? 3 : 2, opts);
        if (_engine) {
            if (verbose && SharedVLC().v_log_set_file) {
                SharedVLC().v_log_set_file(_engine, stderr);
            }
            _player = SharedVLC().mp_new(_engine);
            if (_player) {
                SharedVLC().mp_set_nsobject(_player, (__bridge void *)_video);
                _placeholderLabel.hidden = YES;
            }
        }
    }

    __weak TVTestBuiltinPlayer *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf tick];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [self closeLiveStream];
    if (_player) {
        SharedVLC().mp_stop(_player);
        SharedVLC().mp_release(_player);
    }
    if (_engine) {
        SharedVLC().v_release(_engine);
    }
}

- (void)buildView {
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 450)];
    _view.wantsLayer = YES;
    _view.layer.backgroundColor = NSColor.blackColor.CGColor;

    _video = [[NSView alloc] initWithFrame:_view.bounds];
    _video.wantsLayer = YES;
    _video.layer.backgroundColor = NSColor.blackColor.CGColor;
    _video.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_video];

    _videoOverlay = [[TVTestBuiltinOverlayContainer alloc] initWithFrame:_view.bounds];
    _videoOverlay.wantsLayer = YES;
    _videoOverlay.layer.backgroundColor = NSColor.clearColor.CGColor;
    _videoOverlay.layer.zPosition = 100.0;
    _videoOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_videoOverlay positioned:NSWindowAbove relativeTo:_video];

    _placeholderLabel = [NSTextField wrappingLabelWithString:
        @"映像再生エンジン (VLC.app / libvlc.dylib) が見つかりません。\n"
        @"VLC を /Applications/VLC.app にインストールすると映像・音声を再生できます。\n"
        @"（チューナー選局・B-CAS・EPG・録画機能はそのまま利用可能です）"];
    _placeholderLabel.alignment = NSTextAlignmentCenter;
    _placeholderLabel.font = [NSFont systemFontOfSize:13.0];
    _placeholderLabel.textColor = [NSColor colorWithWhite:0.75 alpha:1.0];
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_videoOverlay addSubview:_placeholderLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_video.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [_video.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
        [_video.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_video.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_videoOverlay.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [_videoOverlay.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
        [_videoOverlay.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_videoOverlay.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_videoOverlay.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_videoOverlay.centerYAnchor],
        [_placeholderLabel.widthAnchor constraintLessThanOrEqualToAnchor:_videoOverlay.widthAnchor multiplier:0.8],
    ]];
}

- (void)tick {
    if (_player && _pendingSeekPosition >= 0.0 && SharedVLC().mp_get_state(_player) == kVLCStatePlaying) {
        SharedVLC().mp_set_position(_player, static_cast<float>(_pendingSeekPosition));
        _pendingSeekPosition = -1.0;
    }
    if ([_delegate respondsToSelector:@selector(playbackPluginDidUpdateState:)]) {
        [_delegate playbackPluginDidUpdateState:self];
    }
}

- (BOOL)hasVideoEngine { return _player != nullptr; }
- (NSView *)view { return _view; }
- (NSView *)videoOverlayView { return _videoOverlay; }
- (BOOL)isPlaying { return _player && SharedVLC().mp_get_state(_player) == kVLCStatePlaying; }
- (BOOL)isLiveStream { return _isLiveStream; }
- (int64_t)playbackTimeMs { return (_player && _hasMedia) ? SharedVLC().mp_get_time(_player) : -1; }
- (int64_t)durationMs { return (_player && _hasMedia) ? SharedVLC().mp_get_length(_player) : -1; }

- (double)playbackPosition {
    if (!_player || !_hasMedia) return 0.0;
    float p = SharedVLC().mp_get_position(_player);
    return p >= 0.0f ? (double)p : 0.0;
}

- (float)playbackRate {
    if (!_player) return _desiredRate;
    float r = SharedVLC().mp_get_rate(_player);
    return r > 0.0f ? r : _desiredRate;
}

- (NSInteger)volume {
    if (!_player) return _desiredVolume;
    int v = SharedVLC().a_get_volume(_player);
    return v >= 0 ? v : _desiredVolume;
}

- (BOOL)muted {
    if (!_player) return _desiredMuted;
    return SharedVLC().a_get_mute(_player) > 0;
}

- (NSSize)videoSize {
    if (!_player || !_hasMedia) return NSZeroSize;
    unsigned w = 0, h = 0;
    if (SharedVLC().vid_get_size(_player, 0, &w, &h) == 0 && w > 0 && h > 0) {
        return NSMakeSize(w, h);
    }
    return NSZeroSize;
}

- (nullable NSString *)aspectRatio { return _aspectRatio; }
- (nullable NSString *)cropGeometry { return _cropGeometry; }
- (nullable NSString *)deinterlaceMode { return _deinterlaceMode; }
- (TVTestAudioChannelMode)audioChannelMode { return _audioChannelMode; }
- (BOOL)controlsHidden { return _controlsHidden; }
- (void)setControlsHidden:(BOOL)controlsHidden { _controlsHidden = controlsHidden; }

- (NSArray<NSDictionary<NSString *, id> *> *)audioTracks {
    NSMutableArray *list = [NSMutableArray array];
    if (!_player) return list;
    libvlc_track_description_t *head = SharedVLC().a_get_track_description(_player);
    for (libvlc_track_description_t *cur = head; cur != nullptr; cur = cur->p_next) {
        if (cur->i_id < 0) continue;
        NSString *name = cur->psz_name
            ? ([NSString stringWithUTF8String:cur->psz_name] ?: @"音声")
            : [NSString stringWithFormat:@"Track %d", cur->i_id];
        [list addObject:@{@"id": @(cur->i_id), @"name": name}];
    }
    if (head) SharedVLC().track_desc_release(head);
    return list;
}

- (NSInteger)currentAudioTrackID {
    return _player ? SharedVLC().a_get_track(_player) : -1;
}

- (void)applyStoredVideoAudioOptions {
    if (!_player) return;
    SharedVLC().a_set_volume(_player, static_cast<int>(_desiredVolume));
    SharedVLC().a_set_mute(_player, _desiredMuted ? 1 : 0);
    SharedVLC().a_set_channel(_player, static_cast<int>(_audioChannelMode));
    SharedVLC().vid_set_aspect_ratio(_player, _aspectRatio.length ? _aspectRatio.UTF8String : nullptr);
    SharedVLC().vid_set_crop_geometry(_player, _cropGeometry.length ? _cropGeometry.UTF8String : nullptr);
    SharedVLC().vid_set_deinterlace(_player, _deinterlaceMode.length ? _deinterlaceMode.UTF8String : nullptr);
}

- (BOOL)openRecording:(NSURL *)url error:(NSError **)error {
    return [self openRecording:url serviceID:0 startPosition:0.0 error:error];
}

- (BOOL)openRecording:(NSURL *)url
            serviceID:(NSInteger)serviceID
        startPosition:(double)position
                error:(NSError **)error {
    [self closeLiveStream];
    if (!_player) {
        if (error) *error = BuiltinPlayerError(@"VLC.app が見つからないため映像再生できません。");
        return NO;
    }
    libvlc_media_t *media = url.isFileURL
        ? SharedVLC().m_new_path(_engine, url.fileSystemRepresentation)
        : SharedVLC().m_new_location(_engine, url.absoluteString.UTF8String);
    if (!media) {
        if (error) *error = BuiltinPlayerError(@"録画メディアを開けませんでした。");
        return NO;
    }
    if (serviceID > 0) {
        NSString *opt = [NSString stringWithFormat:@":program=%ld", (long)serviceID];
        SharedVLC().m_add_option(media, opt.UTF8String);
    }
    SharedVLC().mp_set_media(_player, media);
    SharedVLC().m_release(media);

    _isLiveStream = NO;
    _hasMedia = YES;
    _pendingSeekPosition = (position > 0.0 && position < 1.0) ? position : -1.0;

    if (SharedVLC().mp_play(_player) != 0) {
        if (error) *error = BuiltinPlayerError(@"再生の開始に失敗しました。");
        return NO;
    }
    SharedVLC().mp_set_rate(_player, _desiredRate);
    [self applyStoredVideoAudioOptions];
    return YES;
}

- (BOOL)openLiveStreamWithServiceID:(NSInteger)serviceID error:(NSError **)error {
    [self closeLiveStream];
    if (!_player) {
        // Still allow headless tuning/recording without VLC installed
        _isLiveStream = YES;
        _hasMedia = NO;
        return YES;
    }
    TVTestBuiltinLiveRingBuffer *ring = [[TVTestBuiltinLiveRingBuffer alloc] init];
    libvlc_media_t *media = SharedVLC().m_new_callbacks(
        _engine, BuiltinLiveOpenCB, BuiltinLiveReadCB, nullptr, BuiltinLiveCloseCB,
        (__bridge void *)ring);
    if (!media) {
        if (error) *error = BuiltinPlayerError(@"ライブストリーム用メディアを作成できませんでした。");
        return NO;
    }
    SharedVLC().m_add_option(media, ":demux=ts");
    SharedVLC().m_add_option(media, ":live-caching=350");
    if (serviceID > 0) {
        NSString *opt = [NSString stringWithFormat:@":program=%ld", (long)serviceID];
        SharedVLC().m_add_option(media, opt.UTF8String);
    }
    SharedVLC().mp_set_media(_player, media);
    SharedVLC().m_release(media);

    os_unfair_lock_lock(&_liveBufferLock);
    _liveBuffer = ring;
    os_unfair_lock_unlock(&_liveBufferLock);
    _isLiveStream = YES;
    _hasMedia = YES;
    _pendingSeekPosition = -1.0;

    if (SharedVLC().mp_play(_player) != 0) {
        [self closeLiveStream];
        if (error) *error = BuiltinPlayerError(@"ライブストリームの再生開始に失敗しました。");
        return NO;
    }
    [self applyStoredVideoAudioOptions];
    return YES;
}

- (void)pushLiveTSBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    os_unfair_lock_lock(&_liveBufferLock);
    TVTestBuiltinLiveRingBuffer *ring = _liveBuffer;
    os_unfair_lock_unlock(&_liveBufferLock);
    if (ring) {
        [ring pushBytes:bytes length:length];
    }
}

- (void)purgeLiveStream {
    os_unfair_lock_lock(&_liveBufferLock);
    TVTestBuiltinLiveRingBuffer *ring = _liveBuffer;
    os_unfair_lock_unlock(&_liveBufferLock);
    if (ring) {
        [ring purge];
    }
}

- (void)closeLiveStream {
    os_unfair_lock_lock(&_liveBufferLock);
    TVTestBuiltinLiveRingBuffer *ring = _liveBuffer;
    _liveBuffer = nil;
    os_unfair_lock_unlock(&_liveBufferLock);
    if (ring) {
        [ring close];
    }
    if (_player && _isLiveStream) {
        SharedVLC().mp_stop(_player);
    }
    _isLiveStream = NO;
    _hasMedia = NO;
}

- (void)togglePlayPause {
    if (!_player) return;
    if (SharedVLC().mp_get_state(_player) == kVLCStatePlaying) {
        SharedVLC().mp_pause(_player);
    } else {
        SharedVLC().mp_play(_player);
    }
}

- (void)stop {
    if (_isLiveStream) {
        [self closeLiveStream];
    } else if (_player) {
        SharedVLC().mp_stop(_player);
        _hasMedia = NO;
    }
}

- (void)seekToTimeMs:(int64_t)timeMs {
    if (_player && !_isLiveStream) {
        SharedVLC().mp_set_time(_player, MAX((int64_t)0, timeMs));
    }
}

- (void)seekByMs:(int64_t)deltaMs {
    if (_player && !_isLiveStream) {
        int64_t cur = SharedVLC().mp_get_time(_player);
        if (cur >= 0) {
            SharedVLC().mp_set_time(_player, MAX((int64_t)0, cur + deltaMs));
        }
    }
}

- (void)setPlaybackRate:(float)rate {
    _desiredRate = rate;
    if (_player && !_isLiveStream) {
        SharedVLC().mp_set_rate(_player, rate);
    }
}

- (void)setVolume:(NSInteger)volume {
    _desiredVolume = MAX((NSInteger)0, MIN((NSInteger)100, volume));
    if (_player) SharedVLC().a_set_volume(_player, static_cast<int>(_desiredVolume));
}

- (void)setMuted:(BOOL)muted {
    _desiredMuted = muted;
    if (_player) SharedVLC().a_set_mute(_player, muted ? 1 : 0);
}

- (BOOL)selectAudioTrackID:(NSInteger)trackID {
    if (!_player) return NO;
    return SharedVLC().a_set_track(_player, static_cast<int>(trackID)) == 0;
}

- (BOOL)setAudioChannelMode:(TVTestAudioChannelMode)mode {
    _audioChannelMode = mode;
    if (!_player) return NO;
    return SharedVLC().a_set_channel(_player, static_cast<int>(mode)) == 0;
}

- (void)setAspectRatio:(nullable NSString *)aspectRatio {
    _aspectRatio = [aspectRatio copy];
    if (_player) {
        SharedVLC().vid_set_aspect_ratio(_player, _aspectRatio.length ? _aspectRatio.UTF8String : nullptr);
    }
}

- (void)setCropGeometry:(nullable NSString *)cropGeometry {
    _cropGeometry = [cropGeometry copy];
    if (_player) {
        SharedVLC().vid_set_crop_geometry(_player, _cropGeometry.length ? _cropGeometry.UTF8String : nullptr);
    }
}

- (void)setDeinterlaceMode:(nullable NSString *)mode {
    _deinterlaceMode = [mode copy];
    if (_player) {
        SharedVLC().vid_set_deinterlace(_player, _deinterlaceMode.length ? _deinterlaceMode.UTF8String : nullptr);
    }
}

- (BOOL)takeSnapshotToURL:(NSURL *)outputURL error:(NSError **)error {
    if (!_player || !_hasMedia) {
        if (error) *error = BuiltinPlayerError(@"再生中の映像がありません。");
        return NO;
    }
    if (SharedVLC().vid_take_snapshot(_player, 0, outputURL.fileSystemRepresentation, 0, 0) != 0) {
        if (error) *error = BuiltinPlayerError(@"スナップショットの保存に失敗しました。");
        return NO;
    }
    return YES;
}

@end
