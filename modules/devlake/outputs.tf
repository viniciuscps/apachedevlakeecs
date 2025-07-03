# modules/devlake/outputs.tf - Outputs do módulo DevLake

output "ecs_cluster_id" {
  description = "ID do cluster ECS"
  value       = aws_ecs_cluster.devlake.id
}

output "ecs_cluster_name" {
  description = "Nome do cluster ECS"
  value       = aws_ecs_cluster.devlake.name
}

output "alb_dns_name" {
  description = "DNS name do Application Load Balancer"
  value       = module.devlake_alb.dns_name
}

output "alb_zone_id" {
  description = "Zone ID do Application Load Balancer"
  value       = module.devlake_alb.zone_id
}

output "rds_endpoint" {
  description = "Endpoint do banco de dados RDS"
  value       = module.devlake-rds.db_instance_endpoint
  sensitive   = true
}

output "rds_port" {
  description = "Porta do banco de dados RDS"
  value       = module.devlake-rds.db_instance_port
}

output "efs_id" {
  description = "ID do sistema de arquivos EFS do Grafana"
  value       = aws_efs_file_system.grafana.id
}

output "service_discovery_namespace_id" {
  description = "ID do namespace de service discovery"
  value       = aws_service_discovery_private_dns_namespace.devlake.id
}

output "devlake_service_name" {
  description = "Nome do serviço DevLake no ECS"
  value       = aws_ecs_service.devlake.name
}

output "config_ui_service_name" {
  description = "Nome do serviço Config UI no ECS"
  value       = aws_ecs_service.config_ui.name
}

output "grafana_service_name" {
  description = "Nome do serviço Grafana no ECS"
  value       = aws_ecs_service.grafana.name
}