# verl-all-in-one.yaml 使用文档

这个文件把原本的 `namespace.yaml`、`ray-head.yaml`、`ray-worker.yaml` 合并成一个 YAML，一个文件即可拉起整个 Ray 集群。

## 1. 文件里有什么

```text
Namespace   verl
Service     ray-head（Headless，提供 ray-0.ray-head DNS）
StatefulSet ray（replicas=2，ray-0 是 Head，ray-1 是 Worker）
```

## 2. 主从是怎么区分的

StatefulSet 会创建 `ray-0`、`ray-1` 两个 Pod，容器启动脚本判断：

```bash
if [ "$POD_NAME" = "ray-0" ]; then
    # 启动 Ray Head，等待所有 Worker 加入
else
    # 启动 Ray Worker，连接 ray-0.ray-head:6766
fi
```

所以：

- `ray-0` 永远是 Ray Head
- 其他 Pod 自动成为 Ray Worker
- 角色不依赖节点名，不依赖 IP

## 3. 节点是怎么被选择的

这个 YAML 没有 `nodeSelector`，调度是动态的：

1. 每个 Pod 申请 `huawei.com/Ascend910: 8`
2. Volcano 只选择有 8 张空闲 NPU 的节点
3. `podAntiAffinity` 保证 `ray-0` 和 `ray-1` 不在同一台节点
4. 两台节点各有 8 张 NPU，所以一个 Pod 落一台
5. 具体哪台由调度器决定，不用你写死

## 4. 部署前需要准备的宿主机目录

两台节点都要有：

```bash
sudo mkdir -p /home/models
sudo mkdir -p /home/hf_data
sudo mkdir -p /home/data
sudo mkdir -p /home/scripts
sudo mkdir -p /home/checkpoints
sudo chown -R $USER:$USER /home/models /home/hf_data /home/data /home/scripts /home/checkpoints
```

挂载关系：

| 宿主机 | 容器内 |
| --- | --- |
| `/home/models` | `/root/models` |
| `/home/hf_data` | `/workspace/hf_data` |
| `/home/data` | `/root/data` |
| `/home/scripts` | `/workspace` |
| `/home/checkpoints` | `/root/checkpoints` |

## 5. 需要修改/确认的地方

### 已填好的

- 镜像：`quay.io/ascend/verl:v0.8.0-cann9.0.0-torch_npu2.9.0.post2-910b-ubuntu22.04-py3.11-vllm`
- `HCCL_SOCKET_IFNAME`：`enp189s0f0`
- `GLOO_SOCKET_IFNAME`：`enp189s0f0`

### 需要确认的

| 位置 | 说明 |
| --- | --- |
| `replicas` | 节点数，2 节点保持 `2` |
| `NNODES` | 和 `replicas` 保持一致 |
| `NPUS_PER_NODE` | 每节点 NPU 数，当前 `8` |
| `huawei.com/Ascend910` | 以 `kubectl describe node` 显示为准 |
| `RAY_HEAD_ADDR` | 默认 `ray-0.ray-head:6766`；DNS 有问题时改成 Head 节点 IP |
| 宿主机路径 | `/home/models` 等，如果实际路径不同要改 |

## 6. 部署步骤

### 6.1 检查集群

```bash
kubectl get nodes -o wide
kubectl describe node node-a | grep -i ascend
```

### 6.2 准备模型、原始数据、脚本

模型复制到两台节点：

```bash
rsync -av /你的模型目录/Qwen3-0.6B/ node-a:/home/models/Qwen/Qwen3-0.6B/
rsync -av /你的模型目录/Qwen3-0.6B/ node-b:/home/models/Qwen/Qwen3-0.6B/
```

原始 GSM8K 数据复制到两台节点：

```bash
rsync -av /你的GSM8K原始数据目录/ node-a:/home/hf_data/gsm8k/
rsync -av /你的GSM8K原始数据目录/ node-b:/home/hf_data/gsm8k/
```

启动脚本复制到 node-a：

```bash
scp run_grpo.sh.example node-a:/home/scripts/run_grpo.sh
```

### 6.3 部署

如果之前用旧版 `ray-head.yaml` / `ray-worker.yaml` 部署过，需要先清理旧资源，否则 Service 会报：

```text
spec.clusterIPs[0]: Invalid value: []string{"None"}: may not change once set
```

先删除旧 Service 和旧 Deployment：

```bash
kubectl -n verl delete svc ray-head
kubectl -n verl delete deploy ray-head ray-worker
```

然后部署：

```bash
kubectl apply -f verl-all-in-one.yaml
kubectl -n verl get pod -o wide
```

正常会看到 `ray-0` 和 `ray-1` 分别在两台节点 Running。

### 6.4 预处理数据

```bash
kubectl -n verl exec -it deploy/ray-0 -- bash
```

StatefulSet 的 Deployment 名是 `ray`，也可以：

```bash
kubectl -n verl exec -it ray-0 -- bash
```

容器里：

```bash
cd /verl
python3 examples/data_preprocess/gsm8k.py --local_dataset_path /workspace/hf_data/gsm8k
ls -l /root/data/gsm8k/train.parquet /root/data/gsm8k/test.parquet
exit
```

### 6.5 同步预处理结果到 node-b

```bash
rsync -av /home/data/gsm8k/ node-b:/home/data/gsm8k/
```

### 6.6 确认 Ray 集群就绪

```bash
kubectl -n verl logs ray-0
```

出现：

```text
Ray cluster ready: 2 nodes, 16 NPU
```

### 6.7 手动启动训练

```bash
kubectl -n verl exec -it ray-0 -- bash
bash /workspace/run_grpo.sh
```

训练输出会显示在当前终端。

## 7. 查看结果

```bash
kubectl -n verl port-forward svc/ray-head 8260:8260
```

浏览器打开 `http://localhost:8260`。

checkpoint 在：

```text
容器内：/root/checkpoints/<实验名>/
宿主机：/home/checkpoints/<实验名>/
```

## 8. 清理

```bash
kubectl -n verl delete -f verl-all-in-one.yaml
```

宿主机目录不会删除。
