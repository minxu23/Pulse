#!/bin/bash
# 修改代码后，从源代码重新构建 Demo/Pulse.app。
source "$(cd "$(dirname "$0")" && pwd)/.pulse-demo-common.sh"
build_app
printf "\n✓ 已更新 Demo/Pulse.app。双击「启动演示」即可使用新版本。\n"
