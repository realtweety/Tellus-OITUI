#!/usr/bin/env python3
# Python mirror of the Safari source in OITI/Browser/OITIBrowserDump.xm (0.3.7): OITISafariEvent / OITISafariBegin / OITISafariPublish.
# Logic only, NOT the Objective-C: it checks the intended behavior (which messages a sequence of dispatcher calls produces, and
# which it must not). Keep it in step with that file. Run: python3 tools/safari_source_model.py
import sys

WAITING, RUNNING, FINISHED, CANCELLED = 0, 1, 2, 3
START, FINISH, CANCEL, CRASH, FAIL, RESPONSE, DEST, WRITE = range(1, 9)


class Source:
    def __init__(self):
        self.on = True
        self.rec = dict(download=0, order=0, serial=0, phase=0, written=0, expected=0)
        self.name = None
        self.order_counter = 0
        self.serial_counter = 0
        self.kick = False
        self.sent = []            # (order, status, value, has_name)
        self.names_posted = []    # (order, name)
        self.pub_order = 0
        self.reset_pub()

    def reset_pub(self):
        self.published = self.name_sent = self.done = self.has_last = False
        self.last_msg = None
        self.last_fraction = 0.0

    def begin(self, key, name=None):
        self.order_counter += 1
        self.serial_counter += 1
        self.rec = dict(download=key, order=self.order_counter, serial=self.serial_counter & 0xFF, phase=1, written=0, expected=0)
        self.name = name if name else None
        self.kick = True   # OITISafariKick: a block on the main queue, so it runs after the event that began the download completes

    def event(self, kind, key, extra=None, total=0, expected=0):
        self.event_inner(kind, key, extra, total, expected)
        if self.kick:
            self.kick = False
            self.publish()

    def event_inner(self, kind, key, extra=None, total=0, expected=0):
        if not self.on or not key:
            return
        r = self.rec
        if kind == START:
            if not (r['download'] == key and r['phase'] == 1):
                self.begin(key)
        elif kind == DEST:
            name = extra if isinstance(extra, str) else None
            if r['download'] != key:
                self.begin(key, name)
            elif r['phase'] == 1 and name:
                self.name = name
        elif kind == WRITE:
            if r['download'] == key:
                if r['phase'] == 1:
                    r['written'], r['expected'] = total, expected
            elif r['phase'] != 1:
                self.begin(key)
                self.rec['written'], self.rec['expected'] = total, expected
        elif kind in (FINISH, CANCEL, CRASH, FAIL):
            if r['download'] == key and r['phase'] == 1:
                r['phase'] = 2 if kind == FINISH else 3
                self.kick = True

    def switch_off(self):
        self.on = False
        self.rec = dict(download=0, order=0, serial=0, phase=0, written=0, expected=0)
        self.name = None
        self.pub_order = 0

    def publish(self):   # also what the one-second timer calls
        if not self.on:
            return
        s = dict(self.rec)
        if s['order'] == 0:
            return
        if s['order'] != self.pub_order:
            self.pub_order = s['order']
            self.reset_pub()
        if self.done:
            return
        if s['phase'] == 3:
            if not self.published:
                self.done = True
                return
            status, value = CANCELLED, int(self.last_fraction * 10000.0)
        elif s['phase'] == 2:
            status, value = FINISHED, 10000
        elif s['phase'] == 1:
            if s['expected'] <= 0 or s['written'] < 0:
                return
            f = max(0.0, min(0.9999, s['written'] / s['expected']))
            self.last_fraction = f
            status, value = RUNNING, int(f * 10000.0 + 0.5)
        else:
            return
        has_name = bool(self.name)
        msg = (s['serial'], status, value, has_name)
        if self.has_last and self.last_msg == msg:
            return
        if has_name and not self.name_sent:
            self.names_posted.append((s['order'], self.name))
            self.name_sent = True
        self.has_last, self.last_msg = True, msg
        if status == RUNNING:
            self.published = True
        else:
            self.done = True
        self.sent.append((s['order'], status, value, has_name))


failures = []


def check(label, cond):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        failures.append(label)


def statuses(src, order=None):
    return [m[1] for m in src.sent if order is None or m[0] == order]


# 1. the measured order: start, response, destination, writes, finish
s = Source()
s.event(START, 0xA)
s.event(RESPONSE, 0xA, object())
s.event(DEST, 0xA, "test.bin")
check("no message before a total is known", s.sent == [])
s.event(WRITE, 0xA, None, 1448, 100000000)
s.publish()
check("first running message carries the name and a tiny fraction", s.sent[-1] == (1, RUNNING, 0, True) and s.names_posted == [(1, "test.bin")])
s.event(WRITE, 0xA, None, 50000000, 100000000)
s.publish(); s.publish()
check("fraction 0.5 sent once (duplicates are not resent)", [m for m in s.sent if m[2] == 5000] == [(1, RUNNING, 5000, True)])
s.event(FINISH, 0xA)
check("finish ends with the finished state", s.sent[-1] == (1, FINISHED, 10000, True))
s.event(WRITE, 0xA, None, 60000000, 100000000)
s.publish()
check("a stale write after the finish changes nothing", s.sent[-1] == (1, FINISHED, 10000, True) and statuses(s).count(FINISHED) == 1)

# 2. cancel after progress
s = Source()
s.event(START, 0xB); s.event(DEST, 0xB, "a.zip"); s.event(WRITE, 0xB, None, 64225280, 400000000); s.publish()
s.event(CANCEL, 0xB)
check("cancel after progress: cancelled at the last fraction", s.sent[-1] == (1, CANCELLED, 1605, True))

# 3. cancel before anything was shown
s = Source()
s.event(START, 0xC); s.event(DEST, 0xC, "b.bin"); s.event(CANCEL, 0xC)
check("cancel before any total shows nothing", s.sent == [])

# 4. a tiny download that ends at once
s = Source()
s.event(START, 0xD); s.event(DEST, 0xD, "tiny.txt"); s.event(WRITE, 0xD, None, 900, 900); s.event(FINISH, 0xD)
check("a download that finishes before the first tick shows only the finished state", statuses(s) == [FINISHED] and s.names_posted == [(1, "tiny.txt")])

# 5. failure and crash show as cancelled (unverified in the field)
for kind, label in ((FAIL, "failure"), (CRASH, "crash")):
    s = Source()
    s.event(START, 0xE); s.event(WRITE, 0xE, None, 10, 100); s.publish(); s.event(kind, 0xE)
    check(label + " after progress ends as cancelled", s.sent[-1][1] == CANCELLED)

# 6. a download whose start was not seen (switch turned on mid-download)
s = Source()
s.event(WRITE, 0xF, None, 30, 100)
s.publish()
check("an unannounced write is adopted when nothing runs (no name)", s.sent == [(1, RUNNING, 3000, False)] and s.names_posted == [])
s.event(FINISH, 0xF)
check("and ends normally", s.sent[-1][1] == FINISHED)
s = Source()
s.event(DEST, 0x10, "late.bin"); s.event(WRITE, 0x10, None, 10, 100); s.publish()
check("an unannounced destination begins the download with its name", s.names_posted == [(1, "late.bin")])

# 7. two downloads: the newest wins, the older one is ignored while the newer runs
s = Source()
s.event(START, 0x11); s.event(DEST, 0x11, "one.bin"); s.event(WRITE, 0x11, None, 10, 100)
s.event(START, 0x12); s.event(DEST, 0x12, "two.bin"); s.event(WRITE, 0x12, None, 20, 100)
s.event(WRITE, 0x11, None, 90, 100)   # the old one keeps writing
s.publish()
check("the older download's writes are ignored while the newest runs", s.sent[-1][0] == 2 and s.rec['written'] == 20)
s.event(FINISH, 0x12)
s.event(WRITE, 0x11, None, 95, 100)
s.publish()
check("when the newest ends, the still-running older one is adopted as a new download (name unknown)", s.sent[-1] == (3, RUNNING, 9500, False))

# 8. an unknown expected size is never published
s = Source()
s.event(START, 0x13); s.event(WRITE, 0x13, None, 5000, 0); s.event(WRITE, 0x13, None, 9000, -1); s.publish()
check("no message for an unknown total", s.sent == [])
s.event(FINISH, 0x13)
check("but a finish is still reported", s.sent == [(1, FINISHED, 10000, False)])

# 9. fraction clamps below 1 until the finish event
s = Source()
s.event(START, 0x14); s.event(WRITE, 0x14, None, 100, 100); s.publish()
check("written == expected is 99.99 percent until the finish event", s.sent[-1] == (1, RUNNING, 9999, False))

# 10. the switch off forgets everything; events are ignored while off
s = Source()
s.event(START, 0x15); s.event(WRITE, 0x15, None, 10, 100); s.publish()
s.switch_off()
s.event(WRITE, 0x15, None, 20, 100); s.publish()
check("nothing is sent or tracked while the source is off", len(s.sent) == 1 and s.rec['order'] == 0)

# 11. a reused object address after a finish is a new download
s = Source()
s.event(START, 0x16); s.event(WRITE, 0x16, None, 10, 100); s.event(FINISH, 0x16)
s.event(START, 0x16); s.event(DEST, 0x16, "again.bin"); s.event(WRITE, 0x16, None, 25, 100); s.publish()
check("a new download at the same address gets a new order and serial", s.sent[-1][0] == 2 and s.rec['serial'] == 2)

# 12. a name that arrives after the first running message is announced with the next message
s = Source()
s.event(START, 0x17); s.event(WRITE, 0x17, None, 10, 100); s.publish()
s.event(DEST, 0x17, "slow-name.bin"); s.event(WRITE, 0x17, None, 11, 100); s.publish()
check("a late name is posted before the message that says it exists", s.names_posted == [(1, "slow-name.bin")] and s.sent[-1][3] is True)

print()
if failures:
    print("SAFARI SOURCE MODEL: %d FAILED" % len(failures))
    sys.exit(1)
print("SAFARI SOURCE MODEL: OK (mirror of the logic, not the Objective-C)")
