# terraform.tfvars.example - Exemplo de configuração das variáveis
# Copie este arquivo para terraform.tfvars e ajuste os valores

# Região AWS onde os recursos serão criados
aws_region = "us-east-1"

# Nome da tag para recursos (usado para monitoramento de custos)
tag_name = "devlaketoco"

# Configuração da VPC
vpc_cidr = "10.0.0.0/16"

# Subnets públicas (para ALB)
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]

# Subnets privadas (para ECS Tasks e RDS)
private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24"]

# Senha do banco de dados MySQL (use uma senha forte!)
db_password = "priscila$2025"

# Chave de criptografia para o DevLake (gere uma chave aleatória)
encryption_secret = "890abcdef123456854e0f6799da1870147015a824fc338953554de299358123ccbf7ea7a8edc458"

# Seu domínio (ex: meusite.com)
domain_name = "devlaketoco.com"

# Se deve criar uma nova zona no Route53 ou usar uma existente
# true = criar nova zona, false = usar zona existente
create_route53_zone = false