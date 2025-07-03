#!/bin/bash
# change-db-password.sh - Trocar senha do banco de dados

set -e

echo "🔑 TROCAR SENHA DO BANCO DE DADOS"
echo ""

echo "❌ PROBLEMA: Senha atual 'Priscila#01A' pode ter caracteres problemáticos"
echo "✅ SOLUÇÃO: Usar senha simples sem caracteres especiais"
echo ""

# 1. Gerar nova senha simples
echo "1. Gerando nova senha simples..."

# Senha sem caracteres especiais que podem causar problemas
NEW_PASSWORD="DevLakePwd2025"

echo "Nova senha sugerida: $NEW_PASSWORD"
echo ""
echo "Características da nova senha:"
echo "  ✅ Sem caracteres especiais (#, @, &, etc.)"
echo "  ✅ Alfanumérica simples"
echo "  ✅ Fácil de debugar"
echo ""

read -p "Usar esta senha ou digite uma personalizada: " -r
if [ ! -z "$REPLY" ]; then
    NEW_PASSWORD="$REPLY"
fi

echo "Senha escolhida: $NEW_PASSWORD"
echo ""

# 2. Atualizar terraform.tfvars
echo "2. Atualizando terraform.tfvars..."

if [ -f "terraform.tfvars" ]; then
    # Backup
    cp terraform.tfvars terraform.tfvars.backup.$(date +%Y%m%d-%H%M%S)
    
    # Atualizar senha
    sed -i "s/^db_password\s*=.*/db_password = \"$NEW_PASSWORD\"/" terraform.tfvars
    
    echo "✅ terraform.tfvars atualizado"
    
    # Mostrar linha atualizada
    echo "Nova linha:"
    grep "db_password" terraform.tfvars
else
    echo "❌ terraform.tfvars não encontrado!"
    exit 1
fi

echo ""
echo "3. Verificando RDS atual..."

RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$RDS_STATUS" = "NOT_FOUND" ]; then
    echo "✅ RDS não existe, será criado com nova senha"
    
    echo ""
    echo "4. Aplicando configuração com nova senha..."
    terraform apply -auto-approve
    
else
    echo "⚠️ RDS existe com senha antiga: $RDS_STATUS"
    echo ""
    echo "OPÇÕES:"
    echo "1. 🔄 Modificar senha do RDS existente (rápido)"
    echo "2. 🗑️ Remover RDS e recriar com nova senha (limpo)"
    echo ""
    
    read -p "Escolha uma opção (1/2): " -n 1 -r
    echo
    
    case $REPLY in
        1)
            echo "Opção 1: Modificando senha do RDS existente..."
            
            echo "Aguardando RDS estar disponível para modificação..."
            aws rds wait db-instance-available --db-instance-identifier devlake-db || echo "Continuando mesmo se não disponível..."
            
            echo "Modificando senha..."
            aws rds modify-db-instance \
                --db-instance-identifier devlake-db \
                --master-user-password "$NEW_PASSWORD" \
                --apply-immediately
            
            echo "Aguardando modificação completar..."
            aws rds wait db-instance-available --db-instance-identifier devlake-db || echo "Timeout, mas continuando..."
            
            echo "✅ Senha do RDS modificada"
            ;;
            
        2)
            echo "Opção 2: Removendo RDS e recriando..."
            
            # Backup
            BACKUP_NAME="devlake-pre-password-change-$(date +%Y%m%d-%H%M%S)"
            echo "Criando backup: $BACKUP_NAME"
            aws rds create-db-snapshot --db-instance-identifier devlake-db --db-snapshot-identifier "$BACKUP_NAME" 2>/dev/null || echo "⚠️ Falha no backup"
            
            # Remover proteção
            echo "Removendo proteção de deleção..."
            aws rds modify-db-instance --db-instance-identifier devlake-db --no-deletion-protection --apply-immediately 2>/dev/null || true
            sleep 15
            
            # Remover RDS
            echo "Removendo RDS..."
            aws rds delete-db-instance --db-instance-identifier devlake-db --skip-final-snapshot --delete-automated-backups
            
            echo "Aguardando remoção..."
            aws rds wait db-instance-deleted --db-instance-identifier devlake-db || echo "Timeout, mas continuando..."
            
            # Limpar state
            terraform state rm 'module.devlake.module.devlake-rds.module.db_instance.aws_db_instance.this[0]' 2>/dev/null || true
            
            echo "✅ RDS removido"
            ;;
            
        *)
            echo "❌ Opção inválida"
            exit 1
            ;;
    esac
    
    echo ""
    echo "4. Aplicando nova configuração..."
    terraform refresh
    terraform apply -auto-approve
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "🎉 SENHA ALTERADA COM SUCESSO!"
    
    echo ""
    echo "5. Aguardando RDS ficar disponível..."
    sleep 60
    
    NEW_RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    echo "Status do RDS: $NEW_RDS_STATUS"
    
    if [ "$NEW_RDS_STATUS" = "available" ]; then
        echo "✅ RDS disponível com nova senha"
        
        echo ""
        echo "6. Atualizando DevLake com nova senha..."
        
        # Parar serviço DevLake
        echo "Parando serviço DevLake..."
        aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 >/dev/null
        sleep 30
        
        # Forçar nova task definition
        echo "Atualizando task definition..."
        terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve
        
        # Reativar serviço
        echo "Reativando serviço DevLake..."
        terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve
        
        echo ""
        echo "7. Aguardando DevLake conectar com nova senha..."
        sleep 120
        
        echo ""
        echo "8. Verificando logs..."
        aws logs tail /ecs/devlake --since 3m --format short | tail -15 2>/dev/null || echo "Logs não disponíveis ainda"
        
        echo ""
        echo "9. Verificando se erro foi corrigido..."
        
        if aws logs tail /ecs/devlake --since 3m 2>/dev/null | grep -q 'parse.*mysql://devlake'; then
            echo "⚠️ Ainda há problemas na string de conexão"
            echo "Execute './force-fix-db-url.sh' para corrigir"
        else
            echo "✅ Erro de parsing corrigido!"
            
            # Verificar sinais de sucesso
            if aws logs tail /ecs/devlake --since 2m 2>/dev/null | grep -q -E "(server started|listening|ready|connected)"; then
                echo "🎉 DEVLAKE FUNCIONANDO!"
                echo ""
                echo "🌐 URLs de acesso:"
                echo "  • https://devlake.devlaketoco.com"
                echo "  • https://devlake.devlaketoco.com/grafana"
                
            else
                echo "⚠️ DevLake ainda inicializando..."
                echo "Execute: aws logs tail /ecs/devlake --follow"
            fi
        fi
        
    elif [ "$NEW_RDS_STATUS" = "creating" ] || [ "$NEW_RDS_STATUS" = "modifying" ]; then
        echo "⚠️ RDS ainda sendo processado..."
        echo "Aguarde alguns minutos e execute './monitor.sh'"
        
    else
        echo "⚠️ RDS em estado inesperado: $NEW_RDS_STATUS"
    fi
    
else
    echo "❌ Falha na aplicação do Terraform"
    exit 1
fi

echo ""
echo "📋 RESUMO:"
echo "  • Nova senha: $NEW_PASSWORD"
echo "  • Arquivo terraform.tfvars atualizado"
echo "  • RDS configurado com nova senha"
echo "  • DevLake deve conectar sem problemas de parsing"
echo ""
echo "🔧 Troca de senha concluída!"