# modules/devlake/security.tf - Security Groups

# Security Group para ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "devlake-ecs-tasks"
  description = "Security group for ECS tasks"
  vpc_id      = var.vpc_id

  # Comunicação interna entre tasks
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    self        = true
    description = "Allow traffic from other ECS tasks to DevLake API"
  }

  ingress {
    from_port   = 4000
    to_port     = 4000
    protocol    = "tcp"
    self        = true
    description = "Allow traffic from other ECS tasks to Config UI"
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    self        = true
    description = "Allow traffic from other ECS tasks to Grafana"
  }

  # Tráfego do ALB para ECS Tasks
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow traffic from ALB to DevLake API"
  }

  ingress {
    from_port       = 4000
    to_port         = 4000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow traffic from ALB to Config UI"
  }

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow traffic from ALB to Grafana"
  }

  # Saída para internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = var.tag_name
  }
}

# Security Group para ALB
resource "aws_security_group" "alb" {
  name        = "devlake-alb"
  description = "Security group for DevLake ALB"
  vpc_id      = var.vpc_id

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP traffic"
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS traffic"
  }

  # Saída para ECS Tasks
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = var.tag_name
  }
}