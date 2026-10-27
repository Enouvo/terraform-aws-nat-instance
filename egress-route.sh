#!/bin/bash
# Routes forwarded NAT traffic (see snat.sh). It enters on eth1, the ENI the private route tables target, and leaves:
#   - while eth1 has a public IP, i.e. an Elastic IP: through eth1, via a policy rule (iif eth1 -> table 200, whose
#     default route is eth1), so it leaves from the Elastic IP
#   - otherwise: through eth0 and its auto-assigned public IP, by the main table (the rule is removed)
#
# Runs at boot (from snat.sh) and then every few seconds (nat-egress-route.timer), because both sides change after
# boot: the Elastic IP can be associated late (a new VPC associates it in the same apply that launches the instance)
# or removed, and the network scripts rewrite eth1's routing (ec2-net-utils' refresh / DHCP renewal deletes every
# rule pointing at its eth1 table, 10001, and reconfiguring eth1 drops routes set on it). Only what is missing or
# stale is changed, and only then is anything logged.

# snat.sh: only with egress_via_eip
[ -f /run/nat/egress-via-eip ] || exit 0

nat_route_table=200
state_file=/run/nat/egress-interface

# Logs a change of egress interface once, not on every run
log_egress() {
  if [ "$(cat "$state_file" 2>/dev/null)" != "$1" ]; then
    echo "$1" > "$state_file"
    echo "$2"
  fi
}

# Nothing to do until eth1 is configured; the next run retries
ip -4 addr show dev eth1 | grep -q "inet " || exit 0

imds="http://169.254.169.254/latest"
imds_token=$(curl -s -m 2 -X PUT "$imds/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
eth1_public_ips=$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $imds_token" \
  "$imds/meta-data/network/interfaces/macs/$(cat /sys/class/net/eth1/address)/public-ipv4s")
imds_status=$?
# 22 is curl's HTTP error (404: no public IP). Anything else means the metadata service did not answer: keep the
# current routing rather than guess
[ "$imds_status" -eq 0 ] || [ "$imds_status" -eq 22 ] || exit 0

if [ -z "$eth1_public_ips" ]; then
  while ip rule del priority 1000 2>/dev/null; do :; done
  if [ -f /run/nat/own-traffic-via-eth1 ]; then
    log_egress none "WARNING: no public IP on eth1, and none on eth0 (associate_public_ip_address = false): no way out until an Elastic IP is associated with the ENI"
  else
    log_egress eth0 "eth1 has no public IP: forwarded traffic leaves through eth0 (auto-assigned public IP)"
  fi
  exit 0
fi

# eth1 is in the same subnet as eth0, so the subnet router is the same gateway: take it from any default route
# (the eth0 one may have been replaced below)
gateway=$(ip route show default | awk '/ via / {print $3; exit}')
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

log_egress eth1 "forwarded traffic leaves through eth1, public IP $(echo $eth1_public_ips)"

# Without a public IP on eth0 (associate_public_ip_address = false) the instance's own traffic must leave through
# eth1 as well: the main table's preferred default (no metric) goes via eth1. DHCP on eth0 puts its own back, hence
# re-checked here too.
if [ -f /run/nat/own-traffic-via-eth1 ] && \
   ! ip route show default | grep -v metric | grep -q "via $gateway dev eth1"; then
  ip route replace default via "$gateway" dev eth1
  echo "restored main default via $gateway dev eth1"
fi
