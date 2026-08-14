# verl + Ray + MindCluster 学习笔记：主从容器启动与裸机脚本对比

## 1. 主节点与从节点容器有什么不一样

主节点和从节点容器使用**同一个 verl 镜像**，区别不在镜像，而在**角色和启动命令**：

| 项目 | 主节点（Ray Head） | 从节点（Ray Worker） |
| --- | --- | --- |
| Pod 数量 | 1 个 | `NNODES - 1` 个 |
| 落在哪台机器 | node-a | node-b |
| 启动后做什么 | 启动 Ray Head，等 Worker 加入 | 向 Head 注册，加入 Ray 集群 |
| 是否跑训练脚本 | 不自动跑，由用户手动执行 | 不跑训练脚本 |
| 挂载目录 | models、hf_data、data、scripts、checkpoints | models、hf_data、data |
| 是否需要脚本目录 | 需要，`/workspace/run_grpo.sh` | 不需要 |
| 存活方式 | `sleep infinity` | `sleep infinity` |

## 2. 主节点与从节点拉起时执行的命令有什么不一样

### 主节点（Head）容器启动命令

```bash
set -x
ulimit -n 32768
ray start --head --port 6766 \
  --dashboard-host=0.0.0.0 --dashboard-port=8260 \
  --node-ip-address=$POD_IP \
  --resources="{\"NPU\": 8}"

while true; do
  total_npu=$(ray status | grep -oP '(?<=/)\d+\.\d+(?=\s*NPU)' | head -n 1 | awk '{print int($1)}')
  nodes=$((total_npu / 8))
  if [ "$nodes" -ge 2 ]; then
    echo "Ray cluster ready: $nodes nodes, $total_npu NPU"
    break
  fi
  echo "Waiting for Ray nodes: $nodes / 2"
  sleep 5
done

echo "Run training manually with: bash /workspace/run_grpo.sh"
sleep infinity
```

做的事情：

1. 启动 Ray Head，监听 6766
2. 循环执行 `ray status`，等 NPU 总数达到 `NNODES x 8`
3. 集群就绪后打印提示
4. `sleep infinity` 保持容器存活，**不自动启动训练**

### 从节点（Worker）容器启动命令

```bash
set -x
ulimit -n 32768
ray start --address=$RAY_HEAD_ADDR \
  --node-ip-address=$POD_IP \
  --resources="{\"NPU\": 8}"

sleep infinity
```

`RAY_HEAD_ADDR` 通过环境变量配置，例如：

```text
ray-head:6766                 # Service DNS 方式
51.38.67.149:6766             # 直连 Head 节点 IP 方式
```

Worker 只做一件事：向 Head 注册，然后挂起等待 Ray 调度。

## 3. 主从是靠什么区分的

裸机脚本靠“当前节点 IP 是否等于 `MASTER_ADDR`”判断主从。

K8s 方案**不靠 IP 判断**，主从关系由 YAML 本身决定：

- `ray-head.yaml` 里的 Deployment 只有一个副本，容器命令是 `ray start --head`
- `ray-worker.yaml` 里的 Deployment 有 `NNODES - 1` 个副本，容器命令是 `ray start --address=...`
- 用 `nodeSelector` 把 Head 固定到 node-a，Worker 固定到 node-b

所以：

```text
YAML 定义角色
  -> K8s 把 Pod 放到对应节点
  -> 容器启动命令按角色执行
  -> Ray 组成集群
  -> verl 通过 Ray 调度训练
```

## 4. 容器拉起时自动执行的命令和脚本是什么

容器启动时自动执行的是 YAML 里的：

```yaml
command: ["/bin/bash", "-lc"]
args:
  - |
    ...ray start ...  # 自动执行
    ...等待节点...      # 自动执行
    sleep infinity    # 自动执行
```

自动执行的内容只包括：

- 启动 Ray Head 或 Worker
- Head 等待所有节点加入
- 保持容器存活

**不自动执行**训练脚本。训练脚本是：

```text
/workspace/run_grpo.sh
```

由用户在数据预处理完成后手动启动：

```bash
kubectl -n verl exec -it deploy/ray-head -- bash
bash /workspace/run_grpo.sh
```

`run_grpo.sh` 最终执行：

```bash
python3 -m verl.trainer.main_ppo ...
```

verl 的框架代码在镜像里，用户不需要写分布式训练代码。

## 5. 裸机分布式脚本与 MindCluster/K8s 脚本的差异

### 裸机脚本

```bash
pkill -9 python
ray stop --force
rm -rf /tmp/ray

DEFAULT_SH="./run_*.sh"
NNODES=2
NPUS_PER_NODE=16
MASTER_ADDR="IP FOR MASTER NODE"
SOCKET_IFNAME="Your SOCKET IFNAME"

CURRENT_IP=$(ifconfig $SOCKET_IFNAME | ...)

if [ "$MASTER_ADDR" = "$CURRENT_IP" ]; then
  ray start --head --port 6766 ...
  while true; do
    ... ray status 等待节点 ...
    bash $DEFAULT_SH
  done
else
  ray start --address="$MASTER_ADDR:6766" ...
fi

sleep 600
```

### 差异对比

| 项目 | 裸机脚本 | MindCluster/K8s 脚本 |
| --- | --- | --- |
| 角色判断 | `CURRENT_IP` 是否等于 `MASTER_ADDR` | YAML 定义角色，不判断 IP |
| 清理旧进程 | `pkill -9 python`、`ray stop --force`、`rm -rf /tmp/ray` | 不需要，Pod 是新的；宿主机残留时手动 `ray stop --force` |
| Head 启动 | `ray start --head --port 6766` | 同样 `ray start --head --port 6766`，但 IP 来自 `$POD_IP` |
| Worker 启动 | `ray start --address=$MASTER_ADDR:6766` | `ray start --address=$RAY_HEAD_ADDR`，可配 Service DNS 或直连 IP |
| 等待节点 | 循环 `ray status` 判断 `device_count == NNODES` | 相同逻辑，但跑在容器启动命令里 |
| 启动训练 | 节点齐了自动 `bash $DEFAULT_SH` | 节点齐了只打印提示，用户手动 `bash /workspace/run_grpo.sh` |
| 保活 | `sleep 600` | `sleep infinity` |
| 网络 | 直接使用宿主机网卡 | `hostNetwork: true`，同样直接用宿主机网卡 |
| 调度 | 用户自己在每台机器手动执行 | K8s + Volcano 自动把 Pod 放到对应节点 |
| 资源声明 | `--resources='{"NPU": 16}'` | YAML 里 `huawei.com/Ascend910: 8` |
| 数据同步 | 每台机器自己准备数据 | 仍然每台机器准备，但通过 hostPath 挂载 |

## 6. 启动执行链路对比

### 裸机方式

```text
用户手动在每台机器执行 ray_start.sh
  -> 本机判断主从
  -> 主节点起 Ray Head，从节点注册
  -> 主节点检测节点数
  -> 自动执行 run_*.sh
  -> verl 训练
```

### MindCluster/K8s 方式

```text
kubectl apply -f 03-ray-head.yaml
  -> Head Pod 起 Ray Head
  -> 等待 Worker

kubectl apply -f 04-ray-worker.yaml
  -> Worker Pod 注册到 Ray Head
  -> Head 检测到 2 个节点
  -> 打印 Ray cluster ready

用户进入 Head 容器：
  kubectl exec -it deploy/ray-head -- bash
  bash /workspace/run_grpo.sh
  -> verl 训练
```

## 7. 小结

1. 主从区分：裸机靠 IP，K8s 靠 YAML 角色。
2. 镜像相同：主从容器使用同一个 verl 镜像，只是启动命令不同。
3. 容器自动执行：只负责组 Ray 集群，不自动训练。
4. 训练启动：数据预处理后，用户手动执行 `bash /workspace/run_grpo.sh`。
5. verl 分布式逻辑：由 verl + Ray 自动完成，用户只提供模型、数据、配置和可选 reward 函数。
