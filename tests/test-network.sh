#!/bin/sh
# Run only against mocked commands and a temporary filesystem.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

export PO0_NETWORK_LIBRARY_ONLY=1
export PO0_NETCONF_ROOT="$test_root/netconf"
export PO0_RESOLV_CONF="$test_root/resolv.conf"
export PO0_SAVED_RESOLV_CONF="$test_root/saved-resolv.conf"
# shellcheck source=../initrd-network.sh
. "$repo/initrd-network.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_equal() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
sleep() { :; }

# Never call the host's ip, DHCP client, or networking tools. Each unsupported
# action is an error and is recorded so ignored failures cannot hide it.
ip() {
    printf 'ip %s\n' "$*" >>"$test_root/commands"
    case "$*" in
    '-o link')
        if [ "$mock_interface" = present ]; then
            echo '2: eth0: <BROADCAST,UP> mtu 1500 link/ether 02:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff'
        fi
        ;;
    '-4 -o addr show scope global dev eth0')
        if [ -s "$test_root/ipv4" ]; then
            printf '2: eth0 inet %s scope global eth0\n' "$(cat "$test_root/ipv4")"
        fi
        ;;
    '-6 -o addr show scope global dev eth0' | '-6 route show default dev eth0') ;;
    '-4 route show default dev eth0')
        if [ -s "$test_root/gateway" ]; then
            printf 'default via %s dev eth0\n' "$(cat "$test_root/gateway")"
        fi
        ;;
    'link set dev lo up' | 'link set dev eth0 up') ;;
    '-4 addr add '* ) printf '%s\n' "$4" >"$test_root/ipv4" ;;
    '-4 route add default via '* ) printf '%s\n' "$6" >"$test_root/gateway" ;;
    '-4 route add '* ) : ;;
    *)
        printf 'unexpected ip %s\n' "$*" >>"$test_root/unexpected"
        return 1
        ;;
    esac
}

udhcpc() {
    printf 'udhcpc %s\n' "$*" >>"$test_root/commands"
    case "$scenario" in
    dhcp | no_dns | missing_dns)
        echo '10.20.1.40/24' >"$test_root/ipv4"
        echo '10.20.1.1' >"$test_root/gateway"
        if [ "$scenario" = dhcp ]; then
            printf '# supplied by DHCP\nnameserver 10.20.0.54\n' >"$PO0_RESOLV_CONF"
        fi
        ;;
    changed_lease)
        echo '10.20.2.50/24' >"$test_root/ipv4"
        echo '10.20.2.1' >"$test_root/gateway"
        echo 'nameserver 10.20.0.54' >"$PO0_RESOLV_CONF"
        ;;
    partial_lease)
        echo '10.20.2.50/24' >"$test_root/ipv4"
        echo 'nameserver 10.20.0.54' >"$PO0_RESOLV_CONF"
        ;;
    timeout) return 1 ;;
    *) fail "unrecognized DHCP scenario: $scenario" ;;
    esac
}

# All public Internet access is unavailable in every test. Any attempted probe
# must fail the test even if production code chooses to ignore its exit status.
unexpected_probe() {
    printf 'unexpected probe %s\n' "$*" >>"$test_root/unexpected"
    return 1
}
curl() { unexpected_probe curl "$@"; }
wget() { unexpected_probe wget "$@"; }
nc() { unexpected_probe nc "$@"; }
ping() { unexpected_probe ping "$@"; }
nslookup() { unexpected_probe nslookup "$@"; }
dig() { unexpected_probe dig "$@"; }

reset_case() {
    scenario=$1
    mock_interface=present
    rm -rf "$PO0_NETCONF_ROOT"
    : >"$test_root/ipv4"
    : >"$test_root/gateway"
    : >"$test_root/commands"
    : >"$test_root/unexpected"
    : >"$PO0_RESOLV_CONF"
    printf 'nameserver 127.0.0.53\nnameserver 10.20.0.53\n' >"$PO0_SAVED_RESOLV_CONF"
}

run_saved_config() {
    po0_network_main '02:00:00:00:00:01' '10.20.1.40/24' '10.20.1.1' '' '' true ''
}

assert_no_probes_or_flushes() {
    [ ! -s "$test_root/unexpected" ] || fail "unexpected network operation: $(cat "$test_root/unexpected")"
    if grep -Eq 'flush|del(ete)?|(^| )(curl|wget|nc|ping|nslookup|dig)( |$)' "$test_root/commands"; then
        fail 'network state was deleted or a reachability probe was executed'
    fi
}

reset_case dhcp
run_saved_config >/dev/null || fail 'DHCP success was rejected when public Internet is unavailable'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/ipv4_has_internet")" 1 'legacy IPv4 configured flag'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/dhcpv4")" 1 'target DHCP mode'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv4_static_dns")" 0 'DHCP IPv4 DNS override disabled'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv6_static_dns")" 0 'DHCP IPv6 DNS override disabled'
expect_equal "$(cat "$PO0_RESOLV_CONF")" "$(printf '# supplied by DHCP\nnameserver 10.20.0.54')" 'DHCP resolver preservation'
[ -s "$PO0_NETCONF_ROOT/eth0/logs" ] || fail 'network log was not saved'
grep -Eq '^\[[[:space:]]*[0-9]+\.[0-9]+\] Configuring Po0 DHCP' "$PO0_NETCONF_ROOT/eth0/logs" || fail 'network log is missing uptime prefix'
assert_no_probes_or_flushes
echo 'PASS: DHCP succeeds without public reachability and preserves DNS'

reset_case changed_lease
run_saved_config >/dev/null || fail 'new DHCP lease was rejected'
expect_equal "$(cat "$test_root/ipv4")" '10.20.2.50/24' 'new DHCP address preservation'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/ipv4_addr")" '10.20.2.50/24' 'recorded DHCP address'
expect_equal "$(cat "$test_root/gateway")" '10.20.2.1' 'new DHCP gateway preservation'
if grep -q ' addr add\| route add' "$test_root/commands"; then fail 'new DHCP lease was overwritten'; fi
assert_no_probes_or_flushes
echo 'PASS: changed DHCP lease remains authoritative'

reset_case timeout
run_saved_config >/dev/null 2>&1 || fail 'saved address rescue failed'
expect_equal "$(cat "$test_root/ipv4")" '10.20.1.40/24' 'saved installer address'
expect_equal "$(cat "$test_root/gateway")" '10.20.1.1' 'saved installer gateway'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/dhcpv4")" 1 'rescue must not pin target to static IPv4'
expect_equal "$(cat "$PO0_RESOLV_CONF")" 'nameserver 10.20.0.53' 'saved non-loopback resolver'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv4_static_dns")" 1 'saved IPv4 DNS propagated to target'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv6_static_dns")" 0 'IPv4-only fallback does not add IPv6 DNS'
assert_no_probes_or_flushes
echo 'PASS: DHCP timeout uses saved installer state while target stays DHCP'

reset_case timeout
if po0_network_main '02:00:00:00:00:01' '' '' '' '' true '' >/dev/null 2>&1; then
    fail 'DHCP failure without a saved address was accepted'
fi
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/ipv4_has_internet")" 0 'missing local IPv4 state'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv4_static_dns")" 0 'failed IPv4 leaves DNS override disabled'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv6_static_dns")" 0 'failed IPv4 leaves IPv6 DNS override disabled'
assert_no_probes_or_flushes
echo 'PASS: missing DHCP and saved state fails without destructive cleanup'

reset_case partial_lease
if run_saved_config >/dev/null 2>&1; then fail 'partial different lease was accepted'; fi
expect_equal "$(cat "$test_root/ipv4")" '10.20.2.50/24' 'partial lease address remains untouched'
[ ! -s "$test_root/gateway" ] || fail 'old gateway was applied to a different lease'
assert_no_probes_or_flushes
echo 'PASS: old gateway is not attached to a different incomplete lease'

reset_case no_dns
echo 'nameserver 127.0.0.53' >"$PO0_RESOLV_CONF"
run_saved_config >/dev/null || fail 'saved resolver fallback failed'
expect_equal "$(cat "$PO0_RESOLV_CONF")" 'nameserver 10.20.0.53' 'stub resolver replacement'
assert_no_probes_or_flushes
echo 'PASS: saved resolver replaces only missing or host-local DNS'

reset_case no_dns
printf 'nameserver 10.20.0.53\nnameserver fd00::53\n' >"$PO0_SAVED_RESOLV_CONF"
run_saved_config >/dev/null || fail 'dual-stack saved DNS fallback failed'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv4_static_dns")" 1 'saved IPv4 override'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv6_static_dns")" 1 'saved IPv6 override'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/dhcpv4")" 1 'DNS fallback keeps target DHCP'
expect_equal "$(cat "$PO0_RESOLV_CONF")" "$(cat "$PO0_SAVED_RESOLV_CONF")" 'both saved resolver families retained'
assert_no_probes_or_flushes
# Re-run on the same shell and netconf directory: a later complete DHCP reply
# must remove override flags from the previous fallback without pinning DNS.
scenario=dhcp
run_saved_config >/dev/null || fail 'subsequent DHCP response failed'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv4_static_dns")" 0 'stale IPv4 DNS override cleared'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv6_static_dns")" 0 'stale IPv6 DNS override cleared'
expect_equal "$(cat "$PO0_RESOLV_CONF")" "$(printf '# supplied by DHCP\nnameserver 10.20.0.54')" 'later DHCP DNS authoritative'
assert_no_probes_or_flushes
echo 'PASS: saved DNS family flags propagate and subsequent DHCP clears stale overrides'

reset_case missing_dns
echo 'nameserver 127.0.0.53' >"$PO0_SAVED_RESOLV_CONF"
if run_saved_config >/dev/null 2>&1; then fail 'missing usable DNS was silently accepted'; fi
expect_equal "$(cat "$test_root/ipv4")" '10.20.1.40/24' 'address retained after DNS failure'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv4_static_dns")" 0 'unavailable DNS does not claim IPv4 override'
expect_equal "$(cat "$PO0_NETCONF_ROOT/eth0/should_add_ipv6_static_dns")" 0 'unavailable DNS does not claim IPv6 override'
assert_no_probes_or_flushes
echo 'PASS: missing usable DNS reports failure without removing the lease'

reset_case dhcp
mock_interface=missing
if run_saved_config >/dev/null 2>&1; then fail 'missing interface was accepted'; fi
[ ! -d "$PO0_NETCONF_ROOT" ] || fail 'missing interface produced a target configuration'
assert_no_probes_or_flushes
echo 'PASS: missing interface fails before changing network state'
