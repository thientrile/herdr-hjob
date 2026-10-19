#!/bin/sh
# Puts the hjob shim on PATH. Never overwrites an hjob that did not come from this plugin.
dir="${HJOB_BIN_DIR:-$HOME/.local/bin}"
dest="$dir/hjob"
if [ -e "$dest" ] && ! grep -q "herdr-hjob plugin" "$dest"; then
  echo "hjob-plugin: $dest exists and is not this plugin's shim; left it alone" >&2
  exit 1
fi
mkdir -p "$dir" && cp "$(dirname "$0")/bin/hjob" "$dest" && chmod +x "$dest" || exit 1
echo "hjob-plugin: installed $dest"
case ":$PATH:" in *":$dir:"*) ;; *) echo "hjob-plugin: add $dir to PATH" ;; esac
