#!/usr/bin/env bash
# Only isolated functions and fixtures; no live block devices or downloads.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
case "$scratch" in /*/tmp.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/assets" "$scratch/output" "$scratch/ram-cache"
cp "$repo/po0-lib.sh" "$repo/po0-cloud.sh" "$scratch/assets/"
sed '/^: main$/,$d' "$repo/trans.sh" >"$scratch/trans-functions.sh"
export PO0_ASSET_DIR="$scratch/assets" PO0_CLOUD_META_FILE="$scratch/image.meta"
export PO0_CLOUD_CACHE_DIR="$scratch/ram-cache" TEST_LOG="$scratch/commands.log"
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
po0_cloud_memory_kb() { printf '%s\n' "$MEMORY_KB"; }
qemu-img() {
    printf 'qemu:%s\n' "$*" >>"$TEST_LOG"
    [ "$2" = -f ] && [ "$3" = qcow2 ] || fail 'qemu did not force QCOW2'
    case "$1" in
    info)
        [ "$4" = --output=json ] || fail 'qemu info did not use JSON'
        [ "$FAIL_QEMU_INFO" = 0 ] || return 18
        printf '%s\n' "$QEMU_INFO" ;;
    check) [ "$FAIL_QEMU_CHECK" = 0 ] || return 19 ;;
    *) fail 'unexpected qemu operation' ;;
    esac
}
po0_cloud_rsync_size() { printf 'list:%s\n' "$1" >>"$TEST_LOG"; printf '%s\n' "$REMOTE_BYTES"; }
po0_cloud_http_size() { printf 'head:%s\n' "$1" >>"$TEST_LOG"; printf '%s\n' "$REMOTE_BYTES"; }
po0_cloud_fetch() {
    printf 'fetch:%s\n' "$1" >>"$TEST_LOG"
    [ "$FAIL_FETCH" = 0 ] || return 17
    cp "$FIXTURE_IMAGE" "$2"
}
printf 'QFI\373fixture cloud image contents\n' >"$scratch/plain-image"
gzip -c "$scratch/plain-image" >"$scratch/compressed-image"
printf 'not a qcow image' | gzip -c >"$scratch/non-qcow-image.gz"
head -c 20 "$scratch/compressed-image" >"$scratch/truncated-image.gz"
reset_case() {
    : >"$TEST_LOG"
    cloud_image=1 distro=ubuntu xda=fixture
    img=rsync://mirror.example/images/cloud.qcow2
    img_type=qemu img_type_warp=
    DISK_BYTES=$((20 * 1024 * 1024 * 1024)) MEMORY_KB=$((2 * 1024 * 1024))
    EFI=0 FAIL_FETCH=0 FAIL_QEMU_INFO=0 FAIL_QEMU_CHECK=0
    QEMU_INFO='{"format":"qcow2"}'
    FIXTURE_IMAGE="$scratch/plain-image"
    unset po0_cloud_prepared
    rm -f "$PO0_CLOUD_CACHE_DIR"/image.*
    write_meta
}
write_meta() {
    local size digest
    size=$(wc -c <"$FIXTURE_IMAGE" | tr -d '[:space:]')
    digest=$(sha256sum "$FIXTURE_IMAGE" | cut -d' ' -f1)
    REMOTE_BYTES=$size
    printf 'url=%s\nsize=%s\nchecksum=sha256\nsha256=%s\ntype=qemu%s\n' \
        "$img" "$size" "$digest" "${img_type_warp:+.$img_type_warp}" >"$PO0_CLOUD_META_FILE"
}
compressed_case() { reset_case; img_type_warp=gzip; FIXTURE_IMAGE="$scratch/compressed-image"; write_meta; }
expect_failure() {
    local reason=$1
    shift
    if ( "$@" ) >"$scratch/failure.log" 2>&1; then fail "$reason unexpectedly succeeded"; fi
}
assert_one_fetch() { [ "$(grep -c '^fetch:' "$TEST_LOG")" = 1 ] || fail 'image not downloaded exactly once'; }
assert_no_fetch() { ! grep -q '^fetch:' "$TEST_LOG" || fail 'unexpected image download'; }

reset_case
img=http://mirrors.tencentyun.com/almalinux/9/cloud/image.qcow2
write_meta
po0_prepare_rsync_cloud
assert_no_fetch
[ "$po0_cloud_prepared" = "$img" ] || fail 'HTTP metadata not checked'
! grep -q '^list:\|apk:add rsync' "$TEST_LOG" || fail 'HTTP used rsync'
po0_download_rsync_qcow "$scratch/output/http.qcow2"
assert_one_fetch
grep -Fq 'qemu:check -f qcow2 ' "$TEST_LOG" || fail 'HTTP image skipped QCOW validation'
echo 'PASS: internal HTTP path uses shared preparation and full validation'
reset_case
po0_prepare_rsync_cloud
[ "$po0_cloud_prepared" = "$img" ] || fail 'preparation marker missing'
[ "$(cat "$TEST_LOG")" = "apk:add rsync
list:$img" ] || fail 'package/list ordering changed'
[ "$(get_cloud_image_part_size)" = 150MiB ] || fail 'plain image reservation mismatch'
assert_no_fetch
po0_download_rsync_qcow "$scratch/output/plain.qcow2"
assert_one_fetch
cmp "$scratch/plain-image" "$scratch/output/plain.qcow2"
grep -Fq 'qemu:check -f qcow2 ' "$TEST_LOG" || fail 'QCOW structure not checked'
echo 'PASS: plain QCOW downloads once and verifies size, hash, format and structure'
reset_case
sed -i -e '/^sha256=/d' -e 's/^checksum=.*/checksum=unavailable/' "$PO0_CLOUD_META_FILE"
po0_prepare_rsync_cloud
po0_download_rsync_qcow "$scratch/output/no-sha.qcow2"
assert_one_fetch
grep -Fq 'qemu:check -f qcow2 ' "$TEST_LOG" || fail 'optional SHA bypassed QCOW checks'
echo 'PASS: unavailable publisher checksum retains size and QCOW validation'

reset_case
sed -i 's|^url=.*|url=rsync://other.example/image|' "$PO0_CLOUD_META_FILE"
expect_failure 'mismatched URL' po0_prepare_rsync_cloud
[ ! -s "$TEST_LOG" ] || fail 'URL mismatch reached network'
reset_case
REMOTE_BYTES=$((REMOTE_BYTES + 1))
expect_failure 'changed remote size' po0_prepare_rsync_cloud
reset_case
sed -i 's/^sha256=.*/sha256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' "$PO0_CLOUD_META_FILE"
expect_failure 'noncanonical hash' po0_prepare_rsync_cloud
[ ! -s "$TEST_LOG" ] || fail 'invalid hash reached network'
reset_case
sed -i 's/^checksum=.*/checksum=unavailable/' "$PO0_CLOUD_META_FILE"
expect_failure 'conflicting checksum mode' po0_prepare_rsync_cloud
reset_case
rm "$PO0_CLOUD_META_FILE"
expect_failure 'missing metadata' po0_prepare_rsync_cloud
reset_case
img_type=raw
expect_failure 'raw DD rsync' po0_prepare_rsync_cloud
echo 'PASS: stale, missing and unsupported metadata rejected before partitioning'

reset_case
po0_prepare_rsync_cloud
printf 'tampered image' >"$scratch/bad-image"
FIXTURE_IMAGE="$scratch/bad-image"
: >"$TEST_LOG"
expect_failure 'tampered image' po0_download_rsync_qcow "$scratch/output/bad.qcow2"
! grep -q '^qemu:' "$TEST_LOG" || fail 'unverified image reached qemu'
reset_case
po0_prepare_rsync_cloud
FAIL_QEMU_INFO=1
expect_failure 'invalid QCOW format' po0_download_rsync_qcow "$scratch/output/raw.qcow2"
! grep -q '^qemu:check ' "$TEST_LOG" || fail 'invalid format reached check'
for property in backing-filename full-backing-filename data-file; do
    reset_case
    po0_prepare_rsync_cloud
    QEMU_INFO="{\"format\":\"qcow2\",\"$property\":\"external-file\"}"
    expect_failure "external $property" po0_download_rsync_qcow "$scratch/output/external.qcow2"
    ! grep -q '^qemu:check ' "$TEST_LOG" || fail 'external dependency reached check'
done
reset_case
po0_prepare_rsync_cloud
FAIL_QEMU_CHECK=1
expect_failure 'QCOW structural corruption' po0_download_rsync_qcow "$scratch/output/corrupt.qcow2"
echo 'PASS: changed bytes, wrong format, external files and corrupt QCOW rejected'

compressed_case
po0_prepare_rsync_cloud
assert_one_fetch
[ "$po0_cloud_expanded_bytes" = "$(wc -c <"$scratch/plain-image" | tr -d '[:space:]')" ] || fail 'expanded size guessed'
[ "$(get_cloud_image_part_size)" = 150MiB ] || fail 'expanded reservation mismatch'
cached=$po0_cloud_ram_cache
[ -f "$cached" ] || fail 'compressed cache missing'
po0_download_rsync_qcow "$scratch/output/expanded.qcow2"
assert_one_fetch
cmp "$scratch/plain-image" "$scratch/output/expanded.qcow2"
[ ! -e "$cached" ] || fail 'RAM cache not released'
echo 'PASS: compressed image downloads once before partitioning, expands from RAM'
compressed_case
MEMORY_KB=$((512 * 1024))
expect_failure 'insufficient RAM' po0_prepare_rsync_cloud
assert_no_fetch
compressed_case
FAIL_FETCH=1
expect_failure 'compressed transfer failure' po0_prepare_rsync_cloud
[ -z "$(ls -A "$PO0_CLOUD_CACHE_DIR")" ] || fail 'failed transfer left RAM cache'
compressed_case
sed -i 's/^sha256=.*/sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$PO0_CLOUD_META_FILE"
expect_failure 'compressed hash failure' po0_prepare_rsync_cloud
[ -z "$(ls -A "$PO0_CLOUD_CACHE_DIR")" ] || fail 'failed hash left RAM cache'
for fixture in truncated-image.gz non-qcow-image.gz; do
    compressed_case
    FIXTURE_IMAGE="$scratch/$fixture"
    write_meta
    expect_failure "invalid $fixture" po0_prepare_rsync_cloud
    [ -z "$(ls -A "$PO0_CLOUD_CACHE_DIR")" ] || fail 'bad stream left RAM cache'
done
echo 'PASS: low RAM stops before fetching; transfer/hash/decompression failures release RAM'
compressed_case
po0_prepare_rsync_cloud
po0_cloud_expanded_bytes=$((po0_cloud_expanded_bytes + 1))
expect_failure 'wrong expanded size' po0_download_rsync_qcow "$scratch/output/wrong-size.qcow2"
assert_one_fetch
! grep -q '^qemu:' "$TEST_LOG" || fail 'wrong expanded size reached qemu'
compressed_case
po0_prepare_rsync_cloud
rm "$po0_cloud_ram_cache"
expect_failure 'missing RAM cache' po0_download_rsync_qcow "$scratch/output/missing-cache.qcow2"
assert_one_fetch
echo 'PASS: cache loss and expanded-size mismatch never trigger second download'
reset_case
DISK_BYTES=$((1024 * 1024 * 1024))
expect_failure 'impossible plain partition' po0_prepare_rsync_cloud
assert_no_fetch
compressed_case
DISK_BYTES=$((1024 * 1024 * 1024))
expect_failure 'impossible compressed partition' po0_prepare_rsync_cloud
[ -z "$(ls -A "$PO0_CLOUD_CACHE_DIR")" ] || fail 'disk rejection left RAM cache'
echo 'PASS: image, boot and minimum OS space must fit before partitioning'

for damage in checksum format backing; do
    reset_case
    img=http://mirror.example/cloud.qcow2
    write_meta
    po0_prepare_rsync_cloud
    case "$damage" in
    checksum) printf 'damaged bytes' >"$scratch/damaged-http"; FIXTURE_IMAGE="$scratch/damaged-http" ;;
    format) FAIL_QEMU_INFO=1 ;;
    backing) QEMU_INFO='{"backing-filename":"external.qcow2"}' ;;
    esac
    expect_failure "HTTP $damage" po0_download_rsync_qcow "$scratch/output/http-$damage.qcow2"
done
compressed_case
img=http://mirror.example/cloud.qcow2.gz
write_meta
po0_prepare_rsync_cloud
assert_one_fetch
po0_download_rsync_qcow "$scratch/output/http-expanded.qcow2"
assert_one_fetch
cmp "$scratch/plain-image" "$scratch/output/http-expanded.qcow2"
compressed_case
img=http://mirror.example/cloud.qcow2.gz
write_meta
FAIL_FETCH=1
expect_failure 'HTTP compressed transfer failure' po0_prepare_rsync_cloud
[ -z "$(ls -A "$PO0_CLOUD_CACHE_DIR")" ] || fail 'HTTP transfer failure left cache'
compressed_case
img=http://mirror.example/cloud.qcow2.gz
write_meta
sed -i 's/^size=.*/size=unknown/' "$PO0_CLOUD_META_FILE"
expect_failure 'compressed HTTP without Content-Length' po0_prepare_rsync_cloud
assert_no_fetch
reset_case
img=http://mirror.example/cloud.qcow2
write_meta
sed -i 's/^size=.*/size=unknown/' "$PO0_CLOUD_META_FILE"
REMOTE_BYTES=unknown
po0_prepare_rsync_cloud
[ "$(get_cloud_image_part_size)" = 2048MiB ] || fail 'unknown HTTP size reservation changed'
po0_download_rsync_qcow "$scratch/output/http-unknown.qcow2"
assert_one_fetch
echo 'PASS: HTTP rejects bad hashes/format/dependencies and compressed failures; both formats transfer once'

# Real dispatch prefix with a sentinel instead of actual partition operations.
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
    [ "${po0_cloud_prepared:-}" = "$img" ] || fail 'partitioning before validation'
    echo WOULD_PARTITION >>"$TEST_LOG"
    exit 87
}
assert_dispatch_stops() {
    expect_failure "$1" trans
    ! grep -q WOULD_PARTITION "$TEST_LOG" || fail 'failure reached partitioning'
}
reset_case
rm "$PO0_CLOUD_META_FILE"
assert_dispatch_stops 'missing metadata'
compressed_case
MEMORY_KB=1
assert_dispatch_stops 'insufficient RAM'
compressed_case
FIXTURE_IMAGE="$scratch/truncated-image.gz"
write_meta
assert_dispatch_stops 'decompression failure'
compressed_case
sed -i 's/^sha256=.*/sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$PO0_CLOUD_META_FILE"
assert_dispatch_stops 'checksum failure'
compressed_case
DISK_BYTES=$((1024 * 1024 * 1024))
assert_dispatch_stops 'insufficient disk'
for mode in plain compressed; do
    if [ "$mode" = compressed ]; then compressed_case; else reset_case; fi
    status=0
    ( trans ) >"$scratch/dispatch.log" 2>&1 || status=$?
    [ "$status" -eq 87 ] || fail 'valid dispatch did not reach sentinel'
    grep -q WOULD_PARTITION "$TEST_LOG" || fail 'valid dispatch did not proceed'
    if [ "$mode" = compressed ]; then assert_one_fetch; else assert_no_fetch; fi
done
echo 'PASS: real dispatch rejects metadata/RAM/hash/archive/disk failures before partitioning'

# Conditional callers disable shell errexit. A failed download must explicitly
# return before any install action even in this calling context.
create_part() { echo WOULD_PARTITION >>"$TEST_LOG"; }
download_qcow() { return 73; }
install_qcow_by_copy() { echo WOULD_INSTALL >>"$TEST_LOG"; exit 88; }
reset_case
status=0
( trans ) >"$scratch/download-failure.log" 2>&1 || status=$?
[ "$status" -eq 73 ] || fail 'download failure did not propagate from trans'
! grep -q WOULD_INSTALL "$TEST_LOG" || fail 'download failure reached installation'
echo 'PASS: download failure blocks installation even when errexit is disabled'

# A manual `/trans.sh alpine` keeps the original kernel command line's img URL.
# Only that explicit rescue target may bypass obsolete cloud metadata; raw/DD
# rsync must still fail instead of reaching a disk-writing path.
install_alpine() { echo WOULD_INSTALL_ALPINE >>"$TEST_LOG"; exit 89; }
reset_case
distro=alpine
cloud_image=0
rm "$PO0_CLOUD_META_FILE"
status=0
( trans ) >"$scratch/alpine-rescue.log" 2>&1 || status=$?
[ "$status" -eq 89 ] || fail 'Alpine rescue was blocked by obsolete rsync image state'
grep -q WOULD_INSTALL_ALPINE "$TEST_LOG" || fail 'Alpine rescue dispatch missing'
assert_no_fetch
! grep -q '^list:\|^head:\|apk:add rsync\|apk:add curl\|WOULD_PARTITION' "$TEST_LOG" || fail 'Alpine rescue touched obsolete cloud state'
reset_case
distro=dd
cloud_image=0
img_type=raw
expect_failure 'raw DD rsync remains rejected' trans
! grep -q 'WOULD_PARTITION\|WOULD_INSTALL' "$TEST_LOG" || fail 'raw DD rsync reached disk operations'
echo 'PASS: explicit Alpine rescue ignores stale cloud state; raw DD rsync stays blocked'
