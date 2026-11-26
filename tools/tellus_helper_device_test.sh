#!/bin/sh
# Runs on the PHONE, as root, against the REAL installed tellus-helper, the real dpkg and the built-in public keys.
# It checks that a genuinely signed release is accepted and that every kind of tampering is refused with the right exit code.
#
#   sh tellus_helper_device_test.sh <folder>
#
# <folder> must hold the files of one signed release candidate: com.wilburt.oitcore_<version>_iphoneos-arm64.deb, SHA256SUMS and
# SHA256SUMS.sig. The first case really reinstalls that OITCore package (the version that is already installed, which the helper
# allows). Nothing else is installed: every other case is refused before dpkg runs. The test files are removed from Tellus's update
# folder afterwards.
#
# HELPER and STAGE can be overridden (tools/tellus_helper_test.sh does that to test this script off the phone).

HELPER=${HELPER:-/var/jb/usr/libexec/tellus-helper}
STAGE=${STAGE:-/var/mobile/Library/Caches/TellusUpdates}
SRC=${1:-}
PKGID=com.wilburt.oitcore

[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "usage: sh $0 <folder with the OITCore .deb, SHA256SUMS and SHA256SUMS.sig>"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
[ -x "$HELPER" ] || { echo "no helper at $HELPER"; exit 2; }
DEB=$(ls "$SRC"/${PKGID}_*.deb 2>/dev/null | head -n 1)
[ -n "$DEB" ] && [ -f "$SRC/SHA256SUMS" ] && [ -f "$SRC/SHA256SUMS.sig" ] || { echo "the folder needs $PKGID _*.deb, SHA256SUMS and SHA256SUMS.sig"; exit 2; }
NAME=$(basename "$DEB")
OTHER_NAME=${PKGID}_9.9.9_iphoneos-arm64.deb

PASS=0; FAIL=0
cleanup() { rm -f "$STAGE/$NAME" "$STAGE/$OTHER_NAME" "$STAGE/SHA256SUMS" "$STAGE/SHA256SUMS.sig" "$STAGE/../$NAME"; }
trap cleanup EXIT
prepare() {
    mkdir -p "$STAGE" || exit 2
    cleanup
    cp "$DEB" "$STAGE/$NAME" && cp "$SRC/SHA256SUMS" "$STAGE/SHA256SUMS" && cp "$SRC/SHA256SUMS.sig" "$STAGE/SHA256SUMS.sig" || exit 2
}
check() {   # $1 = label, $2 = expected exit code, rest = command
    label="$1"; want="$2"; shift 2
    out=$("$@" 2>&1); got=$?
    if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); echo "ok   $label (exit $got)"
    else FAIL=$((FAIL + 1)); echo "FAIL $label: wanted exit $want, got $got"; echo "$out" | sed 's/^/     /'; fi
}
install_cmd() { "$HELPER" --install "$STAGE/$1" "$STAGE/SHA256SUMS" "$STAGE/SHA256SUMS.sig" "$2"; }

if "$HELPER" --probe | grep -q "trusted signing keys: 2"; then PASS=$((PASS + 1)); echo "ok   the helper reports two trusted signing keys"
else FAIL=$((FAIL + 1)); echo "FAIL the helper does not report two trusted signing keys (is this the signing-capable helper?)"; fi

prepare
check "signed release is accepted (reinstalls $PKGID)" 0 install_cmd "$NAME" $PKGID

prepare; printf 'tampered\n' >> "$STAGE/SHA256SUMS"
check "SHA256SUMS changed after signing" 22 install_cmd "$NAME" $PKGID

prepare; printf 'X' | dd of="$STAGE/SHA256SUMS.sig" bs=1 seek=10 conv=notrunc 2>/dev/null
check "one byte of the signature changed" 22 install_cmd "$NAME" $PKGID

prepare; rm "$STAGE/SHA256SUMS.sig"
check "signature file missing" 21 install_cmd "$NAME" $PKGID

prepare; printf 'x' >> "$STAGE/$NAME"
check "package changed after signing" 18 install_cmd "$NAME" $PKGID

prepare; cp "$STAGE/$NAME" "$STAGE/$OTHER_NAME"
check "package that the signed list does not mention" 23 install_cmd "$OTHER_NAME" $PKGID

prepare; cp "$STAGE/$NAME" "$STAGE/../$NAME"
check "package outside Tellus's update folder" 14 "$HELPER" --install "$STAGE/../$NAME" "$STAGE/SHA256SUMS" "$STAGE/SHA256SUMS.sig" $PKGID

prepare
check "package id that is not allowed" 11 install_cmd "$NAME" com.example.other

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
