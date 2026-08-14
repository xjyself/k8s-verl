# verl + Ray + MindCluster 入门教程（本地存储版）

这个教程面向第一次搭昇腾多机训练环境的人。目标是：在两台已经装好 Kubernetes 和 MindCluster 的节点上，不使用 NFS，用宿主机本地目录把 verl GRPO 多机训练跑起来。

本教程的训练启动脚本基于你已经单机验证过的脚本，只增加了一行 checkpoint 输出目录；训练代码使用 verl 镜像自带的框架代码和示例（`verl.trainer.main_ppo`），不需要你额外编写分布式训练代码。

## 0. 核心概念

### 0.1 K8s 主节点和 Ray/verl 主节点不是一回事

- K8s 主节点（control plane）负责集群管理。
- verl 依赖 Ray。Ray 有 Head（调度）和 Worker（执行）两种角色。
- Ray Head 是一个 Pod，跑在某台 K8s 节点上，不一定是 K8s 控制面节点。

### 0.2 没有 NFS 也能跑

verl 不强制要求 NFS，只要求“每个训练进程能用同一个绝对路径读到模型和数据”。没有共享存储时：

- 把模型和数据复制到两台节点，路径保持一致
- Pod 用 `hostPath` 挂载本机目录
- 用 `nodeSelector` 把 Head Pod 固定到 node-a，Worker Pod 固定到 node-b

### 0.3 容器启动命令自动执行

YAML 里的 `command` / `args` 在容器启动时自动执行。`kubectl exec` 只是排障时另开 shell。

### 0.4 训练代码在哪

verl 的框架代码和示例代码在 verl 镜像里，启动脚本只是调用它的入口：

```text
run_grpo.sh
  -> python3 -m verl.trainer.main_ppo
  -> verl 自带分布式训练逻辑
```

你不需要把训练代码放进宿主机。

## 1. 目录规划：宿主机放什么，挂载到哪里

宿主机固定使用以下 4 个目录：

| 宿主机目录（两台节点） | 容器内路径 | 放什么 |
| --- | --- | --- |
| `/home/models` | `/root/models` | 模型文件 |
| `/home/hf_data` | `/root/data` | 数据集 |
| `/home/scripts` | `/workspace` | 启动脚本 |
| `/home/checkpoints` | `/root/checkpoints` | 训练结果（checkpoint） |

容器里 `HOME=/root`，所以：

```text
~            = /root
~/models     = /root/models
~/data       = /root/data
~/checkpoints = /root/checkpoints
```

注意：宿主机数据目录叫 `/home/hf_data`，但挂载到容器后是 `/root/data`，因为启动脚本默认读：

```text
TRAIN_FILE=$HOME/data/gsm8k/train.parquet
TEST_FILE=$HOME/data/gsm8k/test.parquet
```

启动脚本放在容器里的 `/workspace`，Head 容器启动后自动执行：

```text
bash /workspace/run_grpo.sh
```

## 2. 环境清单

| 项目 | 说明 |
| --- | --- |
| 两台 K8s 节点 | 本文叫 node-a、node-b，每台 8 张 NPU |
| MindCluster 组件 | NodeD、Device Plugin、Ascend Runtime、Volcano、ClusterD、Ascend Operator |
| verl 镜像 | 包含 verl、Ray、torch_npu、CANN、bash |
| 模型和数据 | Qwen3-0.6B 模型、GSM8K parquet 数据 |
| 管理机 | 装有 `kubectl` 的电脑 |

## 3. 第 0 步：检查集群

以下命令都在**管理机**上执行。

```bash
kubectl get nodes -o wide
```

记下两台节点的名字，本文示例为 `node-a`、`node-b`。

查看 NPU 资源：

```bash
kubectl describe node node-a | grep -i ascend
kubectl describe node node-b | grep -i ascend
```

正常应看到：

```text
huawei.com/Ascend910:  8
huawei.com/Ascend910:  8
```

**记下 NPU 资源名**，后面 YAML 要完全一致。

确认 MindCluster 组件在运行：

```bash
kubectl get pods -A | grep -E "noded|device-plugin|clusterd|volcano|ascend-operator"
```

## 4. 第 1 步：在两台节点上创建目录

在 **node-a 和 node-b** 上都执行：

```bash
sudo mkdir -p /home/models
sudo mkdir -p /home/hf_data
sudo mkdir -p /home/scripts
sudo mkdir -p /home/checkpoints
sudo chown -R $USER:$USER /home/models /home/hf_data /home/scripts /home/checkpoints
```

验证：

```bash
ls -ld /home/models /home/hf_data /home/scripts /home/checkpoints
```

## 5. 第 2 步：把模型和数据复制到两台节点

因为没有共享存储，**两台节点都必须有一份**，路径必须相同。

在管理机或数据源机器上执行：

```bash
rsync -av /你的模型目录/Qwen3-0.6B/ node-a:/home/models/Qwen/Qwen3-0.6B/
rsync -av /你的模型目录/Qwen3-0.6B/ node-b:/home/models/Qwen/Qwen3-0.6B/

rsync -av /你的数据集目录/gsm8k/ node-a:/home/hf_data/gsm8k/
rsync -av /你的数据集目录/gsm8k/ node-b:/home/hf_data/gsm8k/
```

验证：

```bash
ls /home/models/Qwen/Qwen3-0.6B
ls /home/hf_data/gsm8k
```

## 6. 第 3 步：准备启动脚本

本目录提供模板：

```text
run_grpo.sh.example
```

把它复制到 **node-a** 的脚本目录：

```bash
scp run_grpo.sh.example node-a:/home/scripts/run_grpo.sh
```

然后编辑：

```bash
ssh node-a
vim /home/scripts/run_grpo.sh
```

脚本默认配置：

```bash
MODEL_ID=Qwen/Qwen3-0.6B
MODEL_PATH=$HOME/models/$MODEL_ID
NNODES=${NNODES:-1}
TRAIN_FILE=$HOME/data/gsm8k/train.parquet
TEST_FILE=$HOME/data/gsm8k/test.parquet
CHECKPOINT_DIR=$HOME/checkpoints/${EXPERIMENT_NAME}
```

`NNODES` 默认 1 是因为你单机跑过；多机部署时 YAML 里会注入 `NNODES=2`，脚本会读取环境变量。其余路径对应上一节的挂载关系，一般不用改。

验证脚本语法（可选）：

```bash
bash -n /home/scripts/run_grpo.sh
```

## 7. 第 4 步：修改 YAML

### 7.1 `03-ray-head.yaml`

需要改 4 处：

```yaml
image: your-verl-image:tag
kubernetes.io/hostname: node-a
/home/models
/home/hf_data
/home/scripts
/home/checkpoints
huawei.com/Ascend910: 8
HCCL_SOCKET_IFNAME: eth0
```

### 7.2 `04-ray-worker.yaml`

同样改：

```yaml
image: your-verl-image:tag
kubernetes.io/hostname: node-b
/home/models
/home/hf_data
huawei.com/Ascend910: 8
HCCL_SOCKET_IFNAME: eth0
```

Worker 不需要挂载 scripts 和 checkpoints。

## 8. 第 5 步：部署并逐步验证

以下命令都在**管理机**上执行，按顺序来。

### 8.1 创建命名空间

```bash
kubectl apply -f 00-namespace.yaml
kubectl get namespace verl
```

看到 `verl` 状态为 `Active` 再继续。

### 8.2 启动 Ray Head

```bash
kubectl apply -f 03-ray-head.yaml
kubectl -n verl get pod -o wide
kubectl -n verl get pod -w
```

等 `ray-head-...` 变成 `Running`。

看日志：

```bash
kubectl -n verl logs deploy/ray-head
```

正常应看到：

```text
+ ray start --head --port 6766 ...
Ray runtime started.
```

如果一直 `Pending`：

```bash
kubectl -n verl describe pod -l app=ray-head
```

### 8.3 启动 Ray Worker

```bash
kubectl apply -f 04-ray-worker.yaml
kubectl -n verl get pod -o wide
```

应该看到 head 和 worker 分别在 node-a、node-b 上运行。

再看 Head 日志：

```bash
kubectl -n verl logs -f deploy/ray-head
```

看到：

```text
Ray cluster ready: 2 nodes, 16 NPU
```

说明 Ray 集群组好了，Head 会自动执行：

```text
+ bash /workspace/run_grpo.sh
```

## 9. 第 6 步：查看训练结果

### 9.1 日志

```bash
kubectl -n verl logs -f deploy/ray-head
```

### 9.2 Ray Dashboard

```bash
kubectl -n verl port-forward svc/ray-head 8260:8260
```

浏览器打开 `http://localhost:8260`。

### 9.3 Checkpoint 和最终结果

启动脚本里已经显式设置：

```text
trainer.default_local_dir=${CHECKPOINT_DIR}
```

所以结果路径是：

```text
容器内：/root/checkpoints/<实验名>/
宿主机：/home/checkpoints/<实验名>/
```

在 node-a 上查看：

```bash
ls /home/checkpoints/
ls /home/checkpoints/<实验名>/
```

里面会包含模型权重、optimizer 状态、训练状态等。

## 10. 默认路径和可自定义项

| 参数 | 默认值 | 在哪改 |
| --- | --- | --- |
| `MODEL_ID` | `Qwen/Qwen3-0.6B` | `run_grpo.sh` |
| `MODEL_PATH` | `$HOME/models/$MODEL_ID` | `run_grpo.sh` |
| `TRAIN_FILE` | `$HOME/data/gsm8k/train.parquet` | `run_grpo.sh` |
| `TEST_FILE` | `$HOME/data/gsm8k/test.parquet` | `run_grpo.sh` |
| `CHECKPOINT_DIR` | `$HOME/checkpoints/$EXPERIMENT_NAME` | `run_grpo.sh` |
| `NNODES` | 脚本默认 1，YAML 注入 2 | YAML 和脚本 |
| `NPUS_PER_NODE` | `8` | YAML |
| 宿主机目录 | `/home/models`、`/home/hf_data` 等 | `03`、`04` YAML 的 hostPath |

修改目录的规则：**宿主机路径、YAML hostPath、容器挂载路径、run_grpo.sh 里的路径，四处必须对应上**。

## 11. ConfigMap 是什么，为什么这里不用

ConfigMap 是 K8s 用来保存配置文件的资源，可以挂载成容器里的文件，适合保存不随宿主机变化的配置。本教程选择更直观的本地存储方案：**脚本直接放在宿主机 `/home/scripts`，用 hostPath 挂到容器 `/workspace`**，这样在宿主机上改脚本，重启 Pod 就能生效。

## 12. 清理

```bash
kubectl -n verl delete deploy ray-head ray-worker
kubectl -n verl delete svc ray-head
kubectl -n verl delete ns verl
```

`hostPath` 不会删除宿主机目录，模型、数据、checkpoint 都还在。

## 13. 常见问题

### Pod 一直 Pending

```bash
kubectl -n verl describe pod <pod名>
```

检查 `schedulerName: volcano`、NPU 资源名、`nodeSelector` 节点名、节点 NPU 是否空闲。

### Worker 没加入

```bash
kubectl -n verl logs deploy/ray-worker
kubectl -n verl logs deploy/ray-head
```

检查 worker 是否用 `--address=ray-head:6766`，`ray-head` Service 是否存在。

### HCCL 通信失败

检查 `HCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME`、防火墙端口 `6766`、`8260`、`60000-60050`、`61000-61050`，不要手动设置 `ASCEND_RT_VISIBLE_DEVICES`。

### 找不到模型或数据

```bash
ls /home/models/Qwen/Qwen3-0.6B
ls /home/hf_data/gsm8k
```

两台节点路径必须一致。

### 找不到启动脚本

```bash
ls /home/scripts/run_grpo.sh
```

确认文件在 node-a 上，且 YAML 里 hostPath 写的是 `/home/scripts`。

## 14. 本地存储注意事项

- 改模型或数据后，要重新同步到两台节点。
- checkpoint 写在 Head 节点（node-a）本地盘，重装或换机器前先备份。
- 跑通以后想省去手动同步，再升级到 NFS 或 CephFS。
