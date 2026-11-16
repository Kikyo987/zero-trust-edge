# Remote state. Fill bucket / region / table after applying
# terraform/modules/remote-state once. Until then, `terraform init
# -backend=false` works for a local experiment — never for a client.

terraform {
  backend "s3" {
    bucket         = "CHANGE-ME-edge-zero-tf-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "CHANGE-ME-edge-zero-tf-lock"
    encrypt        = true
  }
}
