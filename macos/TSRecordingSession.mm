// SPDX-License-Identifier: GPL-2.0-or-later
#import "TSRecordingSession.h"

#include "LibISDB.hpp"
#include "Base/FileStream.hpp"
#include "EPG/EPGDataFile.hpp"
#include "EPG/EPGDatabase.hpp"
#include "Filters/AnalyzerFilter.hpp"
#include "Filters/CaptionFilter.hpp"
#include "Filters/EPGDatabaseFilter.hpp"
#include "Filters/LogoDownloaderFilter.hpp"
#include "Filters/ServiceSelectorFilter.hpp"
#include "Filters/TSPacketParserFilter.hpp"
#include "TS/TSInformation.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <vector>

namespace {

constexpr size_t kPacketSize = LibISDB::TS_PACKET_SIZE;
constexpr size_t kProbeBytes = 64 * 1024;
constexpr size_t kReadBytes = 256 * 1024;
constexpr size_t kInitialScanLimit = 16 * 1024 * 1024;
constexpr size_t kPositionWindowBytes = 4 * 1024 * 1024;
constexpr size_t kProgressEmitInterval = 48 * 1024 * 1024;
constexpr int64_t kPTSWrap = 0x200000000LL; // 2^33 (90 kHz)
constexpr int64_t kCaptionAutoExpireMs = 12000;

struct PacketLayout {
    size_t stride = 0;
    size_t offset = 0;
};

PacketLayout DetectPacketLayout(const uint8_t *bytes, size_t length) {
    constexpr size_t syncCount = 5;
    for (size_t offset = 0; offset < length; ++offset) {
        if (bytes[offset] != 0x47) {
            continue;
        }
        for (const size_t stride : {kPacketSize, kPacketSize + 4}) {
            if (length - offset < syncCount * stride - (stride - kPacketSize)) {
                continue;
            }
            size_t index = 1;
            while (index < syncCount && bytes[offset + index * stride] == 0x47) {
                ++index;
            }
            if (index == syncCount) {
                return {stride, offset};
            }
        }
    }
    return {};
}

NSError *MakeSessionError(NSString *message) {
    return [NSError errorWithDomain:@"jp.tvtest.native.session"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *DecodeLibISDBString(const LibISDB::String &text) {
    if (text.empty()) {
        return @"";
    }
    return [[NSString alloc] initWithBytes:text.data()
                                    length:text.size()
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *FormatDateTime(const LibISDB::DateTime &dt) {
    if (!dt.IsValid()) {
        return @"";
    }
    return [NSString stringWithFormat:@"%04d/%02d/%02d %02d:%02d:%02d",
            dt.Year, dt.Month, dt.Day, dt.Hour, dt.Minute, dt.Second];
}

NSString *FormatDateOnly(const LibISDB::DateTime &dt) {
    if (!dt.IsValid()) {
        return @"";
    }
    static NSArray<NSString *> *kWeekdays = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kWeekdays = @[@"日", @"月", @"火", @"水", @"木", @"金", @"土"];
    });
    NSString *wd = (dt.DayOfWeek >= 0 && dt.DayOfWeek < 7) ? kWeekdays[dt.DayOfWeek] : @"";
    return [NSString stringWithFormat:@"%02d/%02d(%@)", dt.Month, dt.Day, wd];
}

NSString *FormatTimeShort(const LibISDB::DateTime &dt) {
    if (!dt.IsValid()) {
        return @"";
    }
    return [NSString stringWithFormat:@"%02d:%02d", dt.Hour, dt.Minute];
}

NSString *FormatTimeRange(const LibISDB::DateTime &start, uint32_t durationSec) {
    if (!start.IsValid()) {
        return @"";
    }
    if (durationSec == 0) {
        return FormatTimeShort(start);
    }
    LibISDB::DateTime end = start;
    end.OffsetSeconds(static_cast<long>(durationSec));
    return [NSString stringWithFormat:@"%@〜%@", FormatTimeShort(start), FormatTimeShort(end)];
}

uint8_t PrimaryGenreLevel1(const LibISDB::EventInfo::ContentNibbleInfo &nibble) {
    if (nibble.NibbleCount <= 0) {
        return 0xFF;
    }
    return nibble.NibbleList[0].ContentNibbleLevel1;
}

NSString *GenreTextForLevel1(uint8_t l1) {
    static const char *const kGenres[16] = {
        "ニュース／報道",
        "スポーツ",
        "情報／ワイドショー",
        "ドラマ",
        "音楽",
        "バラエティ",
        "映画",
        "アニメ／特撮",
        "ドキュメンタリー／教養",
        "劇場／公演",
        "趣味／教育",
        "福祉",
        "予備",
        "予備",
        "拡張",
        "その他",
    };
    if (l1 < 16) {
        return [NSString stringWithUTF8String:kGenres[l1]] ?: @"";
    }
    return @"";
}

NSString *FormatExtendedTextList(const LibISDB::EventInfo::ExtendedTextInfoList &list) {
    if (list.empty()) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:list.size()];
    for (const auto &item : list) {
        NSString *desc = DecodeLibISDBString(item.Description);
        NSString *text = DecodeLibISDBString(item.Text);
        if (desc.length && text.length) {
            [parts addObject:[NSString stringWithFormat:@"【%@】\n%@", desc, text]];
        } else if (text.length) {
            [parts addObject:text];
        } else if (desc.length) {
            [parts addObject:[NSString stringWithFormat:@"【%@】", desc]];
        }
    }
    return [parts componentsJoinedByString:@"\n\n"];
}

int64_t DiffPTS90k(int64_t current, int64_t base) {
    int64_t diff = current - base;
    if (diff < -(kPTSWrap / 2)) {
        diff += kPTSWrap;
    } else if (diff > (kPTSWrap / 2)) {
        diff -= kPTSWrap;
    }
    return diff;
}

uint64_t ReadFirstPCR90k(LibISDB::AnalyzerFilter &analyzer) {
    const int count = analyzer.GetServiceCount();
    for (int i = 0; i < count; ++i) {
        const uint64_t pcr = analyzer.GetPCRTimeStamp(i);
        if (pcr != LibISDB::PCR_INVALID) {
            return pcr;
        }
    }
    return LibISDB::PCR_INVALID;
}

bool ExtractPacketPCR90k(const uint8_t *pkt, uint64_t &outPCR90k) {
    if (pkt[0] != 0x47 || (pkt[3] & 0x20) == 0) {
        return false;
    }
    const uint8_t afLen = pkt[4];
    if (afLen < 7 || afLen > 183 || (pkt[5] & 0x10) == 0) {
        return false;
    }
    outPCR90k =
        (static_cast<uint64_t>(pkt[6]) << 25) |
        (static_cast<uint64_t>(pkt[7]) << 17) |
        (static_cast<uint64_t>(pkt[8]) << 9) |
        (static_cast<uint64_t>(pkt[9]) << 1) |
        (static_cast<uint64_t>(pkt[10]) >> 7);
    return true;
}

NSString *FormatSRTTimestamp(int64_t ms) {
    int64_t clamped = std::max<int64_t>(0, ms);
    int64_t h = clamped / 3600000;
    int64_t m = (clamped / 60000) % 60;
    int64_t s = (clamped / 1000) % 60;
    int64_t rem = clamped % 1000;
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld,%03lld", h, m, s, rem];
}

} // namespace

@interface TVTestAudioStreamInfo ()
- (instancetype)initWithPID:(uint16_t)pid
                 streamType:(uint8_t)streamType
               componentTag:(uint8_t)componentTag
                      label:(NSString *)label;
@end

@implementation TVTestAudioStreamInfo
- (instancetype)initWithPID:(uint16_t)pid
                 streamType:(uint8_t)streamType
               componentTag:(uint8_t)componentTag
                      label:(NSString *)label {
    self = [super init];
    if (self) {
        _pid = pid;
        _streamType = streamType;
        _componentTag = componentTag;
        _label = [label copy];
    }
    return self;
}
@end

@interface TVTestESDetail ()
- (instancetype)initWithPID:(uint16_t)pid
                 streamType:(uint8_t)streamType
             streamTypeName:(NSString *)streamTypeName
                   category:(NSString *)category;
@end

@implementation TVTestESDetail
- (instancetype)initWithPID:(uint16_t)pid
                 streamType:(uint8_t)streamType
             streamTypeName:(NSString *)streamTypeName
                   category:(NSString *)category {
    self = [super init];
    if (self) {
        _pid = pid;
        _streamType = streamType;
        _streamTypeName = [streamTypeName copy];
        _category = [category copy];
    }
    return self;
}
@end

@interface TVTestProgramInfo ()
- (instancetype)initWithEventID:(uint16_t)eventID
                          title:(NSString *)title
                descriptionText:(NSString *)descriptionText
                   extendedText:(NSString *)extendedText
                  startTimeText:(NSString *)startTimeText
                    endTimeText:(NSString *)endTimeText
                durationSeconds:(uint32_t)durationSeconds
                    genreLevel1:(uint8_t)genreLevel1
                      genreText:(NSString *)genreText
                  videoSpecText:(NSString *)videoSpecText
                  audioSpecText:(NSString *)audioSpecText;
@end

@implementation TVTestProgramInfo
- (instancetype)initWithEventID:(uint16_t)eventID
                          title:(NSString *)title
                descriptionText:(NSString *)descriptionText
                   extendedText:(NSString *)extendedText
                  startTimeText:(NSString *)startTimeText
                    endTimeText:(NSString *)endTimeText
                durationSeconds:(uint32_t)durationSeconds
                    genreLevel1:(uint8_t)genreLevel1
                      genreText:(NSString *)genreText
                  videoSpecText:(NSString *)videoSpecText
                  audioSpecText:(NSString *)audioSpecText {
    self = [super init];
    if (self) {
        _eventID = eventID;
        _title = [title copy];
        _descriptionText = [descriptionText copy];
        _extendedText = [extendedText copy];
        _startTimeText = [startTimeText copy];
        _endTimeText = [endTimeText copy];
        _durationSeconds = durationSeconds;
        _genreLevel1 = genreLevel1;
        _genreText = [genreText copy];
        _videoSpecText = [videoSpecText copy];
        _audioSpecText = [audioSpecText copy];
    }
    return self;
}
@end

@interface TVTestServiceInfo ()
- (instancetype)initWithServiceID:(uint16_t)serviceID
                           pmtPID:(uint16_t)pmtPID
                           pcrPID:(uint16_t)pcrPID
                      serviceType:(uint8_t)serviceType
                             name:(NSString *)name
                     providerName:(NSString *)providerName
                     videoESCount:(NSUInteger)videoESCount
                     audioStreams:(NSArray<TVTestAudioStreamInfo *> *)audioStreams
                elementaryStreams:(NSArray<TVTestESDetail *> *)elementaryStreams
                      hasCaptions:(BOOL)hasCaptions
                   currentProgram:(nullable TVTestProgramInfo *)currentProgram
                      nextProgram:(nullable TVTestProgramInfo *)nextProgram;
@end

@implementation TVTestServiceInfo
- (instancetype)initWithServiceID:(uint16_t)serviceID
                           pmtPID:(uint16_t)pmtPID
                           pcrPID:(uint16_t)pcrPID
                      serviceType:(uint8_t)serviceType
                             name:(NSString *)name
                     providerName:(NSString *)providerName
                     videoESCount:(NSUInteger)videoESCount
                     audioStreams:(NSArray<TVTestAudioStreamInfo *> *)audioStreams
                elementaryStreams:(NSArray<TVTestESDetail *> *)elementaryStreams
                      hasCaptions:(BOOL)hasCaptions
                   currentProgram:(nullable TVTestProgramInfo *)currentProgram
                      nextProgram:(nullable TVTestProgramInfo *)nextProgram {
    self = [super init];
    if (self) {
        _serviceID = serviceID;
        _pmtPID = pmtPID;
        _pcrPID = pcrPID;
        _serviceType = serviceType;
        _name = [name copy];
        _providerName = [providerName copy];
        _videoESCount = videoESCount;
        _audioStreams = [audioStreams copy];
        _elementaryStreams = [elementaryStreams copy];
        _hasCaptions = hasCaptions;
        _currentProgram = currentProgram;
        _nextProgram = nextProgram;
    }
    return self;
}
@end

@interface TVTestPIDStat ()
- (instancetype)initWithPID:(uint16_t)pid
                      label:(NSString *)label
                packetCount:(uint64_t)packetCount
       continuityErrorCount:(uint64_t)continuityErrorCount
             scrambledCount:(uint64_t)scrambledCount;
@end

@implementation TVTestPIDStat
- (instancetype)initWithPID:(uint16_t)pid
                      label:(NSString *)label
                packetCount:(uint64_t)packetCount
       continuityErrorCount:(uint64_t)continuityErrorCount
             scrambledCount:(uint64_t)scrambledCount {
    self = [super init];
    if (self) {
        _pid = pid;
        _label = [label copy];
        _packetCount = packetCount;
        _continuityErrorCount = continuityErrorCount;
        _scrambledCount = scrambledCount;
    }
    return self;
}
@end

@interface TVTestStreamStats ()
- (instancetype)initWithTotal:(uint64_t)total
                  formatError:(uint64_t)formatError
               transportError:(uint64_t)transportError
              continuityError:(uint64_t)continuityError
                    scrambled:(uint64_t)scrambled
                     pidStats:(NSArray<TVTestPIDStat *> *)pidStats;
@end

@implementation TVTestStreamStats
- (instancetype)initWithTotal:(uint64_t)total
                  formatError:(uint64_t)formatError
               transportError:(uint64_t)transportError
              continuityError:(uint64_t)continuityError
                    scrambled:(uint64_t)scrambled
                     pidStats:(NSArray<TVTestPIDStat *> *)pidStats {
    self = [super init];
    if (self) {
        _totalPackets = total;
        _formatErrorPackets = formatError;
        _transportErrorPackets = transportError;
        _continuityErrorPackets = continuityError;
        _scrambledPackets = scrambled;
        _pidStats = [pidStats copy];
    }
    return self;
}
@end

@interface TVTestRecordingSnapshot ()
- (instancetype)initWithNetworkID:(uint16_t)networkID
                transportStreamID:(uint16_t)transportStreamID
                      networkName:(NSString *)networkName
                           tsName:(NSString *)tsName
                      totTimeText:(NSString *)totTimeText
             estimatedBitrateMbps:(double)estimatedBitrateMbps
                 analyzedPosition:(double)analyzedPosition
                         services:(NSArray<TVTestServiceInfo *> *)services
                      streamStats:(TVTestStreamStats *)streamStats;
@end

@implementation TVTestRecordingSnapshot
- (instancetype)initWithNetworkID:(uint16_t)networkID
                transportStreamID:(uint16_t)transportStreamID
                      networkName:(NSString *)networkName
                           tsName:(NSString *)tsName
                      totTimeText:(NSString *)totTimeText
             estimatedBitrateMbps:(double)estimatedBitrateMbps
                 analyzedPosition:(double)analyzedPosition
                         services:(NSArray<TVTestServiceInfo *> *)services
                      streamStats:(TVTestStreamStats *)streamStats {
    self = [super init];
    if (self) {
        _networkID = networkID;
        _transportStreamID = transportStreamID;
        _networkName = [networkName copy];
        _tsName = [tsName copy];
        _totTimeText = [totTimeText copy];
        _estimatedBitrateMbps = estimatedBitrateMbps;
        _analyzedPosition = analyzedPosition;
        _services = [services copy];
        _streamStats = streamStats;
    }
    return self;
}

- (nullable TVTestServiceInfo *)serviceWithID:(uint16_t)serviceID {
    for (TVTestServiceInfo *svc in _services) {
        if (svc.serviceID == serviceID) {
            return svc;
        }
    }
    return _services.firstObject;
}
@end

@interface TVTestCaptionFormatRun ()
- (instancetype)initWithUTF8ByteOffset:(NSUInteger)offset
                        charColorIndex:(uint8_t)charColor
                        backColorIndex:(uint8_t)backColor
                              charSize:(NSInteger)charSize;
@end

@implementation TVTestCaptionFormatRun
- (instancetype)initWithUTF8ByteOffset:(NSUInteger)offset
                        charColorIndex:(uint8_t)charColor
                        backColorIndex:(uint8_t)backColor
                              charSize:(NSInteger)charSize {
    self = [super init];
    if (self) {
        _utf8ByteOffset = offset;
        _charColorIndex = charColor;
        _backColorIndex = backColor;
        _charSize = charSize;
    }
    return self;
}
@end

@interface TVTestCaptionCue ()
- (instancetype)initWithTimeMs:(int64_t)timeMs
                   languageTag:(uint8_t)languageTag
                          text:(NSString *)text
                  clearsScreen:(BOOL)clearsScreen
                    formatRuns:(NSArray<TVTestCaptionFormatRun *> *)formatRuns;
@end

@implementation TVTestCaptionCue
- (instancetype)initWithTimeMs:(int64_t)timeMs
                   languageTag:(uint8_t)languageTag
                          text:(NSString *)text
                  clearsScreen:(BOOL)clearsScreen
                    formatRuns:(NSArray<TVTestCaptionFormatRun *> *)formatRuns {
    self = [super init];
    if (self) {
        _timeMs = timeMs;
        _languageTag = languageTag;
        _text = [text copy];
        _clearsScreen = clearsScreen;
        _formatRuns = [formatRuns copy];
    }
    return self;
}
@end

@interface TVTestEPGEvent ()
- (instancetype)initWithEventInfo:(const LibISDB::EventInfo &)event;
@end

@implementation TVTestEPGEvent
- (instancetype)initWithEventInfo:(const LibISDB::EventInfo &)event {
    self = [super init];
    if (self) {
        _networkID = event.NetworkID;
        _transportStreamID = event.TransportStreamID;
        _serviceID = event.ServiceID;
        _eventID = event.EventID;
        _startEpochSeconds = static_cast<int64_t>(event.StartTime.GetLinearSeconds());
        _dateText = FormatDateOnly(event.StartTime);
        _timeRangeText = FormatTimeRange(event.StartTime, event.Duration);
        _durationSeconds = event.Duration;
        _genreLevel1 = PrimaryGenreLevel1(event.ContentNibble);
        _title = DecodeLibISDBString(event.EventName);
        _descriptionText = DecodeLibISDBString(event.EventText);
        _extendedText = FormatExtendedTextList(event.ExtendedText);
        _genreText = GenreTextForLevel1(_genreLevel1);
    }
    return self;
}
@end

@interface TVTestEPGServiceEntry ()
- (instancetype)initWithNetworkID:(uint16_t)networkID
                transportStreamID:(uint16_t)transportStreamID
                        serviceID:(uint16_t)serviceID
                      serviceName:(NSString *)serviceName
                           events:(NSArray<TVTestEPGEvent *> *)events;
@end

@implementation TVTestEPGServiceEntry
- (instancetype)initWithNetworkID:(uint16_t)networkID
                transportStreamID:(uint16_t)transportStreamID
                        serviceID:(uint16_t)serviceID
                      serviceName:(NSString *)serviceName
                           events:(NSArray<TVTestEPGEvent *> *)events {
    self = [super init];
    if (self) {
        _networkID = networkID;
        _transportStreamID = transportStreamID;
        _serviceID = serviceID;
        _serviceName = [serviceName copy];
        _events = [events copy];
    }
    return self;
}
@end

namespace {

TVTestStreamStats *BuildStreamStats(LibISDB::TSPacketParserFilter &parser,
                                    LibISDB::AnalyzerFilter &analyzer) {
    const auto total = parser.GetTotalPacketCount();
    const auto cur = parser.GetPacketCount();
    const auto combined = total + cur;

    std::map<uint16_t, NSString *> pidLabels;
    const int svcCount = analyzer.GetServiceCount();
    for (int i = 0; i < svcCount; ++i) {
        LibISDB::AnalyzerFilter::ServiceInfo info;
        if (!analyzer.GetServiceInfo(i, &info)) {
            continue;
        }
        NSString *sName = DecodeLibISDBString(info.ServiceName);
        if (!sName.length) {
            sName = [NSString stringWithFormat:@"SID %u", info.ServiceID];
        }
        if (info.PMTPID != LibISDB::PID_INVALID) {
            pidLabels[info.PMTPID] = [NSString stringWithFormat:@"PMT (%@)", sName];
        }
        if (info.PCRPID != LibISDB::PID_INVALID && pidLabels.find(info.PCRPID) == pidLabels.end()) {
            pidLabels[info.PCRPID] = [NSString stringWithFormat:@"PCR (%@)", sName];
        }
        for (const auto &es : info.VideoESList) {
            const char *st = LibISDB::GetStreamTypeText(es.StreamType);
            pidLabels[es.PID] = [NSString stringWithFormat:@"映像 %s (%@)", st ? st : "", sName];
        }
        for (const auto &es : info.AudioESList) {
            const char *st = LibISDB::GetStreamTypeText(es.StreamType);
            pidLabels[es.PID] = [NSString stringWithFormat:@"音声 %s (%@)", st ? st : "", sName];
        }
        for (const auto &es : info.CaptionESList) {
            pidLabels[es.PID] = [NSString stringWithFormat:@"ARIB字幕 (%@)", sName];
        }
        for (const auto &es : info.DataCarrouselESList) {
            pidLabels[es.PID] = [NSString stringWithFormat:@"データ放送 (%@)", sName];
        }
        for (const auto &ecm : info.ECMList) {
            pidLabels[ecm.PID] = [NSString stringWithFormat:@"ECM (%@)", sName];
        }
    }
    LibISDB::AnalyzerFilter::EMMPIDList emmList;
    if (analyzer.GetEMMPIDList(&emmList)) {
        for (uint16_t pid : emmList) {
            pidLabels[pid] = @"EMM";
        }
    }

    NSMutableArray<TVTestPIDStat *> *pidStats = [NSMutableArray array];
    for (uint16_t pid = 0; pid <= 0x1FFF; ++pid) {
        const auto c = parser.GetTotalPacketCount(pid) + parser.GetPacketCount(pid);
        if (c.Input == 0) {
            continue;
        }
        NSString *label = pidLabels[pid];
        if (!label.length) {
            const char *pre = LibISDB::GetPredefinedPIDText(pid);
            if (pre && pre[0] != '\0') {
                label = [NSString stringWithUTF8String:pre] ?: @"";
            } else {
                label = @"その他";
            }
        }
        [pidStats addObject:[[TVTestPIDStat alloc] initWithPID:pid
                                                         label:label
                                                   packetCount:c.Input
                                          continuityErrorCount:c.ContinuityError
                                                scrambledCount:c.Scrambled]];
    }

    return [[TVTestStreamStats alloc] initWithTotal:combined.Input
                                        formatError:combined.FormatError
                                     transportError:combined.TransportError
                                    continuityError:combined.ContinuityError
                                          scrambled:combined.Scrambled
                                           pidStats:pidStats];
}

TVTestProgramInfo *BuildProgramInfo(LibISDB::AnalyzerFilter &analyzer, int serviceIndex, bool next) {
    LibISDB::String name, text;
    const bool hasName = analyzer.GetEventName(serviceIndex, &name, next);
    analyzer.GetEventText(serviceIndex, &text, next);
    LibISDB::DateTime startTime;
    uint32_t duration = 0;
    analyzer.GetEventTime(serviceIndex, &startTime, &duration, next);

    if (!hasName && text.empty() && !startTime.IsValid()) {
        return nil;
    }

    LibISDB::EventInfo::ExtendedTextInfoList extList;
    analyzer.GetEventExtendedText(serviceIndex, &extList, true, next);
    LibISDB::AnalyzerFilter::EventContentNibble nibble;
    analyzer.GetEventContentNibble(serviceIndex, &nibble, next);

    NSString *startStr = FormatDateTime(startTime);
    NSString *endStr = @"";
    if (startTime.IsValid() && duration > 0) {
        LibISDB::DateTime endTime = startTime;
        endTime.OffsetSeconds(static_cast<long>(duration));
        endStr = FormatTimeShort(endTime);
    }

    NSString *videoSpec = @"";
    const uint8_t vComp = analyzer.GetVideoComponentType(serviceIndex);
    if (vComp != LibISDB::COMPONENT_TYPE_INVALID) {
        const char *vText = LibISDB::GetVideoComponentTypeText_ja(vComp);
        if (vText) {
            videoSpec = [NSString stringWithUTF8String:vText] ?: @"";
        }
    }

    NSString *audioSpec = @"";
    const int audioCount = analyzer.GetAudioESCount(serviceIndex);
    if (audioCount > 0) {
        const uint8_t aComp = analyzer.GetAudioComponentType(serviceIndex, 0);
        if (aComp != LibISDB::COMPONENT_TYPE_INVALID) {
            const char *aText = LibISDB::GetAudioComponentTypeText_ja(aComp);
            if (aText) {
                audioSpec = [NSString stringWithUTF8String:aText] ?: @"";
            }
        }
    }

    const uint8_t l1 = PrimaryGenreLevel1(nibble);
    return [[TVTestProgramInfo alloc] initWithEventID:analyzer.GetEventID(serviceIndex, next)
                                                title:DecodeLibISDBString(name)
                                      descriptionText:DecodeLibISDBString(text)
                                         extendedText:FormatExtendedTextList(extList)
                                        startTimeText:startStr
                                          endTimeText:endStr
                                      durationSeconds:duration
                                          genreLevel1:l1
                                            genreText:GenreTextForLevel1(l1)
                                        videoSpecText:videoSpec
                                        audioSpecText:audioSpec];
}

TVTestRecordingSnapshot *BuildSnapshot(LibISDB::TSPacketParserFilter &parser,
                                       LibISDB::AnalyzerFilter &analyzer,
                                       double estimatedBitrateMbps,
                                       double analyzedPosition) {
    LibISDB::String networkName, tsName;
    analyzer.GetNetworkName(&networkName);
    analyzer.GetTSName(&tsName);
    LibISDB::DateTime totTime;
    analyzer.GetInterpolatedTOTTime(&totTime);

    NSMutableArray<TVTestServiceInfo *> *services = [NSMutableArray array];
    const int count = analyzer.GetServiceCount();
    for (int i = 0; i < count; ++i) {
        LibISDB::AnalyzerFilter::ServiceInfo info;
        if (!analyzer.GetServiceInfo(i, &info)) {
            continue;
        }
        NSMutableArray<TVTestAudioStreamInfo *> *audioStreams = [NSMutableArray array];
        const int audioCount = analyzer.GetAudioESCount(i);
        for (int a = 0; a < audioCount; ++a) {
            LibISDB::AnalyzerFilter::ESInfo es;
            if (!analyzer.GetAudioESInfo(i, a, &es)) {
                continue;
            }
            LibISDB::String compText;
            analyzer.GetAudioComponentText(i, a, &compText);
            NSString *label = DecodeLibISDBString(compText);
            if (!label.length) {
                const uint8_t compType = analyzer.GetAudioComponentType(i, a);
                if (compType != LibISDB::COMPONENT_TYPE_INVALID) {
                    const char *t = LibISDB::GetAudioComponentTypeText_ja(compType);
                    if (t) {
                        label = [NSString stringWithUTF8String:t] ?: @"";
                    }
                }
            }
            if (!label.length) {
                const char *st = LibISDB::GetStreamTypeText(es.StreamType);
                label = [NSString stringWithFormat:@"音声 %d (%s, PID 0x%04X)",
                         a + 1, st ? st : "Audio", es.PID];
            }
            [audioStreams addObject:[[TVTestAudioStreamInfo alloc] initWithPID:es.PID
                                                                    streamType:es.StreamType
                                                                  componentTag:es.ComponentTag
                                                                         label:label]];
        }

        NSMutableArray<TVTestESDetail *> *esDetails = [NSMutableArray array];
        auto addESList = [&](const LibISDB::AnalyzerFilter::ESInfoList &list, NSString *cat) {
            for (const auto &es : list) {
                const char *st = LibISDB::GetStreamTypeText(es.StreamType);
                NSString *stName = st ? [NSString stringWithUTF8String:st] : @"Unknown";
                [esDetails addObject:[[TVTestESDetail alloc] initWithPID:es.PID
                                                              streamType:es.StreamType
                                                          streamTypeName:stName ?: @"Unknown"
                                                                category:cat]];
            }
        };
        addESList(info.VideoESList, @"映像");
        addESList(info.AudioESList, @"音声");
        addESList(info.CaptionESList, @"字幕");
        addESList(info.DataCarrouselESList, @"データ放送");
        addESList(info.OtherESList, @"その他");

        TVTestProgramInfo *current = BuildProgramInfo(analyzer, i, false);
        TVTestProgramInfo *next = BuildProgramInfo(analyzer, i, true);
        NSString *svcName = DecodeLibISDBString(info.ServiceName);
        if (!svcName.length) {
            svcName = [NSString stringWithFormat:@"サービス %u", info.ServiceID];
        }
        [services addObject:[[TVTestServiceInfo alloc] initWithServiceID:info.ServiceID
                                                                  pmtPID:info.PMTPID
                                                                  pcrPID:info.PCRPID
                                                             serviceType:info.ServiceType
                                                                    name:svcName
                                                            providerName:DecodeLibISDBString(info.ProviderName)
                                                            videoESCount:info.VideoESList.size()
                                                            audioStreams:audioStreams
                                                       elementaryStreams:esDetails
                                                             hasCaptions:!info.CaptionESList.empty()
                                                          currentProgram:current
                                                             nextProgram:next]];
    }

    TVTestStreamStats *stats = BuildStreamStats(parser, analyzer);
    return [[TVTestRecordingSnapshot alloc] initWithNetworkID:analyzer.GetNetworkID()
                                            transportStreamID:analyzer.GetTransportStreamID()
                                                  networkName:DecodeLibISDBString(networkName)
                                                       tsName:DecodeLibISDBString(tsName)
                                                  totTimeText:FormatDateTime(totTime)
                                         estimatedBitrateMbps:estimatedBitrateMbps
                                             analyzedPosition:analyzedPosition
                                                     services:services
                                                  streamStats:stats];
}

NSArray<TVTestEPGServiceEntry *> *BuildEPGServiceEntries(
    LibISDB::EPGDatabase &db,
    const std::map<uint16_t, NSString *> &serviceNames) {
    LibISDB::EPGDatabase::ServiceList list;
    db.GetServiceList(&list);

    NSMutableArray<TVTestEPGServiceEntry *> *result = [NSMutableArray arrayWithCapacity:list.size()];
    for (const auto &svc : list) {
        LibISDB::EPGDatabase::EventList events;
        if (!db.GetEventListSortedByTime(svc.NetworkID, svc.TransportStreamID, svc.ServiceID, &events) ||
            events.empty()) {
            continue;
        }
        NSMutableArray<TVTestEPGEvent *> *evArray = [NSMutableArray arrayWithCapacity:events.size()];
        for (const auto &ev : events) {
            [evArray addObject:[[TVTestEPGEvent alloc] initWithEventInfo:ev]];
        }
        auto it = serviceNames.find(svc.ServiceID);
        NSString *name = (it != serviceNames.end() && it->second.length)
            ? it->second
            : [NSString stringWithFormat:@"サービス %u", svc.ServiceID];
        [result addObject:[[TVTestEPGServiceEntry alloc] initWithNetworkID:svc.NetworkID
                                                         transportStreamID:svc.TransportStreamID
                                                                 serviceID:svc.ServiceID
                                                               serviceName:name
                                                                    events:evArray]];
    }
    return result;
}

class CaptionCollector final : public LibISDB::CaptionFilter::Handler {
public:
    CaptionCollector(int64_t *basePTS, uint64_t *latestPCR,
                     std::vector<TVTestCaptionCue *> &cues,
                     std::set<uint8_t> &languages,
                     std::mutex &lock)
        : m_basePTS(basePTS)
        , m_latestPCR(latestPCR)
        , m_cues(cues)
        , m_languages(languages)
        , m_lock(lock) {}

    void OnLanguageUpdate(LibISDB::CaptionFilter *, LibISDB::CaptionParser *pParser) override {
        if (!pParser) {
            return;
        }
        std::lock_guard<std::mutex> guard(m_lock);
        const int count = pParser->GetLanguageCount();
        for (int i = 0; i < count; ++i) {
            LibISDB::CaptionParser::LanguageInfo info;
            if (pParser->GetLanguageInfo(i, &info)) {
                m_languages.insert(info.LanguageTag);
            }
        }
    }

    void OnCaption(LibISDB::CaptionFilter *,
                   LibISDB::CaptionParser *pParser,
                   uint8_t language,
                   const LibISDB::CharType *pText,
                   const LibISDB::ARIBStringDecoder::FormatList *pFormatList) override {
        if (!pParser || !pText) {
            return;
        }
        int64_t pts = pParser->GetLastPTS();
        if (pts < 0 && *m_latestPCR != LibISDB::PCR_INVALID) {
            pts = static_cast<int64_t>(*m_latestPCR);
        }
        if (pts < 0) {
            return;
        }
        if (*m_basePTS < 0) {
            *m_basePTS = pts;
        }
        int64_t relMs = DiffPTS90k(pts, *m_basePTS) / 90;
        if (relMs < 0) {
            relMs = 0;
        }

        std::string raw(pText);
        bool clears = false;
        size_t stripPrefix = 0;
        while (stripPrefix < raw.size() && raw[stripPrefix] == '\f') {
            clears = true;
            ++stripPrefix;
        }
        std::string cleaned;
        cleaned.reserve(raw.size() - stripPrefix);
        std::vector<size_t> posMap(raw.size() + 1, 0);
        for (size_t i = 0; i < raw.size(); ++i) {
            posMap[i] = cleaned.size();
            if (i < stripPrefix) {
                continue;
            }
            if (raw[i] == '\f') {
                clears = true;
                cleaned.push_back('\n');
            } else {
                cleaned.push_back(raw[i]);
            }
        }
        posMap[raw.size()] = cleaned.size();

        NSMutableArray<TVTestCaptionFormatRun *> *runs = [NSMutableArray array];
        if (pFormatList) {
            for (const auto &fmt : *pFormatList) {
                const size_t mapped = fmt.Pos < posMap.size() ? posMap[fmt.Pos] : cleaned.size();
                [runs addObject:[[TVTestCaptionFormatRun alloc]
                                 initWithUTF8ByteOffset:mapped
                                         charColorIndex:fmt.CharColorIndex
                                         backColorIndex:fmt.BackColorIndex
                                               charSize:static_cast<NSInteger>(fmt.Size)]];
            }
        }

        NSString *nsText = [[NSString alloc] initWithBytes:cleaned.data()
                                                    length:cleaned.size()
                                                  encoding:NSUTF8StringEncoding] ?: @"";
        TVTestCaptionCue *cue = [[TVTestCaptionCue alloc] initWithTimeMs:relMs
                                                             languageTag:language
                                                                    text:nsText
                                                            clearsScreen:clears
                                                              formatRuns:runs];
        std::lock_guard<std::mutex> guard(m_lock);
        m_languages.insert(language);
        m_cues.push_back(cue);
    }

private:
    int64_t *m_basePTS;
    uint64_t *m_latestPCR;
    std::vector<TVTestCaptionCue *> &m_cues;
    std::set<uint8_t> &m_languages;
    std::mutex &m_lock;
};

class LogoCollector final : public LibISDB::LogoDownloaderFilter::LogoHandler {
public:
    LogoCollector(std::map<uint16_t, NSData *> &logos,
                  NSString * _Nullable cacheDir,
                  std::mutex &lock)
        : m_logos(logos)
        , m_cacheDir(cacheDir)
        , m_lock(lock) {}

    void OnLogoDownloaded(const LibISDB::LogoDownloaderFilter::LogoData &Data) override {
        if (!Data.pData || Data.DataSize < 8) {
            return;
        }
        // Check PNG magic bytes (ARIB logos in CDT/SDTT are PNG)
        static const uint8_t kPNGMagic[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
        if (std::memcmp(Data.pData, kPNGMagic, 8) != 0) {
            return;
        }
        NSData *png = [NSData dataWithBytes:Data.pData length:Data.DataSize];
        std::lock_guard<std::mutex> guard(m_lock);
        for (const auto &svc : Data.ServiceList) {
            // Prefer larger logo types (type 5 = HD large, type 2 = HD small)
            auto it = m_logos.find(svc.ServiceID);
            if (it == m_logos.end() || png.length > it->second.length) {
                m_logos[svc.ServiceID] = png;
                if (m_cacheDir.length) {
                    NSString *file = [m_cacheDir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%u_%u.png", Data.NetworkID, svc.ServiceID]];
                    [png writeToFile:file atomically:YES];
                }
            }
        }
    }

private:
    std::map<uint16_t, NSData *> &m_logos;
    NSString * _Nullable m_cacheDir;
    std::mutex &m_lock;
};

class PacketWriterSink final : public LibISDB::SingleIOFilter {
public:
    explicit PacketWriterSink(LibISDB::FileStreamPOSIX &outStream)
        : m_outStream(outStream) {}

    const LibISDB::CharType * GetObjectName() const noexcept override {
        return LIBISDB_STR("PacketWriterSink");
    }

    bool ProcessData(LibISDB::DataStream *pData) override {
        if (!pData || !pData->Is<LibISDB::TSPacket>()) {
            return true;
        }
        do {
            auto *pkt = pData->Get<LibISDB::TSPacket>();
            if (pkt && pkt->GetSize() == LibISDB::TS_PACKET_SIZE) {
                if (m_outStream.Write(pkt->GetData(), LibISDB::TS_PACKET_SIZE) != LibISDB::TS_PACKET_SIZE) {
                    m_writeFailed = true;
                    return false;
                }
                ++m_writtenPackets;
            }
        } while (pData->Next());
        return true;
    }

    bool WriteFailed() const noexcept { return m_writeFailed; }
    uint64_t WrittenPackets() const noexcept { return m_writtenPackets; }

private:
    LibISDB::FileStreamPOSIX &m_outStream;
    bool m_writeFailed = false;
    uint64_t m_writtenPackets = 0;
};

} // namespace

@implementation TVTestRecordingSession {
    std::atomic<bool> _cancelled;
    std::atomic<uint64_t> _captionGeneration;
    std::mutex _dataLock;
    int64_t _basePTS90k;
    std::vector<TVTestCaptionCue *> _captionCues;
    std::set<uint8_t> _captionLanguages;
    std::map<uint16_t, NSData *> _serviceLogos;
    NSArray<TVTestEPGServiceEntry *> *_epgServices;
    TVTestStreamStats *_streamStats;
    dispatch_queue_t _indexQueue;
}

+ (nullable instancetype)sessionWithURL:(NSURL *)url error:(NSError **)error {
    return [[self alloc] initWithURL:url error:error];
}

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _url = url;
    _basePTS90k = -1;
    _epgServices = @[];
    _indexQueue = dispatch_queue_create("jp.tvtest.native.tsindex", DISPATCH_QUEUE_SERIAL);

    LibISDB::FileStreamPOSIX stream;
    if (!stream.Open(url.fileSystemRepresentation, LibISDB::FileStreamBase::OpenFlag::Read)) {
        if (error) {
            *error = MakeSessionError(@"録画ファイルを開けませんでした。");
        }
        return nil;
    }

    _fileSize = static_cast<uint64_t>(stream.GetSize());
    std::vector<uint8_t> probe(kProbeBytes);
    const size_t probeRead = stream.Read(probe.data(), probe.size());
    const PacketLayout layout = DetectPacketLayout(probe.data(), probeRead);
    if (layout.stride == 0) {
        if (error) {
            *error = MakeSessionError(@"有効な TS / M2TS パケット同期を検出できませんでした。");
        }
        return nil;
    }
    _packetStride = layout.stride;
    _packetOffset = layout.offset;
    stream.Close();

    NSError *scanError = nil;
    _initialSnapshot = [self scanWindowAtByteOffset:_packetOffset
                                              limit:kInitialScanLimit
                                           position:0.0
                                         recordBase:YES
                                              error:&scanError];
    if (!_initialSnapshot) {
        if (error) {
            *error = scanError ?: MakeSessionError(@"録画の初期解析に失敗しました。");
        }
        return nil;
    }
    _streamStats = _initialSnapshot.streamStats;
    return self;
}

- (void)dealloc {
    [self cancel];
}

- (void)cancel {
    _cancelled.store(true);
    _captionGeneration.fetch_add(1);
}

- (nullable TVTestRecordingSnapshot *)scanWindowAtByteOffset:(uint64_t)byteOffset
                                                       limit:(size_t)scanLimit
                                                    position:(double)position
                                                  recordBase:(BOOL)recordBase
                                                       error:(NSError **)error {
    LibISDB::FileStreamPOSIX stream;
    if (!stream.Open(_url.fileSystemRepresentation, LibISDB::FileStreamBase::OpenFlag::Read)) {
        if (error) {
            *error = MakeSessionError(@"録画ファイルを開けませんでした。");
        }
        return nil;
    }

    uint64_t alignedOffset = _packetOffset;
    if (byteOffset > _packetOffset) {
        const uint64_t delta = byteOffset - _packetOffset;
        alignedOffset = _packetOffset + (delta / _packetStride) * _packetStride;
        if (alignedOffset >= _fileSize && _fileSize > _packetOffset) {
            const uint64_t available = _fileSize - _packetOffset;
            const uint64_t back = std::min<uint64_t>(available, scanLimit);
            alignedOffset = _packetOffset + ((available - back) / _packetStride) * _packetStride;
        }
    }

    if (!stream.SetPos(static_cast<LibISDB::Stream::OffsetType>(alignedOffset),
                       LibISDB::Stream::SetPosType::Begin)) {
        if (error) {
            *error = MakeSessionError(@"録画ファイルのシークに失敗しました。");
        }
        return nil;
    }

    auto analyzer = std::make_unique<LibISDB::AnalyzerFilter>();
    auto parser = std::make_unique<LibISDB::TSPacketParserFilter>();
    parser->SetOutputFilter(analyzer.get(), analyzer.get());

    LibISDB::DataBuffer buffer;
    LibISDB::SingleDataStream dataStream(&buffer);

    const size_t bytesPerRead = (kReadBytes / _packetStride) * _packetStride;
    std::vector<uint8_t> rawBuf(bytesPerRead);
    std::vector<uint8_t> normBuf(bytesPerRead);

    size_t scanned = 0;
    uint64_t firstPCR = LibISDB::PCR_INVALID;
    uint64_t firstPCRBytes = 0;
    uint64_t lastPCR = LibISDB::PCR_INVALID;
    uint64_t lastPCRBytes = 0;
    uint16_t pcrPID = LibISDB::PID_INVALID;

    while (scanned < scanLimit) {
        const size_t toRead = std::min(bytesPerRead, scanLimit - scanned);
        const size_t n = stream.Read(rawBuf.data(), toRead);
        if (n == 0) {
            break;
        }
        const size_t chunkBase = scanned;
        scanned += n;

        size_t consumed = 0;
        size_t written = 0;
        while (n - consumed >= kPacketSize) {
            if (rawBuf[consumed] == 0x47) {
                const uint8_t *pkt = rawBuf.data() + consumed;
                uint64_t pktPCR = 0;
                if (ExtractPacketPCR90k(pkt, pktPCR)) {
                    const uint16_t pid = static_cast<uint16_t>(((pkt[1] & 0x1F) << 8) | pkt[2]);
                    if (pcrPID == LibISDB::PID_INVALID) {
                        pcrPID = pid;
                    }
                    if (pid == pcrPID) {
                        const uint64_t bytePos = chunkBase + consumed;
                        if (firstPCR == LibISDB::PCR_INVALID) {
                            firstPCR = pktPCR;
                            firstPCRBytes = bytePos;
                            if (recordBase && _basePTS90k < 0) {
                                _basePTS90k = static_cast<int64_t>(pktPCR);
                            }
                        }
                        lastPCR = pktPCR;
                        lastPCRBytes = bytePos;
                    }
                }
                std::memcpy(normBuf.data() + written, pkt, kPacketSize);
                written += kPacketSize;
                consumed += std::min(_packetStride, n - consumed);
            } else {
                ++consumed;
            }
        }
        if (written > 0) {
            buffer.SetData(normBuf.data(), written);
            parser->ReceiveData(&dataStream);
        }
    }

    double bitrateMbps = 0.0;
    if (firstPCR != LibISDB::PCR_INVALID && lastPCR != LibISDB::PCR_INVALID && lastPCRBytes > firstPCRBytes) {
        const int64_t deltaPCR = DiffPTS90k(static_cast<int64_t>(lastPCR), static_cast<int64_t>(firstPCR));
        if (deltaPCR > 9000) {
            const double seconds = static_cast<double>(deltaPCR) / 90000.0;
            const double bits = static_cast<double>(lastPCRBytes - firstPCRBytes) * 8.0;
            bitrateMbps = (bits / seconds) / 1000000.0;
        }
    }

    return BuildSnapshot(*parser, *analyzer, bitrateMbps, position);
}

- (nullable TVTestRecordingSnapshot *)analyzeSnapshotAtPosition:(double)position
                                                          error:(NSError **)error {
    const double clamped = std::max(0.0, std::min(1.0, position));
    uint64_t targetOffset = _packetOffset;
    if (_fileSize > _packetOffset) {
        const uint64_t usable = _fileSize - _packetOffset;
        uint64_t rel = static_cast<uint64_t>(clamped * static_cast<double>(usable));
        if (rel + kPositionWindowBytes > usable && usable > kPositionWindowBytes) {
            rel = usable - kPositionWindowBytes;
        }
        targetOffset = _packetOffset + (rel / _packetStride) * _packetStride;
    }
    return [self scanWindowAtByteOffset:targetOffset
                                  limit:kPositionWindowBytes
                               position:clamped
                             recordBase:NO
                                  error:error];
}

- (void)startBackgroundIndexForServiceID:(uint16_t)serviceID
                         onCaptionUpdate:(void (^)(NSArray<NSNumber *> *languageTags))captionUpdate
                             onEPGUpdate:(void (^)(NSArray<TVTestEPGServiceEntry *> *epgServices, BOOL finished))epgUpdate {
    [self startBackgroundIndexForServiceID:serviceID
                               epgDataPath:nil
                              logoCacheDir:nil
                           onCaptionUpdate:captionUpdate
                               onEPGUpdate:epgUpdate
                             onStatsUpdate:nil];
}

- (void)startBackgroundIndexForServiceID:(uint16_t)serviceID
                             epgDataPath:(nullable NSString *)epgDataPath
                            logoCacheDir:(nullable NSString *)logoCacheDir
                         onCaptionUpdate:(void (^)(NSArray<NSNumber *> *languageTags))captionUpdate
                             onEPGUpdate:(void (^)(NSArray<TVTestEPGServiceEntry *> *epgServices, BOOL finished))epgUpdate
                           onStatsUpdate:(nullable void (^)(TVTestStreamStats *stats))statsUpdate {
    _cancelled.store(false);
    const uint64_t gen = _captionGeneration.fetch_add(1) + 1;
    NSString *epgPathCopy = [epgDataPath copy];
    NSString *logoDirCopy = [logoCacheDir copy];

    dispatch_async(_indexQueue, ^{
        // Pre-load cached logos from disk for services in initial snapshot
        if (logoDirCopy.length && self->_initialSnapshot.networkID != 0) {
            std::lock_guard<std::mutex> guard(self->_dataLock);
            for (TVTestServiceInfo *svc in self->_initialSnapshot.services) {
                NSString *path = [logoDirCopy stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%u_%u.png",
                     self->_initialSnapshot.networkID, svc.serviceID]];
                NSData *cached = [NSData dataWithContentsOfFile:path];
                if (cached.length >= 8) {
                    self->_serviceLogos[svc.serviceID] = cached;
                }
            }
        }

        LibISDB::FileStreamPOSIX stream;
        if (!stream.Open(self->_url.fileSystemRepresentation, LibISDB::FileStreamBase::OpenFlag::Read)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (epgUpdate) {
                    epgUpdate(@[], YES);
                }
            });
            return;
        }
        if (!stream.SetPos(static_cast<LibISDB::Stream::OffsetType>(self->_packetOffset),
                           LibISDB::Stream::SetPosType::Begin)) {
            return;
        }

        auto epgDB = std::make_unique<LibISDB::EPGDatabase>();
        epgDB->SetNoPastEvents(false);
        epgDB->SetScheduleOnly(false);

        auto analyzer = std::make_unique<LibISDB::AnalyzerFilter>();
        auto epgFilter = std::make_unique<LibISDB::EPGDatabaseFilter>();
        epgFilter->SetEPGDatabase(epgDB.get());
        auto captionFilter = std::make_unique<LibISDB::CaptionFilter>();
        if (serviceID != 0) {
            captionFilter->SetTargetStream(serviceID);
        }
        auto logoFilter = std::make_unique<LibISDB::LogoDownloaderFilter>();

        int64_t basePTS = self->_basePTS90k;
        uint64_t latestPCR = LibISDB::PCR_INVALID;
        {
            std::lock_guard<std::mutex> guard(self->_dataLock);
            self->_captionCues.clear();
            self->_captionLanguages.clear();
        }
        CaptionCollector collector(&basePTS, &latestPCR,
                                   self->_captionCues,
                                   self->_captionLanguages,
                                   self->_dataLock);
        captionFilter->SetCaptionHandler(&collector);

        LogoCollector logoCollector(self->_serviceLogos, logoDirCopy, self->_dataLock);
        logoFilter->SetLogoHandler(&logoCollector);

        // Pipeline: TSPacketParser -> Analyzer -> EPGDatabase -> Caption -> LogoDownloader
        auto parser = std::make_unique<LibISDB::TSPacketParserFilter>();
        parser->SetOutputFilter(analyzer.get(), analyzer.get());
        analyzer->SetOutputFilter(epgFilter.get(), epgFilter.get());
        epgFilter->SetOutputFilter(captionFilter.get(), captionFilter.get());
        captionFilter->SetOutputFilter(logoFilter.get(), logoFilter.get());

        LibISDB::DataBuffer buffer;
        LibISDB::SingleDataStream dataStream(&buffer);

        const size_t bytesPerRead = (kReadBytes / self->_packetStride) * self->_packetStride;
        std::vector<uint8_t> rawBuf(bytesPerRead);
        std::vector<uint8_t> normBuf(bytesPerRead);

        uint64_t totalRead = 0;
        uint64_t nextEmit = kProgressEmitInterval;
        std::map<uint16_t, NSString *> serviceNames;

        auto collectNames = [&]() {
            const int cnt = analyzer->GetServiceCount();
            for (int i = 0; i < cnt; ++i) {
                LibISDB::String sName;
                if (analyzer->GetServiceName(i, &sName) && !sName.empty()) {
                    serviceNames[analyzer->GetServiceID(i)] = DecodeLibISDBString(sName);
                }
            }
            LibISDB::AnalyzerFilter::SDTServiceList sdtList;
            if (analyzer->GetSDTServiceList(&sdtList)) {
                for (const auto &s : sdtList) {
                    if (!s.ServiceName.empty()) {
                        serviceNames[s.ServiceID] = DecodeLibISDBString(s.ServiceName);
                    }
                }
            }
        };

        auto emitProgress = [&](BOOL finished) {
            collectNames();
            NSArray<TVTestEPGServiceEntry *> *epgEntries = BuildEPGServiceEntries(*epgDB, serviceNames);
            TVTestStreamStats *stats = BuildStreamStats(*parser, *analyzer);
            NSMutableArray<NSNumber *> *langTags = [NSMutableArray array];
            {
                std::lock_guard<std::mutex> guard(self->_dataLock);
                self->_epgServices = epgEntries;
                self->_streamStats = stats;
                if (basePTS >= 0 && self->_basePTS90k < 0) {
                    self->_basePTS90k = basePTS;
                }
                for (uint8_t tag : self->_captionLanguages) {
                    [langTags addObject:@(tag)];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_cancelled.load()) {
                    return;
                }
                if (captionUpdate && self->_captionGeneration.load() == gen) {
                    captionUpdate(langTags);
                }
                if (epgUpdate) {
                    epgUpdate(epgEntries, finished);
                }
                if (statsUpdate) {
                    statsUpdate(stats);
                }
            });
        };

        while (!self->_cancelled.load()) {
            const size_t n = stream.Read(rawBuf.data(), bytesPerRead);
            if (n == 0) {
                break;
            }
            totalRead += n;

            size_t consumed = 0;
            size_t written = 0;
            while (n - consumed >= kPacketSize) {
                if (rawBuf[consumed] == 0x47) {
                    const uint8_t *pkt = rawBuf.data() + consumed;
                    uint64_t pktPCR = 0;
                    if (ExtractPacketPCR90k(pkt, pktPCR)) {
                        latestPCR = pktPCR;
                        if (basePTS < 0) {
                            basePTS = static_cast<int64_t>(pktPCR);
                        }
                    }
                    std::memcpy(normBuf.data() + written, pkt, kPacketSize);
                    written += kPacketSize;
                    consumed += std::min(self->_packetStride, n - consumed);
                } else {
                    ++consumed;
                }
            }
            if (written > 0) {
                buffer.SetData(normBuf.data(), written);
                parser->ReceiveData(&dataStream);
                const uint64_t pcr = ReadFirstPCR90k(*analyzer);
                if (pcr != LibISDB::PCR_INVALID) {
                    latestPCR = pcr;
                    if (basePTS < 0) {
                        basePTS = static_cast<int64_t>(pcr);
                    }
                }
            }

            if (totalRead >= nextEmit) {
                nextEmit += kProgressEmitInterval;
                emitProgress(NO);
            }
        }

        epgFilter->SetEPGDatabase(nullptr);
        captionFilter->SetCaptionHandler(nullptr);
        logoFilter->SetLogoHandler(nullptr);

        if (!self->_cancelled.load()) {
            // Persist merged EPGDatabase via LibISDB::EPGDataFile if requested
            if (epgPathCopy.length && epgDB->GetServiceCount() > 0) {
                auto persisted = std::make_unique<LibISDB::EPGDatabase>();
                persisted->SetNoPastEvents(false);
                persisted->SetScheduleOnly(false);
                LibISDB::EPGDataFile reader;
                if (reader.Open(persisted.get(), epgPathCopy.fileSystemRepresentation,
                                LibISDB::EPGDataFile::OpenFlag::Read)) {
                    reader.Load();
                    reader.Close();
                }
                persisted->Merge(epgDB.get());
                LibISDB::EPGDataFile writer;
                if (writer.Open(persisted.get(), epgPathCopy.fileSystemRepresentation,
                                LibISDB::EPGDataFile::OpenFlag::Write | LibISDB::EPGDataFile::OpenFlag::Flush)) {
                    writer.Save();
                    writer.Close();
                }
            }

            {
                std::lock_guard<std::mutex> guard(self->_dataLock);
                std::stable_sort(self->_captionCues.begin(), self->_captionCues.end(),
                                 [](TVTestCaptionCue *a, TVTestCaptionCue *b) {
                                     return a.timeMs < b.timeMs;
                                 });
            }
            emitProgress(YES);
        }
    });
}

- (void)reindexCaptionsForServiceID:(uint16_t)serviceID
                           onUpdate:(void (^)(NSArray<NSNumber *> *languageTags))onUpdate {
    const uint64_t gen = _captionGeneration.fetch_add(1) + 1;
    dispatch_async(_indexQueue, ^{
        if (self->_cancelled.load() || self->_captionGeneration.load() != gen) {
            return;
        }
        LibISDB::FileStreamPOSIX stream;
        if (!stream.Open(self->_url.fileSystemRepresentation, LibISDB::FileStreamBase::OpenFlag::Read)) {
            return;
        }
        if (!stream.SetPos(static_cast<LibISDB::Stream::OffsetType>(self->_packetOffset),
                           LibISDB::Stream::SetPosType::Begin)) {
            return;
        }

        auto analyzer = std::make_unique<LibISDB::AnalyzerFilter>();
        auto captionFilter = std::make_unique<LibISDB::CaptionFilter>();
        if (serviceID != 0) {
            captionFilter->SetTargetStream(serviceID);
        }

        int64_t basePTS = self->_basePTS90k;
        uint64_t latestPCR = LibISDB::PCR_INVALID;
        {
            std::lock_guard<std::mutex> guard(self->_dataLock);
            self->_captionCues.clear();
            self->_captionLanguages.clear();
        }
        CaptionCollector collector(&basePTS, &latestPCR,
                                   self->_captionCues,
                                   self->_captionLanguages,
                                   self->_dataLock);
        captionFilter->SetCaptionHandler(&collector);

        auto parser = std::make_unique<LibISDB::TSPacketParserFilter>();
        parser->SetOutputFilter(analyzer.get(), analyzer.get());
        analyzer->SetOutputFilter(captionFilter.get(), captionFilter.get());

        LibISDB::DataBuffer buffer;
        LibISDB::SingleDataStream dataStream(&buffer);

        const size_t bytesPerRead = (kReadBytes / self->_packetStride) * self->_packetStride;
        std::vector<uint8_t> rawBuf(bytesPerRead);
        std::vector<uint8_t> normBuf(bytesPerRead);

        while (!self->_cancelled.load() && self->_captionGeneration.load() == gen) {
            const size_t n = stream.Read(rawBuf.data(), bytesPerRead);
            if (n == 0) {
                break;
            }
            size_t consumed = 0;
            size_t written = 0;
            while (n - consumed >= kPacketSize) {
                if (rawBuf[consumed] == 0x47) {
                    const uint8_t *pkt = rawBuf.data() + consumed;
                    uint64_t pktPCR = 0;
                    if (ExtractPacketPCR90k(pkt, pktPCR)) {
                        latestPCR = pktPCR;
                        if (basePTS < 0) {
                            basePTS = static_cast<int64_t>(pktPCR);
                        }
                    }
                    std::memcpy(normBuf.data() + written, pkt, kPacketSize);
                    written += kPacketSize;
                    consumed += std::min(self->_packetStride, n - consumed);
                } else {
                    ++consumed;
                }
            }
            if (written > 0) {
                buffer.SetData(normBuf.data(), written);
                parser->ReceiveData(&dataStream);
                const uint64_t pcr = ReadFirstPCR90k(*analyzer);
                if (pcr != LibISDB::PCR_INVALID) {
                    latestPCR = pcr;
                    if (basePTS < 0) {
                        basePTS = static_cast<int64_t>(pcr);
                    }
                }
            }
        }

        captionFilter->SetCaptionHandler(nullptr);

        if (!self->_cancelled.load() && self->_captionGeneration.load() == gen) {
            NSMutableArray<NSNumber *> *langTags = [NSMutableArray array];
            {
                std::lock_guard<std::mutex> guard(self->_dataLock);
                std::stable_sort(self->_captionCues.begin(), self->_captionCues.end(),
                                 [](TVTestCaptionCue *a, TVTestCaptionCue *b) {
                                     return a.timeMs < b.timeMs;
                                 });
                for (uint8_t tag : self->_captionLanguages) {
                    [langTags addObject:@(tag)];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (onUpdate && !self->_cancelled.load() && self->_captionGeneration.load() == gen) {
                    onUpdate(langTags);
                }
            });
        }
    });
}

- (nullable TVTestCaptionCue *)captionAtTimeMs:(int64_t)timeMs languageTag:(uint8_t)languageTag {
    if (timeMs < 0) {
        return nil;
    }
    std::lock_guard<std::mutex> guard(_dataLock);
    if (_captionCues.empty()) {
        return nil;
    }
    auto it = std::upper_bound(_captionCues.begin(), _captionCues.end(), timeMs,
                               [](int64_t t, TVTestCaptionCue *cue) {
                                   return t < cue.timeMs;
                               });
    while (it != _captionCues.begin()) {
        --it;
        TVTestCaptionCue *cue = *it;
        if (cue.languageTag != languageTag) {
            continue;
        }
        if (timeMs - cue.timeMs > kCaptionAutoExpireMs) {
            return nil;
        }
        if (cue.text.length == 0) {
            return nil;
        }
        return cue;
    }
    return nil;
}

- (NSArray<TVTestCaptionCue *> *)allCaptionCuesForLanguageTag:(uint8_t)languageTag {
    std::lock_guard<std::mutex> guard(_dataLock);
    NSMutableArray<TVTestCaptionCue *> *result = [NSMutableArray array];
    for (TVTestCaptionCue *cue : _captionCues) {
        if (cue.languageTag == languageTag && cue.text.length > 0) {
            [result addObject:cue];
        }
    }
    return result;
}

- (NSArray<TVTestEPGServiceEntry *> *)currentEPGServices {
    std::lock_guard<std::mutex> guard(_dataLock);
    return _epgServices ?: @[];
}

- (TVTestStreamStats *)currentStreamStats {
    std::lock_guard<std::mutex> guard(_dataLock);
    return _streamStats ?: _initialSnapshot.streamStats;
}

- (nullable NSData *)logoPNGDataForServiceID:(uint16_t)serviceID {
    std::lock_guard<std::mutex> guard(_dataLock);
    auto it = _serviceLogos.find(serviceID);
    return (it != _serviceLogos.end()) ? it->second : nil;
}

- (BOOL)exportServiceID:(uint16_t)serviceID
                  toURL:(NSURL *)outputURL
               progress:(nullable void (^)(double fraction))progress
                  error:(NSError **)error {
    NSURL *dir = [outputURL URLByDeletingLastPathComponent];
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
        return NO;
    }

    LibISDB::FileStreamPOSIX inStream;
    if (!inStream.Open(_url.fileSystemRepresentation, LibISDB::FileStreamBase::OpenFlag::Read)) {
        if (error) *error = MakeSessionError(@"入力録画を開けませんでした。");
        return NO;
    }
    if (!inStream.SetPos(static_cast<LibISDB::Stream::OffsetType>(_packetOffset),
                         LibISDB::Stream::SetPosType::Begin)) {
        if (error) *error = MakeSessionError(@"入力録画のシークに失敗しました。");
        return NO;
    }

    LibISDB::FileStreamPOSIX outStream;
    if (!outStream.Open(outputURL.fileSystemRepresentation,
                        LibISDB::FileStreamBase::OpenFlag::Write | LibISDB::FileStreamBase::OpenFlag::Truncate)) {
        if (error) *error = MakeSessionError(@"出力 TS ファイルを作成できませんでした。");
        return NO;
    }

    auto parser = std::make_unique<LibISDB::TSPacketParserFilter>();
    auto selector = std::make_unique<LibISDB::ServiceSelectorFilter>();
    auto writer = std::make_unique<PacketWriterSink>(outStream);

    if (serviceID != 0) {
        selector->SetTargetServiceID(serviceID, LibISDB::StreamSelector::StreamFlag::All);
        parser->SetOutputFilter(selector.get(), selector.get());
        selector->SetOutputFilter(writer.get(), writer.get());
    } else {
        parser->SetOutputFilter(writer.get(), writer.get());
    }

    LibISDB::DataBuffer buffer;
    LibISDB::SingleDataStream dataStream(&buffer);
    const size_t bytesPerRead = (kReadBytes / _packetStride) * _packetStride;
    std::vector<uint8_t> rawBuf(bytesPerRead);
    std::vector<uint8_t> normBuf(bytesPerRead);

    uint64_t totalRead = 0;
    const uint64_t totalBytes = (_fileSize > _packetOffset) ? (_fileSize - _packetOffset) : 1;

    while (true) {
        const size_t n = inStream.Read(rawBuf.data(), bytesPerRead);
        if (n == 0) {
            break;
        }
        totalRead += n;

        size_t consumed = 0;
        size_t written = 0;
        while (n - consumed >= kPacketSize) {
            if (rawBuf[consumed] == 0x47) {
                std::memcpy(normBuf.data() + written, rawBuf.data() + consumed, kPacketSize);
                written += kPacketSize;
                consumed += std::min(_packetStride, n - consumed);
            } else {
                ++consumed;
            }
        }
        if (written > 0) {
            buffer.SetData(normBuf.data(), written);
            parser->ReceiveData(&dataStream);
            if (writer->WriteFailed()) {
                outStream.Close();
                if (error) *error = MakeSessionError(@"TS 書き出し中に書き込みエラーが発生しました。");
                return NO;
            }
        }
        if (progress) {
            progress(std::min(1.0, static_cast<double>(totalRead) / static_cast<double>(totalBytes)));
        }
    }

    outStream.Flush();
    outStream.Close();
    if (writer->WrittenPackets() == 0) {
        if (error) *error = MakeSessionError(@"指定サービスのパケットを出力できませんでした。");
        return NO;
    }
    return YES;
}

+ (NSArray<TVTestEPGServiceEntry *> *)loadPersistedEPGFromPath:(NSString *)epgDataPath {
    if (!epgDataPath.length) {
        return @[];
    }
    auto db = std::make_unique<LibISDB::EPGDatabase>();
    db->SetNoPastEvents(false);
    db->SetScheduleOnly(false);
    LibISDB::EPGDataFile file;
    if (!file.Open(db.get(), epgDataPath.fileSystemRepresentation, LibISDB::EPGDataFile::OpenFlag::Read)) {
        return @[];
    }
    const bool ok = file.Load();
    file.Close();
    if (!ok) {
        return @[];
    }
    std::map<uint16_t, NSString *> emptyNames;
    return BuildEPGServiceEntries(*db, emptyNames);
}

+ (BOOL)exportEPGServices:(NSArray<TVTestEPGServiceEntry *> *)services
                toJSONURL:(NSURL *)outputURL
                    error:(NSError **)error {
    NSMutableArray *jsonServices = [NSMutableArray arrayWithCapacity:services.count];
    for (TVTestEPGServiceEntry *svc in services) {
        NSMutableArray *jsonEvents = [NSMutableArray arrayWithCapacity:svc.events.count];
        for (TVTestEPGEvent *ev in svc.events) {
            [jsonEvents addObject:@{
                @"eventID": @(ev.eventID),
                @"date": ev.dateText,
                @"timeRange": ev.timeRangeText,
                @"durationSeconds": @(ev.durationSeconds),
                @"genre": ev.genreText,
                @"title": ev.title,
                @"description": ev.descriptionText,
                @"extended": ev.extendedText,
            }];
        }
        [jsonServices addObject:@{
            @"networkID": @(svc.networkID),
            @"transportStreamID": @(svc.transportStreamID),
            @"serviceID": @(svc.serviceID),
            @"serviceName": svc.serviceName,
            @"events": jsonEvents,
        }];
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@{@"services": jsonServices}
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:error];
    if (!jsonData) {
        return NO;
    }
    return [jsonData writeToURL:outputURL options:NSDataWritingAtomic error:error];
}

+ (NSString *)formatSRTFromCues:(NSArray<TVTestCaptionCue *> *)cues {
    NSMutableString *out = [NSMutableString string];
    NSUInteger index = 1;
    for (NSUInteger i = 0; i < cues.count; ++i) {
        TVTestCaptionCue *cue = cues[i];
        if (!cue.text.length) {
            continue;
        }
        int64_t startMs = cue.timeMs;
        int64_t endMs = startMs + 5000;
        if (i + 1 < cues.count) {
            int64_t nextMs = cues[i + 1].timeMs;
            if (nextMs > startMs) {
                endMs = std::min<int64_t>(endMs, nextMs);
            }
        }
        [out appendFormat:@"%lu\n%@ --> %@\n%@\n\n",
         (unsigned long)index++,
         FormatSRTTimestamp(startMs),
         FormatSRTTimestamp(endMs),
         cue.text];
    }
    return out;
}

+ (NSString *)formatPlainTextFromCues:(NSArray<TVTestCaptionCue *> *)cues {
    NSMutableString *out = [NSMutableString string];
    for (TVTestCaptionCue *cue in cues) {
        if (!cue.text.length) {
            continue;
        }
        int64_t sec = std::max<int64_t>(0, cue.timeMs) / 1000;
        [out appendFormat:@"[%02lld:%02lld:%02lld] %@\n",
         sec / 3600, (sec / 60) % 60, sec % 60,
         [cue.text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
    }
    return out;
}

@end
