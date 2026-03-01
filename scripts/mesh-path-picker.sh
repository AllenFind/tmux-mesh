#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT_SCRIPT="$SCRIPT_DIR/mesh-layout.sh"
LOG_FILE="/tmp/tmux-mesh.log"
PRESET_GRID="${1:-${PRESET_GRID:-}}"
PRESET_RECTS="${2:-${PRESET_RECTS:-}}"
PRESET_LABEL="${3:-${PRESET_LABEL:-Preset}}"
SOURCE_PANE="${4:-${SOURCE_PANE:-}}"

popup_width=82
popup_height=18
path_input=""
default_path=""
status_message="editing path"
declare -a autocomplete_matches=()
autocomplete_index=-1

cleanup() {
  printf '\033[?25h\033[0m\033[49m'
  stty sane 2>/dev/null || true
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

  printf '%s' "${text:0:max_width-3}..."
}

current_path_display() {
  printf '%s' "$path_input"
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

read_event() {
  local first second third

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

draw_screen() {
  local path_label="path: "
  local path_value trimmed
  local visible_count=8 start_index=0 end_index=0 has_more=0 index suggestion

  path_value="$(current_path_display)"
  trimmed="$(trim_display_text "$path_value" 62)"

  if (( autocomplete_index >= 0 && autocomplete_index >= visible_count )); then
    start_index=$((autocomplete_index - visible_count + 1))
  fi
  end_index=$((start_index + visible_count))
  if (( ${#autocomplete_matches[@]} > end_index )); then
    has_more=1
  fi

  printf '\033[2J\033[H\033[?25l'
  printf '\033[49m\033[38;5;255m'
  printf '\033[2;3Hblank = current pane path'
  printf '\033[3;3H%s%s' "$path_label" "$trimmed"

  for ((index = start_index; index < ${#autocomplete_matches[@]} && index < end_index; index++)); do
    suggestion="$(trim_display_text "${autocomplete_matches[$index]}" 72)"
    printf '\033[%s;3H' "$((5 + index - start_index))"
    if (( index == autocomplete_index )); then
      printf '\033[48;5;250m\033[38;5;16m%-72s' "$suggestion"
      printf '\033[49m\033[38;5;255m'
    else
      printf '%-72s' "$suggestion"
    fi
  done

  if (( has_more == 1 )); then
    printf '\033[14;3Hmore...'
  fi
  printf '\033[3;%sH\033[?25h' "$((3 + ${#path_label} + ${#trimmed}))"
  printf '\033[0m'
}

create_layout() {
  local target_path create_command

  status_message="creating tmux window"
  draw_screen
  target_path="${path_input:-${SOURCE_PANE:-}}"
  create_command="$(printf "%q apply-new-window %q %q %q" "$LAYOUT_SCRIPT" "${PRESET_GRID:?}" "${PRESET_RECTS:-}" "$target_path")"
  tmux run-shell "if ! $create_command >>$LOG_FILE 2>&1; then tmux display-message 'tmux-mesh: create failed, see /tmp/tmux-mesh.log'; fi"
  exit 0
}

handle_input() {
  local event="$1"

  case "$event" in
    ESC)
      exit 0
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

  draw_screen
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
    handle_input "$event"
  done
}

main "$@"
