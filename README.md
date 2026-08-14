# verl + Ray + MindCluster 分布式训练部署指南（2 节点）

本文面向一个已经搭建好的 Kubernetes 集群（2 个昇腾 NPU 节点），说明如何基于 MindCluster 的设备管理和调度能力，使用 Ray 作为分布式调度层，运行 verl 的 GRPO 多机训练。

## 1. 结论摘要

- K8s 的主节点（control plane）与 verl/Ray 的主节点是两个完全不同的概念。K8s 控制面负责集群管理，Ray Head 负责训练集群调度，Ray Head Pod 通常跑在 K8s 的 worker 节点上。
- 2 个节点不等于“2 个相同的副本”。正确结构是 1 个 Ray Head Pod + (N-1) 个 Ray Worker Pod，这里就是 1 个 Head + 1 个 Worker。
- 所有 Pod 使用同一个 verl 镜像，角色通过容器启动命令区分，不通过镜像区分。
- 不要在训练时手动进入容器写代码、放数据。训练脚本用 ConfigMap 挂载，模型/数据/checkpoint 用共享存储 PVC 挂载。
- 不是 verl 主动向 K8s 申请资源，而是你先执行 `kubectl apply`，K8s 负责起 Pod，Ray 负责组集群，Head 容器检测到集群就绪后自动执行训练脚本。

## 2. 架构

```text
你（kubectl apply）
        |
        v
K8s API Server  <---> Volcano 调度器（MindCluster）
        |
        +----------------------+
        |                      |
   ray-head Pod            ray-worker Pod (NNODES - 1)
   （1 个，8 NPU）          （每个 8 NPU）
        |                      |
   ray start --head       ray start --address=ray-head:6766
   ray status 循环等待
        |
   bash /workspace/run_grpo.sh
        |
   verl -> Ray -> vLLM/FSDP2 -> HCCL
```

所有 Pod 都挂载同一份 NFS 共享存储，模型、数据、checkpoint 路径在所有节点一致。

## 3. 文件清单

| 文件 | 用途 | 需要修改 |
| --- | --- | --- |
| `00-namespace.yaml` | 创建 `verl` 命名空间 | 一般不用 |
| `01-storage.yaml` | NFS PV/PVC，挂载模型和数据 | NFS server、path、容量 |
| `02-configmap.yaml` | 挂载 `run_grpo.sh` 训练脚本 | 模型、数据、训练参数 |
| `03-ray-head.yaml` | Ray Head Service + Deployment，Head 同时作为计算节点并触发训练 | 镜像、NNODES、NPU 资源名、网卡 |
| `04-ray-worker.yaml` | Ray Worker Deployment，副本数 = NNODES-1 | 镜像、副本数、NPU 资源名、网卡 |

## 4. 前置条件

1. Kubernetes 集群已就绪，两个节点都能被 `kubectl get nodes` 看到。
2. MindCluster 组件已安装：NodeD、Ascend Device Plugin、Ascend Docker Runtime、Volcano、ClusterD、Ascend Operator。安装步骤以官方 `quick_start` 为准。
3. 两个节点都能用 `npu-smi info` 识别 NPU，且每个节点有 8 张 NPU（按你的 `NPUS_PER_NODE` 调整）。
4. 有 NFS 或同类 ReadWriteMany 共享存储，模型、数据、checkpoint 的目录已经准备好。
5. 有包含 verl、Ray、torch_npu、CANN 的镜像，且与节点驱动版本配套。
6. 你的管理机上已配置好访问集群的 `kubeconfig`。

## 5. 部署步骤

### 5.1 确认 MindCluster 已就绪

在管理机上执行：

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -E "noded|device-plugin|clusterd|volcano|ascend-operator"
kubectl describe node <node-a> | grep -i ascend
kubectl describe node <node-b> | grep -i ascend
```

`kubectl describe node` 的输出里应能看到类似 `huawei.com/Ascend910: 8` 的可分配资源。资源名以你集群实际显示为准，后面 YAML 里要使用同一个名字。

### 5.2 准备 NFS 共享存储

在 NFS 服务器上创建目录：

```bash
mkdir -p /data/nfs/models
mkdir -p /data/nfs/data
mkdir -p /data/nfs/checkpoints
```

把模型文件放到 `/data/nfs/models/Qwen/Qwen3-0.6B`，数据集放到 `/data/nfs/data/gsm8k/`。确认 NFS 导出配置允许两个节点读写。

### 5.3 确认 verl 镜像

镜像必须同时包含：

- verl
- Ray
- torch_npu
- CANN 运行环境
- bash、python3

可以先手动起一个测试 Pod，确认镜像内 `npu-smi info` 和版本可用，再进入正式部署。

### 5.4 修改 YAML

需要修改的地方：

- `01-storage.yaml`：NFS `server`、`path`、容量。
- `02-configmap.yaml`：`run_grpo.sh` 里的模型 ID、数据路径、训练超参。
- `03-ray-head.yaml` 和 `04-ray-worker.yaml`：
  - `image` 换成你的 verl 镜像
  - `NNODES=2`、`NPUS_PER_NODE=8`
  - `huawei.com/Ascend910` 换成实际资源名
  - `HCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME` 换成实际网卡名
  - 如果希望 Pod 固定到指定节点，取消 `nodeSelector` 注释并填节点名

### 5.5 应用 YAML

在管理机上执行：

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-storage.yaml
kubectl apply -f 02-configmap.yaml
kubectl apply -f 03-ray-head.yaml
kubectl apply -f 04-ray-worker.yaml
```

### 5.6 查看部署状态

```bash
kubectl -n verl get pod -o wide
kubectl -n verl logs -f deploy/ray-head
```

预期过程：

1. `ray-head` Pod 启动，执行 `ray start --head`。
2. `ray-worker` Pod 启动，向 `ray-head:6766` 注册。
3. Head 里的循环检测到集群 NPU 总数为 16（2 节点 x 8），开始执行 `run_grpo.sh`。
4. verl 通过 Ray 拉起训练，日志里出现 verl、vLLM、HCCL 相关输出。

### 5.7 监控 Ray Dashboard

```bash
kubectl -n verl port-forward svc/ray-head 8260:8260
```

浏览器访问 `http://localhost:8260`。

## 6. 常见问题

### Pod 一直 Pending

```bash
kubectl -n verl describe pod <pod>
```

常见原因：

- `schedulerName: volcano` 未生效或 Volcano 未安装
- NPU 资源名写错，节点上没有该资源
- 节点 NPU 已被其他任务占用
- 节点缺少 MindCluster 标签（按官方安装文档打标签）

### 容器启动但训练没开始

```bash
kubectl -n verl logs deploy/ray-head
kubectl -n verl exec deploy/ray-head -- ray status
```

确认 `ray status` 里 NPU 总量是否是 `16.0`。如果一直是 `8.0`，说明 worker 没有注册成功，检查 worker 日志和 `ray-head` Service。

### HCCL 通信失败

检查：

- `HCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME` 是否是训练网卡
- 防火墙是否放行 `6766`、`8260`、`60000-60050`、`61000-61050`
- 不要手动设置 `ASCEND_RT_VISIBLE_DEVICES`，由 MindCluster 设备插件注入

## 7. 为什么不直接“提交 2 个副本”

如果只提交一个 Deployment 并设置 `replicas: 2`，会产生两个行为完全相同的 worker Pod，没有 Ray Head，集群无法组起来。必须区分角色：

- Head 容器的启动命令：`ray start --head` + 等待节点 + 执行训练
- Worker 容器的启动命令：`ray start --address=ray-head:6766` + 挂起等待

## 8. 可选：MindCluster 原生 AscendJob

MindCluster 还提供 `AscendJob` CRD，适合 torchrun/MASTER_ADDR 这类传统分布式训练方式，它会自动注入 ranktable 环境变量并生成 hccl.json。verl 依赖 Ray，因此本文采用“普通 Deployment + Ray”的方式。如果你后续希望使用 AscendJob，可参考官方 `basic_scheduling` 文档，把 `run_grpo.sh` 里的 Ray 启动逻辑替换为直接启动 verl，但 verl 内部仍需要 Ray 集群，所以一般建议保留本方案。

## 9. 参考资料

- MindCluster 仓库：https://gitcode.com/Ascend/mind-cluster
- MindCluster 快速入门：https://www.hiascend.com/document/detail/zh/mindcluster/70rc1/description/index/index.html
