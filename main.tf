# main.tf - Arquivo principal do Terraform para Apache DevLake (CORRIGIDO)

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.91.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources para AZs disponíveis
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC
resource "aws_vpc" "devlake_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.tag_name}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "devlake_igw" {
  vpc_id = aws_vpc.devlake_vpc.id

  tags = {
    Name = "${var.tag_name}-igw"
  }
}

# Subnets Públicas (para ALB)
resource "aws_subnet" "public_subnets" {
  count = 2

  vpc_id                  = aws_vpc.devlake_vpc.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.tag_name}-public-subnet-${count.index + 1}"
  }
}

# Subnets Privadas (para ECS Tasks)
resource "aws_subnet" "private_subnets" {
  count = 2

  vpc_id            = aws_vpc.devlake_vpc.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.tag_name}-private-subnet-${count.index + 1}"
  }
}

# Elastic IPs para NAT Gateways
resource "aws_eip" "nat_eips" {
  count = 2

  domain     = "vpc"
  depends_on = [aws_internet_gateway.devlake_igw]

  tags = {
    Name = "${var.tag_name}-nat-eip-${count.index + 1}"
  }
}

# NAT Gateways
resource "aws_nat_gateway" "nat_gateways" {
  count = 2

  allocation_id = aws_eip.nat_eips[count.index].id
  subnet_id     = aws_subnet.public_subnets[count.index].id

  tags = {
    Name = "${var.tag_name}-nat-gateway-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.devlake_igw]
}

# Route Table para Subnets Públicas
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.devlake_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.devlake_igw.id
  }

  tags = {
    Name = "${var.tag_name}-public-rt"
  }
}

# Route Tables para Subnets Privadas
resource "aws_route_table" "private_rt" {
  count = 2

  vpc_id = aws_vpc.devlake_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateways[count.index].id
  }

  tags = {
    Name = "${var.tag_name}-private-rt-${count.index + 1}"
  }
}

# Associações das Route Tables
resource "aws_route_table_association" "public_rta" {
  count = 2

  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_rta" {
  count = 2

  subnet_id      = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_rt[count.index].id
}

# Hosted Zone do Route53 (se não existir)
resource "aws_route53_zone" "devlake_zone" {
  count = var.create_route53_zone ? 1 : 0
  name  = var.domain_name

  tags = {
    Name = var.tag_name
  }
}

# Data source para zona existente
data "aws_route53_zone" "existing_zone" {
  count = var.create_route53_zone ? 0 : 1
  name  = var.domain_name
}

# Certificado SSL
resource "aws_acm_certificate" "devlake_cert" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  subject_alternative_names = [var.domain_name]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.tag_name
  }
}

# Validação do certificado
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.devlake_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = var.create_route53_zone ? aws_route53_zone.devlake_zone[0].zone_id : data.aws_route53_zone.existing_zone[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}

resource "aws_acm_certificate_validation" "devlake_cert" {
  certificate_arn         = aws_acm_certificate.devlake_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Módulo DevLake
module "devlake" {
  source = "./modules/devlake"

  aws_region        = var.aws_region
  tag_name          = var.tag_name
  vpc_id            = aws_vpc.devlake_vpc.id
  private_subnets   = aws_subnet.private_subnets[*].id
  public_subnets    = aws_subnet.public_subnets[*].id
  db_password       = var.db_password
  encryption_secret = var.encryption_secret
  domain_name       = var.domain_name
  certificate_arn   = aws_acm_certificate_validation.devlake_cert.certificate_arn
}

# Registro DNS para DevLake
resource "aws_route53_record" "devlake" {
  zone_id = var.create_route53_zone ? aws_route53_zone.devlake_zone[0].zone_id : data.aws_route53_zone.existing_zone[0].zone_id
  name    = "devlake.${var.domain_name}"
  type    = "A"

  alias {
    name                   = module.devlake.alb_dns_name
    zone_id                = module.devlake.alb_zone_id
    evaluate_target_health = true
  }
}