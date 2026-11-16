#!/bin/sh
# shellcheck shell=dash
# sing-box runs, but the connection of a section does not respond (the proxy server is down).
# Expected: the traffic of the section does not reach its sites at all, it is not sent directly instead.
# The sites are reachable directly from the dev environment, so a successful fetch means a leak.

set -eu

. "$(dirname "$0")/../lib.sh"

LISTED_SUBNET=1.1.1.1

cleanup() {
    dc start proxy > /dev/null 2>&1 || true
    load_fixture proxy > /dev/null 2>&1 || true
}
trap cleanup EXIT

reachable() {
    on_client curl -sk -o /dev/null -m 5 "https://$1"
}

result=0

dc start proxy > /dev/null
load_fixture proxy
on_router sh -c "
    uci set okop.main.user_subnet_list_type='dynamic'
    uci add_list okop.main.user_subnets='$LISTED_SUBNET'
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 2
wait_okop
wait_for 30 reachable "$LISTED_SUBNET" || fail "baseline: $LISTED_SUBNET is not reachable through the proxy"

info "Stopping the proxy server"
dc stop proxy > /dev/null

if client_gets_fakeip example.com; then
    pass "example.com still gets a fake IP, DNS works"
else
    fail "example.com does not get a fake IP, the checks below prove nothing" || result=1
fi

if client_fetches https://example.com; then
    fail "example.com from the lists is fetched without the proxy" || result=1
else
    pass "example.com from the lists is not fetched without the proxy"
fi

if reachable "$LISTED_SUBNET"; then
    fail "$LISTED_SUBNET from the lists is reachable without the proxy" || result=1
else
    pass "$LISTED_SUBNET from the lists is not reachable without the proxy"
fi

# Retried: openwrt.org is reached directly over the real internet, one slow connection is not a failure
if wait_for 30 client_resolves && wait_for 30 client_fetches; then
    pass "other sites work"
else
    fail "other sites do not work while the proxy is down" || result=1
fi

exit "$result"
