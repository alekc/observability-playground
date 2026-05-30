variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to reach SSH (port 22) on both servers. Lock this down to your office / VPN range in any real environment."
  type        = string
  default     = "0.0.0.0/0"
}

variable "project_name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "project-observability"
}

variable "appserver_instance_type" {
  description = "Instance type for the application server."
  type        = string
  default     = "t3.medium"
}

variable "observer_instance_type" {
  description = "Instance type for the observability server (Mimir + Loki + Grafana)."
  type        = string
  default     = "t3.large"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the single public subnet."
  type        = string
  default     = "10.0.1.0/24"
}
