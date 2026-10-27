#!/usr/bin/env bash
# Exercise package-manager dispatch with fixtures, never the installer entrypoint.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/assets" "$scratch/target root/etc" "$scratch/target root/usr/bin"
cp "$repo/po0-lib.sh" "$scratch/assets/po0-lib.sh"
cat >"$scratch/assets/po0-chrony.sh" <<'EOF'
#!/bin/sh
printf 'configure:%s\n' "$1" >>"$TEST_LOG"
EOF
sed '/^: main$/,$d' "$repo/trans.sh" >"$scratch/trans-functions.sh"
export PO0_ASSET_DIR="$scratch/assets"
export TEST_LOG="$scratch/commands.log"
set +u
. "$scratch/trans-functions.sh"
set -u

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
error_and_exit() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
po0_rewrite_target_repos() { printf 'repos:%s\n' "$1" >>"$TEST_LOG"; }
is_have_cmd_on_disk() { [ -f "$1/usr/bin/$2" ]; }
chroot_apt_install() {
    printf 'apt:%s:%s\n' "$1" "$2" >>"$TEST_LOG"
    [ "${FAIL_PACKAGE:-0}" != 1 ]
}
chroot() {
    printf 'chroot:%s\n' "$*" >>"$TEST_LOG"
    [ "${FAIL_PACKAGE:-0}" != 1 ]
}
timeout() { printf 'timeout:%s\n' "$*" >>"$TEST_LOG"; }

target="$scratch/target root"
reset_target() {
    rm -f "$target/etc/alpine-release" "$target/etc/debian_version" \
        "$target/usr/bin/dnf" "$target/usr/bin/yum"
    : >"$TEST_LOG"
    unset FAIL_PACKAGE
}
assert_events() {
    local expected=$1
    [ "$(cat "$TEST_LOG")" = "$expected" ] || fail "Unexpected command order: $(cat "$TEST_LOG")"
}

reset_target
touch "$target/etc/debian_version"
po0_install_chrony "$target"
assert_events "repos:$target
apt:$target:chrony
configure:$target"
echo 'PASS: APT target rewrites repos before installing/configuring chrony'

for manager in dnf yum; do
    reset_target
    touch "$target/usr/bin/$manager"
    po0_install_chrony "$target"
    assert_events "repos:$target
chroot:$target $manager -y install chrony
configure:$target"
done
echo 'PASS: DNF and YUM targets use their own package manager before offline configuration'

reset_target
touch "$target/etc/alpine-release"
po0_install_chrony "$target"
assert_events "repos:$target
chroot:$target apk add chrony
configure:$target"
echo 'PASS: Alpine installs chrony instead of selecting a version-dependent NTP default'

reset_target
touch "$target/etc/debian_version"
export FAIL_PACKAGE=1
if po0_install_chrony "$target"; then fail 'package failure was ignored'; fi
if grep -q '^configure:' "$TEST_LOG"; then fail 'configuration ran after package failure'; fi
echo 'PASS: package failure prevents chrony configuration'

reset_target
if (po0_install_chrony "$target") >"$scratch/unsupported.log" 2>&1; then
    fail 'unsupported package manager was silently accepted'
fi
grep -q 'No chrony package integration' "$scratch/unsupported.log" || fail 'missing unsupported-manager diagnostic'

reset_target
mv "$scratch/assets/po0-chrony.sh" "$scratch/assets/po0-chrony.sh.hidden"
if (po0_install_chrony "$target") >"$scratch/missing.log" 2>&1; then
    fail 'missing bundled configuration helper was accepted'
fi
[ ! -s "$TEST_LOG" ] || fail 'missing helper allowed package operations'
echo 'PASS: missing bundle helper stops before package changes'

: >"$TEST_LOG"
sync_time
expected='timeout:30 ntpd -d -n -q -p time1.tencentyun.com -p time2.tencentyun.com -p time3.tencentyun.com -p time4.tencentyun.com -p time5.tencentyun.com'
assert_events "$expected"
echo 'PASS: installer uses bounded internal NTP without public or HTTP-clock fallback'
