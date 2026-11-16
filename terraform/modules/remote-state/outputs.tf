output "bucket_name" {
  value       = aws_s3_bucket.state.bucket
  description = "State bucket. Paste into environments/*/backend.tf."
}

output "lock_table_name" {
  value       = aws_dynamodb_table.lock.name
  description = "DynamoDB lock table name."
}

output "kms_key_arn" {
  value       = aws_kms_key.state.arn
  description = "KMS key encrypting state objects and the lock table."
}

output "backend_hcl" {
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.bucket}"
        key            = "CHANGE-ME/terraform.tfstate"
        region         = "CHANGE-ME"
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
        encrypt        = true
        kms_key_id     = "${aws_kms_key.state.arn}"
      }
    }
  EOT
  description = "Copy-paste backend block. Fill region and the state key."
}
