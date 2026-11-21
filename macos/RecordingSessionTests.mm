// SPDX-License-Identifier: GPL-2.0-or-later
#import "TSRecordingSession.h"
#import "LiveTunerSession.h"
#import "TVTestSettings.h"
#include "LibISDB.hpp"
#include "Utilities/CRC.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

int g_failures = 0;

void Expect(bool cond, const char *expr, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, expr);
        ++g_failures;
    }
}

#define EXPECT(x) Expect((x), #x, __LINE__)

void AppendTSPacket(std::vector<uint8_t> &out, bool m2ts, uint16_t pid,
                    bool pusi, uint8_t &cc, const uint8_t *payload, size_t len,
                    int64_t pcr90k = -1) {
    uint8_t pkt[188];
    std::memset(pkt, 0xFF, sizeof(pkt));
    pkt[0] = 0x47;
    pkt[1] = static_cast<uint8_t>((pusi ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
    pkt[2] = static_cast<uint8_t>(pid & 0xFF);

    const bool hasPayload = payload != nullptr && len > 0;
    if (pcr90k >= 0) {
        // Adaptation field with PCR (8 bytes minimum: len + flags + 6-byte PCR)
        const size_t maxPayload = 188 - 4 - 8;
        const size_t copyLen = hasPayload ? std::min(len, maxPayload) : 0;
        const size_t afLen = (188 - 4 - copyLen) - 1;
        pkt[3] = static_cast<uint8_t>((hasPayload ? 0x30 : 0x20) | (cc++ & 0x0F));
        pkt[4] = static_cast<uint8_t>(afLen);
        pkt[5] = 0x10; // PCR_flag
        const uint64_t base = static_cast<uint64_t>(pcr90k) & 0x1FFFFFFFFULL;
        pkt[6] = static_cast<uint8_t>((base >> 25) & 0xFF);
        pkt[7] = static_cast<uint8_t>((base >> 17) & 0xFF);
        pkt[8] = static_cast<uint8_t>((base >> 9) & 0xFF);
        pkt[9] = static_cast<uint8_t>((base >> 1) & 0xFF);
        pkt[10] = static_cast<uint8_t>(((base & 0x01) << 7) | 0x7E);
        pkt[11] = 0x00;
        if (copyLen > 0) {
            std::memcpy(pkt + 4 + 1 + afLen, payload, copyLen);
        }
    } else if (hasPayload && len < 184) {
        const size_t stuff = 184 - len;
        pkt[3] = static_cast<uint8_t>(0x30 | (cc++ & 0x0F));
        pkt[4] = static_cast<uint8_t>(stuff - 1);
        if (stuff > 1) {
            pkt[5] = 0x00;
        }
        std::memcpy(pkt + 4 + stuff, payload, len);
    } else {
        pkt[3] = static_cast<uint8_t>(0x10 | (cc++ & 0x0F));
        if (hasPayload) {
            std::memcpy(pkt + 4, payload, std::min<size_t>(len, 184));
        }
    }

    if (m2ts) {
        const uint8_t hdr[4] = {0x00, 0x00, 0x00, 0x00};
        out.insert(out.end(), hdr, hdr + 4);
    }
    out.insert(out.end(), pkt, pkt + 188);
}

void AppendPSISection(std::vector<uint8_t> &out, bool m2ts, uint16_t pid,
                      uint8_t &cc, const std::vector<uint8_t> &sectionWithNoCRC,
                      bool includeCRC = true) {
    std::vector<uint8_t> sec = sectionWithNoCRC;
    const size_t sectionLen = sec.size() - 3 + (includeCRC ? 4 : 0);
    sec[1] = static_cast<uint8_t>((sec[1] & 0xF0) | ((sectionLen >> 8) & 0x0F));
    sec[2] = static_cast<uint8_t>(sectionLen & 0xFF);
    if (includeCRC) {
        const uint32_t crc = LibISDB::CRC32MPEG2::Calc(sec.data(), sec.size());
        sec.push_back(static_cast<uint8_t>((crc >> 24) & 0xFF));
        sec.push_back(static_cast<uint8_t>((crc >> 16) & 0xFF));
        sec.push_back(static_cast<uint8_t>((crc >> 8) & 0xFF));
        sec.push_back(static_cast<uint8_t>(crc & 0xFF));
    }

    // Prefix pointer_field = 0x00 on first packet
    std::vector<uint8_t> buf;
    buf.push_back(0x00);
    buf.insert(buf.end(), sec.begin(), sec.end());

    size_t off = 0;
    bool first = true;
    while (off < buf.size()) {
        const size_t chunk = std::min<size_t>(184, buf.size() - off);
        uint8_t payload[184];
        std::memset(payload, 0xFF, sizeof(payload));
        std::memcpy(payload, buf.data() + off, chunk);
        AppendTSPacket(out, m2ts, pid, first, cc, payload, 184);
        off += chunk;
        first = false;
    }
}

void AppendPES(std::vector<uint8_t> &out, bool m2ts, uint16_t pid,
               uint8_t &cc, const std::vector<uint8_t> &pes) {
    size_t off = 0;
    bool first = true;
    while (off < pes.size()) {
        const size_t chunk = std::min<size_t>(184, pes.size() - off);
        AppendTSPacket(out, m2ts, pid, first, cc, pes.data() + off, chunk);
        off += chunk;
        first = false;
    }
}

std::vector<uint8_t> BuildCaptionPES(uint8_t dataGroupID, int64_t pts, const std::vector<uint8_t> &body) {
    std::vector<uint8_t> group;
    group.push_back(static_cast<uint8_t>(dataGroupID << 2));
    group.push_back(0x00);
    group.push_back(0x00);
    group.push_back(static_cast<uint8_t>((body.size() >> 8) & 0xFF));
    group.push_back(static_cast<uint8_t>(body.size() & 0xFF));
    group.insert(group.end(), body.begin(), body.end());
    const uint16_t crc = LibISDB::CRC16CCITT::Calc(group.data(), group.size());
    group.push_back(static_cast<uint8_t>((crc >> 8) & 0xFF));
    group.push_back(static_cast<uint8_t>(crc & 0xFF));

    std::vector<uint8_t> payload = {0x80, 0xFF, 0xF0};
    payload.insert(payload.end(), group.begin(), group.end());

    std::vector<uint8_t> pes = {0x00, 0x00, 0x01, 0xBD};
    const uint16_t pesLen = static_cast<uint16_t>(3 + 5 + payload.size());
    pes.push_back(static_cast<uint8_t>(pesLen >> 8));
    pes.push_back(static_cast<uint8_t>(pesLen & 0xFF));
    pes.push_back(0x80);
    pes.push_back(0x80); // PTS
    pes.push_back(0x05);
    pes.push_back(static_cast<uint8_t>(0x21 | (((pts >> 30) & 0x07) << 1)));
    pes.push_back(static_cast<uint8_t>((pts >> 22) & 0xFF));
    pes.push_back(static_cast<uint8_t>(0x01 | (((pts >> 15) & 0x7F) << 1)));
    pes.push_back(static_cast<uint8_t>((pts >> 7) & 0xFF));
    pes.push_back(static_cast<uint8_t>(0x01 | ((pts & 0x7F) << 1)));
    pes.insert(pes.end(), payload.begin(), payload.end());
    return pes;
}

// Build a valid synthetic multi-service ISDB TS/M2TS stream
std::vector<uint8_t> BuildSyntheticStream(bool m2ts) {
    std::vector<uint8_t> out;
    uint8_t ccPAT = 0, ccPMT1 = 0, ccPMT2 = 0, ccSDT = 0, ccEIT = 0, ccTOT = 0, ccPCR = 0, ccCap = 0;

    // 1. PAT (TSID 0x7FE0): SID 101 -> PMT 0x0100, SID 102 -> PMT 0x0200
    std::vector<uint8_t> pat = {
        0x00, 0xB0, 0x00,
        0x7F, 0xE0, // TSID
        0xC1, 0x00, 0x00,
        0x00, 0x65, 0xE1, 0x00, // SID 101, PMT 0x0100
        0x00, 0x66, 0xE2, 0x00, // SID 102, PMT 0x0200
    };
    AppendPSISection(out, m2ts, 0x0000, ccPAT, pat);

    // 2. PMT for SID 101 (PCR 0x01FF, Video 0x0111 MPEG2, Audio 0x0112 AAC, Caption 0x0130 Private + StreamID tag 0x30)
    std::vector<uint8_t> pmt1 = {
        0x02, 0xB0, 0x00,
        0x00, 0x65, // SID 101
        0xC1, 0x00, 0x00,
        0xE1, 0xFF, // PCR PID 0x01FF
        0xF0, 0x00, // program_info_length = 0
        // Video ES: stream_type 0x02, PID 0x0111
        0x02, 0xE1, 0x11, 0xF0, 0x00,
        // Audio ES 1: stream_type 0x0F (AAC), PID 0x0112
        0x0F, 0xE1, 0x12, 0xF0, 0x03, 0x52, 0x01, 0x10,
        // Caption ES: stream_type 0x06, PID 0x0130, StreamIdentifierDescriptor(0x52, len=1, tag=0x30)
        0x06, 0xE1, 0x30, 0xF0, 0x03, 0x52, 0x01, 0x30,
    };
    AppendPSISection(out, m2ts, 0x0100, ccPMT1, pmt1);

    // 3. PMT for SID 102 (PCR 0x02FF, Video 0x0211, Audio 0x0212)
    std::vector<uint8_t> pmt2 = {
        0x02, 0xB0, 0x00,
        0x00, 0x66,
        0xC1, 0x00, 0x00,
        0xE2, 0xFF,
        0xF0, 0x00,
        0x02, 0xE2, 0x11, 0xF0, 0x00,
        0x0F, 0xE2, 0x12, 0xF0, 0x00,
    };
    AppendPSISection(out, m2ts, 0x0200, ccPMT2, pmt2);

    // 4. SDT actual (table_id 0x42, TSID 0x7FE0, ONID 0x7FE0)
    // Prefix 0x0E (LS1 -> G1 Alphanumeric) + 0x89 (SSZ/MSZ or half-width) -> 0x0E selects Alphanumeric (fullwidth or ASCII with 0x89 MSZ)
    // With 0x89 (MSZ) + 0x0E (LS1 -> G1 Alphanumeric), ASCII decodes as half-width ASCII!
    std::vector<uint8_t> sdt = {
        0x42, 0xF0, 0x00,
        0x7F, 0xE0, // TSID
        0xC1, 0x00, 0x00,
        0x7F, 0xE0, // ONID
        0xFF,
        // Service 101: MSZ(0x89) + LS1(0x0E) + "NHK1" (6 bytes)
        0x00, 0x65, 0xFC, 0x80, 0x0B,
        0x48, 0x09, 0x01, 0x00, 0x06, 0x89, 0x0E, 'N', 'H', 'K', '1',
        // Service 102: MSZ(0x89) + LS1(0x0E) + "NHK2" (6 bytes)
        0x00, 0x66, 0xFC, 0x80, 0x0B,
        0x48, 0x09, 0x01, 0x00, 0x06, 0x89, 0x0E, 'N', 'H', 'K', '2',
    };
    AppendPSISection(out, m2ts, 0x0011, ccSDT, sdt);

    // 5. TOT (table_id 0x73, MJD for 2026-11-20 = 61364 = 0xEFB4, 21:00:00 BCD)
    std::vector<uint8_t> tot = {
        0x73, 0x70, 0x00,
        0xEF, 0xB4, 0x21, 0x00, 0x00,
        0xF0, 0x00,
    };
    AppendPSISection(out, m2ts, 0x0014, ccTOT, tot, true);

    // 6. Initial PCR = 90000 (1.0s)
    AppendTSPacket(out, m2ts, 0x01FF, false, ccPCR, nullptr, 0, 90000);

    // 7. EIT[p/f] present (section 0) & following (section 1) for SID 101
    // Event 0x0001: "News 9", desc "Main news", start 2026-11-20 21:00:00, dur 00:30:00
    std::vector<uint8_t> eitPresent = {
        0x4E, 0xF0, 0x00,
        0x00, 0x65, // SID 101
        0xC1, 0x00, 0x01, // section 0, last 1
        0x7F, 0xE0, // TSID
        0x7F, 0xE0, // ONID
        0x01, 0x4E,
        // Event 0x0001
        0x00, 0x01,
        0xEF, 0xB4, 0x21, 0x00, 0x00, // start
        0x00, 0x30, 0x00, // duration 30m
        0x80, 0x1A, // running=4, desc_loop_len = 26
        // ShortEventDescriptor (0x4D): len 24
        0x4D, 0x18, 'j', 'p', 'n',
        0x08, 0x89, 0x0E, 'N', 'e', 'w', 's', ' ', '9',
        0x0B, 0x89, 0x0E, 'M', 'a', 'i', 'n', ' ', 'n', 'e', 'w', 's',
    };
    AppendPSISection(out, m2ts, 0x0012, ccEIT, eitPresent);

    std::vector<uint8_t> eitFollowing = {
        0x4E, 0xF0, 0x00,
        0x00, 0x65,
        0xC1, 0x01, 0x01,
        0x7F, 0xE0,
        0x7F, 0xE0,
        0x01, 0x4E,
        0x00, 0x02,
        0xEF, 0xB4, 0x21, 0x30, 0x00,
        0x00, 0x30, 0x00,
        0x80, 0x15,
        0x4D, 0x13, 'j', 'p', 'n',
        0x08, 0x89, 0x0E, 'S', 'p', 'o', 'r', 't', 's',
        0x06, 0x89, 0x0E, 'L', 'i', 'v', 'e',
    };
    AppendPSISection(out, m2ts, 0x0012, ccEIT, eitFollowing);

    // 8. EIT[schedule] (table_id 0x50) for SID 101
    std::vector<uint8_t> eitSched = {
        0x50, 0xF0, 0x00,
        0x00, 0x65,
        0xC1, 0x00, 0x00,
        0x7F, 0xE0,
        0x7F, 0xE0,
        0x00, 0x50,
        // Event 0x0010 at 22:00
        0x00, 0x10,
        0xEF, 0xB4, 0x22, 0x00, 0x00,
        0x01, 0x00, 0x00,
        0x00, 0x16,
        0x4D, 0x14, 'j', 'p', 'n',
        0x07, 0x89, 0x0E, 'D', 'r', 'a', 'm', 'a',
        0x08, 0x89, 0x0E, 'E', 'p', 'i', 's', 'o', 'd',
    };
    AppendPSISection(out, m2ts, 0x0012, ccEIT, eitSched);

    // 9. ARIB Caption management + caption cue at PTS 270000 (rel 2000ms) + clear screen at PTS 630000 (rel 6000ms)
    std::vector<uint8_t> capMgmt = {
        0x3F, 0x01,
        0x10, 'j', 'p', 'n', 0x00,
        0x00, 0x00, 0x00,
    };
    AppendPES(out, m2ts, 0x0130, ccCap, BuildCaptionPES(0x00, 90000, capMgmt));

    // CS (0x0C) + designate Katakana to G2 (GR) + "テレビ"
    const uint8_t capText[] = {0x0C, 0x1B, 0x2A, 0x31, 0xC6, 0xEC, 0xD3};
    std::vector<uint8_t> capStmt = {
        0x3F, 0x00, 0x00, static_cast<uint8_t>(5 + sizeof(capText)),
        0x1F, 0x20, 0x00, 0x00, static_cast<uint8_t>(sizeof(capText)),
    };
    capStmt.insert(capStmt.end(), capText, capText + sizeof(capText));
    AppendPES(out, m2ts, 0x0130, ccCap, BuildCaptionPES(0x01, 270000, capStmt));

    // Clear screen only at PTS 630000 (rel 6000ms)
    std::vector<uint8_t> capClear = {
        0x3F, 0x00, 0x00, 6,
        0x1F, 0x20, 0x00, 0x00, 1, 0x0C,
    };
    AppendPES(out, m2ts, 0x0130, ccCap, BuildCaptionPES(0x01, 630000, capClear));

    // 10. Later PCR = 450000 (5.0s -> 4.0s elapsed) so bitrate estimation works
    for (int i = 0; i < 64; ++i) {
        AppendTSPacket(out, m2ts, 0x1FFF, false, ccPCR, nullptr, 0);
    }
    AppendTSPacket(out, m2ts, 0x01FF, false, ccPCR, nullptr, 0, 450000);

    return out;
}

void RunFormatTest(bool m2ts) {
    NSString *path = m2ts ? @"/tmp/tvtest_session_test.m2ts" : @"/tmp/tvtest_session_test.ts";
    std::vector<uint8_t> data = BuildSyntheticStream(m2ts);
    NSData *nsData = [NSData dataWithBytes:data.data() length:data.size()];
    EXPECT([nsData writeToFile:path atomically:YES]);

    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    TVTestRecordingSession *session = [TVTestRecordingSession sessionWithURL:url error:&error];
    EXPECT(session != nil);
    EXPECT(error == nil);
    if (!session) {
        return;
    }

    EXPECT(session.packetStride == (m2ts ? 192u : 188u));
    TVTestRecordingSnapshot *snap = session.initialSnapshot;
    EXPECT(snap.services.count == 2);
    EXPECT(snap.totTimeText.length > 0);
    EXPECT(snap.estimatedBitrateMbps > 0.0);

    TVTestServiceInfo *svc1 = [snap serviceWithID:101];
    EXPECT(svc1 != nil);
    EXPECT([svc1.name isEqualToString:@"NHK1"]);
    EXPECT(svc1.hasCaptions);
    EXPECT(svc1.audioStreams.count == 1);
    EXPECT(svc1.currentProgram != nil);
    EXPECT([svc1.currentProgram.title isEqualToString:@"News 9"]);
    EXPECT([svc1.currentProgram.descriptionText isEqualToString:@"Main news"]);
    EXPECT(svc1.nextProgram != nil);
    EXPECT([svc1.nextProgram.title isEqualToString:@"Sports"]);

    TVTestServiceInfo *svc2 = [snap serviceWithID:102];
    EXPECT(svc2 != nil);
    EXPECT([svc2.name isEqualToString:@"NHK2"]);

    // Background index for EPG + ARIB captions
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray<TVTestEPGServiceEntry *> *capturedEPG = nil;
    __block NSArray<NSNumber *> *capturedLangs = nil;
    [session startBackgroundIndexForServiceID:101
                              onCaptionUpdate:^(NSArray<NSNumber *> *languageTags) {
        capturedLangs = languageTags;
    }
                                  onEPGUpdate:^(NSArray<TVTestEPGServiceEntry *> *epgServices, BOOL finished) {
        capturedEPG = epgServices;
        if (finished) {
            dispatch_semaphore_signal(done);
        }
    }];

    // Pump main runloop briefly so dispatch_async(main_queue) fires
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0 &&
           [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    EXPECT(capturedLangs != nil && capturedLangs.count == 1);
    EXPECT(capturedEPG != nil && capturedEPG.count >= 1);
    if (capturedEPG.count >= 1) {
        EXPECT(capturedEPG[0].serviceID == 101);
        EXPECT(capturedEPG[0].events.count >= 2);
    }

    // Before caption PTS (2000ms): no caption
    EXPECT([session captionAtTimeMs:1000 languageTag:0] == nil);
    // During caption (2500ms): "テレビ"
    TVTestCaptionCue *cue = [session captionAtTimeMs:2500 languageTag:0];
    EXPECT(cue != nil);
    EXPECT([cue.text isEqualToString:@"テレビ"]);
    // After clear screen (6500ms): cleared
    EXPECT([session captionAtTimeMs:6500 languageTag:0] == nil);

    // Position-synced re-analysis at 0.0
    TVTestRecordingSnapshot *posSnap = [session analyzeSnapshotAtPosition:0.0 error:&error];
    EXPECT(posSnap != nil);
    EXPECT(posSnap.services.count == 2);

    // Stream & PID statistics
    TVTestStreamStats *stats = [session currentStreamStats];
    EXPECT(stats != nil);
    EXPECT(stats.totalPackets > 10);
    EXPECT(stats.pidStats.count >= 6);

    // Caption transcript & SRT export
    NSArray<TVTestCaptionCue *> *allCues = [session allCaptionCuesForLanguageTag:0];
    EXPECT(allCues.count == 1);
    NSString *srt = [TVTestRecordingSession formatSRTFromCues:allCues];
    EXPECT([srt containsString:@"-->"]);
    EXPECT([srt containsString:@"テレビ"]);

    // Single-service TS export via ServiceSelectorFilter (strip SID 102, keep SID 101)
    NSString *exportPath = @"/tmp/tvtest_exported_sid101.ts";
    NSURL *exportURL = [NSURL fileURLWithPath:exportPath];
    EXPECT([session exportServiceID:101 toURL:exportURL progress:nil error:&error]);
    TVTestRecordingSession *exportedSession = [TVTestRecordingSession sessionWithURL:exportURL error:&error];
    EXPECT(exportedSession != nil);
    if (exportedSession) {
        EXPECT(exportedSession.packetStride == 188u);
        EXPECT(exportedSession.initialSnapshot.services.count == 1);
        EXPECT(exportedSession.initialSnapshot.services.firstObject.serviceID == 101);
        [exportedSession cancel];
    }
    std::remove(exportPath.UTF8String);

    // Filename pattern variable expansion
    NSString *expanded = [TVTestSettings.sharedSettings expandFilenamePattern:@"%date%_%service-name%_%event-name%"
                                                                  serviceName:@"NHK1"
                                                                    eventName:@"News/9:00"];
    EXPECT([expanded containsString:@"_NHK1_News_9_00"]);

    [session cancel];
    std::remove(path.UTF8String);
}

} // namespace

@interface TestLiveDelegate : NSObject <TVTestLiveTunerSessionDelegate>
@property (atomic) uint64_t receivedBytes;
@property (atomic, strong, nullable) TVTestRecordingSnapshot *lastSnapshot;
@property (atomic) float lastCNR;
@property (atomic) BOOL lastLocked;
@end

@implementation TestLiveDelegate
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
        didReceiveTSBytes:(const uint8_t *)bytes
                   length:(NSUInteger)length {
    (void)session;
    (void)bytes;
    self.receivedBytes += length;
}
- (void)liveTunerSession:(TVTestLiveTunerSession *)session
       didUpdateSnapshot:(TVTestRecordingSnapshot *)snapshot
             signalLevel:(float)cnrDB
                  locked:(BOOL)locked
             bitrateMbps:(double)bitrateMbps
                   stats:(TVTestStreamStats *)stats {
    (void)session;
    (void)bitrateMbps;
    (void)stats;
    self.lastSnapshot = snapshot;
    self.lastCNR = cnrDB;
    self.lastLocked = locked;
}
@end

namespace {

void RunMacBonDriverLiveTest(void) {
    NSString *bundlePath = @"MacBonDriver/build/MBD_SampleUSB.bundle";
    if (![NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        bundlePath = @"../../MacBonDriver/build/MBD_SampleUSB.bundle";
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        std::printf("Skipping MacBonDriver live test (MBD_SampleUSB.bundle not found)\n");
        return;
    }

    NSString *dir = [bundlePath stringByDeletingLastPathComponent];
    NSArray<TVTestBonDriverInfo *> *discovered = [TVTestLiveTunerSession discoverBonDriversInDirectories:@[dir]];
    EXPECT(discovered.count >= 1);

    NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath];
    NSError *error = nil;
    TVTestLiveTunerSession *live = [TVTestLiveTunerSession sessionWithBundleURL:bundleURL options:nil error:&error];
    EXPECT(live != nil);
    EXPECT(error == nil);
    if (!live) return;

    EXPECT(live.tuningSpaces.count >= 3);
    EXPECT(live.supportsLNBPower);
    EXPECT(live.supportsTSMF);
    EXPECT(live.supportsSmartCard);

    TestLiveDelegate *delegate = [[TestLiveDelegate alloc] init];
    live.delegate = delegate;

    EXPECT([live openTunerWithEPGDataPath:nil logoCacheDir:nil error:&error]);
    EXPECT(live.isTunerOpen);
    EXPECT([live tuneToSpace:0 channel:0 streamID:0 error:&error]);

    // Test LNB power & SmartCard query
    EXPECT([live setLNBPowerMode:MBDLNBPower15V error:&error]);
    EXPECT(live.currentLNBPowerMode == MBDLNBPower15V);
    NSString *scStatus = [live querySmartCardStatusSummary];
    EXPECT([scStatus containsString:@"あり"]);

    // Start live recording to a temp .ts file
    NSString *recPath = @"/tmp/tvtest_live_record_test.ts";
    NSURL *recURL = [NSURL fileURLWithPath:recPath];
    std::remove(recPath.UTF8String);
    EXPECT([live startRecordingToURL:recURL serviceID:0 error:&error]);
    EXPECT(live.isRecording);

    // Pump main runloop briefly so live TS + 500ms snapshot update arrive
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while ([deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    EXPECT(delegate.receivedBytes > 0);
    EXPECT(delegate.lastSnapshot != nil);
    EXPECT(delegate.lastCNR > 0.0f);
    EXPECT(delegate.lastLocked);
    EXPECT(live.recordedBytes > 0);

    [live stopRecording];
    EXPECT(!live.isRecording);

    // Verify recorded file is valid 188-byte TS
    NSData *recData = [NSData dataWithContentsOfURL:recURL];
    EXPECT(recData.length > 0 && (recData.length % 188 == 0));
    if (recData.length > 0) {
        EXPECT(static_cast<const uint8_t *>(recData.bytes)[0] == 0x47);
    }
    std::remove(recPath.UTF8String);

    [live closeTuner];
    EXPECT(!live.isTunerOpen);

    // Also verify MBD_SQR100.bundle discovery, loading, metadata, and 4 tuning spaces (no hardware required)
    NSString *sqrPath = @"MacBonDriver/build/MBD_SQR100.bundle";
    if (![NSFileManager.defaultManager fileExistsAtPath:sqrPath]) {
        sqrPath = @"../../MacBonDriver/build/MBD_SQR100.bundle";
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:sqrPath]) {
        NSURL *sqrURL = [NSURL fileURLWithPath:sqrPath];
        NSError *sqrErr = nil;
        TVTestLiveTunerSession *sqr = [TVTestLiveTunerSession sessionWithBundleURL:sqrURL
                                                                           options:[TVTestSettings.sharedSettings driverOptionsDictionary]
                                                                             error:&sqrErr];
        EXPECT(sqr != nil);
        EXPECT(sqrErr == nil);
        if (sqr) {
            EXPECT([sqr.driverIdentifier isEqualToString:@"jp.macbondriver.sqr100"]);
            EXPECT(sqr.tuningSpaces.count >= 5); // UHF, CATV Pass-Through, BS, CS110, CATV (ISDB-C)
            EXPECT(sqr.supportsTSMF);
            EXPECT(sqr.supportsSmartCard);
            EXPECT(!sqr.isTunerOpen); // Must not prematurely open USB device
        }
    }
}

} // namespace

int main(void) {
    @autoreleasepool {
        RunFormatTest(false);
        RunFormatTest(true);
        RunMacBonDriverLiveTest();
    }
    if (g_failures == 0) {
        std::printf("TVTestRecordingSessionTests: ALL PASSED\n");
        return 0;
    }
    std::fprintf(stderr, "TVTestRecordingSessionTests: %d FAILURE(S)\n", g_failures);
    return 1;
}
