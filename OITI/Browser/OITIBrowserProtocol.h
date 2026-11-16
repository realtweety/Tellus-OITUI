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

// =============================================================================================================================
// Version 2 (OITI 0.3.6). Defined and tested on the PC in batch 1; SpringBoard and the browsers still speak version 1 until batch 2.
//
// Why: version 1 has no room for a browser ID or a file name. Version 2 keeps the low 32 bits of version 1 (magic, serial, status,
// fraction) and re-divides the top half. A process id never needs more than 17 bits (the kernel's limit is 99999; the largest
// seen on the test phone was 99508), which frees room for the browser ID and a name flag.
//
//   bits 63..47  pid of the browser process (17 bits; 0 is invalid)
//   bits 46..43  browser ID (OITIBrowserID*; 0 is invalid)
//   bit  42      1 = a file name for this download was published in the name chunks (below), 0 = no name
//   bits 41..32  zero (a message with any of them set is rejected)
//   bits 31..24  magic 0xB6 (version 2; a version 1 message has 0xB5 and is rejected here, and the other way round)
//   bits 23..16  download serial of that process (wraps at 256)
//   bits 15..14  status (as in version 1)
//   bits 13..0   fraction in ten-thousandths, 0 to 10000
//
// The file name travels in eight more libnotify states, OITI_BROWSER_NAME_CHUNK_COUNT names "com.wilburt.oiti/BrowserName0" to
// "...Name7", each a 64-bit state. Chunk 0 is a header: bits 63..32 pid, 31..24 serial (low 8 bits), 23..16 length of the name in
// bytes (0 to OITI_BROWSER_NAME_MAX_BYTES), 15..0 zero. Chunks 1 to 7 hold the UTF-8 bytes, 8 per chunk, the first byte in the lowest
// 8 bits. The browser sets all eight states first and posts the main state last; SpringBoard reads the chunks only after the main
// message arrives and uses the name only when the header's pid and serial match the main message (so two browsers that publish at
// the same time cannot swap names; the loser simply shows no name). A name longer than the limit is cut on a character boundary.
// =============================================================================================================================

#define OITI_BROWSER_MAGIC_V2 0xB6u
#define OITI_BROWSER_NAME_CHUNK_COUNT 8
#define OITI_BROWSER_NAME_MAX_BYTES 56
#define OITI_BROWSER_PID_MAX_V2 0x1FFFFu

enum {
    OITIBrowserIDArc = 1,
    OITIBrowserIDSafari = 2,
    OITIBrowserIDChrome = 3
};

// Returns 0 (never a valid message) when the pid or the browser ID cannot be represented; callers must not send a 0.
static inline uint64_t OITIBrowserEncodeStateV2(uint32_t pid, uint32_t browser, bool hasName, uint32_t serial, uint32_t status, uint32_t tenThousandths) {
    if (pid == 0 || pid > OITI_BROWSER_PID_MAX_V2 || browser == 0 || browser > 0xFu) return 0;
    if (tenThousandths > 10000u) tenThousandths = 10000u;
    return ((uint64_t)pid << 47) | ((uint64_t)browser << 43) | ((uint64_t)(hasName ? 1u : 0u) << 42) |
           ((uint64_t)OITI_BROWSER_MAGIC_V2 << 24) | ((uint64_t)(serial & 0xFFu) << 16) | ((uint64_t)(status & 3u) << 14) |
           (uint64_t)tenThousandths;
}

// false for anything that is not a version 2 message.
static inline bool OITIBrowserDecodeStateV2(uint64_t state, uint32_t *pid, uint32_t *browser, bool *hasName, uint32_t *serial, uint32_t *status, uint32_t *tenThousandths) {
    if (((state >> 24) & 0xFFu) != OITI_BROWSER_MAGIC_V2) return false;
    if (((state >> 32) & 0x3FFu) != 0) return false;
    uint32_t value = (uint32_t)(state & 0x3FFFu);
    uint32_t sender = (uint32_t)((state >> 47) & 0x1FFFFu);
    uint32_t id = (uint32_t)((state >> 43) & 0xFu);
    if (value > 10000u || sender == 0 || id == 0) return false;
    *pid = sender;
    *browser = id;
    *hasName = ((state >> 42) & 1u) != 0;
    *serial = (uint32_t)((state >> 16) & 0xFFu);
    *status = (uint32_t)((state >> 14) & 3u);
    *tenThousandths = value;
    return true;
}

// The libnotify name of name chunk `index` (0 to 7), or NULL.
static inline const char *OITIBrowserNameChunkName(unsigned index) {
    static const char *const names[OITI_BROWSER_NAME_CHUNK_COUNT] = {
        "com.wilburt.oiti/BrowserName0", "com.wilburt.oiti/BrowserName1", "com.wilburt.oiti/BrowserName2", "com.wilburt.oiti/BrowserName3",
        "com.wilburt.oiti/BrowserName4", "com.wilburt.oiti/BrowserName5", "com.wilburt.oiti/BrowserName6", "com.wilburt.oiti/BrowserName7"
    };
    return index < OITI_BROWSER_NAME_CHUNK_COUNT ? names[index] : 0;
}

// Fills the eight chunk values for a name (UTF-8 bytes, `inputLength` of them, no terminator needed). Returns how many bytes of the name
// were packed (0 for no name or a NULL pointer). Longer names are cut to OITI_BROWSER_NAME_MAX_BYTES at a character boundary.
static inline uint32_t OITIBrowserPackName(const char *utf8, uint32_t inputLength, uint32_t pid, uint32_t serial, uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT]) {
    for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) chunks[i] = 0;
    uint32_t cut = utf8 ? inputLength : 0;
    if (cut > OITI_BROWSER_NAME_MAX_BYTES) {
        cut = OITI_BROWSER_NAME_MAX_BYTES;
        // utf8[cut] is the first byte that does not fit; when it is a continuation byte the cut is inside a character: back up to its first byte
        while (cut > 0 && (((unsigned char)utf8[cut]) & 0xC0u) == 0x80u) cut--;
    }
    for (uint32_t i = 0; i < cut; i++) chunks[1 + i / 8] |= (uint64_t)(unsigned char)utf8[i] << (8u * (i % 8u));
    chunks[0] = ((uint64_t)pid << 32) | ((uint64_t)(serial & 0xFFu) << 24) | ((uint64_t)cut << 16);
    return cut;
}

// Reads a name back. `out` needs OITI_BROWSER_NAME_MAX_BYTES + 1 bytes. Returns the length (0 to 56; out is zero-terminated), or -1 when
// the header is not for this pid and serial, is malformed, or `capacity` is too small. The bytes are not checked for UTF-8 validity.
static inline int OITIBrowserUnpackName(const uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT], uint32_t pid, uint32_t serial, char *out, uint32_t capacity) {
    if (!out || capacity < OITI_BROWSER_NAME_MAX_BYTES + 1) return -1;
    uint64_t header = chunks[0];
    uint32_t length = (uint32_t)((header >> 16) & 0xFFu);
    if ((uint32_t)(header >> 32) != pid || (uint32_t)((header >> 24) & 0xFFu) != (serial & 0xFFu)) return -1;
    if ((header & 0xFFFFu) != 0 || length > OITI_BROWSER_NAME_MAX_BYTES) return -1;
    for (uint32_t i = 0; i < length; i++) out[i] = (char)((chunks[1 + i / 8] >> (8u * (i % 8u))) & 0xFFu);
    out[length] = 0;
    return (int)length;
}
