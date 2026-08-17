# verl + Ray + MindCluster 

在两台已经装好 Kubernetes 和 MindCluster 的节点上，不使用 NFS，用宿主机本地目录把 verl GRPO 多机训练跑起来。

训练启动脚本基于已经单机验证过的脚本，只增加了一行 checkpoint 输出目录；训练代码使用 verl 镜像自带的框架代码和示例（`verl.trainer.main_ppo`）

## 0. 核心概念

### 0.1 K8s 主节点和 Ray/verl 主节点不一定相同

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

本教程中容器启动只负责把 Ray 集群组起来，**不会自动启动训练**。训练脚本在进入容器后手动执行。

### 0.4 原始数据和预处理数据要分开

GSM8K 原始 HuggingFace 数据集需要先转换成 verl 要的 parquet 格式，所以容器里有两个数据目录：

- `/workspace/hf_data`：原始 HF 数据（对应宿主机 `/home/hf_data`）
- `/root/data`：预处理后的 parquet（对应宿主机 `/home/data`）

训练脚本读取的是预处理后的目录：

```text
TRAIN_FILE=$HOME/data/gsm8k/train.parquet
TEST_FILE=$HOME/data/gsm8k/test.parquet
```

## 1. 目录规划：宿主机放什么，挂载到哪里

| 宿主机目录（两台节点） | 容器内路径 | 放什么 |
| --- | --- | --- |
| `/home/models` | `/root/models` | 模型文件 |
| `/home/hf_data` | `/workspace/hf_data` | 原始 HuggingFace 数据集 |
| `/home/data` | `/root/data` | 预处理后的 parquet |
| `/home/scripts` | `/workspace` | 启动脚本 |
| `/home/checkpoints` | `/root/checkpoints` | 训练结果（checkpoint） |

容器里 `HOME=/root`，所以：

```text
~            = /root
~/models     = /root/models
~/hf_data    = /workspace/hf_data
~/data       = /root/data
~/checkpoints = /root/checkpoints
```

启动脚本放在容器里的 `/workspace`。Head 容器启动只负责起 Ray 集群，不自动训练；训练由你手动执行：

```text
bash /workspace/run_grpo.sh
```

## 2. 环境清单

| 项目 | 说明 |
| --- | --- |
| 两台 K8s 节点 | 本文叫 node-a、node-b，每台 8 张 NPU |
| MindCluster 组件 | NodeD、Device Plugin、Ascend Runtime、Volcano、ClusterD、Ascend Operator |
| verl 镜像 | 包含 verl、Ray、torch_npu、CANN、bash |
| 模型和数据 | Qwen3-0.6B 模型、GSM8K 原始 HF 数据 |
| 管理机 | 装有 `kubectl` 的电脑 |

## 3. 检查集群

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

## 4. 在两台节点上创建目录

在 **node-a 和 node-b** 上都执行：

```bash
sudo mkdir -p /home/models
sudo mkdir -p /home/hf_data
sudo mkdir -p /home/data
sudo mkdir -p /home/scripts
sudo mkdir -p /home/checkpoints
sudo chown -R $USER:$USER /home/models /home/hf_data /home/data /home/scripts /home/checkpoints
```

验证：

```bash
ls -ld /home/models /home/hf_data /home/data /home/scripts /home/checkpoints
```

## 5. 把模型和原始数据复制到两台节点

因为没有共享存储，**两台节点都必须有一份**，路径必须相同。

在管理机或数据源机器上执行：

```bash
rsync -av /你的模型目录/Qwen3-0.6B/ node-a:/home/models/Qwen/Qwen3-0.6B/
rsync -av /你的模型目录/Qwen3-0.6B/ node-b:/home/models/Qwen/Qwen3-0.6B/

rsync -av /你的GSM8K原始数据目录/ node-a:/home/hf_data/gsm8k/
rsync -av /你的GSM8K原始数据目录/ node-b:/home/hf_data/gsm8k/
```

验证：

```bash
ls /home/models/Qwen/Qwen3-0.6B
ls /home/hf_data/gsm8k
```

注意：`/home/data` 现在保持为空，等预处理后放 parquet。

## 6. 准备启动脚本

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

`NNODES` 默认 1 是单机；多机部署时 YAML 里会注入 `NNODES=2`，脚本会读取环境变量。其余路径对应上一节的挂载关系，一般不用改。

验证脚本语法（可选）：

```bash
bash -n /home/scripts/run_grpo.sh
```

## 7. 修改 YAML

### 7.1 `ray-head.yaml`

需要确认/修改 5 类内容：

| 内容 | 说明 |
| --- | --- |
| `image` | 换成你的 verl 镜像 |
| `kubernetes.io/hostname` | 换成 node-a 的真实节点名 |
| hostPath 路径 | 默认 `/home/models`、`/home/hf_data`、`/home/data`、`/home/scripts`、`/home/checkpoints`，目录一致就不用改 |
| `huawei.com/Ascend910` | 换成 `kubectl describe node` 显示的真实 NPU 资源名 |
| `HCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME` | 换成真实训练网卡名 |

查看 NPU 资源名：

```bash
kubectl describe node node-a | grep -i ascend
```

查看网卡名（在 node-a 或 node-b 上执行）：

```bash
ip -o -4 addr show scope global | awk '{print $2, $4}'
ip route get <另一台节点的 IP>
```

`ip route get` 输出里的 `dev` 后面就是通信网卡名。`tunl0`、`docker0` 这类虚拟网卡不能用。

### 7.2 `ray-worker.yaml`

同样确认/修改：镜像、node-b 节点名、hostPath 路径（只有 `/home/models`、`/home/hf_data`、`/home/data`）、NPU 资源名、网卡名。

Worker 不需要挂载 scripts 和 checkpoints。

## 8. 部署并验证

以下命令都在**管理机**上执行，按顺序来。

### 8.1 创建命名空间

```bash
kubectl apply -f namespace.yaml
kubectl get namespace verl
```

### 8.2 先启动 Ray Head

```bash
kubectl apply -f ray-head.yaml
kubectl -n verl get pod -o wide
kubectl -n verl get pod -w
```

等 `ray-head-...` 变成 `Running`。

看日志确认 Ray Head 正常：

```bash
kubectl -n verl logs deploy/ray-head
```

应看到：

```text
+ ray start --head --port 6766 ...
Ray runtime started.
```

### 8.3 在 Head 容器里预处理数据

进入 Head 容器：

```bash
kubectl -n verl exec -it deploy/ray-head -- bash
```

在 `/verl` 下执行预处理：

```bash
cd /verl
python3 examples/data_preprocess/gsm8k.py --local_dataset_path /workspace/hf_data/gsm8k
```

确认 parquet 生成在 `/root/data/gsm8k`：

```bash
ls -l /root/data/gsm8k/train.parquet /root/data/gsm8k/test.parquet
```

如果脚本生成的 parquet 在其他位置，用 `find /verl -name "*.parquet"` 找到后复制到 `/root/data/gsm8k/`。

退出容器：

```bash
exit
```

因为 `/root/data` 对应宿主机 `/home/data`，所以 parquet 已落在 node-a 的 `/home/data/gsm8k`。

在node-b执行相同处理逻辑

### 8.4 启动 Ray Worker

```bash
kubectl apply -f ray-worker.yaml
kubectl -n verl get pod -o wide
```

看到 head 和 worker 分别在 node-a、node-b 上运行。

### 8.5 确认集群就绪

```bash
kubectl -n verl logs -f deploy/ray-head
```

出现：

```text
Ray cluster ready: 2 nodes, 16 NPU
```

### 8.5 手动启动训练

集群就绪后，进入 Head 容器手动执行训练脚本：

```bash
kubectl -n verl exec -it deploy/ray-head -- bash
```

容器里执行：

```bash
bash /workspace/run_grpo.sh
```

训练输出会直接显示在当前终端，保持这个终端不要关闭。

## 9. 查看训练结果

### 9.1 日志

```bash
kubectl -n verl logs -f deploy/ray-head
```

### 9.2 Ray Dashboard

```bash
kubectl -n verl port-forward svc/ray-head 8260:8260
```

浏览器打开 `http://localhost:8260`。

### 9.3 Checkpoint

```text
容器内：/root/checkpoints/<实验名>/
宿主机：/home/checkpoints/<实验名>/
```

```bash
ls /home/checkpoints/
ls /home/checkpoints/<实验名>/
```

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
| 宿主机目录 | `/home/models`、`/home/hf_data`、`/home/data` 等 | `03`、`04` YAML 的 hostPath |

修改目录的规则：**宿主机路径、YAML hostPath、容器挂载路径、run_grpo.sh 里的路径，四处必须对应上**。

## 11. ConfigMap 是什么，为什么这里不用

ConfigMap 是 K8s 用来保存配置文件的资源，可以挂载成容器里的文件。本教程选择更直观的本地存储方案：**脚本直接放在宿主机 `/home/scripts`，用 hostPath 挂到容器 `/workspace`**，在宿主机上改脚本，重启 Pod 就能生效。

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

检查 worker 是否用 `--address=51.38.67.149:6766` 这类直连地址，`ray-head` Service 是否存在。

### 找不到 train.parquet

```bash
ls /home/data/gsm8k/train.parquet
ls /home/data/gsm8k/test.parquet
```

如果不存在，说明还没执行预处理，按 8.3 节在 Head 容器里执行 `gsm8k.py`。

### 找不到模型或原始数据

```bash
ls /home/models/Qwen/Qwen3-0.6B
ls /home/hf_data/gsm8k
```

两台节点路径必须一致。

### HCCL 通信失败

检查 `HCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME`、防火墙端口 `6766`、`8260`、`60000-60050`、`61000-61050`，不要手动设置 `ASCEND_RT_VISIBLE_DEVICES`。

## 14. 本地存储注意事项

- 改模型或原始数据后，要重新同步到两台节点。
- 每次重新生成 parquet 后，也要同步 `/home/data` 到两台节点。
- checkpoint 写在 Head 节点（node-a）本地盘，重装或换机器前先备份。
- 跑通以后想省去手动同步，再升级到 NFS 或 CephFS。
