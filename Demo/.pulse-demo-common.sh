#!/bin/bash
# Shared by the demo scripts: find Xcode's simulator tools, pick an iPhone simulator,
# install the prebuilt Pulse.app (or build it from source if missing) and launch it.
set -e
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$DEMO_DIR")"
APP="$DEMO_DIR/Pulse.app"
BUNDLE_ID="com.pulse.restingheart"

say() { printf "\n▸ %s\n" "$1" >&2; }
fail() { printf "\n✕ %s\n\n按任意键关闭窗口…" "$1" >&2; read -n 1 -s </dev/tty 2>/dev/null || true; exit 1; }

if ! xcrun simctl help >/dev/null 2>&1; then
  fail "没有找到 iOS 模拟器。请先从 App Store 安装 Xcode，打开一次并安装 iOS 平台（Xcode › Settings › Components）。"
fi

build_app() {
  say "正在从源代码构建 Pulse（首次约 1–2 分钟）…"
  local dd="$DEMO_DIR/.build"
  xcodebuild -project "$PROJECT_DIR/Pulse.xcodeproj" -scheme Pulse -configuration Release \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build || fail "构建失败，请用 Xcode 打开 Pulse.xcodeproj 查看错误。"
  rm -rf "$APP"
  cp -R "$dd/Build/Products/Release-iphonesimulator/Pulse.app" "$APP"
}

# The newest installed iOS (e.g. "iOS 27.2"). Older runtimes can stay installed; the demo uses this one.
newest_ios() {
  xcrun simctl list runtimes available | grep -E "^iOS [0-9]" | sed -E 's/^(iOS [0-9.]+).*/\1/' | sort -V | tail -1
}

pick_device() {
  local udid ios name
  ios=$(newest_ios)
  # An iPhone already open on the newest iOS, then any open iPhone, then boot one on the newest iOS.
  udid=$(xcrun simctl list devices booted "$ios" | grep -E "iPhone" | grep -Eo "[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}" | head -1)
  [ -z "$udid" ] && udid=$(booted_iphones | head -1)
  if [ -z "$udid" ]; then
    for name in "iPhone 17" "iPhone 17 Pro" "iPhone 18 Pro" "iPhone 16" "iPhone[^(]*"; do
      udid=$(xcrun simctl list devices available "$ios" | grep -E "^ +$name \(" | grep -Eo "[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}" | head -1)
      [ -n "$udid" ] && break
    done
    [ -z "$udid" ] && fail "没有可用的 iPhone 模拟器。请在 Xcode › Window › Devices and Simulators 中添加一台 iPhone。"
    say "正在启动模拟器（$ios）…"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  fi
  echo "$udid"
}

# Cloud model keys for the Health Agent test entry (我的 › 云端模型（测试）), read from the keys
# already used by Spark / summit2md. They are handed to the app for this run only (process
# environment) — never printed, copied or written to any file. Set PULSE_NO_CLOUD_KEYS=1 to skip.
KEY_DIR="${PULSE_KEY_DIR:-$HOME/.spark/keys}"

read_key_file() {
  # Accepts a bare key or a KEY=value line; ignores comments and surrounding quotes/whitespace.
  [ -r "$1" ] || return 0
  grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' | head -1 \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//' \
    | tr -d '[:space:]'
}

persona_name() {
  case "$1" in chenjie) echo "陈杰" ;; linyue) echo "林悦" ;; wangjianguo) echo "王建国" ;; *) echo "晓林" ;; esac
}

load_cloud_keys() {
  CLOUD_OPENROUTER=""; CLOUD_ANTHROPIC=""
  [ "${PULSE_NO_CLOUD_KEYS:-0}" = "1" ] && return 0
  CLOUD_OPENROUTER=$(read_key_file "$KEY_DIR/openrouter.key")
  CLOUD_ANTHROPIC=$(read_key_file "$KEY_DIR/anthropic.key")
  [ -z "$CLOUD_OPENROUTER" ] && CLOUD_OPENROUTER="${OPENROUTER_API_KEY:-}"
  [ -z "$CLOUD_ANTHROPIC" ] && CLOUD_ANTHROPIC="${ANTHROPIC_API_KEY:-}"
  return 0
}

# Xcode 26 and earlier ship Simulator.app; Xcode 27 replaces it with DeviceHub.app.
open_simulator_window() {
  local udid="$1"
  if open -b com.apple.iphonesimulator --args -CurrentDeviceUDID "$udid" >/dev/null 2>&1; then
    SIM_APP="Simulator"
  elif open -b com.apple.dt.Devices >/dev/null 2>&1; then
    SIM_APP="DeviceHub"
  else
    SIM_APP=""
  fi
}

# Sample user for a fresh demo: PULSE_PERSONA=xiaolin|chenjie|linyue|wangjianguo, or pick interactively.
choose_persona() {
  if [ -n "${PULSE_PERSONA:-}" ]; then echo "$PULSE_PERSONA"; return; fi
  printf "\n选择演示用户（10 秒内不选则使用 1）：\n" >&2
  printf "  1) 晓林    39 岁 · 坚持得不错，静息心率明显下降\n" >&2
  printf "  2) 陈杰    45 岁 · 久坐、血压偏高、熬夜饮酒，计划常落空\n" >&2
  printf "  3) 林悦    34 岁 · 倒班护士，作息混乱，记录断断续续\n" >&2
  printf "  4) 王建国  57 岁 · 2 型糖尿病与高血压，漏服药、运动少\n请输入 1–4：" >&2
  local c=""
  read -t 10 -n 1 c </dev/tty 2>/dev/null || true
  printf "\n" >&2
  case "$c" in 2) echo chenjie ;; 3) echo linyue ;; 4) echo wangjianguo ;; *) echo xiaolin ;; esac
}

booted_iphones() {
  xcrun simctl list devices booted | grep -E "iPhone" | grep -Eo "[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}" || true
}

device_name() {
  xcrun simctl list devices | grep "$1" | sed -E 's/^ *([^(]*[^ (]) *\(.*/\1/' | head -1
}

# Installs this build on one simulator and (re)starts Pulse there; the cloud keys go to this run only.
install_and_launch() {
  local udid="$1"; shift
  xcrun simctl install "$udid" "$APP" || return 1
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMCTL_CHILD_PULSE_OPENROUTER_KEY="$CLOUD_OPENROUTER" \
  SIMCTL_CHILD_PULSE_ANTHROPIC_KEY="$CLOUD_ANTHROPIC" \
  SIMCTL_CHILD_PULSE_KEY_SOURCE="~/.spark/keys" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" >/dev/null
}

run_demo() {
  local reset="$1"
  [ -d "$APP" ] || build_app
  local udid
  udid=$(pick_device | tail -1)
  [[ "$udid" =~ ^[0-9A-F-]{36}$ ]] || exit 1
  open_simulator_window "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  load_cloud_keys
  local args=(-PulseDemo)
  # PULSE_TIME="07:40" (or "2026-10-23 07:40") opens the demo at that moment; 我的 › 演示时间 changes it later.
  if [ -n "${PULSE_TIME:-}" ]; then args+=(-PulseTime "$PULSE_TIME"); fi
  if [ "$reset" = "reset" ]; then
    local persona
    persona=$(choose_persona)
    args+=(-PulseReset -PulsePersona "$persona")
    say "正在安装并打开 Pulse（载入示例用户「$(persona_name "$persona")」的 120 天数据）…"
  else
    say "正在安装并打开 Pulse（保留上次的数据）…"
  fi
  # Every booted iPhone gets this build and the same start, so whichever one the simulator window
  # shows is the current demo — an older copy left on another simulator looks like an old version.
  local devices=() d
  while read -r d; do [ -n "$d" ] && devices+=("$d"); done < <(booted_iphones)
  [[ " ${devices[*]} " == *" $udid "* ]] || devices+=("$udid")
  for d in "${devices[@]}"; do
    install_and_launch "$d" "${args[@]}" || fail "安装失败。可以删除 Demo/Pulse.app 后重试，脚本会从源代码重新构建。"
  done
  # The first start of the day can restart the simulator service, which shuts the device down
  # again a few seconds later: if that happens, boot it once more and reopen Pulse.
  local i
  for i in 1 2 3 4 5; do
    sleep 2
    booted_iphones | grep -q "$udid" && continue
    say "模拟器刚被系统重启，正在重新打开…"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    install_and_launch "$udid" "${args[@]}" || fail "安装失败。可以删除 Demo/Pulse.app 后重试，脚本会从源代码重新构建。"
    break
  done
  local found=()
  [ -n "$CLOUD_OPENROUTER" ] && found+=("OpenRouter")
  [ -n "$CLOUD_ANTHROPIC" ] && found+=("Anthropic")
  if [ ${#found[@]} -gt 0 ]; then
    say "已带上 ~/.spark/keys 中的 $(IFS=/; echo "${found[*]}") 密钥（只在本次运行中使用，未写入任何文件）。
  在 App「我的 › 云端模型（测试）」中测试连接、同意发送数据摘要后即可启用。"
  fi
  local name=""
  for d in "${devices[@]}"; do name+="${name:+、}「$(device_name "$d")」"; done
  if [ "$SIM_APP" = "DeviceHub" ]; then
    osascript -e 'tell application id "com.apple.dt.Devices" to activate' >/dev/null 2>&1 || true
    printf "\n✓ Pulse 已在模拟器%s中打开（都是这次的版本）。\n  在 DeviceHub 窗口左侧选择其中一台即可看到并操作 App。这个窗口可以关闭。\n" "$name"
  elif [ "$SIM_APP" = "Simulator" ]; then
    osascript -e 'tell application id "com.apple.iphonesimulator" to activate' >/dev/null 2>&1 || true
    printf "\n✓ Pulse 已在模拟器%s中打开（都是这次的版本）。这个窗口可以关闭。\n" "$name"
  else
    printf "\n✓ Pulse 已在模拟器%s中运行，但没有找到模拟器窗口程序（Simulator 或 DeviceHub）。请在 Xcode › Window 中打开。\n" "$name"
  fi
}
