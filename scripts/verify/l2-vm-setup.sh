#!/bin/sh
# L2 渠道的 VM 内设置：镜像源 + 可用的 resolv.conf，然后重启 docker。
#
# 为什么需要这一步（两件事叠在一起会让 L2 完全起不来）：
#   1. colima **每次启动都会重写** VM 里的 /etc/docker/daemon.json，而它自己不支持
#      registry-mirrors（0.10.3 的配置里没有这个键）——所以镜像源只能在启动后补写；
#   2. 镜像里的 /etc/resolv.conf 是个**悬空**符号链接（systemd-resolved 没跑），
#      dockerd 于是去问 [::1]:53 并失败；而本机直连 Docker Hub 又是超时的。
#      Go 的解析器会把 resolv.conf 缓存住，所以补写之后必须重启 docker。
#
# 幂等：已经配过的镜像源不会重复插入；每次跑都会重写 resolv.conf 并重启 docker。
#
#   sh scripts/verify/l2-vm-setup.sh
#
# 环境变量：DSH_LANE_REGISTRY_MIRROR / DSH_LANE_DNS1 / DSH_LANE_DNS2
set -e

MIRROR="${DSH_LANE_REGISTRY_MIRROR:-https://docker.m.daocloud.io}"
DNS1="${DSH_LANE_DNS1:-223.5.5.5}"
DNS2="${DSH_LANE_DNS2:-119.29.29.29}"

if ! command -v colima >/dev/null 2>&1; then
  echo "找不到 colima：L2 需要 colima + docker（brew install colima docker）" >&2
  exit 1
fi

if ! colima status >/dev/null 2>&1; then
  echo "colima 没在跑：先 colima start" >&2
  exit 1
fi

colima ssh -- sudo sh -c "grep -q registry-mirrors /etc/docker/daemon.json 2>/dev/null || \
  sed -i 's|\"features\"|\"registry-mirrors\":[\"${MIRROR}\"],\"features\"|' /etc/docker/daemon.json"
colima ssh -- sudo sh -c "rm -f /etc/resolv.conf && printf 'nameserver ${DNS1}\nnameserver ${DNS2}\n' > /etc/resolv.conf"
colima ssh -- sudo systemctl restart docker
sleep 5

echo "镜像源：$(docker info --format '{{json .RegistryConfig.Mirrors}}')"
echo "Docker：$(docker info --format '{{.ServerVersion}} {{.Architecture}}')"
