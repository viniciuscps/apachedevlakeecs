#!/bin/bash
# Script para corrigir problemas no terraform destroy
# Resolve dependências que impedem a destruição dos recursos

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    local status="$1"
    local message="$2"
    
    case "$status" in
        "SUCCESS") echo -e "${GREEN}✓ $message${NC}" ;;
        "ERROR")   echo -e "${RED}✗ $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}⚠ $message${NC}" ;;
        "INFO")    echo -e "${BLUE}ℹ $message${NC}" ;;
    esac
}

# Função para obter região AWS
get_aws_region() {
    local region
    region=$(terraform output -raw aws_region 2>/dev/null || echo "")
    
    if [[ -z "$region" ]]; then
        region=$(grep 'aws_region' terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "us-east-1")
    fi
    
    echo "$region"
}

# Função para desabilitar proteção do Load Balancer
disable_lb_protection() {
    local lb_arn="$1"
    local region="$2"
    
    print_status "INFO" "Desabilitando proteção de deleção do Load Balancer..."
    
    aws elbv2 modify-load-balancer-attributes \
        --load-balancer-arn "$lb_arn" \
        --attributes Key=deletion_protection.enabled,Value=false \
        --region "$region"
    
    print_status "SUCCESS" "Proteção de deleção desabilitada"
}

# Função para liberar endereços IP públicos
release_public_addresses() {
    local vpc_id="$1"
    local region="$2"
    
    print_status "INFO" "Verificando endereços IP públicos na VPC $vpc_id..."
    
    # Buscar Elastic IPs associados à VPC
    local eip_allocs
    eip_allocs=$(aws ec2 describe-addresses \
        --filters "Name=domain,Values=vpc" \
        --query 'Addresses[?AssociationId!=null].AllocationId' \
        --output text \
        --region "$region" 2>/dev/null || echo "")
    
    if [[ -n "$eip_allocs" ]]; then
        print_status "INFO" "Encontrados Elastic IPs para liberar: $eip_allocs"
        
        for alloc_id in $eip_allocs; do
            print_status "INFO" "Liberando Elastic IP: $alloc_id"
            
            # Desassociar primeiro
            local assoc_id
            assoc_id=$(aws ec2 describe-addresses \
                --allocation-ids "$alloc_id" \
                --query 'Addresses[0].AssociationId' \
                --output text \
                --region "$region" 2>/dev/null || echo "")
            
            if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
                aws ec2 disassociate-address \
                    --association-id "$assoc_id" \
                    --region "$region" || true
                sleep 5
            fi
            
            # Liberar o IP
            aws ec2 release-address \
                --allocation-id "$alloc_id" \
                --region "$region" || true
                
            print_status "SUCCESS" "Elastic IP $alloc_id liberado"
        done
    else
        print_status "INFO" "Nenhum Elastic IP encontrado para liberar"
    fi
}

# Função para forçar detach do Internet Gateway
force_detach_igw() {
    local igw_id="$1"
    local vpc_id="$2"
    local region="$3"
    
    print_status "INFO" "Forçando detach do Internet Gateway $igw_id..."
    
    # Tentar detach manual
    aws ec2 detach-internet-gateway \
        --internet-gateway-id "$igw_id" \
        --vpc-id "$vpc_id" \
        --region "$region" || true
    
    sleep 10
    
    # Verificar se foi detachado
    local state
    state=$(aws ec2 describe-internet-gateways \
        --internet-gateway-ids "$igw_id" \
        --query 'InternetGateways[0].Attachments[0].State' \
        --output text \
        --region "$region" 2>/dev/null || echo "detached")
    
    if [[ "$state" == "detached" || "$state" == "None" ]]; then
        print_status "SUCCESS" "Internet Gateway detachado com sucesso"
    else
        print_status "WARNING" "Internet Gateway ainda está attached"
    fi
}

# Função principal
main() {
    echo "=============================================="
    echo "   Corretor do Terraform Destroy"
    echo "=============================================="
    echo
    
    # Verificar se estamos no diretório correto
    if [[ ! -f "main.tf" ]]; then
        print_status "ERROR" "main.tf não encontrado. Execute no diretório do Terraform."
        exit 1
    fi
    
    # Obter região AWS
    local region
    region=$(get_aws_region)
    print_status "INFO" "Usando região AWS: $region"
    
    # Verificar se AWS CLI está configurado
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        print_status "ERROR" "AWS CLI não configurado ou sem permissões"
        exit 1
    fi
    
    print_status "SUCCESS" "AWS CLI configurado corretamente"
    echo
    
    # 1. Desabilitar proteção do Load Balancer
    print_status "INFO" "PASSO 1: Processando Load Balancers..."
    
    local lb_arn="arn:aws:elasticloadbalancing:us-east-1:145702441124:loadbalancer/app/devlake-alb/947a52c631206ffd"
    
    if aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --region "$region" > /dev/null 2>&1; then
        disable_lb_protection "$lb_arn" "$region"
    else
        print_status "INFO" "Load Balancer não encontrado ou já removido"
    fi
    
    echo
    
    # 2. Liberar endereços IP públicos
    print_status "INFO" "PASSO 2: Liberando endereços IP públicos..."
    
    local vpc_id="vpc-0dbc729c3e2761f55"
    release_public_addresses "$vpc_id" "$region"
    
    echo
    
    # 3. Forçar detach do Internet Gateway
    print_status "INFO" "PASSO 3: Processando Internet Gateway..."
    
    local igw_id="igw-092fe2dae96526d38"
    
    if aws ec2 describe-internet-gateways --internet-gateway-ids "$igw_id" --region "$region" > /dev/null 2>&1; then
        force_detach_igw "$igw_id" "$vpc_id" "$region"
    else
        print_status "INFO" "Internet Gateway não encontrado ou já removido"
    fi
    
    echo
    
    # 4. Aguardar propagação
    print_status "INFO" "PASSO 4: Aguardando propagação das mudanças..."
    sleep 30
    
    # 5. Tentar terraform destroy novamente
    print_status "INFO" "PASSO 5: Executando terraform destroy..."
    echo
    
    if terraform destroy -auto-approve; then
        print_status "SUCCESS" "Terraform destroy executado com sucesso!"
    else
        print_status "WARNING" "Terraform destroy ainda com problemas"
        echo
        print_status "INFO" "Recursos que podem estar causando problemas:"
        
        # Listar recursos que ainda existem
        terraform state list 2>/dev/null | while read -r resource; do
            echo "  - $resource"
        done
        
        echo
        print_status "INFO" "Tentativas de correção manual:"
        echo
        echo "1. Remover recursos específicos:"
        echo "   terraform destroy -target=aws_internet_gateway.devlake_igw"
        echo "   terraform destroy -target=aws_lb.devlake_alb"
        echo
        echo "2. Forçar remoção do estado:"
        echo "   terraform state rm aws_internet_gateway.devlake_igw"
        echo "   terraform state rm aws_lb.devlake_alb"
        echo
        echo "3. Limpeza manual via AWS CLI:"
        echo "   aws ec2 delete-internet-gateway --internet-gateway-id $igw_id --region $region"
        echo "   aws elbv2 delete-load-balancer --load-balancer-arn $lb_arn --region $region"
    fi
}

# Função para limpeza manual específica
manual_cleanup() {
    local region
    region=$(get_aws_region)
    
    print_status "INFO" "Executando limpeza manual específica..."
    
    # Load Balancer
    local lb_arn="arn:aws:elasticloadbalancing:us-east-1:145702441124:loadbalancer/app/devlake-alb/947a52c631206ffd"
    
    echo "Removendo Load Balancer..."
    aws elbv2 modify-load-balancer-attributes \
        --load-balancer-arn "$lb_arn" \
        --attributes Key=deletion_protection.enabled,Value=false \
        --region "$region" || true
    
    sleep 5
    
    aws elbv2 delete-load-balancer \
        --load-balancer-arn "$lb_arn" \
        --region "$region" || true
    
    # Internet Gateway
    local igw_id="igw-092fe2dae96526d38"
    local vpc_id="vpc-0dbc729c3e2761f55"
    
    echo "Removendo Internet Gateway..."
    aws ec2 detach-internet-gateway \
        --internet-gateway-id "$igw_id" \
        --vpc-id "$vpc_id" \
        --region "$region" || true
    
    sleep 10
    
    aws ec2 delete-internet-gateway \
        --internet-gateway-id "$igw_id" \
        --region "$region" || true
    
    print_status "SUCCESS" "Limpeza manual concluída"
}

# Função para mostrar ajuda
show_help() {
    cat << EOF
Uso: $0 [opção]

Opções:
  --manual    Executar apenas limpeza manual dos recursos problemáticos
  --help      Mostrar esta ajuda

Este script resolve problemas comuns no terraform destroy:
- Desabilita proteção de deleção do Load Balancer
- Libera endereços IP públicos (Elastic IPs)
- Força detach do Internet Gateway
- Executa terraform destroy

Problemas resolvidos:
- DependencyViolation no Internet Gateway
- Deletion protection no Load Balancer
- Elastic IPs que impedem remoção da VPC
EOF
}

# Parse de argumentos
case "${1:-}" in
    "--manual")
        manual_cleanup
        ;;
    "--help"|"-h")
        show_help
        ;;
    *)
        main
        ;;
esac