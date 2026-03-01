#!/usr/bin/env bash

set -euo pipefail

PROGRAM="tmux-mesh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR_SCRIPT="$SCRIPT_DIR/mesh-selector.sh"

rows=0
cols=0
target_count=0
declare -a target_r1=()
declare -a target_c1=()
declare -a target_r2=()
declare -a target_c2=()
parsed_r1=0
parsed_c1=0
parsed_r2=0
parsed_c2=0
base_path=""

fail() {
  tmux display-message "$PROGRAM: $1"
  exit 1
}

pane_path() {
  local pane="${1:-}"

  if [[ -n "$pane" && "$pane" == %* ]]; then
    tmux display-message -p -t "$pane" '#{pane_current_path}'
    return 0
  fi

  return 1
}

expand_path_input() {
  local input="$1"
  local relative_base="$2"

  case "$input" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${input#"~/"}"
      ;;
    /*)
      printf '%s\n' "$input"
      ;;
    *)
      printf '%s/%s\n' "$relative_base" "$input"
      ;;
  esac
}

resolve_base_path() {
  local source="${1:-}"
  local current_pane="${TMUX_PANE:-}"
  local context_path=""
  local expanded_path=""

  if [[ -n "$source" ]]; then
    if pane_path "$source" >/dev/null; then
      base_path="$(pane_path "$source")"
      return 0
    fi
  fi

  if pane_path "$current_pane" >/dev/null; then
    context_path="$(pane_path "$current_pane")"
  else
    context_path="$(pwd)"
  fi

  if [[ -n "$source" ]]; then
    expanded_path="$(expand_path_input "$source" "$context_path")"
    if [[ ! -d "$expanded_path" ]]; then
      fail "path does not exist: $source"
    fi
    base_path="$(cd "$expanded_path" && pwd)"
    return 0
  fi

  base_path="$context_path"
}

shell_quote() {
  printf '%q' "$1"
}

parse_grid() {
  local grid="${1:-}"

  if [[ "$grid" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
    rows="${BASH_REMATCH[1]}"
    cols="${BASH_REMATCH[2]}"
    return 0
  fi

  fail "grid must look like 2x3 or 4x4"
}

reset_targets() {
  target_count=0
  target_r1=()
  target_c1=()
  target_r2=()
  target_c2=()
}

parse_rect_token() {
  local rect="$1"

  if [[ "$rect" =~ ^([1-9][0-9]*),([1-9][0-9]*)(-([1-9][0-9]*),([1-9][0-9]*))?$ ]]; then
    parsed_r1="${BASH_REMATCH[1]}"
    parsed_c1="${BASH_REMATCH[2]}"

    if [[ -n "${BASH_REMATCH[4]:-}" ]]; then
      parsed_r2="${BASH_REMATCH[4]}"
      parsed_c2="${BASH_REMATCH[5]}"
    else
      parsed_r2="$parsed_r1"
      parsed_c2="$parsed_c1"
    fi
  else
    fail "panel must look like 2,2-3,4"
  fi

  if (( parsed_r1 > parsed_r2 || parsed_c1 > parsed_c2 )); then
    fail "panel coordinates must be top-left to bottom-right"
  fi

  if (( parsed_r1 < 1 || parsed_c1 < 1 || parsed_r2 > rows || parsed_c2 > cols )); then
    fail "panel coordinates must stay inside the grid"
  fi
}

rectangles_overlap() {
  local a_r1="$1"
  local a_c1="$2"
  local a_r2="$3"
  local a_c2="$4"
  local b_r1="$5"
  local b_c1="$6"
  local b_r2="$7"
  local b_c2="$8"

  (( a_r1 <= b_r2 && a_r2 >= b_r1 && a_c1 <= b_c2 && a_c2 >= b_c1 ))
}

add_target_rect() {
  local rect="$1"
  local rr1 cc1 rr2 cc2 i

  parse_rect_token "$rect"
  rr1="$parsed_r1"
  cc1="$parsed_c1"
  rr2="$parsed_r2"
  cc2="$parsed_c2"

  for ((i = 0; i < target_count; i++)); do
    if rectangles_overlap \
      "$rr1" "$cc1" "$rr2" "$cc2" \
      "${target_r1[$i]}" "${target_c1[$i]}" "${target_r2[$i]}" "${target_c2[$i]}"; then
      fail "panels cannot overlap"
    fi
  done

  target_r1+=("$rr1")
  target_c1+=("$cc1")
  target_r2+=("$rr2")
  target_c2+=("$cc2")
  target_count=${#target_r1[@]}
}

parse_rect_list() {
  local rects="${1:-}"
  local token

  reset_targets

  if [[ -z "$rects" || "$rects" == "none" ]]; then
    return 0
  fi

  IFS='|' read -r -a parsed_tokens <<<"$rects"
  for token in "${parsed_tokens[@]}"; do
    [[ -n "$token" ]] || continue
    add_target_rect "$token"
  done
}

region_matches_target() {
  local r1="$1"
  local c1="$2"
  local r2="$3"
  local c2="$4"
  local i

  for ((i = 0; i < target_count; i++)); do
    if (( r1 == target_r1[i] && c1 == target_c1[i] && r2 == target_r2[i] && c2 == target_c2[i] )); then
      return 0
    fi
  done

  return 1
}

find_overlapping_target() {
  local r1="$1"
  local c1="$2"
  local r2="$3"
  local c2="$4"
  local i

  for ((i = 0; i < target_count; i++)); do
    if rectangles_overlap \
      "$r1" "$c1" "$r2" "$c2" \
      "${target_r1[$i]}" "${target_c1[$i]}" "${target_r2[$i]}" "${target_c2[$i]}"; then
      echo "$i"
      return 0
    fi
  done

  return 1
}

target_within_region() {
  local index="$1"
  local r1="$2"
  local c1="$3"
  local r2="$4"
  local c2="$5"

  (( target_r1[index] >= r1 &&
     target_c1[index] >= c1 &&
     target_r2[index] <= r2 &&
     target_c2[index] <= c2 ))
}

can_split_row() {
  local r1="$1"
  local c1="$2"
  local r2="$3"
  local c2="$4"
  local boundary="$5"
  local i has_top=0 has_bottom=0

  for ((i = 0; i < target_count; i++)); do
    target_within_region "$i" "$r1" "$c1" "$r2" "$c2" || continue

    if (( target_r2[i] <= boundary )); then
      has_top=1
      continue
    fi

    if (( target_r1[i] > boundary )); then
      has_bottom=1
      continue
    fi

    return 1
  done

  (( has_top == 1 && has_bottom == 1 ))
}

can_split_col() {
  local r1="$1"
  local c1="$2"
  local r2="$3"
  local c2="$4"
  local boundary="$5"
  local i has_left=0 has_right=0

  for ((i = 0; i < target_count; i++)); do
    target_within_region "$i" "$r1" "$c1" "$r2" "$c2" || continue

    if (( target_c2[i] <= boundary )); then
      has_left=1
      continue
    fi

    if (( target_c1[i] > boundary )); then
      has_right=1
      continue
    fi

    return 1
  done

  (( has_left == 1 && has_right == 1 ))
}

find_split() {
  local r1="$1"
  local c1="$2"
  local r2="$3"
  local c2="$4"
  local orientation_pref boundary best_kind="" best_boundary=0
  local size_a size_b score best_score=999999

  if (( (c2 - c1) >= (r2 - r1) )); then
    orientation_pref="col"
  else
    orientation_pref="row"
  fi

  if [[ "$orientation_pref" == "col" ]]; then
    for ((boundary = c1; boundary < c2; boundary++)); do
      can_split_col "$r1" "$c1" "$r2" "$c2" "$boundary" || continue
      size_a=$((boundary - c1 + 1))
      size_b=$((c2 - boundary))
      score=$((size_a > size_b ? size_a - size_b : size_b - size_a))
      if (( score < best_score )); then
        best_kind="col"
        best_boundary="$boundary"
        best_score="$score"
      fi
    done
    for ((boundary = r1; boundary < r2; boundary++)); do
      can_split_row "$r1" "$c1" "$r2" "$c2" "$boundary" || continue
      size_a=$((boundary - r1 + 1))
      size_b=$((r2 - boundary))
      score=$((size_a > size_b ? size_a - size_b : size_b - size_a))
      if (( score < best_score )); then
        best_kind="row"
        best_boundary="$boundary"
        best_score="$score"
      fi
    done
  else
    for ((boundary = r1; boundary < r2; boundary++)); do
      can_split_row "$r1" "$c1" "$r2" "$c2" "$boundary" || continue
      size_a=$((boundary - r1 + 1))
      size_b=$((r2 - boundary))
      score=$((size_a > size_b ? size_a - size_b : size_b - size_a))
      if (( score < best_score )); then
        best_kind="row"
        best_boundary="$boundary"
        best_score="$score"
      fi
    done
    for ((boundary = c1; boundary < c2; boundary++)); do
      can_split_col "$r1" "$c1" "$r2" "$c2" "$boundary" || continue
      size_a=$((boundary - c1 + 1))
      size_b=$((c2 - boundary))
      score=$((size_a > size_b ? size_a - size_b : size_b - size_a))
      if (( score < best_score )); then
        best_kind="col"
        best_boundary="$boundary"
        best_score="$score"
      fi
    done
  fi

  if [[ -n "$best_kind" ]]; then
    printf '%s %s\n' "$best_kind" "$best_boundary"
    return 0
  fi

  return 1
}

expand_unassigned_cells() {
  local covered i r c
  local -a extra=()

  for ((r = 1; r <= rows; r++)); do
    for ((c = 1; c <= cols; c++)); do
      covered=0
      for ((i = 0; i < target_count; i++)); do
        if (( r >= target_r1[i] && r <= target_r2[i] && c >= target_c1[i] && c <= target_c2[i] )); then
          covered=1
          break
        fi
      done
      if (( covered == 0 )); then
        extra+=("${r},${c}")
      fi
    done
  done

  for i in "${extra[@]}"; do
    add_target_rect "$i"
  done
}

clamp_percent() {
  local value="$1"

  if (( value < 1 )); then
    echo 1
    return 0
  fi

  if (( value > 99 )); then
    echo 99
    return 0
  fi

  echo "$value"
}

split_row() {
  local pane="$1"
  local r1="$2"
  local c1="$3"
  local r2="$4"
  local c2="$5"
  local boundary="$6"
  local top_height bottom_height percent bottom_pane

  top_height=$((boundary - r1 + 1))
  bottom_height=$((r2 - boundary))
  percent=$((bottom_height * 100 / (top_height + bottom_height)))
  percent="$(clamp_percent "$percent")"

  bottom_pane="$(tmux split-window -c "$base_path" -d -v -t "$pane" -p "$percent" -P -F '#{pane_id}')"
  build_region "$pane" "$r1" "$c1" "$boundary" "$c2"
  build_region "$bottom_pane" "$((boundary + 1))" "$c1" "$r2" "$c2"
}

split_col() {
  local pane="$1"
  local r1="$2"
  local c1="$3"
  local r2="$4"
  local c2="$5"
  local boundary="$6"
  local left_width right_width percent right_pane

  left_width=$((boundary - c1 + 1))
  right_width=$((c2 - boundary))
  percent=$((right_width * 100 / (left_width + right_width)))
  percent="$(clamp_percent "$percent")"

  right_pane="$(tmux split-window -c "$base_path" -d -h -t "$pane" -p "$percent" -P -F '#{pane_id}')"
  build_region "$pane" "$r1" "$c1" "$r2" "$boundary"
  build_region "$right_pane" "$r1" "$((boundary + 1))" "$r2" "$c2"
}

build_region() {
  local pane="$1"
  local r1="$2"
  local c1="$3"
  local r2="$4"
  local c2="$5"
  local split_kind boundary

  if region_matches_target "$r1" "$c1" "$r2" "$c2"; then
    return 0
  fi

  if (( r1 == r2 && c1 == c2 )); then
    return 0
  fi

  if read -r split_kind boundary <<<"$(find_split "$r1" "$c1" "$r2" "$c2")"; then
    if [[ "$split_kind" == "col" ]]; then
      split_col "$pane" "$r1" "$c1" "$r2" "$c2" "$boundary"
    else
      split_row "$pane" "$r1" "$c1" "$r2" "$c2" "$boundary"
    fi
    return 0
  fi

  fail "panel configuration is not representable by tmux splits"
}

apply_layout() {
  local window_id="$1"
  local grid="$2"
  local rects="${3:-}"
  local root_pane

  parse_grid "$grid"
  parse_rect_list "$rects"
  expand_unassigned_cells

  root_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  tmux kill-pane -a -t "$root_pane"
  build_region "$root_pane" 1 1 "$rows" "$cols"
  tmux select-pane -t "$root_pane"
  tmux display-message "$PROGRAM: built ${rows}x${cols} with ${target_count} panes"
}

new_window() {
  tmux new-window -c "$base_path" -P -F '#{window_id}'
}

prompt_for_merge() {
  local window_id="$1"
  local grid="$2"
  local source="${3:-}"
  local script_quoted source_quoted command

  script_quoted="$(shell_quote "$0")"
  source_quoted="$(shell_quote "$source")"
  command="$(printf "%s apply %s %s \"%%%%\" %s" "$script_quoted" "$window_id" "$grid" "$source_quoted")"
  tmux command-prompt \
    -I "" \
    -p "Merge cells blank|r1,c1-r2,c2" \
    "run-shell '$command'"
}

prompt_new_window() {
  local source="${1:-}"
  local window_id
  local script_quoted source_quoted command

  resolve_base_path "$source"
  script_quoted="$(shell_quote "$0")"
  source_quoted="$(shell_quote "$source")"
  window_id="$(new_window)"
  command="$(printf "%s prompt-merge %s \"%%%%\" %s" "$script_quoted" "$window_id" "$source_quoted")"
  tmux command-prompt \
    -I "2x2" \
    -p "Mesh grid rowsxcols" \
    "run-shell '$command'"
}

apply_new_window() {
  local grid="$1"
  local rects="${2:-}"
  local path="${3:-}"
  local window_id

  resolve_base_path "$path"
  window_id="$(new_window)"
  apply_layout "$window_id" "$grid" "$rects"
}

menu() {
  local script_quoted selector_quoted source_quoted

  resolve_base_path "${1:-}"
  script_quoted="$(shell_quote "$0")"
  selector_quoted="$(shell_quote "$SELECTOR_SCRIPT")"
  source_quoted="$(shell_quote "${1:-}")"
  tmux display-menu -T "$PROGRAM" \
    "2x2 grid" "" "run-shell '$script_quoted apply-new-window 2x2 \"\" $source_quoted'" \
    "2x3 grid" "" "run-shell '$script_quoted apply-new-window 2x3 \"\" $source_quoted'" \
    "3x3 grid" "" "run-shell '$script_quoted apply-new-window 3x3 \"\" $source_quoted'" \
    "4x4 grid" "" "run-shell '$script_quoted apply-new-window 4x4 \"\" $source_quoted'" \
    "4x4 mouse selector" "" "display-popup -d '#{pane_current_path}' -w 82 -h 30 -E 'SOURCE_PANE=$source_quoted $selector_quoted'" \
    "Custom..." "" "run-shell '$script_quoted prompt-new-window $source_quoted'" \
    "2x3 with center merge" "" "run-shell '$script_quoted apply-new-window 2x3 1,2-2,2 $source_quoted'" \
    "4x4 with 2x2 merge" "" "run-shell '$script_quoted apply-new-window 4x4 2,2-3,3 $source_quoted'"
}

case "${1:-}" in
  apply)
    resolve_base_path "${5:-}"
    apply_layout "$2" "$3" "${4:-}"
    ;;
  apply-new-window)
    apply_new_window "$2" "${3:-}" "${4:-}"
    ;;
  menu)
    menu "${2:-}"
    ;;
  prompt-merge)
    resolve_base_path "${4:-}"
    prompt_for_merge "$2" "$3"
    ;;
  prompt-new-window)
    prompt_new_window "${2:-}"
    ;;
  *)
    fail "unknown command"
    ;;
esac
