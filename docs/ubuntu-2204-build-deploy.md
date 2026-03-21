# Ubuntu 22.04 下的编译、镜像发布、Helm 更新与部署测试文档

## 目的

本文给出一套面向 Ubuntu 22.04 x86_64 的实操流程，覆盖以下内容：

1. 编译 karpenter-provider-azure 控制器二进制
2. 构建并推送自定义 Docker 镜像
3. 更新 Helm Chart 使用自定义 image
4. 部署到 AKS 集群
5. 做最小可用验证与功能测试

本文以 self-hosted Karpenter 为目标，不覆盖 AKS 托管 NAP 的发布链路。

## 一、推荐环境

推荐使用：

1. Ubuntu 22.04 LTS
2. x86_64
3. Docker 已安装并可用
4. 已安装 Azure CLI、kubectl、Helm
5. 可以访问目标 ACR 和 AKS 集群

建议资源：

1. 4 vCPU / 8 GB RAM 起步
2. 如果要跑 make verify、构建镜像、调试和测试，建议 8 vCPU / 16 GB RAM

## 二、系统依赖与基础工具

### 1. 安装基础包

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  ca-certificates \
  curl \
  git \
  jq \
  unzip \
  wget
```

### 2. 安装 Go

建议使用仓库当前已经验证过的较新 Go 版本。你也可以沿用你现有环境里的 Go，只要能通过 make test 和 make verify 即可。

安装后确认：

```bash
go version
```

确保 Go bin 在 PATH 中：

```bash
echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.bashrc
source ~/.bashrc
```

### 3. 安装容器与 Kubernetes 工具

至少需要：

1. Docker
2. Azure CLI
3. kubectl
4. Helm
5. yq
6. skaffold

如果你只走 ko publish + helm upgrade 路线，skaffold 不是必需。

### 4. 安装仓库工具链

在 Ubuntu 22.04 上，这个仓库的 toolchain 脚本是可用的，因为它依赖 apt-get 安装交叉编译器。

```bash
cd /path/to/karpenter-provider-azure
PATH="$HOME/go/bin:$PATH" make toolchain
```

这一步会安装 controller-gen、ko、ginkgo、yq、crane、cosign、trivy 等工具。

## 三、获取代码并做本地验证

```bash
git clone <your-fork-or-upstream>
cd karpenter-provider-azure
git checkout <your-branch-or-commit>
```

先跑测试：

```bash
PATH="$HOME/go/bin:$PATH" make test
```

再跑校验：

```bash
PATH="$HOME/go/bin:$PATH" make verify
```

如果这两步都通过，说明你的 Ubuntu 构建环境已经基本正常。

## 四、编译控制器二进制

### 1. 编译标准 self-hosted controller

最直接的方式是使用 go build：

```bash
mkdir -p bin
GOFLAGS='-ldflags=-X=sigs.k8s.io/karpenter/pkg/operator.Version=dev' \
go build -o bin/karpenter-controller ./cmd/controller
```

验证：

```bash
file bin/karpenter-controller
./bin/karpenter-controller --help || true
```

### 2. 可选：编译 AKS 托管变体

这个仓库 release 流程里还会额外构建一个带 `ccp` tag 的变体，标签通常是 `-aks`。

如果你只是 self-hosted 部署，不需要它。

如果你确实想编：

```bash
mkdir -p bin
GOFLAGS='-ldflags=-X=sigs.k8s.io/karpenter/pkg/operator.Version=dev-aks -tags=ccp' \
go build -o bin/karpenter-controller-aks ./cmd/controller
```

## 五、构建并推送自定义镜像

推荐两种方式：

1. 最小可用路径：直接用 ko publish 推送 controller 镜像
2. 开发路径：用 skaffold build 和 skaffold run

如果你的目标是“稳定发布一个自定义镜像给 Helm 使用”，优先推荐 ko publish。

### 方案 A：使用 ko publish

#### 1. 登录 ACR

```bash
export AZURE_ACR_NAME=<your-acr-name>
export AZURE_ACR_REPO=${AZURE_ACR_NAME}.azurecr.io/karpenter

az login
az account set --subscription <your-subscription-id>
az acr login -n "${AZURE_ACR_NAME}"
```

#### 2. 推送镜像

```bash
export IMAGE_TAG=$(git rev-parse --short HEAD)

GOFLAGS='-ldflags=-X=sigs.k8s.io/karpenter/pkg/operator.Version='"${IMAGE_TAG}" \
KO_DOCKER_REPO="${AZURE_ACR_REPO}" \
PATH="$HOME/go/bin:$PATH" ko publish -B --sbom none -t "${IMAGE_TAG}" ./cmd/controller
```

这条命令会输出最终镜像引用，格式通常类似：

```text
<acr>.azurecr.io/karpenter/controller:<tag>@sha256:<digest>
```

你需要记住三项：

1. repository
2. tag
3. digest

#### 3. 获取 digest

如果没记住 ko 输出，可以再查一次：

```bash
crane digest "${AZURE_ACR_REPO}/controller:${IMAGE_TAG}"
```

### 方案 B：使用 skaffold build

这个仓库本身在 [skaffold.yaml](skaffold.yaml) 中已经定义了 controller 镜像构建与 Helm setValueTemplates 注入逻辑。

先配置默认仓库：

```bash
skaffold config set default-repo "${AZURE_ACR_REPO}"
```

然后构建：

```bash
az acr login -n "${AZURE_ACR_NAME}"
skaffold build
```

如果你已经按仓库的 Azure 开发流程配置好了环境变量，也可以直接使用：

```bash
PATH="$HOME/go/bin:$PATH" make az-build AZURE_ACR_NAME=${AZURE_ACR_NAME}
```

但对“独立发布自定义镜像”来说，ko publish 更直接，也更容易和 Helm 配合。

## 六、更新 Helm Chart 使用自定义 image

### 1. chart 中 image 相关字段

chart 的 image 配置在 [charts/karpenter/values.yaml](charts/karpenter/values.yaml) 中，关键字段是：

1. `controller.image.repository`
2. `controller.image.tag`
3. `controller.image.digest`

chart 模板在 [charts/karpenter/templates/_helpers.tpl](charts/karpenter/templates/_helpers.tpl) 中会优先拼接：

1. `repository:tag@digest`

如果你设置了 digest，最终部署会固定到精确镜像内容，而不是只依赖 tag。

### 2. 推荐做法：单独写 override values 文件

不要直接改 chart 默认值，建议写一个额外的覆盖文件，例如 `karpenter-values-custom-image.yaml`：

```yaml
controller:
  image:
    repository: <your-acr>.azurecr.io/karpenter/controller
    tag: <your-tag>
    digest: sha256:<your-digest>
```

例如：

```yaml
controller:
  image:
    repository: myacr.azurecr.io/karpenter/controller
    tag: ef1a3d9
    digest: sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 3. 如果你只想用 tag，不想锁 digest

也可以这样写：

```yaml
controller:
  image:
    repository: <your-acr>.azurecr.io/karpenter/controller
    tag: <your-tag>
    digest: ""
```

但生产环境更建议带 digest。

## 七、准备部署所需的基础 values

这个仓库推荐使用 `configure-values.sh` 基于 AKS 集群动态生成基础 values。

### 0. 先配置 Workload Identity（已有集群场景）

如果你的 AKS 集群是已有集群，建议先显式完成 Karpenter 的 Workload Identity 绑定，再生成 values。

仓库已提供脚本：

```bash
bash ./hack/deploy/configure-workload-identity.sh \
  "${CLUSTER_NAME}" \
  "${RG}" \
  "${KARPENTER_NAMESPACE}" \
  karpenter-sa \
  karpentermsi \
  KARPENTER_FID
```

脚本会完成以下动作：

1. 校验 AKS 是否开启 OIDC issuer 与 Workload Identity
2. 创建（或复用）用户分配托管身份 `karpentermsi`
3. 创建（或复用）`federated credential`
4. 创建并注解 ServiceAccount（`azure.workload.identity/client-id`）
5. 为节点资源组授予 Karpenter 所需角色

如果脚本提示集群未开启 Workload Identity，请先执行：

```bash
az aks update \
  --name "${CLUSTER_NAME}" \
  --resource-group "${RG}" \
  --enable-oidc-issuer \
  --enable-workload-identity
```

最小校验命令：

```bash
kubectl get sa karpenter-sa -n "${KARPENTER_NAMESPACE}" -o yaml | grep -E "azure.workload.identity/(client-id|tenant-id)"
az identity federated-credential list --identity-name karpentermsi --resource-group "${RG}" -o table
```

如果你已经有 AKS 集群，可以这样做：

```bash
export CLUSTER_NAME=<your-aks-cluster-name>
export RG=<your-aks-resource-group>
export KARPENTER_NAMESPACE=kube-system

./hack/deploy/configure-values.sh "${CLUSTER_NAME}" "${RG}" karpenter-sa karpentermsi
```

这会生成基础的 `karpenter-values.yaml`。

然后你再叠加自己的镜像覆盖文件。

## 八、部署到 AKS 集群

### 1. 使用本地 chart 部署自定义镜像

推荐直接从本地 chart 安装，这样你不需要先打包 OCI Helm chart。

```bash
helm upgrade --install karpenter ./charts/karpenter \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --values karpenter-values.yaml \
  --values karpenter-values-custom-image.yaml \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

### 2. 检查控制器是否成功使用自定义镜像

```bash
kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter
kubectl get deployment karpenter -n "${KARPENTER_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}'
```

你应该看到刚才推送的 ACR 仓库、tag 和 digest。

### 3. 查看日志

```bash
kubectl logs -f -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter -c controller
```

## 九、如果你想把 Helm Chart 也打包并推送到 OCI Registry

如果你不只是想部署，还想把 chart 也推到 OCI 仓库，可以参考仓库 release 逻辑。

核心步骤如下：

### 1. 更新 chart 中的 image 信息

```bash
yq e -i '.controller.image.repository = "<your-acr>.azurecr.io/karpenter/controller"' charts/karpenter/values.yaml
yq e -i '.controller.image.tag = "<your-tag>"' charts/karpenter/values.yaml
yq e -i '.controller.image.digest = "sha256:<your-digest>"' charts/karpenter/values.yaml
```

### 2. 更新 chart 版本

```bash
export CHART_VERSION=0.0.1-custom

yq e -i '.version = "'"${CHART_VERSION}"'"' charts/karpenter/Chart.yaml
yq e -i '.appVersion = "'"${CHART_VERSION}"'"' charts/karpenter/Chart.yaml
```

### 3. 打包并推送 chart

```bash
cd charts
helm dependency update karpenter
helm lint karpenter
helm package karpenter --version "${CHART_VERSION}"
helm push "karpenter-${CHART_VERSION}.tgz" "oci://<your-acr>.azurecr.io/karpenter"
cd ..
```

对于 self-hosted 开发来说，这一步通常不是必须的。本地 chart 直接安装更简单。

## 十、最终部署后的最小验证

### 1. 验证 controller 本身

```bash
kubectl get pods -n "${KARPENTER_NAMESPACE}"
kubectl get deployment karpenter -n "${KARPENTER_NAMESPACE}"
kubectl logs -n "${KARPENTER_NAMESPACE}" deployment/karpenter -c controller --tail=200
```

### 2. 创建 NodePool 和 AKSNodeClass

可以直接使用仓库示例，例如：

```bash
kubectl apply -f examples/v1/general-purpose.yaml
```

如果你要验证 GPU 功能，则建议使用你自己的 GPU NodePool 和 AKSNodeClass 配置。

### 3. 创建测试工作负载

仓库里已有一个简单的 inflate 工作负载：

```bash
kubectl apply -f examples/workloads/inflate.yaml
```

把副本数调大，触发扩容：

```bash
kubectl scale deployment inflate --replicas=20
```

### 4. 观察 Karpenter 是否创建节点

```bash
kubectl get nodepools
kubectl get aksnodeclasses
kubectl get nodeclaims
kubectl get nodes -o wide
kubectl logs -f -n "${KARPENTER_NAMESPACE}" deployment/karpenter -c controller
```

如果是 GPU 场景，再重点看：

```bash
kubectl describe nodeclaim <nodeclaim-name>
kubectl get nodes -L node.kubernetes.io/instance-type,kubernetes.azure.com/ebpf-dataplane
```

### 5. 验证自定义镜像确实在运行

```bash
kubectl get deployment karpenter -n "${KARPENTER_NAMESPACE}" -o yaml | grep -A2 'image:'
```

## 十一、建议的完整操作顺序

如果你的目标是“在 Ubuntu 22.04 上把当前改动编译、打镜像、部署到 AKS 做验证”，建议按下面顺序：

1. `make toolchain`
2. `make test`
3. `make verify`
4. `ko publish` 推送自定义 controller 镜像
5. 生成 `karpenter-values.yaml`
6. 新建 `karpenter-values-custom-image.yaml`
7. `helm upgrade --install` 从本地 chart 部署
8. `kubectl logs` 和 `kubectl get nodeclaims` 做冒烟验证
9. 应用示例 NodePool 与 workload 做功能测试

## 十二、常见问题

### 1. 为什么优先建议本地 chart，而不是先推 Helm OCI chart

因为你的主要目标通常是验证 controller 代码改动，而不是验证 chart 发布流程。直接用本地 chart 能减少变量。

### 2. 为什么建议同时使用 tag 和 digest

因为 tag 可读，digest 可精确锁定镜像内容。Helm 模板也已经支持这种组合格式。

### 3. skaffold 和 ko 怎么选

1. 想做快速开发迭代，用 skaffold
2. 想稳定发布一个自定义镜像给 Helm，用 ko publish

## 结论

在 Ubuntu 22.04 x86_64 下，这个仓库的完整闭环应当是可跑通的：

1. 用 Go 编译控制器二进制
2. 用 ko 或 skaffold 构建并推送镜像
3. 用 Helm 覆盖 `controller.image.repository/tag/digest`
4. 用本地 chart 部署到 AKS
5. 通过 NodePool、NodeClaim、controller logs 和测试 workload 验证功能

如果你的重点是验证本次 GPU 机型与驱动开关改动，最推荐的路径是：

1. Ubuntu 上先 `make test && make verify`
2. 再 `ko publish`
3. 最后用本地 chart + 自定义镜像覆盖部署到 AKS 验证