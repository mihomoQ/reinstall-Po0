#!/bin/sh
# No network or installation actions: actual helpers, mocked transport commands.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/assets" "$scratch/cache"
export MOCK_LOG="$scratch/commands.log" MOCK_PAYLOAD="$scratch/payload"
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
if "$listing"; then
    if [ "${MOCK_DIRECTORY:-0}" = 1 ] || [ "${url%/}" != "$url" ]; then
        printf 'drwxr-xr-x 4,096 2026/01/01 00:00:00 folder\n'
    else
        printf 'server banner with number 99999\n-rw-r--r-- 1,024 2026/01/01 00:00:00 image.qcow2\n'
    fi
else
    if [ "${MOCK_FAIL_FETCH_NJU:-0}" = 1 ]; then
        case "$url" in *mirror.nju.edu.cn*) head -c 512 "$MOCK_PAYLOAD" >"$last"; exit 12 ;; esac
    fi
    cp "$MOCK_PAYLOAD" "$last"
fi
EOF
cat >"$scratch/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [ -n "${MOCK_PARTIAL_PATH:-}" ] && [ -s "$MOCK_PARTIAL_PATH" ]; then
    printf 'fixture 999999 0 1 0%% /\n'
    exit 0
fi
printf 'fixture 999999 0 %s 0%% /\n' "${MOCK_FREE:-999999}"
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

image=$(po0_cloud_stage "$resolved" "$scratch/cache" "$scratch/meta")
[ "$image" = "$scratch/cache/cloud-image" ]
[ "$(po0_cloud_meta_get size "$scratch/meta")" = 1024 ]
[ "$(po0_cloud_meta_get url "$scratch/meta")" = "$resolved" ]
po0_cloud_verify "$image" "$scratch/meta"
printf x | dd of="$image" bs=1 count=1 conv=notrunc 2>/dev/null
if po0_cloud_verify "$image" "$scratch/meta" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: staged size and digest pin content; changed content is rejected'

export MOCK_FREE=1
: >"$MOCK_LOG"
if po0_cloud_stage "$resolved" "$scratch/cache" "$scratch/no-space-meta" >/dev/null 2>&1; then exit 1; fi
! grep -q -- '--inplace' "$MOCK_LOG"
[ ! -f "$scratch/no-space-meta" ]
unset MOCK_FREE
echo 'PASS: insufficient staging space stops before full download'

unset MOCK_FAIL_HOST
export MOCK_FAIL_FETCH_NJU=1 MOCK_PARTIAL_PATH="$scratch/failover/cloud-image"
po0_cloud_stage rsync://mirror.nju.edu.cn/ubuntu-cloud-images/image.qcow2 "$scratch/failover" "$scratch/failover-meta" >/dev/null
[ "$(po0_cloud_meta_get url "$scratch/failover-meta")" = rsync://rsync.mirrors.ustc.edu.cn/ubuntu-cloud-images/image.qcow2 ]
unset MOCK_FAIL_FETCH_NJU MOCK_PARTIAL_PATH
echo 'PASS: failed partial transfer does not consume the next mirror space budget'

: >"$MOCK_LOG"
[ "$(po0_rewrite_url https://archive.ubuntu.com/ubuntu/)" = http://mirrors.tencentyun.com/ubuntu/ ]
[ ! -s "$MOCK_LOG" ]
echo 'PASS: software source rewriting has no rsync or network side effects'

listing=$(po0_cloud_text http://mirrors.tencentyun.com/fedora/releases/43/Cloud/x86_64/images/)
case "$listing" in *folder*) ;; *) exit 1 ;; esac
echo 'PASS: cloud directory discovery also falls back over rsync'
