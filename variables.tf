variable "enabled" {
  description = "Enable or not costly resources"
  type        = bool
  default     = true
}

variable "name" {
  description = "Name for all the resources as identifier"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet" {
  description = "ID of the public subnet to place the NAT instance"
  type        = string
}

variable "private_subnets_cidr_blocks" {
  description = "List of CIDR blocks of the private subnets. The NAT instance accepts connections from this subnets"
  type        = list
}

variable "private_route_table_ids" {
  description = "List of ID of the route tables for the private subnets. You can set this to assign the each default route to the NAT instance"
  type        = list
  default     = []
}

variable "image_id" {
  description = "AMI of the NAT instance. Default to the latest Amazon Linux 2"
  type        = string
  default     = ""
}

variable "instance_types" {
  description = "Candidates of spot instance type for the NAT instance. This is used in the mixed instances policy"
  type        = list
  default     = ["t3.nano", "t3a.nano"]
}

variable "use_spot_instance" {
  description = "Whether to use spot or on-demand EC2 instance"
  type        = bool
  default     = true
}

variable "egress_via_eip" {
  description = "Send NAT traffic out through the ENI (eth1) when it has a public IP, i.e. an Elastic IP is associated with it, so it leaves from that stable address instead of the instance's auto-assigned public IP, which changes whenever the instance is replaced. Without a public IP on the ENI, traffic keeps leaving through eth0."
  type        = bool
  default     = true
}

variable "single_eip" {
  description = "Only one Elastic IP is associated with the ENI: egress masquerades on its primary private IP and the egress_public_ip lookup is skipped. Set false to pick among several Elastic IPs with egress_public_ip."
  type        = bool
  default     = true
}

variable "egress_public_ip" {
  description = "Only with single_eip = false: of several Elastic IPs on the ENI, the one to send traffic from (e.g. the address an external service allowlists). It must be associated with one of the ENI's private IPs. Empty: the Elastic IP of the ENI's primary private IP."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "Name of the key pair for the NAT instance. You can set this to assign the key pair to the NAT instance"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to resources created with this module"
  type        = map
  default     = {}
}

variable "user_data_write_files" {
  description = "Additional write_files section of cloud-init"
  type        = list
  default     = []
}

variable "user_data_runcmd" {
  description = "Additional runcmd section of cloud-init"
  type        = list
  default     = []
}

variable "associate_public_ip_address" {
  description = "Whether to associate a public ip address with the instance (eth0). false turns on attach_eni_from_lifecycle_hook: without it the instance could not reach the EC2 API to attach the ENI."
  type        = bool
  default     = true
}

variable "attach_eni_from_lifecycle_hook" {
  description = "Attach the ENI from outside the instance (ASG launch lifecycle hook -> EventBridge -> SSM Automation) instead of from runonce.sh. Always on with associate_public_ip_address = false."
  type        = bool
  default     = false
}

locals {
  // Merge the default tags and user-specified tags.
  // User-specified tags take precedence over the default.
  common_tags = merge(
    {
      Name = "nat-instance-${var.name}"
    },
    var.tags,
  )
}
