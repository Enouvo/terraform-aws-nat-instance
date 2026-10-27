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

# Egress. Forwarded traffic enters on eth1 (the private route tables target this ENI) and leaves through:
#   - eth1, while it has a public IP, i.e. an Elastic IP is associated with the ENI: that stable address
#   - otherwise eth0, from the instance's auto-assigned public IP, which changes whenever the instance is replaced
# Which of the two is not decided here, once: the Elastic IP can be associated after boot (a new VPC associates it
# in the same apply that launches the instance) or removed later, and the network scripts rewrite eth1's routing
# after boot as well. egress-route.sh decides and re-checks every few seconds (nat-egress-route.timer); this script
# masquerades on both interfaces so either path works, and without egress_via_eip only eth0 is ever used.
#
# MASQUERADE uses eth1's primary private IP, so traffic leaves from that address's Elastic IP: the only one with
# single_eip (the default). With single_eip = false and several Elastic IPs on eth1 (one per private IP),
# egress_public_ip picks another one: traffic is SNATed to the private IP that Elastic IP is associated with.
if [ "${egress_via_eip}" = "true" ]; then
  # Routing set before eth1 is configured would be dropped by the network scripts
  for attempt in $(seq 1 60); do
    ip -4 addr show dev eth1 | grep -q "inet " && break
    sleep 1
  done

  snat_to_private_ip=""
  egress_public_ip="${egress_public_ip}"
  if [ "${single_eip}" != "true" ] && [ -n "$egress_public_ip" ]; then
    imds="http://169.254.169.254/latest"
    imds_token=$(curl -s -X PUT "$imds/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    eth1_imds="$imds/meta-data/network/interfaces/macs/$(cat /sys/class/net/eth1/address)"
    # The metadata of a just-attached ENI can lag a few seconds
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      snat_to_private_ip=$(curl -sf -H "X-aws-ec2-metadata-token: $imds_token" \
        "$eth1_imds/ipv4-associations/$egress_public_ip" || true)
      [ -n "$snat_to_private_ip" ] && break
      sleep 2
    done
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

  if [ -n "$snat_to_private_ip" ]; then
    iptables -t nat -A POSTROUTING -o eth1 -j SNAT --to-source "$snat_to_private_ip"
  else
    iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
  fi

  mkdir -p /run/nat
  touch /run/nat/egress-via-eip
  # No public IP on eth0 (associate_public_ip_address = false): the instance's own traffic needs eth1 too
  if [ "${own_traffic_via_eth1}" = "true" ]; then
    touch /run/nat/own-traffic-via-eth1
  fi
  /opt/nat/egress-route.sh
  # Unit files were just written by cloud-init
  systemctl daemon-reload
  systemctl enable --now nat-egress-route.timer
fi

# eth0: the way out without an Elastic IP on eth1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# wait for network connection
curl --retry 10 http://www.example.com

# reestablish connections
systemctl restart amazon-ssm-agent.service
