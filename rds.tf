# modules/devlake/rds.tf - Configuração do RDS MySQL

module "devlake-rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10.0"

  identifier = "devlake-db"

  engine               = "mysql"
  engine_version       = "8.0"
  major_engine_version = "8.0"
  family               = "mysql8.0"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20

  manage_master_user_password = false
  db_name                     = "devlake"
  username                    = "devlake"
  password                    = var.db_password
  port                        = 3306

  create_db_subnet_group = true
  subnet_ids             = var.private_subnets
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true

  # CloudWatch Logs
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
  create_cloudwatch_log_group     = true

  # Backup
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"

  # Encryption
  storage_encrypted = true

  # Performance Insights
  performance_insights_enabled = false

  tags = {
    Name = var.tag_name
  }
}

# Security Group para RDS
resource "aws_security_group" "rds" {
  name        = "devlake-rds"
  description = "Security group for DevLake RDS"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.tag_name
  }

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
    description     = "Allow MySQL access from ECS tasks"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
}