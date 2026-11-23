// Declarations for system functions Apple ships but does not document.
// They are what Activity Monitor-style tools use to read sensors on Apple
// Silicon; they can change between macOS releases, so every caller treats a
// failure as "sensor unavailable" rather than an error.

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>

CF_ASSUME_NONNULL_BEGIN

// MARK: Temperature sensors (IOKit HID)

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
CFTypeRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);

// MARK: Energy and power state counters (libIOReport)

CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup, uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
CFTypeRef _Nullable IOReportCreateSubscription(void *_Nullable a, CFMutableDictionaryRef desired, CFMutableDictionaryRef _Nullable *_Nonnull subscribed, uint64_t channelID, CFTypeRef _Nullable b) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamples(CFTypeRef subscription, CFMutableDictionaryRef _Nullable subscribed, CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current, CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetUnitLabel(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
// For channels that count time spent in each of several states.
int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

// MARK: Process responsibility

// The process the system holds responsible for another: the app behind a
// helper that launchd started on its behalf. Returns the pid itself for a
// process that answers for itself, and -1 when it cannot tell.
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

CF_ASSUME_NONNULL_END
