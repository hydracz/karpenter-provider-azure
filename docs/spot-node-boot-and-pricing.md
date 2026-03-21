# AKS Karpenter 节点创建与 Spot 价格设置说明

本文档说明 Azure Karpenter Provider 在 VM 模式下的节点创建（开机）流程，以及 Spot Max Price 注解的设计与行为。

## 1. 节点创建（开机）主流程

以 `ProvisionModeBootstrappingClient` / `ProvisionModeAKSScriptless` 的 VM 路径为例，核心流程如下：

1. Karpenter 根据调度需求生成 NodeClaim。
2. Provider 基于 NodeClaim + NodePool 约束筛选可用实例类型与容量类型（Spot / On-Demand）。
3. 构建 Launch Template（镜像、标签、网络、kubelet 参数等）。
4. 创建 NIC（并绑定子网、负载均衡后端池、NSG 等）。
5. 创建 VM：
   - 设置 `Priority`（Spot 或 Regular）
   - 配置磁盘、网络、身份、OSProfile
   - Spot 时配置 `BillingProfile.MaxPrice`
6. VM 创建成功后根据模式附加扩展（CSE、AKS billing extension 等）。

## 2. Spot Max Price 注解

为了不引入新的 CRD 字段，使用 annotation 扩展能力：

- 注解键：`karpenter.azure.com/spot-max-price`
- 来源：NodeClaim annotations（通常由 NodePool template metadata 继承）
- 生效条件：仅当本次实际创建容量类型为 Spot 时生效

### 2.1 取值规则

- `-1`：表示按需价上限（Azure Spot 默认语义）
- `>= 0`：表示用户指定最高 Spot 单价
- 其他值：视为非法

### 2.2 默认行为

- 如果 Spot 节点未设置该注解，默认 `MaxPrice = -1`，与历史行为保持一致。

## 3. 混合计费模式（Spot + On-Demand）兼容性

一个 NodePool 可能因约束/回退策略在不同请求中混合创建 Spot 与 On-Demand 节点。

当前实现保证：

1. 当本次创建结果是 Spot：
   - 才读取并校验 `karpenter.azure.com/spot-max-price`
   - 才将其写入 `BillingProfile.MaxPrice`
2. 当本次创建结果是 On-Demand（或 Regular / RI 等非 Spot 语义）：
   - 完全忽略该注解
   - 不会因该注解存在或格式问题影响创建

这保证了同一 NodePool 混合计费场景仍可正常工作。

## 4. AKS Machine API 模式说明

在 `ProvisionModeAKSMachineAPI` 路径下，当前 provider 对 Spot max price 注解不生效。

- Spot 且设置了该注解：返回明确错误，避免用户误以为已生效。
- 非 Spot：不读取该注解，不影响创建。

## 5. 推荐配置方式

建议将注解配置在 NodePool 的模板元数据（会下传到 NodeClaim）：

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: mixed-capacity
spec:
  template:
    metadata:
      annotations:
        karpenter.azure.com/spot-max-price: "0.03"
```

说明：

- 上述配置不会强制所有节点都变成 Spot。
- 是否使用 Spot 仍由容量类型选择逻辑决定。
- 当最终落到 On-Demand/Regular 时，该注解会被忽略。
