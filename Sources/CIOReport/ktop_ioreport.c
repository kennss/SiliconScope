//
//  File:      ktop_ioreport.c
//  Created:   2026-06-08
//  Updated:   2026-06-08
//  Developer: Kennt Kim / Calida Lab
//  Overview:  CIOReport target implementation. Re-exports private IOReport
//             declarations to Swift, and implements ktopCopyTemperatureSensors():
//             a sudoless read of Apple Silicon temperature sensors via the private
//             IOHIDEventSystem API.
//  Notes:     IOReport symbols resolve at runtime via dyld (-undefined
//             dynamic_lookup). Temperature: PrimaryUsagePage 0xff00, PrimaryUsage 5,
//             event type 15 (kIOHIDEventTypeTemperature), field = type << 16.
//
#include "ktop_ioreport.h"

// Cached HID client: creating an IOHIDEventSystemClient (and applying the matching dict)
// is expensive, so we do it once and reuse it across samples. Only the (cheaper) service
// list + per-service events are re-read each call. Single-threaded use (one sampler loop).
static IOHIDEventSystemClientRef gTemperatureClient = NULL;

CFDictionaryRef ktopCopyTemperatureSensors(void) {
    int64_t type = 15;       // kIOHIDEventTypeTemperature

    if (gTemperatureClient == NULL) {
        int32_t page = 0xff00;   // kHIDPage_AppleVendor
        int32_t usage = 5;       // kHIDUsage_AppleVendor_TemperatureSensor
        CFStringRef matchKeys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        CFNumberRef matchVals[2] = {
            CFNumberCreate(NULL, kCFNumberSInt32Type, &page),
            CFNumberCreate(NULL, kCFNumberSInt32Type, &usage)
        };
        CFDictionaryRef matching = CFDictionaryCreate(
            NULL, (const void **)matchKeys, (const void **)matchVals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(matchVals[0]);
        CFRelease(matchVals[1]);

        IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (system == NULL) { CFRelease(matching); return NULL; }
        IOHIDEventSystemClientSetMatching(system, matching);
        CFRelease(matching);
        gTemperatureClient = system;
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(gTemperatureClient);
    if (services == NULL) { return NULL; }

    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (service == NULL) continue;

        CFStringRef name = (CFStringRef)IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, type, 0, 0);

        if (name != NULL && event != NULL) {
            double celsius = IOHIDEventGetFloatValue(event, (int32_t)(type << 16));
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberDoubleType, &celsius);
            CFDictionarySetValue(result, name, number);
            CFRelease(number);
        }
        if (event != NULL) CFRelease(event);
        if (name != NULL) CFRelease(name);
    }

    CFRelease(services);
    return result;   // gTemperatureClient is cached, not released
}
