// SPDX-License-Identifier: GPL-2.0-or-later
#import "LiveTunerSession.h"
#import "TVTestCasBridge.h"
#import "TVTestSettings.h"

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

#include <atomic>
#include <chrono>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

// Reuse internal ObjC initializers from TSRecordingSession.mm via public-safe factory helpers
// (or construct cleanly here with matching LibISDB helpers).

namespace {

NSError *MakeTunerError(NSString *message) {
    return [NSError errorWithDomain:@"jp.tvtest.native.tuner"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *DecodeStr(const LibISDB::String &text) {
    if (text.empty()) return @"";
    return [[NSString alloc] initWithBytes:text.data()
                                    length:text.size()
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *FmtDateTime(const LibISDB::DateTime &dt) {
    if (!dt.IsValid()) return @"";
    return [NSString stringWithFormat:@"%04d/%02d/%02d %02d:%02d:%02d",
            dt.Year, dt.Month, dt.Day, dt.Hour, dt.Minute, dt.Second];
}

NSString *FmtTimeShort(const LibISDB::DateTime &dt) {
    if (!dt.IsValid()) return @"";
    return [NSString stringWithFormat:@"%02d:%02d", dt.Hour, dt.Minute];
}

uint8_t PrimaryGenre(const LibISDB::EventInfo::ContentNibbleInfo &n) {
    return (n.NibbleCount > 0) ? n.NibbleList[0].ContentNibbleLevel1 : 0xFF;
}

NSString *GenreName(uint8_t l1) {
    static const char *const kGenres[16] = {
        "ニュース／報道", "スポーツ", "情報／ワイドショー", "ドラマ",
        "音楽", "バラエティ", "映画", "アニメ／特撮",
        "ドキュメンタリー／教養", "劇場／公演", "趣味／教育", "福祉",
        "予備", "予備", "拡張", "その他",
    };
    return (l1 < 16) ? ([NSString stringWithUTF8String:kGenres[l1]] ?: @"") : @"";
}

NSString *FmtExtended(const LibISDB::EventInfo::ExtendedTextInfoList &list) {
    if (list.empty()) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:list.size()];
    for (const auto &item : list) {
        NSString *d = DecodeStr(item.Description);
        NSString *t = DecodeStr(item.Text);
        if (d.length && t.length) [parts addObject:[NSString stringWithFormat:@"【%@】\n%@", d, t]];
        else if (t.length) [parts addObject:t];
        else if (d.length) [parts addObject:[NSString stringWithFormat:@"【%@】", d]];
    }
    return [parts componentsJoinedByString:@"\n\n"];
}

} // namespace

// Private category declarations matching TSRecordingSession.mm initializers
@interface TVTestAudioStreamInfo (LiveInit)
- (instancetype)initWithPID:(uint16_t)pid streamType:(uint8_t)streamType componentTag:(uint8_t)componentTag label:(NSString *)label;
@end

@interface TVTestESDetail (LiveInit)
- (instancetype)initWithPID:(uint16_t)pid streamType:(uint8_t)streamType streamTypeName:(NSString *)streamTypeName category:(NSString *)category;
@end

@interface TVTestProgramInfo (LiveInit)
- (instancetype)initWithEventID:(uint16_t)eventID title:(NSString *)title descriptionText:(NSString *)descriptionText extendedText:(NSString *)extendedText startTimeText:(NSString *)startTimeText endTimeText:(NSString *)endTimeText durationSeconds:(uint32_t)durationSeconds genreLevel1:(uint8_t)genreLevel1 genreText:(NSString *)genreText videoSpecText:(NSString *)videoSpecText audioSpecText:(NSString *)audioSpecText;
@end

@interface TVTestServiceInfo (LiveInit)
- (instancetype)initWithServiceID:(uint16_t)serviceID pmtPID:(uint16_t)pmtPID pcrPID:(uint16_t)pcrPID serviceType:(uint8_t)serviceType name:(NSString *)name providerName:(NSString *)providerName videoESCount:(NSUInteger)videoESCount audioStreams:(NSArray<TVTestAudioStreamInfo *> *)audioStreams elementaryStreams:(NSArray<TVTestESDetail *> *)elementaryStreams hasCaptions:(BOOL)hasCaptions currentProgram:(nullable TVTestProgramInfo *)currentProgram nextProgram:(nullable TVTestProgramInfo *)nextProgram;
@end

@interface TVTestPIDStat (LiveInit)
- (instancetype)initWithPID:(uint16_t)pid label:(NSString *)label packetCount:(uint64_t)packetCount continuityErrorCount:(uint64_t)continuityErrorCount scrambledCount:(uint64_t)scrambledCount;
@end

@interface TVTestStreamStats (LiveInit)
- (instancetype)initWithTotal:(uint64_t)total formatError:(uint64_t)formatError transportError:(uint64_t)transportError continuityError:(uint64_t)continuityError scrambled:(uint64_t)scrambled pidStats:(NSArray<TVTestPIDStat *> *)pidStats;
@end

@interface TVTestRecordingSnapshot (LiveInit)
- (instancetype)initWithNetworkID:(uint16_t)networkID transportStreamID:(uint16_t)transportStreamID networkName:(NSString *)networkName tsName:(NSString *)tsName totTimeText:(NSString *)totTimeText estimatedBitrateMbps:(double)estimatedBitrateMbps analyzedPosition:(double)analyzedPosition services:(NSArray<TVTestServiceInfo *> *)services streamStats:(TVTestStreamStats *)streamStats;
@end

@interface TVTestCaptionFormatRun (LiveInit)
- (instancetype)initWithUTF8ByteOffset:(NSUInteger)offset charColorIndex:(uint8_t)charColor backColorIndex:(uint8_t)backColor charSize:(NSInteger)charSize;
@end

@interface TVTestCaptionCue (LiveInit)
- (instancetype)initWithTimeMs:(int64_t)timeMs languageTag:(uint8_t)languageTag text:(NSString *)text clearsScreen:(BOOL)clearsScreen formatRuns:(NSArray<TVTestCaptionFormatRun *> *)formatRuns;
@end

@interface TVTestEPGEvent (LiveInit)
- (instancetype)initWithEventInfo:(const LibISDB::EventInfo &)event;
@end

@interface TVTestEPGServiceEntry (LiveInit)
- (instancetype)initWithNetworkID:(uint16_t)networkID transportStreamID:(uint16_t)transportStreamID serviceID:(uint16_t)serviceID serviceName:(NSString *)serviceName events:(NSArray<TVTestEPGEvent *> *)events;
@end

namespace {

TVTestStreamStats *BuildLiveStats(LibISDB::TSPacketParserFilter &parser,
                                  LibISDB::AnalyzerFilter &analyzer) {
    const auto combined = parser.GetTotalPacketCount() + parser.GetPacketCount();
    std::map<uint16_t, NSString *> pidLabels;
    const int svcCount = analyzer.GetServiceCount();
    for (int i = 0; i < svcCount; ++i) {
        LibISDB::AnalyzerFilter::ServiceInfo info;
        if (!analyzer.GetServiceInfo(i, &info)) continue;
        NSString *sName = DecodeStr(info.ServiceName);
        if (!sName.length) sName = [NSString stringWithFormat:@"SID %u", info.ServiceID];
        if (info.PMTPID != LibISDB::PID_INVALID) pidLabels[info.PMTPID] = [NSString stringWithFormat:@"PMT (%@)", sName];
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
    }

    NSMutableArray<TVTestPIDStat *> *pidStats = [NSMutableArray array];
    for (uint16_t pid = 0; pid <= 0x1FFF; ++pid) {
        const auto c = parser.GetTotalPacketCount(pid) + parser.GetPacketCount(pid);
        if (c.Input == 0) continue;
        NSString *label = pidLabels[pid];
        if (!label.length) {
            const char *pre = LibISDB::GetPredefinedPIDText(pid);
            label = (pre && pre[0] != '\0') ? ([NSString stringWithUTF8String:pre] ?: @"") : @"その他";
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

TVTestProgramInfo *BuildLiveProgram(LibISDB::AnalyzerFilter &analyzer, int idx, bool next) {
    LibISDB::String name, text;
    const bool hasName = analyzer.GetEventName(idx, &name, next);
    analyzer.GetEventText(idx, &text, next);
    LibISDB::DateTime startTime;
    uint32_t duration = 0;
    analyzer.GetEventTime(idx, &startTime, &duration, next);
    if (!hasName && text.empty() && !startTime.IsValid()) return nil;

    LibISDB::EventInfo::ExtendedTextInfoList extList;
    analyzer.GetEventExtendedText(idx, &extList, true, next);
    LibISDB::AnalyzerFilter::EventContentNibble nibble;
    analyzer.GetEventContentNibble(idx, &nibble, next);

    NSString *endStr = @"";
    if (startTime.IsValid() && duration > 0) {
        LibISDB::DateTime endTime = startTime;
        endTime.OffsetSeconds(static_cast<long>(duration));
        endStr = FmtTimeShort(endTime);
    }

    NSString *vSpec = @"";
    const uint8_t vc = analyzer.GetVideoComponentType(idx);
    if (vc != LibISDB::COMPONENT_TYPE_INVALID) {
        const char *vt = LibISDB::GetVideoComponentTypeText_ja(vc);
        if (vt) vSpec = [NSString stringWithUTF8String:vt] ?: @"";
    }
    NSString *aSpec = @"";
    if (analyzer.GetAudioESCount(idx) > 0) {
        const uint8_t ac = analyzer.GetAudioComponentType(idx, 0);
        if (ac != LibISDB::COMPONENT_TYPE_INVALID) {
            const char *at = LibISDB::GetAudioComponentTypeText_ja(ac);
            if (at) aSpec = [NSString stringWithUTF8String:at] ?: @"";
        }
    }
    const uint8_t l1 = PrimaryGenre(nibble);
    return [[TVTestProgramInfo alloc] initWithEventID:analyzer.GetEventID(idx, next)
                                                title:DecodeStr(name)
                                      descriptionText:DecodeStr(text)
                                         extendedText:FmtExtended(extList)
                                        startTimeText:FmtDateTime(startTime)
                                          endTimeText:endStr
                                      durationSeconds:duration
                                          genreLevel1:l1
                                            genreText:GenreName(l1)
                                        videoSpecText:vSpec
                                        audioSpecText:aSpec];
}

TVTestRecordingSnapshot *BuildLiveSnapshot(LibISDB::TSPacketParserFilter &parser,
                                           LibISDB::AnalyzerFilter &analyzer,
                                           double bitrateMbps) {
    LibISDB::String netName, tsName;
    analyzer.GetNetworkName(&netName);
    analyzer.GetTSName(&tsName);
    LibISDB::DateTime tot;
    analyzer.GetInterpolatedTOTTime(&tot);

    NSMutableArray<TVTestServiceInfo *> *services = [NSMutableArray array];
    const int count = analyzer.GetServiceCount();
    for (int i = 0; i < count; ++i) {
        LibISDB::AnalyzerFilter::ServiceInfo info;
        if (!analyzer.GetServiceInfo(i, &info)) continue;

        NSMutableArray<TVTestAudioStreamInfo *> *audioStreams = [NSMutableArray array];
        const int aCount = analyzer.GetAudioESCount(i);
        for (int a = 0; a < aCount; ++a) {
            LibISDB::AnalyzerFilter::ESInfo es;
            if (!analyzer.GetAudioESInfo(i, a, &es)) continue;
            LibISDB::String compText;
            analyzer.GetAudioComponentText(i, a, &compText);
            NSString *label = DecodeStr(compText);
            if (!label.length) {
                const char *st = LibISDB::GetStreamTypeText(es.StreamType);
                label = [NSString stringWithFormat:@"音声 %d (%s)", a + 1, st ? st : "Audio"];
            }
            [audioStreams addObject:[[TVTestAudioStreamInfo alloc] initWithPID:es.PID
                                                                    streamType:es.StreamType
                                                                  componentTag:es.ComponentTag
                                                                         label:label]];
        }

        NSMutableArray<TVTestESDetail *> *esDetails = [NSMutableArray array];
        auto addES = [&](const LibISDB::AnalyzerFilter::ESInfoList &list, NSString *cat) {
            for (const auto &es : list) {
                const char *st = LibISDB::GetStreamTypeText(es.StreamType);
                [esDetails addObject:[[TVTestESDetail alloc] initWithPID:es.PID
                                                              streamType:es.StreamType
                                                          streamTypeName:st ? ([NSString stringWithUTF8String:st] ?: @"") : @""
                                                                category:cat]];
            }
        };
        addES(info.VideoESList, @"映像");
        addES(info.AudioESList, @"音声");
        addES(info.CaptionESList, @"字幕");
        addES(info.DataCarrouselESList, @"データ放送");

        NSString *svcName = DecodeStr(info.ServiceName);
        if (!svcName.length) svcName = [NSString stringWithFormat:@"サービス %u", info.ServiceID];
        [services addObject:[[TVTestServiceInfo alloc] initWithServiceID:info.ServiceID
                                                                  pmtPID:info.PMTPID
                                                                  pcrPID:info.PCRPID
                                                             serviceType:info.ServiceType
                                                                    name:svcName
                                                            providerName:DecodeStr(info.ProviderName)
                                                            videoESCount:info.VideoESList.size()
                                                            audioStreams:audioStreams
                                                       elementaryStreams:esDetails
                                                             hasCaptions:!info.CaptionESList.empty()
                                                          currentProgram:BuildLiveProgram(analyzer, i, false)
                                                             nextProgram:BuildLiveProgram(analyzer, i, true)]];
    }

    TVTestStreamStats *stats = BuildLiveStats(parser, analyzer);
    return [[TVTestRecordingSnapshot alloc] initWithNetworkID:analyzer.GetNetworkID()
                                            transportStreamID:analyzer.GetTransportStreamID()
                                                  networkName:DecodeStr(netName)
                                                       tsName:DecodeStr(tsName)
                                                  totTimeText:FmtDateTime(tot)
                                         estimatedBitrateMbps:bitrateMbps
                                             analyzedPosition:0.0
                                                     services:services
                                                  streamStats:stats];
}

NSArray<TVTestEPGServiceEntry *> *BuildLiveEPG(LibISDB::EPGDatabase &db,
                                               LibISDB::AnalyzerFilter &analyzer) {
    std::map<uint16_t, NSString *> names;
    const int cnt = analyzer.GetServiceCount();
    for (int i = 0; i < cnt; ++i) {
        LibISDB::String s;
        if (analyzer.GetServiceName(i, &s) && !s.empty()) {
            names[analyzer.GetServiceID(i)] = DecodeStr(s);
        }
    }
    LibISDB::EPGDatabase::ServiceList list;
    db.GetServiceList(&list);
    NSMutableArray<TVTestEPGServiceEntry *> *out = [NSMutableArray arrayWithCapacity:list.size()];
    for (const auto &svc : list) {
        LibISDB::EPGDatabase::EventList events;
        if (!db.GetEventListSortedByTime(svc.NetworkID, svc.TransportStreamID, svc.ServiceID, &events) ||
            events.empty()) continue;
        NSMutableArray<TVTestEPGEvent *> *arr = [NSMutableArray arrayWithCapacity:events.size()];
        for (const auto &ev : events) {
            [arr addObject:[[TVTestEPGEvent alloc] initWithEventInfo:ev]];
        }
        auto it = names.find(svc.ServiceID);
        NSString *n = (it != names.end() && it->second.length)
            ? it->second
            : [NSString stringWithFormat:@"サービス %u", svc.ServiceID];
        [out addObject:[[TVTestEPGServiceEntry alloc] initWithNetworkID:svc.NetworkID
                                                      transportStreamID:svc.TransportStreamID
                                                              serviceID:svc.ServiceID
                                                            serviceName:n
                                                                 events:arr]];
    }
    return out;
}

class LiveCaptionHandler final : public LibISDB::CaptionFilter::Handler {
public:
    LiveCaptionHandler(std::vector<TVTestCaptionCue *> &cues,
                       std::set<uint8_t> &languages,
                       std::mutex &lock,
                       std::chrono::steady_clock::time_point startTime,
                       void (^onCue)(TVTestCaptionCue *cue, NSArray<NSNumber *> *langs))
        : m_cues(cues), m_languages(languages), m_lock(lock), m_startTime(startTime), m_onCue(onCue) {}

    void OnLanguageUpdate(LibISDB::CaptionFilter *, LibISDB::CaptionParser *pParser) override {
        if (!pParser) return;
        std::lock_guard<std::mutex> g(m_lock);
        const int n = pParser->GetLanguageCount();
        for (int i = 0; i < n; ++i) {
            LibISDB::CaptionParser::LanguageInfo info;
            if (pParser->GetLanguageInfo(i, &info)) m_languages.insert(info.LanguageTag);
        }
    }

    void OnCaption(LibISDB::CaptionFilter *,
                   LibISDB::CaptionParser *,
                   uint8_t language,
                   const LibISDB::CharType *pText,
                   const LibISDB::ARIBStringDecoder::FormatList *pFormatList) override {
        if (!pText) return;
        const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - m_startTime).count();

        std::string raw(pText);
        bool clears = false;
        size_t stripPrefix = 0;
        while (stripPrefix < raw.size() && raw[stripPrefix] == '\f') {
            clears = true;
            ++stripPrefix;
        }
        std::string cleaned;
        std::vector<size_t> posMap(raw.size() + 1, 0);
        for (size_t i = 0; i < raw.size(); ++i) {
            posMap[i] = cleaned.size();
            if (i < stripPrefix) continue;
            if (raw[i] == '\f') { clears = true; cleaned.push_back('\n'); }
            else cleaned.push_back(raw[i]);
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
        TVTestCaptionCue *cue = [[TVTestCaptionCue alloc] initWithTimeMs:elapsedMs
                                                             languageTag:language
                                                                    text:nsText
                                                            clearsScreen:clears
                                                              formatRuns:runs];
        NSMutableArray<NSNumber *> *langs = [NSMutableArray array];
        {
            std::lock_guard<std::mutex> g(m_lock);
            m_languages.insert(language);
            if (nsText.length > 0) {
                m_cues.push_back(cue);
                if (m_cues.size() > 2000) {
                    m_cues.erase(m_cues.begin());
                }
            }
            for (uint8_t tag : m_languages) [langs addObject:@(tag)];
        }
        if (m_onCue) {
            m_onCue(cue, langs);
        }
    }

private:
    std::vector<TVTestCaptionCue *> &m_cues;
    std::set<uint8_t> &m_languages;
    std::mutex &m_lock;
    std::chrono::steady_clock::time_point m_startTime;
    void (^m_onCue)(TVTestCaptionCue *, NSArray<NSNumber *> *);
};

class LiveLogoHandler final : public LibISDB::LogoDownloaderFilter::LogoHandler {
public:
    LiveLogoHandler(std::map<uint16_t, NSData *> &logos, NSString * _Nullable cacheDir, std::mutex &lock)
        : m_logos(logos), m_cacheDir(cacheDir), m_lock(lock) {}

    void OnLogoDownloaded(const LibISDB::LogoDownloaderFilter::LogoData &Data) override {
        if (!Data.pData || Data.DataSize < 8) return;
        static const uint8_t kPNG[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
        if (std::memcmp(Data.pData, kPNG, 8) != 0) return;
        NSData *png = [NSData dataWithBytes:Data.pData length:Data.DataSize];
        std::lock_guard<std::mutex> g(m_lock);
        for (const auto &svc : Data.ServiceList) {
            auto it = m_logos.find(svc.ServiceID);
            if (it == m_logos.end() || png.length > it->second.length) {
                m_logos[svc.ServiceID] = png;
                if (m_cacheDir.length) {
                    NSString *f = [m_cacheDir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%u_%u.png", Data.NetworkID, svc.ServiceID]];
                    [png writeToFile:f atomically:YES];
                }
            }
        }
    }
private:
    std::map<uint16_t, NSData *> &m_logos;
    NSString * _Nullable m_cacheDir;
    std::mutex &m_lock;
};

class LiveRecordSink final : public LibISDB::SingleIOFilter {
public:
    explicit LiveRecordSink(std::unique_ptr<LibISDB::FileStreamPOSIX> stream, std::atomic<uint64_t> &writtenBytes)
        : m_stream(std::move(stream)), m_writtenBytes(writtenBytes) {}

    const LibISDB::CharType * GetObjectName() const noexcept override { return LIBISDB_STR("LiveRecordSink"); }

    bool ProcessData(LibISDB::DataStream *pData) override {
        if (!pData || !pData->Is<LibISDB::TSPacket>() || !m_stream || !m_stream->IsOpen()) return true;
        do {
            auto *pkt = pData->Get<LibISDB::TSPacket>();
            if (pkt && pkt->GetSize() == LibISDB::TS_PACKET_SIZE) {
                size_t w = m_stream->Write(pkt->GetData(), LibISDB::TS_PACKET_SIZE);
                m_writtenBytes.fetch_add(w);
            }
        } while (pData->Next());
        return true;
    }

    void Close() {
        if (m_stream) {
            m_stream->Flush();
            m_stream->Close();
        }
    }

private:
    std::unique_ptr<LibISDB::FileStreamPOSIX> m_stream;
    std::atomic<uint64_t> &m_writtenBytes;
};

} // namespace

@implementation TVTestBonDriverInfo
- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name identifier:(NSString *)ident systems:(NSArray<NSString *> *)systems {
    self = [super init];
    if (self) {
        _bundleURL = url;
        _displayName = [name copy];
        _driverIdentifier = [ident copy];
        _supportedSystems = [systems copy];
    }
    return self;
}
@end

@implementation TVTestTunerChannel
- (instancetype)initWithSpace:(NSUInteger)space channel:(NSUInteger)channel name:(NSString *)name freq:(uint32_t)freq streamID:(uint16_t)sid {
    self = [super init];
    if (self) {
        _spaceIndex = space;
        _channelIndex = channel;
        _name = [name copy];
        _frequencyKHz = freq;
        _streamID = sid;
    }
    return self;
}
@end

@implementation TVTestTunerSpace
- (instancetype)initWithIndex:(NSUInteger)index name:(NSString *)name channels:(NSArray<TVTestTunerChannel *> *)channels {
    self = [super init];
    if (self) {
        _index = index;
        _name = [name copy];
        _channels = [channels copy];
    }
    return self;
}
@end

@implementation TVTestChannelScanResult
- (instancetype)initWithSpace:(NSUInteger)space
                      channel:(NSUInteger)channel
                  channelName:(NSString *)channelName
                 frequencyKHz:(uint32_t)freq
                     streamID:(uint16_t)sid
                       locked:(BOOL)locked
                    signalCNR:(float)cnr
                     services:(NSArray<NSDictionary<NSString *, id> *> *)services {
    self = [super init];
    if (self) {
        _spaceIndex = space;
        _channelIndex = channel;
        _channelName = [channelName copy];
        _frequencyKHz = freq;
        _streamID = sid;
        _locked = locked;
        _signalCNR = cnr;
        _services = [services copy];
    }
    return self;
}
@end

@implementation TVTestLiveTunerSession {
    NSBundle *_bundle;
    id<MacBonDriver> _driver;
    std::atomic<bool> _running;
    std::atomic<bool> _resetFiltersRequested;
    std::atomic<bool> _scanCancelled;
    std::atomic<bool> _epgAcquireCancelled;
    std::atomic<uint16_t> _targetServiceID;
    std::thread _streamThread;

    std::mutex _dataLock;
    TVTestRecordingSnapshot *_latestSnapshot;
    std::vector<TVTestCaptionCue *> _captionCues;
    std::set<uint8_t> _captionLanguages;
    std::map<uint16_t, NSData *> _serviceLogos;
    NSArray<TVTestEPGServiceEntry *> *_epgServices;

    NSString *_epgDataPath;
    NSString *_logoCacheDir;

    // TvCas B-CAS descrambler session
    TVTestCasSession *_casSession;
    NSString *_casLastError;

    // Live recording state protected by _recordLock
    std::mutex _recordLock;
    std::atomic<bool> _isRecording;
    std::atomic<uint64_t> _recordedBytes;
    CFAbsoluteTime _recordStartTime;
    NSURL *_recordingURL;
    uint16_t _recordServiceID;
    std::unique_ptr<LibISDB::TSPacketParserFilter> _recParser;
    std::unique_ptr<LibISDB::ServiceSelectorFilter> _recSelector;
    std::unique_ptr<LiveRecordSink> _recSink;
}

+ (NSArray<TVTestBonDriverInfo *> *)discoverBonDriversInDirectories:(NSArray<NSString *> *)directories {
    NSMutableArray<TVTestBonDriverInfo *> *found = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *dir in directories) {
        if (!dir.length) continue;
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *item in items) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"bundle"]) continue;
            NSString *fullPath = [dir stringByAppendingPathComponent:item];
            NSString *resolved = [fullPath stringByResolvingSymlinksInPath];
            if ([seenPaths containsObject:resolved]) continue;

            NSBundle *bundle = [NSBundle bundleWithPath:fullPath];
            NSDictionary *info = bundle.infoDictionary;
            if (!info) continue;
            if ([info[MBDInfoAPIVersionKey] unsignedIntegerValue] != MacBonDriverAPIVersion) continue;

            NSString *name = info[MBDInfoDisplayNameKey] ?: item.stringByDeletingPathExtension;
            NSString *ident = info[MBDInfoDriverIdentifierKey] ?: bundle.bundleIdentifier ?: item;
            NSArray *systems = [info[MBDInfoSupportedSystemsKey] isKindOfClass:[NSArray class]]
                ? info[MBDInfoSupportedSystemsKey] : @[];
            [seenPaths addObject:resolved];
            [found addObject:[[TVTestBonDriverInfo alloc] initWithURL:[NSURL fileURLWithPath:fullPath]
                                                                 name:name
                                                           identifier:ident
                                                              systems:systems]];
        }
    }
    [found sortUsingComparator:^NSComparisonResult(TVTestBonDriverInfo *a, TVTestBonDriverInfo *b) {
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
    return found;
}

+ (nullable instancetype)sessionWithBundleURL:(NSURL *)bundleURL
                                      options:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                                        error:(NSError **)error {
    return [[self alloc] initWithBundleURL:bundleURL options:options error:error];
}

- (nullable instancetype)initWithBundleURL:(NSURL *)bundleURL
                                   options:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _bundleURL = bundleURL;
    _epgServices = @[];
    _bundle = [NSBundle bundleWithURL:bundleURL];
    if (!_bundle) {
        if (error) *error = MakeTunerError(@"MacBonDriver バンドルを開けませんでした。");
        return nil;
    }
    _driverIdentifier = _bundle.infoDictionary[MBDInfoDriverIdentifierKey]
        ?: _bundle.bundleIdentifier
        ?: bundleURL.lastPathComponent.stringByDeletingPathExtension;
    if (![_bundle loadAndReturnError:error]) {
        return nil;
    }
    Class principal = _bundle.principalClass;
    if (![principal conformsToProtocol:@protocol(MacBonDriver)] ||
        [principal apiVersion] != MacBonDriverAPIVersion) {
        if (error) *error = MakeTunerError(@"MacBonDriver v1.0 仕様に適合していないバンドルです。");
        return nil;
    }
    _driver = [principal driverWithBundle:_bundle options:options error:error];
    if (!_driver) {
        return nil;
    }
    _driver.delegate = self;
    _casSession = [[TVTestCasSession alloc] init];
    [self enumerateTuningSpaces];
    return self;
}

- (void)dealloc {
    [self closeTuner];
}

- (void)enumerateTuningSpaces {
    NSMutableArray<TVTestTunerSpace *> *spaces = [NSMutableArray array];
    for (NSUInteger s = 0; s < 64; ++s) {
        NSString *sName = [_driver tuningSpaceNameAtIndex:s];
        if (!sName) break;
        NSMutableArray<TVTestTunerChannel *> *channels = [NSMutableArray array];
        for (NSUInteger c = 0; c < 512; ++c) {
            NSString *cName = [_driver channelNameInSpace:s channel:c];
            if (!cName) break;
            uint32_t freq = 0;
            uint16_t sid = 0;
            if ([_driver respondsToSelector:@selector(channelInfoForSpace:channel:)]) {
                NSDictionary *info = [_driver channelInfoForSpace:s channel:c];
                freq = [info[MBDChannelInfoFrequencyKHzKey] unsignedIntValue];
                sid = [info[MBDChannelInfoStreamIDKey] unsignedShortValue];
            }
            [channels addObject:[[TVTestTunerChannel alloc] initWithSpace:s channel:c name:cName freq:freq streamID:sid]];
        }
        [spaces addObject:[[TVTestTunerSpace alloc] initWithIndex:s name:sName channels:channels]];
    }
    _tuningSpaces = spaces;
}

- (NSString *)tunerName { return _driver.tunerName ?: @"MacBonDriver"; }
- (BOOL)isTunerOpen { return _driver.isTunerOpen; }
- (NSUInteger)currentSpace { return _driver.currentSpace; }
- (NSUInteger)currentChannel { return _driver.currentChannel; }
- (float)signalLevel { return _driver.signalLevel; }

- (BOOL)supportsLNBPower {
    if ([_driver conformsToProtocol:@protocol(MacBonDriverLNBControl)]) {
        return ((id<MacBonDriverLNBControl>)_driver).supportsLNBPower;
    }
    return NO;
}

- (MBDLNBPowerMode)currentLNBPowerMode {
    if ([_driver conformsToProtocol:@protocol(MacBonDriverLNBControl)]) {
        return ((id<MacBonDriverLNBControl>)_driver).currentLNBPowerMode;
    }
    return MBDLNBPowerOff;
}

- (BOOL)setLNBPowerMode:(MBDLNBPowerMode)mode error:(NSError **)error {
    if (!self.supportsLNBPower) {
        if (error) *error = MakeTunerError(@"このチューナーは LNB 給電制御に対応していません。");
        return NO;
    }
    return [(id<MacBonDriverLNBControl>)_driver setLNBPowerMode:mode error:error];
}

- (BOOL)supportsTSMF {
    if ([_driver conformsToProtocol:@protocol(MacBonDriverTSMF)]) {
        return ((id<MacBonDriverTSMF>)_driver).supportsTSMF;
    }
    return NO;
}

- (uint16_t)currentStreamID {
    if ([_driver conformsToProtocol:@protocol(MacBonDriverTSMF)]) {
        return ((id<MacBonDriverTSMF>)_driver).currentStreamID;
    }
    return 0;
}

- (BOOL)supportsSmartCard {
    return [_driver conformsToProtocol:@protocol(MacBonDriverSmartCard)];
}

- (nullable NSString *)cardReaderName {
    if (self.supportsSmartCard) {
        return ((id<MacBonDriverSmartCard>)_driver).cardReaderName;
    }
    return nil;
}

- (BOOL)isCasOpen { return _casSession.isOpen; }
- (NSString *)casReaderName { return _casSession.readerName ?: @""; }
- (NSString *)casCardIDText { return _casSession.cardIDText ?: @""; }
- (uint64_t)casDescrambledPackets { return _casSession.descrambledPackets; }
- (uint64_t)casUndescrambledPackets { return _casSession.undescrambledPackets; }
- (uint64_t)casEcmCount { return _casSession.ecmCount; }
- (uint64_t)casEcmErrorCount { return _casSession.ecmErrorCount; }
- (nullable NSString *)casLastError { return _casLastError; }

- (BOOL)reopenCasCardWithError:(NSError **)error {
    [_casSession close];
    _casLastError = nil;

    TVTestSettings *settings = TVTestSettings.sharedSettings;
    if (!settings.enableDescramble) {
        return YES;
    }

    _casSession.enableEMMProcess = settings.enableEMMProcess;
    NSError *err = nil;
    BOOL opened = NO;

    switch (settings.casReaderMode) {
        case TVTestCasReaderModeDriverBuiltIn:
            if (self.supportsSmartCard) {
                opened = [_casSession openWithSmartCardTransport:_driver error:&err];
            } else {
                err = MakeTunerError(@"このドライバは内蔵スマートカードリーダー非対応です。");
            }
            break;

        case TVTestCasReaderModePCSC:
            opened = [_casSession openWithPCSCReaderName:settings.casPCSCReaderName error:&err];
            break;

        case TVTestCasReaderModeAuto:
        default:
            if (self.supportsSmartCard) {
                opened = [_casSession openWithSmartCardTransport:_driver error:&err];
            }
            if (!opened) {
                NSError *pcscErr = nil;
                opened = [_casSession openWithPCSCReaderName:settings.casPCSCReaderName error:&pcscErr];
                if (!opened && pcscErr) {
                    err = err ?: pcscErr;
                }
            }
            break;
    }

    if (!opened) {
        _casLastError = err.localizedDescription ?: @"B-CAS カードを開けませんでした。";
        if (error) *error = err;
        return NO;
    }
    return YES;
}

- (NSString *)querySmartCardStatusSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (_casSession.isOpen) {
        [lines addObject:[NSString stringWithFormat:@"TvCas 状態: 接続中 (CA System: 0x%04X)", _casSession.caSystemID]];
        [lines addObject:[NSString stringWithFormat:@"使用リーダー: %@", _casSession.readerName]];
        [lines addObject:[NSString stringWithFormat:@"B-CAS カード ID: %@", _casSession.cardIDText]];
        [lines addObject:[NSString stringWithFormat:@"復号パケット: %llu / 未復号: %llu / ECM: %llu (エラー: %llu)",
                          _casSession.descrambledPackets,
                          _casSession.undescrambledPackets,
                          _casSession.ecmCount,
                          _casSession.ecmErrorCount]];
    } else if (_casLastError.length) {
        [lines addObject:[NSString stringWithFormat:@"TvCas 状態: 未接続 (%@)", _casLastError]];
    } else if (!TVTestSettings.sharedSettings.enableDescramble) {
        [lines addObject:@"TvCas 状態: スクランブル解除無効"];
    } else {
        [lines addObject:@"TvCas 状態: 未接続"];
    }

    if (self.supportsSmartCard) {
        id<MacBonDriverSmartCard> sc = (id<MacBonDriverSmartCard>)_driver;
        NSError *err = nil;
        BOOL openedHere = NO;
        if (!sc.isCardOpen) {
            if ([sc openSmartCardWithError:&err]) {
                openedHere = YES;
            }
        }
        if (sc.isCardOpen) {
            BOOL present = NO;
            NSData *atr = nil;
            if ([sc isCardPresent:&present atr:&atr error:&err]) {
                NSMutableString *atrHex = [NSMutableString string];
                const uint8_t *b = static_cast<const uint8_t *>(atr.bytes);
                for (NSUInteger i = 0; i < atr.length; ++i) {
                    [atrHex appendFormat:@"%02X ", b[i]];
                }
                [lines addObject:[NSString stringWithFormat:@"内蔵リーダー: %@ (カード: %@, ATR: %@)",
                                  sc.cardReaderName ?: @"内蔵リーダー",
                                  present ? @"あり" : @"なし",
                                  atrHex.length ? [atrHex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"-"]];
            }
            if (openedHere) {
                [sc closeSmartCard];
            }
        }
    }

    NSArray<NSString *> *pcsc = [TVTestCasSession availablePCSCReaders];
    if (pcsc.count > 0) {
        [lines addObject:[NSString stringWithFormat:@"検出 PC/SC リーダー: %@", [pcsc componentsJoinedByString:@", "]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (BOOL)isRecording { return _isRecording.load(); }
- (NSURL *)recordingURL {
    std::lock_guard<std::mutex> g(_recordLock);
    return _recordingURL;
}
- (uint64_t)recordedBytes { return _recordedBytes.load(); }
- (NSTimeInterval)recordingDuration {
    if (!_isRecording.load()) return 0.0;
    return MAX(0.0, CFAbsoluteTimeGetCurrent() - _recordStartTime);
}

- (BOOL)openTunerWithEPGDataPath:(nullable NSString *)epgDataPath
                    logoCacheDir:(nullable NSString *)logoCacheDir
                           error:(NSError **)error {
    if (_running.load()) {
        return YES;
    }
    _epgDataPath = [epgDataPath copy];
    _logoCacheDir = [logoCacheDir copy];
    if (![_driver openTunerWithError:error]) {
        return NO;
    }
    // Open B-CAS card (best-effort; unencrypted streams or sample drivers still work if absent).
    [self reopenCasCardWithError:NULL];
    _running.store(true);
    _streamThread = std::thread([self]() {
        @autoreleasepool {
            [self streamingLoop];
        }
    });
    return YES;
}

- (void)closeTuner {
    [self stopRecording];
    _running.store(false);
    [_driver closeTuner];
    if (_streamThread.joinable()) {
        _streamThread.join();
    }
    [_casSession close];
}

- (BOOL)tuneToSpace:(NSUInteger)space
            channel:(NSUInteger)channel
           streamID:(uint16_t)streamID
              error:(NSError **)error {
    if (!_driver.isTunerOpen) {
        if (error) *error = MakeTunerError(@"チューナーが開かれていません。");
        return NO;
    }
    BOOL ok = NO;
    if (streamID > 0 && self.supportsTSMF) {
        ok = [(id<MacBonDriverTSMF>)_driver setSpace:space channel:channel streamID:streamID error:error];
    } else {
        ok = [_driver setSpace:space channel:channel error:error];
    }
    if (ok) {
        {
            std::lock_guard<std::mutex> g(_dataLock);
            _captionCues.clear();
            _captionLanguages.clear();
        }
        _resetFiltersRequested.store(true);
    }
    return ok;
}

- (void)setActiveServiceID:(uint16_t)serviceID {
    _targetServiceID.store(serviceID);
}

- (BOOL)startRecordingToURL:(NSURL *)outputURL
                  serviceID:(uint16_t)serviceID
                      error:(NSError **)error {
    std::lock_guard<std::mutex> g(_recordLock);
    if (_isRecording.load()) {
        if (error) *error = MakeTunerError(@"すでに録画中です。");
        return NO;
    }
    NSURL *dir = [outputURL URLByDeletingLastPathComponent];
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
        return NO;
    }
    auto stream = std::make_unique<LibISDB::FileStreamPOSIX>();
    if (!stream->Open(outputURL.fileSystemRepresentation,
                      LibISDB::FileStreamBase::OpenFlag::Write | LibISDB::FileStreamBase::OpenFlag::Truncate)) {
        if (error) *error = MakeTunerError(@"録画ファイルを作成できませんでした。");
        return NO;
    }

    _recordedBytes.store(0);
    _recordStartTime = CFAbsoluteTimeGetCurrent();
    _recordingURL = outputURL;
    _recordServiceID = serviceID;

    _recParser = std::make_unique<LibISDB::TSPacketParserFilter>();
    _recSink = std::make_unique<LiveRecordSink>(std::move(stream), _recordedBytes);
    if (serviceID != 0) {
        _recSelector = std::make_unique<LibISDB::ServiceSelectorFilter>();
        _recSelector->SetTargetServiceID(serviceID, LibISDB::StreamSelector::StreamFlag::All);
        _recParser->SetOutputFilter(_recSelector.get(), _recSelector.get());
        _recSelector->SetOutputFilter(_recSink.get(), _recSink.get());
    } else {
        _recSelector.reset();
        _recParser->SetOutputFilter(_recSink.get(), _recSink.get());
    }
    _isRecording.store(true);
    return YES;
}

- (void)stopRecording {
    std::lock_guard<std::mutex> g(_recordLock);
    if (!_isRecording.load()) {
        return;
    }
    _isRecording.store(false);
    if (_recSink) {
        _recSink->Close();
    }
    _recParser.reset();
    _recSelector.reset();
    _recSink.reset();
}

- (void)streamingLoop {
    auto epgDB = std::make_unique<LibISDB::EPGDatabase>();
    epgDB->SetNoPastEvents(false);
    epgDB->SetScheduleOnly(false);

    auto parser = std::make_unique<LibISDB::TSPacketParserFilter>();
    auto analyzer = std::make_unique<LibISDB::AnalyzerFilter>();
    auto epgFilter = std::make_unique<LibISDB::EPGDatabaseFilter>();
    auto captionFilter = std::make_unique<LibISDB::CaptionFilter>();
    auto logoFilter = std::make_unique<LibISDB::LogoDownloaderFilter>();

    epgFilter->SetEPGDatabase(epgDB.get());

    const auto startClock = std::chrono::steady_clock::now();
    __weak TVTestLiveTunerSession *weakSelf = self;
    LiveCaptionHandler captionHandler(_captionCues, _captionLanguages, _dataLock, startClock,
                                      ^(TVTestCaptionCue *cue, NSArray<NSNumber *> *langs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TVTestLiveTunerSession *s = weakSelf;
            if (s && [s.delegate respondsToSelector:@selector(liveTunerSession:didReceiveCaption:languageTags:)]) {
                [s.delegate liveTunerSession:s didReceiveCaption:cue languageTags:langs];
            }
        });
    });
    captionFilter->SetCaptionHandler(&captionHandler);

    LiveLogoHandler logoHandler(_serviceLogos, _logoCacheDir, _dataLock);
    logoFilter->SetLogoHandler(&logoHandler);

    parser->SetOutputFilter(analyzer.get(), analyzer.get());
    analyzer->SetOutputFilter(epgFilter.get(), epgFilter.get());
    epgFilter->SetOutputFilter(captionFilter.get(), captionFilter.get());
    captionFilter->SetOutputFilter(logoFilter.get(), logoFilter.get());

    LibISDB::DataBuffer buffer;
    LibISDB::SingleDataStream dataStream(&buffer);
    std::vector<uint8_t> chunkBuf(256 * 1024);

    uint16_t appliedServiceID = 0;
    auto lastEmit = std::chrono::steady_clock::now();
    auto lastEPGEmit = lastEmit;
    uint64_t bytesSinceLastEmit = 0;

    while (_running.load()) {
        if (_resetFiltersRequested.exchange(false)) {
            [_casSession reset];
            parser->Reset();
            analyzer->Reset();
            captionFilter->Reset();
            appliedServiceID = 0;
            bytesSinceLastEmit = 0;
            lastEmit = std::chrono::steady_clock::now();
        }

        const uint16_t desiredSID = _targetServiceID.load();
        if (desiredSID != 0 && desiredSID != appliedServiceID) {
            appliedServiceID = desiredSID;
            captionFilter->SetTargetStream(desiredSID);
        }

        const MBDWaitResult wr = [_driver waitTSStreamWithTimeoutMs:100];
        if (!_running.load()) {
            break;
        }
        if (wr == MBDWaitResultClosed) {
            if (!_driver.isTunerOpen) {
                break;
            }
            // Channel tune / purge epoch wake-up while tuner is still open; keep streaming.
            continue;
        }
        if (wr == MBDWaitResultReady) {
            for (int burst = 0; burst < 16 && _running.load(); ++burst) {
                NSUInteger len = 0;
                NSUInteger rem = 0;
                NSError *err = nil;
                if (![_driver readTSStreamIntoBuffer:chunkBuf.data()
                                            capacity:chunkBuf.size()
                                           bytesRead:&len
                                      remainingCount:&rem
                                               error:&err]) {
                    if (err && err.code == MBDErrorBufferTooSmall && chunkBuf.size() < 4 * 1024 * 1024) {
                        chunkBuf.resize(chunkBuf.size() * 2);
                        continue;
                    }
                    break;
                }
                if (len > 0) {
                    // 0. ARIB STD-B25 MULTI2 descramble in-place via TvCas
                    if (_casSession.isOpen) {
                        [_casSession descrambleTSBytes:chunkBuf.data() length:len];
                    }

                    const uint8_t *bytes = chunkBuf.data();
                    bytesSinceLastEmit += len;

                    // 1. Forward to LibVLC live player
                    id<TVTestLiveTunerSessionDelegate> del = self.delegate;
                    if ([del respondsToSelector:@selector(liveTunerSession:didReceiveTSBytes:length:)]) {
                        [del liveTunerSession:self didReceiveTSBytes:bytes length:len];
                    }

                    // 2. Feed LibISDB live filter pipeline
                    buffer.SetData(bytes, len);
                    parser->ReceiveData(&dataStream);

                    // 3. Feed live recorder if recording
                    if (_isRecording.load()) {
                        std::lock_guard<std::mutex> rg(_recordLock);
                        if (_isRecording.load() && _recParser) {
                            LibISDB::DataBuffer recBuf;
                            recBuf.SetData(bytes, len);
                            LibISDB::SingleDataStream recStream(&recBuf);
                            _recParser->ReceiveData(&recStream);
                        }
                    }
                }
                if (rem == 0) {
                    break;
                }
            }
        }

        const auto now = std::chrono::steady_clock::now();
        const double elapsedSec = std::chrono::duration<double>(now - lastEmit).count();
        if (elapsedSec >= 0.5) {
            const double bitrateMbps = (static_cast<double>(bytesSinceLastEmit) * 8.0 / elapsedSec) / 1000000.0;
            bytesSinceLastEmit = 0;
            lastEmit = now;

            const float cnr = _driver.signalLevel;
            BOOL locked = cnr > 0.0f;
            if ([_driver respondsToSelector:@selector(signalStatistics)]) {
                NSDictionary *st = [_driver signalStatistics];
                if (st[MBDSignalStatLockedKey]) {
                    locked = [st[MBDSignalStatLockedKey] boolValue];
                }
            }

            TVTestRecordingSnapshot *snap = BuildLiveSnapshot(*parser, *analyzer, bitrateMbps);
            TVTestStreamStats *stats = snap.streamStats;
            {
                std::lock_guard<std::mutex> g(_dataLock);
                _latestSnapshot = snap;
            }

            // Update target caption service automatically once first service is discovered
            if (appliedServiceID == 0 && snap.services.count > 0) {
                uint16_t firstSID = snap.services.firstObject.serviceID;
                _targetServiceID.store(firstSID);
                appliedServiceID = firstSID;
                captionFilter->SetTargetStream(firstSID);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                TVTestLiveTunerSession *s = weakSelf;
                if (s && [s.delegate respondsToSelector:@selector(liveTunerSession:didUpdateSnapshot:signalLevel:locked:bitrateMbps:stats:)]) {
                    [s.delegate liveTunerSession:s
                               didUpdateSnapshot:snap
                                     signalLevel:cnr
                                          locked:locked
                                     bitrateMbps:bitrateMbps
                                           stats:stats];
                }
            });
        }

        if (std::chrono::duration<double>(now - lastEPGEmit).count() >= 3.0) {
            lastEPGEmit = now;
            NSArray<TVTestEPGServiceEntry *> *epgEntries = BuildLiveEPG(*epgDB, *analyzer);
            {
                std::lock_guard<std::mutex> g(_dataLock);
                _epgServices = epgEntries;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                TVTestLiveTunerSession *s = weakSelf;
                if (s && [s.delegate respondsToSelector:@selector(liveTunerSession:didUpdateEPG:)]) {
                    [s.delegate liveTunerSession:s didUpdateEPG:epgEntries];
                }
            });
        }
    }

    epgFilter->SetEPGDatabase(nullptr);
    captionFilter->SetCaptionHandler(nullptr);
    logoFilter->SetLogoHandler(nullptr);

    if (_epgDataPath.length && epgDB->GetServiceCount() > 0) {
        auto persisted = std::make_unique<LibISDB::EPGDatabase>();
        persisted->SetNoPastEvents(false);
        persisted->SetScheduleOnly(false);
        LibISDB::EPGDataFile reader;
        if (reader.Open(persisted.get(), _epgDataPath.fileSystemRepresentation, LibISDB::EPGDataFile::OpenFlag::Read)) {
            reader.Load();
            reader.Close();
        }
        persisted->Merge(epgDB.get());
        LibISDB::EPGDataFile writer;
        if (writer.Open(persisted.get(), _epgDataPath.fileSystemRepresentation,
                        LibISDB::EPGDataFile::OpenFlag::Write | LibISDB::EPGDataFile::OpenFlag::Flush)) {
            writer.Save();
            writer.Close();
        }
    }
}

#pragma mark - MacBonDriverDelegate

- (void)bonDriver:(id<MacBonDriver>)driver
  didReceiveEvent:(MBDEventType)event
         userInfo:(nullable NSDictionary<NSString *, id> *)userInfo {
    (void)driver;
    NSString *msg = nil;
    switch (event) {
    case MBDEventDeviceDisconnected:    msg = @"USB チューナーが切断されました"; break;
    case MBDEventDeviceReconnected:     msg = @"USB チューナーが再接続されました"; break;
    case MBDEventSignalLockChanged:     msg = @"信号ロック状態が変化しました"; break;
    case MBDEventStreamOverflow:        msg = @"TS バッファオーバーフローが発生しました"; break;
    case MBDEventSmartCardStateChanged: msg = @"スマートカード状態が変化しました"; break;
    case MBDEventError:
    default:
        msg = [userInfo[@"error"] localizedDescription] ?: @"チューナードライバエラー";
        break;
    }
    __weak TVTestLiveTunerSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        TVTestLiveTunerSession *s = weakSelf;
        if (s && [s.delegate respondsToSelector:@selector(liveTunerSession:didReceiveEvent:message:)]) {
            [s.delegate liveTunerSession:s didReceiveEvent:event message:msg];
        }
    });
}

- (void)cancelChannelScan {
    _scanCancelled.store(true);
}

- (void)cancelEPGAcquisition {
    _epgAcquireCancelled.store(true);
}

- (void)acquireEPGForScannedChannels:(NSArray<NSDictionary<NSString *, id> *> *)channels
                        dwellSeconds:(double)dwellSeconds
                          onProgress:(void (^)(NSUInteger completed, NSUInteger total, NSString *channelName))onProgress
                          completion:(void (^)(BOOL cancelled))completion {
    if (!_driver.isTunerOpen || channels.count == 0) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        }
        return;
    }

    // Deduplicate physical transponders (space, channel, streamID)
    NSMutableArray<NSDictionary<NSString *, id> *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *entry in channels) {
        NSString *key = [NSString stringWithFormat:@"%lu:%lu:%u",
                         [entry[@"space"] unsignedLongValue],
                         [entry[@"channel"] unsignedLongValue],
                         [entry[@"streamID"] unsignedShortValue]];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [unique addObject:entry];
        }
    }

    const NSUInteger prevSpace = _driver.currentSpace;
    const NSUInteger prevChannel = _driver.currentChannel;
    const uint16_t prevStreamID = self.currentStreamID;
    const double dwell = MAX(2.0, MIN(30.0, dwellSeconds));
    _epgAcquireCancelled.store(false);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const NSUInteger total = unique.count;
        for (NSUInteger i = 0; i < total; ++i) {
            if (self->_epgAcquireCancelled.load() || !self->_running.load()) {
                break;
            }
            NSDictionary<NSString *, id> *entry = unique[i];
            NSUInteger sp = [entry[@"space"] unsignedIntegerValue];
            NSUInteger ch = [entry[@"channel"] unsignedIntegerValue];
            uint16_t sid = [entry[@"streamID"] unsignedShortValue];
            NSString *label = entry[@"channelName"] ?: entry[@"name"] ?: @"";

            [self tuneToSpace:sp channel:ch streamID:sid error:NULL];
            const int steps = static_cast<int>(dwell / 0.2);
            for (int s = 0; s < steps; ++s) {
                if (self->_epgAcquireCancelled.load() || !self->_running.load()) break;
                usleep(200000);
            }
            const NSUInteger done = i + 1;
            if (onProgress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    onProgress(done, total, label);
                });
            }
        }

        // Restore previous channel if tuner is still open
        if (self->_running.load() && prevSpace != MBDInvalidIndex && prevChannel != MBDInvalidIndex) {
            [self tuneToSpace:prevSpace channel:prevChannel streamID:prevStreamID error:NULL];
        }
        const BOOL wasCancelled = self->_epgAcquireCancelled.load();
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(wasCancelled);
            });
        }
    });
}

- (void)scanSpace:(NSUInteger)spaceIndex
     dwellSeconds:(double)dwellSeconds
       onProgress:(void (^)(NSUInteger completed, NSUInteger total, TVTestChannelScanResult *result))onProgress
       completion:(void (^)(NSArray<TVTestChannelScanResult *> *results, BOOL cancelled))completion {
    if (spaceIndex >= _tuningSpaces.count || !_driver.isTunerOpen) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], NO); });
        }
        return;
    }
    _scanCancelled.store(false);
    TVTestTunerSpace *space = _tuningSpaces[spaceIndex];
    NSArray<TVTestTunerChannel *> *channels = space.channels;
    const double dwell = MAX(0.4, MIN(10.0, dwellSeconds));

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<TVTestChannelScanResult *> *results = [NSMutableArray array];
        const NSUInteger total = channels.count;

        for (NSUInteger i = 0; i < total; ++i) {
            if (self->_scanCancelled.load() || !self->_running.load()) {
                break;
            }
            TVTestTunerChannel *ch = channels[i];
            {
                std::lock_guard<std::mutex> g(self->_dataLock);
                self->_latestSnapshot = nil;
            }
            NSError *tuneErr = nil;
            BOOL tuned = [self tuneToSpace:ch.spaceIndex channel:ch.channelIndex streamID:ch.streamID error:&tuneErr];
            if (tuned) {
                const int steps = static_cast<int>(dwell / 0.1);
                for (int s = 0; s < steps; ++s) {
                    if (self->_scanCancelled.load() || !self->_running.load()) break;
                    usleep(100000);
                }
            }

            float cnr = tuned ? self->_driver.signalLevel : 0.0f;
            BOOL locked = cnr > 0.0f;
            if (tuned && [self->_driver respondsToSelector:@selector(signalStatistics)]) {
                NSDictionary *st = [self->_driver signalStatistics];
                if (st[MBDSignalStatLockedKey]) {
                    locked = [st[MBDSignalStatLockedKey] boolValue];
                }
            }

            NSMutableArray<NSDictionary<NSString *, id> *> *svcList = [NSMutableArray array];
            {
                std::lock_guard<std::mutex> g(self->_dataLock);
                for (TVTestServiceInfo *svc in self->_latestSnapshot.services) {
                    [svcList addObject:@{
                        @"serviceID": @(svc.serviceID),
                        @"name": svc.name ?: @"",
                        @"space": @(ch.spaceIndex),
                        @"channel": @(ch.channelIndex),
                        @"channelName": ch.name ?: @"",
                        @"frequencyKHz": @(ch.frequencyKHz),
                        @"streamID": @(ch.streamID),
                    }];
                }
            }

            TVTestChannelScanResult *res = [[TVTestChannelScanResult alloc]
                initWithSpace:ch.spaceIndex
                      channel:ch.channelIndex
                  channelName:ch.name
                 frequencyKHz:ch.frequencyKHz
                     streamID:ch.streamID
                       locked:locked
                    signalCNR:cnr
                     services:svcList];
            [results addObject:res];

            const NSUInteger completed = i + 1;
            if (onProgress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    onProgress(completed, total, res);
                });
            }
        }

        const BOOL wasCancelled = self->_scanCancelled.load();
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(results, wasCancelled);
            });
        }
    });
}

- (NSArray<TVTestEPGServiceEntry *> *)currentEPGServices {
    std::lock_guard<std::mutex> g(_dataLock);
    return _epgServices ?: @[];
}

- (NSArray<TVTestCaptionCue *> *)allCaptionCuesForLanguageTag:(uint8_t)languageTag {
    std::lock_guard<std::mutex> g(_dataLock);
    NSMutableArray<TVTestCaptionCue *> *out = [NSMutableArray array];
    for (TVTestCaptionCue *c : _captionCues) {
        if (c.languageTag == languageTag && c.text.length > 0) {
            [out addObject:c];
        }
    }
    return out;
}

- (nullable NSData *)logoPNGDataForServiceID:(uint16_t)serviceID {
    std::lock_guard<std::mutex> g(_dataLock);
    auto it = _serviceLogos.find(serviceID);
    return (it != _serviceLogos.end()) ? it->second : nil;
}

@end
