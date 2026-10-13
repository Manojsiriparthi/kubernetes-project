#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BUCKET_PREFIX="${TF_STATE_BUCKET_PREFIX:-school-demo-terraform-state}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}-${REGION}"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

POLICY="$(printf \
  '{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}' \
  "$BUCKET" "$BUCKET")"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"

cat > "$(dirname "$0")/backend.hcl" <<EOF
bucket       = "$BUCKET"
key          = "school-demo/infra/terraform.tfstate"
region       = "$REGION"
encrypt      = true
use_lockfile = true
EOF

printf 'Created encrypted, versioned Terraform state bucket: %s\n' "$BUCKET"
printf 'Next run: terraform -chdir=infra init -backend-config=backend.hcl\n'
