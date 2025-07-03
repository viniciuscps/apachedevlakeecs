#!/bin/bash
# deploy.sh - Script para deploy do Apache DevLake

set -e

echo "🚀 Iniciando deploy do Apache DevLake no AWS ECS..."

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Verificar se o terraform está instalado
if ! command -v terraform &> /dev/null; then
    print_error "Terraform não está instalado. Por favor, instale o Terraform primeiro."
    exit 1
fi

# Verificar se o AWS CLI está instalado e configurado
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI não está instalado. Por favor, instale o AWS CLI primeiro."
    exit 1
fi

# Verificar credenciais AWS
print_status "Verificando credenciais AWS..."
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "Credenciais AWS não configuradas. Execute 'aws configure' primeiro."
    exit 1
fi

print_success "Credenciais AWS verificadas com sucesso!"

# Verificar se o arquivo terraform.tfvars existe
if [ ! -f "terraform.tfvars" ]; then
    print_warning "Arquivo terraform.tfvars não encontrado."
    print_status "Copiando terraform.tfvars.example para terraform.tfvars..."
    cp terraform.tfvars.example terraform.tfvars
    print_warning "Por favor, edite o arquivo terraform.tfvars com seus valores antes de continuar."
    print_status "Abra o arquivo terraform.tfvars e configure:"
    echo "  - db_password: Uma senha segura para o banco de dados"
    echo "  - encryption_secret: Uma chave de criptografia segura"
    echo "  - domain_name: Seu domínio (ex: meusite.com)"
    echo "  - aws_region: Região AWS desejada"
    read -p "Pressione ENTER após configurar o terraform.tfvars..."
fi

# Inicializar Terraform
print_status "Inicializando Terraform..."
terraform init

# Validar configuração
print_status "Validando configuração do Terraform..."
terraform validate

if [ $? -eq 0 ]; then
    print_success "Configuração validada com sucesso!"
else
    print_error "Erro na validação da configuração."
    exit 1
fi

# Mostrar plano de execução
print_status "Gerando plano de execução..."
terraform plan -out=tfplan

# Confirmar deploy
echo ""
print_warning "ATENÇÃO: Este comando irá criar recursos na AWS que podem gerar custos."
print_status "Custo estimado: ~$45/mês conforme documentação oficial"
echo ""
read -p "Deseja continuar com o deploy? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_status "Deploy cancelado pelo usuário."
    exit 0
fi

# Aplicar configuração
print_status "Aplicando configuração do Terraform..."
terraform apply tfplan

if [ $? -eq 0 ]; then
    print_success "Deploy concluído com sucesso! 🎉"
    echo ""
    print_status "Recursos criados:"
    echo "  ✅ VPC com subnets públicas e privadas"
    echo "  ✅ Cluster ECS com Fargate Spot"
    echo "  ✅ Banco de dados RDS MySQL"
    echo "  ✅ Sistema de arquivos EFS para Grafana"
    echo "  ✅ Application Load Balancer"
    echo "  ✅ Certificado SSL"
    echo "  ✅ Registros DNS no Route53"
    echo ""
    print_status "URLs de acesso:"
    terraform output devlake_url
    terraform output grafana_url
    echo ""
    print_warning "IMPORTANTE:"
    echo "  - O deploy pode levar alguns minutos para ficar totalmente disponível"
    echo "  - Verifique o status dos serviços no AWS Console ECS"
    echo "  - O certificado SSL pode levar alguns minutos para ser validado"
    echo ""
    print_status "Para verificar o status dos serviços:"
    echo "  aws ecs list-services --cluster devlake-cluster"
    echo "  aws ecs describe-services --cluster devlake-cluster --services devlake config-ui grafana"
else
    print_error "Erro durante o deploy. Verifique os logs acima."
    exit 1
fi