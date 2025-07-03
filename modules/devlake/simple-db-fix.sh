#!/bin/bash
# simple-db-fix.sh - Correção simples da DB_URL

echo "🔧 CORREÇÃO SIMPLES - DB_URL"
echo ""

# Backup
cp modules/devlake/main.tf modules/devlake/main.tf.backup.$(date +%Y%m%d-%H%M%S)

echo "📝 Abra o arquivo modules/devlake/main.tf"
echo "🔍 Procure por: name = \"DB_URL\""
echo "✏️  Na linha seguinte, substitua:"
echo ""
echo "❌ DE:"
echo '   value = "mysql://devlake:Priscila#01A"'
echo ""
echo "✅ PARA:"
echo '   value = "mysql://devlake:${var.db_password}@${module.devlake-rds.db_instance_endpoint}:3306/devlake?charset=utf8mb4&parseTime=True&loc=UTC"'
echo ""

read -p "Pressione ENTER após fazer a alteração..."

echo "🔄 Aplicando correção..."

# Parar serviço
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 >/dev/null

echo "⏳ Aguardando 30 segundos..."
sleep 30

# Aplicar nova task definition
echo "📋 Aplicando nova task definition..."
terraform apply -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve

# Reativar serviço  
echo "🔄 Reativando serviço..."
terraform apply -target="module.devlake.aws_ecs_service.devlake" -auto-approve

echo ""
echo "✅ Correção aplicada!"
echo "⏳ Aguarde 2 minutos e verifique os logs:"
echo "   aws logs tail /ecs/devlake --since 3m --follow"
echo ""
echo "🌐 Teste o acesso em alguns minutos:"
echo "   https://devlake.devlaketoco.com"