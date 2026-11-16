#!/bin/sh
# shellcheck shell=dash
# The start fails (sing-box rejects the configuration). okop removed the interception, so the lists of
# every section went directly, as if okop were off.
# Expected: sections with on_failure "block" (the default) stay blocked: their subnets are rejected and
# their domains do not resolve, other sites work. okop retries the start by itself and comes back once the
# configuration is fixed. "okop stop" is a deliberate choice and unblocks them.

set -eu

. "$(dirname "$0")/../lib.sh"

BLOCKED_SUBNET=1.1.1.1
BLOCKED_DOMAIN=example.com

cleanup() {
    load_fixture proxy > /dev/null 2>&1 || true
}
trap cleanup EXIT

reachable() {
    on_client curl -sk -o /dev/null -m 5 "https://$1"
}

client_gets_address() {
    on_client dig +short +time=2 +tries=1 "@$ROUTER_LAN_IP" "$1" A | grep -qE '^[0-9]+(\.[0-9]+){3}$'
}

ip_rule_present() {
    on_router sh -c 'ip rule list | grep -q okop'
}

not() {
    ! "$@"
}

result=0

dc start proxy > /dev/null
load_fixture proxy
# The cached rule sets and the blocked subnet come from a successful start first
on_router sh -c "
    uci set okop.main.user_subnet_list_type='dynamic'
    uci add_list okop.main.user_subnets='$BLOCKED_SUBNET'
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 2
wait_okop

info "Starting with a mixed proxy port sing-box cannot parse"
on_router sh -c "
    uci set okop.dev_proxy.mixed_proxy_enabled=1
    uci set okop.dev_proxy.mixed_proxy_port=8080x
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 20

if on_router pidof sing-box > /dev/null; then
    fail "baseline: sing-box is running, the config was not rejected" || result=1
fi

if ip_rule_present || dnsmasq_uses_singbox; then
    fail "the interception or dnsmasq still points to a sing-box that is not running" || result=1
else
    pass "nothing is sent to the sing-box that is not running"
fi

if wait_for 15 not reachable "$BLOCKED_SUBNET"; then
    pass "the subnet of a blocking section is cut off"
else
    fail "the subnet of a blocking section goes directly" || result=1
fi

if client_gets_address "$BLOCKED_DOMAIN"; then
    fail "$BLOCKED_DOMAIN of a blocking section resolves" || result=1
else
    pass "$BLOCKED_DOMAIN of a blocking section does not resolve"
fi

if wait_for 15 client_resolves && client_fetches; then
    pass "other sites work directly"
else
    fail "other sites do not work after the failed start" || result=1
fi

info "Fixing the configuration without restarting okop, the retry must pick it up"
on_router sh -c "
    uci set okop.dev_proxy.mixed_proxy_enabled=0
    uci commit okop" > /dev/null 2>&1

if wait_for 150 ip_rule_present && wait_for 30 client_gets_fakeip "$BLOCKED_DOMAIN" &&
    wait_for 30 reachable "$BLOCKED_SUBNET"; then
    pass "okop retried the start and works again"
else
    fail "okop did not come back after the configuration was fixed" || result=1
fi

info "Breaking the start again, then stopping okop"
on_router sh -c "
    uci set okop.dev_proxy.mixed_proxy_enabled=1
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 20

info "Stopping okop"
on_router /etc/init.d/okop stop > /dev/null 2>&1

if wait_for 15 reachable "$BLOCKED_SUBNET" && wait_for 15 client_gets_address "$BLOCKED_DOMAIN"; then
    pass "okop stop unblocks the lists"
else
    fail "the lists stay blocked after okop stop" || result=1
fi

if on_router test -e /var/run/okop_start_retry.pid; then
    fail "a retry of the start is still scheduled after okop stop" || result=1
else
    pass "okop stop cancels the retry of the start"
fi

exit "$result"
