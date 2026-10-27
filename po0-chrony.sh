#!/bin/sh
# Configure an already installed chrony package in a target root.
# Enable the service for boot; never start a daemon inside the install chroot.
set -eu

root=${1:-/}
root=${root%/}
[ -n "$root" ] || root=/

if [ ! -x "$root/usr/sbin/chronyd" ] && [ ! -x "$root/usr/bin/chronyd" ]; then
    echo 'Install chrony in the target before configuring Po0 time sources.' >&2
    exit 1
fi

if [ -f "$root/etc/chrony/chrony.conf" ]; then
    config="$root/etc/chrony/chrony.conf"
elif [ -f "$root/etc/chrony.conf" ]; then
    config="$root/etc/chrony.conf"
else
    echo 'The installed chrony package has no supported configuration file.' >&2
    exit 1
fi

# Keep the distribution's drift, logging, key and privilege settings. Disable
# implicit DHCP/include sources as well as public pools, so only the five
# Tencent internal servers are active. The first package configuration is kept.
if [ ! -f "$config.po0-original" ]; then
    cp -p "$config" "$config.po0-original"
fi
tmp="$config.po0-tmp.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
{
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//')
        directive=${trimmed%%[[:space:]]*}
        case "$directive" in
            server|pool|peer|refclock|initstepslew|include|confdir|sourcedir|makestep|rtcsync)
                continue ;;
        esac
        # Remove our own marker so repeated runs produce the same file.
        [ "$line" != '# Po0: Tencent internal time sources' ] || continue
        printf '%s\n' "$line"
    done <"$config"
    echo '# Po0: Tencent internal time sources'
    for n in 1 2 3 4 5; do
        printf 'server time%s.tencentyun.com iburst\n' "$n"
    done
    echo 'makestep 1.0 3'
    echo rtcsync
} >"$tmp"
chmod 644 "$tmp"
mv "$tmp" "$config"

if [ -f "$root/etc/alpine-release" ]; then
    [ -f "$root/etc/init.d/chronyd" ] || {
        echo 'Missing chronyd OpenRC service.' >&2; exit 1
    }
    if [ -e "$root/etc/runlevels/default/ntpd" ] || [ -L "$root/etc/runlevels/default/ntpd" ]; then
        chroot "$root" rc-update del ntpd default
    fi
    chroot "$root" rc-update add chronyd default
else
    service=
    for candidate in chrony chronyd; do
        if [ -f "$root/lib/systemd/system/$candidate.service" ] ||
            [ -f "$root/usr/lib/systemd/system/$candidate.service" ]; then
            service=$candidate
            break
        fi
    done
    [ -n "$service" ] || { echo 'Missing chrony systemd service.' >&2; exit 1; }
    if [ -f "$root/lib/systemd/system/systemd-timesyncd.service" ] ||
        [ -f "$root/usr/lib/systemd/system/systemd-timesyncd.service" ]; then
        chroot "$root" systemctl disable systemd-timesyncd.service
    fi
    chroot "$root" systemctl enable "$service.service"
fi

printf 'Configured chrony with Tencent internal time servers: %s\n' "$config"
