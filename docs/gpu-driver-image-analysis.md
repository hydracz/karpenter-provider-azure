# GPU 驱动安装、镜像选择与 Azure VM Image 分析

## 目的

本文说明 karpenter-provider-azure 中 GPU 驱动安装相关逻辑是如何实现的，并分析以下几个核心问题：

1. provider 如何选择 Azure VM image
2. imageFamily 如何映射到 AKS 的 OS SKU 和 NodeImageVersion
3. provider 如何让 Azure 或 AKS 自动安装 GPU 驱动
4. 新增的 installGPUDrivers 开关是如何生效的

## 总体思路

从实现上看，这个仓库并不直接在 controller 里“下载驱动并安装”。它做的是把 GPU 驱动安装意图和必要的驱动参数传递给 AKS 节点创建链路。

当前主要有三条路径：

1. VM + scriptless bootstrap
2. VM + custom scripts bootstrapping client
3. AKS Machine API

这三条路径最终都会收到以下关键信号：

1. 这是不是 GPU 节点
2. 是否需要自动安装 GPU 驱动
3. 使用哪类 GPU 驱动，例如 grid 或 cuda
4. 驱动版本和相关镜像标识

## 一、Azure VM image 是如何选择的

### 1. 起点是 AKSNodeClass.imageFamily

文件：pkg/apis/v1beta1/aksnodeclass.go

当前支持的 image family 主要包括：

1. Ubuntu
2. Ubuntu2204
3. Ubuntu2404
4. AzureLinux

imageFamily 不是简单的展示字段，它会影响：

1. instance type 是否被视为兼容
2. 最终选择哪类社区镜像或共享镜像
3. AKS Machine API 中的 OSSKU
4. bootstrapping client 里上报给 AKS 的 OsSku

### 2. resolver 根据 imageFamily、Kubernetes 版本和 FIPS 选择具体 ImageFamily 实现

文件：pkg/providers/imagefamily/resolver.go

GetImageFamily 会综合这些输入：

1. imageFamily
2. FIPS 模式
3. Kubernetes 版本

例如：

1. AzureLinux 在较新 K8s 版本下会切到 AzureLinux3
2. 泛化的 Ubuntu 会根据版本默认落到 Ubuntu2204 或 Ubuntu2404
3. FIPS 模式会影响默认镜像候选集

### 3. 每个 ImageFamily 自己维护一组默认镜像定义

文件示例：

1. pkg/providers/imagefamily/ubuntu_2204.go
2. pkg/providers/imagefamily/azlinux3.go

每个 family 会通过 DefaultImages 返回一个有序列表。每项包含：

1. ImageDefinition
2. PublicGalleryURL 或 SIG 信息
3. Requirements，例如架构和 Hyper-V generation
4. Distro 字符串

这个顺序很重要，因为 image provider 是按优先顺序匹配镜像的。

### 4. image provider 将镜像定义解析成实际 ImageID

文件：pkg/providers/imagefamily/nodeimage.go

image provider 的职责是：

1. 获取指定 image family 当前可用的镜像版本
2. 生成最终的 image ID

根据配置不同，镜像可能来自：

1. SIG，Shared Image Gallery
2. CIG，Community Image Gallery

最终返回给上层的是 NodeImage 列表，每个 NodeImage 带有：

1. ID
2. Requirements

### 5. resolver 为当前节点解析最终 image ID

文件：pkg/providers/imagefamily/resolver.go

Resolve 中会做两件关键事情：

1. 调用 ResolveNodeImageFromNodeClass 选出当前 instance type 可用的 image ID
2. 再通过 mapToImageDistro 把 image ID 映射成 bootstrapping client 需要的 distro 字符串

这一步是“镜像选择”和“节点引导”之间的桥。

## 二、imageFamily 如何映射到 Azure 的 OS 选择

### 1. 对 VM + bootstrapping client 路径

文件：pkg/providers/imagefamily/customscriptsbootstrap/provisionclientbootstrap.go

bootstrapping client 中的 ProvisionProfile.OsSku 不是直接等于 imageFamily，而是归一化后的大类：

1. Ubuntu2004、Ubuntu2204、Ubuntu2404 都映射为 OSSKUUbuntu
2. AzureLinux2、AzureLinux3 都映射为 OSSKUAzureLinux

换句话说，bootstrapping client 传的是 AKS 可识别的大类 OS SKU，而具体 distro 细节由 imageDistro 补充。

### 2. 对 AKS Machine API 路径

文件：pkg/providers/instance/aksmachineinstancehelpers.go

AKS Machine API 会走 configureOSSKUAndFIPs。这里的映射更细：

1. Ubuntu2204 对应 OSSKUUbuntu2204
2. Ubuntu2404 对应 OSSKUUbuntu2404
3. AzureLinux 对应 OSSKUAzureLinux
4. 泛化 Ubuntu 会根据 Kubernetes 版本和 FIPS 状态再做默认化

同时，buildAKSMachineTemplate 还会把 imageID 转换成 NodeImageVersion，用于 AKS Machine 的 MachineProperties.NodeImageVersion。

也就是说，AKS Machine API 这条路径更偏向显式表达“这个节点具体要用哪个 AKS 节点镜像版本”。

## 三、GPU 驱动安装是如何实现的

### 1. installGPUDrivers 是入口开关

文件：pkg/apis/v1beta1/aksnodeclass.go

AKSNodeClass 新增了字段：

1. spec.installGPUDrivers

语义如下：

1. true：允许 Azure 或 AKS 自动安装 GPU 驱动
2. false：跳过自动安装，交给 GPU Operator 或其他外部机制手动安装

该字段默认值为 true，所以历史行为保持不变。

### 2. launch template 静态参数先把 GPU 信息集中起来

文件：pkg/providers/launchtemplate/launchtemplate.go

静态参数中会集中注入：

1. GPUNode
2. InstallGPUDrivers
3. GPUDriverVersion
4. GPUDriverType
5. GPUImageSHA

这些值主要来自：

1. instanceType.Name 是否属于 GPU SKU
2. pkg/utils/gpu.go 中的驱动识别逻辑
3. nodeClass.IsInstallGPUDrivers()

后续不同节点创建路径都从这批参数继续传递。

## 四、VM + scriptless bootstrap 路径如何让 Azure 安装 GPU 驱动

### 1. 逻辑入口

文件：pkg/providers/imagefamily/bootstrap/aksbootstrap.go

在 applyOptions 中，如果 a.GPUNode 为 true，则会设置：

1. GPUNode = true
2. ConfigGPUDriverIfNeeded = a.InstallGPUDrivers
3. GPUDriverVersion
4. GPUDriverType
5. GPUImageSHA

这里的关键点是：

1. 以前 GPU 节点会无条件设置 ConfigGPUDriverIfNeeded=true
2. 现在这个值改为由 installGPUDrivers 控制

### 2. 模板变量如何传递到节点

文件：pkg/providers/imagefamily/bootstrap/cse_cmd.sh.gtpl

bootstrap 模板会把以下变量写入节点上的环境变量：

1. GPU_NODE
2. CONFIG_GPU_DRIVER_IF_NEEDED
3. GPU_IMAGE_SHA
4. GPU_DRIVER_VERSION
5. GPU_DRIVER_TYPE

provider 在这里的职责只是把变量写进 CSE 模板。真正的驱动安装动作由 AKS 节点侧的引导脚本继续执行。

因此更准确的描述是：

1. karpenter-provider-azure 负责声明“这个 GPU 节点是否需要自动装驱动”
2. AKS 节点侧脚本根据这些变量决定是否执行驱动安装

### 3. 容器运行时如何配合 GPU

文件：pkg/providers/imagefamily/bootstrap/containerd.toml.gtpl

如果节点被识别为 GPUNode，则 containerd 默认 runtime 会切换到 nvidia-container-runtime。

这一步并不等于驱动已经装好了，但它确保节点在具备 NVIDIA 运行时和驱动之后，容器工作负载可以正确调用 GPU。

## 五、VM + bootstrapping client 路径如何让 Azure 安装 GPU 驱动

### 1. 逻辑入口

文件：pkg/providers/imagefamily/customscriptsbootstrap/provisionclientbootstrap.go

ConstructProvisionValues 在检测到 InstanceType 是 NVIDIA GPU SKU 后，会构造：

1. GpuProfile.DriverType
2. GpuProfile.InstallGPUDriver

其中：

1. DriverType 根据 utils.UseGridDrivers 决定是 GRID 还是 CUDA
2. InstallGPUDriver 直接取自 p.InstallGPUDrivers

### 2. 这条路径的含义

也就是说，在 bootstrapping client 模式下，provider 不是自己安装驱动，而是把 GPU 安装策略编码到 ProvisionValues.ProvisionProfile.GpuProfile 中，再交给 AKS 节点引导服务处理。

如果 installGPUDrivers=false，则 AKS 收到的语义就是：

1. 这是 GPU 节点
2. 但不要自动安装 GPU driver

## 六、AKS Machine API 路径如何让 Azure 安装 GPU 驱动

### 1. 逻辑入口

文件：pkg/providers/instance/aksmachineinstancehelpers.go

buildAKSMachineTemplate 会调用 configureGPUProfile。

configureGPUProfile 的规则是：

1. 如果实例类型不是 NVIDIA GPU，返回 nil
2. 如果是 NVIDIA GPU 且 installGPUDrivers=true，则设置 GPUDriverInstall
3. 如果是 NVIDIA GPU 且 installGPUDrivers=false，则设置 GPUDriverNone

### 2. 这条路径的效果

最终生成的 AKS Machine 模板中，MachineProperties.Hardware.GpuProfile.Driver 会明确写成：

1. Install
2. None

这条路径是三种模式里最明确的一种，因为安装策略直接进入了 AKS Machine API 的声明式模板。

## 七、为什么需要 installGPUDrivers 开关

对于某些新 GPU 机型，Azure 默认驱动不一定满足实际需求，常见原因包括：

1. 需要特定版本的 NVIDIA 驱动
2. 需要配合 GPU Operator 统一管理驱动生命周期
3. 需要与特定 CUDA 版本、容器栈、Fabric Manager 版本保持一致

如果 provider 无条件要求 Azure 自动装驱动，会带来两个问题：

1. 自动安装的版本可能不符合用户工作负载要求
2. 后续再由 GPU Operator 接管时，可能出现驱动冲突或重复安装

因此 installGPUDrivers 的设计目标是把“GPU 节点”和“自动装驱动”这两个概念解耦。

## 八、如何理解“让 Azure 安装 GPU driver”

在这个仓库里，这句话需要分三层理解：

1. provider 负责识别 GPU 节点并生成驱动安装配置
2. Azure 或 AKS 的节点创建链路读取这些配置
3. 真正的驱动安装动作发生在 AKS 节点初始化阶段，而不是 controller 进程本身

因此，provider 的实现重点不是驱动安装脚本细节，而是把正确的控制面意图传达给底层创建链路。

## 九、当前实现的实际结论

如果你使用默认行为：

1. GPU 节点会被识别为 GPUNode
2. provider 会传入默认驱动类型、版本和 GPU image SHA
3. Azure 或 AKS 节点初始化链路会尝试自动安装 GPU 驱动

如果你设置 spec.installGPUDrivers=false：

1. 节点仍然会被识别为 GPU 节点
2. containerd 仍会按 GPU 节点准备 NVIDIA runtime 配置
3. 但是自动安装 GPU 驱动的控制信号会被关闭
4. 驱动安装将由 GPU Operator 或其他外部机制接管

## 十、结论

karpenter-provider-azure 对 GPU 驱动安装的实现，本质上是“把 GPU 与驱动安装策略映射成 AKS 可理解的节点引导参数”。

在这套设计里：

1. imageFamily 决定镜像族和 OS 选择
2. image provider 和 resolver 负责把 family 解析成实际 Azure image
3. GPU 相关工具函数决定驱动类型、版本和镜像标识
4. installGPUDrivers 决定是否把自动装驱动的意图传给 Azure 或 AKS

因此，当你需要支持特殊 GPU 驱动版本时，最合理的方式不是去改 provider 里的默认驱动安装细节，而是：

1. 让 provider 正确识别该 GPU SKU
2. 通过 installGPUDrivers=false 关闭默认自动安装
3. 再通过 GPU Operator 或你自己的节点初始化机制安装目标驱动