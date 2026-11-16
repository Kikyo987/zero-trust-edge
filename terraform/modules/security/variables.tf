variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "egress_unrestricted" {
  type        = bool
  default     = false
  description = "If true, allow all egress. Bootstrap only. Must be false at handover."
}

variable "tags" {
  type    = map(string)
  default = {}
}
