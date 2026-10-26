#!/bin/bash -x
# Rendered with templatefile(): $${...} is a Terraform interpolation, so shell variables below are
# written as $name, never in braces.

# wait for eth1
while ! ip link show dev eth1; do
  sleep 1
done

sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.eth0.rp_filter=0
sysctl -q -w net.ipv4.conf.eth1.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0


# enable IP forwarding and NAT
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.eth1.send_redirects=0

# Egress interface. eth0 carries the instance's auto-assigned public IP, which changes every time the
# instance is replaced (spot interruption, ASG refresh). When the persistent ENI eth1 has a public IP,
# i.e. an Elastic IP is associated with it, route the default and masquerade through eth1 instead, so
# NAT traffic (and the instance's own) leaves from that stable address. eth0 keeps its public IP only
# to boot and attach eth1.
#
# With several Elastic IPs on eth1 (one per private IP), MASQUERADE uses eth1's primary private IP, so
# traffic leaves from the Elastic IP of that address. egress_public_ip picks another one: traffic is
# SNATed to the private IP that Elastic IP is associated with.
egress_dev=eth0
snat_to_private_ip=""
if [ "${egress_via_eip}" = "true" ]; then
  imds="http://169.254.169.254/latest"
  imds_token=$(curl -s -X PUT "$imds/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  eth1_mac=$(cat /sys/class/net/eth1/address)
  eth1_imds="$imds/meta-data/network/interfaces/macs/$eth1_mac"
  # The metadata of a just-attached ENI can lag a few seconds
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    eth1_public_ips=$(curl -sf -H "X-aws-ec2-metadata-token: $imds_token" "$eth1_imds/public-ipv4s" || true)
    [ -n "$eth1_public_ips" ] && break
    sleep 2
  done

  if [ -n "$eth1_public_ips" ]; then
    # eth1 is in the same subnet as eth0, so the subnet router is the same gateway. Set the route
    # explicitly: Amazon Linux 2 adds no main-table default route for a secondary ENI, which is why
    # the original `ip route del default dev eth0` left the instance without one.
    gateway=$(ip route show default dev eth0 | awk '{print $3; exit}')
    ip route replace default via "$gateway" dev eth1
    egress_dev=eth1
    echo "eth1 public IPs: $(echo $eth1_public_ips)"

    egress_public_ip="${egress_public_ip}"
    if [ -n "$egress_public_ip" ]; then
      snat_to_private_ip=$(curl -sf -H "X-aws-ec2-metadata-token: $imds_token" \
        "$eth1_imds/ipv4-associations/$egress_public_ip" || true)
      if [ -n "$snat_to_private_ip" ]; then
        # ec2-net-utils configures secondary private IPs on eth1 asynchronously; add it if still missing
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
          ip -4 addr show dev eth1 | grep -qw "$snat_to_private_ip" && break
          sleep 1
        done
        if ! ip -4 addr show dev eth1 | grep -qw "$snat_to_private_ip"; then
          prefix_length=$(curl -sf -H "X-aws-ec2-metadata-token: $imds_token" "$eth1_imds/subnet-ipv4-cidr-block" | cut -d/ -f2)
          ip addr add "$snat_to_private_ip/$prefix_length" dev eth1
        fi
        echo "SNAT through eth1 to $snat_to_private_ip, public IP $egress_public_ip"
      else
        echo "WARNING: egress_public_ip $egress_public_ip is not associated with eth1; using its primary IP"
      fi
    fi
    [ -z "$snat_to_private_ip" ] && echo "SNAT through eth1 (primary private IP)"
  else
    echo "eth1 has no public IP; SNAT through eth0"
  fi
fi

if [ -n "$snat_to_private_ip" ]; then
  iptables -t nat -A POSTROUTING -o eth1 -j SNAT --to-source "$snat_to_private_ip"
else
  iptables -t nat -A POSTROUTING -o "$egress_dev" -j MASQUERADE
fi
# Should a DHCP renewal on eth0 restore its default route, traffic falls back to eth0's address
# instead of leaving un-translated
if [ "$egress_dev" != eth0 ]; then
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
fi

# wait for network connection
curl --retry 10 http://www.example.com

# reestablish connections
systemctl restart amazon-ssm-agent.service
