# modules/devlake/logs.tf - CloudWatch Logs

# Log Group para DevLake
resource "aws_cloudwatch_log_group" "devlake" {
  name              = "/ecs/devlake"
  retention_in_days = 30

  tags = {
    Name = var.tag_name
  }
}

# Log Group para Config UI
resource "aws_cloudwatch_log_group" "config_ui" {
  name              = "/ecs/config-ui"
  retention_in_days = 30

  tags = {
    Name = var.tag_name
  }
}

# Log Group para Grafana
resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/grafana"
  retention_in_days = 30

  tags = {
    Name = var.tag_name
  }
}