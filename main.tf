module "vpc" {
  source = "./modules/vpc"


  vpc_name             = "${var.vpc_name}-${terraform.workspace}"
  vpc_cidr             = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]
  environment          = "dev"
}

#added ec2
# ---------- SECURITY GROUP ----------
resource "aws_security_group" "web" {
  name        = "${var.vpc_name}-${terraform.workspace}-web-sg"
  description = "Allow HTTP and SSH"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.vpc_name}-${terraform.workspace}-web-sg"
    Environment = var.environment
  }
}

# ---------- KEY PAIR ----------
# Only created when var.key_name is not provided
resource "tls_private_key" "web" {
  count     = var.key_name == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "web" {
  count      = var.key_name == "" ? 1 : 0
  key_name   = "${var.vpc_name}-web-key-${terraform.workspace}"
  public_key = tls_private_key.web[0].public_key_openssh
}

# ---------- AMI DATA SOURCE ----------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ---------- EC2 INSTANCE ----------
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = var.key_name != "" ? var.key_name : aws_key_pair.web[0].key_name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    echo "<h1>Hello from ${terraform.workspace} - $(hostname)</h1>" > /var/www/html/index.html
    systemctl start httpd
    systemctl enable httpd
  EOF

  tags = {
    Name        = "${var.vpc_name}-web-${terraform.workspace}"
    Environment = terraform.workspace
  }
}