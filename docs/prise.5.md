# NAME

prise - configuration file

# SYNOPSIS

*~/.config/prise/init.lua*

# DESCRIPTION

Prise is configured through a Lua file at **~/.config/prise/init.lua**. This
file must return a UI table that implements the prise UI interface.

If no configuration file is present, prise uses the default tiling UI.

The simplest configuration uses the built-in tiling UI:

```lua
return require("prise").tiling()
```

# SETUP OPTIONS

The tiling UI can be customized by calling **setup()** before returning:

```lua
local ui = require("prise").tiling()

ui.setup({
    theme = { ... },
    status_bar = { ... },
    tab_bar = { ... },
    keybinds = { ... },
})

return ui
```

# THEME

The **theme** table configures colors. All values are hex color strings.

**mode_normal**
:   Color for normal mode indicator in status bar. Default: **#89b4fa**

**mode_command**
:   Color for command mode indicator. Default: **#f38ba8**

**bg1**
:   Darkest background. Default: **#1e1e2e**

**bg2**
:   Dark background. Default: **#313244**

**bg3**
:   Medium background. Default: **#45475a**

**bg4**
:   Lighter background. Default: **#585b70**

**fg_bright**
:   Main text color. Default: **#cdd6f4**

**fg_dim**
:   Secondary text color. Default: **#a6adc8**

**fg_dark**
:   Dark text (on light backgrounds). Default: **#1e1e2e**

**accent**
:   Accent color. Default: **#89b4fa**

**green**
:   Success/connected color. Default: **#a6e3a1**

**yellow**
:   Warning color. Default: **#f9e2af**

Example:

```lua
ui.setup({
    theme = {
        accent = "#ff79c6",
        mode_normal = "#50fa7b",
    },
})
```

# BORDERS

The **borders** table configures pane borders for visual separation.

**enabled**
:   Enable or disable pane borders globally. Default: **false**

**style**
:   Border drawing style. Options: **"none"**, **"single"**, **"double"**, **"rounded"**. Default: **"single"**

**focused_color**
:   Hex color code for the focused pane's border. Default: **#89b4fa**

**unfocused_color**
:   Hex color code for unfocused pane borders. Default: **#585b70**

Available border styles:

- **"single"** - Single-line borders: `┌─┐│└┘`
- **"double"** - Double-line borders: `╔═╗║╚╝`
- **"rounded"** - Rounded corners: `╭─╮│╰╯`
- **"none"** - Invisible borders (for consistent spacing)

Example:

```lua
ui.setup({
    borders = {
        enabled = true,
        style = "double",
        focused_color = "#f38ba8",  -- Pink
        unfocused_color = "#313244", -- Dark gray
    },
})
```

# STATUS BAR

The **status_bar** table configures the bottom status bar.

**enabled**
:   Show the status bar. Default: **true**

Example:

```lua
ui.setup({
    status_bar = { enabled = false },
})
```

# TAB BAR

The **tab_bar** table configures the tab bar.

**show_single_tab**
:   Show the tab bar even with only one tab. Default: **false**

# KEYBINDS

The **keybinds** table configures key bindings.

**leader**
:   Key to enter command mode. Default: **{ key = "k", super = true }**

**palette**
:   Key to open command palette. Default: **{ key = "p", super = true }**

Each keybind is a table with:

- **key**: The key character (e.g., "k", "p")
- **ctrl**: Require Ctrl modifier (boolean)
- **alt**: Require Alt modifier (boolean)
- **shift**: Require Shift modifier (boolean)
- **super**: Require Super/Cmd modifier (boolean)

Example:

```lua
ui.setup({
    keybinds = {
        leader = { key = "a", ctrl = true },
        palette = { key = "Space", ctrl = true, shift = true },
    },
})
```

# DEFAULT KEYBINDS

The tiling UI uses a leader key sequence. Press the leader key (default:
**Super+k**), then one of:

**v**
:   Split horizontal

**s**
:   Split vertical

**Enter**
:   Split auto (horizontal if wide, vertical if tall)

**h**, **j**, **k**, **l**
:   Focus left, down, up, right

**H**, **J**, **K**, **L**
:   Resize pane left, down, up, right

**w**
:   Close pane

**z**
:   Toggle zoom (maximize current pane)

**t**
:   New tab

**c**
:   Close tab

**n**, **p**
:   Next/previous tab

**1-9**
:   Switch to tab by number

**d**, **q**
:   Detach from session

The command palette (**Super+p**) provides fuzzy search for all commands.

# SEE ALSO

[prise(1)](prise.1.html), [prise(7)](prise.7.html)
