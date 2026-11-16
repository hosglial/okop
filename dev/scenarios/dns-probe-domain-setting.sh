#!/bin/sh
# shellcheck shell=dash
# The DNS guard checked the DNS server of sing-box by resolving openwrt.org. When that domain is in a list
# (the community list "hodca" has it), sing-box answers with a fake IP by itself, the check always passed,
# and a dead DNS server went unnoticed: nothing outside the lists resolved.
# Expected: the check domain comes from settings.dns_probe_domain; with a domain outside the lists the guard
# notices the dead DNS server although openwrt.org is listed.

set -eu

. "$(dirname "$0")/../lib.sh"

UPSTREAM="77.88.8.8"
PROBE=example.net

block_upstream() {
    on_router sh -c "
        nft add table inet devblock
        nft add chain inet devblock out '{ type filter hook output priority 0; }'
        nft add rule inet devblock out ip daddr $UPSTREAM udp dport 53 drop
        nft add rule inet devblock out ip daddr $UPSTREAM tcp dport 53 drop"
}

unblock_upstream() {
    on_router nft delete table inet devblock 2> /dev/null || true
}

cleanup() {
    unblock_upstream
    load_fixture proxy > /dev/null 2>&1 || true
}
trap cleanup EXIT

not() {
    ! "$@"
}

result=0

dc start proxy > /dev/null
load_fixture proxy
info "openwrt.org is in a list, the check domain is $PROBE"
on_router sh -c "
    uci add_list okop.main.user_domains='openwrt.org'
    uci set okop.settings.dns_probe_domain='$PROBE'
    uci commit okop
    /etc/init.d/okop restart" > /dev/null 2>&1
sleep 2
wait_okop
wait_for 30 client_gets_fakeip openwrt.org || fail "baseline: openwrt.org does not get a fake IP"
wait_for 30 dnsmasq_uses_singbox || fail "baseline: dnsmasq does not use sing-box"

info "Blocking the DNS server sing-box forwards to"
block_upstream

if wait_for 60 not dnsmasq_uses_singbox; then
    pass "the DNS guard noticed the dead DNS server with openwrt.org in a list"
else
    fail "the DNS guard did not notice the dead DNS server" || result=1
fi

if on_router sh -c "logread -e okop | grep -q 'cannot resolve $PROBE'"; then
    pass "the guard checked $PROBE"
else
    fail "the log does not name $PROBE" || result=1
fi

info "Unblocking the DNS server"
unblock_upstream

if wait_for 60 dnsmasq_uses_singbox; then
    pass "dnsmasq goes back to sing-box once the DNS server works"
else
    fail "dnsmasq does not go back to sing-box" || result=1
fi

exit "$result"
