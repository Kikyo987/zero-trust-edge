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
  description = "Must stay disjoint from Tailscale 100.64.0.0/10, pods 10.43.0.0/16, services 10.44.0.0/16."
}

variable "cluster_cidr" {
  type        = string
  default     = "10.43.0.0/16"
  description = "k3s pod CIDR. Routed only inside the cluster."
}

variable "service_cidr" {
  type        = string
  default     = "10.44.0.0/16"
  description = "k3s ClusterIP CIDR. Never advertised to the VPC."
}

variable "enable_nat_gateway" {
  type        = bool
  default     = false
  description = "Leave false unless policy forbids public IPs on compute. See docs/finops.md."
}

variable "assign_public_ip" {
  type        = bool
  default     = true
  description = "Public IP + deny-all inbound SG = cheap egress, zero inbound."
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
  default = 40
}

variable "flow_logs_bucket" {
  type        = string
  description = "Globally unique S3 name for VPC flow logs."
}

variable "k3s_version" {
  type        = string
  default     = "v1.31.4+k3s1"
  description = "Pinned. Do not use 'latest' in production."
}

variable "app_image" {
  type    = string
  default = "ghcr.io/kikyo987/edge-echo:dev"
}

variable "app_hostname" {
  type        = string
  default     = "app.example.com"
  description = "Ingress host. DNS for this name is a Cloudflare Tunnel CNAME, not the node IP."
}

variable "manifests_repo" {
  type        = string
  default     = "https://github.com/Kikyo987/zero-trust-edge.git"
  description = "cloud-init clones k3s/manifests from here."
}
