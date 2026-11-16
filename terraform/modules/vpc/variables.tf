variable "name" {
  type        = string
  description = "Prefix for resource names."
}

variable "cidr" {
  type        = string
  description = "VPC CIDR. Default 10.42.0.0/16 avoids 10.0/16 and Tailscale CGNAT."
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr))
    error_message = "cidr must be a valid IPv4 prefix."
  }
  validation {
    condition     = !startswith(var.cidr, "100.64.") && !startswith(var.cidr, "100.96.")
    error_message = "Do not use Tailscale CGNAT (100.64.0.0/10) or WARP (100.96.0.0/12) as the VPC CIDR."
  }
}

variable "az_count" {
  type        = number
  default     = 2
  description = "How many AZs to carve. 2 keeps HA possible without paying for three NAT GWs later."
}

variable "region" {
  type        = string
  description = "AWS region, used for the S3 gateway endpoint service name."
}

variable "enable_nat_gateway" {
  type        = bool
  default     = false
  description = "Create a NAT Gateway per AZ. Default false — see docs/finops.md."
}

variable "jumbo_frames" {
  type        = bool
  default     = false
  description = "Must stay false while overlays (tunnel, Tailscale, flannel) are in use."

  validation {
    condition     = var.jumbo_frames == false
    error_message = "Jumbo frames are incompatible with Cloudflare Tunnel and Tailscale. Keep mtu 1500 (see docs/postmortem-example.md)."
  }
}

variable "enable_flow_logs" {
  type        = bool
  default     = true
  description = "VPC flow logs to S3 parquet. Cheap. Do not send these to CloudWatch Logs."
}

variable "flow_logs_bucket" {
  type        = string
  default     = ""
  description = "Bucket name for flow logs. Required when enable_flow_logs is true."
}

variable "tags" {
  type    = map(string)
  default = {}
}
