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
if [[ -e "$destination" ]]; then
  backup="$HOME/Library/Application Support/Codex Usage Float/backups/$(date +%Y%m%d-%H%M%S)-$$.app"
  ditto "$destination" "$backup"
  print -r -- "旧版本已备份：$backup"
fi
ditto "$app" "$destination"
print -r -- "已安装：$destination"
print -- '自动跟随需要辅助功能权限。更新后如果权限失效，请移除旧授权条目并重新添加此应用。'
