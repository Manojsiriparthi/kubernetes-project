param(
  [string]$Region = "us-east-1",
  [string]$BucketPrefix = "school-demo-terraform-state"
)

$ErrorActionPreference = "Stop"

$identityJson = & aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
  throw "AWS identity lookup failed. Configure AWS credentials before bootstrapping Terraform state."
}
$accountId = ($identityJson | ConvertFrom-Json).Account
$bucketName = "$BucketPrefix-$accountId-$Region"

if ($Region -eq "us-east-1") {
  & aws s3api create-bucket --bucket $bucketName --region $Region
} else {
  & aws s3api create-bucket --bucket $bucketName --region $Region `
    --create-bucket-configuration "LocationConstraint=$Region"
}
if ($LASTEXITCODE -ne 0) {
  & aws s3api head-bucket --bucket $bucketName 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create or access state bucket $bucketName. Check bucket name availability and AWS permissions."
  }
}

& aws s3api put-public-access-block --bucket $bucketName `
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
if ($LASTEXITCODE -ne 0) {
  throw "Could not block public access to state bucket $bucketName."
}

& aws s3api put-bucket-versioning --bucket $bucketName `
  --versioning-configuration Status=Enabled
if ($LASTEXITCODE -ne 0) {
  throw "Could not enable versioning on state bucket $bucketName."
}

& aws s3api put-bucket-encryption --bucket $bucketName `
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
if ($LASTEXITCODE -ne 0) {
  throw "Could not enable encryption on state bucket $bucketName."
}

$bucketPolicy = @{
  Version = "2012-10-17"
  Statement = @(@{
    Sid       = "DenyInsecureTransport"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Resource  = @("arn:aws:s3:::$bucketName", "arn:aws:s3:::$bucketName/*")
    Condition = @{ Bool = @{ "aws:SecureTransport" = "false" } }
  })
} | ConvertTo-Json -Depth 8 -Compress
& aws s3api put-bucket-policy --bucket $bucketName --policy $bucketPolicy
if ($LASTEXITCODE -ne 0) {
  throw "Could not require TLS for state bucket $bucketName."
}

$backendConfig = @"
bucket       = "$bucketName"
key          = "school-demo/infra/terraform.tfstate"
region       = "$Region"
encrypt      = true
use_lockfile = true
"@
$backendPath = Join-Path $PSScriptRoot "backend.hcl"
[System.IO.File]::WriteAllText($backendPath, $backendConfig, [System.Text.UTF8Encoding]::new($false))
Write-Host "Created encrypted, versioned Terraform state bucket: $bucketName"
Write-Host "Next run: terraform -chdir=infra init -backend-config=backend.hcl"
