#!/bin/bash
# 打开 Pulse 并保留上次演示中记录的数据（第一次运行时会载入示例数据）。
source "$(cd "$(dirname "$0")" && pwd)/.pulse-demo-common.sh"
run_demo keep
