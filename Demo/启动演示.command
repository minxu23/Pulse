#!/bin/bash
# 启动 iOS 模拟器并打开 Pulse，选择一位示例用户，载入全新的示例数据（120 天或一整年）。
# 也可以在终端指定：PULSE_PERSONA=chenjie ./启动演示.command（xiaolin / chenjie / linyue / wangjianguo）
source "$(cd "$(dirname "$0")" && pwd)/.pulse-demo-common.sh"
run_demo reset
