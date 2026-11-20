// SPDX-License-Identifier: GPL-2.0-or-later
#import "RecordingInfo.h"

#include "LibISDB.hpp"
#include "Filters/AnalyzerFilter.hpp"
#include "Filters/TSPacketParserFilter.hpp"

#include <cstring>
#include <memory>

namespace {

constexpr size_t PacketSize = LibISDB::TS_PACKET_SIZE;
constexpr size_t ProbeBytes = 64 * 1024;
constexpr size_t ReadBytes = 256 * 1024;
constexpr size_t ScanLimit = 32 * 1024 * 1024;

struct PacketLayout {
    size_t stride;
    size_t offset;
};

PacketLayout DetectPacketLayout(const uint8_t *bytes, size_t length) {
    constexpr size_t syncCount = 5;
    for (size_t offset = 0; offset < length; ++offset) {
        if (bytes[offset] != 0x47) {
            continue;
        }
        for (const size_t stride : {PacketSize, PacketSize + 4}) {
            if (length - offset < syncCount * stride - (stride - PacketSize)) {
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

NSString *DecodeString(const LibISDB::String &text) {
    return [[NSString alloc] initWithBytes:text.data()
                                   length:text.size()
                                 encoding:NSUTF8StringEncoding] ?: @"";
}

NSArray<NSDictionary<NSString *, id> *> *CollectServices(LibISDB::AnalyzerFilter &analyzer) {
    NSMutableArray *services = [NSMutableArray array];
    const int count = analyzer.GetServiceCount();
    for (int index = 0; index < count; ++index) {
        LibISDB::String name, current, next, description;
        analyzer.GetServiceName(index, &name);
        analyzer.GetEventName(index, &current);
        analyzer.GetEventText(index, &description);
        analyzer.GetEventName(index, &next, true);
        [services addObject:@{
            @"serviceID": @(analyzer.GetServiceID(index)),
            @"name": DecodeString(name),
            @"current": DecodeString(current),
            @"description": DecodeString(description),
            @"next": DecodeString(next),
        }];
    }
    return services;
}

} // namespace

NSArray<NSDictionary<NSString *, id> *> *TVTestReadRecordingInfo(
    NSURL *url, NSProgress *progress, NSError **error) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (!file) {
        return nil;
    }

    @try {
        NSData *probe = [file readDataUpToLength:ProbeBytes error:error];
        if (!probe) {
            return nil;
        }
        const PacketLayout layout = DetectPacketLayout(
            static_cast<const uint8_t *>(probe.bytes), probe.length);
        if (layout.stride == 0) {
            return @[];
        }
        if (![file seekToOffset:layout.offset error:error]) {
            return nil;
        }

        LibISDB::AnalyzerFilter analyzer;
        auto parser = std::make_unique<LibISDB::TSPacketParserFilter>();
        parser->SetOutputFilter(&analyzer, &analyzer);
        LibISDB::DataBuffer buffer;
        LibISDB::SingleDataStream stream(&buffer);
        // Start each read on a packet boundary, including after stripping M2TS timestamps.
        const size_t bytesPerRead = (ReadBytes / layout.stride) * layout.stride;
        NSMutableData *pending = [NSMutableData dataWithCapacity:bytesPerRead];
        NSMutableData *normalized = [NSMutableData dataWithLength:bytesPerRead];
        size_t scanned = 0;
        while (!progress.cancelled && scanned < ScanLimit) {
            @autoreleasepool {
                const size_t limit = MIN(bytesPerRead - pending.length, ScanLimit - scanned);
                NSData *chunk = [file readDataUpToLength:limit error:error];
                if (!chunk) {
                    return nil;
                }
                if (chunk.length == 0) {
                    break;
                }
                scanned += chunk.length;
                [pending appendData:chunk];
                const auto *input = static_cast<const uint8_t *>(pending.bytes);
                auto *output = static_cast<uint8_t *>(normalized.mutableBytes);
                size_t consumed = 0;
                size_t written = 0;
                while (pending.length - consumed >= layout.stride) {
                    std::memcpy(output + written, input + consumed, PacketSize);
                    written += PacketSize;
                    consumed += layout.stride;
                }
                if (written != 0) {
                    buffer.SetData(output, written);
                    parser->ReceiveData(&stream);
                    [pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:nullptr length:0];
                }
            }
        }
        if (!progress.cancelled && pending.length >= PacketSize) {
            buffer.SetData(pending.bytes, PacketSize);
            parser->ReceiveData(&stream);
        }
        return progress.cancelled ? nil : CollectServices(analyzer);
    } @finally {
        [file closeAndReturnError:nullptr];
    }
}
