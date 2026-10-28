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

po0_cloud_http_size() (
    po0_need_curl >&2 || exit
    headers=$(command curl -fsSLI --connect-timeout 5 --max-time 12 "$1") || exit
    # Only the final response's Content-Length describes the selected object.
    printf '%s\n' "$headers" | tr -d '\r' | awk '
        /^HTTP\// {size="unknown"}
        tolower($1) == "content-length:" {size=$2}
        END {
            if (size == "" || size == "unknown") print "unknown"
            else if (size ~ /^[0-9]+$/ && size > 0) {sub(/^0+/, "", size); print size}
            else exit 1
        }'
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
    case "$1" in url|size|sha256|checksum|expanded_size|type) ;; *) exit 1 ;; esac
    [ -f "$2" ] || exit 1
    value=$(sed -n "s/^$1=//p" "$2")
    [ -n "$value" ] || exit 1
    [ "$(printf '%s\n' "$value" | wc -l)" -eq 1 ] || exit 1
    printf '%s\n' "$value"
)

po0_cloud_checksum_parse() (
    # Accept GNU sha256sum and BSD/Fedora SHA256 forms. Match the complete
    # basename literally, never a substring or a caller-supplied regex.
    awk -v wanted="$1" '
        function save(hash, name) {
            sub(/^\*/, "", name); sub(/^\.\//, "", name)
            if (name != wanted) return
            if (length(hash) != 64 || hash ~ /[^0-9a-fA-F]/) {invalid=1; return}
            hash=tolower(hash)
            if (found && result != hash) conflict=1
            result=hash; found=1
        }
        {
            sub(/\r$/, "")
            if ($0 ~ /^SHA256 \(/) {
                prefix="SHA256 (" wanted ")"
                if (index($0, prefix) == 1) {
                    tail=substr($0, length(prefix) + 1)
                    if (substr(tail, 1, 3) != " = ") invalid=1
                    else save(substr(tail, 4), wanted)
                }
            } else {
                hash=$1; name=$0; sub(/^[^[:space:]]+[[:space:]]+/, "", name)
                save(hash, name)
            }
        }
        END {
            if (invalid || conflict) exit 2
            if (found) print result; else exit 1
        }' "$2"
)

po0_cloud_checksum() (
    source=$1
    directory=${source%/*}; filename=${source##*/}
    scratch=$(mktemp -d) || exit
    trap 'rm -rf "$scratch"' EXIT HUP INT TERM
    fedora=$(printf '%s\n' "$filename" | sed -n -E \
        's/^Fedora-Cloud-Base-Generic-(.+)\.(x86_64|aarch64)\.qcow2$/Fedora-Cloud-\1-\2-CHECKSUM/p')
    for manifest in SHA256SUMS "$filename.sha256" "$filename.sha256sum" "$filename.CHECKSUM" CHECKSUM $fedora; do
        manifest_url=$directory/$manifest
        # Even an unusual image filename cannot make this fetch the image.
        [ "$manifest_url" != "$source" ] || continue
        rm -f "$scratch/manifest"
        case "$manifest_url" in
        rsync://*)
            size=$(po0_cloud_rsync_size "$manifest_url" 2>/dev/null) || continue
            [ "$size" -le 1048576 ] || continue
            if ! command rsync -4 -L --no-motd --max-size=1048576 --contimeout=5 --timeout=10 \
                -- "$manifest_url" "$scratch/manifest" >/dev/null 2>&1; then continue; fi
            ;;
        http://*|https://*)
            # Bound received bytes even on older curl versions when the server
            # omits Content-Length. Preserve curl failures across the pipe.
            po0_need_curl >&2 || exit
            {
                if command curl -fsSL --connect-timeout 5 --max-time 15 --max-filesize 1048576 "$manifest_url" 2>/dev/null; then
                    echo 0 >"$scratch/status"
                else echo 1 >"$scratch/status"; fi
            } | head -c 1048577 >"$scratch/manifest"
            [ "$(cat "$scratch/status")" = 0 ] || continue
            ;;
        *) exit 1 ;;
        esac
        [ -f "$scratch/manifest" ] || continue
        [ "$(wc -c <"$scratch/manifest")" -le 1048576 ] || continue
        if digest=$(po0_cloud_checksum_parse "$filename" "$scratch/manifest"); then
            printf '%s\n' "$digest"
            exit 0
        else
            status=$?
            if [ "$status" -eq 2 ]; then
                echo "Invalid or conflicting SHA256 entry for $filename in $manifest_url" >&2
                exit 2
            fi
        fi
    done
    exit 1
)

po0_cloud_probe() (
    requested=$1; metadata=$2
    # Preparation only lists the image and downloads bounded checksum text.
    # The image payload is transferred once, by the installation environment.
    rm -f "$metadata"
    candidates=$(po0_cloud_candidates "$requested") || exit
    for source in $candidates; do
        echo "Cloud image source: $source" >&2
        case "$source" in
        rsync://*) size=$(po0_cloud_rsync_size "$source") || continue ;;
        http://*|https://*) size=$(po0_cloud_http_size "$source") || continue ;;
        *) continue ;;
        esac
        printf 'url=%s\nsize=%s\n' "$source" "$size" >"$metadata" || exit
        if digest=$(po0_cloud_checksum "$source"); then
            printf 'checksum=sha256\nsha256=%s\n' "$digest" >>"$metadata" || exit
        else
            status=$?
            if [ "$status" -eq 2 ]; then
                rm -f "$metadata"
                echo 'Refusing cloud image preparation with an invalid matching SHA256 manifest.' >&2
                exit 2
            fi
            echo 'No matching SHA256 manifest; installation will check transfer, size and QCOW2 structure.' >&2
            printf 'checksum=unavailable\n' >>"$metadata" || exit
        fi
        printf '%s\n' "$source"
        exit 0
    done
    echo 'No available internal/rsync cloud image to prepare.' >&2
    exit 1
)

po0_cloud_verify() (
    image=$1; metadata=$2
    size=$(po0_cloud_meta_get size "$metadata") || exit
    [ -f "$image" ] && [ -s "$image" ] || exit 1
    case "$size" in
    unknown)
        source=$(po0_cloud_meta_get url "$metadata") || exit
        case "$source" in http://*|https://*) ;; *) exit 1 ;; esac
        echo 'No HTTP Content-Length was available; checking checksum and QCOW2 structure.' >&2
        ;;
    ''|*[!0-9]*) echo 'Invalid pinned image size.' >&2; exit 1 ;;
    *)
        [ "$size" -gt 0 ] || exit 1
        [ "$(wc -c <"$image")" -eq "$size" ] || {
            echo 'Cloud image size differs from the prepared listing.' >&2; exit 1
        } ;;
    esac
    # Absence is allowed; malformed or duplicate SHA256 entries are not.
    if ! grep -q '^sha256=' "$metadata"; then
        if [ "$(po0_cloud_meta_get checksum "$metadata" 2>/dev/null)" = sha256 ]; then
            echo 'Missing required SHA256 digest.' >&2; exit 1
        fi
        echo 'No SHA256 manifest was available; transfer and QCOW2 checks remain required.' >&2
        exit 0
    fi
    digest=$(po0_cloud_meta_get sha256 "$metadata") || exit
    case "$digest" in *[!0-9a-f]*|'') echo 'Invalid pinned image digest.' >&2; exit 1 ;; esac
    [ "${#digest}" -eq 64 ] || exit 1
    actual=$(sha256sum "$image" | cut -d ' ' -f1)
    [ "$actual" = "$digest" ] || {
        echo 'Cloud image does not match the prepared SHA256 manifest.' >&2; exit 1
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
