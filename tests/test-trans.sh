#!/usr/bin/env bash
# Isolated fixtures: source function definitions only; never run the installer entrypoint.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/assets" "$scratch/bin" "$scratch/root/etc/apt/sources.list.d" "$scratch/root/etc/yum.repos.d"
cp "$repo/po0-cloud.sh" "$scratch/assets/po0-cloud.sh"

cat >"$scratch/assets/po0-lib.sh" <<'EOF'
PO0_MIRROR_BASE=http://mirror.test
PO0_MIRROR_HOST=mirror.test
po0_rewrite_url() {
    case "$1" in
    https://deb.debian.org/*) printf '%s\n' "$PO0_MIRROR_BASE/${1#https://deb.debian.org/}" ;;
    http://security.debian.org/*) printf '%s\n' "$PO0_MIRROR_BASE/${1#http://security.debian.org/}" ;;
    http://archive.ubuntu.com/*) printf '%s\n' "$PO0_MIRROR_BASE/${1#http://archive.ubuntu.com/}" ;;
    http://security.ubuntu.com/*) printf '%s\n' "$PO0_MIRROR_BASE/${1#http://security.ubuntu.com/}" ;;
    https://repo.almalinux.org/*) printf '%s\n' "$PO0_MIRROR_BASE/${1#https://repo.almalinux.org/}" ;;
    *) printf '%s\n' "$1" ;;
    esac
}
po0_copy_asset() {
    if [ "$2" = - ]; then cat "$PO0_ASSET_DIR/$1"; else cp "$PO0_ASSET_DIR/$1" "$2"; fi
}
EOF
cat >"$scratch/assets/ttys.sh" <<'EOF'
printf 'fixture-tty:%s\n' "$1"
EOF
sed '/^: main$/,$d' "$repo/trans.sh" >"$scratch/trans-functions.sh"
if PO0_ASSET_DIR="$scratch/missing-bundle" bash "$scratch/trans-functions.sh" >"$scratch/missing.log" 2>&1; then
    printf '%s\n' 'FAIL: missing bundle accepted' >&2
    exit 1
fi
grep -Fq 'Missing Po0 bundle:' "$scratch/missing.log"
export PO0_ASSET_DIR="$scratch/assets"
# The upstream definitions intentionally use unset optional variables.
set +u
. "$scratch/trans-functions.sh"
set -u

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_has() { grep -Fqx -- "$2" "$1" || fail "Missing line: $2"; }

cat >"$scratch/root/etc/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main
EOF
cat >"$scratch/root/etc/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/ http://security.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-security
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
cat >"$scratch/root/etc/yum.repos.d/almalinux.repo" <<'EOF'
[baseos]
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
# baseurl=https://repo.almalinux.org/almalinux/$releasever/BaseOS/$basearch/os/
gpgcheck=1
[custom]
metalink=https://example.test/custom
baseurl=https://example.test/base
enabled=0
EOF
po0_rewrite_target_repos "$scratch/root"
assert_has "$scratch/root/etc/apt/sources.list" 'deb http://mirror.test/debian bookworm main contrib non-free-firmware'
assert_has "$scratch/root/etc/apt/sources.list" 'deb http://mirror.test/debian-security bookworm-security main'
assert_has "$scratch/root/etc/apt/sources.list.d/ubuntu.sources" 'URIs: http://mirror.test/ubuntu/ http://mirror.test/ubuntu/'
assert_has "$scratch/root/etc/apt/sources.list.d/ubuntu.sources" 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'
assert_has "$scratch/root/etc/yum.repos.d/almalinux.repo" '#mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos'
assert_has "$scratch/root/etc/yum.repos.d/almalinux.repo" 'baseurl=http://mirror.test/almalinux/$releasever/BaseOS/$basearch/os/'
assert_has "$scratch/root/etc/yum.repos.d/almalinux.repo" 'metalink=https://example.test/custom'
cp "$scratch/root/etc/yum.repos.d/almalinux.repo" "$scratch/once.repo"
po0_rewrite_target_repos "$scratch/root"
cmp "$scratch/once.repo" "$scratch/root/etc/yum.repos.d/almalinux.repo"

cat >"$scratch/bin/wget" <<'EOF'
#!/usr/bin/env bash
if [ "$#" = 0 ]; then printf '%s\n' 'GNU Wget fixture'; exit; fi
printf '<%s>\n' "$@" >"$PO0_WGET_ARGS"
EOF
chmod +x "$scratch/bin/wget"
export PATH="$scratch/bin:$PATH" PO0_WGET_ARGS="$scratch/wget.args"
wget -O "$scratch/a file" 'https://deb.debian.org/debian/file?one=1&two=2' >/dev/null 2>&1
assert_has "$scratch/wget.args" "<$scratch/a file>"
assert_has "$scratch/wget.args" '<http://mirror.test/debian/file?one=1&two=2>'
[ "$(get_ttys 'console=')" = 'fixture-tty:console=' ] || fail 'ttys helper did not use bundle'

# Integration with the actual shared mapping library, not only adapter stubs.
. "$repo/po0-lib.sh"
cat >"$scratch/root/etc/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian trixie main non-free-firmware
deb http://security.debian.org/debian-security trixie-security main
EOF
cat >"$scratch/root/etc/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://cn.archive.ubuntu.com/ubuntu http://security.ubuntu.com/ubuntu
Suites: noble noble-security
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: jammy
EOF
cat >"$scratch/root/etc/yum.repos.d/almalinux.repo" <<'EOF'
[baseos]
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
# baseurl=https://repo.almalinux.org/almalinux/$releasever/BaseOS/$basearch/os/
gpgcheck=1
[custom]
metalink=https://example.test/custom
baseurl=https://example.test/base
enabled=0
EOF
po0_rewrite_target_repos "$scratch/root"
assert_has "$scratch/root/etc/apt/sources.list" 'deb http://mirror.test/debian trixie main non-free-firmware'
assert_has "$scratch/root/etc/apt/sources.list" 'deb http://mirror.test/debian-security trixie-security main'
assert_has "$scratch/root/etc/apt/sources.list.d/ubuntu.sources" 'URIs: http://mirror.test/ubuntu http://mirror.test/ubuntu'
assert_has "$scratch/root/etc/apt/sources.list.d/ubuntu.sources" 'URIs: http://mirror.test/ubuntu-ports'
assert_has "$scratch/root/etc/yum.repos.d/almalinux.repo" '#mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos'
assert_has "$scratch/root/etc/yum.repos.d/almalinux.repo" 'baseurl=http://mirror.test/almalinux/$releasever/BaseOS/$basearch/os/'
assert_has "$scratch/root/etc/yum.repos.d/almalinux.repo" 'metalink=https://example.test/custom'

# A bad operator mapping must fail without replacing the original repository file.
printf '%s\n' 'https://deb.debian.org/ not-a-url' >"$PO0_ASSET_DIR/po0-mirrors.conf"
printf '%s\n' 'deb https://deb.debian.org/debian bookworm main' >"$scratch/bad.list"
cp "$scratch/bad.list" "$scratch/bad.original"
if po0_rewrite_repo_file "$scratch/bad.list" 2>/dev/null; then fail 'Invalid mapping accepted'; fi
cmp "$scratch/bad.list" "$scratch/bad.original"
rm "$PO0_ASSET_DIR/po0-mirrors.conf"

if grep -Eq 'confhome|web_port|web_path|setup_web|websocketd|nginx|logviewer|lighttpd|files\.m\.daocloud\.io' "$repo/trans.sh"; then
    fail 'Remote helper, public fallback, or web-log dependency remains'
fi
printf '%s\n' 'PASS: trans repository rewriting (stub + real mappings), RPM sections, idempotence, URL argument boundaries, missing/local assets, invalid mapping failure, SSH-only logging'

# Exercise upstream's DNS-only override interface with Po0's DHCP address mode.
# All netconf and generated interfaces live in the fixture directory.
mkdir -p "$scratch/netconf/eth0"
for key in ipv4_has_internet dhcpv4; do
    printf '1\n' >"$scratch/netconf/eth0/$key"
done
for key in ipv6_has_internet dhcpv6_or_slaac slaac dhcpv6 other \
    should_disable_dhcpv4 should_disable_accept_ra should_disable_autoconf \
    should_add_ipv4_static_dns should_add_ipv6_static_dns; do
    printf '0\n' >"$scratch/netconf/eth0/$key"
done
printf '02:00:00:00:00:01\n' >"$scratch/netconf/eth0/mac_addr"
printf '\n' >"$scratch/netconf/eth0/rdnss"
get_netconf_to() {
    local value
    value=$(cat "$scratch/netconf/$ethx/$1") || return
    printf -v "$1" '%s' "$value"
}
get_eths() { printf 'eth0\n'; }
get_current_dns() {
    case "$1" in 4) printf '10.20.0.53\n' ;; 6) printf 'fd00::53\n' ;; *) return 1 ;; esac
}
distro=debian
releasever=12
ethx=eth0
is_dhcpv4 || fail 'normal address mode is not DHCP'
if should_add_ipv4_static_dns || should_add_ipv6_static_dns; then fail 'normal DHCP gained DNS overrides'; fi
create_ifupdown_config "$scratch/interfaces"
assert_has "$scratch/interfaces" 'iface eth0 inet dhcp'
if grep -q 'dns-nameserver' "$scratch/interfaces"; then fail 'DHCP resolver was unnecessarily pinned'; fi

printf '1\n' >"$scratch/netconf/eth0/should_add_ipv4_static_dns"
should_add_ipv4_static_dns || fail 'saved IPv4 DNS flag ignored'
is_dhcpv4 || fail 'DNS override disabled DHCP'
if is_staticv4; then fail 'DNS override changed IP to static'; fi
create_ifupdown_config "$scratch/interfaces"
assert_has "$scratch/interfaces" 'iface eth0 inet dhcp'
assert_has "$scratch/interfaces" '    dns-nameservers 10.20.0.53'
if grep -q 'inet static\|accept_ra 0\|autoconf 0' "$scratch/interfaces"; then fail 'DNS override disabled address autoconfiguration'; fi
printf '%s\n' 'PASS: DNS-only override renders DHCP plus saved IPv4 DNS without static IP'

for key in ipv6_has_internet dhcpv6_or_slaac slaac other; do
    printf '1\n' >"$scratch/netconf/eth0/$key"
done
printf 'fd00::54\n' >"$scratch/netconf/eth0/rdnss"
if should_add_ipv6_static_dns; then fail 'working IPv6 DNS was unnecessarily pinned'; fi
printf '1\n' >"$scratch/netconf/eth0/should_add_ipv6_static_dns"
should_add_ipv6_static_dns || fail 'saved IPv6 DNS flag ignored'
create_ifupdown_config "$scratch/interfaces"
assert_has "$scratch/interfaces" 'iface eth0 inet dhcp'
assert_has "$scratch/interfaces" 'iface eth0 inet6 auto'
assert_has "$scratch/interfaces" '    dns-nameserver fd00::53'
is_dhcpv4 || fail 'IPv6 DNS override changed IPv4 DHCP mode'
printf '%s\n' 'PASS: DNS-only override renders SLAAC plus saved IPv6 DNS without disabling DHCP'
