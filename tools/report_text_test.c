// report_text_test.c -- checks OITI/OITIPrefs/OITIReportText.h on the PC (plain C, no Theos, no device):
//   clang -fsanitize=address,undefined -g -I OITI/OITIPrefs -o /tmp/report_text_test tools/report_text_test.c && /tmp/report_text_test
#include <stdio.h>
#include <string.h>
#include "OITIReportText.h"

static int failures = 0, checks = 0;
#define CHECK(cond, what) do { checks++; if (!(cond)) { failures++; printf("FAIL  %s (line %d)\n", what, __LINE__); } } while (0)

static int contains(const char *haystack, const char *needle) { return strstr(haystack, needle) != NULL; }

int main(void) {
    char tag[32], out[OITI_REPORT_MAX_LINE + 96];
    const char *session = "11-13 15:32:50.448 +0.001 #1 M t0 [SESSION] START build=OITI-exp-0.3.6-a pid=7374 proc=SpringBoard";
    CHECK(OITIReportLineTag(session, strlen(session), tag, sizeof tag) == 7 && strcmp(tag, "SESSION") == 0, "tag of a session line");
    const char *plain = "no tag here [but not capitals] and [abc]";
    CHECK(OITIReportLineTag(plain, strlen(plain), tag, sizeof tag) == 0 && tag[0] == 0, "no tag");
    const char *longTag = "x [ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOP] y";
    CHECK(OITIReportLineTag(longTag, strlen(longTag), tag, sizeof tag) == 0, "a tag longer than the buffer is not a tag");
    CHECK(OITIReportLineTag("", 0, tag, sizeof tag) == 0, "empty line");
    CHECK(OITIReportTagIsKey("STATUSBAR") && OITIReportTagIsKey("SAFE") && !OITIReportTagIsKey("ELEMENT") && !OITIReportTagIsKey(""), "key tags");
    CHECK(OITIReportTagIsKey("ISLANDFRAME") && !OITIReportTagIsKey("ISLAND"), "the 0.4.1 position-correction tag is a key tag");
    CHECK(OITIReportTagIsExcluded("INSTALL") && OITIReportTagIsExcluded("DUMP") && OITIReportTagIsExcluded("CLASSQ") && !OITIReportTagIsExcluded("NOTIF"), "excluded tags");

    // notification content is removed
    const char *banner = "11-13 22:00:00.000 +5.0 #9 M t0 [NOTIF] banner request abc bundle=com.example.chat app=Chat title=Anna message=See you at 8? (feature 1)";
    size_t n = OITIReportCleanLine(banner, strlen(banner), out, sizeof out);
    CHECK(!contains(out, "Anna") && !contains(out, "See you") && contains(out, "bundle=com.example.chat") && contains(out, "(removed from the report)") && n == strlen(out), "banner request: title and message removed");
    const char *bannerNoTitle = "x [NOTIF] banner request odd line";
    OITIReportCleanLine(bannerNoTitle, strlen(bannerNoTitle), out, sizeof out);
    CHECK(contains(out, "banner request (removed from the report)") && !contains(out, "odd line"), "banner request without a title field");
    // file names are removed
    const char *fileName = "11-13 22:00:00.000 +5.0 #9 M t0 [DOWNLOAD] browser source: file name for browser.8138.2: secret-plans.pdf";
    OITIReportCleanLine(fileName, strlen(fileName), out, sizeof out);
    CHECK(!contains(out, "secret-plans") && contains(out, "file name for browser.8138.2: (removed from the report)"), "file name removed");
    // control characters and CR
    const char *ctl = "a\tb\x01" "c\r\n";
    OITIReportCleanLine(ctl, strlen(ctl), out, sizeof out);
    CHECK(strcmp(out, "a b c") == 0, "control characters become spaces, the line end is dropped");
    // long lines are cut on a character boundary
    char longLine[1000];
    memset(longLine, 'a', 399);
    memcpy(longLine + 399, "\xC3\xA9", 2);   // e-acute straddles the limit (bytes 399 and 400)
    memset(longLine + 401, 'b', 100);
    OITIReportCleanLine(longLine, 501, out, sizeof out);
    CHECK(strlen(out) == 399 + strlen(" [cut]") && contains(out, " [cut]") && (unsigned char)out[398] == 'a', "a long line is cut before a split character");
    memset(longLine, 'c', 500);
    OITIReportCleanLine(longLine, 500, out, sizeof out);
    CHECK(strlen(out) == OITI_REPORT_MAX_LINE + strlen(" [cut]"), "a long ASCII line is cut at the limit");
    CHECK(OITIReportCleanLine("x", 1, out, 1) == 0 && out[0] == 0, "a one-byte buffer holds nothing");

    // the log section
    char log[4096];
    int w = 0;
    w += snprintf(log + w, sizeof log - w, "partial first lin");   // the cut start of the file
    w += snprintf(log + w, sizeof log - w, "e [SESSION] should be dropped\n");
    w += snprintf(log + w, sizeof log - w, "L1 [SESSION] START one\n");
    w += snprintf(log + w, sizeof log - w, "L2 [ELEMENT] noise\n");
    w += snprintf(log + w, sizeof log - w, "L3 [INSTALL] installed apps: com.secret.app\n");
    w += snprintf(log + w, sizeof log - w, "L4 [SAFE] safe mode on\n");
    w += snprintf(log + w, sizeof log - w, "L5 [DUMP] class dump line\n");
    w += snprintf(log + w, sizeof log - w, "L6 [STATUSBAR] CHOICE one\n");
    w += snprintf(log + w, sizeof log - w, "L7 [ELEMENT] tail line a\n");
    w += snprintf(log + w, sizeof log - w, "L8 [SESSION] START two\n");
    w += snprintf(log + w, sizeof log - w, "L9 [ELEMENT] tail line b");   // no final newline
    char section[8192];
    size_t len = OITIReportBuildLogSection(log, (size_t)w, true, 10, 3, section, sizeof section);
    CHECK(len == strlen(section), "the length matches the string");
    CHECK(!contains(section, "should be dropped") && !contains(section, "com.secret.app") && !contains(section, "class dump line"), "partial line, INSTALL and DUMP lines are left out");
    CHECK(contains(section, "L1 [SESSION]") && contains(section, "L4 [SAFE]") && contains(section, "L6 [STATUSBAR]"), "key lines before the tail are kept");
    CHECK(!contains(section, "L2 [ELEMENT]"), "non-key lines before the tail are left out");
    CHECK(contains(section, "-- last 3 lines of the log --") && contains(section, "L7 [ELEMENT]") && contains(section, "L8 [SESSION]") && contains(section, "L9 [ELEMENT] tail line b"), "the tail has its 3 lines, the last one without a newline");
    const char *tailPart = strstr(section, "-- last 3 lines");
    CHECK(tailPart && !strstr(tailPart, "L6 [STATUSBAR]") && strstr(section, "L8 [SESSION]") >= tailPart, "key lines inside the tail are not printed twice");
    // keyLines limit: only the newest 2 key lines before the tail window
    len = OITIReportBuildLogSection(log, (size_t)w, true, 2, 3, section, sizeof section);
    CHECK(!contains(section, "L1 [SESSION]") && contains(section, "L4 [SAFE]") && contains(section, "L6 [STATUSBAR]") && contains(section, "before the last lines: 2"), "the key line limit keeps the newest ones");
    // tail limit counts only included lines: 2 tail lines skip the excluded ones in between
    len = OITIReportBuildLogSection(log, (size_t)w, true, 0, 5, section, sizeof section);
    CHECK(contains(section, "-- last 5 lines of the log --") && contains(section, "L6 [STATUSBAR]") && !contains(section, "L5 [DUMP]"), "excluded lines do not count against the tail");
    // empty and whitespace-only logs, a log that is only a partial line
    len = OITIReportBuildLogSection("", 0, false, 5, 5, section, sizeof section);
    CHECK(contains(section, "empty or could not be read"), "empty log");
    len = OITIReportBuildLogSection("only a partial line", 19, true, 5, 5, section, sizeof section);
    CHECK(contains(section, "empty or could not be read"), "a log that is one partial line");
    len = OITIReportBuildLogSection("\n\n\n", 3, false, 5, 5, section, sizeof section);
    CHECK(len == strlen(section), "blank lines are fine");
    // a full report is cut with a marker, never overflows
    char small[200];
    len = OITIReportBuildLogSection(log, (size_t)w, true, 10, 10, small, sizeof small);
    CHECK(len == strlen(small) && len < sizeof small && contains(small, "[cut: the report is full]"), "a small buffer is cut with a marker");
    char tiny[1];
    CHECK(OITIReportBuildLogSection(log, (size_t)w, true, 10, 10, tiny, sizeof tiny) == 0 && tiny[0] == 0, "a one-byte buffer");
    CHECK(OITIReportBuildLogSection(log, (size_t)w, true, 10, 10, tiny, 0) == 0, "a zero-byte buffer");

    // fuzz: random bytes with many newlines, tags and limits; the sanitizers watch for overflows, the checks for the invariants
    unsigned seed = 12345u;
    const char *pieces[] = {" [SESSION] ", " [DUMP] ", " [ELEMENT] ", " [STATUSBAR] ", "banner request x title=y message=z", "file name for a: b", "\n", "\n", "\xC3", "\xA9", "\xF0\x9F\x98\x80", "a", "bb", "\r", "[", "]", " "};
    for (int round = 0; round < 3000; round++) {
        static char fuzz[6000];
        size_t f = 0;
        seed = seed * 1103515245u + 12345u;
        int parts = (int)((seed >> 16) % 300);
        for (int i = 0; i < parts; i++) {
            seed = seed * 1103515245u + 12345u;
            const char *piece = pieces[(seed >> 16) % (sizeof pieces / sizeof pieces[0])];
            size_t pl = strlen(piece);
            seed = seed * 1103515245u + 12345u;
            int repeat = ((seed >> 16) % 9 == 0) ? 120 : 1;   // now and then a very long run
            for (int r = 0; r < repeat && f + pl < sizeof fuzz; r++) { memcpy(fuzz + f, piece, pl); f += pl; }
        }
        seed = seed * 1103515245u + 12345u;
        size_t cap = 1 + (seed >> 16) % 3000;
        char *buffer = (char *)malloc(cap);
        unsigned keyLimit = (seed >> 8) % 20, tailLimit = (seed >> 4) % 40;
        size_t got = OITIReportBuildLogSection(fuzz, f, (seed & 1) != 0, keyLimit, tailLimit, buffer, cap);
        CHECK(got < cap && buffer[got] == 0 && strlen(buffer) == got, "fuzz: bounded and terminated");
        free(buffer);
    }
    printf("%s (%d checks, %d failures)\n", failures ? "REPORT TEXT: FAILED" : "REPORT TEXT: OK", checks, failures);
    return failures ? 1 : 0;
}
