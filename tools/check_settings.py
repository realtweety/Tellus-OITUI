#!/usr/bin/env python3
"""Static checks for the Settings plists of Insula (OITI/OITIPrefs/Resources).

Checks (1) that every button action named in a plist is a method of the page's controller (or of OITIBaseListController), and
(2) footer placement: the page builder
(-[OITIBaseListController oiti_buildSettingsPage]) attaches a group's
footerText to the card that follows the group. A group that has a footerText
but is directly followed by another group (or by the end of the list) has no
card to hold it. The builder shows such a footer under the group's header, so
this script only reports them (INFO) to make sure it is deliberate.

Usage: python3 tools/check_settings.py        (run from the repo root)
Exit status 1 only for real problems (a footer on a group with no label and no rows).
"""
import plistlib, glob, os, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "OITI", "OITIPrefs", "Resources")
problems = 0
for path in sorted(glob.glob(os.path.join(root, "*.plist"))):
    name = os.path.basename(path)
    try:
        data = plistlib.load(open(path, "rb"))
    except Exception:
        continue
    items = data.get("items") if isinstance(data, dict) else None
    if not items:
        continue
    for i, item in enumerate(items):
        if item.get("cell") != "PSGroupCell" or not item.get("footerText"):
            continue
        nxt = items[i + 1] if i + 1 < len(items) else None
        has_rows = nxt is not None and nxt.get("cell") != "PSGroupCell"
        if has_rows:
            continue
        label = item.get("label")
        if label:
            print(f"INFO  {name}: group '{label}' has a footer and no rows; shown under its header")
        else:
            print(f"ERROR {name}: group #{i} has a footer, no label and no rows: nothing can show it")
            problems += 1
print("footer check:", "problems found" if problems else "ok")

# (1) Button actions: a PSButtonCell whose action is not implemented does nothing (or raises) when tapped.
import re
prefs_dir = os.path.join(root, "..")
sources = {}
for m in glob.glob(os.path.join(prefs_dir, "*.m")):
    sources[os.path.basename(m)] = open(m, encoding="utf-8").read()
base_text = sources.get("OITIBaseListController.m", "")
def selectors(text):
    return {mm.group(1) for mm in re.finditer(r"^- \(\w+\)\s*(\w+)", text, re.M)}
base_methods = selectors(base_text)
action_problems = 0
for path in sorted(glob.glob(os.path.join(root, "*.plist"))):
    name = os.path.splitext(os.path.basename(path))[0]
    try:
        data = plistlib.load(open(path, "rb"))
    except Exception:
        continue
    items = data.get("items") if isinstance(data, dict) else None
    if not items:
        continue
    controller = None
    for fname, text in sources.items():
        if re.search(r'oiti_plistName\s*\{\s*return @"%s"' % re.escape(name), text):
            controller = fname
    if not controller:
        continue
    methods = selectors(sources[controller]) | base_methods
    for item in items:
        action = item.get("action")
        if item.get("cell") == "PSButtonCell" and action and action.rstrip(":") not in methods:
            print(f"ERROR {name}.plist: action '{action}' is not defined in {controller} or OITIBaseListController.m")
            action_problems += 1
print("button action check:", "problems found" if action_problems else "ok")
problems += action_problems
sys.exit(1 if problems else 0)
sys.exit(1 if problems else 0)
