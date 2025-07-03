# modules/devlake/variables.tf - Variáveis do módulo DevLake

variable "aws_region" {
  description = "AWS region onde os recursos serão criados"
  type        = string
}

variable "tag_name" {
  description = "Nome da tag para todos os recursos DevLake"
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC onde os recursos serão criados"
  type        = string
}

variable "private_subnets" {
  description = "Lista de IDs das subnets privadas"
  type        = list(string)
}

variable "public_subnets" {
  description = "Lista de IDs das subnets públicas"
  type        = list(string)
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
  description = "Nome do domínio para acesso ao DevLake"
  type        = string
}

variable "certificate_arn" {
  description = "ARN do certificado SSL"
  type        = string
}