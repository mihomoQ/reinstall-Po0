#!/bin/ash
# shellcheck shell=dash
# Po0 uses a private DHCP interface with cloud-side public IP mapping.
# Configure the interface; do not infer network health from public endpoints.

DHCP_TIMEOUT=15
DNS_FILE_TIMEOUT=5

# These paths are overridable so the network logic can be tested without
# touching the host's interfaces, resolver, or /dev directory.
PO0_NETCONF_ROOT=${PO0_NETCONF_ROOT:-/dev/netconf}
PO0_RESOLV_CONF=${PO0_RESOLV_CONF:-/etc/resolv.conf}
PO0_SAVED_RESOLV_CONF=${PO0_SAVED_RESOLV_CONF:-/configs/po0-resolv.conf}

log() {
    log_with_uptime="[$(printf '%6s' "$(cut -d ' ' -f1 /proc/uptime)")] $*"
    echo "$log_with_uptime" >&2
    if [ -n "${ethx:-}" ]; then
        mkdir -p "$PO0_NETCONF_ROOT/$ethx" || return 1
        echo "$log_with_uptime" >>"$PO0_NETCONF_ROOT/$ethx/logs"
    fi
}

get_ethx() {
    ip -o link | grep -i -F "link/ether $mac_addr " |
        cut -d: -f2 | sed 's/^ *//;s/@.*//' | head -1 | grep .
}

get_first_ipv4_addr() {
    ip -4 -o addr show scope global dev "$ethx" | head -1 |
        grep -o '[0-9\.]*/[0-9]*'
}

get_first_ipv6_addr() {
    ip -6 -o addr show scope global dev "$ethx" | head -1 |
        grep -o '[0-9a-fA-F\:]*/[0-9]*'
}

get_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | head -1 | cut -d' ' -f3
}

get_ipv6_gateway() {
    ip -6 route show default dev "$ethx" | head -1 | cut -d' ' -f3
}

is_have_ipv4() {
    [ -n "$(get_first_ipv4_addr)" ] && [ -n "$(get_ipv4_gateway)" ]
}

is_have_ipv6() {
    [ -n "$(get_first_ipv6_addr)" ] && [ -n "$(get_ipv6_gateway)" ]
}

usable_nameservers() {
    [ -f "$1" ] || return 0
    # A host-local resolver such as 127.0.0.53 is absent in the installer.
    sed -n 's/^[[:space:]]*nameserver[[:space:]]\{1,\}\([^[:space:]#]*\).*/\1/p' "$1" |
        while IFS= read -r dns; do
            case "$dns" in
            '' | 127.* | 0.0.0.0 | :: | ::1) continue ;;
            *.* | *:*) printf 'nameserver %s\n' "$dns" ;;
            esac
        done
}

restore_saved_dns_if_needed() {
    if [ -n "$(usable_nameservers "$PO0_RESOLV_CONF")" ]; then
        return 0
    fi
    saved_dns=$(usable_nameservers "$PO0_SAVED_RESOLV_CONF")
    if [ -z "$saved_dns" ]; then
        log "No DHCP DNS or saved resolver is available for $ethx."
        return 1
    fi
    printf '%s\n' "$saved_dns" >"$PO0_RESOLV_CONF" || return 1
    # Use upstream's DNS-only override interface without disabling DHCP or
    # probing public endpoints. Only resolvers saved from this machine qualify.
    if printf '%s\n' "$saved_dns" | grep -q '^nameserver [^:]*\.'; then
        should_add_ipv4_static_dns=1
    fi
    if printf '%s\n' "$saved_dns" | grep -q '^nameserver .*:'; then
        should_add_ipv6_static_dns=1
    fi
    log "DHCP DNS is missing; using saved resolvers for $ethx."
}

configure_dhcp() {
    # BusyBox's own retry limit also works in Debian initrds without timeout.
    if ! udhcpc -i "$ethx" -f -q -n -t 5 -T 3; then
        log "DHCPv4 did not complete on $ethx; checking saved configuration."
    fi

    # Do not wait for IPv6 on the normal IPv4-only Po0 instance. Keep IPv6
    # support when the original system had it, without a reachability probe.
    if [ -n "$ipv6_addr" ]; then
        if [ -f /usr/share/debconf/confmodule ] && command -v dhcp6c >/dev/null; then
            mkdir -p /var/lib/netcfg
            cat <<EOF >/var/lib/netcfg/dhcp6c.conf
interface $ethx {
    send ia-na 0;
    request domain-name-servers;
    request domain-name;
    script "/lib/netcfg/print-dhcp6c-info";
};
id-assoc na 0 {
};
EOF
            dhcp6c -c /var/lib/netcfg/dhcp6c.conf "$ethx" || true
            sleep "$DHCP_TIMEOUT"
            dhcp6_pid=$(cat /var/run/dhcp6c.pid 2>/dev/null || true)
            case "$dhcp6_pid" in
            '' | *[!0-9]*) ;;
            *) kill "$dhcp6_pid" 2>/dev/null || true ;;
            esac
        elif command -v udhcpc6 >/dev/null; then
            timeout "$DHCP_TIMEOUT" udhcpc6 -i "$ethx" -f -q -n || true
        fi
    fi
    sleep "$DNS_FILE_TIMEOUT"
}

restore_missing_addresses() {
    # Rescue fallback only fills missing state. A different DHCP lease is
    # authoritative: never replace it with the address from the old system.
    current_ipv4=$(get_first_ipv4_addr)
    if [ -z "$current_ipv4" ] && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
        log "Using saved IPv4 temporarily in the installer: $ipv4_addr"
        ip -4 addr add "$ipv4_addr" dev "$ethx" || return 1
        current_ipv4=$ipv4_addr
    fi
    if [ -n "$current_ipv4" ] && [ "${current_ipv4%/*}" = "${ipv4_addr%/*}" ] &&
        [ -n "$ipv4_gateway" ] && [ -z "$(get_ipv4_gateway)" ]; then
        ip -4 route add "$ipv4_gateway" dev "$ethx" || return 1
        ip -4 route add default via "$ipv4_gateway" dev "$ethx" || return 1
    fi

    current_ipv6=$(get_first_ipv6_addr)
    if [ -z "$current_ipv6" ] && [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
        ip -6 addr add "$ipv6_addr" dev "$ethx" || return 1
        current_ipv6=$ipv6_addr
    fi
    if [ -n "$current_ipv6" ] && [ "${current_ipv6%/*}" = "${ipv6_addr%/*}" ] &&
        [ -n "$ipv6_gateway" ] && [ -z "$(get_ipv6_gateway)" ]; then
        ip -6 route add "$ipv6_gateway" dev "$ethx" || return 1
        ip -6 route add default via "$ipv6_gateway" dev "$ethx" || return 1
    fi
}

write_netconf() {
    netconf="$PO0_NETCONF_ROOT/$ethx"
    mkdir -p "$netconf" || return 1
    # Keep trans.sh's file interface. The legacy *_has_internet names now
    # mean only that a local address and default route exist, not Internet
    # reachability. All download operations check their own result.
    printf '%s\n' "$ipv4_configured" >"$netconf/ipv4_has_internet" || return 1
    printf '%s\n' "$ipv6_configured" >"$netconf/ipv6_has_internet" || return 1
    # Po0's target system must still use DHCP even if the installer temporarily
    # restored the previous address after a DHCP timeout.
    printf '1\n' >"$netconf/dhcpv4" || return 1
    printf '%s\n' "$dhcpv6_or_slaac" >"$netconf/dhcpv6_or_slaac" || return 1
    printf '0\n' >"$netconf/should_disable_dhcpv4" || return 1
    printf '0\n' >"$netconf/should_disable_accept_ra" || return 1
    printf '0\n' >"$netconf/should_disable_autoconf" || return 1
    printf '%s\n' "$should_add_ipv4_static_dns" >"$netconf/should_add_ipv4_static_dns" || return 1
    printf '%s\n' "$should_add_ipv6_static_dns" >"$netconf/should_add_ipv6_static_dns" || return 1
    printf '1\n' >"$netconf/is_in_china" || return 1
    printf '%s\n' "$ethx" >"$netconf/ethx" || return 1
    printf '%s\n' "$mac_addr" >"$netconf/mac_addr" || return 1
    printf '%s\n' "$(get_first_ipv4_addr)" >"$netconf/ipv4_addr" || return 1
    printf '%s\n' "$(get_ipv4_gateway)" >"$netconf/ipv4_gateway" || return 1
    printf '%s\n' "$(get_first_ipv6_addr)" >"$netconf/ipv6_addr" || return 1
    printf '%s\n' "$(get_ipv6_gateway)" >"$netconf/ipv6_gateway" || return 1
    printf '%s\n' "$ipv6_extra_addrs" >"$netconf/ipv6_extra_addrs" || return 1
}

po0_network_main() {
    mac_addr=${1:-}
    ipv4_addr=${2:-}
    ipv4_gateway=${3:-}
    ipv6_addr=${4:-}
    ipv6_gateway=${5:-}
    # Argument 6 is retained for the upstream caller ABI; Po0 is always CN.
    ipv6_extra_addrs=${7:-}
    should_add_ipv4_static_dns=0
    should_add_ipv6_static_dns=0
    if [ -z "$mac_addr" ]; then
        echo 'Missing network interface MAC address.' >&2
        return 1
    fi

    ethx=
    for i in $(seq 20); do
        if ethx=$(get_ethx); then
            break
        fi
        sleep 1
    done
    if [ -z "$ethx" ]; then
        log "Network card not found: $mac_addr"
        return 1
    fi

    log "Configuring Po0 DHCP on $ethx ($mac_addr)..."
    ip link set dev lo up || return 1
    ip link set dev "$ethx" up || return 1
    configure_dhcp

    dhcpv6_or_slaac=0
    [ -z "$(get_first_ipv6_addr)" ] || dhcpv6_or_slaac=1
    restore_missing_addresses || return 1

    ipv4_configured=0
    ipv6_configured=0
    is_have_ipv4 && ipv4_configured=1
    is_have_ipv6 && ipv6_configured=1
    dns_ready=0
    if [ "$ipv4_configured" = 1 ] && restore_saved_dns_if_needed; then
        dns_ready=1
    fi
    write_netconf || return 1

    if [ "$ipv4_configured" = 0 ]; then
        log "No IPv4 address/default route on $ethx; existing state was preserved."
        return 1
    fi
    [ "$dns_ready" = 1 ] || return 1
    log "Po0 network configured on $ethx; public connectivity is not tested."
}

if [ "${PO0_NETWORK_LIBRARY_ONLY:-0}" != 1 ]; then
    po0_network_main "$@"
fi
