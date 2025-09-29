#!/bin/bash

# Script de Deploy Automatizado - Projeto BIA
# Versiona usando commit hash (7 dígitos) e atualiza ECS

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para log
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Verificar parâmetros
if [ $# -ne 2 ]; then
    echo "Uso: $0 <CLUSTER_NAME> <SERVICE_NAME>"
    echo "Exemplo: $0 cluster-bia-alb service-bia-alb"
    exit 1
fi

CLUSTER_NAME=$1
SERVICE_NAME=$2

log "Iniciando deploy para Cluster: $CLUSTER_NAME, Service: $SERVICE_NAME"

# Verificar se estamos em um repositório Git
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    error "Este diretório não é um repositório Git válido"
fi

# Obter commit hash (7 dígitos)
COMMIT_HASH=$(git rev-parse --short=7 HEAD)
if [ -z "$COMMIT_HASH" ]; then
    error "Não foi possível obter o commit hash"
fi

log "Commit Hash: $COMMIT_HASH"

# Configurações AWS
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

if [ -z "$AWS_ACCOUNT_ID" ]; then
    error "Não foi possível obter o Account ID da AWS"
fi

ECR_REPOSITORY="bia"
IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$COMMIT_HASH"

log "AWS Account ID: $AWS_ACCOUNT_ID"
log "AWS Region: $AWS_REGION"
log "Image URI: $IMAGE_URI"

# Verificar se o cluster existe
log "Verificando se o cluster $CLUSTER_NAME existe..."
if ! aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then
    error "Cluster $CLUSTER_NAME não encontrado ou não está ativo"
fi

# Verificar se o serviço existe
log "Verificando se o service $SERVICE_NAME existe..."
if ! aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then
    error "Service $SERVICE_NAME não encontrado no cluster $CLUSTER_NAME"
fi

# Verificar se a imagem já existe no ECR
log "Verificando se a imagem $COMMIT_HASH já existe no ECR..."
if aws ecr describe-images --repository-name "$ECR_REPOSITORY" --image-ids imageTag="$COMMIT_HASH" >/dev/null 2>&1; then
    warning "Imagem $COMMIT_HASH já existe no ECR. Pulando build..."
    SKIP_BUILD=true
else
    SKIP_BUILD=false
fi

# Build e push da imagem Docker (se necessário)
if [ "$SKIP_BUILD" = false ]; then
    log "Fazendo login no ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    log "Construindo imagem Docker..."
    docker build -t "$ECR_REPOSITORY:$COMMIT_HASH" .

    log "Taggeando imagem para ECR..."
    docker tag "$ECR_REPOSITORY:$COMMIT_HASH" "$IMAGE_URI"

    log "Enviando imagem para ECR..."
    docker push "$IMAGE_URI"
    
    success "Imagem $COMMIT_HASH enviada para ECR com sucesso"
fi

# Obter task definition atual
log "Obtendo task definition atual do service..."
CURRENT_TASK_DEF=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].taskDefinition' --output text)

if [ -z "$CURRENT_TASK_DEF" ]; then
    error "Não foi possível obter a task definition atual"
fi

TASK_FAMILY=$(echo "$CURRENT_TASK_DEF" | cut -d'/' -f2 | cut -d':' -f1)
log "Task Definition Family: $TASK_FAMILY"

# Obter definição completa da task
log "Obtendo definição completa da task definition..."
TASK_DEFINITION=$(aws ecs describe-task-definition --task-definition "$CURRENT_TASK_DEF" --query 'taskDefinition')

# Criar nova task definition com nova imagem
log "Criando nova task definition com imagem $COMMIT_HASH..."
NEW_TASK_DEFINITION=$(echo "$TASK_DEFINITION" | jq --arg IMAGE_URI "$IMAGE_URI" '
    .containerDefinitions[0].image = $IMAGE_URI |
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
')

# Registrar nova task definition
log "Registrando nova task definition..."
echo "$NEW_TASK_DEFINITION" > /tmp/new-task-def.json
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file:///tmp/new-task-def.json --query 'taskDefinition.taskDefinitionArn' --output text)

if [ -z "$NEW_TASK_DEF_ARN" ]; then
    error "Falha ao registrar nova task definition"
fi

success "Nova task definition registrada: $NEW_TASK_DEF_ARN"

# Atualizar service com nova task definition
log "Atualizando service $SERVICE_NAME com nova task definition..."
aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --task-definition "$NEW_TASK_DEF_ARN" \
    --query 'service.deployments[0].status' \
    --output text >/dev/null

success "Service $SERVICE_NAME atualizado com sucesso"

# Aguardar deployment
log "Aguardando deployment completar..."
echo "Monitorando deployment (pressione Ctrl+C para parar o monitoramento)..."

DEPLOYMENT_START_TIME=$(date +%s)
TIMEOUT=600  # 10 minutos

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - DEPLOYMENT_START_TIME))
    
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        warning "Timeout de $TIMEOUT segundos atingido. Verifique o deployment manualmente."
        break
    fi
    
    DEPLOYMENT_STATUS=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --query 'services[0].deployments[?status==`PRIMARY`] | [0] | {status: status, runningCount: runningCount, desiredCount: desiredCount, rolloutState: rolloutState}' \
        --output json)
    
    RUNNING_COUNT=$(echo "$DEPLOYMENT_STATUS" | jq -r '.runningCount // 0')
    DESIRED_COUNT=$(echo "$DEPLOYMENT_STATUS" | jq -r '.desiredCount // 0')
    ROLLOUT_STATE=$(echo "$DEPLOYMENT_STATUS" | jq -r '.rolloutState // "UNKNOWN"')
    
    echo -ne "\r${BLUE}Status:${NC} Running: $RUNNING_COUNT/$DESIRED_COUNT | Rollout: $ROLLOUT_STATE | Tempo: ${ELAPSED_TIME}s"
    
    if [ "$ROLLOUT_STATE" = "COMPLETED" ] && [ "$RUNNING_COUNT" = "$DESIRED_COUNT" ]; then
        echo ""
        success "Deployment completado com sucesso!"
        break
    elif [ "$ROLLOUT_STATE" = "FAILED" ]; then
        echo ""
        error "Deployment falhou!"
    fi
    
    sleep 5
done

# Verificar targets healthy no ALB (se aplicável)
log "Verificando health dos targets..."
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names "bia-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")

if [ -n "$TARGET_GROUP_ARN" ] && [ "$TARGET_GROUP_ARN" != "None" ]; then
    HEALTHY_TARGETS=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' --output text 2>/dev/null || echo "0")
    log "Targets healthy: $HEALTHY_TARGETS"
fi

# Resumo final
echo ""
echo "=================================="
success "DEPLOY COMPLETADO COM SUCESSO!"
echo "=================================="
echo "📦 Imagem: $IMAGE_URI"
echo "🏷️  Tag: $COMMIT_HASH"
echo "🎯 Cluster: $CLUSTER_NAME"
echo "⚙️  Service: $SERVICE_NAME"
echo "📋 Task Definition: $NEW_TASK_DEF_ARN"
echo "🌐 URL: https://bia.cloudfix.net.br"
echo "=================================="

log "Deploy finalizado!"
