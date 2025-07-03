
# outputs.tf - Outputs do Terraform

output "vpc_id" {
  description = "ID da VPC criada"
  value       = aws_vpc.devlake_vpc.id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas"
  value       = aws_subnet.private_subnets[*].id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas"
  value       = aws_subnet.public_subnets[*].id
}

output "devlake_url" {
  description = "URL para acessar o DevLake"
  value       = "https://devlake.${var.domain_name}"
}

output "grafana_url" {
  description = "URL para acessar o Grafana"
  value       = "https://devlake.${var.domain_name}/grafana"
}

output "alb_dns_name" {
  description = "DNS name do Application Load Balancer"
  value       = module.devlake.alb_dns_name
}

output "rds_endpoint" {
  description = "Endpoint do banco de dados RDS"
  value       = module.devlake.rds_endpoint
  sensitive   = true
}

output "certificate_arn" {
  description = "ARN do certificado SSL"
  value       = aws_acm_certificate.devlake_cert.arn
}

output "route53_zone_id" {
  description = "Zone ID do Route53"
  value       = var.create_route53_zone ? aws_route53_zone.devlake_zone[0].zone_id : data.aws_route53_zone.existing_zone[0].zone_id
}
