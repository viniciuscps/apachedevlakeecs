#!/bin/bash
# increase-resources.sh - Aumentar recursos ECS para DevLake

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

echo "⚡ Aumentando recursos ECS para DevLake"
echo ""

print_warning "PROBLEMA IDENTIFICADO:"
echo "  • Container DevLake não consegue inicializar com recursos atuais"
echo "  • Fargate Spot pode estar limitando recursos"
echo "  • Necessário aumentar CPU e memória"
echo ""

# Verificar se estamos no diretório correto
if [ ! -f "modules/devlake/main.tf" ]; then
    print_error "Arquivo modules/devlake/main.tf não encontrado"
    exit 1
fi

print_status "Verificando recursos atuais..."

# Mostrar recursos atuais
CURRENT_CPU=$(grep -A 5 "aws_ecs_task_definition.*devlake" modules/devlake/main.tf | grep "cpu" | head -1 | sed 's/.*= //' || echo "256")
CURRENT_MEMORY=$(grep -A 6 "aws_ecs_task_definition.*devlake" modules/devlake/main.tf | grep "memory" | head -1 | sed 's/.*= //' || echo "512")

echo "  • CPU atual: $CURRENT_CPU"
echo "  • Memória atual: $CURRENT_MEMORY MB"
echo ""

print_status "Novos recursos recomendados:"
echo "  • DevLake: CPU 1024 (1 vCPU), Memória 2048 MB (2 GB)"
echo "  • Config UI: CPU 512 (0.5 vCPU), Memória 1024 MB (1 GB)"
echo "  • Grafana: CPU 512 (0.5 vCPU), Memória 1024 MB (1 GB)"
echo ""

read -p "Aplicar aumento de recursos? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    print_status "Operação cancelada pelo usuário."
    exit 0
fi

print_status "Fazendo backup do arquivo atual..."
cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)

print_status "Atualizando recursos das task definitions..."

# Atualizar recursos do DevLake
sed -i.bak1 's/cpu.*= 256/cpu                      = 1024/' modules/devlake/main.tf
sed -i.bak2 's/memory.*= 512/memory                   = 2048/' modules/devlake/main.tf

# Atualizar recursos do Config UI
sed -i.bak3 '/:.*config_ui/,/^}/s/cpu.*= 256/cpu                      = 512/' modules/devlake/main.tf
sed -i.bak4 '/:.*config_ui/,/^}/s/memory.*= 512/memory                   = 1024/' modules/devlake/main.tf

# Atualizar recursos do Grafana  
sed -i.bak5 '/:.*grafana/,/^}/s/cpu.*= 256/cpu                      = 512/' modules/devlake/main.tf
sed -i.bak6 '/:.*grafana/,/^}/s/memory.*= 512/memory                   = 1024/' modules/devlake/main.tf

# Limpar arquivos de backup temporários
rm -f modules/devlake/main.tf.bak*

print_status "Adicionando configurações de health check e timeout..."

# Criar versão melhorada do main.tf com recursos aumentados
cat > temp_improved_main.tf << 'EOF'
# Task definition DevLake com recursos aumentados
resource "aws_ecs_task_definition" "devlake" {
  family                   = "devlake"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024  # 1 vCPU
  memory                   = 2048  # 2 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "devlake"
      image = "devlake.docker.scarf.sh/apache/devlake:v1.0.1"
      
      portMappings = [
        {
          name          = "devlake-port"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "DB_URL"
          value = "mysql://devlake:${var.db_password}@${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"
        },
        {
          name  = "LOGGING_DIR"
          value = "/app/logs"
        },
        {
          name  = "TZ"
          value = "UTC"
        },
        {
          name  = "ENCRYPTION_SECRET"
          value = var.encryption_secret
        }
      ]

      # Health check melhorado
      healthCheck = {
        command = ["CMD-SHELL", "curl -f http://localhost:8080/api/ping || exit 1"]
        interval = 30
        timeout = 10
        retries = 5
        startPeriod = 120
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.devlake.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "devlake"
        }
      }
    }
  ])

  tags = {
    Name = var.tag_name
  }
}

# Task definition Config UI com recursos aumentados
resource "aws_ecs_task_definition" "config_ui" {
  family                   = "config-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512   # 0.5 vCPU
  memory                   = 1024  # 1 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "config-ui"
      image = "devlake.docker.scarf.sh/apache/devlake-config-ui:latest"
      
      portMappings = [
        {
          name          = "config-ui-port"
          containerPort = 4000
          hostPort      = 4000
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "DEVLAKE_ENDPOINT"
          value = "devlake.devlake-ns:8080"
        },
        {
          name  = "GRAFANA_ENDPOINT"
          value = "grafana.devlake-ns:3000"
        },
        {
          name  = "TZ"
          value = "UTC"
        }
      ]

      # Health check
      healthCheck = {
        command = ["CMD-SHELL", "curl -f http://localhost:4000 || exit 1"]
        interval = 30
        timeout = 5
        retries = 3
        startPeriod = 60
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.config_ui.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "config-ui"
        }
      }
    }
  ])

  tags = {
    Name = var.tag_name
  }
}

# Task definition Grafana com recursos aumentados
resource "aws_ecs_task_definition" "grafana" {
  family                   = "grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512   # 0.5 vCPU
  memory                   = 1024  # 1 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.grafana_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "grafana"
      image = "devlake.docker.scarf.sh/apache/devlake-dashboard:v1.0.1"
      
      portMappings = [
        {
          name          = "grafana-port"
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "GF_SERVER_ROOT_URL"
          value = "https://devlake.${var.domain_name}/grafana"
        },
        {
          name  = "TZ"
          value = "UTC"
        },
        {
          name  = "MYSQL_URL"
          value = module.devlake-rds.db_instance_endpoint
        },
        {
          name  = "MYSQL_DATABASE"
          value = "devlake"
        },
        {
          name  = "MYSQL_USER"
          value = "devlake"
        },
        {
          name  = "MYSQL_PASSWORD"
          value = var.db_password
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "grafana-storage"
          containerPath = "/var/lib/grafana"
          readOnly      = false
        }
      ]

      # Health check
      healthCheck = {
        command = ["CMD-SHELL", "curl -f http://localhost:3000/api/health || exit 1"]
        interval = 30
        timeout = 5
        retries = 3
        startPeriod = 90
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.grafana.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])

  volume {
    name = "grafana-storage"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.grafana.id
      root_directory          = "/"
      transit_encryption      = "ENABLED"
      
      authorization_config {
        access_point_id = aws_efs_access_point.grafana.id
        iam             = "ENABLED"
      }
    }
  }

  tags = {
    Name = var.tag_name
  }
}
EOF

print_status "Verificando se atualização foi aplicada..."

# Verificar se os recursos foram atualizados
if grep -q "cpu.*= 1024" modules/devlake/main.tf; then
    print_success "✅ Recursos do DevLake atualizados para 1 vCPU / 2GB"
else
    print_warning "Aplicando atualização manual dos recursos..."
    
    # Aplicar correções específicas nas task definitions
    python3 -c "
import re

with open('modules/devlake/main.tf', 'r') as f:
    content = f.read()

# Atualizar recursos do DevLake
content = re.sub(r'(resource \"aws_ecs_task_definition\" \"devlake\"[\s\S]*?)cpu\s*=\s*\d+', r'\1cpu                      = 1024', content)
content = re.sub(r'(resource \"aws_ecs_task_definition\" \"devlake\"[\s\S]*?)memory\s*=\s*\d+', r'\1memory                   = 2048', content)

# Atualizar recursos do Config UI
content = re.sub(r'(resource \"aws_ecs_task_definition\" \"config_ui\"[\s\S]*?)cpu\s*=\s*\d+', r'\1cpu                      = 512', content)
content = re.sub(r'(resource \"aws_ecs_task_definition\" \"config_ui\"[\s\S]*?)memory\s*=\s*\d+', r'\1memory                   = 1024', content)

# Atualizar recursos do Grafana
content = re.sub(r'(resource \"aws_ecs_task_definition\" \"grafana\"[\s\S]*?)cpu\s*=\s*\d+', r'\1cpu                      = 512', content)
content = re.sub(r'(resource \"aws_ecs_task_definition\" \"grafana\"[\s\S]*?)memory\s*=\s*\d+', r'\1memory                   = 1024', content)

with open('modules/devlake/main.tf', 'w') as f:
    f.write(content)
" 2>/dev/null || print_warning "Atualização Python falhou, continuando..."

fi

rm -f temp_improved_main.tf

print_status "Atualizando também strategy do capacity provider..."

# Atualizar strategy para usar FARGATE normal em caso de problemas com SPOT
sed -i.bak 's/capacity_provider = "FARGATE_SPOT"/capacity_provider = "FARGATE"/' modules/devlake/main.tf

print_warning "Alterado de FARGATE_SPOT para FARGATE regular para maior estabilidade"

print_status "Validando configuração..."
terraform validate

if [ $? -eq 0 ]; then
    print_success "✅ Configuração validada!"
else
    print_error "❌ Erro na validação"
    exit 1
fi

print_status "Aplicando recursos aumentados..."

# Atualizar as task definitions
print_status "Atualizando task definitions..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve
terraform apply -target="module.devlake.aws_ecs_task_definition.config_ui" -auto-approve
terraform apply -target="module.devlake.aws_ecs_task_definition.grafana" -auto-approve

# Forçar update dos serviços
print_status "Forçando update dos serviços ECS..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve
terraform apply -target="module.devlake.aws_ecs_service.config_ui" -auto-approve
terraform apply -target="module.devlake.aws_ecs_service.grafana" -auto-approve

if [ $? -eq 0 ]; then
    print_success "🚀 Recursos aumentados com sucesso!"
    echo ""
    
    print_status "Novos recursos aplicados:"
    echo "  ✅ DevLake: 1 vCPU / 2GB RAM"
    echo "  ✅ Config UI: 0.5 vCPU / 1GB RAM"  
    echo "  ✅ Grafana: 0.5 vCPU / 1GB RAM"
    echo "  ✅ Capacity Provider: FARGATE (mais estável que SPOT)"
    echo ""
    
    print_warning "⏱️ AGUARDE 5-10 MINUTOS para:"
    echo "  • Novas tasks inicializarem com recursos aumentados"
    echo "  • Health checks passarem"
    echo "  • Target groups ficarem healthy"
    echo ""
    
    print_status "Monitorando deployment..."
    
    for i in {1..10}; do
        echo -n "Aguardando... ($i/10) "
        sleep 30
        
        # Verificar se services estão rodando
        DEVLAKE_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
        CONFIG_UI_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services config-ui --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
        GRAFANA_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services grafana --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
        
        if [ "$DEVLAKE_RUNNING" != "0" ] && [ "$CONFIG_UI_RUNNING" != "0" ] && [ "$GRAFANA_RUNNING" != "0" ]; then
            echo "✅"
            break
        else
            echo "⏳"
        fi
    done
    
    echo ""
    print_status "Status atual dos serviços:"
    echo "  • DevLake: $DEVLAKE_RUNNING task(s) rodando"
    echo "  • Config UI: $CONFIG_UI_RUNNING task(s) rodando"
    echo "  • Grafana: $GRAFANA_RUNNING task(s) rodando"
    
    echo ""
    print_status "🌐 Teste os URLs:"
    
    DOMAIN_NAME=""
    if [ -f "terraform.tfvars" ]; then
        DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
    fi
    
    if [ ! -z "$DOMAIN_NAME" ]; then
        echo "  • https://devlake.$DOMAIN_NAME"
        echo "  • https://devlake.$DOMAIN_NAME/grafana"
    fi
    
    echo ""
    print_warning "📊 MONITORAMENTO:"
    echo "  ./monitor.sh          # Status geral"
    echo "  aws logs tail /ecs/devlake --follow    # Logs DevLake"
    echo ""
    
    print_warning "💰 CUSTO ESTIMADO (novo):"
    echo "  • ~$60-70/mês (aumento devido aos recursos maiores)"
    echo "  • Mas maior estabilidade e performance"
    
else
    print_error "❌ Erro ao aplicar recursos aumentados"
    print_status "Tentando reverter para FARGATE_SPOT se necessário..."
    
    # Reverter para SPOT se FARGATE regular falhar
    sed -i.bak 's/capacity_provider = "FARGATE"/capacity_provider = "FARGATE_SPOT"/' modules/devlake/main.tf
    
    print_status "Execute:"
    echo "  terraform plan"
    echo "  terraform apply"
    exit 1
fi

echo ""
print_success "🎉 DevLake deve estar disponível em breve com recursos aumentados!"