# Terraform

Modular AWS edge: VPC, security groups, a single k3s node, remote state.

```
modules/remote-state   S3 + DynamoDB + KMS (apply once per account)
modules/vpc            10.42.0.0/16, public/private /24s, NACL seatbelt, S3 endpoint
modules/security       empty ingress SG, strict egress, PMTUD ICMP
modules/compute        t4g.small, IMDSv2, encrypted gp3, optional EIP
environments/dev       wires the three runtime modules
```

## Apply order

```bash
# 1. State backend (local state is fine for this one module)
cd modules/remote-state
terraform init
terraform apply -var='project=edge-zero' \
  -var='bucket_name=edge-zero-tf-state-ACCOUNTID' \
  -var='lock_table_name=edge-zero-tf-lock'

# 2. Paste outputs into environments/dev/backend.tf

# 3. Dev edge
cd ../../environments/dev
cp terraform.tfvars.example terraform.tfvars
# edit flow_logs_bucket
terraform init
terraform plan
# Confirm: 0 NAT Gateways, 0 inbound TCP from 0.0.0.0/0
terraform apply
```

## Plan review checklist

- `aws_nat_gateway` count is 0 unless the SOW paid for it
- `aws_vpc_security_group_ingress_rule` has no `0.0.0.0/0` TCP
- `http_tokens = required` on the instance
- `assign_public_ip` matches the NAT choice (true/false, not both)
- CIDR is still `10.42.0.0/16` and does not overlap Tailscale

Do not commit `terraform.tfvars` or `*.tfstate`.
