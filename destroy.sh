#!/bin/bash
# destroy.sh - Script para destruir a infraestrutura do Apache DevLake (MELHORADO)

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Função para imprimir mensagens coloridas
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

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

echo "🗑️  DESTRUIÇÃO COMPLETA DA INFRAESTRUTURA APACHE DEVLAKE"
echo ""

print_header "AVISO CRÍTICO"
print_error "⚠️  ESTE SCRIPT IRÁ DESTRUIR TODA A INFRAESTRUTURA!"
print_error "⚠️  TODOS OS DADOS SERÃO PERDIDOS PERMANENTEMENTE!"
print_error "⚠️  NÃO HÁ COMO DESFAZER ESTA OPERAÇÃO!"
echo ""

print_warning "Recursos que serão removidos:"
echo "  🗂️  Cluster ECS e todos os serviços"
echo "  🗄️  Banco de dados RDS MySQL (e todos os dados)"
echo "  💾  Sistema de arquivos EFS (dashboards do Grafana)"
echo "  ⚖️  Application Load Balancer (com proteção de deleção)"
echo "  🌐  VPC e todos os recursos de rede"
echo "  🔒  Certificados SSL"
echo "  📍  Registros DNS no Route53"
echo "  🔌  NAT Gateways e Elastic IPs"
echo "  🛡️  Security Groups e recursos IAM"
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

# Opção de backup
print_header "BACKUP DE SEGURANÇA"
print_status "🔄 Verificando se existem recursos para backup..."

# Verificar se RDS existe
RDS_EXISTS=false
if aws rds describe-db-instances --db-instance-identifier devlake-db &> /dev/null; then
    RDS_EXISTS=true
    print_warning "📊 Banco de dados RDS encontrado!"
    
    read -p "Deseja criar um backup do banco antes da destruição? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        print_status "📦 Criando backup do banco de dados..."
        
        BACKUP_NAME="devlake-final-backup-$(date +%Y%m%d-%H%M%S)"
        
        aws rds create-db-snapshot \
            --db-instance-identifier devlake-db \
            --db-snapshot-identifier "$BACKUP_NAME" || {
            print_warning "⚠️ Falha ao criar backup, mas continuando..."
        }
        
        if [ $? -eq 0 ]; then
            print_success "✅ Backup criado: $BACKUP_NAME"
            print_status "⏳ Aguardando backup completar..."
            
            # Aguardar o backup completar (com timeout)
            aws rds wait db-snapshot-completed --db-snapshot-identifier "$BACKUP_NAME" --cli-read-timeout 300 || {
                print_warning "⚠️ Timeout no backup, mas continuando destruição..."
            }
            
            if [ $? -eq 0 ]; then
                print_success "✅ Backup concluído com sucesso!"
            fi
        fi
    fi
fi

print_header "CONFIRMAÇÃO FINAL"
print_error "🔥 DESTRUIÇÃO IRREVERSÍVEL"
echo ""
print_warning "Para confirmar, digite exatamente: DESTRUIR TUDO"
read -p "Confirmação: " confirmation

if [ "$confirmation" != "DESTRUIR TUDO" ]; then
    print_status "❌ Operação cancelada pelo usuário."
    exit 0
fi

print_header "INICIANDO DESTRUIÇÃO ORDENADA"

# Função para remover proteção de deleção do ALB
remove_alb_protection() {
    print_status "🛡️ Removendo proteção de deleção do ALB..."
    
    ALB_ARN=$(aws elbv2 describe-load-balancers --names devlake-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
        print_status "ALB encontrado: $ALB_ARN"
        
        # Verificar se proteção está habilitada
        PROTECTION_ENABLED=$(aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$ALB_ARN" --query 'Attributes[?Key==`deletion_protection.enabled`].Value' --output text 2>/dev/null || echo "false")
        
        if [ "$PROTECTION_ENABLED" = "true" ]; then
            print_status "🔓 Desabilitando proteção de deleção..."
            aws elbv2 modify-load-balancer-attributes \
                --load-balancer-arn "$ALB_ARN" \
                --attributes Key=deletion_protection.enabled,Value=false || {
                print_error "❌ Falha ao remover proteção do ALB"
                return 1
            }
            print_success "✅ Proteção de deleção removida"
        else
            print_status "ℹ️ Proteção de deleção já está desabilitada"
        fi
    else
        print_status "ℹ️ ALB não encontrado ou já removido"
    fi
}

# Função para liberar Elastic IPs
release_elastic_ips() {
    print_status "🔌 Liberando Elastic IPs..."
    
    # Buscar EIPs com tag do projeto
    EIP_ALLOCS=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=devlake*" --query 'Addresses[].AllocationId' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$EIP_ALLOCS" ]; then
        for alloc_id in $EIP_ALLOCS; do
            print_status "📍 Liberando EIP: $alloc_id"
            aws ec2 release-address --allocation-id "$alloc_id" 2>/dev/null || print_warning "⚠️ Falha ao liberar EIP $alloc_id"
        done
    fi
}

# Função para forçar término de instâncias EC2 se houver
terminate_ec2_instances() {
    print_status "🖥️ Verificando instâncias EC2..."
    
    # Buscar instâncias com tag do projeto
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=devlake*" "Name=instance-state-name,Values=running,stopped,stopping" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$INSTANCE_IDS" ]; then
        print_status "🔄 Terminando instâncias EC2..."
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS || print_warning "⚠️ Falha ao terminar algumas instâncias"
        
        print_status "⏳ Aguardando terminação..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS || print_warning "⚠️ Timeout aguardando terminação"
    fi
}

# Função para limpar ENIs órfãos
cleanup_enis() {
    print_status "🔗 Limpando ENIs órfãos..."
    
    # Buscar ENIs disponíveis (não anexados) na VPC do projeto
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=devlake*" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        ENI_IDS=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || echo "")
        
        if [ ! -z "$ENI_IDS" ]; then
            for eni_id in $ENI_IDS; do
                print_status "🔌 Removendo ENI: $eni_id"
                aws ec2 delete-network-interface --network-interface-id "$eni_id" 2>/dev/null || print_warning "⚠️ Falha ao remover ENI $eni_id"
            done
        fi
    fi
}

print_status "🎯 Etapa 1/8: Preparação para destruição..."

# Executar limpezas preliminares
remove_alb_protection
terminate_ec2_instances
cleanup_enis

print_status "🎯 Etapa 2/8: Destruição ordenada dos serviços ECS..."

# Parar serviços ECS primeiro
print_status "⏹️ Parando serviços ECS..."
aws ecs update-service --cluster devlake-cluster --service devlake --desired-count 0 2>/dev/null || true
aws ecs update-service --cluster devlake-cluster --service config-ui --desired-count 0 2>/dev/null || true
aws ecs update-service --cluster devlake-cluster --service grafana --desired-count 0 2>/dev/null || true

# Aguardar parada dos serviços
print_status "⏳ Aguardando parada dos serviços..."
sleep 30

# Destruir serviços ECS
terraform destroy -target="module.devlake.aws_ecs_service.devlake" -auto-approve 2>/dev/null || true
terraform destroy -target="module.devlake.aws_ecs_service.config_ui" -auto-approve 2>/dev/null || true
terraform destroy -target="module.devlake.aws_ecs_service.grafana" -auto-approve 2>/dev/null || true

print_status "🎯 Etapa 3/8: Removendo Load Balancer..."
terraform destroy -target="module.devlake.module.devlake_alb" -auto-approve 2>/dev/null || true

print_status "🎯 Etapa 4/8: Removendo Task Definitions..."
terraform destroy -target="module.devlake.aws_ecs_task_definition.devlake" -auto-approve 2>/dev/null || true
terraform destroy -target="module.devlake.aws_ecs_task_definition.config_ui" -auto-approve 2>/dev/null || true
terraform destroy -target="module.devlake.aws_ecs_task_definition.grafana" -auto-approve 2>/dev/null || true

print_status "🎯 Etapa 5/8: Removendo Cluster ECS..."
terraform destroy -target="module.devlake.aws_ecs_cluster.devlake" -auto-approve 2>/dev/null || true

print_status "🎯 Etapa 6/8: Removendo banco de dados RDS..."
terraform destroy -target="module.devlake.module.devlake-rds" -auto-approve 2>/dev/null || true

print_status "🎯 Etapa 7/8: Liberando recursos de rede..."
release_elastic_ips

# Destruir NAT Gateways
terraform destroy -target="aws_nat_gateway.nat_gateways" -auto-approve 2>/dev/null || true

# Aguardar liberação dos NAT Gateways
print_status "⏳ Aguardando liberação dos NAT Gateways..."
sleep 60

print_status "🎯 Etapa 8/8: Destruição completa..."

# Mostrar plano de destruição final
print_status "📋 Gerando plano final de destruição..."
terraform plan -destroy -out=destroy.tfplan

echo ""
print_warning "🔥 DESTRUIÇÃO FINAL - ÚLTIMA CHANCE!"
read -p "Continuar com a destruição completa? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_status "❌ Destruição cancelada pelo usuário."
    rm -f destroy.tfplan
    exit 0
fi

# Executar destruição final
print_status "🔥 Executando destruição completa..."
print_warning "⏳ Este processo pode levar 10-15 minutos..."

terraform apply destroy.tfplan

DESTROY_EXIT_CODE=$?

# Limpeza adicional se terraform falhar parcialmente
if [ $DESTROY_EXIT_CODE -ne 0 ]; then
    print_warning "⚠️ Terraform destroy falhou parcialmente. Executando limpeza manual..."
    
    # Limpar recursos órfãos
    cleanup_enis
    release_elastic_ips
    
    # Tentar remover VPC manualmente se ainda existir
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=devlake*" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
    if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        print_status "🧹 Limpeza manual da VPC: $VPC_ID"
        
        # Remover security groups não-default
        SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo "")
        for sg_id in $SG_IDS; do
            aws ec2 delete-security-group --group-id "$sg_id" 2>/dev/null || true
        done
        
        # Remover route tables não-main
        RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null || echo "")
        for rt_id in $RT_IDS; do
            aws ec2 delete-route-table --route-table-id "$rt_id" 2>/dev/null || true
        done
        
        # Remover subnets
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
        for subnet_id in $SUBNET_IDS; do
            aws ec2 delete-subnet --subnet-id "$subnet_id" 2>/dev/null || true
        done
        
        # Remover Internet Gateway
        IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
        if [ ! -z "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
            aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null || true
        fi
        
        # Finalmente, remover VPC
        aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    fi
    
    print_warning "🔄 Tentando terraform destroy novamente..."
    terraform destroy -auto-approve || print_error "❌ Destruição manual necessária para recursos restantes"
fi

# Limpar arquivos temporários
rm -f destroy.tfplan
rm -f tfplan
rm -f *.tfplan

if [ $DESTROY_EXIT_CODE -eq 0 ]; then
    print_header "DESTRUIÇÃO CONCLUÍDA"
    print_success "🎉 Infraestrutura destruída com sucesso!"
    
    echo ""
    print_status "📊 Recursos removidos:"
    echo "  ✅ Cluster ECS e serviços"
    echo "  ✅ Banco de dados RDS"
    echo "  ✅ Sistema de arquivos EFS"
    echo "  ✅ Application Load Balancer"
    echo "  ✅ VPC e recursos de rede"
    echo "  ✅ Certificados SSL"
    echo "  ✅ Registros DNS"
    echo "  ✅ NAT Gateways e Elastic IPs"
    echo "  ✅ Security Groups"
    echo ""
    
    if [ ! -z "$BACKUP_NAME" ]; then
        print_status "💾 Backup disponível: $BACKUP_NAME"
        print_warning "⚠️ Lembre-se de remover o backup manualmente quando não precisar mais:"
        echo "  aws rds delete-db-snapshot --db-snapshot-identifier $BACKUP_NAME"
        echo ""
    fi
    
    print_warning "🔍 VERIFICAÇÃO FINAL:"
    echo "  • Verifique no AWS Console se todos os recursos foram removidos"
    echo "  • Alguns recursos podem levar alguns minutos para desaparecer completamente"
    echo "  • Certificados SSL podem permanecer por algumas horas (sem custo)"
    echo "  • Snapshots de backup precisam ser removidos manualmente"
    echo ""
    
    print_success "💰 Custos mensais (~$45-65) foram eliminados!"
    
else
    print_header "DESTRUIÇÃO PARCIAL"
    print_error "❌ Alguns recursos podem não ter sido removidos completamente"
    print_warning "🔍 Verificações necessárias:"
    echo ""
    echo "1. 🌐 AWS Console > VPC > Verificar VPCs órfãos"
    echo "2. ⚖️ AWS Console > EC2 > Load Balancers"
    echo "3. 🗄️ AWS Console > RDS > Databases"
    echo "4. 🔌 AWS Console > EC2 > Elastic IPs"
    echo "5. 🛡️ AWS Console > EC2 > Security Groups"
    echo ""
    
    print_status "🔧 Para limpeza manual:"
    echo "  terraform state list                    # Listar recursos restantes"
    echo "  terraform destroy -target=RESOURCE      # Remover recursos específicos"
    echo "  terraform refresh                       # Atualizar state"
    echo ""
    
    exit 1
fi