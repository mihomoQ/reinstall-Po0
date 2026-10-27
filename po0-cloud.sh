#!/bin/sh
# Cloud-image transport only. Package repositories never call these fallbacks.
# Source after po0-lib.sh; no network requests are made while sourcing.

po0_need_curl() {
    command -v curl >/dev/null 2>&1 || {
        echo 'The curl client is required for an internal cloud-image source.' >&2
        return 1
    }
}

po0_need_rsync() {
    command -v rsync >/dev/null 2>&1 || {
        echo 'The rsync client is required for this cloud-image source.' >&2
        return 1
    }
}

po0_cloud_candidates() (
    input=$1
    case "$input" in
        *[[:space:]]*) echo 'Whitespace is not supported in a cloud-image URL.' >&2; exit 1 ;;
    esac
    case "$input" in
        http://*|https://*)
            case "$input" in
                https://mirrors.cloud.tencent.com/*|http://mirrors.cloud.tencent.com/*)
                    rest=${input#*://}; input=$PO0_MIRROR_BASE/${rest#*/} ;;
                https://mirrors.openanolis.cn/*|http://mirrors.openanolis.cn/*)
                    rest=${input#*://}; input=$PO0_MIRROR_BASE/${rest#*/} ;;
                https://repo.openeuler.openatom.cn/*|http://repo.openeuler.openatom.cn/*|https://repo.openeuler.org/*|http://repo.openeuler.org/*)
                    rest=${input#*://}; input=$PO0_MIRROR_BASE/openeuler/${rest#*/} ;;
            esac
            first=$(po0_rewrite_url "$input") || exit
            printf '%s\n' "$first"
            case "$first" in
                "$PO0_MIRROR_BASE"/*) path=${first#"$PO0_MIRROR_BASE"/} ;;
                *) exit 0 ;;
            esac ;;
        rsync://*)
            first=$input
            printf '%s\n' "$first"
            rest=${input#rsync://}; host=${rest%%/*}; path=${rest#*/}
            case "$host" in
                mirror.nju.edu.cn|rsync.mirrors.ustc.edu.cn|mirrors.tuna.tsinghua.edu.cn) ;;
                cloud-images.ubuntu.com)
                    case "$path" in cloud-images/*) path=ubuntu-cloud-images/${path#cloud-images/} ;; *) exit 0 ;; esac ;;
                *) exit 0 ;;
            esac ;;
        *) printf '%s\n' "$input"; exit 0 ;;
    esac
    # Bundle-maintained daemon endpoints. MirrorZ's HTTP 302 service is not a
    # rsync redirector, so it is intentionally not a runtime dependency.
    for base in rsync://mirror.nju.edu.cn rsync://rsync.mirrors.ustc.edu.cn rsync://mirrors.tuna.tsinghua.edu.cn; do
        candidate=$base/$path
        [ "$candidate" = "$first" ] || printf '%s\n' "$candidate"
    done
    case "$path" in
        ubuntu-cloud-images/*)
            candidate=rsync://cloud-images.ubuntu.com/cloud-images/${path#ubuntu-cloud-images/}
            [ "$candidate" = "$first" ] || printf '%s\n' "$candidate" ;;
    esac
)

po0_cloud_rsync_size() (
    po0_need_rsync >&2 || exit
    listing=$(LC_ALL=C command rsync -4 -L --no-motd --list-only --contimeout=5 --timeout=10 -- "$1") || exit
    # A single explicit file, not a module/directory. Ignore banners and reject
    # multiple matches. Human-readable rsync sizes can contain thousands commas.
    printf '%s\n' "$listing" | awk '
        /^-/ && $2 ~ /^[0-9,]+$/ {gsub(/,/, "", $2); value=$2; count++}
        END {if (count == 1 && value > 0) print value; else exit 1}'
)

po0_cloud_resolve() (
    candidates=$(po0_cloud_candidates "$1") || exit
    for candidate in $candidates; do
        echo "Cloud image source: $candidate" >&2
        case "$candidate" in
            http://*|https://*)
                po0_need_curl >&2 || exit
                if command curl -fsSLI --connect-timeout 5 --max-time 12 "$candidate" >/dev/null; then
                    printf '%s\n' "$candidate"; exit 0
                fi ;;
            rsync://*)
                if po0_cloud_rsync_size "$candidate" >/dev/null; then
                    printf '%s\n' "$candidate"; exit 0
                fi ;;
            *) echo "Unsupported cloud-image URL: $candidate" >&2 ;;
        esac
    done
    echo 'No available internal/rsync copy of this cloud image.' >&2
    exit 1
)

po0_cloud_fetch() {
    case "$1" in
        rsync://*)
            po0_need_rsync >&2 || return
            # In-place avoids a second complete temporary copy on the installer
            # partition. A failed transfer is never accepted without verification.
            command rsync -4 -tL --no-motd --partial --inplace --ignore-times \
                --contimeout=5 --timeout=30 --info=progress2 -- "$1" "$2" >&2 ;;
        http://*|https://*)
            po0_need_curl >&2 || return
            command curl -fL --connect-timeout 5 --retry 2 -o "$2" "$1" ;;
        *) echo "Unsupported cloud-image transfer: $1" >&2; return 1 ;;
    esac
}

po0_cloud_meta_get() (
    case "$1" in url|size|sha256|expanded_size|type) ;; *) exit 1 ;; esac
    [ -f "$2" ] || exit 1
    value=$(sed -n "s/^$1=//p" "$2")
    [ -n "$value" ] || exit 1
    [ "$(printf '%s\n' "$value" | wc -l)" -eq 1 ] || exit 1
    printf '%s\n' "$value"
)

po0_cloud_stage() (
    requested=$1; cache=$2; metadata=$3
    mkdir -p "$cache"
    # Canonicalize for use after the caller changes its working directory.
    cache=$(cd "$cache" && pwd)
    destination=$cache/cloud-image
    candidates=$(po0_cloud_candidates "$requested") || exit
    for source in $candidates; do
        case "$source" in rsync://*) ;; *) continue ;; esac
        size=$(po0_cloud_rsync_size "$source") || continue
        available=$(df -Pk "$cache" | awk 'NR == 2 {print $4}')
        case "$available" in ''|*[!0-9]*) echo 'Cannot determine cloud staging space.' >&2; exit 1 ;; esac
        needed=$(((size + 1023) / 1024 + 65536))
        if [ "$available" -lt "$needed" ]; then
            echo "Insufficient host space for rsync image staging ($size bytes plus reserve)." >&2
            exit 1
        fi
        echo "Staging full rsync image before boot: $source ($size bytes)" >&2
        if ! po0_cloud_fetch "$source" "$destination"; then
            # A failed source must not consume the free-space budget checked
            # for the next mirror. Do not mix a partial from another source.
            rm -f "$destination"
            continue
        fi
        actual=$(wc -c <"$destination")
        [ "$actual" -eq "$size" ] || {
            echo 'Staged image size changed; trying another source.' >&2
            rm -f "$destination"
            continue
        }
        digest=$(sha256sum "$destination") || exit 1
        digest=${digest%% *}
        case "$digest" in ''|*[!0-9a-f]*) echo 'Failed to hash staged cloud image.' >&2; exit 1 ;; esac
        [ "${#digest}" -eq 64 ] || exit 1
        printf 'url=%s\nsize=%s\nsha256=%s\n' "$source" "$size" "$digest" >"$metadata"
        printf '%s\n' "$destination"
        exit 0
    done
    echo 'Failed to stage a complete rsync cloud image before boot.' >&2
    exit 1
)

po0_cloud_verify() (
    image=$1; metadata=$2
    size=$(po0_cloud_meta_get size "$metadata") || exit
    digest=$(po0_cloud_meta_get sha256 "$metadata") || exit
    case "$size" in ''|*[!0-9]*) echo 'Invalid pinned image size.' >&2; exit 1 ;; esac
    case "$digest" in *[!0-9a-f]*|'') echo 'Invalid pinned image digest.' >&2; exit 1 ;; esac
    [ "${#digest}" -eq 64 ] || exit 1
    [ -f "$image" ] && [ "$(wc -c <"$image")" -eq "$size" ] || {
        echo 'Cloud image size differs from the preboot copy.' >&2; exit 1
    }
    actual=$(sha256sum "$image" | cut -d ' ' -f1)
    [ "$actual" = "$digest" ] || {
        echo 'Cloud image content changed since preparation; refusing to use it.' >&2; exit 1
    }
)

po0_cloud_text() (
    # Directory/index discovery for variable-name cloud images only.
    candidates=$(po0_cloud_candidates "$1") || exit
    scratch=$(mktemp -d) || exit
    trap 'rm -rf "$scratch"' EXIT HUP INT TERM
    for source in $candidates; do
        case "$source" in
            http://*|https://*)
                po0_need_curl >&2 || exit
                if command curl -fsSL --connect-timeout 5 --max-time 15 --max-filesize 1048576 "$source" >"$scratch/text"; then
                    cat "$scratch/text"; exit 0
                fi ;;
            rsync://*)
                po0_need_rsync >&2 || exit
                case "$source" in
                    */)
                        if command rsync -4 -L --no-motd --list-only --contimeout=5 --timeout=10 -- "$source" >"$scratch/text"; then
                            # Existing filename selectors can consume plain listings.
                            cat "$scratch/text"; exit 0
                        fi ;;
                    *)
                        size=$(po0_cloud_rsync_size "$source") || continue
                        [ "$size" -le 1048576 ] || continue
                        if po0_cloud_fetch "$source" "$scratch/text"; then cat "$scratch/text"; exit 0; fi ;;
                esac ;;
        esac
    done
    echo "No usable cloud-image directory/index: $1" >&2
    exit 1
)
