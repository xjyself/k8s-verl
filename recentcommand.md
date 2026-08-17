# verl + Ray + MindCluster 常用调试命令

以下命令默认在管理机上执行，带有 `ssh node-x` 的命令才需要登录节点。

## 1. 部署 / 启动

### 三个文件分开部署

```bash
kubectl apply -f namespace.yaml
kubectl apply -f ray-head.yaml
kubectl apply -f ray-worker.yaml
```

### 合并版单文件部署

```bash
kubectl apply -f verl-all-in-one.yaml
```

### AscendJob 版部署

```bash
kubectl apply -f verl-ascendjob.yaml
```

## 2. 停止集群

### 停掉 StatefulSet（删除 Pod）

```bash
kubectl -n verl delete statefulset ray
```

### 停掉 Deployment

```bash
kubectl -n verl delete deploy ray-head ray-worker
```

### 只缩容不删除

```bash
kubectl -n verl scale statefulset ray --replicas=0
kubectl -n verl scale deploy ray-worker --replicas=0
```

### 删除全部相关资源

```bash
kubectl -n verl delete statefulset ray
kubectl -n verl delete deploy ray-head ray-worker
kubectl -n verl delete svc ray-head
kubectl -n verl delete ns verl
```

### 清理宿主机残留 Ray 进程

```bash
ssh <节点IP或主机名> 'ray stop --force; pkill -9 -f ray'
```

## 3. 查看状态

```bash
kubectl get nodes -o wide
kubectl -n verl get pod -o wide
kubectl -n verl get svc,endpoints
kubectl -n verl get deploy,statefulset
kubectl -n verl get all
```

### 只看某个 Pod

```bash
kubectl -n verl get pod ray-0
kubectl -n verl get pod -l app=ray
```

## 4. 查看详情和日志

### Pod 详情

```bash
kubectl -n verl describe pod ray-0
kubectl -n verl describe pod -l app=ray-worker
```

### 日志

```bash
kubectl -n verl logs ray-0 --tail=100
kubectl -n verl logs ray-1 --tail=100
kubectl -n verl logs -f ray-0
kubectl -n verl logs deploy/ray-head --tail=100
kubectl -n verl logs deploy/ray-worker --tail=100
```

### 上一个容器的日志（Pod 重启过）

```bash
kubectl -n verl logs ray-1 --previous --tail=100
```

## 5. 进入容器

### 进入 Head / Worker

```bash
kubectl -n verl exec -it ray-0 -- bash
kubectl -n verl exec -it ray-1 -- bash
```

### 直接执行单条命令

```bash
kubectl -n verl exec ray-0 -- ray status
kubectl -n verl exec ray-0 -- npu-smi info
kubectl -n verl exec ray-0 -- env | grep -E "HCCL|RAY|NPU|HOME"
```

## 6. 网络排查

### Service 是否 Headless

```bash
kubectl -n verl get svc ray-head -o yaml | grep -E "clusterIP|selector"
```

### Endpoints 是否有后端

```bash
kubectl -n verl get endpoints ray-head
```

### Pod 所在节点和 IP

```bash
kubectl -n verl get pod -o wide
```

### 容器内测试 DNS 和 TCP

```bash
kubectl -n verl exec ray-1 -- getent hosts ray-0.ray-head
kubectl -n verl exec ray-1 -- bash -c 'timeout 3 bash -c "</dev/tcp/ray-0.ray-head/6766" && echo OK || echo FAIL'
```

### 宿主机上查监听端口

```bash
ssh <Head所在节点> 'ss -lntp | grep 6766'
```

## 7. 修改环境变量后重启

### 直接设置环境变量

```bash
kubectl -n verl set env deploy/ray-worker RAY_HEAD_ADDR=51.38.67.147:6766
```

### 查看当前环境变量是否生效

```bash
kubectl -n verl get deploy ray-worker -o yaml | grep -E "address|RAY_HEAD_ADDR"
```

### 修改 YAML 后重新应用并重启 Pod

```bash
kubectl apply -f verl-all-in-one.yaml
kubectl -n verl delete pod ray-0 ray-1
```

## 8. Ray Dashboard

```bash
kubectl -n verl port-forward svc/ray-head 8260:8260
```

浏览器打开：

```text
http://localhost:8260
```

## 9. 常见报错快速定位

### Pod 一直 Pending

```bash
kubectl -n verl describe pod <pod名>
```

检查：

- `schedulerName: volcano` 是否存在
- NPU 资源名是否和 `kubectl describe node | grep -i ascend` 一致
- 节点 NPU 是否被其他任务占用

### Worker 连不上 Head

```bash
kubectl -n verl logs ray-1 --tail=100
kubectl -n verl logs ray-0 --tail=100
kubectl -n verl get endpoints ray-head
```

### Service 报 clusterIP 不能修改

先删旧 Service 再 apply：

```bash
kubectl -n verl delete svc ray-head
kubectl apply -f verl-all-in-one.yaml
```

### 找不到 train.parquet

```bash
kubectl -n verl exec -it ray-0 -- bash
cd /verl
python3 examples/data_preprocess/gsm8k.py --local_dataset_path /workspace/hf_data/gsm8k
ls -l /root/data/gsm8k/train.parquet /root/data/gsm8k/test.parquet
```

## 10. 一键重置（清空后重新部署）

```bash
kubectl -n verl delete statefulset ray
kubectl -n verl delete deploy ray-head ray-worker
kubectl -n verl delete svc ray-head
kubectl -n verl delete ns verl

ssh <node-a> 'ray stop --force; pkill -9 -f ray'
ssh <node-b> 'ray stop --force; pkill -9 -f ray'

kubectl apply -f verl-all-in-one.yaml
```
