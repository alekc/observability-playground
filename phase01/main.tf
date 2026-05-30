###############################################################################
# Data sources
###############################################################################

# Pin to a single availability zone so both instances land together and we
# avoid cross-AZ data transfer charges for the metrics / logs traffic.
data "aws_availability_zones" "available" {
  state = "available"
}

# Canonical's Ubuntu 26.04 LTS AMI, latest build for the region. The codename
# is left as a wildcard so this keeps working without hardcoding it, and the
# hvm-ssd* glob covers both the gp2 and gp3 image families.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  az = data.aws_availability_zones.available.names[0]
}

###############################################################################
# Network
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# Security groups
#
# appserver (application): public HTTP + SSH.
# observer (observability): public Grafana + SSH, plus Mimir / Loki reachable
# only from appserver's security group, not the whole internet.
###############################################################################

resource "aws_security_group" "appserver" {
  name        = "${var.project_name}-appserver"
  description = "Application server: HTTP from anywhere, SSH from allowed CIDR."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP (Caddy: frontend + backend)"
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
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-appserver"
    Project = var.project_name
  }
}

resource "aws_security_group" "observer" {
  name        = "${var.project_name}-observer"
  description = "Observability server: Grafana + SSH public, Mimir/Loki from appserver only."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description     = "Mimir remote_write from appserver"
    from_port       = 9009
    to_port         = 9009
    protocol        = "tcp"
    security_groups = [aws_security_group.appserver.id]
  }

  ingress {
    description     = "Loki push from appserver"
    from_port       = 3100
    to_port         = 3100
    protocol        = "tcp"
    security_groups = [aws_security_group.appserver.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-observer"
    Project = var.project_name
  }
}

###############################################################################
# SSH key pair
#
# Generated in-OpenTofu so the whole stack is self-contained. The private key
# is written to project-key.pem with 0600 perms for immediate scp / ssh use.
###############################################################################

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = {
    Project = var.project_name
  }
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/project-key.pem"
  file_permission = "0600"
}

###############################################################################
# EC2 instances
###############################################################################

resource "aws_instance" "appserver" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.appserver_instance_type
  availability_zone           = local.az
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.appserver.id]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = true
  user_data                   = file("${path.module}/user_data.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-appserver"
    Role    = "application"
    Project = var.project_name
  }
}

resource "aws_instance" "observer" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.observer_instance_type
  availability_zone           = local.az
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.observer.id]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = true
  user_data                   = file("${path.module}/user_data.sh")

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-observer"
    Role    = "observability"
    Project = var.project_name
  }
}
