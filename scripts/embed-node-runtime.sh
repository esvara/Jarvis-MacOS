#!/bin/zsh

set -euo pipefail

SOURCE_NODE_BIN="${1:?Missing source node binary path.}"
TARGET_NODE_BIN="${2:?Missing target node binary path.}"
FRAMEWORKS_DIR="${3:?Missing frameworks directory path.}"

mkdir -p "$(dirname "$TARGET_NODE_BIN")" "$FRAMEWORKS_DIR"
cp -L "$SOURCE_NODE_BIN" "$TARGET_NODE_BIN"
chmod +w "$TARGET_NODE_BIN"
chmod +x "$TARGET_NODE_BIN"

typeset -A queued
typeset -A source_paths
typeset -a pending=()
source_paths[$TARGET_NODE_BIN]="$SOURCE_NODE_BIN"

resolve_rpath() {
  local source_subject="$1"
  local rpath_value="$2"
  local source_dir="${source_subject:h}"
  local executable_dir="${source_subject:h}"

  case "$rpath_value" in
    @loader_path/*)
      echo "$source_dir/${rpath_value#@loader_path/}"
      ;;
    @executable_path/*)
      echo "$executable_dir/${rpath_value#@executable_path/}"
      ;;
    /*)
      echo "$rpath_value"
      ;;
    *)
      echo "$source_dir/$rpath_value"
      ;;
  esac
}

resolve_dependency_path() {
  local dependency="$1"
  local source_subject="$2"
  local source_dir="${source_subject:h}"

  case "$dependency" in
    /System/*|/usr/lib/*)
      return 1
      ;;
    /*)
      [[ -f "$dependency" ]] || return 1
      echo "$dependency"
      return 0
      ;;
    @loader_path/*)
      local candidate="$source_dir/${dependency#@loader_path/}"
      [[ -f "$candidate" ]] || return 1
      echo "$candidate"
      return 0
      ;;
    @rpath/*)
      local suffix="${dependency#@rpath/}"
      local candidate
      while IFS= read -r rpath_value; do
        candidate="$(resolve_rpath "$source_subject" "$rpath_value")/$suffix"
        if [[ -f "$candidate" ]]; then
          echo "$candidate"
          return 0
        fi
      done < <(
        otool -l "$source_subject" \
          | awk '
              $1 == "cmd" && $2 == "LC_RPATH" { capture = 1; next }
              capture && $1 == "path" { print $2; capture = 0 }
            '
      )
      local fallback="$source_dir/$suffix"
      [[ -f "$fallback" ]] || return 1
      echo "$fallback"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

copy_dependency() {
  local original="$1"
  local name="${original:t}"
  local target="$FRAMEWORKS_DIR/$name"

  if [[ ! -f "$target" ]]; then
    cp -L "$original" "$target"
    chmod +w "$target"
    chmod 755 "$target"
    install_name_tool -id "@loader_path/$name" "$target" 2>/dev/null || true
  fi

  source_paths[$target]="$original"

  if [[ -z "${queued[$target]-}" ]]; then
    queued[$target]=1
    pending+=("$target")
  fi
}

rewrite_dependencies() {
  local subject="$1"
  local replacement_prefix="$2"
  local source_subject="${source_paths[$subject]-$subject}"

  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue

    local original_dependency=""
    original_dependency="$(resolve_dependency_path "$dependency" "$source_subject")" || continue
    local name="${original_dependency:t}"
    copy_dependency "$original_dependency"

    if [[ "$dependency" == @loader_path/* && "$replacement_prefix" == "@loader_path" ]]; then
      continue
    fi

    install_name_tool -change "$dependency" "$replacement_prefix/$name" "$subject"
  done < <(otool -L "$source_subject" | tail -n +2 | awk '{print $1}')
}

rewrite_dependencies "$TARGET_NODE_BIN" "@executable_path/../Frameworks"

while (( ${#pending[@]} > 0 )); do
  subject="${pending[1]}"
  pending=("${pending[@]:1}")
  install_name_tool -id "@loader_path/${subject:t}" "$subject" 2>/dev/null || true
  rewrite_dependencies "$subject" "@loader_path"
done

external_refs="$(
  otool -L "$TARGET_NODE_BIN" \
    | tail -n +2 \
    | awk '{print $1}' \
    | grep '^/' \
    | grep -v '^/System/' \
    | grep -v '^/usr/lib/' \
    || true
)"

if [[ -n "$external_refs" ]]; then
  echo "Node runtime still references external libraries:" >&2
  echo "$external_refs" >&2
  exit 1
fi
