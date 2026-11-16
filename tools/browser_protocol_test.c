// browser_protocol_test.c -- checks Browser/OITIBrowserProtocol.h on the PC (version 1 and, since 0.3.6, version 2 and the file name chunks) (plain C, no Theos, no device):
//   clang -I OITI -o /tmp/browser_protocol_test tools/browser_protocol_test.c && /tmp/browser_protocol_test
#include <stdio.h>
#include <string.h>
#include "Browser/OITIBrowserProtocol.h"

static int failures = 0;
#define CHECK(cond, message) do { if (!(cond)) { printf("FAIL  %s\n", message); failures++; } } while (0)

int main(void) {
    uint32_t statuses[] = {OITIBrowserStatusRunning, OITIBrowserStatusFinished, OITIBrowserStatusCancelled, OITIBrowserStatusWaiting};
    uint32_t pids[] = {1u, 79814u, 99999u, 4294967295u};
    uint32_t serials[] = {0u, 1u, 255u};
    uint32_t values[] = {0u, 1u, 4999u, 9999u, 10000u};
    int roundTrips = 0;
    for (int a = 0; a < 4; a++) for (int b = 0; b < 3; b++) for (int c = 0; c < 4; c++) for (int d = 0; d < 5; d++) {
        uint32_t pid, serial, status, value;
        uint64_t state = OITIBrowserEncodeState(pids[a], serials[b], statuses[c], values[d]);
        bool ok = OITIBrowserDecodeState(state, &pid, &serial, &status, &value);
        CHECK(ok && pid == pids[a] && serial == serials[b] && status == statuses[c] && value == values[d], "round trip");
        roundTrips++;
    }
    uint32_t pid, serial, status, value;
    CHECK(OITIBrowserEncodeState(1, 0, 1, 99999) == OITIBrowserEncodeState(1, 0, 1, 10000), "fraction is capped at 10000");
    CHECK(OITIBrowserEncodeState(1, 256, 1, 0) == OITIBrowserEncodeState(1, 0, 1, 0), "serial wraps at 256");
    // the research channel test state of 10 Nov 2026 (magic 0xA5, pid 78953) must NOT decode as a download message
    CHECK(!OITIBrowserDecodeState(0x13469a5000001ull, &pid, &serial, &status, &value), "the research probe value is rejected");
    CHECK(!OITIBrowserDecodeState(0ull, &pid, &serial, &status, &value), "zero is rejected");
    CHECK(!OITIBrowserDecodeState(((uint64_t)5 << 32) | (0xB5ull << 24) | 10001ull, &pid, &serial, &status, &value), "a fraction above 10000 is rejected");
    CHECK(!OITIBrowserDecodeState((0xB5ull << 24) | 5ull, &pid, &serial, &status, &value), "pid 0 is rejected");
    // ---- version 2 (0.3.6): browser ID, name flag, 17-bit pid
    {
        uint32_t v2pids[] = {1u, 79814u, 99508u, 99999u, 131071u};
        uint32_t browsers[] = {OITIBrowserIDArc, OITIBrowserIDSafari, OITIBrowserIDChrome, 15u};
        bool flags[] = {false, true};
        for (int a = 0; a < 5; a++) for (int b = 0; b < 4; b++) for (int f = 0; f < 2; f++) for (int s = 0; s < 3; s++)
        for (int c = 0; c < 4; c++) for (int d = 0; d < 5; d++) {
            uint32_t pid2, browser2, serial2, status2, value2; bool hasName2;
            uint64_t state = OITIBrowserEncodeStateV2(v2pids[a], browsers[b], flags[f], serials[s], statuses[c], values[d]);
            bool ok = OITIBrowserDecodeStateV2(state, &pid2, &browser2, &hasName2, &serial2, &status2, &value2);
            CHECK(state != 0 && ok && pid2 == v2pids[a] && browser2 == browsers[b] && hasName2 == flags[f] && serial2 == serials[s] &&
                  status2 == statuses[c] && value2 == values[d], "v2 round trip");
            // a version 2 message is never a version 1 message, and the other way round
            CHECK(!OITIBrowserDecodeState(state, &pid, &serial, &status, &value), "v2 message is rejected by the v1 decoder");
            uint64_t v1 = OITIBrowserEncodeState(v2pids[a], serials[s], statuses[c], values[d]);
            CHECK(!OITIBrowserDecodeStateV2(v1, &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v1 message is rejected by the v2 decoder");
            roundTrips += 3;
        }
        uint32_t pid2, browser2, serial2, status2, value2; bool hasName2;
        CHECK(OITIBrowserEncodeStateV2(0, 1, false, 0, 1, 0) == 0, "v2: pid 0 cannot be encoded");
        CHECK(OITIBrowserEncodeStateV2(131072u, 1, false, 0, 1, 0) == 0, "v2: a pid above 17 bits cannot be encoded");
        CHECK(OITIBrowserEncodeStateV2(5, 0, false, 0, 1, 0) == 0, "v2: browser 0 cannot be encoded");
        CHECK(OITIBrowserEncodeStateV2(5, 16, false, 0, 1, 0) == 0, "v2: a browser ID above 4 bits cannot be encoded");
        CHECK(OITIBrowserEncodeStateV2(1, 1, false, 0, 1, 99999) == OITIBrowserEncodeStateV2(1, 1, false, 0, 1, 10000), "v2: fraction is capped");
        CHECK(OITIBrowserEncodeStateV2(1, 1, false, 256, 1, 0) == OITIBrowserEncodeStateV2(1, 1, false, 0, 1, 0), "v2: serial wraps at 256");
        uint64_t good = OITIBrowserEncodeStateV2(1234, OITIBrowserIDChrome, true, 7, OITIBrowserStatusRunning, 5000);
        CHECK(OITIBrowserDecodeStateV2(good, &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: a good message decodes");
        CHECK(!OITIBrowserDecodeStateV2(good | (1ull << 32), &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: a set spare bit is rejected");
        CHECK(!OITIBrowserDecodeStateV2(good | (1ull << 41), &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: the top spare bit is rejected");
        CHECK(!OITIBrowserDecodeStateV2(0ull, &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: zero is rejected");
        CHECK(!OITIBrowserDecodeStateV2(0x13469a5000001ull, &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: the research probe value is rejected");
        CHECK(!OITIBrowserDecodeStateV2((good & ~(0xFull << 43)), &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: browser 0 is rejected");
        CHECK(!OITIBrowserDecodeStateV2((good & ~(0x1FFFFull << 47)), &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: pid 0 is rejected");
        CHECK(!OITIBrowserDecodeStateV2((good & ~0x3FFFull) | 10001ull, &pid2, &browser2, &hasName2, &serial2, &status2, &value2), "v2: a fraction above 10000 is rejected");
    }

    // ---- name chunks
    {
        char out[OITI_BROWSER_NAME_MAX_BYTES + 1];
        uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT];
        const char *names[] = {
            "", "a", "report.pdf", "caf\xC3\xA9.zip", "\xE3\x83\x95\xE3\x82\xA1\xE3\x82\xA4\xE3\x83\xAB.bin",
            "12345678", "123456789", "0123456789012345678901234567890123456789012345678901234567890123456789"  /* 70 bytes */
        };
        int packed = 0;
        for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
            uint32_t length = (uint32_t)strlen(names[i]);
            uint32_t n = OITIBrowserPackName(names[i], length, 4321u, 9u, chunks);
            int back = OITIBrowserUnpackName(chunks, 4321u, 9u, out, sizeof out);
            uint32_t expected = length > OITI_BROWSER_NAME_MAX_BYTES ? OITI_BROWSER_NAME_MAX_BYTES : length;
            CHECK(n == expected && back == (int)expected && memcmp(out, names[i], expected) == 0 && out[expected] == 0, "name round trip");
            packed++;
        }
        // exactly 56 bytes fit, 57 are cut to 56
        char fiftySix[57], fiftySeven[58];
        memset(fiftySix, 'x', 56); fiftySix[56] = 0;
        memset(fiftySeven, 'y', 57); fiftySeven[57] = 0;
        CHECK(OITIBrowserPackName(fiftySix, 56, 1, 1, chunks) == 56 && OITIBrowserUnpackName(chunks, 1, 1, out, sizeof out) == 56, "56 bytes fit");
        CHECK(OITIBrowserPackName(fiftySeven, 57, 1, 1, chunks) == 56 && OITIBrowserUnpackName(chunks, 1, 1, out, sizeof out) == 56, "57 bytes are cut to 56");
        // a cut inside a two-byte character backs up to the character's first byte: 55 bytes, then e-acute (2 bytes)
        char cutTwo[64]; memset(cutTwo, 'a', 55); memcpy(cutTwo + 55, "\xC3\xA9", 2); cutTwo[57] = 0;
        CHECK(OITIBrowserPackName(cutTwo, 57, 1, 1, chunks) == 55, "a cut inside a 2-byte character drops the character");
        // a cut inside a four-byte character (the emoji U+1F600 starts at byte 53): 53 bytes, then 4 bytes, then more
        char cutFour[80]; memset(cutFour, 'b', 53); memcpy(cutFour + 53, "\xF0\x9F\x98\x80", 4); memset(cutFour + 57, 'c', 10); cutFour[67] = 0;
        CHECK(OITIBrowserPackName(cutFour, 67, 1, 1, chunks) == 53, "a cut inside a 4-byte character drops the character");
        // a four-byte character that ends exactly at byte 56 is kept
        char keepFour[80]; memset(keepFour, 'd', 52); memcpy(keepFour + 52, "\xF0\x9F\x98\x80", 4); memset(keepFour + 56, 'e', 5); keepFour[61] = 0;
        CHECK(OITIBrowserPackName(keepFour, 61, 1, 1, chunks) == 56, "a character that ends exactly at the limit is kept");
        // header checks
        OITIBrowserPackName("report.pdf", 10, 4321u, 9u, chunks);
        CHECK(OITIBrowserUnpackName(chunks, 4322u, 9u, out, sizeof out) == -1, "wrong pid: name rejected");
        CHECK(OITIBrowserUnpackName(chunks, 4321u, 10u, out, sizeof out) == -1, "wrong serial: name rejected");
        CHECK(OITIBrowserUnpackName(chunks, 4321u, 9u + 256u, out, sizeof out) == 10, "the serial is compared in its low 8 bits");
        CHECK(OITIBrowserUnpackName(chunks, 4321u, 9u, out, 56) == -1, "a buffer that is too small is rejected");
        CHECK(OITIBrowserUnpackName(chunks, 4321u, 9u, NULL, 57) == -1, "a NULL buffer is rejected");
        uint64_t bad[OITI_BROWSER_NAME_CHUNK_COUNT]; memcpy(bad, chunks, sizeof bad);
        bad[0] = (bad[0] & ~(0xFFull << 16)) | (57ull << 16);
        CHECK(OITIBrowserUnpackName(bad, 4321u, 9u, out, sizeof out) == -1, "a length above 56 is rejected");
        memcpy(bad, chunks, sizeof bad); bad[0] |= 1ull;
        CHECK(OITIBrowserUnpackName(bad, 4321u, 9u, out, sizeof out) == -1, "non-zero reserved header bits are rejected");
        CHECK(OITIBrowserPackName(NULL, 5, 4321u, 9u, chunks) == 0 && OITIBrowserUnpackName(chunks, 4321u, 9u, out, sizeof out) == 0, "a NULL name packs as no name");
        CHECK(strcmp(OITIBrowserNameChunkName(0), "com.wilburt.oiti/BrowserName0") == 0 && strcmp(OITIBrowserNameChunkName(7), "com.wilburt.oiti/BrowserName7") == 0 &&
              OITIBrowserNameChunkName(8) == 0, "chunk names");
        roundTrips += packed;
    }
    printf("%s (%d round trips, %d failures)\n", failures ? "BROWSER PROTOCOL: FAILED" : "BROWSER PROTOCOL: OK", roundTrips, failures);
    return failures ? 1 : 0;
}
