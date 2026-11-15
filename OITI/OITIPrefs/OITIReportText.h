// OITIReportText.h -- picks and cleans the lines of OITI's log for the diagnostics report (Settings > Insula > Diagnostics).
//
// Plain C, no Foundation, so tools/report_text_test.c checks it on the PC (with the address and undefined-behavior sanitizers).
//
// What goes into the report from the log:
//  * "key lines": every line whose tag is in the key list (SESSION, SAFE, GUARD, STATUSBAR, GESTALT), up to a limit, from before
//    the tail window, oldest first;
//  * the tail: the last N lines of any tag.
// Lines tagged INSTALL, DUMP or CLASSQ are never included (install and class dumps list apps and are huge). Every line is cleaned
// before it is written: control characters become spaces, the notification title and message of a "banner request" line and the
// file name of a "file name for" line are removed (DiagnosticsLevel 1 writes them, the report must not carry them), and a line is
// cut at OITI_REPORT_MAX_LINE bytes on a character boundary. Nothing is guaranteed about other lines: the text that shows the
// report (Settings) tells the person to read it before posting it.
#pragma once
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#define OITI_REPORT_MAX_LINE 400

typedef struct { size_t start; size_t length; } OITIReportSpan;

// The tag of a log line, the first " [TAG]" (capitals, digits and underscores) of "MM-DD HH:MM:SS.mmm +s #n M tN [TAG] text".
// Copies it zero-terminated into `tag` and returns its length; 0 (and an empty string) when there is none.
static inline size_t OITIReportLineTag(const char *line, size_t length, char *tag, size_t capacity) {
    if (capacity) tag[0] = 0;
    for (size_t i = 0; i + 2 < length; i++) {
        if (line[i] != ' ' || line[i + 1] != '[') continue;
        size_t j = i + 2, n = 0;
        while (j < length && ((line[j] >= 'A' && line[j] <= 'Z') || (line[j] >= '0' && line[j] <= '9') || line[j] == '_')) { j++; n++; }
        if (n > 0 && j < length && line[j] == ']' && n < capacity) {
            memcpy(tag, line + i + 2, n);
            tag[n] = 0;
            return n;
        }
    }
    return 0;
}

static inline bool OITIReportTagIsKey(const char *tag) {
    static const char *const keys[] = {"SESSION", "SAFE", "GUARD", "STATUSBAR", "GESTALT"};
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) if (strcmp(tag, keys[i]) == 0) return true;
    return false;
}

static inline bool OITIReportTagIsExcluded(const char *tag) {
    static const char *const excluded[] = {"INSTALL", "DUMP", "CLASSQ"};
    for (size_t i = 0; i < sizeof excluded / sizeof excluded[0]; i++) if (strcmp(tag, excluded[i]) == 0) return true;
    return false;
}

// Index of the first occurrence of `needle` in line[from..length), or (size_t)-1.
static inline size_t OITIReportFind(const char *line, size_t length, size_t from, const char *needle) {
    size_t n = strlen(needle);
    if (n == 0 || length < n) return (size_t)-1;
    for (size_t i = from; i + n <= length; i++) if (memcmp(line + i, needle, n) == 0) return i;
    return (size_t)-1;
}

// Cleans one line into `out` (zero-terminated, at most capacity - 1 bytes; capacity should be OITI_REPORT_MAX_LINE + 80) and returns
// the length written.
static inline size_t OITIReportCleanLine(const char *line, size_t length, char *out, size_t capacity) {
    if (capacity == 0) return 0;
    while (length > 0 && (line[length - 1] == '\r' || line[length - 1] == '\n')) length--;
    const char *tail = "";
    size_t keep = length;
    size_t banner = OITIReportFind(line, length, 0, "banner request ");
    size_t nameLine = OITIReportFind(line, length, 0, "file name for ");
    if (banner != (size_t)-1) {
        size_t title = OITIReportFind(line, length, banner, " title=");
        if (title != (size_t)-1) { keep = title; tail = " title=(removed from the report) message=(removed from the report)"; }
        else { keep = banner + strlen("banner request "); tail = "(removed from the report)"; }
    } else if (nameLine != (size_t)-1) {
        size_t colon = OITIReportFind(line, length, nameLine, ": ");
        if (colon != (size_t)-1) { keep = colon + 2; tail = "(removed from the report)"; }
    }
    bool redacted = tail[0] != 0;
    size_t limit = OITI_REPORT_MAX_LINE;
    bool cut = false;
    if (keep > limit) {
        keep = limit;
        // line[keep] is the first byte that does not fit; a continuation byte means the cut is inside a character: back up
        while (keep > 0 && (((unsigned char)line[keep]) & 0xC0u) == 0x80u) keep--;
        cut = true;
    }
    size_t o = 0;
    for (size_t i = 0; i < keep && o + 1 < capacity; i++) {
        unsigned char c = (unsigned char)line[i];
        out[o++] = (c < 0x20 || c == 0x7f) ? ' ' : (char)c;
    }
    const char *suffix = cut ? " [cut]" : "";
    for (size_t i = 0; suffix[i] && o + 1 < capacity; i++) out[o++] = suffix[i];
    if (redacted) for (size_t i = 0; tail[i] && o + 1 < capacity; i++) out[o++] = tail[i];
    out[o] = 0;
    return o;
}

typedef struct { char *buffer; size_t capacity; size_t length; bool full; } OITIReportSink;

static inline void OITIReportSinkAppend(OITIReportSink *sink, const char *text, size_t length) {
    if (sink->full) return;
    // keep room for the closing marker
    if (sink->length + length + 40 >= sink->capacity) {
        const char *marker = "[cut: the report is full]\n";
        size_t m = strlen(marker);
        if (sink->length + m + 1 <= sink->capacity) { memcpy(sink->buffer + sink->length, marker, m); sink->length += m; }
        sink->buffer[sink->length] = 0;
        sink->full = true;
        return;
    }
    memcpy(sink->buffer + sink->length, text, length);
    sink->length += length;
    sink->buffer[sink->length] = 0;
}

static inline void OITIReportSinkLine(OITIReportSink *sink, const char *line, size_t length) {
    char cleaned[OITI_REPORT_MAX_LINE + 96];
    size_t n = OITIReportCleanLine(line, length, cleaned, sizeof cleaned);
    cleaned[n++] = '\n';
    OITIReportSinkAppend(sink, cleaned, n);
}

// Builds the log section from the bytes of the end of a log file. `partialFirst`: the first line may be cut (the bytes start in the
// middle of the file), so it is dropped. Returns the length written to `out` (always zero-terminated, never above capacity - 1).
static inline size_t OITIReportBuildLogSection(const char *log, size_t length, bool partialFirst, unsigned keyLines, unsigned tailLines,
                                              char *out, size_t capacity) {
    if (capacity == 0) return 0;
    out[0] = 0;
    OITIReportSink sink = { out, capacity, 0, false };
    size_t begin = 0;
    if (partialFirst) {
        while (begin < length && log[begin] != '\n') begin++;
        if (begin < length) begin++; else begin = length;
    }
    // index the lines
    size_t count = 0;
    for (size_t i = begin; i < length; i++) if (log[i] == '\n') count++;
    if (length > begin && log[length - 1] != '\n') count++;
    if (count == 0) {
        const char *none = "(the log is empty or could not be read)\n";
        OITIReportSinkAppend(&sink, none, strlen(none));
        return sink.length;
    }
    OITIReportSpan *spans = (OITIReportSpan *)malloc(count * sizeof(OITIReportSpan));
    if (!spans) return sink.length;
    size_t index = 0, lineStart = begin;
    for (size_t i = begin; i <= length && index < count; i++) {
        if (i == length || log[i] == '\n') {
            if (i == length && lineStart == length) break;
            spans[index].start = lineStart;
            spans[index].length = i - lineStart;
            index++;
            lineStart = i + 1;
        }
    }
    count = index;

    // the tail window: the last tailLines lines that are not excluded
    size_t tailStart = count;
    unsigned taken = 0;
    char tag[32];
    for (size_t i = count; i > 0 && taken < tailLines; i--) {
        OITIReportLineTag(log + spans[i - 1].start, spans[i - 1].length, tag, sizeof tag);
        if (OITIReportTagIsExcluded(tag)) continue;
        tailStart = i - 1;
        taken++;
    }

    // key lines before the window: the last keyLines of them, printed oldest first
    size_t keyFrom = tailStart;
    unsigned keyCount = 0;
    for (size_t i = tailStart; i > 0 && keyCount < keyLines; i--) {
        OITIReportLineTag(log + spans[i - 1].start, spans[i - 1].length, tag, sizeof tag);
        if (!OITIReportTagIsKey(tag)) continue;
        keyFrom = i - 1;
        keyCount++;
    }
    char header[160];
    int h = snprintf(header, sizeof header, "-- key lines (SESSION, SAFE, GUARD, STATUSBAR, GESTALT) before the last lines: %u --\n", keyCount);
    if (h > 0) OITIReportSinkAppend(&sink, header, (size_t)h);
    for (size_t i = keyFrom; i < tailStart; i++) {
        OITIReportLineTag(log + spans[i].start, spans[i].length, tag, sizeof tag);
        if (OITIReportTagIsKey(tag)) OITIReportSinkLine(&sink, log + spans[i].start, spans[i].length);
    }
    h = snprintf(header, sizeof header, "-- last %u lines of the log --\n", taken);
    if (h > 0) OITIReportSinkAppend(&sink, header, (size_t)h);
    for (size_t i = tailStart; i < count; i++) {
        OITIReportLineTag(log + spans[i].start, spans[i].length, tag, sizeof tag);
        if (OITIReportTagIsExcluded(tag)) continue;
        OITIReportSinkLine(&sink, log + spans[i].start, spans[i].length);
    }
    free(spans);
    return sink.length;
}
