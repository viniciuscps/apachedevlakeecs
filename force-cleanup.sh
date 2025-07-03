#!/bin/bash
# force-cleanup.sh - Limpeza forçada de recursos AWS órfãos

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

echo "🧹 LIMPEZA FORÇADA DE RECURSOS AWS - Apache DevLake"
echo ""

print_warning "⚠️ Este script remove recursos AWS mesmo que o Terraform falhe"
print_warning "⚠️ Use apenas se 'terraform destroy' falhou"
echo ""

read -p "Continuar com limpeza forçada? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_status "Operação cancelada."
    exit 0
fi

print_header "LIMPEZA FORÇADA EM ANDAMENTO"

# Função para remover proteção de deleção do ALB e forçar remoção
force_remove_alb() {
    print_status "🛡️ Forçando remoção do Application Load Balancer..."
    
    ALB_ARNS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?LoadBalancerName==`devlake-alb`].LoadBalancerArn' --output text 2>/dev/null || echo "")
    
    for ALB_ARN in $ALB_ARNS; do
        if [ ! -z "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
            print_status "📍 ALB encontrado: $ALB_ARN"
            
            # Remover proteção de deleção
            print_status "🔓 Removendo proteção de deleção..."
            aws elbv2 modify-load-balancer-attributes \
                --load-balancer-arn "$ALB_ARN" \
                --attributes Key=deletion_protection.enabled,Value=false 2>/dev/null || print_warning "Falha ao remover proteção"
            
            # Remover listeners
            print_status "🔇 Removendo listeners..."
            LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text 2>/dev/null || echo "")
            for listener_arn in $LISTENER_ARNS; do
                aws elbv2 delete-listener --listener-arn "$listener_arn" 2>/dev/null || true
            done
            
            # Remover target groups
            print_status "🎯 Removendo target groups..."
            TG_ARNS=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || echo "")
            for tg_arn in $TG_ARNS; do
                aws elbv2 delete-target-group --target-group-arn "$tg_arn" 2>/dev/null || true
            done
            
            sleep 10
            
            # Remover ALB
            print_status "🗑️ Removendo ALB..."
            aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" 2>/dev/null || print_warning "Falha ao remover ALB"
            
            print_success "✅ ALB removido: $ALB_ARN"
        fi
    done
}

# Função para forçar remoção de ECS
force_remove_ecs() {
    print_status "🐳 Forçando remoção do ECS..."
    
    # Parar e remover serviços
    CLUSTER_NAME="devlake-cluster"
    if aws ecs describe-clusters --clusters "$CLUSTER_NAME" &>/dev/null; then
        print_status "📦 Cluster ECS encontrado: $CLUSTER_NAME"
        
        # Listar e parar serviços
        SERVICES=$(aws ecs list-services --cluster "$CLUSTER_NAME" --query 'serviceArns[]' --output text 2>/dev/null || echo "")
        for service_arn in $SERVICES; do
            service_name=$(basename "$service_arn")
            print_status "⏹️ Parando serviço: $service_name"
            
            # Definir desired count para 0
            aws ecs update-service --cluster "$CLUSTER_NAME" --service "$service_name" --desired-count 0 2>/dev/null || true
            
            sleep 10
            
            # Deletar serviço
            aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$service_name" --force 2>/dev/null || true
        done
        
        # Aguardar serviços pararem
        print_status "⏳ Aguardando serviços pararem..."
        sleep 30
        
        # Remover task definitions
        print_status "📋 Removendo task definitions..."
        TASK_FAMILIES=("devlake" "config-ui" "grafana")
        for family in "${TASK_FAMILIES[@]}"; do
            # Listar todas as revisões
            REVISIONS=$(aws ecs list-task-definitions --family-prefix "$family" --query 'taskDefinitionArns[]' --output text 2>/dev/null || echo "")
            for task_def_arn in $REVISIONS; do
                aws ecs deregister-task-definition --task-definition "$task_def_arn" 2>/dev/null || true
            done
        done
        
        # Remover cluster
        print_status "🗑️ Removendo cluster ECS..."
        aws ecs delete-cluster --cluster "$CLUSTER_NAME" 2>/dev/null || print_warning "Falha ao remover cluster ECS"
        
        print_success "✅ ECS removido"
    else
        print_status "ℹ️ Cluster ECS não encontrado"
    fi
}

# Função para forçar remoção de RDS
force_remove_rds() {
    print_status "🗄️ Forçando remoção do RDS..."
    
    DB_IDENTIFIER="devlake-db"
    if aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" &>/dev/null; then
        print_status "💾 RDS encontrado: $DB_IDENTIFIER"
        
        # Remover proteção de deleção se houver
        aws rds modify-db-instance \
            --db-instance-identifier "$DB_IDENTIFIER" \
            --no-deletion-protection \
            --apply-immediately 2>/dev/null || print_warning "Falha ao remover proteção de deleção do RDS"
        
        sleep 10
        
        # Deletar RDS sem snapshot final
        print_status "🗑️ Removendo instância RDS..."
        aws rds delete-db-instance \
            --db-instance-identifier "$DB_IDENTIFIER" \
            --skip-final-snapshot \
            --delete-automated-backups 2>/dev/null || print_warning "Falha ao remover RDS"
        
        print_success "✅ RDS removido"
    else
        print_status "ℹ️ RDS não encontrado"
    fi
}

# Função para forçar remoção de EFS
force_remove_efs() {
    print_status "💿 Forçando remoção do EFS..."
    
    # Buscar EFS com creation token do grafana
    EFS_IDS=$(aws efs describe-file-systems --query 'FileSystems[?CreationToken==`grafana-storage`].FileSystemId' --output text 2>/dev/null || echo "")
    
    for efs_id in $EFS_IDS; do
        if [ ! -z "$efs_id" ] && [ "$efs_id" != "None" ]; then
            print_status "📁 EFS encontrado: $efs_id"
            
            # Remover mount targets
            print_status "🔗 Removendo mount targets..."
            MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id "$efs_id" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || echo "")
            for mt_id in $MOUNT_TARGETS; do
                aws efs delete-mount-target --mount-target-id "$mt_id" 2>/dev/null || true
            done
            
            # Aguardar remoção dos mount targets
            sleep 30
            
            # Remover access points
            print_status "🚪 Removendo access points..."
            ACCESS_POINTS=$(aws efs describe-access-points --file-system-id "$efs_id" --query 'AccessPoints[].AccessPointId' --output text 2>/dev/null || echo "")
            for ap_id in $ACCESS_POINTS; do
                aws efs delete-access-point --access-point-id "$ap_id" 2>/dev/null || true
            done
            
            sleep 10
            
            # Remover EFS
            print_status "🗑️ Removendo EFS..."
            aws efs delete-file-system --file-system-id "$efs_id" 2>/dev/null || print_warning "Falha ao remover EFS"
            
            print_success "✅ EFS removido: $efs_id"
        fi
    done
}

# Função para liberar Elastic IPs
force_release_eips() {
    print_status "🔌 Liberando Elastic IPs..."
    
    # Buscar EIPs com tag do DevLake
    EIP_DATA=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=*devlake*" --query 'Addresses[].[AllocationId,AssociationId]' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$EIP_DATA" ]; then
        echo "$EIP_DATA" | while read alloc_id assoc_id; do
            if [ ! -z "$alloc_id" ]; then
                print_status "📍 Processando EIP: $alloc_id"
                
                # Desassociar se estiver associado
                if [ ! -z "$assoc_id" ] && [ "$assoc_id" != "None" ]; then
                    print_status "🔓 Desassociando EIP..."
                    aws ec2 disassociate-address --association-id "$assoc_id" 2>/dev/null || true
                    sleep 5
                fi
                
                # Liberar EIP
                print_status "🆓 Liberando EIP..."
                aws ec2 release-address --allocation-id "$alloc_id" 2>/dev/null || print_warning "Falha ao liberar EIP $alloc_id"
            fi
        done
        print_success "✅ Elastic IPs processados"
    else
        print_status "ℹ️ Nenhum Elastic IP encontrado"
    fi
}

# Função para forçar remoção de VPC e dependências
force_remove_vpc() {
    print_status "🌐 Forçando remoção da VPC..."
    
    # Buscar VPC do DevLake
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*devlake*" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        print_status "🏠 VPC encontrada: $VPC_ID"
        
        # 1. Terminar instâncias EC2
        print_status "🖥️ Terminando instâncias EC2..."
        INSTANCE_IDS=$(aws ec2 describe-instances \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped,stopping" \
            --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
        
        if [ ! -z "$INSTANCE_IDS" ]; then
            aws ec2 terminate-instances --instance-ids $INSTANCE_IDS 2>/dev/null || true
            print_status "⏳ Aguardando terminação das instâncias..."
            aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS 2>/dev/null || print_warning "Timeout aguardando terminação"
        fi
        
        # 2. Remover NAT Gateways
        print_status "🚪 Removendo NAT Gateways..."
        NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State==`available`].NatGatewayId' --output text 2>/dev/null || echo "")
        for nat_id in $NAT_GW_IDS; do
            if [ ! -z "$nat_id" ]; then
                aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" 2>/dev/null || true
            fi
        done
        
        if [ ! -z "$NAT_GW_IDS" ]; then
            print_status "⏳ Aguardando remoção dos NAT Gateways..."
            sleep 60
        fi
        
        # 3. Remover ENIs não anexados
        print_status "🔗 Removendo ENIs órfãos..."
        ENI_IDS=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || echo "")
        
        for eni_id in $ENI_IDS; do
            if [ ! -z "$eni_id" ]; then
                aws ec2 delete-network-interface --network-interface-id "$eni_id" 2>/dev/null || true
            fi
        done
        
        # 4. Remover VPC Endpoints
        print_status "🔌 Removendo VPC Endpoints..."
        VPC_ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || echo "")
        for endpoint_id in $VPC_ENDPOINT_IDS; do
            if [ ! -z "$endpoint_id" ]; then
                aws ec2 delete-vpc-endpoint --vpc-endpoint-id "$endpoint_id" 2>/dev/null || true
            fi
        done
        
        # 5. Remover Security Groups (exceto default)
        print_status "🛡️ Removendo Security Groups..."
        SG_IDS=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo "")
        
        # Remover regras primeiro para quebrar dependências
        for sg_id in $SG_IDS; do
            if [ ! -z "$sg_id" ]; then
                # Remover regras de ingress
                aws ec2 revoke-security-group-ingress --group-id "$sg_id" --source-group "$sg_id" --protocol all 2>/dev/null || true
                # Remover regras de egress
                aws ec2 revoke-security-group-egress --group-id "$sg_id" --protocol all --cidr 0.0.0.0/0 2>/dev/null || true
            fi
        done
        
        # Aguardar e remover security groups
        sleep 10
        for sg_id in $SG_IDS; do
            if [ ! -z "$sg_id" ]; then
                aws ec2 delete-security-group --group-id "$sg_id" 2>/dev/null || true
            fi
        done
        
        # 6. Desassociar e remover route tables (exceto main)
        print_status "🗺️ Removendo Route Tables..."
        RT_IDS=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null || echo "")
        
        for rt_id in $RT_IDS; do
            if [ ! -z "$rt_id" ]; then
                # Desassociar subnets
                ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$rt_id" --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' --output text 2>/dev/null || echo "")
                for assoc_id in $ASSOC_IDS; do
                    aws ec2 disassociate-route-table --association-id "$assoc_id" 2>/dev/null || true
                done
                
                # Remover route table
                aws ec2 delete-route-table --route-table-id "$rt_id" 2>/dev/null || true
            fi
        done
        
        # 7. Remover subnets
        print_status "🏘️ Removendo Subnets..."
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
        for subnet_id in $SUBNET_IDS; do
            if [ ! -z "$subnet_id" ]; then
                aws ec2 delete-subnet --subnet-id "$subnet_id" 2>/dev/null || true
            fi
        done
        
        # 8. Desanexar e remover Internet Gateway
        print_status "🌍 Removendo Internet Gateway..."
        IGW_ID=$(aws ec2 describe-internet-gateways \
            --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
            --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
        
        if [ ! -z "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
            aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
            sleep 5
            aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null || true
        fi
        
        # 9. Finalmente, remover VPC
        print_status "🗑️ Removendo VPC..."
        sleep 10
        aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || print_warning "Falha ao remover VPC - pode ter dependências restantes"
        
        print_success "✅ VPC removida: $VPC_ID"
    else
        print_status "ℹ️ VPC não encontrada"
    fi
}

# Função para limpar certificados ACM
force_remove_certificates() {
    print_status "🔒 Removendo certificados ACM..."
    
    CERT_ARNS=$(aws acm list-certificates --query 'CertificateSummaryList[?contains(DomainName,`devlake`)].CertificateArn' --output text 2>/dev/null || echo "")
    
    for cert_arn in $CERT_ARNS; do
        if [ ! -z "$cert_arn" ]; then
            print_status "📜 Removendo certificado: $cert_arn"
            aws acm delete-certificate --certificate-arn "$cert_arn" 2>/dev/null || print_warning "Falha ao remover certificado (pode estar em uso)"
        fi
    done
}

# Função para limpar registros Route53
force_remove_route53() {
    print_status "📍 Limpando registros Route53..."
    
    # Buscar zonas do DevLake
    ZONE_IDS=$(aws route53 list-hosted-zones --query 'HostedZones[?contains(Name,`devlake`)].Id' --output text 2>/dev/null || echo "")
    
    for zone_id in $ZONE_IDS; do
        zone_id=$(basename "$zone_id")  # Remover /hostedzone/ prefix
        if [ ! -z "$zone_id" ]; then
            print_status "🌐 Processando zona: $zone_id"
            
            # Listar registros (exceto NS e SOA)
            RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' --output json 2>/dev/null || echo "[]")
            
            # Remover registros não-essenciais
            echo "$RECORDS" | jq -c '.[]' 2>/dev/null | while read record; do
                if [ ! -z "$record" ]; then
                    # Criar changeset para deletar
                    aws route53 change-resource-record-sets \
                        --hosted-zone-id "$zone_id" \
                        --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$record}]}" 2>/dev/null || true
                fi
            done
        fi
    done
}

# Executar limpeza forçada
print_header "INICIANDO LIMPEZA FORÇADA"

print_status "Etapa 1/8: Removendo Application Load Balancer..."
force_remove_alb

print_status "Etapa 2/8: Removendo ECS..."
force_remove_ecs

print_status "Etapa 3/8: Removendo RDS..."
force_remove_rds

print_status "Etapa 4/8: Removendo EFS..."
force_remove_efs

print_status "Etapa 5/8: Liberando Elastic IPs..."
force_release_eips

print_status "Etapa 6/8: Removendo certificados ACM..."
force_remove_certificates

print_status "Etapa 7/8: Limpando Route53..."
force_remove_route53

print_status "Etapa 8/8: Removendo VPC e dependências..."
force_remove_vpc

print_header "LIMPEZA FORÇADA CONCLUÍDA"

print_success "🎉 Limpeza forçada concluída!"
echo ""
print_warning "📋 VERIFICAÇÕES FINAIS RECOMENDADAS:"
echo "  1. 🌐 AWS Console > VPC > Verificar se VPCs foram removidas"
echo "  2. ⚖️ AWS Console > EC2 > Load Balancers"
echo "  3. 🗄️ AWS Console > RDS > Databases"
echo "  4. 💿 AWS Console > EFS > File Systems"
echo "  5. 🔌 AWS Console > EC2 > Elastic IPs"
echo "  6. 🛡️ AWS Console > EC2 > Security Groups"
echo "  7. 📍 AWS Console > Route53 > Hosted Zones"
echo "  8. 🔒 AWS Console > ACM > Certificates"
echo ""

print_status "🔧 Se ainda houver recursos órfãos:"
echo "  terraform refresh                    # Atualizar state"
echo "  terraform state list                # Listar recursos restantes"
echo "  terraform destroy                   # Tentar destroy novamente"
echo ""

print_success "💰 Custos mensais eliminados! Verifique o AWS Console para confirmação final."