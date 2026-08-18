#!/bin/bash
set -x

# 放到两台节点的 /home/scripts/start.sh
# YAML 中 Master/Worker 容器都执行：bash /workspace/start.sh

ulimit -n 32768

# 静态环境变量统一在这里配置，YAML 只保留 K8s 注入的变量
export PYTHONSAFEPATH=1
export PYTHONPATH=/vllm
export RAY_DEDUP_LOGS=0
export HYDRA_FULL_ERROR=1
export TASK_QUEUE_ENABLE=1
export HCCL_ASYNC_ERROR_HANDLING=0
export HCCL_EXEC_TIMEOUT=3600
export HCCL_CONNECT_TIMEOUT=3600
export HCCL_HOST_SOCKET_PORT_RANGE=60000-60050
export HCCL_NPU_SOCKET_PORT_RANGE=61000-61050
export RAY_EXPERIMENTAL_NOSET_ASCEND_RT_VISIBLE_DEVICES=1
export HCCL_SOCKET_IFNAME=enp189s0f0
export GLOO_SOCKET_IFNAME=enp189s0f0
export HF_DEACTIVATE_ASYNC_LOAD=1

# 角色由 YAML 传入：RAY_ROLE=master / RAY_ROLE=worker
# 如果没传，根据 Pod 名兜底判断
if [ -z "$RAY_ROLE" ]; then
  case "$POD_NAME" in
    *-master-*) RAY_ROLE=master ;;
    *-worker-*) RAY_ROLE=worker ;;
  esac
fi

if [ "$RAY_ROLE" = "master" ]; then
  echo "I am Ray Head"
  ray start --head --port 6766 \
    --dashboard-host=0.0.0.0 --dashboard-port=8260 \
    --node-ip-address=$POD_IP \
    --resources="{\"NPU\": ${NPUS_PER_NODE}}"

  while true; do
    total_npu=$(ray status | grep -oP '(?<=/)\d+\.\d+(?=\s*NPU)' | head -n 1 | awk '{print int($1)}')
    nodes=$((total_npu / NPUS_PER_NODE))
    if [ "$nodes" -ge "$NNODES" ]; then
      echo "Ray cluster ready: $nodes nodes, $total_npu NPU"
      ray status
      break
    fi
    echo "Waiting for Ray nodes: $nodes / $NNODES"
    sleep 5
  done

  echo "Ray cluster is ready. Run training manually with: bash /workspace/run_grpo.sh"
else
  echo "I am Ray Worker"
  if [ -n "$RAY_HEAD_ADDR" ]; then
    HEAD_ADDR=$RAY_HEAD_ADDR
  elif [ -n "$MASTER_ADDR" ]; then
    HEAD_ADDR=${MASTER_ADDR}:6766
  else
    echo "Set RAY_HEAD_ADDR or MASTER_ADDR"
    exit 1
  fi
  ray start --address=$HEAD_ADDR \
    --node-ip-address=$POD_IP \
    --resources="{\"NPU\": ${NPUS_PER_NODE}}"
fi

sleep infinity
