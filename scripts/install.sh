#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/build/Codex Usage Float.app"
if [[ ! -d "$app" ]]; then
  print -u2 -- '请先运行 zsh build.sh。'
  exit 1
fi
if pgrep -x CodexUsageFloat >/dev/null; then
  print -u2 -- '请先通过菜单栏退出 Codex 用量浮窗，再重新运行安装命令。不会停止 Codex。'
  exit 1
fi
codesign --verify --deep --strict "$app"
destination="$HOME/Applications/Codex Usage Float.app"
mkdir -p "$HOME/Applications"
if [[ -e "$destination" ]] && codesign -d --verbose=2 "$destination" 2>&1 | rg -q '^Authority='; then
  requirement="$(codesign -d -r- "$destination" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$requirement" ]] || ! codesign --verify --strict -R="$requirement" "$app" 2>/dev/null; then
    print -u2 -- '新版与已安装版的签名身份不一致，已停止安装以保护现有授权。请使用相同固定签名重新构建。'
    exit 1
  fi
fi
if [[ -e "$destination" ]]; then
  backup="$HOME/Library/Application Support/Codex Usage Float/backups/$(date +%Y%m%d-%H%M%S)-$$.app"
  ditto "$destination" "$backup"
  print -r -- "旧版本已备份：$backup"
fi
ditto "$app" "$destination"
print -r -- "已安装：$destination"
print -- '首次切换到固定签名需要重新授权一次；之后使用同一签名与安装路径更新，可沿用辅助功能授权。'
