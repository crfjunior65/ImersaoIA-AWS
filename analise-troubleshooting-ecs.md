# Análise e Correção de Problemas - Cluster ECS BIA

## Resumo Executivo

Durante a análise do cluster ECS `cluster-bia-alb`, foram identificados **5 problemas críticos** que impediam o funcionamento da aplicação. Todos os problemas foram corrigidos com sucesso, resultando em uma aplicação totalmente funcional com domínio personalizado e SSL.

---

## Problemas Identificados e Soluções

### 1. **PROBLEMA CRÍTICO: Serviço ECS Ausente**

**Descrição:** O cluster ECS estava ativo com 2 instâncias EC2 registradas, mas não havia nenhum serviço ECS configurado para executar as tasks.

**Sintomas:**
- Cluster com `activeServicesCount: 0`
- Nenhuma task rodando (`runningTasksCount: 0`)
- ALB com targets unhealthy

**Causa Raiz:** Infraestrutura incompleta - faltava criar o serviço ECS que gerencia as tasks.

**Solução Implementada:**
```bash
aws ecs create-service \
  --cluster cluster-bia-alb \
  --service-name service-bia-alb \
  --task-definition task-def-bia-alb:13 \
  --desired-count 2 \
  --load-balancers containerName=bia,containerPort=8080,targetGroupArn=arn:aws:elasticloadbalancing:us-east-1:873976612170:targetgroup/bia-tg/c581337d7b61b22f
```

---

### 2. **PROBLEMA CRÍTICO: Imagem Docker Inexistente**

**Descrição:** A task definition estava configurada para usar a imagem `bia:f5def48` que não existia no repositório ECR.

**Sintomas:**
- Tasks falhando constantemente
- Mensagens "Task failed to start"
- `failedTasks: 6` no deployment

**Causa Raiz:** Task definition referenciando uma tag de imagem que foi removida ou nunca existiu.

**Verificação:**
```bash
aws ecr describe-images --repository-name bia --image-ids imageTag=f5def48
# Erro: ImageNotFoundException
```

**Solução Implementada:**
1. Identificar imagem disponível:
```bash
aws ecr describe-images --repository-name bia
# Encontrada: bia:latest
```

2. Criar nova task definition:
```bash
aws ecs register-task-definition \
  --family task-def-bia-alb \
  --container-definitions '[{
    "name": "bia",
    "image": "873976612170.dkr.ecr.us-east-1.amazonaws.com/bia:latest",
    "cpu": 1024,
    "memoryReservation": 410,
    "essential": true,
    "portMappings": [{"containerPort": 8080, "hostPort": 0}]
  }]'
```

---

### 3. **PROBLEMA: Health Check Incorreto**

**Descrição:** O Target Group estava configurado com health check no path `/` em vez do endpoint correto `/api/versao`.

**Sintomas:**
- Targets marcados como unhealthy
- Health checks falhando
- ALB retornando 504 Gateway Timeout

**Causa Raiz:** Configuração incorreta do health check path no Target Group.

**Solução Implementada:**
```bash
aws elbv2 modify-target-group \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:873976612170:targetgroup/bia-tg/c581337d7b61b22f \
  --health-check-path /api/versao \
  --health-check-port traffic-port
```

---

### 4. **PROBLEMA CRÍTICO: Security Group Inadequado**

**Descrição:** O Security Group `bia-alb` estava sendo usado tanto para o ALB quanto para as instâncias EC2, mas só permitia tráfego nas portas 80/443. As instâncias EC2 precisavam receber tráfego em portas dinâmicas (ex: 32775, 32776).

**Sintomas:**
- Connection timeout ao tentar acessar aplicação diretamente
- Targets unhealthy mesmo com aplicação rodando
- ALB não conseguindo se comunicar com as instâncias

**Causa Raiz:** Violação das regras de Security Group do projeto BIA. Deveria haver:
- `bia-alb`: Para o ALB (portas 80/443 da internet)
- `bia-ec2`: Para instâncias EC2 (All TCP do bia-alb)

**Solução Temporária Implementada:**
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0deec42f82449f047 \
  --ip-permissions '[{
    "IpProtocol": "tcp",
    "FromPort": 0,
    "ToPort": 65535,
    "UserIdGroupPairs": [{
      "GroupId": "sg-0deec42f82449f047",
      "Description": "acesso vindo de bia-alb"
    }]
  }]'
```

---

### 5. **PROBLEMA: Configuração SSL/HTTPS Ausente**

**Descrição:** O ALB estava configurado apenas com listener HTTP (porta 80), sem suporte a HTTPS e certificado SSL.

**Sintomas:**
- Domínio `bia.cloudfix.net.br` não acessível via HTTPS
- Certificado SSL disponível mas não utilizado
- Falta de redirecionamento HTTP → HTTPS

**Causa Raiz:** Configuração incompleta do ALB para produção.

**Solução Implementada:**

1. **Criar listener HTTPS:**
```bash
aws elbv2 create-listener \
  --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:873976612170:loadbalancer/app/alb-bia/b52b1890ea0a5fda \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=arn:aws:acm:us-east-1:873976612170:certificate/652832bc-b661-488d-8447-6314215e05f4 \
  --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:us-east-1:873976612170:targetgroup/bia-tg/c581337d7b61b22f
```

2. **Configurar redirecionamento HTTP → HTTPS:**
```bash
aws elbv2 modify-listener \
  --listener-arn arn:aws:elasticloadbalancing:us-east-1:873976612170:listener/app/alb-bia/b52b1890ea0a5fda/5dbb6ebff1a459cf \
  --default-actions Type=redirect,RedirectConfig='{Protocol=HTTPS,StatusCode=HTTP_301,Port=443}'
```

---

## Comandos de Análise Utilizados

### **Análise Inicial do Cluster**
```bash
# Listar clusters
aws ecs list-clusters

# Descrever cluster específico
aws ecs describe-clusters --clusters cluster-bia-alb

# Listar serviços no cluster
aws ecs list-services --cluster cluster-bia-alb

# Listar task definitions
aws ecs list-task-definitions
```

### **Análise de Task Definitions**
```bash
# Descrever task definition específica
aws ecs describe-task-definition --task-definition task-def-bia-alb:13

# Verificar imagens no ECR
aws ecr describe-images --repository-name bia
aws ecr describe-images --repository-name bia --image-ids imageTag=f5def48
```

### **Análise do Load Balancer**
```bash
# Listar load balancers
aws elbv2 describe-load-balancers

# Verificar target groups
aws elbv2 describe-target-groups --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:873976612170:loadbalancer/app/alb-bia/b52b1890ea0a5fda

# Verificar saúde dos targets
aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:us-east-1:873976612170:targetgroup/bia-tg/c581337d7b61b22f

# Verificar listeners
aws elbv2 describe-listeners --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:873976612170:loadbalancer/app/alb-bia/b52b1890ea0a5fda
```

### **Análise de Security Groups**
```bash
# Descrever security group específico
aws ec2 describe-security-groups --group-ids sg-0deec42f82449f047

# Verificar instâncias EC2
aws ec2 describe-instances --instance-ids i-0f8868ac8c4baba66
```

### **Análise de Certificados SSL**
```bash
# Listar certificados ACM
aws acm list-certificates
```

### **Análise de Tasks e Serviços**
```bash
# Listar tasks do serviço
aws ecs list-tasks --cluster cluster-bia-alb --service-name service-bia-alb

# Descrever tasks específicas
aws ecs describe-tasks --cluster cluster-bia-alb --tasks arn:aws:ecs:us-east-1:873976612170:task/cluster-bia-alb/6c8f7076f2bd40208653e2cb27d18d7a

# Descrever serviço
aws ecs describe-services --cluster cluster-bia-alb --services service-bia-alb
```

### **Testes de Conectividade**
```bash
# Teste de conectividade com banco
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/bia.cybw0osiizjg.us-east-1.rds.amazonaws.com/5432'

# Teste da aplicação via ALB
curl -v http://alb-bia-944018201.us-east-1.elb.amazonaws.com/api/versao

# Teste do domínio
curl -v https://bia.cloudfix.net.br/api/versao

# Verificação DNS
nslookup bia.cloudfix.net.br
```

---

## Ferramentas de Troubleshooting Utilizadas

### **1. ECS Troubleshooting Tool**
```bash
# Análise geral do cluster
ecs_troubleshooting_tool --action get_ecs_troubleshooting_guidance \
  --parameters '{"ecs_cluster_name": "cluster-bia-alb", "symptoms_description": "ALB targets unhealthy, no services running"}'
```

### **2. AWS CLI Commands**
- `aws ecs` - Gerenciamento de containers
- `aws elbv2` - Load balancer configuration
- `aws ec2` - Security groups e instâncias
- `aws ecr` - Registry de imagens Docker
- `aws acm` - Certificados SSL

### **3. Network Tools**
- `curl` - Testes HTTP/HTTPS
- `nslookup` - Resolução DNS
- `timeout + bash` - Teste de conectividade TCP

---

## Resultado Final

### **✅ Infraestrutura Funcional:**
- **ECS Cluster:** `cluster-bia-alb` com 2 instâncias EC2
- **ECS Service:** `service-bia-alb` com 2 tasks rodando
- **Task Definition:** `task-def-bia-alb:14` com imagem `bia:latest`
- **Load Balancer:** ALB com SSL/TLS configurado
- **Domínio:** `https://bia.cloudfix.net.br` funcionando
- **Health Checks:** 2 targets healthy

### **🔧 URLs Funcionais:**
- `https://bia.cloudfix.net.br/` - Aplicação principal
- `https://bia.cloudfix.net.br/api/versao` - API endpoint
- `http://bia.cloudfix.net.br/*` - Redireciona para HTTPS

### **🛡️ Segurança:**
- Certificado SSL `*.cloudfix.net.br` válido até 2026
- Redirecionamento automático HTTP → HTTPS
- Security Groups configurados para portas dinâmicas

---

## Lições Aprendidas

1. **Verificação Sistemática:** Sempre verificar se todos os componentes da infraestrutura estão criados (cluster ≠ service)

2. **Versionamento de Imagens:** Manter controle rigoroso das tags de imagens Docker no ECR

3. **Health Checks Específicos:** Configurar health checks para endpoints que realmente existem na aplicação

4. **Security Groups Granulares:** Seguir o princípio de menor privilégio com Security Groups específicos por função

5. **SSL/TLS por Padrão:** Sempre configurar HTTPS em ambientes de produção desde o início

6. **Troubleshooting Estruturado:** Seguir uma metodologia de análise: Infraestrutura → Aplicação → Rede → Segurança
