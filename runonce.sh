#!/bin/bash -x

%{ if !attach_eni_externally ~}
aws ec2 modify-instance-attribute --no-source-dest-check \
  --region "$(/opt/aws/bin/ec2-metadata -z  | sed 's/placement: \(.*\).$/\1/')" \
  --instance-id "$(/opt/aws/bin/ec2-metadata -i | cut -d' ' -f2)"

# attach the ENI
aws ec2 attach-network-interface \
  --region "$(/opt/aws/bin/ec2-metadata -z  | sed 's/placement: \(.*\).$/\1/')" \
  --instance-id "$(/opt/aws/bin/ec2-metadata -i | cut -d' ' -f2)" \
  --device-index 1 \
  --network-interface-id "${eni_id}"
%{ else ~}
# The ENI (${eni_id}) is attached from outside by the ASG lifecycle hook's SSM Automation (lifecycle-hook.tf):
# this instance may have no public IP to reach the EC2 API with. snat.sh waits for eth1.
%{ endif ~}

# start SNAT
systemctl enable snat
systemctl start snat
