// OITIBrowserProtocol.h -- the message from a browser process to SpringBoard (OITI 0.3.5, Arc Search). Plain C, no Foundation.
//
// Two libnotify names, both proven on the iPhone 8 Plus (iOS 16.7.16) with Arc Search 1.49.0 in the browser research of 10 Nov 2026
// (an app's sandbox let it set a 64-bit state and post; SpringBoard received the notification and read the state intact):
//   OITI_BROWSER_SOURCE_ENABLED_NAME  SpringBoard -> browsers. State 1 = "Show Arc Downloads" is on (and Show Download Progress is on,
//                                     Apple Mode is off, safe mode is off), 0 = off. A browser installs its hooks only while it is 1.
//   OITI_BROWSER_DOWNLOAD_STATE_NAME  browser -> SpringBoard. The state describes the newest download of that process (below).
//
// The 64-bit download state:
//   bits 63..32  pid of the browser process (SpringBoard checks that it is still alive)
//   bits 31..24  magic 0xB5 (version 1; anything else is ignored)
//   bits 23..16  download serial of that process (wraps at 256; a new serial means a new download)
//   bits 15..14  status: 0 waiting (no total yet; never sent), 1 running, 2 finished, 3 cancelled or lost
//   bits 13..0   fraction in ten-thousandths, 0 to 10000 (10000 only with status finished)
// Percentage only: no file name and no size travel in it (a file name is planned for 0.3.6).

#pragma once
#include <stdint.h>
#include <stdbool.h>

#define OITI_BROWSER_SOURCE_ENABLED_NAME "com.wilburt.oiti/BrowserSourceEnabled"
#define OITI_BROWSER_DOWNLOAD_STATE_NAME "com.wilburt.oiti/BrowserDownloadState"
#define OITI_BROWSER_MAGIC 0xB5u

enum {
    OITIBrowserStatusWaiting = 0,
    OITIBrowserStatusRunning = 1,
    OITIBrowserStatusFinished = 2,
    OITIBrowserStatusCancelled = 3
};

static inline uint64_t OITIBrowserEncodeState(uint32_t pid, uint32_t serial, uint32_t status, uint32_t tenThousandths) {
    if (tenThousandths > 10000u) tenThousandths = 10000u;
    return ((uint64_t)pid << 32) | ((uint64_t)OITI_BROWSER_MAGIC << 24) | ((uint64_t)(serial & 0xFFu) << 16) |
           ((uint64_t)(status & 3u) << 14) | (uint64_t)tenThousandths;
}

// false for anything that is not a version 1 message (wrong magic, no pid, a fraction above 10000).
static inline bool OITIBrowserDecodeState(uint64_t state, uint32_t *pid, uint32_t *serial, uint32_t *status, uint32_t *tenThousandths) {
    if (((state >> 24) & 0xFFu) != OITI_BROWSER_MAGIC) return false;
    uint32_t value = (uint32_t)(state & 0x3FFFu);
    uint32_t sender = (uint32_t)(state >> 32);
    if (value > 10000u || sender == 0) return false;
    *pid = sender;
    *serial = (uint32_t)((state >> 16) & 0xFFu);
    *status = (uint32_t)((state >> 14) & 3u);
    *tenThousandths = value;
    return true;
}
