#!/bin/bash
# fix-deployment.sh - Script para corrigir problemas no deployment do DevLake

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

echo "🔧 Corrigindo problemas no deployment do Apache DevLake..."
echo ""

print_error "PROBLEMA IDENTIFICADO:"
echo "  • Target group attachments manuais estão conflitando com ECS"
echo "  • O ECS deve gerenciar automaticamente os targets do ALB"
echo ""

# Verificar se estamos no diretório correto
if [ ! -f "main.tf" ]; then
    print_error "Este script deve ser executado no diretório raiz do Terraform"
    print_status "Certifique-se de estar no diretório que contém o main.tf"
    exit 1
fi

# Verificar se o Terraform está inicializado
if [ ! -d ".terraform" ]; then
    print_status "Inicializando Terraform..."
    terraform init
fi

print_warning "Este script irá:"
echo "  1. Remover recursos problemáticos (target group attachments)"
echo "  2. Atualizar configuração do Terraform"
echo "  3. Aplicar configuração corrigida"
echo ""

read -p "Continuar com a correção? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    print_status "Operação cancelada pelo usuário."
    exit 0
fi

print_status "Etapa 1/4: Removendo recursos problemáticos..."

# Tentar remover os target group attachments se existirem
terraform destroy -target="module.devlake.aws_lb_target_group_attachment.grafana[0]" -auto-approve 2>/dev/null || print_warning "  Target group attachment Grafana não encontrado (já removido)"
terraform destroy -target="module.devlake.aws_lb_target_group_attachment.config_ui[0]" -auto-approve 2>/dev/null || print_warning "  Target group attachment Config UI não encontrado (já removido)"

print_success "Recursos problemáticos removidos!"

print_status "Etapa 2/4: Verificando integridade do state..."
terraform refresh

print_status "Etapa 3/4: Validando configuração..."
terraform validate

if [ $? -eq 0 ]; then
    print_success "Configuração validada com sucesso!"
else
    print_error "Erro na validação da configuração."
    exit 1
fi

print_status "Etapa 4/4: Aplicando configuração corrigida..."

# Aplicar a configuração corrigida
terraform apply -auto-approve

if [ $? -eq 0 ]; then
    print_success "🎉 Deployment corrigido com sucesso!"
    echo ""
    
    print_status "Aguardando serviços estabilizarem..."
    sleep 60
    
    # Verificar status dos serviços
    print_status "Verificando status dos serviços ECS..."
    
    # Verificar se os serviços estão rodando
    DEVLAKE_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services devlake --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
    CONFIG_UI_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services config-ui --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
    GRAFANA_RUNNING=$(aws ecs describe-services --cluster devlake-cluster --services grafana --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
    
    if [ "$DEVLAKE_RUNNING" -gt 0 ]; then
        print_success "DevLake: $DEVLAKE_RUNNING instância(s) rodando ✅"
    else
        print_warning "DevLake: Nenhuma instância rodando ⚠️"
    fi
    
    if [ "$CONFIG_UI_RUNNING" -gt 0 ]; then
        print_success "Config UI: $CONFIG_UI_RUNNING instância(s) rodando ✅"
    else
        print_warning "Config UI: Nenhuma instância rodando ⚠️"
    fi
    
    if [ "$GRAFANA_RUNNING" -gt 0 ]; then
        print_success "Grafana: $GRAFANA_RUNNING instância(s) rodando ✅"
    else
        print_warning "Grafana: Nenhuma instância rodando ⚠️"
    fi
    
    echo ""
    print_status "Verificando target groups do ALB..."
    
    # Buscar ARNs dos target groups
    TG_GRAFANA=$(aws elbv2 describe-target-groups --names devlake-grafana-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
    TG_CONFIG_UI=$(aws elbv2 describe-target-groups --names devlake-config-ui-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$TG_GRAFANA" ] && [ "$TG_GRAFANA" != "None" ]; then
        HEALTHY_GRAFANA=$(aws elbv2 describe-target-health --target-group-arn "$TG_GRAFANA" --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]' --output text 2>/dev/null | wc -l)
        TOTAL_GRAFANA=$(aws elbv2 describe-target-health --target-group-arn "$TG_GRAFANA" --query 'TargetHealthDescriptions' --output text 2>/dev/null | wc -l)
        
        if [ "$HEALTHY_GRAFANA" -gt 0 ]; then
            print_success "Target Group Grafana: $HEALTHY_GRAFANA/$TOTAL_GRAFANA healthy ✅"
        else
            print_warning "Target Group Grafana: $HEALTHY_GRAFANA/$TOTAL_GRAFANA healthy (aguardando health check...)"
        fi
    fi
    
    if [ ! -z "$TG_CONFIG_UI" ] && [ "$TG_CONFIG_UI" != "None" ]; then
        HEALTHY_CONFIG_UI=$(aws elbv2 describe-target-health --target-group-arn "$TG_CONFIG_UI" --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]' --output text 2>/dev/null | wc -l)
        TOTAL_CONFIG_UI=$(aws elbv2 describe-target-health --target-group-arn "$TG_CONFIG_UI" --query 'TargetHealthDescriptions' --output text 2>/dev/null | wc -l)
        
        if [ "$HEALTHY_CONFIG_UI" -gt 0 ]; then
            print_success "Target Group Config UI: $HEALTHY_CONFIG_UI/$TOTAL_CONFIG_UI healthy ✅"
        else
            print_warning "Target Group Config UI: $HEALTHY_CONFIG_UI/$TOTAL_CONFIG_UI healthy (aguardando health check...)"
        fi
    fi
    
    echo ""
    print_status "URLs de acesso:"
    
    # Extrair domain_name do terraform.tfvars
    DOMAIN_NAME=""
    if [ -f "terraform.tfvars" ]; then
        DOMAIN_NAME=$(grep -E '^domain_name\s*=' terraform.tfvars | sed 's/.*=\s*"\([^"]*\)".*/\1/' 2>/dev/null || echo "")
    fi
    
    if [ ! -z "$DOMAIN_NAME" ]; then
        echo "  🌐 DevLake UI: https://devlake.$DOMAIN_NAME"
        echo "  📊 Grafana: https://devlake.$DOMAIN_NAME/grafana"
    else
        terraform output devlake_url 2>/dev/null || echo "  🌐 DevLake UI: https://devlake.seu-dominio.com"
        terraform output grafana_url 2>/dev/null || echo "  📊 Grafana: https://devlake.seu-dominio.com/grafana"
    fi
    
    echo ""
    print_warning "PRÓXIMOS PASSOS:"
    echo "  1. Aguarde ~5 minutos para os health checks estabilizarem"
    echo "  2. Execute './monitor.sh' para acompanhar o status"
    echo "  3. Teste o acesso às URLs acima"
    echo "  4. Configure suas integrações no DevLake"
    
    echo ""
    print_warning "TROUBLESHOOTING:"
    echo "  • Se os serviços não responderem, verifique os logs:"
    echo "    aws logs tail /ecs/devlake --follow"
    echo "    aws logs tail /ecs/config-ui --follow"
    echo "    aws logs tail /ecs/grafana --follow"
    echo ""
    echo "  • Para verificar targets do ALB:"
    echo "    aws elbv2 describe-target-health --target-group-arn $TG_CONFIG_UI"
    echo "    aws elbv2 describe-target-health --target-group-arn $TG_GRAFANA"
    
else
    print_error "❌ Erro durante a correção. Verificando problemas..."
    
    print_status "Diagnóstico rápido:"
    
    # Verificar se cluster existe
    if aws ecs describe-clusters --clusters devlake-cluster &>/dev/null; then
        print_success "Cluster ECS existe"
    else
        print_error "Cluster ECS não encontrado"
    fi
    
    # Verificar se RDS existe
    if aws rds describe-db-instances --db-instance-identifier devlake-db &>/dev/null; then
        print_success "Banco RDS existe"
    else
        print_error "Banco RDS não encontrado"
    fi
    
    # Verificar se ALB existe
    if aws elbv2 describe-load-balancers --names devlake-alb &>/dev/null; then
        print_success "ALB existe"
    else
        print_error "ALB não encontrado"
    fi
    
    echo ""
    print_error "Recomendações para corrigir:"
    echo "  1. Verifique os logs do Terraform acima"
    echo "  2. Execute: terraform plan (para ver o que está pendente)"
    echo "  3. Se necessário: terraform destroy && terraform apply"
    echo "  4. Verifique suas credenciais AWS e permissões"
    
    exit 1
fi

echo ""
print_success "🚀 Correção concluída! Execute './monitor.sh' para monitoramento contínuo."