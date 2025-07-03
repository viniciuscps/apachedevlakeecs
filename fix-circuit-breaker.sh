#!/bin/bash
# fix-circuit-breaker.sh - Corrigir Circuit Breaker e problema de DB

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

echo "🔄 CORREÇÃO CIRCUIT BREAKER + DB CONNECTION"
echo ""

print_error "PROBLEMA IDENTIFICADO:"
echo "  ⚠️ Circuit Breaker do ECS ativado (rollback automático)"
echo "  ⚠️ Container DevLake falhando por problema de DB_URL"
echo "  ⚠️ Deployment em loop de falha"
echo ""

print_status "ESTRATÉGIA DE CORREÇÃO:"
echo "  1. Desabilitar circuit breaker temporariamente"
echo "  2. Corrigir definitivamente a string de conexão DB"
echo "  3. Aumentar timeout de inicialização"
echo "  4. Reativar circuit breaker"
echo ""

read -p "Continuar com a correção? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    print_status "Operação cancelada pelo usuário."
    exit 0
fi

# Verificar se estamos no diretório correto
if [ ! -f "modules/devlake/main.tf" ]; then
    print_error "Arquivo modules/devlake/main.tf não encontrado"
    exit 1
fi

print_status "Etapa 1/6: Obtendo informações do RDS..."

# Obter endpoint do RDS
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" = "None" ]; then
    print_error "❌ RDS endpoint não encontrado!"
    print_status "Verificando se RDS existe..."
    if ! aws rds describe-db-instances --db-instance-identifier devlake-db &>/dev/null; then
        print_error "RDS 'devlake-db' não existe! Execute terraform apply primeiro."
        exit 1
    fi
else
    print_success "✅ RDS endpoint: $RDS_ENDPOINT"
fi

# Obter senha
DB_PASSWORD=""
if [ -f "terraform.tfvars" ]; then
    DB_PASSWORD=$(grep -E '^db_password\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
fi

if [ -z "$DB_PASSWORD" ]; then
    print_error "❌ Senha não encontrada em terraform.tfvars"
    exit 1
else
    print_success "✅ Senha obtida"
fi

print_status "Etapa 2/6: Fazendo backup e corrigindo configuração..."

# Backup
cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)

# Criar versão corrigida do arquivo main.tf
cat > temp_fixed_main.tf << EOF
# ECS Services com circuit breaker desabilitado e configuração corrigida
resource "aws_ecs_service" "devlake" {
  name            = "devlake"
  cluster         = aws_ecs_cluster.devlake.id
  task_definition = aws_ecs_task_definition.devlake.arn
  desired_count   = 1
  
  health_check_grace_period_seconds = 300  # 5 minutos (aumentado)

  capacity_provider_strategy {
    base     = 1
    weight   = 100
    capacity_provider = "FARGATE"  # Mais estável que SPOT
  }

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.devlake.arn
  }

  # CIRCUIT BREAKER DESABILITADO TEMPORARIAMENTE
  deployment_circuit_breaker {
    enable   = false
    rollback = false
  }

  # Configuração especial para DevLake - apenas uma instância por vez
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
  propagate_tags                     = "SERVICE"

  tags = {
    Name = var.tag_name
  }
}

# Task definition DevLake corrigida
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
          value = "mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"
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

      # Health check mais tolerante
      healthCheck = {
        command = ["CMD-SHELL", "curl -f http://localhost:8080/api/ping || exit 1"]
        interval = 60      # Aumentado de 30 para 60 segundos
        timeout = 30       # Aumentado de 10 para 30 segundos
        retries = 5        # Mantido 5 tentativas
        startPeriod = 300  # Aumentado para 5 minutos
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
EOF

print_status "Etapa 3/6: Aplicando correções no arquivo principal..."

# Aplicar correções específicas
python3 -c "
import re

# Ler arquivo atual
with open('modules/devlake/main.tf', 'r') as f:
    content = f.read()

# 1. Desabilitar circuit breaker no serviço DevLake
content = re.sub(
    r'(deployment_circuit_breaker\s*{\s*enable\s*=\s*)true',
    r'\1false',
    content
)

content = re.sub(
    r'(deployment_circuit_breaker\s*{\s*enable\s*=\s*false\s*rollback\s*=\s*)true',
    r'\1false',
    content
)

# 2. Aumentar health_check_grace_period_seconds
content = re.sub(
    r'health_check_grace_period_seconds\s*=\s*\d+',
    'health_check_grace_period_seconds = 300',
    content
)

# 3. Corrigir DB_URL definitivamente
db_url_pattern = r'(\s*{\s*name\s*=\s*\"DB_URL\"\s*value\s*=\s*)\"[^\"]*\"'
db_url_replacement = r'\1\"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"'

content = re.sub(db_url_pattern, db_url_replacement, content)

# 4. Aumentar recursos se ainda não foi feito
content = re.sub(r'cpu\s*=\s*256', 'cpu                      = 1024', content)
content = re.sub(r'memory\s*=\s*512', 'memory                   = 2048', content)

# 5. Usar FARGATE em vez de FARGATE_SPOT
content = re.sub(r'capacity_provider\s*=\s*\"FARGATE_SPOT\"', 'capacity_provider = \"FARGATE\"', content)

# Salvar arquivo corrigido
with open('modules/devlake/main.tf', 'w') as f:
    f.write(content)

print('✅ Correções aplicadas no main.tf')
"

rm -f temp_fixed_main.tf

print_status "Etapa 4/6: Validando configuração..."

terraform validate

if [ $? -eq 0 ]; then
    print_success "✅ Configuração validada!"
else
    print_error "❌ Erro na validação"
    exit 1
fi

print_status "Etapa 5/6: Parando serviço atual e aplicando correções..."

# Parar o serviço atual que está em loop de falha
print_status "Parando serviço DevLake atual..."
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 --force-new-deployment >/dev/null 2>&1

print_status "Aguardando parada completa..."
sleep 30

# Aplicar nova task definition
print_status "Aplicando nova task definition corrigida..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

if [ $? -eq 0 ]; then
    print_success "✅ Nova task definition aplicada"
else
    print_error "❌ Falha na task definition"
    exit 1
fi

# Aplicar configuração do serviço
print_status "Aplicando configuração do serviço (sem circuit breaker)..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

if [ $? -eq 0 ]; then
    print_success "✅ Serviço DevLake reconfigurado"
else
    print_error "❌ Falha na reconfiguração do serviço"
    exit 1
fi

print_status "Etapa 6/6: Monitorando inicialização..."

print_warning "⏱️ AGUARDANDO INICIALIZAÇÃO (5-10 minutos)..."
echo "  • Circuit breaker DESABILITADO"
echo "  • Timeout aumentado para 5 minutos"
echo "  • Recursos: 1 vCPU / 2GB RAM"
echo ""

# Monitorar por 10 minutos
for i in {1..20}; do
    echo -n "Verificação $i/20: "
    
    # Verificar se task está rodando
    RUNNING_COUNT=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
    
    if [ "$RUNNING_COUNT" != "0" ]; then
        echo "✅ Task rodando"
        
        # Verificar logs para erros
        sleep 10
        if aws logs tail /ecs/devlake --since 1m 2>/dev/null | grep -q "invalid port.*after host"; then
            echo "    ❌ Ainda com erro de DB"
        elif aws logs tail /ecs/devlake --since 1m 2>/dev/null | grep -q "panic:"; then
            echo "    ❌ Erro de panic"
        else
            echo "    ✅ Sem erros aparentes nos logs"
            
            # Aguardar mais um pouco e verificar health
            sleep 30
            if [ $i -gt 5 ]; then  # Após 5 verificações (2.5 minutos)
                print_success "🎉 DevLake parece estar estável!"
                break
            fi
        fi
    else
        echo "⏳ Task ainda inicializando"
    fi
    
    sleep 30
done

echo ""
print_status "📊 Status final:"

# Status dos serviços
DEVLAKE_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
CONFIG_UI_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services config-ui --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
GRAFANA_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services grafana --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")

echo "  • DevLake: $DEVLAKE_RUNNING task(s) rodando"
echo "  • Config UI: $CONFIG_UI_RUNNING task(s) rodando"
echo "  • Grafana: $GRAFANA_RUNNING task(s) rodando"

echo ""
print_status "🌐 URLs para testar:"

DOMAIN_NAME=""
if [ -f "terraform.tfvars" ]; then
    DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
fi

if [ ! -z "$DOMAIN_NAME" ]; then
    echo "  • https://devlake.$DOMAIN_NAME"
    echo "  • https://devlake.$DOMAIN_NAME/grafana"
fi

echo ""
print_warning "📋 PRÓXIMOS PASSOS:"
echo "  1. Aguarde mais 5 minutos para completa estabilização"
echo "  2. Teste o acesso às URLs acima"
echo "  3. Se funcionando, reative o circuit breaker:"
echo "     - Edite modules/devlake/main.tf"
echo "     - Mude 'enable = false' para 'enable = true'"
echo "     - Execute: terraform apply"
echo ""

print_warning "🔍 COMANDOS DE DEBUG:"
echo "  aws logs tail /ecs/devlake --follow          # Logs em tempo real"
echo "  ./monitor.sh                                 # Status geral"
echo "  aws ecs describe-services --cluster devlake-cluster --services devlake"

echo ""
if [ "$DEVLAKE_RUNNING" != "0" ]; then
    print_success "✅ DevLake foi corrigido e está rodando!"
else
    print_warning "⚠️ DevLake ainda inicializando. Execute './monitor.sh' em alguns minutos."
fi