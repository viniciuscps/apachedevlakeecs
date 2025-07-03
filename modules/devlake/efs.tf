# modules/devlake/efs.tf - Configuração do EFS para Grafana

# Sistema de arquivos EFS para Grafana
resource "aws_efs_file_system" "grafana" {
  creation_token = "grafana-storage"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  performance_mode = "generalPurpose"
  throughput_mode  = "provisioned"
  provisioned_throughput_in_mibps = 1

  tags = {
    Name = var.tag_name
  }
}

# Access Point para Grafana
resource "aws_efs_access_point" "grafana" {
  file_system_id = aws_efs_file_system.grafana.id

  posix_user {
    gid = 472
    uid = 472
  }

  root_directory {
    path = "/var/lib/grafana"
    
    creation_info {
      owner_gid   = 472
      owner_uid   = 472
      permissions = "755"
    }
  }

  tags = {
    Name = var.tag_name
  }
}

# Mount Targets para cada subnet privada
resource "aws_efs_mount_target" "grafana" {
  count = length(var.private_subnets)

  file_system_id  = aws_efs_file_system.grafana.id
  subnet_id       = var.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# Security Group para EFS
resource "aws_security_group" "efs" {
  name        = "grafana-efs"
  description = "Security group for Grafana EFS mount targets"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.tag_name
  }

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
    description     = "Allow NFS access from ECS tasks"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
}