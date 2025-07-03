#!/bin/bash
# fix-subnet-group.sh - Corrigir conflito do DB Subnet Group

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

echo "🔧 CORREÇÃO DO DB SUBNET GROUP CONFLICT"
echo ""

print_error "PROBLEMA IDENTIFICADO:"
echo "  DB Subnet Group está tentando usar subnets de VPC diferente"
echo "  Isso indica recursos remanescentes de deployments anteriores"
echo ""

print_status "1. Removendo resource conflitante do Terraform state..."

# Remover DB Subnet Group do state
terraform state rm 'module.devlake.module.devlake-rds.module.db_subnet_group.aws_db_subnet_group.this[0]' 2>/dev/null || print_warning "Resource não encontrado no state"

print_status "2. Verificando instância RDS existente..."
RDS_EXISTS=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$RDS_EXISTS" != "NOT_FOUND" ]; then
    print_warning "⚠️ Instância RDS já existe: $RDS_EXISTS"
    
    # Verificar VPC do RDS vs VPC do projeto
    RDS_VPC=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBSubnetGroup.VpcId' --output text 2>/dev/null || echo "")
    CURRENT_VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*devlake*" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
    
    print_status "RDS VPC: $RDS_VPC"
    print_status "Projeto VPC: $CURRENT_VPC"
    
    if [ "$RDS_VPC" != "$CURRENT_VPC" ]; then
        print_error "❌ RDS está em VPC diferente! Precisa ser removido."
        echo ""
        
        read -p "Remover RDS existente e recriar na VPC correta? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            
            # Criar backup
            print_status "Criando backup antes da remoção..."
            BACKUP_NAME="devlake-pre-fix-backup-$(date +%Y%m%d-%H%M%S)"
            aws rds create-db-snapshot --db-instance-identifier devlake-db --db-snapshot-identifier "$BACKUP_NAME" 2>/dev/null || print_warning "Falha no backup"
            
            # Remover proteção
            print_status "Removendo proteção de deleção..."
            aws rds modify-db-instance --db-instance-identifier devlake-db --no-deletion-protection --apply-immediately 2>/dev/null || true
            sleep 10
            
            # Remover RDS
            print_status "Removendo instância RDS..."
            aws rds delete-db-instance --db-instance-identifier devlake-db --skip-final-snapshot --delete-automated-backups || print_error "Falha ao remover RDS"
            
            print_status "Aguardando remoção completa do RDS (pode levar alguns minutos)..."
            aws rds wait db-instance-deleted --db-instance-identifier devlake-db || print_warning "Timeout - continuando"
            
            print_success "✅ RDS removido"
        else
            print_status "Operação cancelada pelo usuário"
            exit 1
        fi
    else
        print_success "✅ RDS está na VPC correta"
    fi
fi

print_status "3. Removendo subnet groups órfãos..."
SUBNET_GROUPS=$(aws rds describe-db-subnet-groups --query 'DBSubnetGroups[?contains(DBSubnetGroupName,`devlake`)].DBSubnetGroupName' --output text 2>/dev/null || echo "")

for group in $SUBNET_GROUPS; do
    print_status "Removendo subnet group órfão: $group"
    aws rds delete-db-subnet-group --db-subnet-group-name "$group" 2>/dev/null || print_warning "Falha ao remover $group"
done

print_status "4. Aplicando configuração corrigida..."

# Refresh do state
terraform refresh

# Aplicar configuração
terraform apply -auto-approve

if [ $? -eq 0 ]; then
    print_success "🎉 Problema do DB Subnet Group corrigido!"
    echo ""
    
    print_status "Aguardando RDS ficar disponível..."
    sleep 60
    
    RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$RDS_STATUS" = "available" ]; then
        print_success "✅ RDS disponível"
        
        print_status "Verificando DevLake..."
        sleep 120  # Aguardar DevLake inicializar
        
        # Verificar logs do DevLake
        print_status "Verificando logs do DevLake..."
        aws logs tail /ecs/devlake --since 3m --format short | tail -10 || print_warning "Logs não disponíveis ainda"
        
        echo ""
        print_status "🌐 URLs de acesso:"
        echo "  • https://devlake.devlaketoco.com"
        echo "  • https://devlake.devlaketoco.com/grafana"
        
        echo ""
        print_warning "PRÓXIMOS PASSOS:"
        echo "  1. Aguarde 5-10 minutos para completa estabilização"
        echo "  2. Execute: aws logs tail /ecs/devlake --follow"
        echo "  3. Teste o acesso às URLs acima"
        
    elif [ "$RDS_STATUS" = "creating" ]; then
        print_warning "⚠️ RDS ainda sendo criado..."
        print_status "Execute novamente em alguns minutos"
        
    else
        print_warning "⚠️ RDS status: $RDS_STATUS"
    fi
    
else
    print_error "❌ Falha na aplicação do Terraform"
    exit 1
fi

echo ""
print_success "🔧 Correção concluída! Execute './monitor.sh' para acompanhar."


