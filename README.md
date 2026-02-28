# tmux-mesh

`tmux-mesh` is a tmux plugin for creating a new window from a grid template and, optionally, merging a rectangular set of cells into one larger pane.

The default interaction is a tmux popup with a `4x4` mesh. You drag across cells with the mouse, commit one rectangle at a time as a panel, then create the final tmux window when the layout is ready.

Examples:

- `2x3` for a two-row, three-column mesh
- `4x4` for a sixteen-cell mesh
- Merge `2,2-3,4` to turn that rectangle into one larger pane while the remaining cells stay separate

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

- `prefix + M`: open a menu with common mesh presets
- `prefix + m`: open the `4x4` mouse selector popup

You can override them:

```tmux
set -g @mesh_layout_menu_key 'g'
set -g @mesh_layout_prompt_key 'G'
```

## Mouse Flow

1. Press `prefix + m`
2. Drag across the `4x4` popup grid with the mouse
3. Press `Enter` to save that rectangle as the next panel
4. Repeat until you have the panel groups you want
5. Press `c` to create the new window
6. Press `q` or `Esc` to cancel

Unassigned tiles are turned into single-tile panes when the final window is created.

## Typed Flow

The old typed prompt is still available from the presets menu if you want arbitrary sizes like `2x3` or `6x4`.

## Notes

- Merge selection must be a rectangle
- Non-rectangular merges are not supported because tmux panes are built from recursive splits
- Rebuilding an existing window layout would require removing existing panes first; the default workflow creates a fresh window instead
- The popup selector uses `display-popup`, so it requires tmux 3.2 or newer
