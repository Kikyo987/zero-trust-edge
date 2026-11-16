variable "name" {
  type        = string
  description = "Prefix for the role and instance profile."
}

variable "project" {
  type        = string
  description = "SSM parameter path prefix, e.g. edge-zero → /edge-zero/*"
}

variable "tags" {
  type    = map(string)
  default = {}
}
