#!/bin/zsh
# Compiles organize.swift on first use (and after it changes), then runs it.
# Usage: organize.sh <base folder> <file>...
set -e
dir=${OMMATEUM_PLUGIN_DIR:-${0:A:h}}
src=$dir/organize.swift
bin=$dir/.build/organize

if [[ ! -x $bin || $src -nt $bin ]]; then
  # xcode-select -p does not open the installer dialog that /usr/bin/swiftc would.
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo "Swift コンパイラが見つかりません。ターミナルで xcode-select --install を実行してください。" >&2
    exit 1
  fi
  mkdir -p $dir/.build
  tmp=$(mktemp $dir/.build/organize.XXXXXX)
  if ! /usr/bin/swiftc -O -o $tmp $src; then
    rm -f $tmp
    echo "organize.swift のコンパイルに失敗しました。" >&2
    exit 1
  fi
  mv -f $tmp $bin
fi

exec $bin "$@"
