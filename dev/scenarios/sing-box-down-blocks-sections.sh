#!/bin/sh
# shellcheck shell=dash
# sing-box stays down while okop is running. The lists of every section then went directly: subnets took
# the main routing table, and the DNS guard gave dnsmasq the upstream servers, which resolve the domains
# to real addresses.
# Expected: sections with on_failure "block" (the default) lose their traffic until sing-box is back:
# their subnets and fully routed devices are rejected, their domains do not resolve. Sections with
# "direct", exclusions inside a blocked domain and everything else keep working directly.

set -eu

. "$(dirname "$0")/../lib.sh"

BLOCKED_SUBNET=1.1.1.1
DIRECT_SUBNET=1.0.0.1
BLOCKED_DOMAIN=example.com
DIRECT_DOMAIN=example.org
EXCLUDED_DOMAIN=www.example.com
CLIENT_IP=192.168.77.10

cleanup() {
    on_router /etc/init.d/sing-box start > /dev/null 2>&1 || true
    load_fixture proxy > /dev/null 2>&1 || true
}
trap cleanup EXIT

reachable() {
    on_client curl -sk -o /dev/null -m 5 "https://$1"
}

lists_routed_to_singbox() {
    on_router ip -4 rule list | grep -q "lookup okop"
}

client_gets_address() {
    on_client dig +short +time=2 +tries=1 "@$ROUTER_LAN_IP" "$1" A | grep -qE '^[0-9]+(\.[0-9]+){3}$'
}

client_gets_real_ip() {
    on_client dig +short +time=2 +tries=1 "@$ROUTER_LAN_IP" "$1" A |
        grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -qvE '^198\.1[89]\.'
}

not() {
    ! "$@"
}

result=0

dc start proxy > /dev/null
load_fixture proxy
info "main blocks on failure, loose lets its lists go directly, $EXCLUDED_DOMAIN is excluded"
on_router sh -c "
    uci set okop.main.user_subnet_list_type='dynamic'
    uci add_list okop.main.user_subnets='$BLOCKED_SUBNET'
    uci set okop.loose=section
    uci set okop.loose.connection_type='outbound'
    uci set okop.loose.outbound='dev_proxy'
    uci set okop.loose.on_failure='direct'
    uci set okop.loose.user_domain_list_type='dynamic'
    uci add_list okop.loose.user_domains='$DIRECT_DOMAIN'
    uci set okop.loose.user_subnet_list_type='dynamic'
    uci add_list okop.loose.user_subnets='$DIRECT_SUBNET'
    uci set okop.excluded=section
    uci set okop.excluded.connection_type='exclusion'
    uci set okop.excluded.user_domain_list_type='dynamic'
    uci add_list okop.excluded.user_domains='$EXCLUDED_DOMAIN'
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 2
wait_okop
wait_for 30 reachable "$BLOCKED_SUBNET" || fail "baseline: $BLOCKED_SUBNET is not reachable through the proxy"
wait_for 15 client_gets_fakeip "$BLOCKED_DOMAIN" || fail "baseline: $BLOCKED_DOMAIN does not get a fake IP"

# Save & Apply in LuCI restarts okop. Every moment of the restart, traffic of the blocking section is either
# routed to sing-box or rejected, and its domains stay on sing-box DNS.
info "Restarting okop, watching for a gap"
on_router sh -c '
    rm -f /tmp/okop-gap
    (
        # BusyBox sleep takes whole seconds only: checked back to back for the whole restart instead
        until=$(($(date +%s) + 45))
        while [ "$(date +%s)" -lt "$until" ]; do
            if ! ip -4 rule list | grep -q "lookup okop" &&
                ! nft list chain inet OkopKillswitch forward 2> /dev/null | grep -q reject; then
                echo subnets >> /tmp/okop-gap
            fi
            ls /tmp/dnsmasq.*.d/okop-blocked-domains.conf > /dev/null 2>&1 || echo domains >> /tmp/okop-gap
        done
    ) > /dev/null 2>&1 &
    /etc/init.d/okop restart > /dev/null 2>&1
    wait' > /dev/null 2>&1
if on_router test -s /tmp/okop-gap; then
    fail "a restart leaves the blocking section unprotected: $(on_router sort -u /tmp/okop-gap | tr '\n' ' ')" || result=1
else
    pass "a restart never leaves the blocking section unprotected"
fi
wait_okop

info "Stopping sing-box"
on_router /etc/init.d/sing-box stop
wait_for 40 not lists_routed_to_singbox || fail "the DNS guard did not notice sing-box is down"
wait_for 30 not dnsmasq_uses_singbox || fail "the DNS guard did not give dnsmasq the upstream servers"

if wait_for 15 not reachable "$BLOCKED_SUBNET"; then
    pass "the subnet of a blocking section is cut off"
else
    fail "the subnet of a blocking section goes directly" || result=1
fi

if wait_for 15 reachable "$DIRECT_SUBNET"; then
    pass "the subnet of a section with on_failure direct goes directly"
else
    fail "the subnet of a section with on_failure direct is cut off" || result=1
fi

if client_gets_address "$BLOCKED_DOMAIN"; then
    fail "$BLOCKED_DOMAIN of a blocking section resolves" || result=1
else
    pass "$BLOCKED_DOMAIN of a blocking section does not resolve"
fi

if wait_for 15 client_gets_real_ip "$DIRECT_DOMAIN"; then
    pass "$DIRECT_DOMAIN of a section with on_failure direct resolves to a real address"
else
    fail "$DIRECT_DOMAIN of a section with on_failure direct does not resolve" || result=1
fi

if wait_for 15 client_gets_real_ip "$EXCLUDED_DOMAIN"; then
    pass "the excluded $EXCLUDED_DOMAIN resolves inside the blocked $BLOCKED_DOMAIN"
else
    fail "the excluded $EXCLUDED_DOMAIN does not resolve" || result=1
fi

if client_resolves && client_fetches; then
    pass "other sites work directly"
else
    fail "other sites do not work while sing-box is down" || result=1
fi

info "Routing the client fully through the blocking section"
on_router sh -c "
    uci add_list okop.main.fully_routed_ips='$CLIENT_IP'
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 2
wait_okop
on_router /etc/init.d/sing-box stop
wait_for 40 not lists_routed_to_singbox || fail "the DNS guard did not notice sing-box is down"

if wait_for 15 not client_fetches https://1.0.0.1; then
    pass "a fully routed device of a blocking section is cut off"
else
    fail "a fully routed device of a blocking section goes directly" || result=1
fi

info "Starting sing-box"
on_router /etc/init.d/sing-box start

if wait_for 40 lists_routed_to_singbox && wait_for 30 client_gets_fakeip "$BLOCKED_DOMAIN" &&
    wait_for 30 reachable "$BLOCKED_SUBNET"; then
    pass "the blocking section works through sing-box again"
else
    fail "the blocking section does not work after sing-box is back" || result=1
fi

exit "$result"
