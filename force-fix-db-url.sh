#!/bin/bash
# force-fix-db-url.sh - Forçar correção definitiva da DB_URL

set -e

echo "🔧 CORREÇÃO DEFINITIVA FORÇADA - DB_URL"
echo ""

echo "❌ PROBLEMA CRÍTICO: DevLake ainda recebe mysql://devlake:Priscila"
echo "✅ SOLUÇÃO: Forçar atualização completa da task definition"
echo ""

# 1. Obter endpoint real do RDS
echo "1. Obtendo endpoint real do RDS..."
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier devlake-db --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" = "None" ]; then
    echo "❌ RDS não encontrado!"
    exit 1
fi

echo "✅ RDS Endpoint: $RDS_ENDPOINT"

# 2. Verificar senha
DB_PASSWORD=""
if [ -f "terraform.tfvars" ]; then
    DB_PASSWORD=$(grep -E '^db_password\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
fi

if [ -z "$DB_PASSWORD" ]; then
    echo "❌ Senha não encontrada!"
    exit 1
fi

echo "✅ Senha obtida"

# 3. Construir string correta
CORRECT_DB_URL="mysql://devlake:${DB_PASSWORD}@${RDS_ENDPOINT}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"

echo ""
echo "2. String de conexão correta:"
echo "  $CORRECT_DB_URL"

# 4. Parar serviço atual
echo ""
echo "3. Parando serviço DevLake..."
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 >/dev/null
sleep 30

# 5. Verificar e corrigir arquivo main.tf
echo ""
echo "4. Verificando arquivo modules/devlake/main.tf..."

if ! grep -q ":3306/devlake" modules/devlake/main.tf; then
    echo "❌ Arquivo main.tf ainda incorreto! Corrigindo..."
    
    # Backup
    cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)
    
    # Correção específica para a linha DB_URL
    sed -i '/name.*=.*"DB_URL"/,/value.*=/ {
        /value.*=/ c\
          value = "mysql://devlake:${var.db_password}@${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"
    }' modules/devlake/main.tf
    
    echo "✅ Arquivo corrigido"
else
    echo "✅ Arquivo parece correto"
fi

# 6. Mostrar linha atual no arquivo
echo ""
echo "5. Linha atual no arquivo:"
grep -A 1 "DB_URL" modules/devlake/main.tf | grep "value"

# 7. Remover task definition do state para forçar recriação
echo ""
echo "6. Forçando recriação da task definition..."
terraform state rm 'module.devlake.aws_ecs_task_definition.devlake' 2>/dev/null || true

# 8. Aplicar nova task definition
echo ""
echo "7. Criando nova task definition..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

if [ $? -ne 0 ]; then
    echo "❌ Falha na criação da task definition"
    exit 1
fi

# 9. Verificar nova task definition
echo ""
echo "8. Verificando nova task definition..."
sleep 10

NEW_DB_URL=$(aws ecs describe-task-definition --task-definition devlake --query 'taskDefinition.containerDefinitions[0].environment' --output json 2>/dev/null | jq -r '.[] | select(.name=="DB_URL") | .value' 2>/dev/null || echo "")

echo "Nova DB_URL na task definition:"
echo "  $NEW_DB_URL"

if [[ "$NEW_DB_URL" == *"$RDS_ENDPOINT:3306/devlake"* ]]; then
    echo "✅ DB_URL correta na task definition!"
else
    echo "❌ DB_URL AINDA INCORRETA!"
    echo ""
    echo "DEPURAÇÃO AVANÇADA:"
    echo "Esperado: mysql://devlake:*@$RDS_ENDPOINT:3306/devlake*"
    echo "Atual: $NEW_DB_URL"
    echo ""
    echo "POSSÍVEL CAUSA: Variável \${module.devlake-rds.db_instance_endpoint} não está sendo expandida"
    echo ""
    echo "SOLUÇÃO MANUAL:"
    echo "1. Edite modules/devlake/main.tf"
    echo "2. Substitua a linha DB_URL value por:"
    echo "   value = \"mysql://devlake:${DB_PASSWORD}@${RDS_ENDPOINT}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\""
    echo "3. Execute: terraform apply -target=\"module.devlake.aws_ecs_task_definition.devlake\""
    echo ""
    read -p "Fazer correção manual agora? (Y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo "Aplicando correção com endpoint hardcoded..."
        
        # Usar endpoint real em vez de variável
        sed -i "/name.*=.*\"DB_URL\"/,/value.*=/ {
            /value.*=/ c\\
          value = \"mysql://devlake:\${var.db_password}@${RDS_ENDPOINT}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC\"
        }" modules/devlake/main.tf
        
        # Aplicar novamente
        terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve
        
        # Verificar novamente
        sleep 10
        FINAL_DB_URL=$(aws ecs describe-task-definition --task-definition devlake --query 'taskDefinition.containerDefinitions[0].environment' --output json 2>/dev/null | jq -r '.[] | select(.name=="DB_URL") | .value' 2>/dev/null || echo "")
        echo "DB_URL final: $FINAL_DB_URL"
    fi
fi

# 10. Reativar serviço
echo ""
echo "9. Reativando serviço DevLake..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

echo ""
echo "10. Aguardando nova task inicializar..."
sleep 120

echo ""
echo "11. Verificando logs..."
aws logs tail /ecs/devlake --since 3m --format short | tail -15 2>/dev/null || echo "Logs não disponíveis"

echo ""
echo "12. Verificando se erro foi corrigido..."

if aws logs tail /ecs/devlake --since 3m 2>/dev/null | grep -q 'parse.*mysql://devlake:Priscila'; then
    echo "❌ ERRO AINDA PERSISTE!"
    echo ""
    echo "ÚLTIMA TENTATIVA - DEPURAÇÃO COMPLETA:"
    
    echo "Task Definition atual (completa):"
    aws ecs describe-task-definition --task-definition devlake --query 'taskDefinition.containerDefinitions[0].environment'
    
    echo ""
    echo "Arquivo main.tf (linha DB_URL):"
    grep -A 2 -B 2 "DB_URL" modules/devlake/main.tf
    
    echo ""
    echo "PROBLEMA: Task definition não está sendo atualizada corretamente"
    echo "SOLUÇÃO: Verificar se há cache ou problemas de dependência"
    
else
    echo "✅ ERRO CORRIGIDO!"
    echo ""
    echo "Aguardando DevLake conectar ao banco..."
    sleep 60
    
    if aws logs tail /ecs/devlake --since 2m 2>/dev/null | grep -q -E "(server started|listening|ready|connected)"; then
        echo "🎉 DEVLAKE FUNCIONANDO!"
        echo ""
        echo "🌐 URLs de acesso:"
        echo "  • https://devlake.devlaketoco.com"
        echo "  • https://devlake.devlaketoco.com/grafana"
    else
        echo "⚠️ DevLake ainda inicializando..."
    fi
fi

echo ""
echo "🔧 Correção forçada concluída!"