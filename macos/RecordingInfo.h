// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reads the beginning of a recording. The caller may cancel through progress.
NSArray<NSDictionary<NSString *, id> *> * _Nullable TVTestReadRecordingInfo(
    NSURL *url, NSProgress *progress, NSError **error);

NS_ASSUME_NONNULL_END
