variable "project" {
  type    = string
  default = "edge-zero"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.42.0.0/16"
  description = "Must stay disjoint from Tailscale 100.64.0.0/10 and office RFC1918."
}

variable "enable_nat_gateway" {
  type        = bool
  default     = false
  description = "Leave false unless policy forbids public IPs on compute. See docs/finops.md."
}

variable "assign_public_ip" {
  type        = bool
  default     = true
  description = "Public IP + empty SG = cheap egress, zero inbound."
}

variable "egress_unrestricted" {
  type        = bool
  default     = false
  description = "Must be false at handover."
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "architecture" {
  type    = string
  default = "arm64"
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "flow_logs_bucket" {
  type        = string
  description = "Globally unique S3 name for VPC flow logs."
}
