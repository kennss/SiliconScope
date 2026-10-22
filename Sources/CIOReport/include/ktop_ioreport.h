//
//  File:      ktop_ioreport.h
//  Created:   2026-06-08
//  Updated:   2026-10-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  C declarations for Apple's private IOReport framework, exposed to
//             Swift (SiliconScopeCore). There is no SDK stub for IOReport, so symbols are
//             resolved at runtime from the dyld shared cache by linking the final
//             binary with -undefined dynamic_lookup.
//  Notes:     "Copy"/"Create" funcs return +1 (retained) values; "Get" funcs return
//             unretained CFStringRef (toll-free bridged with NSString — kept C-only
//             on purpose so this stays a pure CoreFoundation header). Using this
//             private API means the app cannot be App Store sandboxed. Signatures
//             referenced from public reverse-engineering (e.g. NeoAsitop, MIT) —
//             declarations only, no implementation copied.
//
#ifndef KTOP_IOREPORT_H
#define KTOP_IOREPORT_H

#include <CoreFoundation/CoreFoundation.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

// Channel format codes returned by IOReportChannelGetFormat.
enum {
    kKtopIOReportFormatInvalid     = 0,
    kKtopIOReportFormatSimple      = 1,
    kKtopIOReportFormatState       = 2,
    kKtopIOReportFormatSimpleArray = 4,
};

// Iteration result codes for the IOReportIterate block.
enum {
    kKtopIOReportIterOk      = 0,
    kKtopIOReportIterFailed  = 1,
    kKtopIOReportIterSkipped = 2,
};

// Channel discovery.
extern CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern void IOReportMergeChannels(CFMutableDictionaryRef dst, CFMutableDictionaryRef src, CFTypeRef nullPtr);

// Subscription and sampling.
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desiredChannels, CFMutableDictionaryRef *subbedChannels, uint64_t channelID, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subbedChannels, CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef current, CFTypeRef a);

// Per-sample iteration.
typedef int (^ioreportiterateblock)(CFDictionaryRef channel);
extern void IOReportIterate(CFDictionaryRef samples, ioreportiterateblock block);

// Per-channel metadata.
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
extern int IOReportChannelGetFormat(CFDictionaryRef channel);
// The channel's unit, e.g. "mJ", "uJ", "nJ" for energy, "B" or "events" for counters, "" for none.
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);

// Per-channel value readers.
extern long IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int index);
extern int IOReportStateGetCount(CFDictionaryRef channel);
extern uint64_t IOReportStateGetResidency(CFDictionaryRef channel, int index);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef channel, int index);
extern uint64_t IOReportArrayGetValueAtIndex(CFDictionaryRef channel, int index);

// --- Private IOHIDEventSystem: Apple Silicon temperature/power sensors ---
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// ktop helper: returns a +1 CFDictionary of { CFString sensorName : CFNumber celsius }.
// Implemented in ktop_ioreport.c. Caller releases (Swift handles via the Copy rule).
extern CFDictionaryRef ktopCopyTemperatureSensors(void);

#endif /* KTOP_IOREPORT_H */
