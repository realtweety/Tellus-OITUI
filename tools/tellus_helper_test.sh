#!/bin/sh
# Tests TellusApp/Helper/tellus-helper.c off the phone, in a container or on Linux.
#
# It compiles the helper with test paths (a fake dpkg, temporary folders), builds two tiny .deb files with dpkg-deb, and runs
# the good case and every refusal. It does not touch a phone and installs nothing: the "dpkg" is a script that only logs.
# The helper insists on being root, so run it as root (a container usually is). The "not root" case needs setpriv and is
# skipped without it.
#
#   sh tools/tellus_helper_test.sh
#
# Needs: gcc (or cc), dpkg-deb, sha256sum. Not a device test: the persona spawn, the real dpkg and the real folders are not
# exercised here.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="$HERE/TellusApp/Helper/tellus-helper.c"
W=$(mktemp -d /tmp/tellus-helper-test.XXXXXX)
trap 'rm -rf "$W"' EXIT

command -v dpkg-deb >/dev/null || { echo "dpkg-deb is missing"; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum is missing"; exit 2; }
CC=${CC:-cc}
[ "$(id -u)" = 0 ] || { echo "run as root: the helper refuses to install otherwise"; exit 2; }

mkdir -p "$W/stage" "$W/outside"

printf '#!/bin/sh\necho "FAKE-DPKG $*" >> %s/dpkg.log\nexit 0\n' "$W" > "$W/ok-dpkg.sh"
printf '#!/bin/sh\necho "dpkg: error processing archive (simulated)"\nexit 1\n' > "$W/fail-dpkg.sh"
chmod +x "$W/ok-dpkg.sh" "$W/fail-dpkg.sh"

build_helper() {   # $1 = output, $2 = the dpkg script
    "$CC" -Wall -Wextra \
        -DTELLUS_DPKG_PATH="\"$2\"" -DTELLUS_DPKG_DEB_PATH="\"$(command -v dpkg-deb)\"" \
        -DTELLUS_PRIVATE_DIR="\"$W/priv\"" -DTELLUS_STAGING_DIR_1="\"$W/stage\"" -DTELLUS_STAGING_DIR_2="\"$W/stage-2\"" \
        -o "$1" "$SRC" || { echo "the helper does not compile"; exit 1; }
}
build_helper "$W/helper" "$W/ok-dpkg.sh"
build_helper "$W/helper-fail" "$W/fail-dpkg.sh"

make_deb() {   # $1 = package id, $2 = output file
    d="$W/pkg-$1"; mkdir -p "$d/DEBIAN"
    printf 'Package: %s\nVersion: 0.1.0\nArchitecture: iphoneos-arm64\nMaintainer: test\nDescription: test\n' "$1" > "$d/DEBIAN/control"
    dpkg-deb --build "$d" "$2" >/dev/null 2>&1 || { echo "dpkg-deb failed"; exit 1; }
}
CORE="com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb"
make_deb com.wilburt.oitcore "$W/stage/$CORE"
make_deb com.wilburt.tellus "$W/stage/com.wilburt.tellus_0.1.0_iphoneos-arm64.deb"
HASH=$(sha256sum "$W/stage/$CORE" | cut -d' ' -f1)
TELLUS_HASH=$(sha256sum "$W/stage/com.wilburt.tellus_0.1.0_iphoneos-arm64.deb" | cut -d' ' -f1)

PASS=0; FAIL=0
expect() {   # $1 = label, $2 = expected exit code, rest = command
    label="$1"; want="$2"; shift 2
    out=$("$@" 2>&1); got=$?
    if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); echo "ok   $label (exit $got)"
    else FAIL=$((FAIL + 1)); echo "FAIL $label: wanted exit $want, got $got"; echo "$out" | sed 's/^/     /'; fi
}

expect "valid OITCore install" 0 "$W/helper" --install "$W/stage/$CORE" "$HASH" com.wilburt.oitcore
grep -q "FAKE-DPKG -i --force-confold $W/priv/$CORE" "$W/dpkg.log" && { PASS=$((PASS + 1)); echo "ok   dpkg ran on the private copy"; } || { FAIL=$((FAIL + 1)); echo "FAIL dpkg did not run on the private copy"; }
[ -z "$(ls "$W/priv" 2>/dev/null)" ] && { PASS=$((PASS + 1)); echo "ok   the private copy is removed afterwards"; } || { FAIL=$((FAIL + 1)); echo "FAIL the private copy is still there"; }
expect "valid Tellus install" 0 "$W/helper" --install "$W/stage/com.wilburt.tellus_0.1.0_iphoneos-arm64.deb" "$TELLUS_HASH" com.wilburt.tellus
expect "wrong checksum" 18 "$W/helper" --install "$W/stage/$CORE" 0000000000000000000000000000000000000000000000000000000000000000 com.wilburt.oitcore
expect "package not on the allowlist (Litus)" 11 "$W/helper" --install "$W/stage/$CORE" "$HASH" com.wilburt.oits
expect "package not on the allowlist (anything else)" 11 "$W/helper" --install "$W/stage/$CORE" "$HASH" com.evil.package
cp "$W/stage/$CORE" "$W/outside/$CORE"
expect "file outside the update folder" 14 "$W/helper" --install "$W/outside/$CORE" "$HASH" com.wilburt.oitcore
ln -sf "$W/outside/$CORE" "$W/stage/com.wilburt.oitcore_9.9.9_x.deb"
expect "symlink pointing out of the update folder" 14 "$W/helper" --install "$W/stage/com.wilburt.oitcore_9.9.9_x.deb" "$HASH" com.wilburt.oitcore
expect "path with .. out of the update folder" 14 "$W/helper" --install "$W/stage/../outside/$CORE" "$HASH" com.wilburt.oitcore
expect "file name does not match the package" 15 "$W/helper" --install "$W/stage/$CORE" "$HASH" com.wilburt.oiti
cp "$W/stage/$CORE" "$W/stage/com.wilburt.oiti_0.0.1_iphoneos-arm64.deb"
expect "a different package inside the file" 20 "$W/helper" --install "$W/stage/com.wilburt.oiti_0.0.1_iphoneos-arm64.deb" "$HASH" com.wilburt.oiti
expect "checksum is not a SHA-256 value" 12 "$W/helper" --install "$W/stage/$CORE" ABC com.wilburt.oitcore
expect "file does not exist" 13 "$W/helper" --install "$W/stage/missing_1.deb" "$HASH" com.wilburt.oitcore
expect "dpkg fails" 30 "$W/helper-fail" --install "$W/stage/$CORE" "$HASH" com.wilburt.oitcore
[ -z "$(ls "$W/priv" 2>/dev/null)" ] && { PASS=$((PASS + 1)); echo "ok   the private copy is removed after a failed dpkg"; } || { FAIL=$((FAIL + 1)); echo "FAIL the private copy survived a failed dpkg"; }
expect "unknown mode" 2 "$W/helper" --stat /etc/hostname
expect "no arguments" 2 "$W/helper"
if command -v setpriv >/dev/null; then
    chmod 755 "$W" "$W/helper"
    expect "not running as root" 10 setpriv --reuid=65534 --regid=65534 --clear-groups "$W/helper" --install "$W/stage/$CORE" "$HASH" com.wilburt.oitcore
else
    echo "skip not running as root (no setpriv)"
fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
