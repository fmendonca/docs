# Instalação de OpenShift Data Foundation (ODF) usando LUNs de Storage com Multipath

## Introdução

O OpenShift Data Foundation (ODF), anteriormente conhecido como OpenShift Container Storage (OCS), é uma solução de armazenamento definida por software que fornece armazenamento persistente para aplicações containerizadas no OpenShift Container Platform. Quando implementado com LUNs (Logical Unit Numbers) de storage externo, o ODF pode aproveitar a tecnologia de multipath para garantir alta disponibilidade e melhor performance através de múltiplos caminhos de acesso aos dispositivos de armazenamento.

A configuração de multipath no OpenShift é essencial quando se trabalha com storage SAN (Storage Area Network) que oferece múltiplos caminhos físicos para os mesmos dispositivos de armazenamento. Esta redundância não apenas melhora a disponibilidade do sistema, mas também pode distribuir a carga de I/O entre diferentes caminhos, resultando em melhor performance geral do cluster.

Este documento fornece um guia completo para configurar multipath usando MachineConfig no OpenShift Container Platform e posteriormente instalar o ODF utilizando LUNs de storage configurados com multipath. O processo envolve várias etapas críticas que devem ser executadas na ordem correta para garantir uma implementação bem-sucedida.

## Configuração de Multipath com MachineConfig

### Fundamentos do Multipath no OpenShift

O multipath é uma tecnologia que permite ao sistema operacional acessar um único dispositivo de armazenamento através de múltiplos caminhos físicos. No contexto do OpenShift, isso é particularmente importante quando se utiliza storage SAN com conectividade redundante, seja através de Fibre Channel, iSCSI ou outras tecnologias de rede de armazenamento.

O OpenShift Container Platform utiliza o Red Hat Enterprise Linux CoreOS (RHCOS) como sistema operacional base para os nós do cluster. O RHCOS é uma distribuição imutável, o que significa que as modificações no sistema operacional devem ser aplicadas através de mecanismos específicos, sendo o MachineConfig o método principal para realizar configurações persistentes no nível do sistema operacional.

### Preparação do Arquivo multipath.conf

O primeiro passo para configurar multipath no OpenShift é criar um arquivo de configuração multipath.conf adequado. Este arquivo define como o sistema deve tratar os dispositivos multipath, incluindo políticas de balanceamento de carga, timeouts e outras configurações específicas do ambiente.

Um exemplo básico de configuração multipath.conf inclui as seguintes seções principais:

```
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss.*"
}

blacklist_exceptions {
    property "(SCSI_IDENT_|ID_WWN)"
}
```

A seção `defaults` define configurações globais que se aplicam a todos os dispositivos multipath. A opção `user_friendly_names yes` instrui o sistema a criar nomes amigáveis para os dispositivos multipath (como /dev/mapper/mpatha, /dev/mapper/mpathb, etc.) em vez de usar apenas os identificadores WWN (World Wide Name).

A configuração `find_multipaths yes` faz com que o sistema automaticamente detecte dispositivos que podem ser configurados como multipath, baseando-se na presença de múltiplos caminhos para o mesmo dispositivo de armazenamento.

### Criação do MachineConfig para Multipath

O MachineConfig é um recurso do OpenShift que permite aplicar configurações específicas do sistema operacional aos nós do cluster. Para configurar multipath, é necessário criar um MachineConfig que instale o arquivo multipath.conf nos nós apropriados.

O processo de criação do MachineConfig envolve primeiro codificar o conteúdo do arquivo multipath.conf em base64, e então criar um manifesto YAML que instrui o Machine Config Operator a aplicar essa configuração aos nós selecionados.

Primeiro, crie o arquivo multipath.conf localmente:

```bash
cat > /tmp/multipath.conf << 'EOF'
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
    polling_interval 10
    path_selector "round-robin 0"
    path_grouping_policy multibus
    path_checker readsector0
    rr_min_io 100
    max_fds 8192
    rr_weight priorities
    failback immediate
    no_path_retry fail
    queue_without_daemon no
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss.*"
    devnode "^nvme.*"
    devnode "^vd[a-z]"
}

blacklist_exceptions {
    property "(SCSI_IDENT_|ID_WWN)"
}

devices {
    device {
        vendor ".*"
        product ".*"
        path_grouping_policy multibus
        path_selector "round-robin 0"
        failback immediate
        rr_weight priorities
        no_path_retry fail
    }
}
EOF
```

Em seguida, codifique o arquivo em base64:

```bash
MULTIPATH_CONF_B64=$(cat /tmp/multipath.conf | base64 -w0)
```

Agora, crie o MachineConfig. É importante notar que você deve aplicar esta configuração tanto para nós master quanto worker, dependendo de onde o ODF será executado:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-multipath-conf
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${MULTIPATH_CONF_B64}
        filesystem: root
        mode: 420
        path: /etc/multipath.conf
    systemd:
      units:
      - enabled: true
        name: multipathd.service
```

Para nós master (caso você esteja executando ODF em nós master em um ambiente de teste):

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-multipath-conf
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${MULTIPATH_CONF_B64}
        filesystem: root
        mode: 420
        path: /etc/multipath.conf
    systemd:
      units:
      - enabled: true
        name: multipathd.service
```

### Aplicação do MachineConfig

Após criar os manifestos do MachineConfig, aplique-os ao cluster:

```bash
# Substitua ${MULTIPATH_CONF_B64} pelo valor real codificado em base64
oc apply -f multipath-worker-machineconfig.yaml
oc apply -f multipath-master-machineconfig.yaml  # Se necessário
```

O Machine Config Operator detectará automaticamente as mudanças e iniciará um processo de rolling update nos nós afetados. Este processo pode levar algum tempo, pois cada nó será reinicializado para aplicar as novas configurações.

Monitore o progresso da aplicação do MachineConfig:

```bash
# Verificar o status dos MachineConfigPools
oc get mcp

# Verificar o progresso detalhado
oc describe mcp worker
oc describe mcp master  # Se aplicável
```

Durante o processo de atualização, você verá o status dos nós mudando de "Ready" para "SchedulingDisabled" e depois retornando para "Ready" conforme cada nó é atualizado e reinicializado.

### Verificação da Configuração de Multipath

Após a conclusão do rolling update, é essencial verificar se a configuração de multipath foi aplicada corretamente em todos os nós. Isso pode ser feito acessando os nós diretamente ou usando debug pods.

Para verificar usando debug pods:

```bash
# Criar um debug pod em um nó worker
oc debug node/<nome-do-no>

# Dentro do debug pod, verificar se o multipath está configurado
chroot /host

# Verificar se o arquivo de configuração foi criado
cat /etc/multipath.conf

# Verificar se o serviço multipathd está ativo
systemctl status multipathd

# Listar dispositivos multipath (se houver LUNs conectados)
multipath -ll
```

Se os LUNs de storage já estiverem conectados aos nós, você deve ver a saída do comando `multipath -ll` mostrando os dispositivos multipath configurados com seus respectivos caminhos.




## Preparação dos LUNs de Storage para ODF

### Requisitos de LUNs para OpenShift Data Foundation

O OpenShift Data Foundation possui requisitos específicos para os dispositivos de armazenamento que serão utilizados como base para o cluster Ceph subjacente. Estes requisitos são fundamentais para garantir performance adequada, confiabilidade e compatibilidade com as operações do ODF.

#### Requisitos Básicos de Hardware

O ODF requer no mínimo três nós worker com dispositivos de armazenamento localmente anexados. Cada nó deve ter pelo menos um dispositivo de bloco bruto disponível para ser usado pelo ODF. Estes dispositivos devem estar completamente vazios, sem volumes físicos (PVs), grupos de volumes (VGs) ou volumes lógicos (LVs) existentes.

Para implementações em produção, recomenda-se que cada nó tenha múltiplos dispositivos de armazenamento para melhor distribuição de dados e performance. O tamanho mínimo recomendado para cada dispositivo é de 100GB, embora para ambientes de produção sejam recomendados dispositivos significativamente maiores, tipicamente na faixa de 1TB ou mais.

#### Requisitos Específicos para LUNs SAN

Quando se utiliza LUNs de storage SAN, existem considerações adicionais importantes. Cada LUN deve ser apresentado de forma consistente para todos os nós que participarão do cluster ODF. Isso significa que o mesmo LUN deve ser visível com o mesmo identificador (WWN ou SCSI ID) em todos os nós relevantes.

A configuração de multipath é especialmente crítica neste cenário, pois os LUNs SAN tipicamente oferecem múltiplos caminhos de acesso através de diferentes controladores de storage ou interfaces de rede. O multipath não apenas fornece redundância em caso de falha de um caminho, mas também pode melhorar a performance através da distribuição de I/O entre múltiplos caminhos.

#### Considerações de Performance

Para otimizar a performance do ODF com LUNs SAN, é importante considerar as características de latência e throughput do storage subjacente. O Ceph, que é a tecnologia de armazenamento distribuído utilizada pelo ODF, é sensível à latência, especialmente para operações de metadados.

Recomenda-se que os LUNs utilizados para ODF tenham latência consistentemente baixa, idealmente abaixo de 10ms para operações de leitura e escrita. Para ambientes com requisitos de alta performance, pode ser benéfico utilizar LUNs baseados em storage SSD ou NVMe.

### Identificação e Descoberta de LUNs

Após a configuração do multipath e antes de instalar o ODF, é necessário identificar e verificar que os LUNs estão corretamente visíveis e configurados em todos os nós do cluster.

#### Verificação de Dispositivos Multipath

O primeiro passo é verificar se os LUNs estão sendo corretamente detectados pelo subsistema multipath. Isso pode ser feito usando o comando `multipath -ll` em cada nó:

```bash
# Acessar um nó para verificação
oc debug node/<nome-do-no>
chroot /host

# Listar todos os dispositivos multipath
multipath -ll

# Verificar dispositivos de bloco disponíveis
lsblk

# Verificar informações SCSI detalhadas
lsscsi
```

A saída do comando `multipath -ll` deve mostrar os LUNs configurados com seus respectivos caminhos. Por exemplo:

```
mpatha (36001405d27e5c9c5d494b35a9d6c3a3e) dm-2 LIO-ORG,TCMU device
size=100G features='0' hwhandler='1 alua' wp=rw
|-+- policy='round-robin 0' prio=50 status=active
| `- 2:0:0:1 sdb 8:16 active ready running
`-+- policy='round-robin 0' prio=10 status=enabled
  `- 3:0:0:1 sdc 8:32 active ready running
```

Esta saída indica que existe um dispositivo multipath chamado `mpatha` com dois caminhos ativos (`sdb` e `sdc`), cada um acessível através de diferentes controladores SCSI.

#### Verificação de Consistência entre Nós

É crucial verificar que os mesmos LUNs estão visíveis de forma consistente em todos os nós que participarão do cluster ODF. Isso pode ser feito comparando os WWNs (World Wide Names) dos dispositivos entre diferentes nós:

```bash
# Em cada nó, verificar os WWNs dos dispositivos
for device in /dev/mapper/mpath*; do
    echo "Device: $device"
    /lib/udev/scsi_id -g -u -d $device
    echo "---"
done
```

Os WWNs devem ser idênticos para o mesmo LUN em todos os nós, garantindo que o ODF possa identificar corretamente os dispositivos de armazenamento compartilhados.

### Preparação dos Dispositivos para ODF

Antes de utilizar os LUNs com o ODF, é necessário garantir que eles estejam completamente limpos e livres de qualquer estrutura de dados existente.

#### Limpeza de Dispositivos

Execute os seguintes comandos em cada nó para limpar os dispositivos que serão utilizados pelo ODF:

```bash
# Para cada dispositivo multipath que será usado pelo ODF
DEVICE="/dev/mapper/mpatha"  # Substitua pelo dispositivo correto

# Limpar assinaturas de filesystem existentes
wipefs -a $DEVICE

# Zerar o início do dispositivo
dd if=/dev/zero of=$DEVICE bs=1M count=100

# Zerar o final do dispositivo
DEVICE_SIZE=$(blockdev --getsz $DEVICE)
dd if=/dev/zero of=$DEVICE bs=512 seek=$((DEVICE_SIZE - 2048)) count=2048

# Verificar que o dispositivo está limpo
blkid $DEVICE  # Não deve retornar nenhuma informação
```

#### Configuração de Permissões e Ownership

Embora o ODF gerencie automaticamente as permissões dos dispositivos durante a instalação, é uma boa prática verificar que os dispositivos estão acessíveis com as permissões corretas:

```bash
# Verificar permissões dos dispositivos multipath
ls -la /dev/mapper/mpath*

# Verificar que os dispositivos são acessíveis para leitura/escrita
dd if=$DEVICE of=/dev/null bs=4k count=1
dd if=/dev/zero of=$DEVICE bs=4k count=1
```

### Validação da Configuração de Storage

Antes de prosseguir com a instalação do ODF, é recomendável realizar testes básicos de performance e funcionalidade dos LUNs configurados.

#### Testes de Performance Básicos

Execute testes simples de I/O para verificar que os dispositivos estão funcionando corretamente e oferecendo performance adequada:

```bash
# Teste de escrita sequencial
dd if=/dev/zero of=$DEVICE bs=1M count=1000 oflag=direct

# Teste de leitura sequencial
dd if=$DEVICE of=/dev/null bs=1M count=1000 iflag=direct

# Teste de latência com fio (se disponível)
fio --name=latency-test --filename=$DEVICE --direct=1 --rw=randread --bs=4k --numjobs=1 --runtime=60 --time_based --iodepth=1
```

#### Verificação de Failover de Multipath

Para validar que o multipath está funcionando corretamente, você pode simular a falha de um caminho e verificar que o I/O continua funcionando através do caminho alternativo:

```bash
# Identificar os caminhos do dispositivo multipath
multipath -ll mpatha

# Simular falha de um caminho (exemplo com iptables se usando iSCSI)
# CUIDADO: Isso pode interromper temporariamente o acesso ao storage
iptables -I OUTPUT -d <IP_DO_TARGET_ISCSI> -j DROP

# Verificar que o multipath detectou a falha
multipath -ll mpatha

# Testar que o I/O ainda funciona
dd if=/dev/zero of=/dev/mapper/mpatha bs=1M count=10 oflag=direct

# Restaurar o caminho
iptables -D OUTPUT -d <IP_DO_TARGET_ISCSI> -j DROP

# Verificar que ambos os caminhos estão ativos novamente
multipath -ll mpatha
```

### Documentação da Configuração de Storage

É importante documentar a configuração de storage para referência futura e para facilitar operações de manutenção. Crie um inventário dos dispositivos que inclua:

- WWN de cada LUN
- Tamanho de cada dispositivo
- Mapeamento entre dispositivos físicos e dispositivos multipath
- Configuração de multipath utilizada
- Resultados dos testes de performance

Esta documentação será valiosa durante operações de expansão do cluster, troubleshooting e manutenção preventiva.

#### Exemplo de Inventário de Storage

| Dispositivo Multipath | WWN | Tamanho | Caminhos | Nós | Status |
|----------------------|-----|---------|----------|-----|--------|
| /dev/mapper/mpatha | 36001405d27e5c9c5d494b35a9d6c3a3e | 100GB | sdb, sdc | worker-1, worker-2, worker-3 | Ativo |
| /dev/mapper/mpathb | 36001405d27e5c9c5d494b35a9d6c3a3f | 100GB | sdd, sde | worker-1, worker-2, worker-3 | Ativo |
| /dev/mapper/mpathc | 36001405d27e5c9c5d494b35a9d6c3a40 | 100GB | sdf, sdg | worker-1, worker-2, worker-3 | Ativo |

### Considerações de Segurança para LUNs

Ao trabalhar com LUNs SAN em um ambiente OpenShift, existem várias considerações de segurança importantes que devem ser abordadas.

#### Isolamento de Rede de Storage

Certifique-se de que a rede de storage (SAN) esteja adequadamente isolada da rede de dados principal. Isso pode ser alcançado através de VLANs dedicadas, redes físicas separadas ou através de configurações de firewall apropriadas.

Para implementações iSCSI, considere o uso de redes dedicadas para tráfego de storage, preferencialmente com largura de banda adequada (10GbE ou superior) para suportar as demandas de I/O do cluster ODF.

#### Autenticação e Autorização

Configure autenticação adequada para acesso aos LUNs. Para iSCSI, isso pode incluir CHAP (Challenge-Handshake Authentication Protocol) authentication. Para Fibre Channel, utilize zoning adequado para garantir que apenas os nós autorizados tenham acesso aos LUNs específicos.

#### Criptografia de Dados

Considere a implementação de criptografia de dados em repouso e em trânsito. O ODF suporta criptografia de dados em repouso através de integração com sistemas de gerenciamento de chaves externos, como HashiCorp Vault ou IBM Key Protect.

Para criptografia em trânsito, utilize protocolos seguros como iSCSI sobre TLS ou IPSec para proteger os dados durante a transmissão entre os nós do cluster e o storage SAN.


## Instalação e Configuração do OpenShift Data Foundation

### Pré-requisitos para Instalação do ODF

Antes de proceder com a instalação do OpenShift Data Foundation, é essencial verificar que todos os pré-requisitos foram atendidos. Estes pré-requisitos abrangem tanto aspectos de infraestrutura quanto configurações específicas do cluster OpenShift.

#### Requisitos de Cluster

O cluster OpenShift deve estar executando uma versão suportada do OpenShift Container Platform. Para ODF 4.15, as versões suportadas incluem OpenShift 4.12 através 4.15. É importante verificar a matriz de compatibilidade oficial da Red Hat para confirmar as versões específicas suportadas para a versão do ODF que você planeja instalar.

O cluster deve ter pelo menos três nós worker disponíveis para executar os componentes do ODF. Embora seja tecnicamente possível executar ODF em nós master em ambientes de teste ou desenvolvimento, isso não é recomendado para ambientes de produção devido a considerações de performance e isolamento de cargas de trabalho.

Cada nó que participará do cluster ODF deve ter recursos computacionais adequados. Os requisitos mínimos incluem 16 vCPUs e 64GB de RAM por nó, embora para ambientes de produção sejam recomendados recursos significativamente maiores. A Red Hat recomenda 24 vCPUs e 96GB de RAM por nó para cargas de trabalho de produção.

#### Requisitos de Rede

O ODF requer conectividade de rede adequada entre os nós do cluster. A rede deve suportar a largura de banda necessária para replicação de dados Ceph e operações de cliente. Para ambientes de produção, recomenda-se uma rede de pelo menos 10GbE entre os nós de storage.

Se você estiver utilizando uma rede de storage dedicada (como no caso de LUNs SAN), certifique-se de que esta rede esteja adequadamente configurada e que todos os nós tenham acesso aos LUNs necessários através dos caminhos multipath configurados.

#### Verificação de Recursos

Antes de instalar o ODF, execute uma verificação completa dos recursos disponíveis no cluster:

```bash
# Verificar nós disponíveis e seus recursos
oc get nodes -o wide

# Verificar recursos de CPU e memória por nó
oc describe nodes | grep -A 5 "Allocated resources"

# Verificar dispositivos de storage disponíveis
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== Node: $node ==="
    oc debug node/$node -- chroot /host lsblk
done
```

### Instalação do Operador OpenShift Data Foundation

A instalação do ODF é gerenciada através do OpenShift Data Foundation Operator, que pode ser instalado através do OperatorHub integrado ao OpenShift Container Platform.

#### Instalação via Interface Web

A maneira mais direta de instalar o operador ODF é através da interface web do OpenShift:

1. Acesse o console web do OpenShift como um usuário com privilégios de cluster-admin
2. Navegue para "Operators" → "OperatorHub"
3. Procure por "OpenShift Data Foundation"
4. Selecione o operador e clique em "Install"
5. Configure as opções de instalação conforme necessário
6. Clique em "Install" para iniciar a instalação

#### Instalação via CLI

Alternativamente, o operador pode ser instalado via linha de comando usando manifestos YAML:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: "stable-4.15"
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Aplique este manifesto ao cluster:

```bash
oc apply -f odf-operator-subscription.yaml
```

#### Verificação da Instalação do Operador

Após a instalação, verifique que o operador foi instalado corretamente:

```bash
# Verificar que o namespace foi criado
oc get namespace openshift-storage

# Verificar que o operador está executando
oc get pods -n openshift-storage

# Verificar o status da subscription
oc get subscription -n openshift-storage

# Verificar os CRDs instalados pelo operador
oc get crd | grep odf
```

O operador deve estar no status "Succeeded" e todos os pods devem estar no status "Running" antes de prosseguir com a criação do cluster de storage.

### Configuração do Local Storage Operator

Para utilizar LUNs localmente anexados (incluindo LUNs SAN apresentados como dispositivos locais através de multipath), é necessário instalar e configurar o Local Storage Operator.

#### Instalação do Local Storage Operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: "stable"
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
```

#### Criação do LocalVolumeSet

O LocalVolumeSet é usado para descobrir automaticamente e provisionar volumes persistentes a partir dos dispositivos de storage locais (incluindo dispositivos multipath):

```yaml
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: odf-localvolumeset
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: cluster.ocs.openshift.io/openshift-storage
        operator: In
        values:
        - ""
  storageClassName: localblock
  volumeMode: Block
  fsType: ""
  maxDeviceCount: 10
  deviceInclusionSpec:
    deviceTypes:
    - disk
    deviceMechanicalProperties:
    - NonRotational
    - Rotational
    minSize: 100Gi
    maxSize: 10Ti
    models:
    - ".*"
    vendors:
    - ".*"
    paths:
    - "/dev/mapper/mpath*"
```

Esta configuração instrui o Local Storage Operator a descobrir automaticamente dispositivos multipath que correspondam aos critérios especificados e criar PersistentVolumes para eles.

#### Aplicação de Labels aos Nós

Antes de aplicar o LocalVolumeSet, é necessário aplicar labels apropriados aos nós que participarão do cluster ODF:

```bash
# Aplicar label aos nós de storage
oc label node worker-1 cluster.ocs.openshift.io/openshift-storage=""
oc label node worker-2 cluster.ocs.openshift.io/openshift-storage=""
oc label node worker-3 cluster.ocs.openshift.io/openshift-storage=""

# Verificar que os labels foram aplicados
oc get nodes -l cluster.ocs.openshift.io/openshift-storage
```

### Criação do StorageSystem

Após a instalação dos operadores necessários e a configuração do Local Storage, o próximo passo é criar o StorageSystem, que é o recurso principal que define o cluster ODF.

#### Configuração do StorageSystem

```yaml
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: openshift-storage
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: openshift-storage
---
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  arbiter: {}
  encryption:
    kms: {}
  externalStorage: {}
  flexibleScaling: true
  resources:
    mds:
      limits:
        cpu: "3"
        memory: "8Gi"
      requests:
        cpu: "1"
        memory: "8Gi"
    mgr:
      limits:
        cpu: "1"
        memory: "3Gi"
      requests:
        cpu: "1"
        memory: "3Gi"
    mon:
      limits:
        cpu: "1"
        memory: "2Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
    noobaa-core:
      limits:
        cpu: "1"
        memory: "4Gi"
      requests:
        cpu: "1"
        memory: "4Gi"
    noobaa-db:
      limits:
        cpu: "1"
        memory: "4Gi"
      requests:
        cpu: "1"
        memory: "4Gi"
    osd:
      limits:
        cpu: "2"
        memory: "5Gi"
      requests:
        cpu: "1"
        memory: "5Gi"
    prepareosd:
      limits:
        cpu: "500m"
        memory: "50Mi"
      requests:
        cpu: "500m"
        memory: "50Mi"
    rgw:
      limits:
        cpu: "1"
        memory: "4Gi"
      requests:
        cpu: "1"
        memory: "4Gi"
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      metadata: {}
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 100Gi
        storageClassName: localblock
        volumeMode: Block
      status: {}
    name: ocs-deviceset-localblock
    placement: {}
    portable: false
    replica: 3
    resources:
      limits:
        cpu: "2"
        memory: "5Gi"
      requests:
        cpu: "1"
        memory: "5Gi"
  version: 4.15.0
```

#### Aplicação da Configuração

Aplique a configuração do StorageSystem ao cluster:

```bash
oc apply -f storage-system.yaml
```

### Monitoramento da Instalação

A instalação do ODF pode levar vários minutos para ser concluída. Durante este processo, vários pods serão criados e configurados. É importante monitorar o progresso da instalação para identificar e resolver quaisquer problemas que possam surgir.

#### Verificação do Status dos Pods

```bash
# Monitorar todos os pods no namespace openshift-storage
watch oc get pods -n openshift-storage

# Verificar logs de pods específicos se houver problemas
oc logs -n openshift-storage <nome-do-pod>

# Verificar eventos no namespace
oc get events -n openshift-storage --sort-by='.lastTimestamp'
```

#### Verificação do Status do Cluster Ceph

Após a instalação ser concluída, verifique o status do cluster Ceph subjacente:

```bash
# Verificar o status geral do cluster
oc get storagecluster -n openshift-storage

# Verificar o status detalhado do Ceph
oc rsh -n openshift-storage $(oc get pods -n openshift-storage | grep rook-ceph-tools | awk '{print $1}')

# Dentro do pod rook-ceph-tools, execute:
ceph status
ceph osd status
ceph df
```

#### Verificação das Storage Classes

O ODF cria automaticamente várias storage classes que podem ser utilizadas por aplicações:

```bash
# Listar todas as storage classes criadas pelo ODF
oc get storageclass | grep ocs

# Verificar detalhes de uma storage class específica
oc describe storageclass ocs-storagecluster-ceph-rbd
```

### Configuração de Monitoramento e Alertas

O ODF integra-se com o sistema de monitoramento do OpenShift para fornecer métricas e alertas sobre o estado do cluster de storage.

#### Verificação do Monitoramento

```bash
# Verificar que os ServiceMonitors foram criados
oc get servicemonitor -n openshift-storage

# Verificar que as métricas estão sendo coletadas
oc get prometheus -n openshift-monitoring

# Acessar o console de monitoramento
echo "Acesse: https://$(oc get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}')"
```

#### Configuração de Alertas Personalizados

Você pode configurar alertas personalizados para monitorar aspectos específicos do seu ambiente ODF:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: odf-custom-alerts
  namespace: openshift-storage
spec:
  groups:
  - name: odf.custom.rules
    rules:
    - alert: ODFHighLatency
      expr: ceph_osd_apply_latency_ms > 100
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High OSD apply latency detected"
        description: "OSD {{ $labels.ceph_daemon }} has high apply latency of {{ $value }}ms"
    - alert: ODFLowDiskSpace
      expr: ceph_cluster_total_used_bytes / ceph_cluster_total_bytes > 0.8
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "ODF cluster disk usage is high"
        description: "ODF cluster disk usage is {{ $value | humanizePercentage }}"
```

### Testes de Funcionalidade

Após a instalação ser concluída com sucesso, é importante realizar testes para verificar que o ODF está funcionando corretamente.

#### Teste de Criação de PVC

Crie um PersistentVolumeClaim de teste para verificar que o provisioning dinâmico está funcionando:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: ocs-storagecluster-ceph-rbd
```

```bash
# Aplicar o PVC de teste
oc apply -f test-pvc.yaml

# Verificar que o PVC foi provisionado
oc get pvc test-pvc

# Verificar que o PV foi criado automaticamente
oc get pv | grep test-pvc
```

#### Teste de Pod com Storage

Crie um pod que utilize o PVC para verificar que o storage está funcionando corretamente:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: default
spec:
  containers:
  - name: test-container
    image: registry.redhat.io/ubi8/ubi:latest
    command:
    - sleep
    - "3600"
    volumeMounts:
    - name: test-storage
      mountPath: /data
  volumes:
  - name: test-storage
    persistentVolumeClaim:
      claimName: test-pvc
```

```bash
# Aplicar o pod de teste
oc apply -f test-pod.yaml

# Verificar que o pod está executando
oc get pod test-pod

# Testar escrita e leitura no volume
oc exec test-pod -- dd if=/dev/zero of=/data/testfile bs=1M count=100
oc exec test-pod -- ls -la /data/
oc exec test-pod -- rm /data/testfile
```

### Configuração de Backup e Disaster Recovery

Para ambientes de produção, é essencial configurar estratégias adequadas de backup e disaster recovery para o cluster ODF.

#### Configuração do OADP (OpenShift API for Data Protection)

O OADP fornece capacidades de backup e restore para aplicações e dados no OpenShift:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable-1.3
  installPlanApproval: Automatic
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

#### Configuração de Snapshots

O ODF suporta snapshots de volumes, que podem ser utilizados para backup e restore rápidos:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ocs-storagecluster-rbdplugin-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: openshift-storage.rbd.csi.ceph.com
deletionPolicy: Delete
parameters:
  clusterID: openshift-storage
  csi.storage.k8s.io/snapshotter-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/snapshotter-secret-namespace: openshift-storage
```

### Otimização de Performance

Para obter o melhor desempenho do seu cluster ODF, considere as seguintes otimizações.

#### Tuning de Parâmetros Ceph

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-config-override
  namespace: openshift-storage
data:
  config: |
    [global]
    osd_pool_default_size = 3
    osd_pool_default_min_size = 2
    osd_pool_default_pg_num = 128
    osd_pool_default_pgp_num = 128
    osd_max_write_size = 512
    osd_client_message_size_cap = 2147483648
    osd_deep_scrub_interval = 2419200
    osd_map_cache_size = 1024
    osd_recovery_max_active = 5
    osd_max_backfills = 2
    osd_recovery_op_priority = 2
    osd_recovery_max_chunk = 1048576
    osd_op_threads = 8
```

#### Configuração de Node Affinity

Para garantir que os pods ODF sejam distribuídos adequadamente pelos nós de storage:

```yaml
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  placement:
    osd:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: In
              values:
              - ""
      tolerations:
      - effect: NoSchedule
        key: node.ocs.openshift.io/storage
        operator: Equal
        value: "true"
```


## Troubleshooting e Resolução de Problemas

### Problemas Comuns com Multipath

Durante a implementação de multipath com ODF, podem surgir diversos problemas que requerem diagnóstico e resolução cuidadosos.

#### Dispositivos Multipath Não Detectados

Um dos problemas mais comuns é quando os dispositivos multipath não são detectados corretamente pelo sistema. Isso pode ocorrer devido a configurações incorretas no arquivo multipath.conf ou problemas com a conectividade SAN.

Para diagnosticar este problema, execute os seguintes comandos em cada nó:

```bash
# Verificar se o serviço multipathd está ativo
systemctl status multipathd

# Verificar logs do multipathd
journalctl -u multipathd -f

# Forçar uma nova detecção de dispositivos
multipath -r

# Verificar dispositivos SCSI disponíveis
lsscsi -g

# Verificar se os dispositivos têm múltiplos caminhos
multipath -ll -v3
```

Se os dispositivos não estão sendo detectados, verifique:
- Se os LUNs estão corretamente apresentados pelo storage SAN
- Se a configuração de zoning (para Fibre Channel) ou discovery (para iSCSI) está correta
- Se o arquivo multipath.conf não está excluindo os dispositivos através da seção blacklist

#### Problemas de Performance com Multipath

Problemas de performance podem manifestar-se como latência alta ou throughput baixo. Estes problemas frequentemente estão relacionados à configuração inadequada do algoritmo de balanceamento de carga ou problemas com caminhos específicos.

Para diagnosticar problemas de performance:

```bash
# Verificar estatísticas de I/O por caminho
iostat -x 1

# Verificar estatísticas específicas do multipath
dmsetup status
dmsetup table

# Testar performance de caminhos individuais
dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct
dd if=/dev/zero of=/dev/sdc bs=1M count=100 oflag=direct

# Comparar com performance do dispositivo multipath
dd if=/dev/zero of=/dev/mapper/mpatha bs=1M count=100 oflag=direct
```

### Problemas Específicos do ODF

#### Falha na Criação de OSDs

Um problema comum durante a instalação do ODF é a falha na criação de OSDs (Object Storage Daemons) do Ceph. Isso pode ocorrer quando os dispositivos não estão adequadamente limpos ou quando há problemas de permissão.

Para diagnosticar problemas de OSD:

```bash
# Verificar logs do operador rook-ceph
oc logs -n openshift-storage deployment/rook-ceph-operator

# Verificar status dos pods prepare-osd
oc get pods -n openshift-storage | grep prepare

# Verificar logs detalhados de um pod prepare-osd com falha
oc logs -n openshift-storage <prepare-osd-pod-name>

# Verificar se os dispositivos estão limpos
oc debug node/<node-name> -- chroot /host wipefs -a /dev/mapper/mpatha
```

#### Problemas de Conectividade Ceph

Problemas de conectividade entre componentes Ceph podem causar degradação do cluster ou falhas de I/O:

```bash
# Acessar o pod rook-ceph-tools para diagnóstico
oc rsh -n openshift-storage $(oc get pods -n openshift-storage | grep rook-ceph-tools | awk '{print $1}')

# Dentro do pod, verificar status do cluster
ceph status
ceph health detail

# Verificar conectividade entre OSDs
ceph osd tree
ceph osd stat

# Verificar logs de componentes específicos
ceph log last 50
```

### Procedimentos de Manutenção

#### Substituição de Dispositivos com Falha

Quando um dispositivo de storage falha, é necessário substituí-lo sem interromper as operações do cluster:

```bash
# Identificar o OSD com falha
ceph osd tree | grep down

# Marcar o OSD como out (fora do cluster)
ceph osd out osd.<id>

# Aguardar a redistribuição dos dados
ceph -w

# Remover o OSD do cluster
ceph osd purge osd.<id> --yes-i-really-mean-it

# Limpar o dispositivo físico
wipefs -a /dev/mapper/mpath<x>

# Adicionar o novo dispositivo através do Local Storage Operator
# (o processo será automatizado se o LocalVolumeSet estiver configurado corretamente)
```

#### Expansão do Cluster

Para adicionar novos nós de storage ao cluster ODF:

```bash
# Aplicar labels ao novo nó
oc label node <new-node> cluster.ocs.openshift.io/openshift-storage=""

# Verificar que os novos dispositivos são detectados
oc get localvolume -n openshift-local-storage

# Escalar o StorageCluster para incluir os novos dispositivos
oc patch storagecluster ocs-storagecluster -n openshift-storage --type merge -p '{"spec":{"storageDeviceSets":[{"count":2,"dataPVCTemplate":{"spec":{"resources":{"requests":{"storage":"100Gi"}},"storageClassName":"localblock","volumeMode":"Block"}},"name":"ocs-deviceset-localblock","replica":3}]}}'
```

### Monitoramento Contínuo

#### Configuração de Alertas Avançados

Configure alertas específicos para monitorar a saúde do multipath e do ODF:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: multipath-odf-monitoring
  namespace: openshift-storage
spec:
  groups:
  - name: multipath.rules
    rules:
    - alert: MultipathDeviceDown
      expr: up{job="node-exporter"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Multipath device path is down"
        description: "A multipath device path is down on node {{ $labels.instance }}"
    
    - alert: CephOSDDown
      expr: ceph_osd_up == 0
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Ceph OSD is down"
        description: "Ceph OSD {{ $labels.ceph_daemon }} is down"
    
    - alert: CephClusterDegraded
      expr: ceph_health_status != 0
      for: 10m
      labels:
        severity: critical
      annotations:
        summary: "Ceph cluster is in degraded state"
        description: "Ceph cluster health is {{ $labels.status }}"
```

#### Scripts de Monitoramento Automatizado

Crie scripts para monitoramento automatizado da infraestrutura:

```bash
#!/bin/bash
# Script de verificação de saúde do ODF com multipath

echo "=== Verificação de Saúde ODF/Multipath ==="
echo "Data: $(date)"
echo

# Verificar status dos nós
echo "Status dos nós:"
oc get nodes -l cluster.ocs.openshift.io/openshift-storage

echo
echo "Status dos dispositivos multipath:"
for node in $(oc get nodes -l cluster.ocs.openshift.io/openshift-storage -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== Node: $node ==="
    oc debug node/$node -- chroot /host multipath -ll 2>/dev/null | grep -E "(mpath|status)"
done

echo
echo "Status do cluster Ceph:"
oc rsh -n openshift-storage $(oc get pods -n openshift-storage | grep rook-ceph-tools | awk '{print $1}') -- ceph status

echo
echo "Status dos OSDs:"
oc rsh -n openshift-storage $(oc get pods -n openshift-storage | grep rook-ceph-tools | awk '{print $1}') -- ceph osd stat

echo
echo "Utilização de storage:"
oc rsh -n openshift-storage $(oc get pods -n openshift-storage | grep rook-ceph-tools | awk '{print $1}') -- ceph df
```

## Considerações de Segurança e Compliance

### Criptografia de Dados

O ODF suporta criptografia de dados em repouso através de integração com sistemas de gerenciamento de chaves externos. Para ambientes que requerem compliance com regulamentações como GDPR, HIPAA ou PCI-DSS, a criptografia é essencial.

#### Configuração com HashiCorp Vault

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-secret
  namespace: openshift-storage
type: Opaque
data:
  token: <base64-encoded-vault-token>
---
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  encryption:
    enable: true
    kms:
      enable: true
      connectionDetails:
        KMS_PROVIDER: vault
        VAULT_ADDR: https://vault.example.com:8200
        VAULT_BACKEND_PATH: ocs
        VAULT_SECRET_ENGINE: kv-v2
      tokenSecretName: vault-secret
```

### Auditoria e Logging

Configure logging detalhado para auditoria de acesso e operações:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-audit-config
  namespace: openshift-storage
data:
  config: |
    [global]
    log_to_file = true
    log_file = /var/log/ceph/ceph.log
    log_max_new = 1000
    log_max_recent = 10000
    debug_ms = 1
    debug_osd = 5
    debug_filestore = 5
    debug_journal = 5
```

## Conclusão

A implementação de OpenShift Data Foundation com LUNs de storage e configuração de multipath representa uma solução robusta e escalável para armazenamento persistente em ambientes OpenShift. Este guia forneceu uma abordagem abrangente que cobre desde a configuração inicial do multipath através de MachineConfig até a instalação completa e otimização do ODF.

Os pontos-chave para uma implementação bem-sucedida incluem:

**Planejamento Adequado**: A importância de um planejamento cuidadoso não pode ser subestimada. Isso inclui a avaliação adequada dos requisitos de hardware, rede e storage, bem como o entendimento das dependências entre componentes.

**Configuração Correta do Multipath**: A configuração adequada do multipath é fundamental para garantir alta disponibilidade e performance. O uso de MachineConfig garante que as configurações sejam aplicadas de forma consistente e persistente em todos os nós do cluster.

**Preparação Meticulosa dos Dispositivos**: A preparação adequada dos LUNs, incluindo limpeza completa e verificação de conectividade, é essencial para evitar problemas durante a instalação e operação do ODF.

**Monitoramento Contínuo**: A implementação de monitoramento abrangente e alertas proativos permite a detecção precoce de problemas e a manutenção preventiva do ambiente.

**Procedimentos de Manutenção**: O estabelecimento de procedimentos claros para manutenção, troubleshooting e expansão garante que o ambiente possa ser mantido e evoluído ao longo do tempo.

A combinação de OpenShift Data Foundation com storage SAN multipath oferece uma base sólida para aplicações empresariais que requerem armazenamento de alta disponibilidade e performance. Com a configuração adequada e manutenção contínua, esta solução pode fornecer anos de operação confiável e escalável.

Para ambientes de produção, recomenda-se fortemente a realização de testes extensivos em ambiente de desenvolvimento ou staging antes da implementação em produção. Isso inclui testes de failover, recuperação de desastres e performance sob carga.

A evolução contínua tanto do OpenShift quanto do ODF significa que novas funcionalidades e melhorias são regularmente disponibilizadas. Manter-se atualizado com as últimas versões e best practices é essencial para maximizar os benefícios desta solução de armazenamento.

## Referências

[1] Red Hat OpenShift Data Foundation Documentation - https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation

[2] OpenShift Container Platform Machine Configuration - https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/machine_configuration

[3] Andreas Karis Blog - OpenShift with iSCSI multipath - https://andreaskaris.github.io/blog/openshift/openshift-with-multipath/

[4] Red Hat Customer Portal - Allowing OSD's to be provisioned in ODF when dm-multipath enabled - https://access.redhat.com/solutions/6989736

[5] Red Hat OpenShift Data Foundation Planning Guide - https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.15/html/planning_your_deployment

[6] Ceph Documentation - https://docs.ceph.com/

[7] Linux Device Mapper Multipath - https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_device_mapper_multipath

[8] OpenShift Local Storage Operator - https://docs.openshift.com/container-platform/4.15/storage/persistent_storage/persistent-storage-local.html

