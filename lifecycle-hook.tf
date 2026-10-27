# ---------------------------------------------------------------------------------------------------------------------
# Attach the ENI from outside the instance (attach_eni_from_lifecycle_hook, or associate_public_ip_address = false)
#
# By default runonce.sh attaches the ENI through the EC2 API from the instance itself, which needs a public IP on
# eth0: until eth1 is attached, eth0 is the instance's only way out. Here the ASG holds each launching instance in
# Pending:Wait (lifecycle hook), EventBridge starts an SSM Automation runbook that attaches the ENI and disables the
# instance's source/dest check, then completes the hook. No code to package or run: the runbook calls the APIs itself.
# A failed attach completes the hook with ABANDON, so the ASG replaces the instance.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  attach_eni_externally = var.enabled && (var.attach_eni_from_lifecycle_hook || !var.associate_public_ip_address)
  lifecycle_hook_name   = "attach-eni"
  lifecycle_hook_count  = local.attach_eni_externally ? 1 : 0
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_ssm_document" "attach_eni" {
  count = local.lifecycle_hook_count

  name            = "${var.name}-attach-eni"
  document_type   = "Automation"
  document_format = "JSON"
  tags            = local.common_tags

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Attach the NAT ENI ${aws_network_interface.this.id} to a launching NAT instance, then let the launch continue"
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      InstanceId           = { type = "String" }
      AutoScalingGroupName = { type = "String" }
      LifecycleHookName    = { type = "String" }
      LifecycleActionToken = { type = "String" }
      AutomationAssumeRole = { type = "String", default = aws_iam_role.attach_eni_automation[0].arn }
    }
    mainSteps = [
      {
        name           = "waitForInstanceRunning"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 180
        onFailure      = "step:abandon"
        inputs = {
          Service          = "ec2"
          Api              = "DescribeInstances"
          InstanceIds      = ["{{ InstanceId }}"]
          PropertySelector = "$.Reservations[0].Instances[0].State.Name"
          DesiredValues    = ["running"]
        }
      },
      {
        # The instance being replaced may still hold it
        name           = "waitForEniAvailable"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 240
        onFailure      = "step:abandon"
        inputs = {
          Service             = "ec2"
          Api                 = "DescribeNetworkInterfaces"
          NetworkInterfaceIds = [aws_network_interface.this.id]
          PropertySelector    = "$.NetworkInterfaces[0].Status"
          DesiredValues       = ["available"]
        }
      },
      {
        name      = "disableSourceDestCheck"
        action    = "aws:executeAwsApi"
        onFailure = "step:abandon"
        inputs = {
          Service         = "ec2"
          Api             = "ModifyInstanceAttribute"
          InstanceId      = "{{ InstanceId }}"
          SourceDestCheck = { Value = false }
        }
      },
      {
        name        = "attachEni"
        action      = "aws:executeAwsApi"
        maxAttempts = 3
        onFailure   = "step:abandon"
        inputs = {
          Service            = "ec2"
          Api                = "AttachNetworkInterface"
          InstanceId         = "{{ InstanceId }}"
          NetworkInterfaceId = aws_network_interface.this.id
          DeviceIndex        = 1
        }
      },
      {
        name   = "continueLaunch"
        action = "aws:executeAwsApi"
        isEnd  = true
        inputs = {
          Service               = "autoscaling"
          Api                   = "CompleteLifecycleAction"
          AutoScalingGroupName  = "{{ AutoScalingGroupName }}"
          LifecycleHookName     = "{{ LifecycleHookName }}"
          LifecycleActionToken  = "{{ LifecycleActionToken }}"
          LifecycleActionResult = "CONTINUE"
        }
      },
      {
        name   = "abandon"
        action = "aws:executeAwsApi"
        isEnd  = true
        inputs = {
          Service               = "autoscaling"
          Api                   = "CompleteLifecycleAction"
          AutoScalingGroupName  = "{{ AutoScalingGroupName }}"
          LifecycleHookName     = "{{ LifecycleHookName }}"
          LifecycleActionToken  = "{{ LifecycleActionToken }}"
          LifecycleActionResult = "ABANDON"
        }
      },
    ]
  })
}

# Role the runbook runs as
resource "aws_iam_role" "attach_eni_automation" {
  count = local.lifecycle_hook_count

  # IAM role name_prefix is at most 38 characters
  name_prefix = "${substr(var.name, 0, 26)}-eni-ssm-"
  tags        = local.common_tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "attach_eni_automation" {
  count = local.lifecycle_hook_count

  name_prefix = var.name
  role        = aws_iam_role.attach_eni_automation[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AttachNetworkInterface", "ec2:ModifyInstanceAttribute"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = "arn:${data.aws_partition.current.partition}:autoscaling:*:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name}*"
      },
    ]
  })
}

# Launch lifecycle events of this ASG -> the runbook. Matched by name prefix and hook name rather than the ASG's
# generated name, so the rule exists before the ASG launches its first instance.
resource "aws_cloudwatch_event_rule" "attach_eni" {
  count = local.lifecycle_hook_count

  name_prefix = "${substr(var.name, 0, 26)}-attach-eni-"
  description = "NAT instance ${var.name} launching: attach its ENI"
  tags        = local.common_tags
  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance-launch Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [{ prefix = var.name }]
      LifecycleHookName    = [local.lifecycle_hook_name]
    }
  })
}

resource "aws_cloudwatch_event_target" "attach_eni" {
  count = local.lifecycle_hook_count

  rule     = aws_cloudwatch_event_rule.attach_eni[0].name
  arn      = "${replace(aws_ssm_document.attach_eni[0].arn, ":document/", ":automation-definition/")}:$DEFAULT"
  role_arn = aws_iam_role.attach_eni_events[0].arn

  # Automation parameters are lists of strings
  input_transformer {
    input_paths = {
      instance = "$.detail.EC2InstanceId"
      asg      = "$.detail.AutoScalingGroupName"
      hook     = "$.detail.LifecycleHookName"
      token    = "$.detail.LifecycleActionToken"
    }
    input_template = <<-EOF
      {
        "InstanceId": [<instance>],
        "AutoScalingGroupName": [<asg>],
        "LifecycleHookName": [<hook>],
        "LifecycleActionToken": [<token>]
      }
    EOF
  }
}

# Role EventBridge starts the runbook with
resource "aws_iam_role" "attach_eni_events" {
  count = local.lifecycle_hook_count

  # IAM role name_prefix is at most 38 characters
  name_prefix = "${substr(var.name, 0, 26)}-eni-evt-"
  tags        = local.common_tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "attach_eni_events" {
  count = local.lifecycle_hook_count

  name_prefix = var.name
  role        = aws_iam_role.attach_eni_events[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:StartAutomationExecution"
        Resource = "${replace(aws_ssm_document.attach_eni[0].arn, ":document/", ":automation-definition/")}:*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.attach_eni_automation[0].arn
      },
    ]
  })
}

# For an ASG that already exists when this is turned on (initial_lifecycle_hook only applies at creation)
resource "aws_autoscaling_lifecycle_hook" "attach_eni" {
  count = local.lifecycle_hook_count

  name                   = local.lifecycle_hook_name
  autoscaling_group_name = aws_autoscaling_group.this.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "ABANDON"
  heartbeat_timeout      = 600
}
