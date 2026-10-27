#!/usr/bin/env bash
# Only isolated functions and fixtures; no live block devices or downloads.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
# mktemp creates the directory; validate its absolute temporary leaf before cleanup.
case "$scratch" in /*/tmp.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/assets" "$scratch/output"
cp "$repo/po0-lib.sh" "$repo/po0-cloud.sh" "$scratch/assets/"
sed '/^: main$/,$d' "$repo/trans.sh" >"$scratch/trans-functions.sh"
export PO0_ASSET_DIR="$scratch/assets"
export PO0_CLOUD_META_FILE="$scratch/image.meta"
export TEST_LOG="$scratch/commands.log"
set +u
. "$scratch/trans-functions.sh"
set -u

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
error_and_exit() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { :; }
apk() { printf 'apk:%s\n' "$*" >>"$TEST_LOG"; }
is_use_cloud_image() { [ "$cloud_image" = 1 ]; }
is_efi() { [ "${EFI:-0}" = 1 ]; }
get_disk_size() { printf '%s\n' "$DISK_BYTES"; }
qemu-img() { printf 'qemu:%s\n' "$*" >>"$TEST_LOG"; }
po0_cloud_rsync_size() {
    printf 'list:%s\n' "$1" >>"$TEST_LOG"
    printf '%s\n' "$REMOTE_BYTES"
}
po0_cloud_fetch() {
    printf 'fetch:%s\n' "$1" >>"$TEST_LOG"
    [ "${FAIL_FETCH:-0}" != 1 ] || return 17
    cp "$FIXTURE_IMAGE" "$2"
}
printf 'QFI\373fixture cloud image contents\n' >"$scratch/plain-image"
gzip -c "$scratch/plain-image" >"$scratch/compressed-image"

reset_case() {
    : >"$TEST_LOG"
    cloud_image=1
    distro=ubuntu
    xda=fixture
    img=rsync://mirror.example/images/cloud.qcow2
    img_type=qemu
    img_type_warp=
    DISK_BYTES=$((20 * 1024 * 1024 * 1024))
    EFI=0
    FAIL_FETCH=0
    FIXTURE_IMAGE="$scratch/plain-image"
    unset po0_cloud_prepared
    write_meta
}
write_meta() {
    local size digest expanded
    size=$(wc -c <"$FIXTURE_IMAGE" | tr -d '[:space:]')
    digest=$(sha256sum "$FIXTURE_IMAGE" | cut -d' ' -f1)
    expanded=$(wc -c <"$scratch/plain-image" | tr -d '[:space:]')
    REMOTE_BYTES=$size
    printf 'url=%s\nsize=%s\nsha256=%s\ntype=qemu%s\nexpanded_size=%s\n' \
        "$img" "$size" "$digest" "${img_type_warp:+.$img_type_warp}" "$expanded" >"$PO0_CLOUD_META_FILE"
}
expect_failure() {
    local reason=$1
    shift
    if ( "$@" ) >"$scratch/failure.log" 2>&1; then
        fail "$reason unexpectedly succeeded"
    fi
}

reset_case
img=http://mirrors.tencentyun.com/almalinux/9/cloud/image.qcow2
po0_prepare_rsync_cloud
[ ! -s "$TEST_LOG" ] || fail 'HTTP image caused rsync/package operations'
echo 'PASS: internal HTTP path bypasses rsync preparation'

reset_case
po0_prepare_rsync_cloud
[ "$po0_cloud_prepared" = "$img" ] || fail 'preparation marker missing'
[ "$(cat "$TEST_LOG")" = "apk:add rsync
list:$img" ] || fail 'package/list ordering changed'
[ "$(get_cloud_image_part_size)" = 150MiB ] || fail 'plain image reservation mismatch'
po0_download_rsync_qcow "$scratch/output/plain.qcow2"
cmp "$scratch/plain-image" "$scratch/output/plain.qcow2"
grep -Fq 'qemu:info ' "$TEST_LOG" || fail 'verified image was not checked by qemu'
echo 'PASS: plain QCOW preparation, actual hash/size verification and staged transfer'

reset_case
saved_url=$img
sed -i 's|^url=.*|url=rsync://other.example/image|' "$PO0_CLOUD_META_FILE"
expect_failure 'mismatched URL' po0_prepare_rsync_cloud
[ ! -s "$TEST_LOG" ] || fail 'URL mismatch reached package or network operation'
reset_case
REMOTE_BYTES=$((REMOTE_BYTES + 1))
expect_failure 'changed remote size' po0_prepare_rsync_cloud
reset_case
sed -i 's/^sha256=.*/sha256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' "$PO0_CLOUD_META_FILE"
expect_failure 'noncanonical hash rejected by shared verifier' po0_prepare_rsync_cloud
[ ! -s "$TEST_LOG" ] || fail 'invalid hash reached package or network operation'
reset_case
rm "$PO0_CLOUD_META_FILE"
expect_failure 'missing metadata' po0_prepare_rsync_cloud
reset_case
img_type=raw
expect_failure 'raw DD rsync' po0_prepare_rsync_cloud
echo 'PASS: stale, missing and unsupported metadata is rejected before partitioning'

reset_case
po0_prepare_rsync_cloud
printf 'tampered image' >"$scratch/bad-image"
FIXTURE_IMAGE="$scratch/bad-image"
: >"$TEST_LOG"
expect_failure 'tampered second-stage image' po0_download_rsync_qcow "$scratch/output/bad.qcow2"
! grep -q '^qemu:' "$TEST_LOG" || fail 'unverified image reached qemu'
echo 'PASS: a changed download never reaches qemu'

reset_case
img_type_warp=gzip
FIXTURE_IMAGE="$scratch/compressed-image"
write_meta
po0_prepare_rsync_cloud
po0_download_rsync_qcow "$scratch/output/expanded.qcow2"
cmp "$scratch/plain-image" "$scratch/output/expanded.qcow2"
[ ! -e "$scratch/output/expanded.qcow2.rsync-compressed" ] || fail 'compressed staging file left after success'
echo 'PASS: compressed image is verified before extraction and checked afterwards'

reset_case
img_type_warp=gzip
FIXTURE_IMAGE="$scratch/compressed-image"
write_meta
po0_prepare_rsync_cloud
po0_cloud_expanded_bytes=$((po0_cloud_expanded_bytes + 1))
: >"$TEST_LOG"
expect_failure 'wrong expanded size' po0_download_rsync_qcow "$scratch/output/wrong-size.qcow2"
! grep -q '^qemu:' "$TEST_LOG" || fail 'wrong expanded size reached qemu'
reset_case
img_type_warp=gzip
FIXTURE_IMAGE="$scratch/plain-image"
write_meta
po0_prepare_rsync_cloud
: >"$TEST_LOG"
expect_failure 'decompression failure' po0_download_rsync_qcow "$scratch/output/not-gzip.qcow2"
! grep -q '^qemu:' "$TEST_LOG" || fail 'broken compressed data reached qemu'
echo 'PASS: decompression and expanded-size errors propagate'

reset_case
img_type_warp=xz
sed -i -e "s/^size=.*/size=$((200 * 1024 * 1024))/" \
    -e 's/^type=.*/type=qemu.xz/' \
    -e "s/^expanded_size=.*/expanded_size=$((900 * 1024 * 1024))/" "$PO0_CLOUD_META_FILE"
REMOTE_BYTES=$((200 * 1024 * 1024))
po0_prepare_rsync_cloud
[ "$(get_cloud_image_part_size)" = 1250MiB ] || fail 'compressed+expanded reservation not included'
DISK_BYTES=$((2 * 1024 * 1024 * 1024))
: >"$TEST_LOG"
expect_failure 'impossible installer partition' po0_prepare_rsync_cloud
[ ! -s "$TEST_LOG" ] || fail 'impossible layout reached package/network operations'
echo 'PASS: both staging files and minimum OS room are reserved before disk changes'

# Execute the real trans dispatch prefix with all side effects replaced. The
# partition operation is an exit sentinel, never a real disk operation.
mod_motd() { :; }
ensure_service_started() { :; }
clear_previous() { :; }
add_community_repo() { :; }
set_max_sectors_kb_for_tencent_cloud_liveos() { :; }
cat() {
    if [ "${1:-}" = /proc/cmdline ]; then echo 'fixture kernel command line';
    else command cat "$@"; fi
}
create_part() {
    [ "${po0_cloud_prepared:-}" = "$img" ] || fail 'partitioning reached before validation'
    echo WOULD_PARTITION >>"$TEST_LOG"
    exit 87
}
reset_case
rm "$PO0_CLOUD_META_FILE"
expect_failure 'trans with missing metadata' trans
! grep -q WOULD_PARTITION "$TEST_LOG" || fail 'trans reached destructive stage after failed preflight'
reset_case
status=0
( trans ) >"$scratch/dispatch.log" 2>&1 || status=$?
[ "$status" -eq 87 ] || fail 'valid preflight did not reach only the mocked partition sentinel'
grep -q WOULD_PARTITION "$TEST_LOG" || fail 'valid dispatch failed to validate and proceed'
echo 'PASS: real trans dispatch validates rsync before reaching partitioning'
