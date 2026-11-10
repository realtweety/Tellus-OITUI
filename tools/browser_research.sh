#!/bin/sh
# browser_research.sh -- runs ON THE PHONE (sh, as root). Browser downloads research (0.3.5): every phone-side step in one place.
#
# Put it on the phone once (PC):   scp -P 2222 ~/OITUI/tools/browser_research.sh root@127.0.0.1:/var/mobile/br.sh
# Log in once (PC):                ssh -p 2222 root@127.0.0.1
# Then, on the phone:              sh /var/mobile/br.sh <command> [safari]
#
# Commands (Arc Search unless the last word is "safari"):
#   enable      create the enable file in the app's Library folder (not tmp: iOS may purge tmp). Force-quit and reopen the browser after.
#   status      what exists, what the log says, whether the browser runs, its crash reports, what SpringBoard logged
#   test        post the channel test (the browser must be open with the enable file in place)
#   mark TEXT   append the phone's clock and TEXT to /var/mobile/oiti-marks.txt (press a button in the browser, then run this)
#   marks       print the marks
#   log         print the whole browser log (from the PC:  ssh -p 2222 root@127.0.0.1 'sh /var/mobile/br.sh log' > ~/Downloads/OITIBrowser-all.log)
#   clear       delete the browser log and the marks
#   level 0|1   DiagnosticsLevel for the SpringBoard side (1 is needed to see the channel test arrive)
#   disable     remove the enable file (the research is off again)
# Nothing here changes any setting except DiagnosticsLevel (level) and the two files named above.

APP_ROOT=${APP_ROOT:-/var/mobile/Containers/Data/Application}
export PATH="$PATH:/var/jb/usr/bin:/var/jb/bin"
cmd=${1:-status}
shift 2>/dev/null
BROWSER=arc; ID=ArcMobile2; PROC=ArcMobile2
for a in "$@"; do [ "$a" = safari ] && { BROWSER=safari; ID=com.apple.mobilesafari; PROC=MobileSafari; }; done

app_dir() {
  for d in "$APP_ROOT"/*; do
    f="$d/.com.apple.mobile_container_manager.metadata.plist"
    if [ -f "$f" ] && grep -q "$ID" "$f" 2>/dev/null; then echo "$d"; return 0; fi
  done
  return 1
}
DIR=$(app_dir)
if [ -z "$DIR" ] && [ "$cmd" != "marks" ] && [ "$cmd" != "level" ] && [ "$cmd" != "mark" ]; then
  echo "No data folder found for $BROWSER ($ID) under $APP_ROOT."; exit 1
fi
ENABLE="$DIR/Library/OITIBrowserDump.enable"
LOG="$DIR/Library/OITIBrowser.log"
MARKS=${MARKS:-/var/mobile/oiti-marks.txt}

case "$cmd" in
  enable)
    mkdir -p "$DIR/Library" && touch "$ENABLE" && rm -f "$DIR/tmp/OITIBrowserDump.enable"
    echo "enable file: $ENABLE"; ls -l "$ENABLE"
    echo "Now force-quit $BROWSER on the phone and open it again (the file is read at launch)." ;;
  status)
    echo "=== $BROWSER data folder: $DIR"
    echo "=== enable file:"; ls -l "$ENABLE" 2>&1
    echo "=== browser log:"; ls -l "$LOG" 2>&1
    echo "=== $PROC running:"; ps aux | grep "$PROC" | grep -v grep || echo "(not running)"
    echo "=== last 15 lines of the browser log:"; tail -n 15 "$LOG" 2>&1 | cut -c1-260
    echo "=== newest crash reports of $PROC:"; ls -t /var/mobile/Library/Logs/CrashReporter 2>/dev/null | grep -i "$PROC" | head -n 3
    echo "=== DiagnosticsLevel:"; defaults read com.wilburt.oiti.prefs DiagnosticsLevel 2>&1
    echo "=== BROWSER lines in the SpringBoard log (last 8):"; grep BROWSER /tmp/OITIDebug.log 2>&1 | tail -n 8 | cut -c1-260
    echo "=== SpringBoard session:"; grep "START build" /tmp/OITIDebug.log 2>&1 | tail -n 1 | cut -c1-200 ;;
  test)
    notifyutil -p com.wilburt.oiti/BrowserDump && echo "posted com.wilburt.oiti/BrowserDump; wait 2 s, then run: sh /var/mobile/br.sh status" ;;
  mark)
    echo "$(date +%T) $*" | tee -a "$MARKS" ;;
  marks)
    cat "$MARKS" 2>&1 ;;
  log)
    echo "== $LOG"; cat "$LOG" 2>&1 ;;
  clear)
    rm -f "$LOG" "$MARKS"; echo "cleared the browser log and the marks" ;;
  level)
    lvl=${1:-0}
    defaults write com.wilburt.oiti.prefs DiagnosticsLevel -int "$lvl" && notifyutil -p com.wilburt.oiti/PrefsChanged && echo "DiagnosticsLevel is $lvl" ;;
  disable)
    rm -f "$ENABLE" "$DIR/tmp/OITIBrowserDump.enable"; echo "removed the enable file for $BROWSER; force-quit it to be sure" ;;
  *)
    echo "usage: sh /var/mobile/br.sh enable|status|test|mark TEXT|marks|log|clear|level 0|1|disable [safari]"; exit 2 ;;
esac
