# 手动配置 Bootstrap Token：无需 kubeadm

本文面向 **self-hosted Karpenter 的 `aksscriptless` / `bootstrappingclient`
模式**。仅使用 YAML、`kubectl` 和 Helm 配置节点入群凭据，不启用自动维护
token 的代码、定时任务或额外控制器。NAP 和 AKS Machine API 的节点入群由
AKS 管理，不要用本文替换其凭据。

**推荐方式：** 创建专用的 Kubernetes bootstrap token，通过固定名称的 Secret
提供给 Helm。若集群策略允许，可不设置过期时间；若必须定期轮换，只需更新
Secret 并滚动重启 Karpenter，不必反复修改 Deployment 或 Helm 中的 token 值。

## 1. 前提与对象用途

需要 Bash、`kubectl`、Helm、OpenSSL、jq 和 Mike Farah `yq` v4，**不需要
`kubeadm`**。使用有权创建 Secret、ServiceAccount 和 ClusterRoleBinding 的
管理员 kubeconfig，并确认当前操作的是目标 AKS 集群。

Azure 身份、联邦凭据、Azure RBAC、网络配置和镜像等仍须按照
[安装说明](../README.md#installation-self-hosted-karpenter)配置。本文只替换
bootstrap token 的来源，并不是完整的 AKS/Karpenter 安装配置。

| 对象 | 用途 |
| --- | --- |
| Controller 的 ServiceAccount | Karpenter 访问 Kubernetes，并通过 Workload Identity 获取 Azure 身份 |
| Bootstrap 组的两个 ClusterRoleBinding | 允许新节点申请 kubelet 客户端证书，并授权标准 CSR 自动审批流程 |
| `kube-system/bootstrap-token-<id>` | API server 验证节点 bootstrap token 的**权威 Secret** |
| Controller 命名空间中的 `karpenter-bootstrap-token` | 保存完整的 `id.secret`，供 `KUBELET_BOOTSTRAP_TOKEN` 环境变量引用 |

不要创建 `kubernetes.io/service-account-token` Secret，也不要将
`kubectl create token <service-account>` 生成的 JWT 当作本文的 bootstrap
token。这是两种不同身份；这里的 ServiceAccount **不需要**绑定 bootstrap
权限或 `cluster-admin`。Controller 原有的 Kubernetes 权限仍由 Helm chart 配置。

`secretKeyRef` 不能跨命名空间，也不能把两个 Secret key 拼接成一个字符串，
所以需要 Controller 命名空间内的第二份完整 token。复制这份 Secret **不会**
延长权威 Secret 的有效期。

## 2. 准备参数与权限 YAML

以下以全新安装、release 名称 `karpenter`、ServiceAccount 名称 `karpenter-sa`
为例。已有部署应沿用当前命名空间和 ServiceAccount；Azure 联邦凭据的 subject
必须匹配 `system:serviceaccount:<namespace>:<service-account>`。

```bash
set +x
umask 077
export KARPENTER_NAMESPACE=karpenter
export KARPENTER_SERVICE_ACCOUNT=karpenter-sa
export HELM_RELEASE=karpenter
export KARPENTER_CLIENT_ID="<Karpenter Azure managed identity 的 client ID>"
BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/karpenter-bootstrap.XXXXXX")"
kubectl config current-context
```

不要开启 shell tracing，也不要把稍后生成的凭据文件放入 Git、工单、聊天记录
或 CI 日志。Secret 中的 base64 不是加密。`BOOTSTRAP_DIR` 是本地私密工作目录，
文件应妥善保管，完成操作后按组织的凭据处理要求清理。

创建 `access.yaml`：

```bash
cat > "$BOOTSTRAP_DIR/access.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${KARPENTER_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${KARPENTER_SERVICE_ACCOUNT}
  namespace: ${KARPENTER_NAMESPACE}
  annotations:
    azure.workload.identity/client-id: "${KARPENTER_CLIENT_ID}"
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: karpenter-manual-bootstrap-csr
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
  - kind: Group
    name: system:bootstrappers:karpenter-manual
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: karpenter-manual-bootstrap-approve
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
subjects:
  - kind: Group
    name: system:bootstrappers:karpenter-manual
    apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f "$BOOTSTRAP_DIR/access.yaml"
```

这两个绑定只针对专用 bootstrap 组，不修改 AKS 自带的绑定，也不授予
Controller 读取 `kube-system` 中全部 Secret 的权限。Secret 环境变量由 kubelet
注入，不需要因此给 Controller ServiceAccount 增加 Secret `get/list` 权限。
Chart 的 Pod 配置会显式启用 Controller 所需的 ServiceAccount token 挂载。

**已有 Helm 部署的注意事项：** 如果 ServiceAccount 已由 Helm 创建，保留其
Helm 管理方式和 Azure 身份配置，跳过上面的 Namespace/ServiceAccount 两个
对象，只应用两个新的 ClusterRoleBinding。不要为了套用本例，把原来的
`serviceAccount.create: true` 改为 `false`；Helm 升级可能删除它原先管理的
ServiceAccount。

## 3. 用 YAML 创建自己的 token

不要复制 AKS 系统池的 token，也不要使用文档中公开的示例密码。下面每次执行
都会生成新凭据；初次部署执行一次，后续仅在主动轮换时重新执行。

```bash
TOKEN_ID="$(openssl rand -hex 3)"
TOKEN_SECRET="$(openssl rand -hex 8)"

cat > "$BOOTSTRAP_DIR/bootstrap-token.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "Manually managed Karpenter node bootstrap"
  token-id: "${TOKEN_ID}"
  token-secret: "${TOKEN_SECRET}"
  usage-bootstrap-authentication: "true"
  auth-extra-groups: "system:bootstrappers:karpenter-manual"
EOF

cat > "$BOOTSTRAP_DIR/controller-token.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: karpenter-bootstrap-token
  namespace: ${KARPENTER_NAMESPACE}
type: Opaque
stringData:
  token: "${TOKEN_ID}.${TOKEN_SECRET}"
EOF
```

要求如下：

- 权威 Secret 必须位于 `kube-system`，类型必须为
  `bootstrap.kubernetes.io/token`，名称必须是 `bootstrap-token-<token-id>`。
- 完整 token 必须匹配 `[a-z0-9]{6}\.[a-z0-9]{16}`。
- **没有 `expiration` 字段时，Kubernetes bootstrap token 没有主动过期时间。**
  不要写空字符串、`0` 或伪造的超远日期。它仍可被删除、禁用或被策略拒绝，
  因此不等于“保证永远有效”。
- 此处不启用 `usage-bootstrap-signing`：节点通过已配置的 API endpoint 和 CA
  建立信任，不需要签名 kubeadm discovery 的 `cluster-info`。

如果组织或 AKS admission 策略要求有限有效期，在**应用之前**给权威 YAML 增加
UTC RFC3339 `expiration`。例如，策略允许 90 天时：

```bash
# Linux / GNU date:
export EXPIRES_AT="$(date -u -d '+90 days' '+%Y-%m-%dT%H:%M:%SZ')"
# macOS 改用：export EXPIRES_AT="$(date -u -v+90d '+%Y-%m-%dT%H:%M:%SZ')"
yq -i '.stringData.expiration = strenv(EXPIRES_AT)' \
  "$BOOTSTRAP_DIR/bootstrap-token.yaml"
```

省略该可选步骤即可创建无主动过期时间的 token。然后创建权威 Secret，并保存
Controller 使用的副本：

```bash
kubectl create -f "$BOOTSTRAP_DIR/bootstrap-token.yaml"
kubectl apply -f "$BOOTSTRAP_DIR/controller-token.yaml"
```

权威 Secret 使用 `create`，避免随机 ID 碰撞时覆盖现有凭据。如果返回
`AlreadyExists`，重新生成新 ID/secret 和两份 YAML，不要覆盖已有 Secret。

长期 bootstrap token 是敏感的节点准入凭据：配合 CSR 自动审批，泄漏者可以
申请节点客户端证书。仅在接受这一风险且符合组织策略时使用；限制 Secret、
节点 bootstrap 配置及相关本地文件的访问。不要为绕过组织策略而删除过期字段。

AKS 控制平面由 Azure 管理，不能靠这些 YAML 打开 API server 的 bootstrap
authenticator。**创建 Secret 成功并不证明认证成功**；下一节检查实际结果。

## 4. 检查实际有效期与认证

检查服务端保存的元数据和过期字段，避免输出 token 内容：

```bash
kubectl -n kube-system get secret "bootstrap-token-${TOKEN_ID}" -o json \
  | jq '{
      name: .metadata.name,
      type: .type,
      expiration: (if .data.expiration then (.data.expiration | @base64d) else "not set" end)
    }'
```

若策略自动补入了有效期，以服务端保存的值为准。若创建被拒绝，按策略选择
允许的有效期；不要假定所有 AKS 集群都允许无过期时间的凭据。

管理员可以创建一次非持久化 TokenReview，直接检查这个 token 是否被 API server
接受。输出只保留认证状态和身份，不显示请求中的凭据：

```bash
cat > "$BOOTSTRAP_DIR/token-review.json" <<EOF
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {"token": "${TOKEN_ID}.${TOKEN_SECRET}"}
}
EOF
kubectl create -f "$BOOTSTRAP_DIR/token-review.json" -o json \
  | jq -e '{
      authenticated: .status.authenticated,
      username: .status.user.username,
      groups: .status.user.groups
    } | select(.authenticated == true)'
```

预期身份是 `system:bootstrap:<token-id>`，组包含
`system:bootstrappers:karpenter-manual`。若认证失败，先检查 Secret 的名称、
类型、有效期、认证开关及集群策略；不要继续部署或改用权限更大的 SA token。
认证结果可能有 API server 缓存，修改或撤销凭据后的一次成功结果不代表
凭据变更已经即时生效。

再检查专用 bootstrap 身份的 CSR 创建权限：

```bash
kubectl auth can-i create certificatesigningrequests.certificates.k8s.io \
  --as="system:bootstrap:${TOKEN_ID}" \
  --as-group=system:authenticated \
  --as-group=system:bootstrappers \
  --as-group=system:bootstrappers:karpenter-manual
```

预期为 `yes`。这一步是管理员 impersonation 的 **RBAC 检查**，不能代替前面的
真实 token 认证检查，也不等于已经验证 AKS CSR 签发。需要最终用新节点成功
申请证书并进入 `Ready` 来确认完整链路。

## 5. Helm 使用固定 Secret 引用

先按安装说明准备完整的 `karpenter-values.yaml`，包括 Azure、子网、集群、
SSH key 和所选镜像等配置。在仓库根目录执行下面的转换，**保留其他环境变量**，
只把 token 明文替换为 `valueFrom.secretKeyRef`：

```bash
yq '
  .controller.env = (
    (.controller.env // []) | map(select(.name != "KUBELET_BOOTSTRAP_TOKEN"))
  ) |
  .controller.env += [{
    "name": "KUBELET_BOOTSTRAP_TOKEN",
    "valueFrom": {
      "secretKeyRef": {"name": "karpenter-bootstrap-token", "key": "token"}
    }
  }] |
  .serviceAccount.create = false |
  .serviceAccount.name = strenv(KARPENTER_SERVICE_ACCOUNT) |
  .podLabels."azure.workload.identity/use" = "true"
' karpenter-values.yaml > "$BOOTSTRAP_DIR/karpenter-values-secretref.yaml"
```

这里的 `serviceAccount.create: false` 仅对应本文**全新安装时手工创建 SA** 的
路径。已有 Helm 管理的 SA，应保持 `true`，并保留其 annotations，例如：

```bash
yq -i '.serviceAccount.create = true' \
  "$BOOTSTRAP_DIR/karpenter-values-secretref.yaml"
```

转换后的关键配置是：

```yaml
controller:
  env:
    # 其他现有环境变量继续保留。
    - name: KUBELET_BOOTSTRAP_TOKEN
      valueFrom:
        secretKeyRef:
          name: karpenter-bootstrap-token
          key: token
```

不要只使用这个短片段覆盖整个 `controller.env`：Helm 的列表合并会替换列表，
导致其他必需环境变量丢失。若曾通过命令行参数或 `envFrom` 提供旧 token，也应
清理旧来源，确保没有更高优先级的旧参数。

本仓库的 `configure-values.sh` 会读取集群中找到的第一个 bootstrap Secret，
不保证它就是本文创建的凭据。每次重新运行该脚本后，都要重新执行上面的
Secret 引用转换，不能把新生成的明文配置直接部署回去。

使用本地 chart，并保留与你的 Controller 镜像匹配的其他 values：

```bash
helm upgrade --install "$HELM_RELEASE" ./charts/karpenter \
  --namespace "$KARPENTER_NAMESPACE" \
  --values "$BOOTSTRAP_DIR/karpenter-values-secretref.yaml" \
  --wait
```

本文没有开启自动 token 管理选项，不需要为此构建自定义 Controller。

## 6. 后续维护：不再编辑 Deployment

**Secret 环境变量不是热更新。** 当前 Controller 在启动时读取
`KUBELET_BOOTSTRAP_TOKEN`；即便 Secret 内容更新，运行中的进程仍使用旧值。
挂载 Secret 文件也不会让当前实现自动重读 token。

| 操作 | 更新权威 Secret | 更新 Controller Secret | 重启 Controller |
| --- | --- | --- | --- |
| 无过期时间且未被删除/禁用 | 无需 | 无需 | 无需 |
| 策略允许仅调整同一 token 的过期时间 | 需要 | 无需 | 无需 |
| 更换 token 值 | 创建新 Secret | 更新固定名称 Secret | 需要滚动重启 |

有限期 token 仍需在到期前人工处理，`secretKeyRef` 本身不会续期。若必须更换
token 值，按以下顺序操作：

1. 在同一安全 shell 中保存 `OLD_TOKEN_ID="$TOKEN_ID"`，重新执行第 3 节的文件
   生成步骤，生成**新** ID/secret 并按策略设置有效期。此时只执行
   `kubectl create -f "$BOOTSTRAP_DIR/bootstrap-token.yaml"`，先创建新的权威
   Secret，保留旧权威 Secret，暂不更新 Controller 副本。
   若换了终端，应先从自己的运维记录恢复旧 ID 和本节所需路径/参数。
2. 重新执行第 4 节确认新凭据有效，再更新固定名称的 Secret 并滚动重启：

   ```bash
   kubectl apply -f "$BOOTSTRAP_DIR/controller-token.yaml"
   kubectl -n "$KARPENTER_NAMESPACE" rollout restart deployment \
     -l "app.kubernetes.io/instance=${HELM_RELEASE}"
   kubectl -n "$KARPENTER_NAMESPACE" rollout status deployment \
     -l "app.kubernetes.io/instance=${HELM_RELEASE}" --timeout=5m
   ```

3. 确认新建节点能够进入 `Ready`，且使用旧 token 的在途节点已完成入群，留出
   最坏情况下的 VM provisioning/join 时间后，再删除旧凭据：

   ```bash
   kubectl -n kube-system delete secret "bootstrap-token-${OLD_TOKEN_ID}"
   ```

整个轮换过程保持 `karpenter-bootstrap-token` 的名称与 key 不变，
**不需要修改 Deployment YAML，也不需要因 token 值变化而执行 Helm upgrade**。
Controller 滚动重启可能暂时影响新节点调度/创建，时间取决于副本数和启动情况；
已入群节点正常使用 kubelet 客户端证书，不依赖原 bootstrap token 持续工作。
删除 bootstrap Secret 也不会撤销已签发的客户端证书。

排查时可查看 `kubectl get nodeclaims`、`kubectl get nodes`、`kubectl get csr`；
不要批量批准所有 CSR，不要修改 AKS 的系统证书续期绑定，也不要打印 Secret、
VM customData 或 bootstrap 脚本。CSR 一直 Pending 需检查专用组、审批授权和 AKS
策略，不能仅凭 Secret 存在就判断入群配置正确。

## 参考

- [Kubernetes bootstrap tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/)
- [Kubelet TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
- [Secret 环境变量更新限制](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/#define-container-environment-variables-using-secret-data)
