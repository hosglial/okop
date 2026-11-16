#!/bin/sh
# shellcheck shell=dash
# Domains of an Exclusion section got fake IPs like the routed ones, so their traffic still went through
# sing-box (and stopped when it was down), only to leave it directly. A domain excluded from a broader
# routed list (www.example.com out of example.com) must not get a fake IP either.
# Expected: excluded domains resolve to real addresses and are fetched past the proxy, the routed ones
# keep their fake IPs.

set -eu

. "$(dirname "$0")/../lib.sh"

EXCLUDED=www.example.com

cleanup() {
    load_fixture proxy > /dev/null 2>&1 || true
}
trap cleanup EXIT

client_gets_real_ip() {
    on_client dig +short +time=2 +tries=1 "@$ROUTER_LAN_IP" "$1" A |
        grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -qvE '^198\.1[89]\.'
}

result=0

dc start proxy > /dev/null
load_fixture proxy
info "Excluding $EXCLUDED, example.com stays routed"
on_router sh -c "
    uci set okop.excluded=section
    uci set okop.excluded.connection_type='exclusion'
    uci set okop.excluded.user_domain_list_type='dynamic'
    uci add_list okop.excluded.user_domains='$EXCLUDED'
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 2
wait_okop

if wait_for 15 client_gets_real_ip "$EXCLUDED"; then
    pass "$EXCLUDED resolves to a real address"
else
    fail "$EXCLUDED does not resolve to a real address" || result=1
fi

if wait_for 15 client_gets_fakeip example.com && wait_for 15 client_gets_fakeip youtube.com; then
    pass "example.com and youtube.com keep fake IPs"
else
    fail "routed domains lost their fake IPs" || result=1
fi

if client_fetches "https://$EXCLUDED"; then
    pass "client fetches https://$EXCLUDED"
else
    fail "client cannot fetch https://$EXCLUDED" || result=1
fi

if dc logs proxy --since 1m 2> /dev/null | grep -q "inbound connection to $EXCLUDED:443"; then
    fail "the connection to $EXCLUDED went through the proxy" || result=1
else
    pass "the connection to $EXCLUDED did not go through the proxy"
fi

exit "$result"
