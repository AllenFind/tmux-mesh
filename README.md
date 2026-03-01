# tmux-mesh

`tmux-mesh` is a tmux plugin for creating a new window from a grid template and, optionally, merging a rectangular set of cells into one larger pane.

New windows and panes inherit the current tmux pane's working directory by default.

Built-in presets:

- `2x2`
- `3x3`
- `Two columns, right stacked`

## Install

With TPM:

```tmux
set -g @plugin 'AllenFind/tmux-mesh'
run '~/.tmux/plugins/tpm/tpm'
```

Or source the plugin file directly:

```tmux
run-shell '/path/to/tmux_plugin/mesh-layout.tmux'
```

## Default Keys

- `prefix + M`: open the layout menu

You can override it:

```tmux
set -g @mesh_layout_menu_key 'g'
```

## Menu Flow

1. Press `prefix + M`
2. Pick one of the built-in presets
3. Use the popup path input, or leave it blank to use the current pane's working directory
4. A new window is created with that path

## Notes

- Merge selection must be a rectangle
- Non-rectangular merges are not supported because tmux panes are built from recursive splits
- Rebuilding an existing window layout would require removing existing panes first; the default workflow creates a fresh window instead
