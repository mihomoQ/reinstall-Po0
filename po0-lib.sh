#!/bin/sh
# Shared Po0 resource handling. Sourcing this file never probes the network.
# shellcheck shell=dash

: "${PO0_ASSET_DIR:=/po0-assets}"
if [ -f "$PO0_ASSET_DIR/po0.conf" ]; then
    # Operator-controlled configuration shipped with this bundle.
    # shellcheck source=/dev/null
    . "$PO0_ASSET_DIR/po0.conf"
fi
: "${PO0_MIRROR_BASE:=http://mirrors.tencentyun.com}"
PO0_MIRROR_BASE=${PO0_MIRROR_BASE%/}
case "$PO0_MIRROR_BASE" in
    http://*) ;;
    *) echo 'PO0_MIRROR_BASE must be an HTTP origin; installer package-source paths use HTTP.' >&2; return 1 ;;
esac
PO0_MIRROR_HOST=${PO0_MIRROR_BASE#*://}
case "$PO0_MIRROR_HOST" in
    ''|*[!A-Za-z0-9.:-]*)
        echo 'PO0_MIRROR_BASE must contain only a host and optional port, without a path or credentials.' >&2
        return 1 ;;
esac
export PO0_MIRROR_BASE PO0_MIRROR_HOST

po0_copy_asset() (
    # A subshell keeps helper variables out of the caller's installer state.
    case "$1" in
        ''|/*|*..*|*\\*) echo "Invalid bundled asset name: $1" >&2; exit 1 ;;
    esac
    [ -s "$PO0_ASSET_DIR/$1" ] || {
        echo "Missing Po0 bundle asset: $1. Extract the complete release bundle." >&2
        exit 1
    }
    if [ "$2" = - ]; then
        cat "$PO0_ASSET_DIR/$1"
    else
        cp "$PO0_ASSET_DIR/$1" "$2"
    fi
)

po0_rewrite_url() (
    _po0_url=$1
    # User mappings are literal prefixes, never shell expressions or regexes.
    # A space or tab separates the old and new prefix; first match wins.
    if [ -f "$PO0_ASSET_DIR/po0-mirrors.conf" ]; then
        while read -r _po0_from _po0_to _po0_extra || [ -n "$_po0_from$_po0_to$_po0_extra" ]; do
            case "$_po0_from" in ''|\#*) continue ;; esac
            case "$_po0_to" in http://*|https://*) ;; *)
                echo 'Invalid target URL in po0-mirrors.conf' >&2; exit 1 ;; esac
            [ -z "$_po0_extra" ] || {
                echo 'Expected two URL prefixes per po0-mirrors.conf line.' >&2; exit 1
            }
            case "$_po0_url" in
                "$_po0_from"*) printf '%s%s\n' "$_po0_to" "${_po0_url#"$_po0_from"}"; exit 0 ;;
            esac
        done <"$PO0_ASSET_DIR/po0-mirrors.conf"
    fi
    case "$_po0_url" in http://*|https://*) ;; *) printf '%s\n' "$_po0_url"; exit 0 ;; esac
    _po0_authority=${_po0_url#*://}
    _po0_host=${_po0_authority%%/*}
    _po0_path=/${_po0_authority#*/}
    [ "$_po0_authority" != "$_po0_host" ] || _po0_path=/
    case "$_po0_host" in
        mirror.nju.edu.cn|mirrors.nju.edu.cn|mirrors.ustc.edu.cn|mirrors.tuna.tsinghua.edu.cn|mirrors.tencent.com|mirrors.tencentyun.com)
            # Keep the repository tree: some trees are absent on Tencent.
            # The actual download must fail, never fall back to the public mirror.
            ;;
        deb.debian.org|ftp.debian.org) ;;
        security.debian.org)
            case "$_po0_path" in /debian-security*) ;; *) _po0_path=/debian-security$_po0_path ;; esac ;;
        archive.debian.org) _po0_path=/debian-archive$_po0_path ;;
        archive.ubuntu.com|*.archive.ubuntu.com|security.ubuntu.com|ports.ubuntu.com) ;;
        dl-cdn.alpinelinux.org|dl-*.alpinelinux.org) ;;
        repo.almalinux.org) ;;
        dl.rockylinux.org|download.rockylinux.org)
            _po0_path=${_po0_path#/pub}
            _po0_path=${_po0_path#/rocky}
            _po0_path=/rocky$_po0_path ;;
        download.fedoraproject.org|dl.fedoraproject.org)
            _po0_path=${_po0_path#/pub}
            case "$_po0_path" in /fedora/linux/*) _po0_path=/fedora${_po0_path#/fedora/linux} ;; esac ;;
        cloud-images.ubuntu.com) _po0_path=/ubuntu-cloud-images$_po0_path ;;
        cdimage.debian.org) _po0_path=/debian-cdimage${_po0_path#/images} ;;
        kali.download|http.kali.org) ;;
        *) printf '%s\n' "$_po0_url"; exit 0 ;;
    esac
    printf '%s%s\n' "$PO0_MIRROR_BASE" "$_po0_path"
)

po0_check_bundle() (
    [ -s "$PO0_ASSET_DIR/po0-assets.list" ] || {
        echo 'Missing po0-assets.list. Download/extract the complete bundle, not reinstall.sh alone.' >&2
        exit 1
    }
    while IFS= read -r _po0_asset || [ -n "$_po0_asset" ]; do
        case "$_po0_asset" in ''|\#*) continue ;; esac
        [ -s "$PO0_ASSET_DIR/$_po0_asset" ] || {
            echo "Incomplete Po0 bundle: $_po0_asset" >&2; exit 1
        }
    done <"$PO0_ASSET_DIR/po0-assets.list"
    if [ -f "$PO0_ASSET_DIR/SHA256SUMS" ]; then
        cd "$PO0_ASSET_DIR" || exit 1
        sha256sum -c SHA256SUMS >/dev/null || exit 1
    fi
)
