#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT_SCRIPT="$SCRIPT_DIR/mesh-layout.sh"
LOG_FILE="/tmp/tmux-mesh.log"

rows=4
cols=4
popup_width=82
cell_w=6
cell_h=3
grid_left=4
grid_top=3
preview_top=3
preview_w=23
preview_h=11
selection=""
committed=""
drag_start=""
drag_end=""
status_message=""
screen_initialized=0
cursor_row=1
cursor_col=1
anchor=""
cell_style_result=""
cell_label_result=""

preview_left=$((popup_width - grid_left - preview_w))

cleanup() {
  printf '\033[?25h\033[0m\033[49m'
  stty sane 2>/dev/null || true
}

draw_box() {
  local top="$1"
  local left="$2"
  local bottom="$3"
  local right="$4"
  local label="$5"
  local style="${6:-default}"
  local x y width

  width=$((right - left + 1))

  apply_style "$style"

  for ((y = top; y <= bottom; y++)); do
    printf '\033[%s;%sH' "$y" "$left"
    printf '%*s' "$width" ''
  done

  printf '\033[%s;%sH%s' "$top" "$left" "┌"
  for ((x = left + 1; x < right; x++)); do
    printf '\033[%s;%sH─' "$top" "$x"
  done
  printf '\033[%s;%sH%s' "$top" "$right" "┐"

  printf '\033[%s;%sH%s' "$bottom" "$left" "└"
  for ((x = left + 1; x < right; x++)); do
    printf '\033[%s;%sH─' "$bottom" "$x"
  done
  printf '\033[%s;%sH%s' "$bottom" "$right" "┘"

  for ((y = top + 1; y < bottom; y++)); do
    printf '\033[%s;%sH│' "$y" "$left"
    printf '\033[%s;%sH│' "$y" "$right"
  done

  printf '\033[%s;%sH%s' "$(((top + bottom) / 2))" "$((left + 2))" "$label"
  printf '\033[0m'
}

panel_style() {
  local index="$1"
  local styles=(
    "48;5;29;38;5;231"
    "48;5;24;38;5;231"
    "48;5;58;38;5;231"
    "48;5;130;38;5;231"
    "48;5;88;38;5;231"
    "48;5;60;38;5;231"
    "48;5;95;38;5;231"
    "48;5;31;38;5;231"
    "48;5;22;38;5;231"
    "48;5;67;38;5;231"
    "48;5;136;38;5;231"
    "48;5;124;38;5;231"
    "48;5;53;38;5;231"
    "48;5;166;38;5;231"
    "48;5;37;38;5;231"
    "48;5;99;38;5;231"
  )
  echo "${styles[$((index % ${#styles[@]}))]}"
}

apply_style() {
  local style="$1"

  case "$style" in
    cursor)
      printf '\033[48;5;250m\033[38;5;16m'
      ;;
    current)
      printf '\033[48;5;39m\033[38;5;231m'
      ;;
    default)
      printf '\033[49m\033[38;5;255m'
      ;;
    preview-default)
      printf '\033[49m\033[38;5;252m'
      ;;
    panel:*)
      printf '\033[%sm' "${style#panel:}"
      ;;
    *)
      printf '\033[49m\033[38;5;255m'
      ;;
  esac
}

overlay_label() {
  local row="$1"
  local col="$2"
  local top left

  top=$((grid_top + (row - 1) * cell_h))
  left=$((grid_left + (col - 1) * cell_w))

  if (( row == cursor_row && col == cursor_col )); then
    printf '\033[48;5;250m\033[38;5;16m'
    printf '\033[%s;%sH[]' "$((top + 1))" "$((left + 1))"
    printf '\033[0m'
    return 0
  fi

  if [[ -n "$selection" ]]; then
    local sr sc er ec
    IFS='-,' read -r sr sc er ec <<<"$selection"
    if (( row >= sr && row <= er && col >= sc && col <= ec )); then
      printf '\033[48;5;39m\033[38;5;231m'
      printf '\033[%s;%sH++' "$((top + 1))" "$((left + 1))"
      printf '\033[0m'
    fi
  fi
}

draw_preview_frame() {
  local top="$preview_top"
  local left="$preview_left"
  local bottom=$((preview_top + preview_h))
  local right=$((preview_left + preview_w))
  local x y

  printf '\033[1;%sHFinal layout preview' "$left"

  printf '\033[%s;%sH┌' "$top" "$left"
  for ((x = left + 1; x < right; x++)); do
    printf '\033[%s;%sH─' "$top" "$x"
  done
  printf '\033[%s;%sH┐' "$top" "$right"

  printf '\033[%s;%sH└' "$bottom" "$left"
  for ((x = left + 1; x < right; x++)); do
    printf '\033[%s;%sH─' "$bottom" "$x"
  done
  printf '\033[%s;%sH┘' "$bottom" "$right"

  for ((y = top + 1; y < bottom; y++)); do
    printf '\033[%s;%sH│' "$y" "$left"
    printf '\033[%s;%sH│' "$y" "$right"
    printf '\033[%s;%sH' "$y" "$((left + 1))"
    printf '%*s' "$((right - left - 1))" ''
  done
}

clear_region() {
  local top="$1"
  local left="$2"
  local height="$3"
  local width="$4"
  local y

  printf '\033[49m'
  for ((y = 0; y < height; y++)); do
    printf '\033[%s;%sH' "$((top + y))" "$left"
    printf '%*s' "$width" ''
  done
  printf '\033[0m'
}

cell_style_and_label() {
  local row="$1"
  local col="$2"
  local sr=0 sc=0 er=0 ec=0
  local panel_index cr1 cc1 cr2 cc2 panel_style_code

  cell_style_result="default"
  cell_label_result="${row},${col}"

  if [[ -n "$committed" ]]; then
    IFS='|' read -r -a committed_items <<<"$committed"
    for panel_index in "${!committed_items[@]}"; do
      IFS='-,' read -r cr1 cc1 cr2 cc2 <<<"${committed_items[$panel_index]}"
      if (( row >= cr1 && row <= cr2 && col >= cc1 && col <= cc2 )); then
        panel_style_code="$(panel_style "$panel_index")"
        cell_style_result="panel:$panel_style_code"
        cell_label_result="P$((panel_index + 1))"
        return 0
      fi
    done
  fi

  if [[ -n "$selection" ]]; then
    IFS='-,' read -r sr sc er ec <<<"$selection"
    if (( row >= sr && row <= er && col >= sc && col <= ec )); then
      cell_style_result="current"
    fi
  fi

  if (( row == cursor_row && col == cursor_col )) && [[ "$cell_style_result" == "default" ]]; then
    cell_style_result="cursor"
  fi
}

draw_cell() {
  local row="$1"
  local col="$2"
  local top left bottom right style label

  top=$((grid_top + (row - 1) * cell_h))
  left=$((grid_left + (col - 1) * cell_w))
  bottom=$((top + cell_h - 1))
  right=$((left + cell_w - 1))

  cell_style_and_label "$row" "$col"
  style="$cell_style_result"
  label="$cell_label_result"
  draw_box "$top" "$left" "$bottom" "$right" "$label" "$style"
  overlay_label "$row" "$col"
}

draw_grid() {
  local row col

  for ((row = 1; row <= rows; row++)); do
    for ((col = 1; col <= cols; col++)); do
      draw_cell "$row" "$col"
    done
  done
}

draw_preview() {
  local panel_index cr1 cc1 cr2 cc2 panel_style_code sr sc er ec

  clear_region "$preview_top" "$preview_left" $((preview_h + 1)) $((preview_w + 1))
  draw_preview_frame

  if [[ -n "$committed" ]]; then
    IFS='|' read -r -a committed_items <<<"$committed"
    for panel_index in "${!committed_items[@]}"; do
      IFS='-,' read -r cr1 cc1 cr2 cc2 <<<"${committed_items[$panel_index]}"
      panel_style_code="$(panel_style "$panel_index")"
      fill_preview_rect "$cr1" "$cc1" "$cr2" "$cc2" "P$((panel_index + 1))" "panel:$panel_style_code"
    done
  fi

  if [[ -n "$selection" ]]; then
    IFS='-,' read -r sr sc er ec <<<"$selection"
    fill_preview_rect "$sr" "$sc" "$er" "$ec" "NEW" "current"
  fi
}

draw_info() {
  clear_region 17 4 2 100
  printf '\033[17;4Hmove:HJKL/arrows  select:v  commit:Enter/a  create:c  cancel:q'
  printf '\033[18;4Hstatus: %s' "${status_message:-ready}"
  printf '\033[0m\033[?25l'
}

draw_static_screen() {
  printf '\033[2J\033[H\033[49m'
  printf '\033[1;1H'
  printf '%*s' "$popup_width" ''
  printf '\033[1;4HPanel Selector'
  draw_preview_frame
  printf '\033[0m'
}

preview_coords() {
  local row="$1"
  local col="$2"
  local row2="$3"
  local col2="$4"
  local top left bottom right inner_w inner_h

  inner_w=$((preview_w - 1))
  inner_h=$((preview_h - 1))
  top=$((preview_top + 1 + (row - 1) * inner_h / rows))
  left=$((preview_left + 1 + (col - 1) * inner_w / cols))
  bottom=$((preview_top + (row2 * inner_h / rows)))
  right=$((preview_left + (col2 * inner_w / cols)))

  printf '%s %s %s %s' "$top" "$left" "$bottom" "$right"
}

fill_preview_rect() {
  local row="$1"
  local col="$2"
  local row2="$3"
  local col2="$4"
  local label="$5"
  local style="$6"
  local top left bottom right x y label_row label_col

  read -r top left bottom right <<<"$(preview_coords "$row" "$col" "$row2" "$col2")"
  apply_style "$style"

  for ((y = top; y <= bottom; y++)); do
    printf '\033[%s;%sH' "$y" "$left"
    printf '%*s' "$((right - left + 1))" ''
  done

  for ((x = left; x <= right; x++)); do
    printf '\033[%s;%sH─' "$top" "$x"
    printf '\033[%s;%sH─' "$bottom" "$x"
  done
  for ((y = top; y <= bottom; y++)); do
    printf '\033[%s;%sH│' "$y" "$left"
    printf '\033[%s;%sH│' "$y" "$right"
  done
  printf '\033[%s;%sH┌' "$top" "$left"
  printf '\033[%s;%sH┐' "$top" "$right"
  printf '\033[%s;%sH└' "$bottom" "$left"
  printf '\033[%s;%sH┘' "$bottom" "$right"

  label_row=$(((top + bottom) / 2))
  label_col=$(((left + right - ${#label}) / 2))
  if (( label_col < left + 1 )); then
    label_col=$((left + 1))
  fi
  printf '\033[%s;%sH%s' "$label_row" "$label_col" "$label"
  printf '\033[0m'
}

normalize_selection() {
  local start="$1"
  local finish="$2"
  local sr sc er ec

  IFS=, read -r sr sc <<<"$start"
  IFS=, read -r er ec <<<"$finish"

  if (( sr > er )); then
    local tmp="$sr"
    sr="$er"
    er="$tmp"
  fi

  if (( sc > ec )); then
    local tmp="$sc"
    sc="$ec"
    ec="$tmp"
  fi

  selection="${sr},${sc}-${er},${ec}"
}

update_selection_from_anchor() {
  if [[ -n "$anchor" ]]; then
    normalize_selection "$anchor" "${cursor_row},${cursor_col}"
  fi
}

move_cursor() {
  local dr="$1"
  local dc="$2"
  local old_row="$cursor_row"
  local old_col="$cursor_col"
  local old_selection="$selection"

  cursor_row=$((cursor_row + dr))
  cursor_col=$((cursor_col + dc))

  if (( cursor_row < 1 )); then
    cursor_row=1
  elif (( cursor_row > rows )); then
    cursor_row="$rows"
  fi

  if (( cursor_col < 1 )); then
    cursor_col=1
  elif (( cursor_col > cols )); then
    cursor_col="$cols"
  fi

  update_selection_from_anchor

  if [[ -n "$anchor" && "$selection" != "$old_selection" ]]; then
    draw_grid
    draw_preview
    draw_info
    return 0
  fi

  draw_cell "$old_row" "$old_col"
  draw_cell "$cursor_row" "$cursor_col"
  draw_info
}

toggle_anchor() {
  if [[ -n "$anchor" ]]; then
    anchor=""
    selection=""
    status_message="selection cleared"
    draw_grid
    draw_preview
    draw_info
    return 0
  fi

  anchor="${cursor_row},${cursor_col}"
  selection="${cursor_row},${cursor_col}-${cursor_row},${cursor_col}"
  status_message="selection started"
  draw_grid
  draw_preview
  draw_info
}

draw_screen() {
  if (( screen_initialized == 0 )); then
    draw_static_screen
    screen_initialized=1
  fi

  draw_grid
  draw_preview
  draw_info
}

read_event() {
  local first second third fourth sixth

  IFS= read -rsn1 first || return 1

  if [[ "$first" != $'\033' ]]; then
    printf '%s' "$first"
    return 0
  fi

  IFS= read -rsn1 second || return 1
  if [[ "$second" != "[" ]]; then
    printf 'ESC'
    return 0
  fi

  IFS= read -rsn1 third || return 1
  case "$third" in
    A|B|C|D)
      printf 'ARROW_%s' "$third"
      ;;
    *)
      printf 'ESC[%s' "$third"
      ;;
  esac
}

selection_overlaps_committed() {
  local rect="$1"
  local sr sc er ec cr1 cc1 cr2 cc2 item

  [[ -n "$rect" ]] || return 1
  IFS='-,' read -r sr sc er ec <<<"$rect"

  [[ -n "$committed" ]] || return 1

  IFS='|' read -r -a committed_items <<<"$committed"
  for item in "${committed_items[@]}"; do
    IFS='-,' read -r cr1 cc1 cr2 cc2 <<<"$item"
    if (( sr <= cr2 && er >= cr1 && sc <= cc2 && ec >= cc1 )); then
      return 0
    fi
  done

  return 1
}

drop_overlapping_committed() {
  local rect="$1"
  local sr sc er ec cr1 cc1 cr2 cc2 item
  local -a kept=()
  local old_ifs="$IFS"

  [[ -n "$committed" ]] || return 0
  IFS='-,' read -r sr sc er ec <<<"$rect"

  IFS='|' read -r -a committed_items <<<"$committed"
  for item in "${committed_items[@]}"; do
    IFS='-,' read -r cr1 cc1 cr2 cc2 <<<"$item"
    if (( sr <= cr2 && er >= cr1 && sc <= cc2 && ec >= cc1 )); then
      continue
    fi
    kept+=("$item")
  done

  if ((${#kept[@]} == 0)); then
    committed=""
  else
    IFS='|'
    committed="${kept[*]}"
  fi

  IFS="$old_ifs"
}

commit_selection() {
  if [[ -z "$selection" ]]; then
    selection="${cursor_row},${cursor_col}-${cursor_row},${cursor_col}"
  fi

  if selection_overlaps_committed "$selection"; then
    drop_overlapping_committed "$selection"
    status_message="overlapping panels replaced"
  fi

  if [[ -n "$committed" ]]; then
    committed="${committed}|${selection}"
  else
    committed="$selection"
  fi

  selection=""
  anchor=""
  status_message="panel added"
  return 0
}

main() {
  local create_command

  trap cleanup EXIT
  stty -echo -icanon time 0 min 1

  draw_screen

  while true; do
    local event
    event="$(read_event)" || break

    case "$event" in
      q|Q|ESC)
        exit 0
        ;;
      h|H|ARROW_D)
        move_cursor 0 -1
        ;;
      j|J|ARROW_B)
        move_cursor 1 0
        ;;
      k|K|ARROW_A)
        move_cursor -1 0
        ;;
      l|L|ARROW_C)
        move_cursor 0 1
        ;;
      v|V)
        toggle_anchor
        ;;
      a|A)
        commit_selection || true
        draw_screen
        ;;
      c|C)
        if [[ -n "$committed" ]]; then
          status_message="creating tmux window"
          create_command="$(printf "%q apply-new-window 4x4 %q %q" "$LAYOUT_SCRIPT" "$committed" "$PWD")"
          tmux run-shell "if $create_command >>$LOG_FILE 2>&1; then tmux display-message 'tmux-mesh: window created'; else tmux display-message 'tmux-mesh: create failed, see /tmp/tmux-mesh.log'; fi"
          exit 0
        fi
        status_message="add at least one panel first"
        draw_screen
        ;;
      "")
        commit_selection || true
        draw_screen
        ;;
      $'\r'|$'\n')
        commit_selection || true
        draw_screen
        ;;
    esac
  done
}

main "$@"
