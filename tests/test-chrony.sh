#!/bin/sh
# Exercise offline target configuration; never start a real service or alter time.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
export CHROOT_LOG="$scratch/chroot.log"
cat >"$scratch/bin/chroot" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CHROOT_LOG"
case "$*" in *' start '*|*' restart '*|*' --now '*) exit 99 ;; esac
EOF
chmod +x "$scratch/bin/chroot"
PATH="$scratch/bin:$PATH"
export PATH

make_root() {
    root="$scratch/$1"
    mkdir -p "$root/usr/sbin" "$root/etc/chrony" "$root/lib/systemd/system"
    printf '#!/bin/sh\n' >"$root/usr/sbin/chronyd"
    chmod +x "$root/usr/sbin/chronyd"
    : >"$CHROOT_LOG"
}
assert_sources() {
    [ "$(grep -c '^server time[1-5]\.tencentyun\.com iburst$' "$1")" -eq 5 ]
    [ "$(grep -c '^makestep 1.0 3$' "$1")" -eq 1 ]
    [ "$(grep -c '^rtcsync$' "$1")" -eq 1 ]
    ! grep -Eq '^[[:space:]]*(pool|peer|refclock|initstepslew|include|confdir|sourcedir)[[:space:]]' "$1"
    ! grep -q '^server external' "$1"
}

make_root debian
config="$root/etc/chrony/chrony.conf"
cat >"$config" <<'EOF'
# Keep this package comment.
driftfile /var/lib/chrony/chrony.drift
keyfile /etc/chrony/chrony.keys
pool public.pool.example iburst
 server external.example iburst
peer external-peer.example
refclock SHM 0
initstepslew 30 public.example
include /etc/chrony/extra.conf
confdir /etc/chrony/conf.d
sourcedir /run/chrony-dhcp
makestep 0.1 10
rtcsync
EOF
touch "$root/lib/systemd/system/chrony.service" "$root/lib/systemd/system/systemd-timesyncd.service"
sh "$repo/po0-chrony.sh" "$root" >/dev/null
assert_sources "$config"
grep -Fq 'driftfile /var/lib/chrony/chrony.drift' "$config"
grep -Fq 'keyfile /etc/chrony/chrony.keys' "$config"
grep -Fq 'pool public.pool.example iburst' "$config.po0-original"
grep -Fq 'systemctl disable systemd-timesyncd.service' "$CHROOT_LOG"
grep -Fq 'systemctl enable chrony.service' "$CHROOT_LOG"
cp "$config" "$scratch/first.conf"
sh "$repo/po0-chrony.sh" "$root" >/dev/null
cmp "$config" "$scratch/first.conf"
echo 'PASS: Debian sources, implicit-source exclusion, defaults, backup and idempotence'

make_root rpm
config="$root/etc/chrony.conf"
printf 'driftfile /var/lib/chrony/drift\npool public.example iburst' >"$config"
touch "$root/lib/systemd/system/chronyd.service"
sh "$repo/po0-chrony.sh" "$root" >/dev/null
assert_sources "$config"
grep -Fq 'systemctl enable chronyd.service' "$CHROOT_LOG"
cp "$config" "$scratch/rpm.conf"
sh "$repo/po0-chrony.sh" "$root" >/dev/null
cmp "$config" "$scratch/rpm.conf"
echo 'PASS: RPM config path, missing final newline, service and idempotence'

make_root alpine
config="$root/etc/chrony/chrony.conf"
printf 'pool public.example iburst\n' >"$config"
touch "$root/etc/alpine-release"
mkdir -p "$root/etc/init.d" "$root/etc/runlevels/default"
touch "$root/etc/init.d/chronyd" "$root/etc/runlevels/default/ntpd"
sh "$repo/po0-chrony.sh" "$root" >/dev/null
assert_sources "$config"
grep -Fq 'rc-update del ntpd default' "$CHROOT_LOG"
grep -Fq 'rc-update add chronyd default' "$CHROOT_LOG"
echo 'PASS: Alpine selects chronyd and disables competing ntpd'

make_root missing_package
config="$root/etc/chrony/chrony.conf"
printf 'pool untouched.example\n' >"$config"
rm "$root/usr/sbin/chronyd"
if sh "$repo/po0-chrony.sh" "$root" >/dev/null 2>&1; then exit 1; fi
grep -Fxq 'pool untouched.example' "$config"
[ ! -f "$config.po0-original" ]
echo 'PASS: missing package fails before modifying configuration'

! grep -Eq ' (start|restart) | --now ' "$CHROOT_LOG"
echo 'PASS: configuration only enables services; no chroot daemon start'
