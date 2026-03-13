#!/usr/bin/env bash
# connect-tor.sh
# tor コンテナの net1 を各 kind ノードの openbr0 に veth で接続する。
# devcontainer (--pid=host, --privileged) または host 上で実行すること。
#
# 使い方:
#   sudo ./scripts/connect-tor.sh          # 接続
#   sudo ./scripts/connect-tor.sh cleanup  # 切断・クリーンアップ

set -euo pipefail

CLAB_TOR="clab-openperouter-lab-tor"
KIND_NODES=("k8s-oper-worker" "k8s-oper-worker2" "k8s-oper-control-plane")
BRIDGE="openbr0"
TOR_IP="10.100.0.100/24"

TOR_PID=$(docker inspect -f '{{.State.Pid}}' "$CLAB_TOR" 2>/dev/null || true)

cleanup() {
  echo "=== cleanup ==="
  for node in "${KIND_NODES[@]}"; do
    NODE_PID=$(docker inspect -f '{{.State.Pid}}' "$node" 2>/dev/null || true)
    [ -z "$NODE_PID" ] && continue
    nsenter -t "$NODE_PID" -n -- ip link del "veth-tor-${node}" 2>/dev/null || true
    echo "  removed veth on $node"
  done
  # tor 側の net1 も削除
  if [ -n "$TOR_PID" ]; then
    nsenter -t "$TOR_PID" -n -- ip link del net1 2>/dev/null || true
  fi
  echo "done"
}

if [ "${1:-}" = "cleanup" ]; then
  cleanup
  exit 0
fi

echo "=== connect-tor.sh ==="

if ! docker inspect "$CLAB_TOR" &>/dev/null; then
  echo "ERROR: $CLAB_TOR が見つかりません。clab deploy を先に実行してください"
  exit 1
fi

if [ -z "$TOR_PID" ]; then
  echo "ERROR: tor の PID を取得できません"
  exit 1
fi

echo "tor PID: $TOR_PID"

# 既存の net1 をクリーンアップ
nsenter -t "$TOR_PID" -n -- ip link del net1 2>/dev/null || true

# 各 kind ノードに veth を作成して openbr0 に接続する
# tor 側は最初のノードのみ net1 として接続、他はブリッジ拡張用
FIRST=true
for node in "${KIND_NODES[@]}"; do
  NODE_PID=$(docker inspect -f '{{.State.Pid}}' "$node" 2>/dev/null || true)
  if [ -z "$NODE_PID" ]; then
    echo "  SKIP: $node (PID 取得失敗)"
    continue
  fi

  VETH_NODE="veth-tor-${node}"
  VETH_HOST="veth-h-${node}"

  # 既存の veth をクリーンアップ
  nsenter -t "$NODE_PID" -n -- ip link del "$VETH_NODE" 2>/dev/null || true
  ip link del "$VETH_HOST" 2>/dev/null || true

  # veth ペアを作成
  ip link add "$VETH_HOST" type veth peer name "$VETH_NODE"

  # ノード側の veth を kind ノードの namespace に移動して openbr0 に接続
  ip link set "$VETH_NODE" netns "$NODE_PID"
  nsenter -t "$NODE_PID" -n -- ip link set "$VETH_NODE" master "$BRIDGE"
  nsenter -t "$NODE_PID" -n -- ip link set "$VETH_NODE" up

  if [ "$FIRST" = true ]; then
    # tor 側: 最初の veth を net1 として接続し IP を付与
    ip link set "$VETH_HOST" netns "$TOR_PID"
    nsenter -t "$TOR_PID" -n -- ip link set "$VETH_HOST" name net1
    nsenter -t "$TOR_PID" -n -- ip link set net1 up
    nsenter -t "$TOR_PID" -n -- ip addr add "$TOR_IP" dev net1
    FIRST=false
    echo "  connected: $node → net1 ($TOR_IP)"
  else
    # 2台目以降: ホスト側の veth をノードの openbr0 に直接追加 (tor には不要)
    ip link set "$VETH_HOST" netns "$NODE_PID"
    nsenter -t "$NODE_PID" -n -- ip link set "$VETH_HOST" master "$BRIDGE"
    nsenter -t "$NODE_PID" -n -- ip link set "$VETH_HOST" up
    echo "  connected: $node → openbr0 (bridge extension)"
  fi
done

echo ""
echo "=== 接続完了 ==="
echo "BGP 確認:"
echo "  docker exec $CLAB_TOR vtysh -c 'show bgp summary'"
