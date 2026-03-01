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
input_mode=0
path_input=""
default_path=""
declare -a autocomplete_matches=()
autocomplete_index=-1
cell_style_result=""
cell_label_result=""
last_info_signature=""

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

repeat_char() {
  local char="$1"
  local count="$2"
  local index

  for ((index = 0; index < count; index++)); do
    printf '%s' "$char"
  done
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

trim_display_text() {
  local text="$1"
  local max_width="$2"

  if (( ${#text} <= max_width )); then
    printf '%s' "$text"
    return 0
  fi

  if (( max_width <= 3 )); then
    printf '%.*s' "$max_width" "$text"
    return 0
  fi

  printf '%s...' "${text:0:max_width-3}"
}

current_path_display() {
  if [[ -n "$path_input" ]]; then
    printf '%s' "$path_input"
    return 0
  fi

  printf ''
}

reset_autocomplete() {
  autocomplete_matches=()
  autocomplete_index=-1
}

common_prefix() {
  local prefix="$1"
  shift
  local value index

  for value in "$@"; do
    index=0
    while (( index < ${#prefix} && index < ${#value} )) && [[ "${prefix:index:1}" == "${value:index:1}" ]]; do
      ((index += 1))
    done
    prefix="${prefix:0:index}"
  done

  printf '%s' "$prefix"
}

path_lookup_seed() {
  local raw="${path_input:-}"

  if [[ -z "$raw" ]]; then
    printf '%s/' "$default_path"
    return 0
  fi

  case "$raw" in
    "~")
      printf '%s/' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s' "$HOME" "${raw#"~/"}"
      ;;
    /*)
      printf '%s' "$raw"
      ;;
    *)
      printf '%s/%s' "$default_path" "$raw"
      ;;
  esac
}

display_path_for_match() {
  local match="$1"
  local raw="${path_input:-}"

  case "$raw" in
    "~"|"~/"*)
      if [[ "$match" == "$HOME" ]]; then
        printf '%s\n' "~"
        return 0
      fi
      if [[ "$match" == "$HOME/"* ]]; then
        printf '~/%s\n' "${match#"$HOME"/}"
        return 0
      fi
      ;;
  esac

  printf '%s\n' "$match"
}

visible_directory_matches() {
  local seed="$1"
  local match name

  while IFS= read -r match; do
    name="${match%/}"
    name="${name##*/}"
    [[ "$name" == .* ]] && continue
    printf '%s\n' "$match"
  done < <(compgen -d -- "$seed" | sort -u)
}

complete_path_input() {
  local seed common count

  seed="$(path_lookup_seed)"
  if (( ${#autocomplete_matches[@]} == 0 || autocomplete_index == -1 )); then
    mapfile -t autocomplete_matches < <(visible_directory_matches "$seed")
    count="${#autocomplete_matches[@]}"

    if (( count == 0 )); then
      return 0
    fi

    if (( count == 1 )); then
      autocomplete_index=0
      path_input="$(display_path_for_match "${autocomplete_matches[0]}")"
      return 0
    fi

    common="$(common_prefix "${autocomplete_matches[0]}" "${autocomplete_matches[@]:1}")"
    if [[ -n "$common" && "$common" != "$seed" ]]; then
      path_input="$(display_path_for_match "$common")"
      reset_autocomplete
      mapfile -t autocomplete_matches < <(visible_directory_matches "$common")
      count="${#autocomplete_matches[@]}"
      if (( count == 0 )); then
        return 0
      fi
    fi
  fi

  count="${#autocomplete_matches[@]}"
  (( count > 0 )) || return 0
  autocomplete_index=$(((autocomplete_index + 1) % count))
  path_input="$(display_path_for_match "${autocomplete_matches[$autocomplete_index]}")"
}

handle_path_input() {
  local event="$1"

  case "$event" in
    ESC)
      input_mode=0
      reset_autocomplete
      status_message="path input closed"
      ;;
    $'\177'|$'\b')
      if [[ -n "$path_input" ]]; then
        path_input="${path_input%?}"
      fi
      reset_autocomplete
      status_message="editing path"
      ;;
    $'\t')
      complete_path_input
      ;;
    $'\r'|$'\n'|"")
      input_mode=0
      create_layout
      return 0
      ;;
    *)
      if [[ "$event" =~ ^[[:print:]]$ ]]; then
        path_input+="$event"
        reset_autocomplete
        status_message="editing path"
      fi
      ;;
  esac

  draw_info
}

draw_info() {
  local path_label path_value suggestion line trimmed cursor_col
  local visible_count=10 start_index=0 end_index=0 index has_more=0
  local signature="" info_width status_width

  path_label="path: "
  path_value="$(current_path_display)"
  info_width=$((popup_width - 4))
  status_width=$((info_width - 8))
  trimmed="$(trim_display_text "$path_value" "$((info_width - ${#path_label}))")"
  cursor_col=$((2 + ${#path_label} + ${#trimmed}))

  if (( autocomplete_index >= 0 && autocomplete_index >= visible_count )); then
    start_index=$((autocomplete_index - visible_count + 1))
  fi
  end_index=$((start_index + visible_count))
  if (( ${#autocomplete_matches[@]} > end_index )); then
    has_more=1
  fi

  signature="status=${status_message:-ready};path=${path_input};mode=$input_mode;index=$autocomplete_index;start=$start_index;more=$has_more"
  for ((index = start_index; index < ${#autocomplete_matches[@]} && index < end_index; index++)); do
    signature+=$'\n'"${autocomplete_matches[$index]}"
  done

  if [[ "$signature" == "$last_info_signature" ]]; then
    if (( input_mode == 1 )); then
      printf '\033[22;%sH\033[?25h' "$cursor_col"
    else
      printf '\033[?25l'
    fi
    return 0
  fi
  last_info_signature="$signature"

  clear_region 17 2 14 "$info_width"
  printf '\033[17;2HMove HJKL/arrows  Mark v  Add a  Path o  Complete Tab'
  printf '\033[18;2HCreate Enter/c  Cancel Esc'
  printf '\033[19;2H'
  repeat_char "─" "$info_width"
  printf '\033[20;2Hstatus: %s' "$(trim_display_text "${status_message:-ready}" "$status_width")"
  printf '\033[21;2H'
  repeat_char "─" "$info_width"
  printf '\033[22;2H%s%s' "$path_label" "$trimmed"
  if [[ -z "$path_input" ]]; then
    trimmed="$(trim_display_text "(blank uses $default_path)" "$((info_width - ${#path_label}))")"
    printf '\033[23;2H%s' "$trimmed"
  fi

  if (( input_mode == 1 )); then
    printf '\033[22;%sH' "$cursor_col"
    printf '\033[?25h'
  else
    printf '\033[?25l'
  fi

  line=24
  for ((index = start_index; index < ${#autocomplete_matches[@]} && index < end_index; index++)); do
    suggestion="${autocomplete_matches[$index]}"
    trimmed="$(trim_display_text "$suggestion" 72)"
    if (( index == autocomplete_index )); then
      printf '\033[48;5;250m\033[38;5;16m'
      printf '\033[%s;2H  %-72s' "$line" "$trimmed"
      printf '\033[0m'
    else
      printf '\033[%s;2H  %s' "$line" "$trimmed"
    fi
    ((line += 1))
  done

  if (( has_more == 1 )); then
    printf '\033[%s;2H  ....' "$line"
  fi

  printf '\033[0m'
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

  if ! IFS= read -rsn1 -t 0.05 second; then
    printf 'ESC'
    return 0
  fi
  if [[ "$second" != "[" ]]; then
    printf 'ESC'
    return 0
  fi

  if ! IFS= read -rsn1 -t 0.05 third; then
    printf 'ESC'
    return 0
  fi
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

create_layout() {
  local create_command target_path

  if [[ -z "$committed" ]]; then
    status_message="add at least one panel first"
    draw_screen
    return 1
  fi

  status_message="creating tmux window"
  draw_info
  target_path="${path_input:-${SOURCE_PANE:-}}"
  create_command="$(printf "%q apply-new-window 4x4 %q %q" "$LAYOUT_SCRIPT" "$committed" "$target_path")"
  tmux run-shell "if ! $create_command >>$LOG_FILE 2>&1; then tmux display-message 'tmux-mesh: create failed, see /tmp/tmux-mesh.log'; fi"
  exit 0
}

main() {
  trap cleanup EXIT
  stty -echo -icanon time 0 min 1
  if [[ -n "${SOURCE_PANE:-}" ]]; then
    default_path="$(tmux display-message -p -t "$SOURCE_PANE" '#{pane_current_path}' 2>/dev/null || pwd)"
  else
    default_path="$(pwd)"
  fi

  draw_screen

  while true; do
    local event
    event="$(read_event)" || break

    if (( input_mode == 1 )); then
      handle_path_input "$event"
      continue
    fi

    case "$event" in
      ESC)
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
      o|O|p|P)
        input_mode=1
        reset_autocomplete
        status_message="editing path"
        draw_info
        ;;
      c|C)
        create_layout || true
        ;;
      "")
        if [[ -n "$selection" || -z "$committed" ]]; then
          commit_selection || true
          draw_screen
        else
          create_layout || true
        fi
        ;;
      $'\r'|$'\n')
        if [[ -n "$selection" || -z "$committed" ]]; then
          commit_selection || true
          draw_screen
        else
          create_layout || true
        fi
        ;;
    esac
  done
}

main "$@"
