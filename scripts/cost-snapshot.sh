#!/usr/bin/env bash
# Idle-resource and posture hunt. Read-only AWS APIs.
# Exit 1 if a NAT Gateway exists or a SG allows 0.0.0.0/0 inbound TCP
# (those are the two regressions that hurt small teams most).
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_PAGER=""
FAIL=0

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 2; }; }
need aws
need jq

echo "== region ${REGION} =="
echo

echo "-- Elastic IPs not associated --"
UNASSOC="$(aws ec2 describe-addresses --region "${REGION}" \
  --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId]' --output text)"
if [[ -z "${UNASSOC}" ]]; then
  echo "  none"
else
  echo "${UNASSOC}" | sed 's/^/  /'
  FAIL=1
fi

echo
echo "-- gp3/gp2 volumes available (detached) --"
aws ec2 describe-volumes --region "${REGION}" \
  --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,VolumeType]' --output text | sed 's/^/  /' || true

echo
echo "-- NAT Gateways --"
NATS="$(aws ec2 describe-nat-gateways --region "${REGION}" \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].[NatGatewayId,VpcId,SubnetId]' --output text)"
if [[ -z "${NATS}" ]]; then
  echo "  none (good — see docs/finops.md)"
else
  echo "${NATS}" | sed 's/^/  /'
  echo "  NAT Gateway present. Confirm this is a policy requirement."
  FAIL=1
fi

echo
echo "-- Security groups with 0.0.0.0/0 inbound TCP --"
OPEN="$(aws ec2 describe-security-groups --region "${REGION}" --output json \
  | jq -r '.SecurityGroups[]
      | . as $sg
      | .IpPermissions[]?
      | select(.IpProtocol=="tcp" or .IpProtocol=="-1")
      | .IpRanges[]?
      | select(.CidrIp=="0.0.0.0/0")
      | "\($sg.GroupId)\t\($sg.GroupName)\t\($sg.VpcId)"' \
  | sort -u)"
if [[ -z "${OPEN}" ]]; then
  echo "  none (good)"
else
  echo "${OPEN}" | sed 's/^/  /'
  echo "  public inbound TCP is a zero-trust regression."
  FAIL=1
fi

echo
echo "-- Load balancers --"
aws elbv2 describe-load-balancers --region "${REGION}" \
  --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,State.Code]' --output text 2>/dev/null | sed 's/^/  /' \
  || echo "  none"

echo
echo "-- unassociated / unused ENIs --"
aws ec2 describe-network-interfaces --region "${REGION}" \
  --filters Name=status,Values=available \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text | sed 's/^/  /' || true

echo
if [[ "${FAIL}" -ne 0 ]]; then
  echo "cost/posture snapshot found regressions"
  exit 1
fi
echo "cost/posture snapshot clean"
