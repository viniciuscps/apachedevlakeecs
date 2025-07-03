#!/bin/bash
# fix-devlake-final.sh - Correção final do DevLake

set -e

echo "🔧 CORREÇÃO FINAL DO DEVLAKE - DB_URL"
echo ""

echo "❌ PROBLEMA: DevLake ainda recebe DB_URL incorreta"
echo "String atual: mysql://devlake:Priscila"
echo "String esperada: mysql://devlake:Priscila@endpoint:3306/devlake..."
echo ""

# Obter endpoint real do RDS
echo "1. Obtendo endpoint real do RDS..."
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" = "None" ]; then
    echo "❌ RDS endpoint não encontrado!"
    exit 1
else
    echo "✅ RDS endpoint: $RDS_ENDPOINT"
fi

# Verificar task definition atual
echo ""
echo "2. Verificando task definition atual..."
CURRENT_DB_URL=$(aws ecs describe-task-definition --task-definition devlake --query 'taskDefinition.containerDefinitions[0].environment' --output json 2>/dev/null | jq -r '.[] | select(.name=="DB_URL") | .value' 2>/dev/null || echo "")

echo "DB_URL atual na task definition:"
echo "  $CURRENT_DB_URL"

if [[ "$CURRENT_DB_URL" == *":3306/devlake"* ]]; then
    echo "✅ DB_URL parece correta na task definition"
    echo "❌ Mas container ainda recebe string incorreta"
    echo ""
    echo "CAUSA: Task definition não foi aplicada ou há cache"
else
    echo "❌ DB_URL incorreta na task definition!"
fi

echo ""
echo "3. Parando serviço atual..."
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 >/dev/null

echo "Aguardando parada completa..."
sleep 30

echo ""
echo "4. Verificando arquivo modules/devlake/main.tf..."

# Verificar se DB_URL está correta no arquivo
if grep -q ":3306/devlake" modules/devlake/main.tf; then
    echo "✅ DB_URL correta no arquivo main.tf"
else
    echo "❌ DB_URL incorreta no arquivo! Corrigindo..."
    
    # Fazer backup
    cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)
    
    # Corrigir usando sed
    sed -i 's|mysql://devlake:\${var\.db_password}@\${module\.devlake-rds\.db_instance_endpoint}/devlake|mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake|g' modules/devlake/main.tf
    
    echo "✅ DB_URL corrigida no arquivo"
fi

echo ""
echo "5. Forçando nova task definition..."

# Forçar nova task definition
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

if [ $? -eq 0 ]; then
    echo "✅ Nova task definition aplicada"
else
    echo "❌ Falha na task definition"
    exit 1
fi

echo ""
echo "6. Verificando nova task definition..."
sleep 10

NEW_DB_URL=$(aws ecs describe-task-definition --task-definition devlake --query 'taskDefinition.containerDefinitions[0].environment' --output json 2>/dev/null | jq -r '.[] | select(.name=="DB_URL") | .value' 2>/dev/null || echo "")

echo "Nova DB_URL na task definition:"
echo "  $NEW_DB_URL"

if [[ "$NEW_DB_URL" == *"$RDS_ENDPOINT:3306/devlake"* ]]; then
    echo "✅ DB_URL correta com endpoint real!"
else
    echo "❌ DB_URL ainda incorreta!"
    echo ""
    echo "VERIFICAÇÃO MANUAL NECESSÁRIA:"
    echo "1. Abra: modules/devlake/main.tf"
    echo "2. Procure por: name = \"DB_URL\""
    echo "3. Certifique-se que a linha value tenha:"
    echo "   value = \"mysql://devlake:\${var.db_password}@\${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\""
    echo ""
    read -p "Pressione ENTER após verificar/corrigir..."
    
    # Tentar aplicar novamente
    terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve
fi

echo ""
echo "7. Reativando serviço DevLake..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

echo ""
echo "8. Aguardando nova task inicializar..."
sleep 120

echo ""
echo "9. Verificando logs mais recentes..."
aws logs tail /ecs/devlake --since 3m --format short | tail -15 2>/dev/null || echo "Logs ainda não disponíveis"

echo ""
echo "10. Verificando se erro persiste..."

# Verificar se ainda tem o erro
if aws logs tail /ecs/devlake --since 3m 2>/dev/null | grep -q 'parse.*mysql://devlake:Priscila'; then
    echo "❌ ERRO AINDA PERSISTE!"
    echo ""
    echo "DIAGNÓSTICO ADICIONAL:"
    
    # Mostrar exatamente o que está na task definition
    echo "Task definition completa (DB_URL):"
    aws ecs describe-task-definition --task-definition devlake --query 'taskDefinition.containerDefinitions[0].environment' --output json | jq '.[] | select(.name=="DB_URL")'
    
    echo ""
    echo "PRÓXIMOS PASSOS:"
    echo "1. Verificar se variável \${module.devlake-rds.db_instance_endpoint} está sendo expandida"
    echo "2. Verificar se há problemas de dependência entre modules"
    echo "3. Tentar terraform refresh && terraform apply"
    
else
    echo "✅ ERRO CORRIGIDO!"
    echo ""
    echo "Verificando se DevLake conectou ao banco..."
    
    sleep 60
    
    # Verificar logs para sinais de sucesso
    if aws logs tail /ecs/devlake --since 2m 2>/dev/null | grep -q -E "(server started|listening|ready|connected)"; then
        echo "✅ DevLake iniciou com sucesso!"
        
        echo ""
        echo "🌐 URLs de acesso:"
        echo "  • https://devlake.devlaketoco.com (Config UI)"
        echo "  • https://devlake.devlaketoco.com/grafana (Grafana)"
        
        echo ""
        echo "🎉 DEVLAKE FUNCIONANDO!"
        
    else
        echo "⚠️ DevLake ainda inicializando..."
        echo "Execute: aws logs tail /ecs/devlake --follow"
    fi
fi

echo ""
echo "🔧 Correção final concluída!"