#!/bin/bash
# 把笔记本的 SSH 公钥装到每台 Pi 上（之后所有脚本都免密）。每台会提示输入一次 Pi 的密码。
# 用法：scripts/add_keys.sh [用户@IP ...]      （默认：hosts.env 里的所有 Pi）
set -uo pipefail
source "$(dirname "$0")/lib.sh"
[ -f ~/.ssh/id_ed25519.pub ] || [ -f ~/.ssh/id_rsa.pub ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for h in ${*:-$ALL_PIS}; do
  if ssh_pi "$h" true 2>/dev/null; then echo "[$h] 已经可以免密登录"; continue; fi
  echo "[$h] 请输入密码："; ssh-copy-id -o StrictHostKeyChecking=accept-new "$h" >/dev/null 2>&1 \
    && echo "[$h] 完成" || echo "[$h] 失败：检查 IP、用户名和密码"
done
