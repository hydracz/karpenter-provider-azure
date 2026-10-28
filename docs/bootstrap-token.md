# 手动配置 Bootstrap Token：方案与原理

## 方案

**自己生成一枚 bootstrap token，登记到集群，再让 Karpenter 通过固定的
Secret 引用使用它。** 全程不需要 `kubeadm`，也不启用自动维护 token 的代码。

创建四类资源：

| 资源 | 作用 |
| --- | --- |
| Karpenter ServiceAccount | Controller 访问 Kubernetes 和使用 Azure Workload Identity |
| 两个 ClusterRoleBinding | 允许 bootstrap 身份申请节点证书，并进入标准 CSR 自动审批流程 |
| `kube-system/bootstrap-token-<id>` | 向 API server 登记这枚 token |
| `karpenter/karpenter-bootstrap-token` | 为 Helm 提供完整 token，名称和 key 后续保持不变 |

**不设置 `expiration`，token 就没有主动过期时间。** 是否允许这样创建，由
目标 AKS 的策略决定。若策略要求有效期，就在权威 Secret 的 `stringData` 中
设置符合策略的 UTC RFC3339 `expiration`，以后到期前人工处理。

本文保留旧 token，不包含删除步骤。没有过期时间的旧 token 会继续有效。
长期 token 可以用于申请节点证书，应按敏感凭据保管。

适用范围：self-hosted 的 `aksscriptless` / `bootstrappingclient` 模式。
NAP 和 AKS Machine API 的节点入群仍由 AKS 管理。
完整 Helm 安装步骤见 [使用 Helm 手动部署 Karpenter](helm-install-zh.md)。

## 原理：谁认可 token，谁授予权限

### Token 不是集群签发的，节点证书才是

这枚 token 是管理员在本地生成的随机字符串，格式为
`6位ID.16位secret`。它不是 JWT，没有集群数字签名。

管理员通过 Kubernetes API 创建 `bootstrap.kubernetes.io/token` Secret，
就是把这枚凭据**登记到集群**。创建操作受管理员自身的 RBAC 和 admission
策略约束；普通用户不能因此随意登记凭据。

### API server 根据 Secret 认证

新节点使用 token 连接 API server。已启用的 bootstrap authenticator 会检查：

- Secret 位于 `kube-system`，类型和 `bootstrap-token-<id>` 名称正确；
- 请求中的 ID 和 secret 与保存的数据相符；
- `usage-bootstrap-authentication` 为 `"true"`，并且 token 没有过期。

认证通过后，节点获得临时身份：

```text
用户名：system:bootstrap:<id>
组：system:bootstrappers
附加组：system:bootstrappers:karpenter-manual
```

附加组来自下面 YAML 的 `auth-extra-groups`。**Secret 决定认证身份，
ClusterRoleBinding 决定这个身份能做什么**，两者分开。

### RBAC 授权申请证书，控制平面签发证书

本文的两个绑定将专用组 `system:bootstrappers:karpenter-manual` 关联到：

| ClusterRole | 授予的能力 |
| --- | --- |
| `system:node-bootstrapper` | 创建、读取节点证书申请 CSR |
| `system:certificates.k8s.io:certificatesigningrequests:nodeclient` | 允许标准审批器批准符合节点客户端证书要求的 CSR |

完整入群过程是：

```text
Karpenter 将 manual token 写入新 VM 的 bootstrap 配置
    → kubelet 用 token 通过 API server 认证
    → kubelet 提交 kubernetes.io/kube-apiserver-client-kubelet CSR
    → 控制平面的审批器检查请求及授权，批准 CSR
    → 签名器使用集群 CA 签发 kubelet 客户端证书
    → kubelet 使用证书，以 system:node:<节点名> / system:nodes 身份工作
```

入群后使用的是节点证书和证书续期，不再依靠 bootstrap token 维持日常连接。
Karpenter 本身不签发 token 或节点证书；它只负责把所配置的 token 交给新节点。
AKS 管理这些控制平面组件，最终要以 TokenReview 成功、新节点 CSR 获批并
进入 `Ready` 为准。

## 1. 准备参数

需要 Bash、`kubectl`、Helm、OpenSSL、jq 和 Mike Farah `yq` v4，以及有权创建
这些资源的管理员 kubeconfig。Azure 身份、联邦凭据和 Azure RBAC 先按
[安装说明](../README.md#installation-self-hosted-karpenter)配置。

下面是全新安装的例子。已有部署沿用当前 namespace 和 ServiceAccount。
Azure 联邦凭据的 subject 必须匹配
`system:serviceaccount:<namespace>:<service-account>`。

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

生成的文件包含凭据，保存在私密目录，不要提交到 Git 或输出到日志。

## 2. 创建 ServiceAccount 和权限

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
automountServiceAccountToken: true
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

ServiceAccount 的 Controller 权限由 Helm chart 配置；上面两个绑定只授权给
新节点的 bootstrap 组。Controller 需要挂载 ServiceAccount token 才能访问
Kubernetes API。官方 `1.10.2` chart 不在 Pod 层显式开启挂载，因此这里必须
设为 `true`；设为 `false` 会导致 Controller 启动失败。这与新节点使用的
bootstrap token 是两种不同的凭据。

已有 Helm 部署保留原 ServiceAccount，只创建两个新绑定，继续使用原有
`serviceAccount.create` 设置，避免改变资源归属。

## 3. 创建 token，并从集群获取 token

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
kubectl create -f "$BOOTSTRAP_DIR/bootstrap-token.yaml"

BOOTSTRAP_TOKEN="$(kubectl -n kube-system get secret \
  "bootstrap-token-${TOKEN_ID}" -o json \
  | jq -er '(.data["token-id"] | @base64d) + "." + (.data["token-secret"] | @base64d)')"

cat > "$BOOTSTRAP_DIR/controller-token.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: karpenter-bootstrap-token
  namespace: ${KARPENTER_NAMESPACE}
type: Opaque
stringData:
  token: "${BOOTSTRAP_TOKEN}"
EOF
kubectl apply -f "$BOOTSTRAP_DIR/controller-token.yaml"
```

第一份是 API server 使用的权威记录；第二份为 Controller 提供完整 token。
上述命令将 token 读入变量，不在终端显示。若 `create` 返回 `AlreadyExists`，
重新生成 ID/secret，不覆盖已有凭据。

## 4. 确认集群认可这枚 token

查看集群实际保存的有效期，不输出凭据：

```bash
kubectl -n kube-system get secret "bootstrap-token-${TOKEN_ID}" -o json \
  | jq '{
      name: .metadata.name,
      expiration: (if .data.expiration then (.data.expiration | @base64d) else "not set" end)
    }'
```

`not set` 表示没有过期字段。如果 admission 策略补入了有效期，以服务端值为准。

用 TokenReview 实际验证认证：

```bash
cat > "$BOOTSTRAP_DIR/token-review.json" <<EOF
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {"token": "${BOOTSTRAP_TOKEN}"}
}
EOF
kubectl create -f "$BOOTSTRAP_DIR/token-review.json" -o json \
  | jq -e '{
      authenticated: .status.authenticated,
      username: .status.user.username,
      groups: .status.user.groups
    } | select(.authenticated == true)'
```

预期 `authenticated: true`，用户名为 `system:bootstrap:<id>`，附加组包含
`system:bootstrappers:karpenter-manual`。创建 Secret 成功本身不代表认证成功。

再检查该身份的 CSR 创建权限：

```bash
kubectl auth can-i create certificatesigningrequests.certificates.k8s.io \
  --as="system:bootstrap:${TOKEN_ID}" \
  --as-group=system:authenticated \
  --as-group=system:bootstrappers \
  --as-group=system:bootstrappers:karpenter-manual
```

预期 `yes`。TokenReview 验证认证，`can-i` 验证 RBAC；新节点的 CSR 签发和
`Ready` 状态验证完整入群链路。

## 5. Helm 引用固定名称的 Secret

先准备包含 Azure、子网、集群、SSH key 等配置的完整 `karpenter-values.yaml`。
执行下面的转换，保留其他环境变量，只替换 token 的来源：

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

`create: false` 对应本文手工创建 ServiceAccount 的新安装。已有 Helm 管理的
ServiceAccount 保持原来的 `true`，同时保留其 annotations。

最终 Deployment 中的 token 配置只有引用，没有明文：

```yaml
- name: KUBELET_BOOTSTRAP_TOKEN
  valueFrom:
    secretKeyRef:
      name: karpenter-bootstrap-token
      key: token
```

安装匹配版本的官方 chart 和 Controller。新安装会安装 chart 自带的 CRD：

```bash
export KARPENTER_VERSION=1.10.2
helm upgrade --install "$HELM_RELEASE" oci://mcr.microsoft.com/aks/karpenter/karpenter \
  --version "$KARPENTER_VERSION" \
  --namespace "$KARPENTER_NAMESPACE" \
  --values "$BOOTSTRAP_DIR/karpenter-values-secretref.yaml" \
  --wait
```

已有部署保持其原有且互相匹配的 chart/镜像版本。若使用本仓库的自定义 chart，
也要使用与其匹配的 Controller 构建，不要混用不同版本的 feature gates。

`configure-values.sh` 会选取集群中的第一个 bootstrap Secret；每次重生成
values 后，重新执行上述引用转换。保留完整 `controller.env`，因为 Helm 会
整体替换环境变量列表。移除其他位置的旧 token 参数，避免覆盖这里的配置。

## 6. 后续如何使用

无过期时间的 token 可以持续用于新节点入群，不需要为每次创建节点生成新 token。
本文不删除旧 token，不改变已有节点。

如果主动换一枚 token，重新执行第 3、4 节，确认新凭据有效，然后让 Controller
重新读取固定名称的 Secret：

```bash
kubectl -n "$KARPENTER_NAMESPACE" rollout restart deployment \
  -l "app.kubernetes.io/instance=${HELM_RELEASE}"
kubectl -n "$KARPENTER_NAMESPACE" rollout status deployment \
  -l "app.kubernetes.io/instance=${HELM_RELEASE}" --timeout=5m
```

**无需编辑 Deployment，也无需因 token 值变化执行 Helm upgrade。**
`secretKeyRef` 不会自动续期或热更新进程环境变量，所以换 token 后需要这次
滚动重启。查看 `kubectl get nodeclaims`、`kubectl get nodes` 和 `kubectl get csr`
确认新节点入群；不要批量批准所有 CSR。

## 参考

- [Kubernetes bootstrap tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/)
- [Kubelet TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
- [Secret 环境变量](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/#define-container-environment-variables-using-secret-data)
