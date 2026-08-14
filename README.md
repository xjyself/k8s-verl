# verl + Ray + MindCluster 入门教程（本地存储版）

这个教程面向第一次搭昇腾多机训练环境的人。目标是：在两台已经装好 Kubernetes 和 MindCluster 的节点上，用本地磁盘（不使用 NFS）把 verl GRPO 多机训练跑起来。

## 0. 先了解三件事

### 0.1 K8s 主节点和 verl 主节点不是一回事

- K8s 主节点（control plane）负责管理整个集群，比如接受 `kubectl apply`、调度 Pod。
- verl 自己不管节点，verl 依赖 Ray。Ray 有 Head（调度）和 Worker（执行）两种角色。
- Ray Head 是一个 Pod，跑在某台 K8s 节点上；这台 K8s 节点不一定是 K8s 控制面节点。

### 0.2 没有 NFS 也能跑

verl 本身不强制要求 NFS。它要求的是：**每个训练进程都能通过同一个绝对路径读到模型和数据**。

没有共享存储时，做法是：

- 把模型和数据复制到每一台节点上，路径保持一致，例如都是 `/data/verl/models/...` 和 `/data/verl/data/...`。
- 每个 Pod 用 `hostPath` 挂载本机目录。
- 用 `nodeSelector` 把 Head Pod 固定到 node-a，Worker Pod 固定到 node-b。

代价是：改模型或数据要手动同步到每台机器；checkpoint 默认主要写在其中一台的本地盘。

### 0.3 容器启动命令是自动执行的

YAML 里的 `command` / `args` 在容器启动时自动执行，不需要手动进入容器。`kubectl exec` 只是排障时另开一个 shell。

## 1. 环境清单

开始之前确认你有：

| 项目 | 说明 |
| --- | --- |
| 两台 K8s 节点 | 本文叫 node-a、node-b，每台 8 张 NPU |
| MindCluster 组件 | NodeD、Device Plugin、Ascend Runtime、Volcano、ClusterD、Ascend Operator |
| verl 镜像 | 镜像内包含 verl、Ray、torch_npu、CANN、bash |
| 模型和数据 | Qwen3-0.6B 模型、GSM8K 训练/测试 parquet |
| 管理机 | 装了 `kubectl` 且能访问集群的电脑 |

## 2. 第 0 步：检查集群

以下命令都在**管理机**上执行。

查看节点：

```bash
kubectl get nodes -o wide
```

记下两台节点的名字，本文示例叫 `node-a` 和 `node-b`。

查看每台节点有多少 NPU：

```bash
kubectl describe node node-a | grep -i ascend
kubectl describe node node-b | grep -i ascend
```

正常应看到类似：

```text
huawei.com/Ascend910:  8
huawei.com/Ascend910:  8
```

**记下资源名**，例如 `huawei.com/Ascend910`。后面 YAML 里要完全一致，以你集群实际显示为准。

确认 MindCluster 组件在运行：

```bash
kubectl get pods -A | grep -E "noded|device-plugin|clusterd|volcano|ascend-operator"
```

## 3. 第 1 步：在两台节点上准备本地目录

以下命令在两台节点上都执行。

创建目录：

```bash
sudo mkdir -p /data/verl/models/Qwen/Qwen3-0.6B
sudo mkdir -p /data/verl/data/gsm8k
```

验证：

```bash
ls -ld /data/verl/models /data/verl/data
```

## 4. 第 2 步：把模型和数据复制到两台节点

因为每台节点都是本地盘，**两台节点都必须有一份**，路径必须相同。

在管理机或数据源机器上执行：

```bash
rsync -av /你的模型目录/Qwen3-0.6B/ node-a:/data/verl/models/Qwen/Qwen3-0.6B/
rsync -av /你的模型目录/Qwen3-0.6B/ node-b:/data/verl/models/Qwen/Qwen3-0.6B/

rsync -av /你的数据集目录/gsm8k/ node-a:/data/verl/data/gsm8k/
rsync -av /你的数据集目录/gsm8k/ node-b:/data/verl/data/gsm8k/
```

验证两台节点：

```bash
ls /data/verl/models/Qwen/Qwen3-0.6B
ls /data/verl/data/gsm8k
```

## 5. 第 3 步：修改 4 个文件

文件都在本目录：

| 文件 | 你要改什么 |
| --- | --- |
| `00-namespace.yaml` | 不需要改 |
| `02-configmap.yaml` | 模型 ID、数据路径、训练超参 |
| `03-ray-head.yaml` | 镜像、node-a 名字、NPU 资源名、网卡名 |
| `04-ray-worker.yaml` | 镜像、node-b 名字、NPU 资源名、网卡名 |

### 5.1 `03-ray-head.yaml`

至少改这 4 处：

```yaml
image: your-verl-image:tag          # 改成你的 verl 镜像
nodeSelector:
  kubernetes.io/hostname: node-a     # 改成实际节点名
huawei.com/Ascend910: 8              # 改成实际资源名
HCCL_SOCKET_IFNAME: eth0             # 改成训练网卡名
```

### 5.2 `04-ray-worker.yaml`

同样改镜像、节点名（node-b）、资源名、网卡名。副本数保持 `replicas: 1`，因为 2 节点只需要 1 个 Worker。

### 5.3 `02-configmap.yaml`

默认已经写好 Qwen3-0.6B 和 GSM8K 路径。如果你的模型或数据不同，修改：

```bash
MODEL_ID
MODEL_PATH
TRAIN_FILE
TEST_FILE
```

## 6. 第 4 步：一步步部署并验证

以下命令都在**管理机**上执行，按顺序来，每步都验证成功再继续。

### 6.1 创建命名空间

```bash
kubectl apply -f 00-namespace.yaml
```

验证：

```bash
kubectl get namespace verl
```

看到 `verl` 且状态为 `Active` 就继续。

### 6.2 挂载训练脚本

```bash
kubectl apply -f 02-configmap.yaml
```

验证：

```bash
kubectl -n verl get configmap verl-scripts
```

### 6.3 启动 Ray Head

```bash
kubectl apply -f 03-ray-head.yaml
```

查看 Pod：

```bash
kubectl -n verl get pod -o wide
```

先等 `ray-head-...` 变成 `Running`：

```bash
kubectl -n verl get pod -w
```

查看 Head 日志：

```bash
kubectl -n verl logs deploy/ray-head
```

正常情况下你应该看到类似：

```text
+ ray start --head --port 6766 ...
Local node IP: ...
Ray runtime started.
```

如果一直 `Pending`，执行：

```bash
kubectl -n verl describe pod -l app=ray-head
```

最常见原因是 NPU 资源名写错，或者节点没有足够 NPU。

### 6.4 启动 Ray Worker

```bash
kubectl apply -f 04-ray-worker.yaml
```

查看两个 Pod：

```bash
kubectl -n verl get pod -o wide
```

应该看到 `ray-head-...` 和 `ray-worker-...` 都是 `Running`，且分别落在 node-a 和 node-b。

再看 Head 日志：

```bash
kubectl -n verl logs -f deploy/ray-head
```

当 Worker 注册成功后，日志里会出现：

```text
Ray cluster ready: 2 nodes, 16 NPU
```

然后 Head 会自动执行：

```text
+ bash /workspace/run_grpo.sh
```

### 6.5 确认训练开始

继续看日志，出现 verl 的加载模型、Ray actor 启动、vLLM 初始化等输出就说明训练跑起来了。

也可以进入容器确认 NPU 是否可用：

```bash
kubectl -n verl exec deploy/ray-head -- npu-smi info
kubectl -n verl exec deploy/ray-head -- ray status
```

`ray status` 里应看到：

```text
16.0/16.0 NPU
```

## 7. 第 5 步：查看 Ray Dashboard

在管理机执行：

```bash
kubectl -n verl port-forward svc/ray-head 8260:8260
```

然后浏览器打开：

```text
http://localhost:8260
```

可以看到集群状态、任务、日志。

## 8. 清理

停止训练并删除资源：

```bash
kubectl -n verl delete deploy ray-head ray-worker
kubectl -n verl delete svc ray-head
kubectl -n verl delete cm verl-scripts
kubectl -n verl delete ns verl
```

注意：`hostPath` 只是挂载，不会删除节点上的 `/data/verl` 目录，数据还在。

## 9. 常见问题

### Pod 一直 Pending

```bash
kubectl -n verl describe pod <pod名>
```

检查：

- `schedulerName: volcano` 是否存在
- NPU 资源名和节点 `allocatable` 是否一致
- `nodeSelector` 节点名是否写对
- 节点 NPU 是否被其他任务占用

### Worker 一直没加入

```bash
kubectl -n verl logs deploy/ray-worker
kubectl -n verl logs deploy/ray-head
```

检查：

- Head 日志里是否显示 `ray start --head` 成功
- Worker 是否用 `--address=ray-head:6766`
- `ray-head` Service 是否存在

### HCCL 通信失败

检查：

- `HCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME` 是不是训练网卡
- 防火墙是否放行 `6766`、`8260`、`60000-60050`、`61000-61050`
- 不要手动设置 `ASCEND_RT_VISIBLE_DEVICES`，设备插件会自动注入

### 训练报找不到模型或数据

检查两台节点：

```bash
ls /data/verl/models/Qwen/Qwen3-0.6B
ls /data/verl/data/gsm8k
```

两台节点路径必须完全一致，大小写也不能错。

## 10. 本地存储的注意事项

- 修改模型或数据后，要重新同步到两台节点。
- checkpoint 默认写在训练保存路径下，通常是 Head 所在节点的本地盘；重启或换节点前记得手动备份。
- 等跑通以后，如果想省去手动同步，再升级到 NFS 或 CephFS。
