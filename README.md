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
    <th align="center">Search-only to start — the toggle boxes fill while active; press <code>⇄</code> for the full panel</th>
  </tr>
  <tr>
    <td align="center">
      <img src="img/preview.png" alt="The Search and Replace float in replace mode: the ⇄ toggle box left of the fixed-width pattern field, then Aa, ab, .*, I and H boxes — active toggles filled — plus the Replace field with the AB preserve-case and ⇉ Replace All icon boxes, the Files-to-Include filter and a ripgrep results tree showing every match and its old/new line" width="88%">
    </td>
  </tr>
</table>

## ✨ Features

- 🔍 **live results** while you type, powered by ripgrep
- 📈 **streamed on huge repos**: partial results paint during a 10–30 s scan,
  `Ctrl+G` switches to **on-demand** search where the scan starts only on `Enter`
- ⌨️ **VS Code-style toggle boxes** — `⇄` replace mode · `Aa` match case · `ab` whole word · `.*` regex · plus fzf-style `I` (include git-ignored files) and `H` (include hidden files)
- 🪟 **search-only to start**; `Tab` off the search field lands on `⇄` — activating it reveals the replace row and focuses the replace field without ever resizing the search box; `Enter` in the search field jumps to the results tree
- 🖱️ **mouse-friendly**: every box, field and button is clickable
- ✅ **Replace All asks first** with a Yes/No dialog before touching any file
- 📂 **search variants** for the current file and the word under cursor / visual selection
- 🧭 **panel navigation on `Alt+h/j/k/l`** — no plugin keymaps stolen from you
- 🔧 **every glyph is configurable** via the `icons` table in `setup()`

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
    {
      "<leader>fs",
      mode = "n",
      function()
        require("vscode-search-replace").open()
      end,
      desc = "Search & Replace",
    },
    {
      "<leader>sw",
      mode = { "n", "v" },
      function()
        require("vscode-search-replace").open({ word = true })
      end,
      desc = "Search word under cursor / selection",
    },
    -- Variants (bind any key yourself — the plugin ships no global keymaps):
    -- current-file search for the word under cursor:
    --   { "<leader>ff", function() require("vscode-search-replace").open({ file = true, word = true }) end, desc = "Search word in current file" },
  },
}
```

## ⚙️ Configuration

**nvim-vscode-search-replace** works out of the box. Please refer to the default settings below.

<details><summary>Default Settings</summary>

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
  -- every glyph is overridable; omitted keys keep the defaults below
  icons = {
    tree_expanded = "\u{F107}", -- chevron before an expanded file row
    tree_collapsed = "\u{F105}", -- chevron before a collapsed file row
    replace_mode = "⇄", -- search row box left of Search: show/hide the replace row
    replace_all = "⇉", -- Replace All box
    case = "Aa",
    whole_word = "ab",
    regex = ".*",
    no_ignore = "I", -- search row box: include git-ignored files (Alt+i)
    hidden = "H", -- search row box: include hidden files (Ctrl+h)
    preserve_case = "AB", -- replace row box: replacements adopt each match's case
})
```

</details>

## 🚀 Usage

Open with `:SearchReplace` (`:h vscode-search-replace` for the full help), or
call the Lua API — `opts = {}` searches the whole project (cwd), `{ file = true }`
the current file only, `{ word = true }` prefills the pattern from the visual
selection / word under cursor and searches immediately:

```lua
require("vscode-search-replace").open()
require("vscode-search-replace").open({ file = true, word = true })
```

The float opens in search-only mode. `Tab` from the search field stops on the
`⇄` box (left of Search); `Enter`/`Space`/click reveals the replace row — the
replace field with the `AB` and `⇉` boxes at its right — and drops the cursor
into the replace field. From there `Tab` keeps walking in visual order
(`AB` → `⇉` → Files to Include → results tree), and `Enter` in the search
field runs the pending search (on-demand mode) or jumps straight to the
results tree (live mode). `Alt+j`/`Alt+k` hop directly
between the three text fields (Search · Replace · Files to Include).

Troubleshooting: `:checkhealth vscode-search-replace`

## ⌨️ Keymaps

Every panel is reachable — `Tab`/`Shift+Tab` to walk, `Alt+j`/`Alt+k` to hop
between text fields, `Enter`/`Space` or a mouse click to activate — and the
`Alt` hotkeys work from wherever focus is. Press `?` inside the float to see
this list.

| Keymap                | Mode  | Description                                      |
| --------------------- | ----- | ------------------------------------------------ |
| `<Tab>` / `<S-Tab>`   | n/i   | next / previous panel                            |
| `Alt+j` / `Alt+k`         | n/i   | next / previous text field (Search · Replace · Files to Include) |
| `Alt+h` / `Alt+l`     | n/i   | sidebar ⇄ results tree                           |
| `Enter` / `Space` / click | n/i | in Search: run search (on-demand) or jump to results tree · else activate focused widget · jump to selected match |
| `Alt+c`               | n/i   | toggle `Aa` — match case                         |
| `Alt+w`               | n/i   | toggle `ab` — match whole word                   |
| `Alt+r`               | n/i   | toggle `.*` — regular expression                 |
| `Alt+i`               | n/i   | toggle `I` — include git-ignored files           |
| `Ctrl+h`              | n/i   | toggle `H` — include hidden files                |
| `Ctrl+g`              | n/i   | switch live ⇄ on-demand search                   |
| `Alt+p`               | n/i   | toggle `AB` — preserve case (replace mode)       |
| `Ctrl+Alt+Enter`      | n/i   | Replace All — asks Yes/No first                  |
| `y` / `n` · `Enter` / `Esc` | n | answer the Replace All dialog (or click `Yes`/`No`) |
| `?`                   | n     | show/hide the keymap help                        |
| `q` / `Esc` / `<leader>fs` | n/i | close                                         |
| `zc`                  | n     | collapse all files in the tree (press again to expand) |

## 🙏 References

- [NuiComponents Showcase](https://nui-components.grapp.dev/docs/showcase) — the
  component library this UI is built on
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — UI primitives
