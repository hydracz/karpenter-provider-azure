# 使用 Helm 手动部署 Karpenter

在已有 AKS 集群安装 self-hosted Karpenter，使用手工创建、无过期时间的
bootstrap token。本文使用官方 chart 和 Controller `1.10.2`，模式为
`aksscriptless`，网络为 Azure CNI Overlay + Cilium。不启用托管 NAP。

需要 Azure CLI、kubectl、Helm、jq、OpenSSL，以及集群管理员和 Azure 角色
分配权限。集群必须已启用 OIDC issuer 和 Workload Identity，并保留至少一个
系统节点运行 Controller。不要在同一集群同时运行托管 NAP 和此部署。

## 1. 连接集群

在仓库根目录执行，替换下面四个参数：

```bash
set -euo pipefail
set +x
umask 077
export AZURE_SUBSCRIPTION_ID="<订阅 ID>"
export RG="<AKS 资源组>"
export CLUSTER_NAME="<AKS 集群名>"
export SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_rsa.pub"
export KARPENTER_NAMESPACE=karpenter
export KARPENTER_SERVICE_ACCOUNT=karpenter-sa
export HELM_RELEASE=karpenter
export KARPENTER_VERSION=1.10.2
export IDENTITY_NAME=karpentermsi
export BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/karpenter-manual.XXXXXX")"
export KUBECONFIG="$BOOTSTRAP_DIR/kubeconfig"

az account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none
az aks get-credentials --resource-group "$RG" --name "$CLUSTER_NAME" \
  --file "$KUBECONFIG" --output none
kubectl config current-context
kubectl get nodes

AKS_JSON="$(az aks show --resource-group "$RG" --name "$CLUSTER_NAME" --output json)"
jq -e '
  .oidcIssuerProfile.enabled == true and
  .securityProfile.workloadIdentity.enabled == true and
  .networkProfile.networkPlugin == "azure" and
  .networkProfile.networkPluginMode == "overlay" and
  .networkProfile.networkDataplane == "cilium" and
  (.nodeProvisioningProfile.mode // "Manual") != "Auto"
' <<< "$AKS_JSON"
```

使用独立 kubeconfig，不覆盖本机原来的集群上下文。如果检查返回 `false`，
先核对集群配置，不要直接安装。

## 2. 配置 Azure 身份

已有身份时直接读取，不重复创建：

```bash
LOCATION="$(jq -er '.location' <<< "$AKS_JSON")"
NODE_RG="$(jq -er '.nodeResourceGroup' <<< "$AKS_JSON")"
az identity list --resource-group "$RG" --query '[].name' --output table
```

仅在身份不存在时执行：

```bash
az identity create --name "$IDENTITY_NAME" --resource-group "$RG" \
  --location "$LOCATION" --output none
```

读取身份并配置联邦凭据：

```bash
IDENTITY_JSON="$(az identity show --name "$IDENTITY_NAME" \
  --resource-group "$RG" --output json)"
export KARPENTER_CLIENT_ID="$(jq -er '.clientId' <<< "$IDENTITY_JSON")"
PRINCIPAL_ID="$(jq -er '.principalId' <<< "$IDENTITY_JSON")"
NODE_RG_ID="$(az group show --name "$NODE_RG" --query id --output tsv)"

az identity federated-credential create --name KARPENTER_FID \
  --identity-name "$IDENTITY_NAME" --resource-group "$RG" \
  --issuer "$(jq -er '.oidcIssuerProfile.issuerUrl' <<< "$AKS_JSON")" \
  --subject "system:serviceaccount:${KARPENTER_NAMESPACE}:${KARPENTER_SERVICE_ACCOUNT}" \
  --audiences api://AzureADTokenExchange --output none

for ROLE in "Virtual Machine Contributor" "Network Contributor" "Managed Identity Operator"; do
  az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --scope "$NODE_RG_ID" --role "$ROLE" --output none
done
```

以上作用域适用于节点资源组内的网络和 kubelet identity。使用自定义 VNet
或跨资源组身份时，还要在相应资源上单独授权；不要扩大到整个订阅。
Azure RBAC 生效可能需要几分钟。

## 3. 创建手工 token

按 [bootstrap-token.md](bootstrap-token.md#2-创建-serviceaccount-和权限)
第 2～4 节创建 ServiceAccount、两个 CSR 绑定和两份 Secret，并完成
TokenReview 与 CSR 权限检查。沿用本文的 namespace、ServiceAccount 和 client ID。
其中第 1 节的临时目录不必重新创建。

必须确认：

- ServiceAccount 的 `automountServiceAccountToken` 为 `true`。
- `kube-system/bootstrap-token-<id>` 没有 `expiration`，TokenReview 为 `true`。
- Controller 使用的 Secret 为 `karpenter/karpenter-bootstrap-token`，key 为 `token`。

ServiceAccount token 用于 Controller 访问 Kubernetes；bootstrap token 用于
新节点申请证书，不能相互替代。无过期时间的 token 是长期凭据，不要打印或提交。

## 4. 生成 Helm values

以下命令使用集群实际配置，不读取或写入 token 明文。Helm 支持 JSON 格式的
values 文件，无需 `configure-values.sh` 或 `yq`。

```bash
SUBNET_ID="$(jq -r '.agentPoolProfiles[0].vnetSubnetId // empty' <<< "$AKS_JSON")"
if [ -z "$SUBNET_ID" ]; then
  SUBNET_ID="$(az vmss list --resource-group "$NODE_RG" \
    --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' \
    --output tsv)"
fi
test -n "$SUBNET_ID" && test "$SUBNET_ID" != "None"
VNET_ID="${SUBNET_ID%/subnets/*}"
VNET_GUID="$(az network vnet show --ids "$VNET_ID" --query resourceGuid --output tsv)"
CLUSTER_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
SSH_PUBLIC_KEY="$(cat "$SSH_PUBLIC_KEY_FILE")"

jq -n --argjson aks "$AKS_JSON" \
  --arg subscription "$AZURE_SUBSCRIPTION_ID" --arg rg "$RG" \
  --arg endpoint "$CLUSTER_ENDPOINT" --arg subnet "$SUBNET_ID" \
  --arg vnetGuid "$VNET_GUID" --arg ssh "$SSH_PUBLIC_KEY" \
  --arg sa "$KARPENTER_SERVICE_ACCOUNT" --arg client "$KARPENTER_CLIENT_ID" '
  {
    replicas: 1,
    serviceAccount: {
      create: false, name: $sa,
      annotations: {"azure.workload.identity/client-id": $client}
    },
    podLabels: {"azure.workload.identity/use": "true"},
    settings: {featureGates: {staticCapacity: false}},
    controller: {
      resources: {
        requests: {cpu: "500m", memory: "1Gi"},
        limits: {cpu: "1", memory: "2Gi"}
      },
      env: ((
        {
          CLUSTER_NAME: $aks.name, CLUSTER_ENDPOINT: $endpoint,
          SSH_PUBLIC_KEY: $ssh, NETWORK_PLUGIN: $aks.networkProfile.networkPlugin,
          NETWORK_PLUGIN_MODE: $aks.networkProfile.networkPluginMode,
          NETWORK_POLICY: ($aks.networkProfile.networkPolicy // ""),
          NETWORK_DATAPLANE: $aks.networkProfile.networkDataplane,
          VNET_SUBNET_ID: $subnet, VNET_GUID: $vnetGuid,
          NODE_IDENTITIES: $aks.identityProfile.kubeletidentity.resourceId,
          KUBELET_IDENTITY_CLIENT_ID: $aks.identityProfile.kubeletidentity.clientId,
          AZURE_SUBSCRIPTION_ID: $subscription, LOCATION: $aks.location,
          AZURE_NODE_RESOURCE_GROUP: $aks.nodeResourceGroup, ARM_RESOURCE_GROUP: $rg,
          ENABLE_AZURE_SDK_LOGGING: "false", USE_SIG: "false",
          PROVISION_MODE: "aksscriptless"
        } | to_entries | map({name: .key, value: .value})
      ) + [{
        name: "KUBELET_BOOTSTRAP_TOKEN",
        valueFrom: {secretKeyRef: {name: "karpenter-bootstrap-token", key: "token"}}
      }])
    }
  }
' > "$BOOTSTRAP_DIR/karpenter-values.json"
```

AKS 自动创建的网络可能不返回 `vnetSubnetId`，此时从现有 VMSS 读取。
多子网集群应明确选择供新节点使用的子网，不要默认采用第一个节点池的子网。
已有部署保留其完整 values；`controller.env` 是整体替换，不是逐项合并。

## 5. 安装并检查

```bash
helm upgrade --install "$HELM_RELEASE" oci://mcr.microsoft.com/aks/karpenter/karpenter \
  --version "$KARPENTER_VERSION" --namespace "$KARPENTER_NAMESPACE" \
  --values "$BOOTSTRAP_DIR/karpenter-values.json" --wait --timeout 5m

kubectl -n "$KARPENTER_NAMESPACE" rollout status deployment/karpenter --timeout=5m
kubectl -n "$KARPENTER_NAMESPACE" get pods -l app.kubernetes.io/name=karpenter
```

预期 Controller 为 `1/1 Running`。已有部署不要随意切换版本；chart、镜像和
feature gates 必须匹配。新安装使用 chart 自带的 CRD；升级已有 CRD 按对应
版本的升级说明处理。

若出现 `failed to download openapi`，先用
`kubectl --request-timeout=30s get --raw=/readyz` 确认 API server 可达。
仅大体积 OpenAPI 下载持续超时时，可给上述 Helm 命令追加
`--disable-openapi-validation`；这只跳过客户端 OpenAPI 校验，不关闭
Kubernetes 服务端校验或 admission。本次实测使用了此参数。

## 6. 验证创建节点

下面创建一个最多使用 2 vCPU 的测试池和一个只能调度到该池的 Pod。
`Standard_D2s_v5` 需在目标区域可用且有配额。
命令中的 `--validate=false` 避免本次环境的客户端 OpenAPI 下载超时；
API server 仍执行资源约束和 admission，网络正常时可以去掉此参数。

```bash
kubectl apply --validate=false -f - <<'EOF'
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: manual-token-validation
spec:
  imageFamily: Ubuntu2404
  osDiskSizeGB: 64
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: manual-token-validation
spec:
  limits:
    cpu: "2"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 60s
  template:
    metadata:
      labels:
        kubernetes.azure.com/ebpf-dataplane: cilium
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: manual-token-validation
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["Standard_D2s_v5"]
      startupTaints:
        - key: node.cilium.io/agent-not-ready
          value: "true"
          effect: NoExecute
---
apiVersion: v1
kind: Pod
metadata:
  name: manual-token-proof
  namespace: karpenter
spec:
  nodeSelector:
    karpenter.sh/nodepool: manual-token-validation
  containers:
    - name: pause
      image: mcr.microsoft.com/oss/kubernetes/pause:3.6
      resources:
        requests:
          cpu: 200m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 64Mi
EOF
kubectl -n karpenter wait --for=condition=Ready pod/manual-token-proof --timeout=10m
kubectl -n karpenter get pod manual-token-proof -o wide
kubectl get nodeclaims,nodes
kubectl get csr
```

通过标准：新 NodeClaim 和节点为 `Ready`，测试 Pod 在该节点 `Running`；
对应客户端 CSR 的用户名为手工 token 的 `system:bootstrap:<id>`，已自动批准
并签发证书。只看到 Azure VM 创建成功或 Helm `deployed` 不算通过。
不要手动批量批准 CSR。

清理测试资源，不卸载 Controller，不删除 token：

```bash
kubectl -n karpenter delete pod manual-token-proof
kubectl delete nodepool manual-token-validation --wait=true --timeout=5m
kubectl delete aksnodeclass manual-token-validation
kubectl get nodeclaims,nodes
```

NodePool 删除由 Karpenter 回收所属节点和 Azure 资源。确认测试 VM、NIC、
磁盘已删除，避免持续计费。集群系统节点仍会计费。

## 常见问题

| 现象 | 检查 |
| --- | --- |
| Controller 启动即退出、日志为空 | ServiceAccount 是否禁用了 token 挂载；Pod 应有 `/var/run/secrets/kubernetes.io/serviceaccount` |
| Azure 返回 403 | Workload Identity subject、身份注解、角色作用域及 RBAC 生效时间 |
| Pod 一直 Pending | NodeClass/NodePool 是否 Ready，SKU 配额及 Pod 的 nodeSelector |
| VM 已创建但节点未注册 | TokenReview、bootstrap 组的 CSR 权限及对应 CSR 是否签发 |
| Helm 下载 OpenAPI 超时 | 按第 5 节检查连通性；仅 OpenAPI 下载超时可跳过客户端校验 |

## 实测记录

2026-10-28，在已有 AKS 1.35.9 集群完成验证：官方 chart/Controller `1.10.2`、
Azure CNI Overlay + Cilium、Ubuntu2404、`Standard_D2s_v5`。

同一枚无 `expiration` 的手工 token 先后用于两个新节点。两次客户端 CSR
均由该 token 身份提交、自动批准并签发，节点和 NodeClaim 均进入 `Ready`，
测试 Pod 在新节点运行。第二次使用本文生成的 values 完成 Helm 升级后执行。

原部署失败原因是 ServiceAccount 禁用了 API token 挂载，改为 `true` 后恢复。
测试节点、VM、NIC 和磁盘已回收，保留 Controller、token 和原系统节点。
无过期字段不代表永久保证：删除 Secret、修改认证或集群策略仍可使 token 失效。
