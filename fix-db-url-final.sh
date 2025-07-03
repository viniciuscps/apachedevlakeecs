#!/bin/bash
# fix-db-url-final.sh - Correção DEFINITIVA da DB_URL baseada nos logs

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

echo "🔧 CORREÇÃO DEFINITIVA - DB_URL baseada na análise de logs"
echo ""

print_error "PROBLEMA CONFIRMADO pelos logs:"
echo '  String atual: mysql://devlake:Priscila'
echo '  String correta: mysql://devlake:Priscila@endpoint:3306/devlake...'
echo ""

print_status "A variável \${module.devlake-rds.db_instance_endpoint} não está sendo expandida!"
echo ""

# Verificar se estamos no diretório correto
if [ ! -f "modules/devlake/main.tf" ]; then
    print_error "Arquivo modules/devlake/main.tf não encontrado"
    exit 1
fi

print_status "1. Obtendo endpoint REAL do RDS..."

# Obter endpoint real do RDS
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" = "None" ]; then
    print_error "❌ RDS endpoint não encontrado!"
    
    # Verificar se RDS existe
    if ! aws rds describe-db-instances --db-instance-identifier devlake-db &>/dev/null; then
        print_error "RDS 'devlake-db' não existe!"
        print_status "Execute primeiro: terraform apply"
        exit 1
    fi
else
    print_success "✅ RDS endpoint obtido: $RDS_ENDPOINT"
fi

print_status "2. Obtendo senha do banco..."

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

print_status "3. Fazendo backup e corrigindo arquivo..."

# Backup
cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)

print_status "4. Construindo string de conexão correta..."

# String de conexão completa e correta
CORRECT_DB_URL="mysql://devlake:${DB_PASSWORD}@${RDS_ENDPOINT}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"

print_status "String correta que será usada:"
echo "  $CORRECT_DB_URL"
echo ""

print_status "5. Aplicando correção no arquivo main.tf..."

# Correção definitiva usando uma abordagem mais robusta
python3 -c """
import re
import sys

# Ler arquivo
try:
    with open('modules/devlake/main.tf', 'r') as f:
        content = f.read()
    print('✓ Arquivo lido com sucesso')
except Exception as e:
    print(f'✗ Erro ao ler arquivo: {e}')
    sys.exit(1)

# Encontrar e substituir a linha DB_URL no container DevLake
# Padrão para encontrar a seção environment do container devlake
pattern = r'(environment\s*=\s*\[\s*\{[^}]*name\s*=\s*\"DB_URL\"[^}]*value\s*=\s*\")[^\"]*(\")[^}]*\})'

replacement = r'\1mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\2'

# Aplicar substituição
new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

if new_content != content:
    print('✓ Padrão encontrado e substituído')
    try:
        with open('modules/devlake/main.tf', 'w') as f:
            f.write(new_content)
        print('✓ Arquivo salvo com sucesso')
    except Exception as e:
        print(f'✗ Erro ao salvar arquivo: {e}')
        sys.exit(1)
else:
    print('⚠ Padrão não encontrado, fazendo correção manual...')
    
    # Correção manual mais específica
    lines = content.split('\n')
    
    for i, line in enumerate(lines):
        if 'DB_URL' in line and i+1 < len(lines):
            # Encontrou DB_URL, corrigir a próxima linha (value)
            value_line = lines[i+1]
            if 'value' in value_line:
                print(f'✓ Linha {i+1} antes: {value_line.strip()}')
                
                # Construir nova linha com indentação correta
                indent = len(value_line) - len(value_line.lstrip())
                new_value_line = ' ' * indent + 'value = \"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"'
                
                lines[i+1] = new_value_line
                print(f'✓ Linha {i+1} depois: {new_value_line.strip()}')
                break
    
    # Salvar arquivo corrigido
    try:
        with open('modules/devlake/main.tf', 'w') as f:
            f.write('\n'.join(lines))
        print('✓ Correção manual aplicada e arquivo salvo')
    except Exception as e:
        print(f'✗ Erro ao salvar correção manual: {e}')
        sys.exit(1)
"""

print_status "6. Verificando se correção foi aplicada..."

# Verificar se a correção foi aplicada
if grep -q ":3306/devlake" modules/devlake/main.tf; then
    print_success "✅ String de conexão corrigida!"
    
    # Mostrar a linha corrigida
    print_status "Linha corrigida encontrada:"
    grep -A 1 "DB_URL" modules/devlake/main.tf | grep "value"
    echo ""
else
    print_error "❌ Correção automática falhou!"
    print_status ""
    print_status "CORREÇÃO MANUAL NECESSÁRIA:"
    print_status "1. Abra: modules/devlake/main.tf"
    print_status "2. Procure por: name = \"DB_URL\""
    print_status "3. Na linha seguinte (value), substitua por:"
    echo '   value = "mysql://devlake:${var.db_password}@${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"'
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

# Parar o serviço atual que está falhando
print_status "⏹️ Parando serviço DevLake atual..."
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 >/dev/null 2>&1

print_status "⏳ Aguardando parada completa..."
sleep 30

# Aplicar nova task definition
print_status "📋 Aplicando nova task definition..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

if [ $? -eq 0 ]; then
    print_success "✅ Nova task definition aplicada"
else
    print_error "❌ Falha na aplicação da task definition"
    exit 1
fi

# Reativar o serviço
print_status "🔄 Reativando serviço DevLake..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

if [ $? -eq 0 ]; then
    print_success "🎉 Correção aplicada com sucesso!"
    echo ""
    
    print_status "⏳ Aguardando nova task inicializar (2 minutos)..."
    sleep 120
    
    print_status "📊 Verificando logs mais recentes..."
    echo ""
    print_warning "Logs das últimas linhas:"
    aws logs tail /ecs/devlake --since 3m --format short | tail -15 2>/dev/null || {
        print_warning "Aguardando logs aparecerem..."
        sleep 30
        aws logs tail /ecs/devlake --since 1m --format short | tail -10 2>/dev/null || echo "Logs ainda não disponíveis"
    }
    
    echo ""
    print_status "🔍 Verificando se erro persiste..."
    
    # Verificar se ainda tem o erro da string de conexão
    if aws logs tail /ecs/devlake --since 3m | grep -q 'parse.*mysql://devlake:Priscila'; then
        print_error "❌ Erro ainda persiste! A task definition não foi atualizada corretamente."
        print_status ""
        print_status "DIAGNÓSTICO:"
        print_status "A variável \${module.devlake-rds.db_instance_endpoint} ainda não está sendo expandida."
        print_status ""
        print_status "VERIFICAR:"
        echo "1. Se o módulo RDS está sendo referenciado corretamente"
        echo "2. Se há dependências entre resources"
        echo "3. Se o terraform state está consistente"
        echo ""
        
        print_status "PRÓXIMOS PASSOS:"
        echo "1. terraform refresh"
        echo "2. terraform plan"
        echo "3. Verificar outputs do módulo RDS"
        echo ""
        
    elif aws logs tail /ecs/devlake --since 3m | grep -q "panic:\|fatal:"; then
        print_warning "⚠️ Ainda há outros erros nos logs"
        print_status "Último erro encontrado:"
        aws logs tail /ecs/devlake --since 3m | grep "panic:\|fatal:" | tail -3
        echo ""
        
    else
        print_success "✅ Erro de parsing da DB_URL CORRIGIDO!"
        
        # Verificar se o serviço está rodando
        sleep 30
        RUNNING_COUNT=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
        
        if [ "$RUNNING_COUNT" != "0" ]; then
            print_success "✅ Serviço DevLake rodando: $RUNNING_COUNT task(s)"
            echo ""
            
            print_status "🌐 Teste o acesso em alguns minutos:"
            DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "seu-dominio.com")
            echo "  • https://devlake.$DOMAIN_NAME"
            echo "  • https://devlake.$DOMAIN_NAME/grafana"
            echo ""
            
            print_success "🎉 PROBLEMA RESOLVIDO! DevLake deve estar acessível em breve."
            
        else
            print_warning "⚠️ Serviço ainda inicializando..."
            print_status "Execute './monitor.sh' para acompanhar o progresso"
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
print_success "🔧 Correção da DB_URL concluída!"
print_status "Execute 'aws logs tail /ecs/devlake --follow' para acompanhar os logs em tempo real."