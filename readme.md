# Introducing Workspaces and Remote State

## Workspaces — Multi-Environment Deployment
**What workspaces solve**
Right now you can only deploy one environment. If you want dev AND prod, you would have to copy the entire folder. Workspaces let you deploy the same code multiple times, each with its own isolated state file.

```
Same .tf files
    |
    ├── dev workspace  →  dev state  →  dev VPC + dev EC2
    └── prod workspace →  prod state →  prod VPC + prod EC2
```

### Step 1.1 — Create environment-specific variable files
 
Create **dev.tfvars** in the project root:
 
```hcl
aws_region           = "us-east-1"
vpc_name             = "demo-vpc"
vpc_cidr             = "10.0.0.0/16"
environment          = "dev"
instance_type        = "t2.micro"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24"]
availability_zones   = ["us-east-1a", "us-east-1b"]
```
 
Create **prod.tfvars** in the project root:
 
```hcl
aws_region           = "us-east-1"
vpc_name             = "demo-vpc"
vpc_cidr             = "10.1.0.0/16"
environment          = "prod"
instance_type        = "t2.small"
public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs = ["10.1.10.0/24", "10.1.20.0/24"]
availability_zones   = ["us-east-1a", "us-east-1b"]
```
 
Key differences between dev and prod:
 
| Setting | Dev | Prod |
|---|---|---|
| VPC CIDR | 10.0.0.0/16 | 10.1.0.0/16 (no overlap) |
| Instance type | t2.micro | t2.small |
| Subnet CIDRs | 10.0.x.x | 10.1.x.x |
 
### Step 1.2 — Make the code workspace-aware
Let introduce the `${terraform.workspace}` variable in our naming
Open the **root `main.tf`**. Replace the line 3,14,42 and 84  with the line commented out:
 
```hcl
module "vpc" {
  source               = "./modules/vpc"
  # vpc_name             = "${var.vpc_name}-${terraform.workspace}"
 .
 .
}
```

Now update the security group name and tags in the same file:
 
```hcl
resource "aws_security_group" "web" {
  #name        = "${var.vpc_name}-${terraform.workspace}-web-sg"
  description = "Allow HTTP and SSH"
  vpc_id      = module.vpc.vpc_id

  .
  .
  .

  tags = {
    Name        = "${var.vpc_name}-${terraform.workspace}-web-sg"
    Environment = terraform.workspace
  }
}
```
Update the EC2 instance tags and user_data:
 
```hcl
resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]
 
  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
   # echo "<h1>Hello from ${terraform.workspace} - $(hostname)</h1>" > /var/www/html/index.html
    systemctl start httpd
    systemctl enable httpd
  EOF
 
  tags = {
  #  Name        = "${var.vpc_name}-web-${terraform.workspace}"
    Environment = terraform.workspace
  }
}
```
Update the environment output in the **root `outputs.tf`**:
 
```hcl
output "environment" {
  description = "Current environment"
  value       = terraform.workspace
}
```
 
### Step 1.3 — Create workspaces and deploy dev
 
```bash
# See current workspace
terraform workspace list
# Output: * default
 
# Create and switch to dev
terraform workspace new dev
terraform workspace new prod

# Output: Created and switched to workspace "dev"!

terraform workspace select dev

# Deploy dev
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars

# Check current workspace
terraform workspace show
 
# See resources in current workspace
terraform state list
 
# See outputs
terraform output
 
# Destroy only dev
terraform workspace select dev
terraform destroy -var-file=dev.tfvars

# Delete workspace (must have no resources)
terraform workspace select default
terraform workspace delete dev
```


## PHASE 2: Remote State with S3 and DynamoDB
 
### What remote state solves
 
With local state:
- State files live on your machine only
- If your machine dies, you lose track of all infrastructure
- Two people can run apply at the same time and corrupt the state
- No encryption, no versioning, no backup
 
With remote state:
- State is stored in S3 (shared, encrypted, versioned)
- DynamoDB provides locking so two people cannot apply simultaneously
- Any team member or CI/CD pipeline can access the same state
 
### Step 2.1 — Create the S3 bucket and DynamoDB table
 
Run these commands once. These resources are NOT managed by your Terraform project — they are the backend that stores your project's state.
 
```bash
# Create the S3 bucket (pick a unique name)
aws s3api create-bucket \
  --bucket demo-vpc-tfstate-YOURNAME \
  --region us-east-1
 
# Enable versioning
aws s3api put-bucket-versioning \
  --bucket demo-vpc-tfstate-YOURNAME \
  --versioning-configuration Status=Enabled
 
# Enable encryption
aws s3api put-bucket-encryption \
  --bucket demo-vpc-tfstate-YOURNAME \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'
 
# Create DynamoDB table for locking
aws dynamodb create-table \
  --table-name demo-vpc-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```
 
Replace `YOURNAME` with something unique to you.
 
### Step 2.2 — Add backend configuration
 
Create **backend.tf** in the project root:
 
```hcl
terraform {
  backend "s3" {
    bucket         = "demo-vpc-tfstate-YOURNAME"
    key            = "vpc-module/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "demo-vpc-terraform-locks"
    encrypt        = true
  }
}
```
 
Replace the bucket name with the one you created.
 
| Argument | What it does |
|---|---|
| bucket | S3 bucket where state is stored |
| key | Path inside the bucket for the state file |
| region | AWS region of the bucket |
| dynamodb_table | Table used for state locking |
| encrypt | Encrypts state at rest |
 
### Step 2.3 — Migrate local state to remote
 
```bash
terraform init -migrate-state
```
 
Terraform will detect the backend change and ask:
 
```
Do you want to copy existing state to the new backend?
  Enter a value: yes
```
 
Type `yes`. Your local state is now in S2.
 
If you have resources deployed in workspaces (dev/prod), switch to each workspace and run `terraform init -migrate-state` for each one:
 
```bash
terraform workspace select dev
terraform init -migrate-state
 
terraform workspace select prod
terraform init -migrate-state
```
 
### Step 2.4 — Verify
 
```bash
# Confirm state still works
terraform state list
 
# Check S3 for the state file
aws s3 ls s3://demo-vpc-tfstate-YOURNAME/vpc-module/
```
 
With workspaces, each workspace stores state at a separate key:
- Default: `vpc-module/terraform.tfstate`
- Dev: `vpc-module/env:/dev/terraform.tfstate`
- Prod: `vpc-module/env:/prod/terraform.tfstate`
 
### Step 2.5 — Test locking
 
Open two terminals. In both, navigate to the project folder and select the same workspace.
 
Terminal 1:
 
```bash
terraform plan -var-file=dev.tfvars
```
 
Terminal 2 (while terminal 1 is running):
 
```bash
terraform plan -var-file=dev.tfvars
```
 
Terminal 2 will fail with:
 
```
Error: Error acquiring the state lock
 
Terraform acquires a state lock to protect the state from being
written by multiple users at the same time.
```
 
This is the correct behavior. DynamoDB is preventing concurrent access.
 
### Step 2.6 — Remove local state files
 
State is now in S2. Local copies are no longer needed:
 
```bash
rm -f terraform.tfstate
rm -f terraform.tfstate.backup
rm -rf terraform.tfstate.d/
```

## Destroy everything:
 
```bash
terraform workspace select prod
terraform destroy -var-file=prod.tfvars
terraform workspace select dev
terraform destroy -var-file=dev.tfvars
terraform workspace select default
terraform workspace delete dev
terraform workspace delete prod
```

## Delete all versions and markers:

```bash
aws s3api list-object-versions \
  --bucket demo-vpc-tfstate-YOURNAME \
  --region us-east-1 \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  --output json > versions.json

aws s3api delete-objects \
  --bucket demo-vpc-tfstate-YOURNAME \
  --region us-east-1 \
  --delete file://versions.json
```

```bash
aws s3api list-object-versions \
  --bucket demo-vpc-tfstate-YOURNAME \
  --region us-east-1 \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
  --output json > delete-markers.json

aws s3api delete-objects \
  --bucket demo-vpc-tfstate-YOURNAME \
  --region us-east-1 \
  --delete file://delete-markers.json
```
 
# Optional: remove backend resources
aws s3 rb s3://demo-vpc-tfstate-YOURNAME --force
aws dynamodb delete-table --table-name demo-vpc-terraform-locks
rm versions.json delete-markers.json
```

---
 
## Command Reference
 
| Command | What it does |
|---------|-------------|
| `terraform workspace new dev` | Create a new workspace called dev |
| `terraform workspace select dev` | Switch to the dev workspace |
| `terraform workspace list` | List all workspaces |
| `terraform workspace show` | Show the current workspace |
| `terraform workspace delete dev` | Delete the dev workspace |
| `terraform plan -var-file=dev.tfvars` | Plan using dev-specific variables |
| `terraform apply -var-file=dev.tfvars` | Apply using dev-specific variables |
| `terraform init -migrate-state` | Move local state to a new remote backend |
| `terraform state list` | List all resources in the current workspace |
| `terraform output` | Show output values |