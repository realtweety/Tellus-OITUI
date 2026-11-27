#!/bin/sh
# Tests TellusApp/Helper/tellus-helper.c off the phone, in a container or on Linux.
#
# It compiles the helper (with the vendored Monocypher Ed25519 code) with test paths, test signing keys and a fake dpkg,
# builds tiny .deb files with dpkg-deb, signs manifests with throwaway keys made by OpenSSL, and runs the good cases and every
# refusal. It does not touch a phone and installs nothing: the "dpkg" is a script that only logs (it passes
# "--compare-versions" through to the real dpkg). The helper insists on being root, so run it as root (a container usually is).
# The "not root" case needs setpriv and is skipped without it.
#
#   sh tools/tellus_helper_test.sh
#
# Needs: gcc (or cc), dpkg, dpkg-deb, sha256sum, openssl 3 (raw Ed25519; macOS's LibreSSL is not enough). Not a device test:
# the persona spawn, the real dpkg and the real folders are not exercised here.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="$HERE/TellusApp/Helper/tellus-helper.c"
VENDOR="$HERE/TellusApp/Helper"
W=$(mktemp -d /tmp/tellus-helper-test.XXXXXX)
trap 'rm -rf "$W"' EXIT

command -v dpkg-deb >/dev/null || { echo "dpkg-deb is missing"; exit 2; }
command -v dpkg >/dev/null || { echo "dpkg is missing"; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum is missing"; exit 2; }
command -v openssl >/dev/null || { echo "openssl is missing"; exit 2; }
CC=${CC:-cc}
[ "$(id -u)" = 0 ] || { echo "run as root: the helper refuses to install otherwise"; exit 2; }
REAL_DPKG=$(command -v dpkg)

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
expect() {   # $1 = label, $2 = expected exit code, rest = command
    label="$1"; want="$2"; shift 2
    out=$("$@" 2>&1); got=$?
    if [ "$got" = "$want" ]; then ok "$label (exit $got)"
    else bad "$label: wanted exit $want, got $got"; echo "$out" | sed 's/^/     /'; fi
}

mkdir -p "$W/stage" "$W/outside" "$W/installed"

# ---- the vendored Ed25519 code
"$CC" -O2 -c "$VENDOR/monocypher.c" -o "$W/monocypher.o" || { echo "monocypher.c does not compile"; exit 1; }
"$CC" -O2 -c "$VENDOR/monocypher-ed25519.c" -o "$W/monocypher-ed25519.o" || { echo "monocypher-ed25519.c does not compile"; exit 1; }
"$CC" -I "$VENDOR" -o "$W/vectors" "$HERE/tools/ed25519_vector_test.c" "$W/monocypher.o" "$W/monocypher-ed25519.o" \
    || { echo "the vector test does not compile"; exit 1; }
if "$W/vectors" > "$W/vectors.log" 2>&1; then ok "Ed25519 matches the RFC 8032 test vectors"; else bad "Ed25519 test vectors"; cat "$W/vectors.log"; fi

# ---- throwaway keys: A (primary), B (backup), C (not trusted)
for k in A B C; do openssl genpkey -algorithm ed25519 -out "$W/key$k.pem" 2>/dev/null || { echo "openssl cannot make Ed25519 keys"; exit 2; }; done
pub_hex() { openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d ' \n'; }
PUB_A=$(pub_hex "$W/keyA.pem"); PUB_B=$(pub_hex "$W/keyB.pem")

# ---- fake dpkg and dpkg-query
cat > "$W/ok-dpkg.sh" <<STUB
#!/bin/sh
[ "\$1" = "--compare-versions" ] && exec $REAL_DPKG "\$@"
echo "FAKE-DPKG \$*" >> $W/dpkg.log
exit 0
STUB
cat > "$W/fail-dpkg.sh" <<STUB
#!/bin/sh
[ "\$1" = "--compare-versions" ] && exec $REAL_DPKG "\$@"
echo "dpkg: error processing archive (simulated)"
exit 1
STUB
cat > "$W/fake-dpkg-query.sh" <<STUB
#!/bin/sh
for last; do :; done
[ -f "$W/installed/\$last.error" ] && { echo "dpkg-query: broken" >&2; exit 2; }
[ -f "$W/installed/\$last" ] && { printf '%s' "\$(cat $W/installed/\$last)"; exit 0; }
echo "dpkg-query: no packages found matching \$last" >&2
exit 1
STUB
chmod +x "$W/ok-dpkg.sh" "$W/fail-dpkg.sh" "$W/fake-dpkg-query.sh"

build_helper() {   # $1 = output, $2 = the dpkg script, $3 = "prod" to keep the shipped signing keys
    keys="-DTELLUS_TRUSTED_KEY_1=\"\\\"$PUB_A\\\"\" -DTELLUS_TRUSTED_KEY_2=\"\\\"$PUB_B\\\"\""
    [ "${3:-}" = prod ] && keys=""
    eval "\"\$CC\" -Wall -Wextra -I \"\$VENDOR\" $keys \
        -DTELLUS_DPKG_PATH=\"\\\"\$2\\\"\" -DTELLUS_DPKG_DEB_PATH=\"\\\"\$(command -v dpkg-deb)\\\"\" \
        -DTELLUS_DPKG_QUERY_PATH=\"\\\"\$W/fake-dpkg-query.sh\\\"\" \
        -DTELLUS_PRIVATE_DIR=\"\\\"\$W/priv\\\"\" -DTELLUS_STAGING_DIR_1=\"\\\"\$W/stage\\\"\" -DTELLUS_STAGING_DIR_2=\"\\\"\$W/stage-2\\\"\" \
        -o \"\$1\" \"\$SRC\" \"\$W/monocypher.o\" \"\$W/monocypher-ed25519.o\"" || { echo "the helper does not compile"; exit 1; }
}
build_helper "$W/helper" "$W/ok-dpkg.sh"
build_helper "$W/helper-fail" "$W/fail-dpkg.sh"
build_helper "$W/helper-prod" "$W/ok-dpkg.sh" prod

make_deb() {   # $1 = package id, $2 = output file, $3 = version (default 0.1.0)
    d="$W/pkg-$1"; mkdir -p "$d/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: iphoneos-arm64\nMaintainer: test\nDescription: test\n' "$1" "${3:-0.1.0}" > "$d/DEBIAN/control"
    dpkg-deb --build "$d" "$2" >/dev/null 2>&1 || { echo "dpkg-deb failed"; exit 1; }
}
CORE="com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb"
TELLUS="com.wilburt.tellus_0.1.0_iphoneos-arm64.deb"
OITI_FAKE="com.wilburt.oiti_0.0.1_iphoneos-arm64.deb"
make_deb com.wilburt.oitcore "$W/stage/$CORE"
make_deb com.wilburt.tellus "$W/stage/$TELLUS"
cp "$W/stage/$CORE" "$W/stage/$OITI_FAKE"      # a different package inside a file named for Insula
cp "$W/stage/$CORE" "$W/core.orig"
CORE_HASH=$(sha256sum "$W/stage/$CORE" | cut -d' ' -f1)
TELLUS_HASH=$(sha256sum "$W/stage/$TELLUS" | cut -d' ' -f1)

MANIFEST="$W/stage/SHA256SUMS"; SIGNATURE="$W/stage/SHA256SUMS.sig"
sign_with() { openssl pkeyutl -sign -rawin -inkey "$1" -in "$MANIFEST" -out "$SIGNATURE" || { echo "signing failed"; exit 2; }; }
good_manifest() { ( cd "$W/stage" && sha256sum "$CORE" "$TELLUS" "$OITI_FAKE" > SHA256SUMS ); }
reset_good() { cp "$W/core.orig" "$W/stage/$CORE"; good_manifest; sign_with "$W/keyA.pem"; rm -f "$W/installed/"*; }
install_cmd() {   # $1 = helper, $2 = package file name, $3 = package id
    "$1" --install "$W/stage/$2" "$MANIFEST" "$SIGNATURE" "$3"
}
reset_good

# ---- the good cases
expect "valid OITCore install (primary key)" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
grep -q "FAKE-DPKG -i --force-confold $W/priv/$CORE" "$W/dpkg.log" && ok "dpkg ran on the private copy" || bad "dpkg did not run on the private copy"
[ -z "$(ls "$W/priv" 2>/dev/null)" ] && ok "the private copy is removed afterwards" || bad "the private copy is still there"
expect "valid Tellus install" 0 install_cmd "$W/helper" "$TELLUS" com.wilburt.tellus
sign_with "$W/keyB.pem"
expect "valid install signed by the backup key" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
"$W/helper" --probe | grep -q "trusted signing keys: 2" && ok "--probe reports two trusted keys" || bad "--probe does not report the trusted keys"

# ---- signature refusals
reset_good
rm "$SIGNATURE"
expect "signature file missing" 21 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; head -c 64 /dev/urandom > "$SIGNATURE"
expect "random bytes as the signature" 22 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; sign_with "$W/keyC.pem"
expect "signed by a key that is not trusted" 22 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; printf '%s  extra-file.deb\n' "$CORE_HASH" >> "$MANIFEST"
expect "manifest changed after signing" 22 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; head -c 63 "$SIGNATURE" > "$W/stage/short.sig"; mv "$W/stage/short.sig" "$SIGNATURE"
expect "signature of the wrong size" 21 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good
expect "valid signature, but the test helper's keys are not the shipped keys" 22 install_cmd "$W/helper-prod" "$CORE" com.wilburt.oitcore
cp "$SIGNATURE" "$W/stage/other.sig"
expect "signature file with the wrong name" 21 "$W/helper" --install "$W/stage/$CORE" "$MANIFEST" "$W/stage/other.sig" com.wilburt.oitcore
rm "$W/stage/other.sig"
cp "$MANIFEST" "$W/stage/other-sums"
expect "manifest with the wrong name" 21 "$W/helper" --install "$W/stage/$CORE" "$W/stage/other-sums" "$SIGNATURE" com.wilburt.oitcore
rm "$W/stage/other-sums"
cp "$MANIFEST" "$W/outside/SHA256SUMS"; cp "$SIGNATURE" "$W/outside/SHA256SUMS.sig"
expect "manifest and signature outside the update folder" 21 "$W/helper" --install "$W/stage/$CORE" "$W/outside/SHA256SUMS" "$W/outside/SHA256SUMS.sig" com.wilburt.oitcore
expect "manifest does not exist" 21 "$W/helper" --install "$W/stage/$CORE" "$W/stage/nothing" "$SIGNATURE" com.wilburt.oitcore

# ---- manifest contents (always signed correctly by key A)
reset_good; printf '%s  %s\n' "$TELLUS_HASH" "$TELLUS" > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "package not listed in the signed manifest" 23 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; { printf '%s  %s\n' "$CORE_HASH" "$CORE"; printf '%s  %s\n' "$TELLUS_HASH" "$CORE"; } > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "package listed twice with different hashes" 23 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; { printf '%s  %s\n' "$CORE_HASH" "$CORE"; printf '%s  %s\n' "$CORE_HASH" "$CORE"; } > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "package listed twice with the same hash" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; printf '%s *%s' "$CORE_HASH" "$CORE" > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "binary-mode line without a final newline" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; printf '%s  %s\r\n' "$CORE_HASH" "$CORE" > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "Windows line ending" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$CORE" > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "signed manifest lists a different hash" 18 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; printf 'x' >> "$W/stage/$CORE"
expect "package changed after signing" 18 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
reset_good; printf '%s  %s\n' "$(echo $CORE_HASH | tr a-f A-F)" "$CORE" > "$MANIFEST"; sign_with "$W/keyA.pem"
expect "uppercase hash in the manifest is not accepted" 23 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore

# ---- the older checks, now with a signed manifest
reset_good
expect "package not on the allowlist (Litus)" 11 install_cmd "$W/helper" "$CORE" com.wilburt.oits
expect "package not on the allowlist (anything else)" 11 install_cmd "$W/helper" "$CORE" com.evil.package
cp "$W/stage/$CORE" "$W/outside/$CORE"
expect "package outside the update folder" 14 "$W/helper" --install "$W/outside/$CORE" "$MANIFEST" "$SIGNATURE" com.wilburt.oitcore
ln -sf "$W/outside/$CORE" "$W/stage/com.wilburt.oitcore_9.9.9_x.deb"
expect "symlink pointing out of the update folder" 14 "$W/helper" --install "$W/stage/com.wilburt.oitcore_9.9.9_x.deb" "$MANIFEST" "$SIGNATURE" com.wilburt.oitcore
expect "path with .. out of the update folder" 14 "$W/helper" --install "$W/stage/../outside/$CORE" "$MANIFEST" "$SIGNATURE" com.wilburt.oitcore
expect "file name does not match the package" 15 install_cmd "$W/helper" "$CORE" com.wilburt.oiti
expect "a different package inside the file" 20 install_cmd "$W/helper" "$OITI_FAKE" com.wilburt.oiti
expect "package file does not exist" 13 "$W/helper" --install "$W/stage/missing_1.deb" "$MANIFEST" "$SIGNATURE" com.wilburt.oitcore
expect "dpkg fails" 30 install_cmd "$W/helper-fail" "$CORE" com.wilburt.oitcore
[ -z "$(ls "$W/priv" 2>/dev/null)" ] && ok "the private copy is removed after a failed dpkg" || bad "the private copy survived a failed dpkg"
expect "the old four-argument form (a hash instead of a manifest) is refused" 2 "$W/helper" --install "$W/stage/$CORE" "$CORE_HASH" com.wilburt.oitcore
expect "unknown mode" 2 "$W/helper" --stat /etc/hostname
expect "no arguments" 2 "$W/helper"

# ---- downgrade protection (the package inside is version 0.1.0)
reset_good
echo -n "0.2.0" > "$W/installed/com.wilburt.oitcore"
expect "installed version is newer: refused" 24 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
[ -z "$(ls "$W/priv" 2>/dev/null)" ] && ok "the private copy is removed after a refused downgrade" || bad "the private copy survived a refused downgrade"
echo -n "0.1.0" > "$W/installed/com.wilburt.oitcore"
expect "installed version is equal: allowed" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
echo -n "0.0.9" > "$W/installed/com.wilburt.oitcore"
expect "installed version is older: allowed" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
echo -n "0.1.0~rc.1" > "$W/installed/com.wilburt.oitcore"
expect "installed pre-release of the same version: allowed" 0 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
rm -f "$W/installed/com.wilburt.oitcore"; touch "$W/installed/com.wilburt.oitcore.error"
expect "installed version cannot be read: refused" 25 install_cmd "$W/helper" "$CORE" com.wilburt.oitcore
rm -f "$W/installed/"*

if command -v setpriv >/dev/null; then
    chmod 755 "$W" "$W/helper"
    expect "not running as root" 10 setpriv --reuid=65534 --regid=65534 --clear-groups "$W/helper" --install "$W/stage/$CORE" "$MANIFEST" "$SIGNATURE" com.wilburt.oitcore
else
    echo "skip not running as root (no setpriv)"
fi

# ---- the on-phone test script, run here against this test build (test keys, fake dpkg)
mkdir -p "$W/devsrc"
cp "$W/core.orig" "$W/devsrc/$CORE"
( cd "$W/devsrc" && sha256sum "$CORE" > SHA256SUMS )
openssl pkeyutl -sign -rawin -inkey "$W/keyA.pem" -in "$W/devsrc/SHA256SUMS" -out "$W/devsrc/SHA256SUMS.sig"
rm -f "$W/installed/"*
export DPKG="$REAL_DPKG" DPKG_DEB="$(command -v dpkg-deb)" DPKG_QUERY="$W/fake-dpkg-query.sh"
if HELPER="$W/helper" STAGE="$W/stage" sh "$HERE/tools/tellus_helper_device_test.sh" "$W/devsrc" > "$W/devtest.log" 2>&1; then
    ok "tools/tellus_helper_device_test.sh passes against this test build ($(grep -c '^ok' "$W/devtest.log") checks)"
else
    bad "tools/tellus_helper_device_test.sh fails against this test build"; sed 's/^/     /' "$W/devtest.log"
fi
# ... and with an older signed Tellus package, which the helper must refuse because a newer Tellus is installed (exit 24)
mkdir -p "$W/devolder"
cp "$W/stage/$TELLUS" "$W/devolder/$TELLUS"     # Tellus 0.1.0
( cd "$W/devolder" && sha256sum "$TELLUS" > SHA256SUMS )
openssl pkeyutl -sign -rawin -inkey "$W/keyA.pem" -in "$W/devolder/SHA256SUMS" -out "$W/devolder/SHA256SUMS.sig"
printf '%s' "0.2.0" > "$W/installed/com.wilburt.tellus"
if HELPER="$W/helper" STAGE="$W/stage" sh "$HERE/tools/tellus_helper_device_test.sh" "$W/devsrc" "$W/devolder" > "$W/devtest2.log" 2>&1 \
   && grep -q "^ok   older signed Tellus 0.1.0 is refused while 0.2.0 is installed (exit 24)" "$W/devtest2.log"; then
    ok "the device script's older-version case passes (the helper refuses Tellus 0.1.0 over 0.2.0)"
else
    bad "the device script's older-version case"; sed 's/^/     /' "$W/devtest2.log"
fi
printf '%s' "0.0.5" > "$W/installed/com.wilburt.tellus"
if HELPER="$W/helper" STAGE="$W/stage" sh "$HERE/tools/tellus_helper_device_test.sh" "$W/devsrc" "$W/devolder" > "$W/devtest3.log" 2>&1 \
   && grep -q "^skip the older-version check" "$W/devtest3.log"; then
    ok "the device script skips the older-version case when the installed Tellus is not newer"
else
    bad "the device script's skip of the older-version case"; sed 's/^/     /' "$W/devtest3.log"
fi
rm -f "$W/installed/"*

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
