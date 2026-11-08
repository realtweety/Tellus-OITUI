#!/bin/bash
# cards_matrix.sh -- runs on the PHONE (as root, over SSH). v0.3.0 polish, batch 7, item 3.
#
# Walks the stack cards through a set of Island Style, Island Size, Custom Position and Custom Scale cases: for each case it applies
# the settings, posts the settings-changed notification, sends four test notices (the developer trigger, like COMMANDS.md "Tool:
# four test notifications over SSH") and prints the STACKCARDS lines the case produced. The lines say where the Island was measured,
# where the cards went and whether they overlap the Island or leave the screen ("WARNING"). It only changes the keys it lists and
# puts every one of them back at the end (or deletes a key that was not set before). Needs DiagnosticsLevel 1 or higher and the
# notifications switches on (Settings > Insula > Notifications: Show Notifications in the Island; Stack on).
#
#   scp -P 2222 tools/cards_matrix.sh root@localhost:/tmp/ && ssh -p 2222 root@localhost bash /tmp/cards_matrix.sh
#
# Send me the output. About 3 minutes. Reduce Motion should be off. Ctrl-C is safe: the original values are restored on exit.

# Rootless: the tools live in /var/jb/..., and a non-interactive SSH command gets a short PATH ("notifyutil: command not found" in the
# 2026-11-06 run even with darwintools installed, so no setting was ever reloaded). Search the usual places first.
export PATH="/var/jb/usr/bin:/var/jb/usr/local/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
NOTIFY=$(command -v notifyutil)
if [ -z "$NOTIFY" ]; then
  echo "notifyutil not found. Where is it? Try: ls /var/jb/usr/bin | grep -i notify   or   dpkg -L darwintools | grep notifyutil"
  echo "Then put that folder in PATH at the top of this script, or run it with: PATH=<that folder>:\$PATH bash /tmp/cards_matrix.sh"
  exit 1
fi
echo "using $NOTIFY"

DOMAIN=com.wilburt.oiti.prefs
LOG=/tmp/OITIDebug.log
KEYS="IslandNotificationsStyle MetricsSensorWidthScale MetricsSensorHeightScale scaleEnabled RelativeScaleX RelativeScaleY posEnabled yPos"
TMP=/tmp/OITICardsMatrix.saved
: > "$TMP"

level=$(defaults read $DOMAIN DiagnosticsLevel 2>/dev/null || echo 0)
if [ "$level" -lt 1 ]; then echo "DiagnosticsLevel is $level: set it to 1 (defaults write $DOMAIN DiagnosticsLevel -int 1), sbreload, then run again."; exit 1; fi
[ -f "$LOG" ] || { echo "no $LOG: DiagnosticsLevel must be 1 or higher and SpringBoard must have restarted since."; exit 1; }

echo "settings before the run: $(for k in $KEYS; do printf "%s=%s " $k "$(defaults read $DOMAIN $k 2>/dev/null || echo unset)"; done)"
for k in $KEYS; do
  v=$(defaults read $DOMAIN $k 2>/dev/null) && echo "$k=$v" >> "$TMP" || echo "$k=<unset>" >> "$TMP"
done

restore() {
  echo; echo "== restoring settings =="
  while IFS='=' read -r k v; do
    if [ "$v" = "<unset>" ]; then defaults delete $DOMAIN "$k" 2>/dev/null
    else
      case $k in
        IslandNotificationsStyle) defaults write $DOMAIN "$k" -int "$v" ;;
        scaleEnabled|posEnabled)  case $v in 1|true|YES) defaults write $DOMAIN "$k" -bool true ;; *) defaults write $DOMAIN "$k" -bool false ;; esac ;;
        yPos)                     defaults write $DOMAIN "$k" -string "$v" ;;
        *)                        defaults write $DOMAIN "$k" -float "$v" ;;
      esac
    fi
  done < "$TMP"
  "$NOTIFY" -p com.wilburt.oiti/PrefsChanged
  echo "done"
}
trap restore EXIT

apply() { # style width height customScale(0|1) scaleXY customPos(0|1) yPos
  defaults write $DOMAIN IslandNotificationsStyle -int "$1"
  defaults write $DOMAIN MetricsSensorWidthScale -float "$2"
  defaults write $DOMAIN MetricsSensorHeightScale -float "$3"
  if [ "$4" = 1 ]; then defaults write $DOMAIN scaleEnabled -bool true; else defaults write $DOMAIN scaleEnabled -bool false; fi
  defaults write $DOMAIN RelativeScaleX -float "$5"
  defaults write $DOMAIN RelativeScaleY -float "$5"
  if [ "$6" = 1 ]; then defaults write $DOMAIN posEnabled -bool true; else defaults write $DOMAIN posEnabled -bool false; fi
  defaults write $DOMAIN yPos -string "$7"
  "$NOTIFY" -p com.wilburt.oiti/PrefsChanged
}

fire() { # four notices, fixed order, 1.8 s apart
  for n in 1 2 3 4; do
    case $n in
      1) t="Alex";     m="Are we still on for tonight?";  b=com.apple.MobileSMS ;;
      2) t="Calendar"; m="Standup starts in 10 minutes";  b=com.apple.mobilecal ;;
      3) t="Mail";     m="Your order has shipped";        b=com.apple.mobilemail ;;
      4) t="Mom";      m="Call me when you get a chance"; b=com.apple.MobileSMS ;;
    esac
    printf '%s\n%s\n%s\n' "$t" "$m" "$b" > /tmp/OITIPoCSample.txt
    touch /tmp/OITIPoC.trigger
    sleep 1.8
  done
}

run_case() { # name, then the apply arguments
  name=$1; shift
  echo; echo "=== $name ==="
  apply "$@"
  sleep 3
  before=$(wc -c < "$LOG")
  fire
  sleep 5
  tail -c +$((before + 1)) "$LOG" | grep "STACKCARDS" | grep -E "placement|refresh|cards (hidden|shown|removed|leaving)|morph" | cut -c1-420 | head -n 14
  sleep 8   # let the notices time out before the next case
}

#         name                          style width height customScale scale customPos yPos
run_case "Expanded, defaults"            2 1.0 1.0 0 1.0 0 20.5
run_case "Wide"                          1 1.0 1.0 0 1.0 0 20.5
run_case "Compact"                       0 1.0 1.0 0 1.0 0 20.5
run_case "Expanded, Island width 0.8"    2 0.8 1.0 0 1.0 0 20.5
run_case "Expanded, Island width 1.3"    2 1.3 1.0 0 1.0 0 20.5
run_case "Expanded, Island height 1.2"   2 1.0 1.2 0 1.0 0 20.5
run_case "Expanded, custom position Y 35" 2 1.0 1.0 0 1.0 1 35
run_case "Expanded, custom position Y 60" 2 1.0 1.0 0 1.0 1 60
run_case "Expanded, custom scale 1.3"    2 1.0 1.0 1 1.3 0 20.5
