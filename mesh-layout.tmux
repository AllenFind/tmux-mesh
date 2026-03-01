run-shell '
current_file="#{current_file}"
current_dir="${current_file%/*}"
script="$current_dir/scripts/mesh-layout.sh"
menu_key="$(tmux show-option -gqv @mesh_layout_menu_key)"
menu_key="${menu_key:-M}"
tmux bind-key "$menu_key" run-shell "$script menu \"#{pane_id}\""
'
