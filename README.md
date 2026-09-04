<div align="center">

# 🔍 VSCode Search & Replace

**VS Code-style project-wide search & replace for Neovim** — a floating two-panel
UI with live results, inline diff previews, and ripgrep speed. Built on
[nui-components.nvim](https://github.com/grapp-dev/nui-components.nvim).

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-blueviolet.svg)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)

</div>

<table>
  <tr>
    <th align="center">Search-only to start — press <code>⇄</code> for the full replace panel</th>
  </tr>
  <tr>
    <td align="center">
      <img src="img/preview.png" alt="The Search and Replace float: toggle boxes Aa, ab, .*, I, H around the pattern field, a Replace field with AB and ⇉ boxes, a Files-to-Include filter and a ripgrep results tree with old/new diffs" width="88%">
    </td>
  </tr>
</table>

## ✨ Features

- 🔍 **live ripgrep results** while you type, with an inline old/new diff per match — partial results paint during long scans and `Ctrl+G` switches to **on-demand** search
- ⌨️ **VS Code find-widget look** — `⇄` reveals the replace row without ever resizing the search box; `Aa` case · `ab` whole word · `.*` regex · `I` git-ignored · `H` hidden (scope boxes lit by default; `.git` never searched) · `AB` preserve case
- 🖱️ **mouse-friendly**: click any box, field or result — and **Replace All asks first** with a Yes/No dialog
- 📂 **variants**: whole project, current file, word under cursor / visual selection
- 🎛️ **fully configurable**: every glyph (`icons`) and every key (`keymap`) is overridable; the plugin ships **no global keymaps**

## ⚡️ Requirements

- Neovim ≥ 0.10
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) on your `PATH`
- [Nerd Font](https://www.nerdfonts.com/) _(optional, for tree icons)_

## 📦 Installation

```lua
{
  "hungnguyen1503/nvim-vscode-search-replace",
  dependencies = { "grapp-dev/nui-components.nvim", "MunifTanjim/nui.nvim" },
  cmd = "SearchReplace",
  opts = {}, -- or call setup() by hand, see below
  keys = {
    { "<leader>fs", function() require("vscode-search-replace").open() end, desc = "Search & Replace" },
    { "<leader>sw", mode = { "n", "v" }, function() require("vscode-search-replace").open({ word = true }) end, desc = "Search word / selection" },
    -- More variants (bind any key — the plugin ships no global keymaps):
    --   open({ file = true })                search the current file
    --   open({ file = true, word = true })   search the word under cursor in it
  },
}
```

## ⚙️ Configuration

Works out of the box — override only what you want. Only three things to know about `keymap`:

1. **Partial tables keep the defaults** — listing one key changes just that key.
2. Values are Neovim keycodes (`"<A-c>"`, `"zc"`, `"<leader>gs"`); `false` unbinds an action.
3. Built-in keys that can't be remapped: `Esc` (close), `Enter`/`Space` (activate), tree `j`/`k`, dialog `y`/`n`.

```lua
require("vscode-search-replace").setup({
  debounce = 500,            -- ms before re-searching after you stop typing
  keymap = {
    toggle_case = "<C-c>",   -- remap one box hotkey
    collapse_all = false,    -- unbind it entirely
    close = { "q", "<leader>gs" },  -- close accepts a list
  },
  icons = { case = "CC" },   -- glyphs work the same way: partial = rest default
})
```

<details><summary>Full default settings</summary>

```lua
require("vscode-search-replace").setup({
  -- float anchor: "center" | "top" | "bottom" | "left" | "right"
  position = "center",
  -- width:  <= 1 → fraction of the editor;  > 1 → absolute columns
  width = 0.9,
  -- height: <= 1 → fraction of the editor;  > 1 → absolute lines
  height = 0.85,
  -- ms after the last keystroke before the re-search fires
  debounce = 300,
  -- glyphs; omitted keys keep the defaults below
  icons = {
    tree_expanded = "\u{F107}",   -- chevron before an expanded file row
    tree_collapsed = "\u{F105}",  -- chevron before a collapsed file row
    replace_mode = "⇄",           -- search row box left of Search: show/hide the replace row
    replace_all = "⇉",            -- Replace All box
    case = "Aa",
    whole_word = "ab",
    regex = ".*",
    no_ignore = "I",              -- include git-ignored files (Alt+I)
    hidden = "H",                 -- include hidden files (Alt+H)
    preserve_case = "AB",         -- replacements adopt each match's case
  },
  -- panel bindings; false unbinds; omitted keys keep the defaults below
  keymap = {
    next_panel = "<Tab>",         -- next panel
    prev_panel = "<S-Tab>",       -- previous panel
    field_next = "<A-j>",         -- next text field (Search · Replace · Files to Include)
    field_prev = "<A-k>",         -- previous text field
    to_tree = "<A-l>",            -- focus the results tree
    to_field = "<A-h>",           -- tree -> last field (elsewhere: results tree)
    focus_results = "<CR>",       -- in Search: run search / jump to results tree
    toggle_case = "<A-c>",        -- Aa box
    toggle_whole_word = "<A-w>",  -- ab box
    toggle_regex = "<A-r>",       -- .* box
    toggle_no_ignore = "<A-I>",   -- I box (press Alt+Shift+i)
    toggle_hidden = "<A-H>",      -- H box (press Alt+Shift+h)
    toggle_preserve_case = "<A-p>", -- AB box (replace mode only)
    replace_all = "<C-A-CR>",     -- Replace All (Ctrl+Alt+Enter, asks first)
    search_method = "<C-g>",      -- live <-> on-demand search
    collapse_all = "zc",          -- collapse/expand all files in the tree
    help = "?",                   -- show/hide the keymap overlay
    close = { "q", "<leader>fs", "<leader>S" },  -- Esc always closes, too
  },
})
```

</details>

## 🚀 Usage

Open with `:SearchReplace`, or the Lua API — `open()` searches the whole
project (cwd), `{ file = true }` the current file only, `{ word = true }`
prefills from the visual selection / word under cursor, `{ pattern = "..." }`
starts with a fixed pattern:

```lua
require("vscode-search-replace").open()
require("vscode-search-replace").open({ file = true, word = true })
```

The float opens search-only — `Tab` lands on `⇄`, which reveals the replace
row. Full help: `:h vscode-search-replace` · troubleshooting:
`:checkhealth vscode-search-replace`.

## ⌨️ Keymaps

These are the **defaults** — every one is remappable via
`setup({ keymap = ... })` (see Configuration above); press `?`
inside the panel to see your active bindings.

| Default key                  | Action                                        |
| ---------------------------- | --------------------------------------------- |
| `<Tab>` / `<S-Tab>`          | next / previous panel                         |
| `Alt+j` / `Alt+k`            | next / previous text field                    |
| `Alt+h` / `Alt+l`            | results tree ⇄ fields                         |
| `Enter` / `Space` / click    | activate the focused widget; `Enter` in Search runs the search (on-demand) or jumps to the results tree; in the tree it opens the match |
| `Alt+c` · `Alt+w` · `Alt+r`  | toggle `Aa` match case · `ab` whole word · `.*` regex |
| `Alt+I` · `Alt+H`            | toggle `I` include git-ignored · `H` include hidden (lit by default; `.git` never searched) |
| `Alt+p`                      | toggle `AB` preserve case (replace mode)      |
| `Ctrl+G`                     | switch live ⇄ on-demand search                |
| `Ctrl+Alt+Enter` / click `⇉` | Replace All — asks Yes/No first (`y`/`n`)     |
| `?`                          | show/hide this keymap list (shows your configured keys) |
| `q` / `Esc` / `<leader>fs`   | close                                         |
| `zc`                         | collapse / expand all files in the tree       |

## 🙏 References

- [NuiComponents Showcase](https://nui-components.grapp.dev/docs/showcase) — the
  component library this UI is built on
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — UI primitives
