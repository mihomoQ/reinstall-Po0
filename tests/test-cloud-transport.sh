#!/bin/sh
# No network or installation actions: actual helpers, mocked transport commands.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/assets" "$scratch/cache"
export MOCK_LOG="$scratch/commands.log" MOCK_PAYLOAD="$scratch/payload" MOCK_MANIFEST="$scratch/manifest"
dd if=/dev/zero of="$MOCK_PAYLOAD" bs=1024 count=1 2>/dev/null
cat >"$scratch/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$MOCK_LOG"
[ "${MOCK_HTTP:-ok}" = ok ] || exit 22
case " $* " in *' -fsSLI '*) exit 0 ;; esac
printf '<a href="image.qcow2">image.qcow2</a>\n'
EOF
cat >"$scratch/bin/rsync" <<'EOF'
#!/bin/sh
echo "rsync $*" >>"$MOCK_LOG"
listing=false
for arg do
    [ "$arg" != --list-only ] || listing=true
    case "$arg" in rsync://*) url=$arg ;; esac
    last=$arg
done
case "$url" in *"${MOCK_FAIL_HOST:-invalid.test}"*) exit 5 ;; esac
filename=${url##*/}
if "$listing"; then
    if [ "${MOCK_DIRECTORY:-0}" = 1 ] || [ "${url%/}" != "$url" ]; then
        printf 'drwxr-xr-x 4,096 2026/01/01 00:00:00 folder\n'
    elif [ "$filename" = image.qcow2 ]; then
        printf 'server banner with number 99999\n-rw-r--r-- 1,024 2026/01/01 00:00:00 image.qcow2\n'
    elif [ "$filename" = "${MOCK_MANIFEST_NAME:-SHA256SUMS}" ] && [ -f "$MOCK_MANIFEST" ]; then
        printf -- '-rw-r--r-- %s 2026/01/01 00:00:00 %s\n' "${MOCK_MANIFEST_SIZE:-1024}" "$filename"
    else
        exit 23
    fi
else
    if [ "$filename" = image.qcow2 ]; then
        printf 'image-fetch %s\n' "$url" >>"$MOCK_LOG"
        cp "$MOCK_PAYLOAD" "$last"
    else
        printf 'manifest-fetch %s\n' "$url" >>"$MOCK_LOG"
        cp "$MOCK_MANIFEST" "$last"
    fi
fi
EOF
chmod +x "$scratch/bin/"*
PATH="$scratch/bin:$PATH"
export PATH PO0_ASSET_DIR="$scratch/assets"
. "$repo/po0-lib.sh"
. "$repo/po0-cloud.sh"
url=http://mirrors.tencentyun.com/ubuntu-cloud-images/releases/noble/release/image.qcow2

: >"$MOCK_LOG"
[ "$(po0_cloud_resolve "$url")" = "$url" ]
! grep -q '^rsync ' "$MOCK_LOG"
echo 'PASS: an available internal image never contacts rsync'

export MOCK_HTTP=missing MOCK_FAIL_HOST=mirror.nju.edu.cn
resolved=$(po0_cloud_resolve "$url")
[ "$resolved" = rsync://rsync.mirrors.ustc.edu.cn/ubuntu-cloud-images/releases/noble/release/image.qcow2 ]
echo 'PASS: unavailable internal image falls through failed campus source to next source'

[ "$(po0_cloud_rsync_size "$resolved")" = 1024 ]
export MOCK_DIRECTORY=1
if po0_cloud_rsync_size "$resolved" >/dev/null; then exit 1; fi
unset MOCK_DIRECTORY
echo 'PASS: file stat ignores banners/commas and rejects directories'

digest=$(sha256sum "$MOCK_PAYLOAD" | cut -d ' ' -f1)
printf '%s  image.qcow2\n' "$digest" >"$MOCK_MANIFEST"
: >"$MOCK_LOG"
[ "$(po0_cloud_probe "$resolved" "$scratch/meta")" = "$resolved" ]
[ "$(po0_cloud_meta_get size "$scratch/meta")" = 1024 ]
[ "$(po0_cloud_meta_get url "$scratch/meta")" = "$resolved" ]
[ "$(po0_cloud_meta_get checksum "$scratch/meta")" = sha256 ]
[ "$(po0_cloud_meta_get sha256 "$scratch/meta")" = "$digest" ]
! grep -q '^image-fetch ' "$MOCK_LOG"
grep -q '^manifest-fetch ' "$MOCK_LOG"
image=$scratch/cache/cloud-image
po0_cloud_fetch "$resolved" "$image"
[ "$(grep -c '^image-fetch ' "$MOCK_LOG")" -eq 1 ]
po0_cloud_verify "$image" "$scratch/meta"
printf x | dd of="$image" bs=1 count=1 conv=notrunc 2>/dev/null
if po0_cloud_verify "$image" "$scratch/meta" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: preparation fetches only a manifest; one image transfer is verified against its SHA256'

printf '%s  other-image.qcow2\n' "$digest" >"$MOCK_MANIFEST"
: >"$MOCK_LOG"
[ "$(po0_cloud_probe "$resolved" "$scratch/no-hash-meta")" = "$resolved" ]
[ "$(po0_cloud_meta_get checksum "$scratch/no-hash-meta")" = unavailable ]
! grep -q '^sha256=' "$scratch/no-hash-meta"
! grep -q '^image-fetch ' "$MOCK_LOG"
po0_cloud_verify "$MOCK_PAYLOAD" "$scratch/no-hash-meta"
printf x >"$scratch/short-image"
if po0_cloud_verify "$scratch/short-image" "$scratch/no-hash-meta" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: missing matching checksum is explicit; exact image size remains mandatory'

export MOCK_MANIFEST_SIZE=1048577
: >"$MOCK_LOG"
po0_cloud_probe "$resolved" "$scratch/large-manifest-meta" >/dev/null
! grep -q '^manifest-fetch ' "$MOCK_LOG"
! grep -q '^image-fetch ' "$MOCK_LOG"
unset MOCK_MANIFEST_SIZE
echo 'PASS: oversized checksum files are never downloaded'

printf '%s  image.qcow2\n' "$digest" >"$MOCK_MANIFEST"
po0_cloud_probe rsync://mirror.nju.edu.cn/ubuntu-cloud-images/image.qcow2 "$scratch/failover-meta" >/dev/null
[ "$(po0_cloud_meta_get url "$scratch/failover-meta")" = rsync://rsync.mirrors.ustc.edu.cn/ubuntu-cloud-images/image.qcow2 ]
echo 'PASS: failed image listing falls through to the next available source'

upper=$(printf '%s' "$digest" | tr 'a-f' 'A-F')
printf 'SHA256 (image[1].qcow2) = %s\n' "$upper" >"$MOCK_MANIFEST"
[ "$(po0_cloud_checksum_parse 'image[1].qcow2' "$MOCK_MANIFEST")" = "$digest" ]
if po0_cloud_checksum_parse image1.qcow2 "$MOCK_MANIFEST" >/dev/null; then exit 1; fi
printf '%s *./image.qcow2\r\n' "$digest" >"$MOCK_MANIFEST"
[ "$(po0_cloud_checksum_parse image.qcow2 "$MOCK_MANIFEST")" = "$digest" ]
printf '%064d  image.qcow2\n' 0 >>"$MOCK_MANIFEST"
status=0
po0_cloud_checksum_parse image.qcow2 "$MOCK_MANIFEST" >/dev/null || status=$?
[ "$status" -eq 2 ]
status=0
po0_cloud_probe "$resolved" "$scratch/conflict-meta" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ]
[ ! -f "$scratch/conflict-meta" ]
printf 'invalid-hash  image.qcow2\n' >"$MOCK_MANIFEST"
status=0
po0_cloud_probe "$resolved" "$scratch/invalid-meta" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ]
[ ! -f "$scratch/invalid-meta" ]
printf 'SHA256 (image.qcow2) = invalid-hash\n' >"$MOCK_MANIFEST"
status=0
po0_cloud_checksum_parse image.qcow2 "$MOCK_MANIFEST" >/dev/null || status=$?
[ "$status" -eq 2 ]
echo 'PASS: exact GNU/BSD malformed or conflicting entries stop preparation instead of dropping checksum verification'

export MOCK_MANIFEST_NAME=image.qcow2.sha256
printf '%s  image.qcow2\n' "$digest" >"$MOCK_MANIFEST"
[ "$(po0_cloud_checksum "$resolved")" = "$digest" ]
unset MOCK_MANIFEST_NAME
printf '\nsha256=invalid\n' >>"$scratch/no-hash-meta"
if po0_cloud_verify "$MOCK_PAYLOAD" "$scratch/no-hash-meta" >/dev/null 2>&1; then exit 1; fi
printf 'sha256=%s\n' "$digest" >>"$scratch/meta"
if po0_cloud_verify "$MOCK_PAYLOAD" "$scratch/meta" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: per-image sidecar works and malformed/duplicate pinned hashes cannot bypass verification'

: >"$MOCK_LOG"
[ "$(po0_rewrite_url https://archive.ubuntu.com/ubuntu/)" = http://mirrors.tencentyun.com/ubuntu/ ]
[ ! -s "$MOCK_LOG" ]
echo 'PASS: software source rewriting has no rsync or network side effects'

listing=$(po0_cloud_text http://mirrors.tencentyun.com/fedora/releases/43/Cloud/x86_64/images/)
case "$listing" in *folder*) ;; *) exit 1 ;; esac
echo 'PASS: cloud directory discovery also falls back over rsync'
