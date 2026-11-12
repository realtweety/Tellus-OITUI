// browser_protocol_test.c -- checks Browser/OITIBrowserProtocol.h on the PC (plain C, no Theos, no device):
//   clang -I OITI -o /tmp/browser_protocol_test tools/browser_protocol_test.c && /tmp/browser_protocol_test
#include <stdio.h>
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
    printf("%s (%d round trips, %d failures)\n", failures ? "BROWSER PROTOCOL: FAILED" : "BROWSER PROTOCOL: OK", roundTrips, failures);
    return failures ? 1 : 0;
}
