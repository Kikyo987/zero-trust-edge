variable "name" {
  type = string
}

variable "subnet_id" {
  type        = string
  description = "Public subnet if assign_public_ip=true, private subnet if NAT is in play."
}

variable "security_group_id" {
  type = string
}

variable "instance_profile_name" {
  type        = string
  description = "From the iam module. Do not create a second profile here."
}

variable "instance_type" {
  type        = string
  default     = "t4g.small"
  description = "ARM default. Use t3.small only if you must run amd64 images."
}

variable "architecture" {
  type    = string
  default = "arm64"
}

variable "ami_name_filter" {
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
  description = "Canonical Ubuntu 24.04. Switch to amd64-server-* with architecture=x86_64 if needed."
}

variable "assign_public_ip" {
  type        = bool
  default     = true
  description = "Cheap egress path. Combined with deny-all inbound SG this is still zero inbound."
}

variable "root_volume_gb" {
  type    = number
  default = 40 # Docker + k3s + Loki need more than 20 GB in practice
}

variable "key_name" {
  type        = string
  default     = ""
  description = "Leave empty. Tailscale is the login path. SSM is the break-glass."
}

variable "user_data" {
  type        = string
  description = "cloud-init. Keep secrets out of here — pull from SSM."
}

variable "detailed_monitoring" {
  type    = bool
  default = false
}

variable "enable_snapshots" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
