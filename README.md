# Prova DevOps: CI/CD com Jenkins e Docker

Este repositório contém minha solução para a prova de DevOps. Criei uma esteira de **Integração e Entrega Contínua (CI/CD)** para o projeto C++17 `calculator`, que roda em um único host **Ubuntu 24.04** com **Jenkins** e **Docker** em modo **Swarm**.

O objetivo deste documento é registrar o caminho que segui. Vou compartilhar as decisões que tomei e por que as fiz, os comandos que usei, as saídas relevantes e, principalmente, os problemas que encontrei e como os resolvi. Sempre que possível, incluí prints.

## Sumário

1. [Arquitetura](#1-arquitetura)
2. [Componentes do repositório](#2-componentes-do-repositório)
3. [Mapeamento dos entregáveis](#3-mapeamento-dos-entregáveis)
4. [Passo a passo da implantação](#4-passo-a-passo-da-implantação)
5. [Pipelines](#5-pipelines)
6. [Problemas encontrados e soluções](#6-problemas-encontrados-e-soluções)
7. [Notas operacionais](#7-notas-operacionais)

---

## 1. Arquitetura

Decidi rodar o Jenkins em **Docker Swarm**, mesmo com um único nó, ao invés de usar um `docker compose` puro. O motivo foi a possibilidade de usar os *secrets* nativos do Swarm, que uso para guardar os segredos de conexão dos agentes JNLP, a política de reinício declarativa que o Swarm oferece, e a possibilidade de adicionar nós remotos, caso necessário.

O controlador **não executa builds**, configurado com 0 executores no nó *built-in*. Todo o trabalho pesado fica a cargo dos dois agentes.

Explicando cada peça:

- **Controlador** (`jenkins`): orquestra os jobs, guarda os artefatos e oferece a interface web.
- **Dois agentes de execução** (`agent1` e `agent2`): são agentes JNLP *inbound* que carregam apenas o **Docker CLI**, não a toolchain C++. Eles se comunicam com o daemon Docker **do host** pelo socket montado e, usando o plugin *Docker Pipeline* (`docker.build().inside{}`), executam cada etapa dentro de um contêiner descartável da toolchain. Assim, os agentes permanecem leves e o ambiente de compilação é sempre o mesmo, independentemente do agente utilizado.
- **Imagem de toolchain** (`calculator/Dockerfile`): um Ubuntu 24.04 com todos os pré-requisitos listados no `calculator/README.md`, construída a partir do código no momento do build.

Com `agent1` e `agent2`, atendo o requisito mínimo da prova: um servidor de CI com pelo menos dois nós agentes.

---

## 2. Componentes do repositório

| Arquivo | Papel |
|---------|-------|
| `jenkins/docker-compose.yaml` | Stack do Swarm: controlador + 2 agentes, limites de recurso, *secrets* e a montagem do socket |
| `jenkins/agent.Dockerfile` | Imagem do agente = inbound-agent + Docker CLI + buildx; usuário `jenkins` no grupo `docker` do host |
| `calculator/Dockerfile` | Imagem da toolchain C++17 (g++, gtest, clang-tidy, clang-format) |
| `calculator/Jenkinsfile` | **Pipeline único**: CI completa (checagem, testes e artefato) e, por condição, o modo só-artefato (manual sob demanda + diário) |

---

## 3. Mapeamento dos entregáveis

Para não deixar dúvida sobre o que atende o quê, montei esta tabela:

| Entregável da prova | Onde está atendido |
|---------------------|--------------------|
| Servidor de CI + ≥ 2 agentes | `jenkins/docker-compose.yaml` (`jenkins`, `agent1`, `agent2`) |
| Tarefa com **gatilho manual** de geração de artefatos sob demanda | `calculator/Jenkinsfile`, no *Build with Parameters* com `ARTIFACT_ONLY = true` |
| → Obtenção do código-fonte | etapa `Checkout` (`checkout scm`) |
| → Geração dos artefatos | etapa `Build artifact` (`make`) |
| → Armazenamento dos artefatos | etapa `Archive artifact` (`archiveArtifacts`, store nativo do Jenkins) |
| **Agendamento diário** da geração | `triggers { cron('H 2 * * *') }`; o timer é detectado na etapa `Detect mode` e cai no modo só-artefato |
| **Pipeline de validação** (checagem, testes, artefato) | `calculator/Jenkinsfile` (execução completa em push/poll) |
| Falha em qualquer etapa = **crítica** | saída não-zero derruba o build; as etapas seguintes não rodam |
| Integração automática via **webhook** | `githubPush()` + `pollSCM('H/5 * * * *')` como reforço |

---

## 4. Passo a passo da implantação

Pré-requisito: Docker Engine com o Swarm já ativo no host.

### 4.1 Inicializar o Swarm (só uma vez)

```bash
sudo docker swarm init
```

![docker swarm init](assets/docker-swarm-init.png)

### 4.2 Construir a imagem do agente

Na primeira vez que executei o pipeline, encontrei um erro de permissão. O agente não conseguia acessar o Docker do host.

![erro de permissão do agente](assets/docker-permission-error.png)

Para resolver isso, passei o GID do grupo `docker` do host em tempo de build. Isso foi necessário para que o dono do socket montado fosse o mesmo do grupo `docker`. É uma questão importante, que detalho na [seção 6.4](#64-permissão-negada-no-socket-do-docker). Aqui está como fiz:

```bash
sudo docker build \
  --build-arg DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) \
  -t jenkins-agent:docker -f jenkins/agent.Dockerfile jenkins/
```

### 4.3 Subir o controlador

Os agentes só conseguem obter os *secrets* de conexão depois que o controlador está em execução. Então subi o controlador primeiro. Dá para comentar os dois serviços de agente temporariamente, ou subir tudo e gerar os *secrets* logo em seguida. Aqui está como subi o controlador:

```bash
sudo docker stack deploy -c jenkins/docker-compose.yaml jenkins
```

### 4.4 Desbloquear o Jenkins

No início, procurei saber quais portas estavam abertas no servidor que me foi disponibilizado. Além da porta 22, usada para SSH, também encontrei a porta 8080 aberta. Foi por essa porta que continuei configurando o Jenkins pela interface web.

![portas abertas no servidor](assets/checking-server-open-ports.png)

Quando o nó principal é iniciado, ele gera um token de desbloqueio. Com esse token é possível seguir pela interface web. Para obtê-lo, usei o seguinte comando:

```bash
sudo docker exec $(sudo docker ps -qf name=jenkins_jenkins) \
  cat /var/jenkins_home/secrets/initialAdminPassword
```

![primeira inicialização do Jenkins](assets/jenkins-first-startup.png)

Optei pela instalação recomendada do Jenkins, que já vem com os plugins de acesso ao GitHub. Além disso, adicionei o **"Docker Pipeline"** para facilitar o build e o uso de imagens/contêineres dentro dos pipelines. Também instalei o **"Blue Ocean"**, só para ter uma visualização melhor do pipeline e dos logs.

### 4.5 Cadastrar os nós agentes

Em **Manage Jenkins → Nodes**, configurei os seguintes nós:

- O nó *built-in*: defini o número de executores como **0**, já que o controlador não executa builds;
- Os novos nós `agent1` e `agent2`: configurei como permanentes, do tipo inbound/JNLP, com a raiz remota `/home/jenkins/agent`. Também defini **LABELS = `docker`**, o que é importante para a configuração.

Inicialmente executei os agentes sem os *secrets*, o que resultou em erro de conexão.

![erro de secret dos agentes](assets/wrong-secrets-for-agents.png)

O *secret* de cada nó é gerado pelo próprio controlador e aparece no comando que ele sugere na hora de criar o agente. É de lá que copio o *secret* de conexão de cada nó.

![secret do nó no Jenkins](assets/get-node-secret.png)

### 4.6 Criar os Swarm secrets

O compose espera os *secrets* como `external: true`, então criei os dois necessários:

```bash
printf '%s' '<secret-do-agent1>' | sudo docker secret create agent1_secret -
printf '%s' '<secret-do-agent2>' | sudo docker secret create agent2_secret -
```

> Uso `printf '%s'` de propósito, sem `echo`, para não injetar um `\n` no fim do *secret*. Isso já me custou um tempo de depuração (seção 6.5).

### 4.7 Redeploy para os agentes conectarem

```bash
sudo docker stack deploy -c jenkins/docker-compose.yaml jenkins
```

### 4.8 Criar o job de Pipeline

Deixei um único job do tipo *Multibranch Pipeline* apontando para este repositório. Ele descobre as branches sozinho e usa o critério de marcador `**/Jenkinsfile*`, que encontra o `calculator/Jenkinsfile` automaticamente, sem precisar apontar o *Script Path* na mão. O mesmo job cobre a CI e a geração de artefato; quem decide o comportamento é o gatilho/parâmetro (explico na [seção 5](#5-pipelines)).

---

## 5. Pipelines

Optei por deixar **um único** `calculator/Jenkinsfile` para simplificar: um só marcador, um só job. A etapa `Detect mode` decide, em tempo de execução, entre dois caminhos, usando `when { expression {...} }`:

- **Modo só-artefato** (`ARTIFACT_MODE = true`): pula o lint e os testes e só constrói e arquiva o binário. Entra nesse modo quando:
  - o build veio do **timer diário** (`TimerTrigger`), ou
  - o **parâmetro `ARTIFACT_ONLY`** foi marcado num *Build with Parameters* (a geração de artefato **manual, sob demanda**).
  ![trigger manual](assets/manual-build.png)
- **Modo CI completa** (padrão): roda todas as etapas com os *gates* críticos. Entra aqui num `githubPush()`/`pollSCM` (commit novo) ou num run manual sem o parâmetro.

### 5.1 Etapas

| Etapa | Roda quando | Comando |
|-------|-------------|---------|
| `Checkout` | sempre | `checkout scm`, obtém o código-fonte |
| `Detect mode` | sempre | decide o `ARTIFACT_MODE` (timer ou `ARTIFACT_ONLY`) |
| `Build toolchain image` | sempre | `docker.build(...)` |
| `Code check (lint + format)` | só CI completa | `make check` (clang-tidy `cppcoreguidelines*` como *warnings-as-errors* + clang-format) |
| `Unit tests` | só CI completa | `make unittest` (GoogleTest) |
| `Build artifact` | sempre | `make` → `calculator/bin/calculator` (+ `BUILDINFO.txt`) |
| `Archive artifact` | sempre | `archiveArtifacts` (store nativo do Jenkins) |

No Blue Ocean dá para ver bem essa separação de etapas:

![etapas no Blue Ocean](assets/blue-ocean-stages.png)

Para o armazenamento usei o *store* nativo do Jenkins, mas ele é fácil de trocar por um S3, por exemplo; basta substituir o passo `archiveArtifacts`.

![artefatos arquivados](assets/artifacts.png)

### 5.2 Gatilhos

```groovy
triggers {
    githubPush()            // CI completa a cada commit (webhook)
    pollSCM('H/5 * * * *')  // reforço por polling
    cron('H 2 * * *')       // artefato diário (~02:xx America/Sao_Paulo)
}
```

Qualquer falha é tratada como **crítica**: a saída não-zero derruba o build e as etapas seguintes não rodam (o bloco `post { failure {...} }` sinaliza isso). Para ligar o webhook: repositório → *Settings → Webhooks* → `http://<host>:8080/github-webhook/`.

> **Sobre o estado atual do código-fonte:** a CI completa está **vermelha de propósito**. O `make check` falha (variáveis não inicializadas em `src/main.cpp`, regra `cppcoreguidelines-init-variables`) e o `make unittest` quebra (`Calculator<int>(0,0).divide()`, divisão inteira `0/0`, SIGFPE). Isso serve justamente para demonstrar o *gate* de falha crítica funcionando. É só corrigir o fonte para ver um run verde.

---

## 6. Problemas encontrados e soluções

Aqui estão os problemas reais que apareceram durante a montagem, na ordem em que surgiram, com a solução que apliquei em cada um.

### 6.1 Docker não estava instalado no host

Logo de cara o host não tinha o Docker Engine.

![docker não instalado](assets/docker-was-not-installed.png)

**Solução:** instalei o Docker Engine + CLI pelo repositório oficial da Docker e em seguida rodei o `sudo docker swarm init`. Segui a documentação oficial:

- https://docs.docker.com/engine/install/ubuntu/
- https://docs.docker.com/engine/swarm/swarm-mode/

### 6.2 Falha de DNS durante o `docker build`

O `apt-get update` dentro do build falhava porque o contêiner não resolvia nomes.

![problema de DNS no docker build](assets/dns-solve-issue-at-docker-build.png)

**Solução:** configurei o DNS do daemon em `/etc/docker/daemon.json` (`"dns": ["8.8.8.8"]`) e reiniciei o serviço. A resolução voltou a funcionar dentro dos contêineres de build.

### 6.3 Erro de memória (OutOfMemory / Metaspace) e falta de swap

O host é pequeno (~900 MB) e sem swap, e a JVM do Jenkins estourava.

![sem swap](assets/no-swap.png)
![erro de out of memory](assets/out-of-memory-error.png)

**Solução:** limitei os *heaps* da JVM e coloquei limites de cgroup no compose. O controlador ficou com `-Xmx192m` (`MaxMetaspaceSize=256m`, `UseSerialGC`) e os agentes com `-Xmx128m`, com os limites de memória correspondentes no `deploy`. Depois do ajuste o uso ficou estável:

![uso de memória depois dos limites](assets/memory-usage-after-set-up-limits.png)

### 6.4 Permissão negada no socket do Docker

O usuário `jenkins` do agente não conseguia usar `/var/run/docker.sock`.

![erro de permissão do docker](assets/docker-permission-error.png)

**Solução:** como o `docker stack deploy` **ignora `group_add`**, gravei o GID do grupo `docker` do host direto na imagem do agente, em tempo de build (`--build-arg DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)`), e adicionei o usuário `jenkins` a esse grupo. Está tudo no `jenkins/agent.Dockerfile`.

### 6.5 Secrets errados para os agentes

Os agentes não conectavam (a autenticação JNLP era recusada) por causa de *secret* incorreto.

![secrets errados para os agentes](assets/wrong-secrets-for-agents.png)

**Solução:** recriei os Swarm secrets `agent1_secret`/`agent2_secret` com o *secret* exato de cada nó (Manage Jenkins → Nodes), tomando o cuidado de usar `printf '%s'` para não injetar um `\n` no fim.

### 6.6 Nome/label do nó errado

O pipeline usa `agent { label 'docker' }` e não achava executor porque os nós estavam com nome/label diferentes do esperado.

![nomes de label errados](assets/wrong-labels-name.png)

**Solução:** padronizei o `JENKINS_AGENT_NAME` (`agent1`/`agent2`) e a label **`docker`** nos nós, casando com o `label 'docker'` do Jenkinsfile.

### 6.7 Falhas de lint, formatação e testes (essas eram esperadas)

Essas falhas são a demonstração do *gate* crítico da CI:

![problemas de lint](assets/lint-issues.png)
![aviso de clang-format](assets/clang-format-warning.png)
![testes unitários falharam](assets/unittests-failed.png)

**Sobre a "solução":** aqui não há o que corrigir na infra, são falhas **de propósito** no fonte atual (ver o aviso na seção 5.2). O pipeline as trata como críticas e interrompe a execução, que é exatamente a evidência de que os *gates* estão funcionando.

---

## 7. Notas operacionais

Algumas coisas que vale ter em mente para operar isso no dia a dia:

- **GID do grupo docker:** o `agent.Dockerfile` recebe o GID do host via `--build-arg`. Se o `getent group docker` mostrar um GID diferente, é só reconstruir a imagem do agente.
- **Memória:** o host é pequeno (~900 MB), então os *heaps* da JVM ficam limitados no compose, com os limites de cgroup correspondentes.
- **Disco:** cada run constrói uma imagem de toolchain baseada em Ubuntu; os pipelines dão `docker rmi` na imagem daquele build no bloco `post { always }`. Vale rodar um `docker image prune -f` de tempos em tempos.
- **Isolamento:** as tags por build (`:${BUILD_NUMBER}`) evitam que dois runs concorrentes nos dois agentes colidam.
