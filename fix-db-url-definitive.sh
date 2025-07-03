#!/bin/bash
# fix-db-url-definitive.sh - Correção definitiva da string de conexão do banco

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

echo "🔧 CORREÇÃO DEFINITIVA - String de conexão do banco"
echo ""

print_error "PROBLEMA CRÍTICO IDENTIFICADO:"
echo "  A string DB_URL ainda está: mysql://devlake:Priscila"
echo "  Falta o endpoint do RDS completamente!"
echo ""

# Verificar se estamos no diretório correto
if [ ! -f "modules/devlake/main.tf" ]; then
    print_error "Arquivo modules/devlake/main.tf não encontrado"
    exit 1
fi

print_status "1. Obtendo endpoint real do RDS..."

# Obter endpoint do RDS
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" = "None" ]; then
    print_error "❌ RDS endpoint não encontrado!"
    print_status "Verificando se RDS existe..."
    aws rds describe-db-instances --db-instance-identifier devlake-db || {
        print_error "RDS 'devlake-db' não existe!"
        print_status "Execute: terraform apply para criar o RDS primeiro"
        exit 1
    }
else
    print_success "✅ RDS endpoint encontrado: $RDS_ENDPOINT"
fi

print_status "2. Verificando senha do banco..."

DB_PASSWORD=""
if [ -f "terraform.tfvars" ]; then
    DB_PASSWORD=$(grep -E '^db_password\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
fi

if [ -z "$DB_PASSWORD" ]; then
    print_error "❌ Senha não encontrada em terraform.tfvars"
    exit 1
else
    print_success "✅ Senha obtida: ${DB_PASSWORD:0:3}***"
fi

print_status "3. Analisando arquivo main.tf atual..."

# Verificar linha problemática
CURRENT_DB_URL=$(grep -A 10 "DB_URL" modules/devlake/main.tf | grep "value" | head -1)
echo "Linha atual: $CURRENT_DB_URL"

print_status "4. Criando string de conexão correta..."

CORRECT_DB_URL="mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"
echo "String correta: $CORRECT_DB_URL"

print_status "5. Fazendo backup e corrigindo arquivo..."

# Backup
cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)

# Correção definitiva usando Python para garantir precisão
python3 -c "
import re

# Ler arquivo
with open('modules/devlake/main.tf', 'r') as f:
    content = f.read()

print('Arquivo original lido, tamanho:', len(content))

# Padrões para encontrar e corrigir a DB_URL
patterns_to_fix = [
    # Padrão 1: value = \"mysql://devlake:\${var.db_password}@...
    (r'value\s*=\s*\"mysql://devlake:\\\${var\.db_password}@[^\"]*\"',
     'value = \"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"'),
    
    # Padrão 2: apenas mysql://devlake:senha
    (r'\"mysql://devlake:[^@]*\"',
     '\"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"'),
    
    # Padrão 3: qualquer mysql://devlake que não tenha endpoint completo
    (r'mysql://devlake:\\\${var\.db_password}@\\\${module\.devlake-rds\.db_instance_endpoint}/devlake',
     'mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake')
]

# Aplicar correções
original_content = content
for pattern, replacement in patterns_to_fix:
    old_content = content
    content = re.sub(pattern, replacement, content)
    if content != old_content:
        print(f'Aplicada correção: {pattern[:50]}...')

# Verificar se houve mudança
if content != original_content:
    print('✅ Correções aplicadas!')
    with open('modules/devlake/main.tf', 'w') as f:
        f.write(content)
else:
    print('⚠️ Nenhuma correção automática aplicada, fazendo correção manual...')
    
    # Correção manual mais agressiva
    lines = content.split('\n')
    for i, line in enumerate(lines):
        if 'DB_URL' in line and i+1 < len(lines):
            # Encontrou a variável DB_URL, corrigir a próxima linha (value)
            value_line = lines[i+1]
            if 'value' in value_line and 'mysql://' in value_line:
                print(f'Linha {i+1} antes: {value_line}')
                lines[i+1] = '          value = \"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"'
                print(f'Linha {i+1} depois: {lines[i+1]}')
                break
    
    # Salvar arquivo corrigido
    with open('modules/devlake/main.tf', 'w') as f:
        f.write('\n'.join(lines))
    print('✅ Correção manual aplicada!')
"

print_status "6. Verificando correção..."

# Verificar se a correção foi aplicada
if grep -q ":3306/devlake" modules/devlake/main.tf; then
    print_success "✅ String de conexão corrigida!"
    
    # Mostrar a linha corrigida
    print_status "Linha corrigida:"
    grep -A 1 "DB_URL" modules/devlake/main.tf | grep "value"
else
    print_error "❌ Correção automática falhou!"
    print_status "CORREÇÃO MANUAL NECESSÁRIA:"
    echo ""
    echo "Edite modules/devlake/main.tf e encontre a seção:"
    echo "  environment = ["
    echo "    {"
    echo "      name  = \"DB_URL\""
    echo "      value = \"...\""  # <-- ESTA LINHA
    echo "    },"
    echo ""
    echo "Substitua o value por:"
    echo "  value = \"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\""
    echo ""
    read -p "Pressione ENTER após fazer a correção manual..."
fi

print_status "7. Validando configuração Terraform..."

terraform validate

if [ $? -eq 0 ]; then
    print_success "✅ Configuração validada!"
else
    print_error "❌ Erro na validação do Terraform"
    exit 1
fi

print_status "8. Aplicando correção..."

# Primeiro, parar o serviço atual que está falhando
print_status "Parando serviço DevLake atual..."
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 >/dev/null 2>&1 || true

# Aguardar um pouco
sleep 10

# Aplicar nova task definition
print_status "Aplicando nova task definition..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

# Reativar o serviço
print_status "Reativando serviço DevLake..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

if [ $? -eq 0 ]; then
    print_success "🎉 Correção aplicada com sucesso!"
    echo ""
    
    print_status "Aguardando nova task inicializar..."
    sleep 60
    
    print_status "Verificando logs mais recentes..."
    echo ""
    print_warning "Logs das últimas 10 linhas:"
    aws logs tail /ecs/devlake --since 2m --format short | tail -10 2>/dev/null || {
        print_warning "Aguardando logs aparecerem..."
        sleep 30
        aws logs tail /ecs/devlake --since 1m --format short | tail -5 2>/dev/null || echo "Logs ainda não disponíveis"
    }
    
    echo ""
    print_status "Verificando se erro persist..."
    
    # Verificar se ainda tem o erro da string de conexão
    if aws logs tail /ecs/devlake --since 3m | grep -q "invalid port.*after host"; then
        print_error "❌ Erro ainda persiste!"
        print_status "Mostrando configuração atual da DB_URL:"
        grep -A 2 "DB_URL" modules/devlake/main.tf
        echo ""
        print_status "String deveria ser similar a:"
        echo "  mysql://devlake:Priscila@devlake-db.xyz.us-east-1.rds.amazonaws.com:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"
    else
        print_success "✅ Erro de conexão corrigido!"
        
        # Verificar status do serviço
        sleep 30
        RUNNING_COUNT=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
        
        if [ "$RUNNING_COUNT" != "0" ]; then
            print_success "✅ Serviço DevLake rodando: $RUNNING_COUNT task(s)"
            
            echo ""
            print_status "🌐 Teste o acesso:"
            DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "seu-dominio.com")
            echo "  https://devlake.$DOMAIN_NAME"
            echo "  https://devlake.$DOMAIN_NAME/grafana"
            
        else
            print_warning "⚠️ Serviço ainda inicializando..."
            print_status "Execute './monitor.sh' para acompanhar"
        fi
    fi
    
else
    print_error "❌ Erro ao aplicar correção"
    print_status "Tente executar manualmente:"
    echo "  terraform plan"
    echo "  terraform apply"
    exit 1
fi

echo ""
print_success "🔧 Correção concluída! Aguarde alguns minutos e teste o acesso."