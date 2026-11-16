# Terraform

Modular AWS edge: VPC, least-privilege security groups, IAM, a single
k3s node, remote state. cloud-init installs Docker and k3s.

```
modules/remote-state   S3 + DynamoDB + KMS (apply once per account)
modules/vpc            10.42.0.0/16, public/private /24s, NACL, S3 endpoint
modules/security       no public TCP inbound; k3s ports sourced from self
modules/iam            instance role, SSM, ECR, /<project>/* parameters
modules/compute        t4g.small, IMDSv2, encrypted gp3, cloud-init
environments/dev       wires the four runtime modules
```

## CIDR plan

| Name | CIDR | Where it is routed |
| --- | --- | --- |
| VPC | `10.42.0.0/16` | AWS |
| public AZ-a / AZ-b | `10.42.0.0/24`, `10.42.1.0/24` | IGW (egress) |
| private AZ-a / AZ-b | `10.42.10.0/24`, `10.42.11.0/24` | local + optional NAT |
| pods | `10.43.0.0/16` | k3s only |
| services | `10.44.0.0/16` | ClusterIP, never the VPC |
| Tailscale | `100.64.0.0/10` | overlay — never allocate this as a VPC |

## Security group posture

| Port | Direction | Source / dest | Why |
| --- | --- | --- | --- |
| 22 / 80 / 443 | inbound | — | **closed**. Tunnel outbound, SSH on Tailscale |
| 6443 tcp | inbound | same SG | kube-apiserver |
| 10250 tcp | inbound | same SG | kubelet |
| 8472 udp | inbound | same SG | flannel VXLAN |
| 51820 udp | inbound | same SG | flannel WireGuard |
| ICMP type 3 | inbound | `0.0.0.0/0` | PMTUD |
| 443 tcp/udp | outbound | `0.0.0.0/0` | tunnel, GHCR, SSM |
| 53, 123, 41641, 3478 | outbound | `0.0.0.0/0` | DNS, NTP, Tailscale |

## Apply order

```bash
# 1. State backend (once per account)
cd modules/remote-state
terraform init
terraform apply \
  -var='project=edge-zero' \
  -var='bucket_name=edge-zero-tf-state-ACCOUNTID' \
  -var='lock_table_name=edge-zero-tf-lock'

# 2. Paste bucket / table / region into environments/dev/backend.tf

# 3. Dev edge
cd ../../environments/dev
cp terraform.tfvars.example terraform.tfvars
# set flow_logs_bucket
terraform init
terraform plan
# Confirm: 0 NAT Gateways, 0 inbound TCP from 0.0.0.0/0, 6443 from self
terraform apply
```

Optional after apply:

```bash
aws ssm put-parameter \
  --name /edge-zero/tailscale-auth-key \
  --type SecureString \
  --value "tskey-auth-..."
```

cloud-init will join the tailnet on the next boot (or immediately if the
parameter exists before first boot).

## Plan review checklist

- `aws_nat_gateway` count is 0 unless the SOW paid for it
- no `0.0.0.0/0` TCP ingress on the node SG
- 6443 / 10250 / 8472 / 51820 sourced from the node SG, not the world
- `http_tokens = required`
- `assign_public_ip` matches the NAT choice
- CIDR is still `10.42.0.0/16` and does not overlap Tailscale

Do not commit `terraform.tfvars` or `*.tfstate`.
