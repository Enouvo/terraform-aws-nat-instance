resource "aws_security_group" "this" {
  name_prefix = var.name
  vpc_id      = var.vpc_id
  description = "Security group for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_security_group_rule" "egress" {
  security_group_id = aws_security_group.this.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
}

resource "aws_security_group_rule" "ingress_any" {
  security_group_id = aws_security_group.this.id
  type              = "ingress"
  cidr_blocks       = var.private_subnets_cidr_blocks
  from_port         = 0
  to_port           = 65535
  protocol          = "all"
}

resource "aws_network_interface" "this" {
  security_groups   = [aws_security_group.this.id]
  subnet_id         = var.public_subnet
  source_dest_check = false
  description       = "ENI for NAT instance ${var.name}"
  tags              = local.common_tags
}

resource "aws_route" "this" {
  count                  = length(var.private_route_table_ids)
  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.this.id
}

# AMI of the latest Amazon Linux 2 
data "aws_ami" "this" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "block-device-mapping.volume-type"
    values = ["gp2"]
  }
}

resource "aws_launch_template" "this" {
  name_prefix = var.name
  image_id    = var.image_id != "" ? var.image_id : data.aws_ami.this.id
  key_name    = var.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  user_data = base64encode(join("\n", [
    "#cloud-config",
    yamlencode(merge(
      # Without a public IP the instance has no way out until snat.sh routes its own traffic through eth1, which
      # runs after Amazon Linux's boot-time security update would have stalled on the unreachable repositories
      var.associate_public_ip_address ? {} : { repo_upgrade : "none" },
      {
        # https://cloudinit.readthedocs.io/en/latest/topics/modules.html
        write_files : concat([
          {
            path : "/opt/nat/runonce.sh",
            content : templatefile("${path.module}/runonce.sh", {
              eni_id                = aws_network_interface.this.id
              attach_eni_externally = local.attach_eni_externally
            }),
            permissions : "0755",
          },
          {
            path : "/opt/nat/snat.sh",
            content : templatefile("${path.module}/snat.sh", {
              egress_via_eip   = var.egress_via_eip
              single_eip       = var.single_eip
              egress_public_ip = var.egress_public_ip
              # Without a public IP on eth0, the instance's own traffic (SSM, package updates) needs eth1 too
              own_traffic_via_eth1 = !var.associate_public_ip_address
            }),
            permissions : "0755",
          },
          {
            path : "/etc/systemd/system/snat.service",
            content : file("${path.module}/snat.service"),
          },
          # Keep forwarded traffic routed out of eth1 when egress goes through its Elastic IP (snat.sh)
          {
            path : "/opt/nat/egress-route.sh",
            content : file("${path.module}/egress-route.sh"),
            permissions : "0755",
          },
          {
            path : "/etc/systemd/system/nat-egress-route.service",
            content : file("${path.module}/nat-egress-route.service"),
          },
          {
            path : "/etc/systemd/system/nat-egress-route.timer",
            content : file("${path.module}/nat-egress-route.timer"),
          },
        ], var.user_data_write_files),
        runcmd : concat([
          ["/opt/nat/runonce.sh"],
        ], var.user_data_runcmd),
    }))
  ]))

  description = "Launch template for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = var.name
  desired_capacity    = var.enabled ? 1 : 0
  min_size            = var.enabled ? 1 : 0
  max_size            = 1
  vpc_zone_identifier = [var.public_subnet]

  # With the ENI attached by the lifecycle hook, a new instance only gets InService once the ENI is free. When this ASG
  # is replaced (create_before_destroy), the old instance holding it is terminated only after the new ASG is created,
  # so waiting for the new one's capacity here would deadlock until the timeout.
  wait_for_capacity_timeout = local.attach_eni_externally ? "0" : null

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.use_spot_instance ? 0 : 1
      on_demand_percentage_above_base_capacity = var.use_spot_instance ? 0 : 100
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  # Present from the first launch of a new ASG on (lifecycle-hook.tf). Changes are ignored (lifecycle below): on an
  # existing ASG they would replace it, so aws_autoscaling_lifecycle_hook.attach_eni adds the hook there instead.
  dynamic "initial_lifecycle_hook" {
    for_each = local.attach_eni_externally ? [1] : []
    content {
      name                 = local.lifecycle_hook_name
      lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
      default_result       = "ABANDON"
      heartbeat_timeout    = local.lifecycle_hook_timeout
    }
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [initial_lifecycle_hook]

    precondition {
      condition     = !var.associate_public_ip_address ? var.egress_via_eip : true
      error_message = "associate_public_ip_address = false needs egress_via_eip: the Elastic IP on the ENI is then the instance's only way out."
    }
  }

  # The rule and its target must exist before the first launch, or its lifecycle event is missed and the hook
  # times out (ABANDON) before a retry launch is caught
  depends_on = [aws_cloudwatch_event_target.attach_eni, aws_iam_role_policy.attach_eni_events, aws_iam_role_policy.attach_eni_automation]
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = var.name
  role        = aws_iam_role.this.name
}

resource "aws_iam_role" "this" {
  name_prefix        = var.name
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.this.name
}

resource "aws_iam_role_policy" "eni" {
  role        = aws_iam_role.this.name
  name_prefix = var.name
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AttachNetworkInterface",
                "ec2:ModifyInstanceAttribute"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}
