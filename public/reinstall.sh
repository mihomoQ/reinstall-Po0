#!/usr/bin/env bash
set -e
dir=$(mktemp -d)
trap 'rm -rf -- "$dir"' EXIT
url=https://reinstall.aa.jp.eu.org:8443/reinstall.tar.gz
curl -fsS "$url" -o "$dir/source.tar.gz" || wget -qO "$dir/source.tar.gz" "$url"
tar -xzf "$dir/source.tar.gz" -C "$dir"
test -s "$dir/reinstall-Po0/reinstall.sh"
rm -f "$dir/source.tar.gz"
trap - EXIT
exec bash "$dir/reinstall-Po0/reinstall.sh" "$@"
