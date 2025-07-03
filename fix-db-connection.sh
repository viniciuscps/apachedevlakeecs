#!/bin/bash
# fix-db-connection.sh - Corrigir conexão do banco de dados

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

echo "🔧 Corrigindo conexão do banco de dados DevLake"
echo ""

print_error "PROBLEMA IDENTIFICADO:"
echo "  • String de conexão DB_URL está malformada"
echo "  • Faltando endpoint do RDS na configuração"
echo "  • DevLake não consegue conectar ao MySQL"
echo ""

# Verificar se estamos no diretório correto
if [ ! -f "modules/devlake/main.tf" ]; then
    print_error "Arquivo modules/devlake/main.tf não encontrado"
    exit 1
fi

print_status "Diagnosticando o problema..."

# Verificar se o RDS existe e pegar o endpoint
print_status "Verificando RDS..."
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" = "None" ]; then
    print_error "RDS não encontrado ou não acessível"
    print_status "Verifique se o RDS 'devlake-db' existe:"
    echo "  aws rds describe-db-instances --db-instance-identifier devlake-db"
    exit 1
else
    print_success "RDS encontrado: $RDS_ENDPOINT"
fi

# Verificar senha do banco
DB_PASSWORD=""
if [ -f "terraform.tfvars" ]; then
    DB_PASSWORD=$(grep -E '^db_password\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
fi

if [ -z "$DB_PASSWORD" ]; then
    print_error "Senha do banco não encontrada em terraform.tfvars"
    read -s -p "Digite a senha do banco de dados: " DB_PASSWORD
    echo ""
fi

print_success "Senha do banco obtida"

print_status "Corrigindo task definition do DevLake..."

# Fazer backup do arquivo atual
cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)

# Corrigir a DB_URL na task definition
sed -i.bak "s|mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}/devlake|mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake|g" modules/devlake/main.tf

# Verificar se a correção foi aplicada
if grep -q ":3306/devlake" modules/devlake/main.tf; then
    print_success "String de conexão corrigida no arquivo"
else
    print_warning "Correção automática falhou, corrigindo manualmente..."
    
    # Correção manual mais específica
    python3 -c "
import re

with open('modules/devlake/main.tf', 'r') as f:
    content = f.read()

# Corrigir a DB_URL
pattern = r'\"mysql://devlake:\\\${var\.db_password}@\\\${module\.devlake-rds\.db_instance_endpoint}/devlake\?charset=utf8mb4&parseTime=True&loc=UTC\"'
replacement = '\"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"'

content = re.sub(pattern, replacement, content)

# Também corrigir qualquer variação
content = re.sub(
    r'\"mysql://devlake:\\\${var\.db_password}@\\\${module\.devlake-rds\.db_instance_endpoint}/devlake',
    '\"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake',
    content
)

with open('modules/devlake/main.tf', 'w') as f:
    f.write(content)
" 2>/dev/null || print_warning "Correção Python falhou, usando sed..."

fi

print_status "Verificando arquivo corrigido..."
if grep -q "mysql://devlake.*:3306/devlake" modules/devlake/main.tf; then
    print_success "✅ String de conexão DB_URL corrigida!"
else
    print_error "❌ Falha na correção automática"
    print_status "Corrigindo manualmente..."
    
    # Mostrar a linha que precisa ser corrigida
    echo ""
    print_warning "Procure por esta linha em modules/devlake/main.tf:"
    echo '  value = "mysql://devlake:${var.db_password}@${module.devlake-rds.db_instance_endpoint}/devlake?charset=utf8mb4&parseTime=True&loc=UTC"'
    echo ""
    print_status "E substitua por:"
    echo '  value = "mysql://devlake:${var.db_password}@${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"'
    echo ""
    read -p "Pressione ENTER após fazer a correção manual..."
fi

print_status "Aplicando correção..."

# Validar configuração
terraform validate

if [ $? -eq 0 ]; then
    print_success "Configuração validada!"
else
    print_error "Erro na validação"
    exit 1
fi

# Aplicar apenas a task definition corrigida
print_status "Atualizando task definition do DevLake..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

# Forçar atualização do serviço
print_status "Forçando atualização do serviço DevLake..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

if [ $? -eq 0 ]; then
    print_success "🎉 Correção aplicada com sucesso!"
    echo ""
    
    print_status "Aguardando nova task inicializar..."
    sleep 60
    
    print_status "Verificando logs do DevLake..."
    echo ""
    print_warning "Logs das últimas linhas:"
    aws logs tail /ecs/devlake --since 2m --format short | tail -10 || print_warning "Não foi possível obter logs"
    
    echo ""
    print_status "Verificando status do serviço..."
    
    # Verificar se a task está rodando
    RUNNING_COUNT=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
    DESIRED_COUNT=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].desiredCount' --output text 2>/dev/null || echo "0")
    
    if [ "$RUNNING_COUNT" = "$DESIRED_COUNT" ] && [ "$RUNNING_COUNT" != "0" ]; then
        print_success "✅ Serviço DevLake: $RUNNING_COUNT/$DESIRED_COUNT tasks rodando"
    else
        print_warning "⚠️ Serviço DevLake: $RUNNING_COUNT/$DESIRED_COUNT tasks rodando"
        print_status "Aguardando estabilização..."
    fi
    
    echo ""
    print_status "🌐 URLs para testar:"
    
    DOMAIN_NAME=""
    if [ -f "terraform.tfvars" ]; then
        DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
    fi
    
    if [ ! -z "$DOMAIN_NAME" ]; then
        echo "  • DevLake UI: https://devlake.$DOMAIN_NAME"
        echo "  • Grafana: https://devlake.$DOMAIN_NAME/grafana"
    fi
    
    echo ""
    print_warning "IMPORTANTE:"
    echo "  • Aguarde 5-10 minutos para completa estabilização"
    echo "  • Execute './monitor.sh' para acompanhar em tempo real"
    echo "  • Se ainda houver erro 503, verifique os target groups do ALB"
    
    echo ""
    print_status "Comandos úteis para debug:"
    echo "  # Ver logs em tempo real:"
    echo "  aws logs tail /ecs/devlake --follow"
    echo ""
    echo "  # Verificar health dos target groups:"
    echo "  aws elbv2 describe-target-health --target-group-arn \$(aws elbv2 describe-target-groups --names devlake-config-ui-tg --query 'TargetGroups[0].TargetGroupArn' --output text)"
    
else
    print_error "❌ Erro na aplicação da correção"
    print_status "Verifique os logs acima e tente:"
    echo "  terraform plan"
    echo "  terraform apply"
    exit 1
fi