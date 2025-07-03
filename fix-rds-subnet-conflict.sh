#!/bin/bash
# fix-rds-subnet-conflict.sh - Resolver conflito RDS/Subnet

set -e

echo "🔧 CORRIGINDO CONFLITO RDS/SUBNET GROUP"
echo ""

echo "❌ PROBLEMA: RDS não consegue trocar de subnet group"
echo "Causa: Múltiplos subnet groups na mesma VPC causando confusão"
echo ""

# 1. Verificar estado atual
echo "1. Diagnosticando estado atual..."

RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")
echo "RDS Status: $RDS_STATUS"

if [ "$RDS_STATUS" = "NOT_FOUND" ]; then
    echo "✅ RDS não existe, pode prosseguir com criação limpa"
    echo "Aplicando terraform apply..."
    terraform apply -auto-approve
    exit 0
fi

RDS_SUBNET_GROUP=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text 2>/dev/null || echo "")
echo "RDS Subnet Group atual: $RDS_SUBNET_GROUP"

# 2. Listar todos os subnet groups relacionados ao DevLake
echo ""
echo "2. Listando subnet groups do DevLake..."
ALL_GROUPS=$(aws rds describe-db-subnet-groups --query 'DBSubnetGroups[?contains(DBSubnetGroupName,`devlake`)].DBSubnetGroupName' --output text 2>/dev/null || echo "")

echo "Subnet groups encontrados:"
for group in $ALL_GROUPS; do
    VPC_ID=$(aws rds describe-db-subnet-groups --db-subnet-group-name "$group" --query 'DBSubnetGroups[0].VpcId' --output text 2>/dev/null || echo "")
    echo "  - $group (VPC: $VPC_ID)"
done

# 3. Estratégia de correção
echo ""
echo "3. ESTRATÉGIA DE CORREÇÃO:"
echo "Vamos remover o RDS e recriar limpo para evitar conflitos"
echo ""

read -p "Continuar com remoção e recriação do RDS? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Operação cancelada"
    exit 1
fi

# 4. Backup antes da remoção
echo "4. Criando backup de segurança..."
BACKUP_NAME="devlake-pre-recreate-backup-$(date +%Y%m%d-%H%M%S)"
aws rds create-db-snapshot --db-instance-identifier devlake-db --db-snapshot-identifier "$BACKUP_NAME" 2>/dev/null || echo "⚠️ Falha no backup"

if aws rds describe-db-snapshots --db-snapshot-identifier "$BACKUP_NAME" >/dev/null 2>&1; then
    echo "✅ Backup criado: $BACKUP_NAME"
else
    echo "⚠️ Backup não foi criado, mas continuando..."
fi

# 5. Remover proteção de deleção
echo ""
echo "5. Removendo proteção de deleção..."
aws rds modify-db-instance --db-instance-identifier devlake-db --no-deletion-protection --apply-immediately 2>/dev/null || true
sleep 15

# 6. Remover RDS
echo "6. Removendo instância RDS..."
aws rds delete-db-instance --db-instance-identifier devlake-db --skip-final-snapshot --delete-automated-backups

echo "Aguardando remoção completa do RDS (isso pode levar 5-10 minutos)..."
aws rds wait db-instance-deleted --db-instance-identifier devlake-db || echo "⚠️ Timeout, mas continuando..."

echo "✅ RDS removido"

# 7. Limpar subnet groups órfãos
echo ""
echo "7. Removendo subnet groups órfãos..."
for group in $ALL_GROUPS; do
    echo "Removendo: $group"
    aws rds delete-db-subnet-group --db-subnet-group-name "$group" 2>/dev/null || echo "⚠️ Falha ao remover $group (pode estar em uso)"
done

# 8. Limpar state do Terraform
echo ""
echo "8. Limpando state do Terraform..."
terraform state rm 'module.devlake.module.devlake-rds.module.db_instance.aws_db_instance.this[0]' 2>/dev/null || true
terraform state rm 'module.devlake.module.devlake-rds.module.db_subnet_group.aws_db_subnet_group.this[0]' 2>/dev/null || true

# 9. Refresh e aplicar
echo ""
echo "9. Aplicando configuração limpa..."
terraform refresh
terraform apply -auto-approve

if [ $? -eq 0 ]; then
    echo ""
    echo "🎉 RDS RECRIADO COM SUCESSO!"
    
    echo ""
    echo "10. Aguardando RDS ficar disponível..."
    echo "Isso pode levar 5-10 minutos..."
    
    # Aguardar um pouco antes de verificar
    sleep 120
    
    NEW_RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    echo "Novo RDS Status: $NEW_RDS_STATUS"
    
    if [ "$NEW_RDS_STATUS" = "available" ]; then
        echo "✅ RDS disponível!"
        
        echo ""
        echo "11. Verificando DevLake..."
        
        # Verificar se DevLake vai conectar agora
        echo "Aguardando DevLake tentar conectar..."
        sleep 180
        
        echo "Verificando logs do DevLake..."
        aws logs tail /ecs/devlake --since 3m --format short | tail -10 2>/dev/null || echo "Logs não disponíveis ainda"
        
        echo ""
        if aws logs tail /ecs/devlake --since 3m 2>/dev/null | grep -q 'parse.*mysql://devlake:Priscila'; then
            echo "❌ DevLake ainda com problema de DB_URL"
            echo "Execute: ./fix-devlake-final.sh"
        else
            echo "✅ DevLake parece estar funcionando!"
            echo ""
            echo "🌐 URLs de acesso:"
            echo "  • https://devlake.devlaketoco.com"
            echo "  • https://devlake.devlaketoco.com/grafana"
        fi
        
    elif [ "$NEW_RDS_STATUS" = "creating" ]; then
        echo "⚠️ RDS ainda sendo criado..."
        echo "Execute 'aws rds describe-db-instances --db-instance-identifier devlake-db' para acompanhar"
        
    else
        echo "⚠️ RDS em estado: $NEW_RDS_STATUS"
    fi
    
    if [ ! -z "$BACKUP_NAME" ]; then
        echo ""
        echo "💾 BACKUP DISPONÍVEL: $BACKUP_NAME"
        echo "Para restaurar (se necessário): aws rds restore-db-instance-from-db-snapshot"
    fi
    
else
    echo "❌ Falha na aplicação do Terraform"
    exit 1
fi

echo ""
echo "🔧 Correção do conflito RDS/Subnet concluída!"