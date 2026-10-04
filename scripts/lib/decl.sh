#!/usr/bin/env bash
# Vibe Coding Workstation —— 声明层组合
#
# 借鉴 DeepSeek Harness 的分层设计：
#   DSH:  空根 → dsh.profile.bundles → profile cordis.patch.yml → $DSH_HOME patch → --patch
#   本模块: 空根 → workstation.yaml → workstation.local.yaml → --patch <file>
#
# 每层是**按键覆盖**：后层只覆盖它显式写了的键，其余继承前层。
# 覆盖按 id 定位（services.<id>），不依赖顺序。
#
# 本模块只做「组合」，不解析完整 YAML —— 对本文件自身采用的结构化 YAML
# （两级缩进、键: 值）做行级合并，零依赖。超出该结构的写法会被拒绝而非误读。

set -Eeuo pipefail

# ── 组合：把若干层合并成一份扁平化的最终声明 ────────────────────────
# 输出格式：<路径>	<值>，例如 services.forgejo.port	3000
# 这既是 --dump 的输出，也是内部查询的依据。

_decl_files=()

decl_add_layer() {
  # 注意：不能写成 `[ -f "$1" ] && _decl_files+=("$1")` ——
  # 当文件不存在时该表达式为假，作为函数最后一条命令会在 set -e 下
  # 让整个脚本退出。必须显式 return 0。
  if [ -f "$1" ]; then
    _decl_files+=("$1")
  fi
  return 0
}

# 解析一层为「路径 → 值」，按出现顺序输出
_decl_parse() {
  local file="$1"
  local stack=() depth=0 line indent key val path

  while IFS= read -r line || [ -n "$line" ]; do
    # 去注释与尾空白（不处理值内的 #，本项目值里不含）
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    # 缩进宽度（2 空格为一级）
    # 注意：不要用 `sed | wc -c` —— sed 会补换行，使 wc -c 恒 ≥1，
    # 零缩进行被算成 1，奇数缩进也会错位。用 bash 内建剥离前导空格。
    local lead="${line%%[![:space:]]*}"
    indent=${#lead}
    depth=$((indent / 2))

    # 丢掉比当前层更深的栈
    while [ "${#stack[@]}" -gt "$depth" ]; do
      unset 'stack[${#stack[@]}-1]'
    done

    if printf '%s' "$line" | grep -q '^[[:space:]]*-'; then
      # 列表项：记录为 <父路径>[]=<值>
      val="$(printf '%s' "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')"
      path="$(IFS=.; echo "${stack[*]}")"
      printf '%s[]\t%s\n' "$path" "$val"
      continue
    fi

    key="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/:.*$//')"
    if printf '%s' "$line" | grep -q ':'; then
      val="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
      if [ -n "$val" ]; then
        path="$(IFS=.; echo "${stack[*]}")"
        [ -n "$path" ] && printf '%s.%s\t%s\n' "$path" "$key" "$val" || printf '%s\t%s\n' "$key" "$val"
      else
        # 进入子级
        [ "${#stack[@]}" -gt "$depth" ] && unset 'stack[${#stack[@]}-1]'
        stack+=("$key")
      fi
    fi
  done < "$file"
}

# 组合所有层：后层同键覆盖前层；*[] 列表键累积
decl_compose() {
  declare -A map=()
  local -a listkeys=()
  local f line k v

  for f in "${_decl_files[@]}"; do
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] || continue
      case "$k" in
        *'[]')
          local base="${k%[]}"
          map["${k}:${v}"]="$v"
          ;;
        *) map["$k"]="$v" ;;
      esac
    done < <(_decl_parse "$f")
  done

  # 稳定输出
  local key
  for key in $(printf '%s\n' "${!map[@]}" | sort); do
    printf '%s\t%s\n' "$key" "${map[$key]}"
  done
}

# 查询单个键
#
# ⚠️ 不用 `awk ... exit` / `head` 这类**提前退出**的消费者：
#    上游 printf 收到 SIGPIPE，配合 set -o pipefail 会让整条管道返回非零，
#    在 set -e 下直接杀死调用方脚本（命令替换里尤其隐蔽）。
#    因此让 awk 读完所有输入，最后再输出。
decl_get() {
  local want="$1"
  decl_compose | awk -F'\t' -v k="$want" '$1==k {v=$2} END {if (v != "") print v}'
  return 0
}

# 列出某前缀下的所有键
decl_keys() {
  local prefix="$1"
  decl_compose | awk -F'\t' -v p="$prefix" 'index($1,p)==1 {print $1}'
  return 0
}
