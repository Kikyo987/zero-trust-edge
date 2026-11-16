variable "project" {
  type        = string
  description = "Short name used in KMS alias and tags."
}

variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket for state. Include account id or a random suffix."
}

variable "lock_table_name" {
  type        = string
  description = "DynamoDB table for state locking."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to every resource."
}
