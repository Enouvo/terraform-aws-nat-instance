#!/bin/bash
# Keeps forwarded NAT traffic routed out of eth1, the ENI with the Elastic IP (see snat.sh). Forwarded
# traffic enters on eth1, so a policy rule sends it through table 200, whose default route is eth1.
#
# Runs at boot (from snat.sh) and then every few seconds (nat-egress-route.timer): the network scripts
# rewrite eth1's routing after boot as well. ec2-net-utils' periodic refresh / DHCP renewal deletes every
# rule that points at its eth1 table (10001), and reconfiguring eth1 drops routes set on it. Only what is
# missing is (re)added, and only then is anything logged.

# snat.sh decides whether egress goes through eth1 at all
[ -f /run/nat/egress-via-eth1 ] || exit 0

nat_route_table=200

# Nothing to do until eth1 is configured; the next run retries
ip -4 addr show dev eth1 | grep -q "inet " || exit 0

# eth1 is in the same subnet as eth0, so the subnet router is the same gateway
gateway=$(ip route show default dev eth0 | awk '{print $3; exit}')
[ -n "$gateway" ] || exit 0

if ! ip route show table "$nat_route_table" | grep -q "^default via $gateway dev eth1"; then
  ip route replace default via "$gateway" dev eth1 table "$nat_route_table"
  echo "restored default via $gateway dev eth1 in table $nat_route_table"
fi

if ! ip rule show | grep -q "^1000:.*iif eth1 lookup $nat_route_table"; then
  while ip rule del priority 1000 2>/dev/null; do :; done
  ip rule add iif eth1 lookup "$nat_route_table" priority 1000
  echo "restored rule iif eth1 lookup $nat_route_table"
fi
