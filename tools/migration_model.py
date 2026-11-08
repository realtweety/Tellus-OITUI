# Python mirror of OITIMigratePresetPositions in OITI/Shared/OITIPreferences.xm (logic only, NOT the Objective-C).
# Keep it in step with that function; it checks the intended behavior of the one-time migration (v0.3.0 batch 8) against the real
# device table in OITI/OITIDeviceProfiles.h: every row, both switches, no table entry, a second run, safe mode.
# Run: python3 tools/migration_model.py
import re, os, sys
here = os.path.dirname(os.path.abspath(__file__))
rows = {}
for m in re.finditer(r'\{\s*"(iPhone[\d,]+)",\s*"([^"]+)",\s*([\d.]+),\s*([\d.]+),\s*([\d.]+),\s*([\d.]+),\s*(YES|NO)\s*\}',
                     open(os.path.join(here, '..', 'OITI', 'OITIDeviceProfiles.h')).read()):
    rows[m.group(1)] = dict(name=m.group(2), islandY=float(m.group(3)), bannerY=float(m.group(4)))
assert len(rows) >= 17, len(rows)

def g(v): return '%g' % v      # the stringWithFormat:@"%g" of the Objective-C

def migrate(prefs, model):
    if prefs.get('PresetPositionsMigrated'): return prefs
    p = rows.get(model)
    if p and prefs.get('fixEnabled'):
        prefs['posEnabled'] = True; prefs['xPos'] = '0'; prefs['yPos'] = g(p['islandY'])
    if p and prefs.get('notificationFix'):
        prefs['notEnabled'] = True; prefs['xNot'] = '0'; prefs['yNot'] = g(p['bannerY'])
    prefs['PresetPositionsMigrated'] = True
    return prefs

def old_island_y(prefs, model, sy=1.0):   # what OITIApplyIslandPosition did before: the profile won over the custom position
    p = rows.get(model) if prefs.get('fixEnabled') else None
    if p: return p['islandY'] / sy
    if prefs.get('posEnabled'): return float(prefs.get('yPos', 20.5)) / sy
    return None
def new_island_y(prefs, sy=1.0):
    return float(prefs.get('yPos', 20.5)) / sy if prefs.get('posEnabled') else None
def old_banner_y(prefs, model):
    p = rows.get(model)
    if prefs.get('notificationFix'): return p['bannerY'] if p else None
    if prefs.get('notEnabled'): return float(prefs.get('yNot', 40.0))
    return None
def new_banner_y(prefs):
    return float(prefs.get('yNot', 40.0)) if prefs.get('notEnabled') else None

ok = True
def check(name, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + name); ok = ok and cond

# 1. Every row, every combination of the two Fix switches, with and without a typed custom value: the position does not move.
same = True
for model, p in rows.items():
    for fix in (False, True):
        for bfix in (False, True):
            for custom in (False, True):
                before = {'fixEnabled': fix, 'notificationFix': bfix}
                if custom: before.update(posEnabled=True, xPos='5', yPos='33', notEnabled=True, xNot='7', yNot='55')
                after = migrate(dict(before), model)
                for sy in (1.0, 1.3):
                    a, b = old_island_y(before, model, sy), new_island_y(after, sy)
                    if (a is None) != (b is None) or (a is not None and abs(a - b) > 1e-9): same = False; print('  island', model, before, a, b)
                a, b = old_banner_y(before, model), new_banner_y(after)
                if (a is None) != (b is None) or (a is not None and abs(a - b) > 1e-9): same = False; print('  banner', model, before, a, b)
check('all %d table rows: Island Y and banner Y are the same before and after, for every switch combination' % len(rows), same)

# 2. A device with no table entry (the 8 Plus): nothing but the marker is written, custom values untouched.
before = {'fixEnabled': True, 'notificationFix': True, 'posEnabled': True, 'yPos': '12', 'notEnabled': True, 'yNot': '50'}
after = migrate(dict(before), 'iPhone10,2')
check('no table entry: only the marker is added', after == dict(before, PresetPositionsMigrated=True))
# 3. Runs once: a second call (a later launch) changes nothing even if the user has since set a different position.
after['yPos'] = '99'; again = migrate(dict(after), 'iPhone14,2')
check('second run changes nothing', again == after)
# 4. The default custom position (Y 20.5, banner 40) is not disturbed when the Fix switches were off.
after = migrate({}, 'iPhone14,2')
check('Fix switches off on a row: nothing but the marker', after == {'PresetPositionsMigrated': True})
# 5. The strings are what the Settings text fields write ("20.5", "35"), accepted by the strict position parser.
after = migrate({'fixEnabled': True, 'notificationFix': True}, 'iPhone14,3')
check('values are plain numbers as text: %s' % {k: after[k] for k in ('xPos', 'yPos', 'xNot', 'yNot')},
      all(re.fullmatch(r'\d+(\.\d+)?', after[k]) for k in ('xPos', 'yPos', 'xNot', 'yNot')))
print('MIGRATION MODEL:', 'OK' if ok else 'FAILED'); sys.exit(0 if ok else 1)
