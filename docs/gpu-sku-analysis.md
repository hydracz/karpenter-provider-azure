# GPU SKU 接入与机型选择分析

## 目的

本文说明 karpenter-provider-azure 中新增 GPU SKU 的实现流程，并分析运行时如何识别 GPU 实例、如何使用价格信息，以及 Karpenter 最终如何在候选机型中做选择。

本文重点覆盖以下问题：

1. 新增一个 Azure GPU VM SKU 时，需要改哪些代码
2. provider 如何识别某个 SKU 是 GPU 机型
3. provider 如何拿到价格并附加到实例候选集
4. Karpenter 如何从候选集中选择最终机型

## 总体架构

在这个仓库里，GPU 机型支持并不是单独维护一套“GPU 实例列表 API”。实现方式是：

1. 先由 instancetype provider 拉取 Azure 全量 VM SKU 元数据
2. 再通过本仓库维护的 GPU 识别规则，判断哪些 SKU 属于 NVIDIA GPU 机型
3. 同时由 pricing provider 为这些 SKU 补充按地域区分的 on-demand 和 spot 价格
4. 最终由 cloudprovider 基于 NodePool 和 NodeClaim 的约束、offering 可用性、资源匹配情况筛选出候选实例类型
5. 候选实例类型及其价格会交给 Karpenter core，最终由 Karpenter 结合调度约束和价格做选择

因此，这个 provider 的职责更接近“构建候选集并打标签、补齐价格与可用性”，而不是在 provider 内部自己硬编码“选哪一台 GPU 机器最优”。

## 新增 GPU SKU 的代码流程

### 1. 在 GPU 支持清单中注册 SKU

文件：pkg/utils/supported-gpus.yaml

这是 GPU SKU 的基础数据源。每个 SKU 至少要描述：

1. GPU 厂商
2. 支持的操作系统范围

例如这次新增的 NC RTX PRO 6000 BSE v6 系列，就在这个文件中声明为 nvidia，并注明支持 ubuntu、windows。

这一步的意义是：

1. 让 provider 知道这个 SKU 是 GPU 机型
2. 让 image/instance type 过滤逻辑知道这个 GPU 机型支持哪些 OS family

如果只改运行时逻辑而不更新这个文件，新的 GPU SKU 往往不会被当成“受支持 GPU 机型”看待。

### 2. 在 GPU 驱动类型规则中注册 SKU

文件：pkg/utils/gpu.go

这个文件承载了几类 GPU 判断逻辑：

1. IsNvidiaEnabledSKU：判断某个 SKU 是否是 NVIDIA GPU 机型
2. GetGPUDriverVersion：返回默认驱动版本
3. GetGPUDriverType：返回驱动类型，通常是 cuda 或 grid
4. GetAKSGPUImageSHA：返回 AKS GPU 相关镜像 SHA 后缀
5. ConvergedGPUDriverSizes：标记哪些 SKU 走 converged/grid 类驱动逻辑

如果新增的 GPU SKU 需要走特殊驱动族，例如 grid 或 converged 驱动，那么除了 supported-gpus.yaml，还需要把 SKU 加到这里对应的集合中。

这次新增的 RTX PRO 6000 BSE v6 就被加入了 ConvergedGPUDriverSizes，因此运行时会将它判定为 grid 驱动类型，而不是默认的 cuda。

### 3. 补单元测试

文件：pkg/utils/gpu_test.go

新增 SKU 后，至少应覆盖三类测试：

1. 是否能识别为 NVIDIA GPU 机型
2. 驱动类型是否正确
3. 默认驱动版本或镜像 SHA 是否符合当前实现预期

这是最小回归保护。否则未来改动 GPU 识别逻辑时，新的 SKU 很容易被误伤。

## provider 运行时如何获取 GPU 实例

### 1. operator 启动时初始化 instancetype provider 与 pricing provider

文件：pkg/operator/operator.go

operator 启动时会构造：

1. pricingProvider
2. instanceTypeProvider
3. imageProvider

其中 instanceTypeProvider 会在控制器正式运行前先执行一次 UpdateInstanceTypes，这样 controller 启动后就已经有一份可用的实例类型缓存。

### 2. instancetype provider 维护全量可用实例类型

文件：pkg/providers/instancetype/instancetypes.go

DefaultProvider.List 并不是“实时去 Azure 查询一个 GPU 列表”，而是从缓存好的 instanceTypesInfo 中遍历所有 SKU，逐个构造 cloudprovider.InstanceType。

每个 InstanceType 会包含：

1. Name：例如 Standard_NC128ds_xl_RTXPRO6000BSE_v6
2. Requirements：实例类型标签和特征约束
3. Offerings：不同 zone 和 capacity type 的价格与可用性
4. Capacity：cpu、memory、gpu 等容量
5. Overhead：kube/system reserved 等开销

### 3. GPU 识别发生在 requirements 构建阶段

文件：pkg/providers/instancetype/instancetype.go

computeRequirements 会调用 setRequirementsGPU。这里的逻辑是：

1. 用 utils.IsNvidiaEnabledSKU(sku.GetName()) 判断 SKU 是否是 NVIDIA GPU 机型
2. 如果是，则写入 GPU 相关 labels

典型标签包括：

1. karpenter.azure.com/sku-gpu-manufacturer = nvidia
2. karpenter.azure.com/sku-gpu-name = Azure 返回的加速器类型
3. karpenter.azure.com/sku-gpu-count = GPU 数量

所以“如何获取 GPU 实例”的答案不是调用某个专门的 GPU API，而是：

1. 先把 Azure SKU 构造成通用 InstanceType
2. 再通过 GPU labels 和容量字段把 GPU 机型从全集中识别出来

## provider 如何判断价格

### 1. pricing provider 的价格来源

文件：pkg/providers/pricing/pricing.go

pricing.Provider 维护两份价格数据：

1. onDemandPrices
2. spotPrices

它的行为有两个层次：

1. 启动时先加载内置静态价格表，保证即使价格 API 不可用，也有一份近似的排序基线
2. 在 public cloud 中定期从 Azure 价格接口拉取最新价格并刷新缓存

如果某个 SKU 临时拿不到价格，还会回退到已知的静态价格数据或缺省映射，而不是直接让整个 provider 失效。

### 2. 价格是附着在 offering 上，而不是只挂在 instance type 上

文件：pkg/providers/instancetype/instancetypes.go

createOfferings 会按以下维度生成 offering：

1. zone
2. capacity type

因此同一个实例类型通常会生成多条 offering：

1. zone A + on-demand
2. zone A + spot
3. zone B + on-demand
4. zone B + spot

每条 offering 上都带有：

1. Price
2. Available
3. 对应的 requirements

其中 Available 还会结合 unavailableOfferings 缓存，把最近出现容量不足的组合先标记为不可用。

这意味着“价格判断”并不是只看 SKU 名称，而是“某个 SKU 在某个 zone、某个 capacity type 下的当前价格和可用性”。

## Karpenter 如何选择机型

### 1. provider 先返回候选集

文件：pkg/cloudprovider/cloudprovider.go

CloudProvider.resolveInstanceTypes 的逻辑是：

1. 从 instanceTypeProvider.List 取出当前 nodeClass 下所有可用 instance types
2. 用 NodeClaim 的 requirements 做兼容性过滤
3. 用 offering availability 过滤不可用候选
4. 用 resources.Fits 过滤掉资源不满足请求的候选

最终返回的是“满足约束的候选机型集合”，不是单个最终机型。

### 2. 最终选择由 Karpenter core 完成

在 provider 这一层，已经把每个候选实例的 requirements、price、availability 都准备好了。Karpenter core 在此基础上会进一步做容量类型、成本和调度相关决策。

从 provider 角度可以把规则理解为：

1. provider 负责把“哪些 GPU 机型能用”讲清楚
2. provider 负责把“这些 GPU 机型当前多少钱”讲清楚
3. Karpenter core 再从兼容集合中选择最终实例

因此，如果你希望选型结果可控，最有效的手段不是改 provider 内部逻辑，而是通过 NodePool 和 NodeClaim requirement 把候选集收窄。

## 实际上如何约束到 GPU 机型

常见的约束方式有三类：

### 1. 精确指定实例类型

适合你明确知道只要某一个 SKU，例如：

1. Standard_NC128ds_xl_RTXPRO6000BSE_v6

这种方式最直接，也最容易控制驱动、性能和成本边界。

### 2. 按 GPU 数量、厂商、架构、容量类型约束

适合你允许多个 GPU SKU 竞争，例如：

1. GPU 厂商必须是 nvidia
2. 需要至少 1 张 GPU
3. 只允许 spot
4. 只允许 amd64

这种方式会保留更多弹性，让 Karpenter 能结合价格和可用性自动选择。

### 3. 按 imageFamily 和其他节点特性约束

provider 在列举实例类型时还会额外过滤：

1. imageFamily 是否支持该 SKU
2. encryption at host 是否支持
3. localDNS 是否支持
4. artifact streaming 是否支持

也就是说，机型能否进入候选集，不仅由 GPU 本身决定，还受到操作系统镜像族和其他节点特性的联动影响。

## 新增 GPU SKU 的建议流程

如果后续还要再加新的 GPU 机型，建议按下面顺序操作：

1. 从 Azure 官方文档确认准确 SKU 名称
2. 在 pkg/utils/supported-gpus.yaml 注册 GPU 与 OS 支持矩阵
3. 在 pkg/utils/gpu.go 里补驱动类型、版本和特殊机型集合
4. 确认 image family 是否支持该 GPU 机型对应的 OS
5. 补充 pkg/utils/gpu_test.go 的识别与驱动类型测试
6. 如果驱动安装行为有变化，补 imagefamily 和 instance 层面的测试
7. 跑完整 test 和后续 verify

## 结论

在 karpenter-provider-azure 中，新增 GPU SKU 的核心不是“单点加一个名字”，而是同时补齐三层信息：

1. 这个 SKU 是不是 GPU，支持哪些 OS
2. 这个 SKU 用哪一类 GPU 驱动逻辑
3. 它在实例类型候选集里应该如何被打标签、定价和筛选

provider 本身负责把这些事实组织成可供调度决策使用的候选集；至于最终挑哪一种 GPU 机型，仍然是 Karpenter core 结合约束、可用性和价格来决定。