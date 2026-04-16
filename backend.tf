terraform {
  backend "s3" {
    bucket         = "demo-vpc-tfstate-YOURNAME"
    key            = "vpc-module/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "demo-vpc-terraform-locks"
    encrypt        = true
  }
}