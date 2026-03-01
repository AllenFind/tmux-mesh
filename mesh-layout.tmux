#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$CURRENT_DIR/scripts/mesh-layout.sh"
SELECTOR="$CURRENT_DIR/scripts/mesh-selector.sh"

menu_key="$(tmux show-option -gqv @mesh_layout_menu_key)"
prompt_key="$(tmux show-option -gqv @mesh_layout_prompt_key)"

menu_key="${menu_key:-M}"
prompt_key="${prompt_key:-m}"

tmux bind-key "$menu_key" run-shell "$SCRIPT menu"
tmux bind-key "$prompt_key" display-popup -d "#{pane_current_path}" -w 82 -h 23 -E "$SELECTOR"
