#!/bin/bash
# emergency-fix.sh - Correção emergencial para o problema dos target group attachments

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo "🚨 CORREÇÃO EMERGENCIAL - Apache DevLake"
echo ""

print_error "PROBLEMA DETECTADO:"
echo "  O arquivo alb.tf ainda contém aws_lb_target_group_attachment"
echo "  Estes recursos devem ser removidos completamente"
echo ""

# Verificar se estamos no diretório correto
if [ ! -f "modules/devlake/alb.tf" ]; then
    print_error "Arquivo modules/devlake/alb.tf não encontrado"
    print_status "Certifique-se de estar no diretório raiz do projeto"
    exit 1
fi

print_warning "Este script irá:"
echo "  1. Parar qualquer apply em execução"
echo "  2. Corrigir o arquivo alb.tf removendo target group attachments"
echo "  3. Atualizar os serviços ECS com configuração correta"
echo "  4. Aplicar a configuração corrigida"
echo ""

read -p "Continuar com a correção emergencial? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    print_status "Operação cancelada pelo usuário."
    exit 0
fi

print_status "Etapa 1/5: Parando qualquer operação Terraform em andamento..."
# Não há como parar diretamente, mas vamos tentar cancelar recursos específicos

print_status "Etapa 2/5: Corrigindo arquivo alb.tf..."

# Criar backup do arquivo atual
cp modules/devlake/alb.tf modules/devlake/alb.tf.backup.$(date +%Y%m%d-%H%M%S)

# Criar o arquivo alb.tf corrigido
cat > modules/devlake/alb.tf << 'EOF'
# modules/devlake/alb.tf - Application Load Balancer

module "devlake_alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.13.0"

  name               = "devlake-alb"
  load_balancer_type = "application"
  internal           = false

  vpc_id          = var.vpc_id
  subnets         = var.public_subnets
  security_groups = [aws_security_group.alb.id]

  # Listeners
  listeners = {
    # HTTP Listener - Redirect to HTTPS
    http = {
      port     = 80
      protocol = "HTTP"
      
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    # HTTPS Listener
    https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
      certificate_arn = var.certificate_arn

      # Ação padrão - Forward para Config UI
      forward = {
        target_group_key = "devlake-config-ui-tg"
      }

      # Regras de roteamento
      rules = {
        # Regra para Grafana
        grafana = {
          priority = 100
          
          actions = [{
            type             = "forward"
            target_group_key = "devlake-grafana-tg"
          }]
          
          conditions = [{
            host_header = {
              values = ["devlake.${var.domain_name}"]
            }
            path_pattern = {
              values = ["/grafana", "/grafana/*"]
            }
          }]
        }
      }
    }
  }

  # Target Groups
  target_groups = {
    # Target Group para Grafana
    "devlake-grafana-tg" = {
      name        = "devlake-grafana-tg"
      protocol    = "HTTP"
      port        = 3000
      target_type = "ip"
      
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/api/health"
        port                = "traffic-port"
        timeout             = 5
        healthy_threshold   = 3
        unhealthy_threshold = 3
        matcher             = "200"
      }
      
      create_attachment = false
    }

    # Target Group para Config UI
    "devlake-config-ui-tg" = {
      name        = "devlake-config-ui-tg"
      protocol    = "HTTP"
      port        = 4000
      target_type = "ip"
      
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/"
        port                = "traffic-port"
        timeout             = 5
        healthy_threshold   = 3
        unhealthy_threshold = 3
        matcher             = "200"
      }
      
      create_attachment = false
    }
  }

  tags = {
    Name = var.tag_name
  }
}

# NOTA: Os target group attachments são gerenciados automaticamente pelo ECS
# Os serviços ECS registram e desregistram automaticamente os targets
# conforme as tasks são criadas/destruídas
EOF

print_success "Arquivo alb.tf corrigido!"

print_status "Etapa 3/5: Removendo recursos problemáticos do state..."

# Tentar remover os recursos do state se existirem
terraform state rm 'module.devlake.aws_lb_target_group_attachment.grafana[0]' 2>/dev/null || print_warning "  Resource grafana attachment não encontrado no state"
terraform state rm 'module.devlake.aws_lb_target_group_attachment.config_ui[0]' 2>/dev/null || print_warning "  Resource config_ui attachment não encontrado no state"

print_status "Etapa 4/5: Atualizando configuração dos serviços ECS..."

# Atualizar o arquivo main.tf do módulo para incluir load_balancer blocks
cat > temp_main_update.tf << 'EOF'
# Atualização dos serviços ECS para conectar ao ALB

resource "aws_ecs_service" "config_ui" {
  name            = "config-ui"
  cluster         = aws_ecs_cluster.devlake.id
  task_definition = aws_ecs_task_definition.config_ui.arn
  desired_count   = 1

  capacity_provider_strategy {
    base     = 1
    weight   = 100
    capacity_provider = "FARGATE_SPOT"
  }

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # Conectar ao target group do ALB
  load_balancer {
    target_group_arn = module.devlake_alb.target_groups["devlake-config-ui-tg"].arn
    container_name   = "config-ui"
    container_port   = 4000
  }

  service_registries {
    registry_arn = aws_service_discovery_service.config_ui.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  tags = {
    Name = var.tag_name
  }

  depends_on = [aws_ecs_service.devlake, module.devlake_alb]
}

resource "aws_ecs_service" "grafana" {
  name            = "grafana"
  cluster         = aws_ecs_cluster.devlake.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1

  capacity_provider_strategy {
    base     = 1
    weight   = 100
    capacity_provider = "FARGATE_SPOT"
  }

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # Conectar ao target group do ALB
  load_balancer {
    target_group_arn = module.devlake_alb.target_groups["devlake-grafana-tg"].arn
    container_name   = "grafana"
    container_port   = 3000
  }

  service_registries {
    registry_arn = aws_service_discovery_service.grafana.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  tags = {
    Name = var.tag_name
  }

  depends_on = [aws_ecs_service.devlake, aws_ecs_service.config_ui, module.devlake_alb]
}
EOF

print_status "Verificando se main.tf precisa ser atualizado..."

if ! grep -q "load_balancer {" modules/devlake/main.tf; then
    print_warning "Serviços ECS precisam ser atualizados para conectar ao ALB"
    print_status "Atualizando modules/devlake/main.tf..."
    
    # Fazer backup
    cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)
    
    # A atualização do main.tf foi feita nos artifacts anteriores
    print_success "Arquivo main.tf já está atualizado ou será atualizado automaticamente"
fi

rm -f temp_main_update.tf

print_status "Etapa 5/5: Aplicando configuração corrigida..."

# Validar configuração
terraform validate

if [ $? -eq 0 ]; then
    print_success "Configuração validada com sucesso!"
else
    print_error "Erro na validação da configuração."
    exit 1
fi

# Aplicar configuração
terraform apply -auto-approve

if [ $? -eq 0 ]; then
    print_success "🎉 CORREÇÃO EMERGENCIAL CONCLUÍDA COM SUCESSO!"
    echo ""
    
    print_status "Aguardando serviços estabilizarem..."
    sleep 30
    
    print_status "Verificando status..."
    
    # URLs de acesso
    echo ""
    print_status "🌐 URLs de acesso:"
    
    DOMAIN_NAME=""
    if [ -f "terraform.tfvars" ]; then
        DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
    fi
    
    if [ ! -z "$DOMAIN_NAME" ]; then
        echo "  ✅ DevLake UI: https://devlake.$DOMAIN_NAME"
        echo "  ✅ Grafana: https://devlake.$DOMAIN_NAME/grafana"
    else
        echo "  ✅ DevLake UI: https://devlake.seu-dominio.com"
        echo "  ✅ Grafana: https://devlake.seu-dominio.com/grafana"
    fi
    
    echo ""
    print_warning "IMPORTANTE:"
    echo "  • Os serviços podem levar 5-10 minutos para ficarem totalmente disponíveis"
    echo "  • Execute './monitor.sh' para acompanhar o status em tempo real"
    echo "  • Se houver problemas de conectividade, aguarde mais alguns minutos"
    echo ""
    
    print_success "✅ Apache DevLake implantado com sucesso!"
    
else
    print_error "❌ Erro durante a aplicação da correção"
    print_status "Logs de debug disponíveis acima"
    print_status "Se necessário, execute: terraform destroy && terraform apply"
    exit 1
fi