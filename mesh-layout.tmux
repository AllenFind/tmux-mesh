run-shell '
current_file="#{current_file}"
current_dir="${current_file%/*}"
script="$current_dir/scripts/mesh-layout.sh"
selector="$current_dir/scripts/mesh-selector.sh"
menu_key="$(tmux show-option -gqv @mesh_layout_menu_key)"
prompt_key="$(tmux show-option -gqv @mesh_layout_prompt_key)"
menu_key="${menu_key:-M}"
prompt_key="${prompt_key:-m}"
tmux bind-key "$menu_key" run-shell "$script menu \"#{pane_id}\""
tmux bind-key "$prompt_key" display-popup -d "#{pane_current_path}" -w 82 -h 30 -E "SOURCE_PANE=#{pane_id} \"$selector\""
'
