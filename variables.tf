# variables.tf - Variáveis do Terraform

variable "aws_region" {
  description = "AWS region onde os recursos serão criados"
  type        = string
  default     = "us-east-1"
}

variable "tag_name" {
  description = "Nome da tag para todos os recursos DevLake (para monitoramento de custos)"
  type        = string
  default     = "devlake"
}

variable "vpc_cidr" {
  description = "CIDR block para a VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks para as subnets públicas"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks para as subnets privadas"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

variable "db_password" {
  description = "Senha para o banco de dados MySQL do DevLake"
  type        = string
  sensitive   = true
}

variable "encryption_secret" {
  description = "Chave de criptografia para o DevLake"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Nome do domínio para acesso ao DevLake (ex: meusite.com)"
  type        = string
}

variable "create_route53_zone" {
  description = "Se deve criar uma nova zona no Route53 ou usar uma existente"
  type        = bool
  default     = false
}