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
    <th align="center">Live search with inline red/green diff preview</th>
  </tr>
  <tr>
    <td align="center">
      <img src="img/preview.png" alt="The Search and Replace float: pattern and replacement fields, case and regex toggles, Files-to-Include filter, and a ripgrep results tree showing every match with its old and new line" width="88%">
    </td>
  </tr>
</table>

## ✨ Features

- 🔍 live debounced results while you type (ripgrep)
- 🎨 inline red/green diff preview per match, with `\1`–`\9` capture references
- 🔘 `Aa` case / `.*` regex toggles, Files-to-Include filter
- 📂 current-file and word-under-cursor / visual-selection search variants
- ⚡ `<CR>` jumps straight to the match · `<C-R>` replaces everywhere
- ⌨️ panel navigation with `Alt+h/j/k/l` — no plugin keymaps stolen from you

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
      "<leader>S",
      function()
        require("vscode-search-replace").open()
      end,
      desc = "Search & Replace",
    },
  },
}
```

## ⚙️ Configuration

```lua
require("vscode-search-replace").setup({
  position = "center", -- "center" | "top" | "bottom" | "left" | "right"
  width = 0.9, -- <=1: fraction of the editor; >1: absolute columns
  height = 0.85, -- <=1: fraction of the editor; >1: absolute lines
  debounce = 300, -- ms after the last keystroke before re-searching
})
```

## 🚀 Usage

Open with `:SearchReplace` (`:h vscode-search-replace` for the full help), or
call the Lua API — `opts = {}` searches the whole project (cwd), `{ file = true }`
the current file only, `{ word = true }` prefills the pattern from the visual
selection / word under cursor and searches immediately:

```lua
require("vscode-search-replace").open()
require("vscode-search-replace").open({ file = true, word = true })
```

Inside the float:

| Key               | Action                      |
| ----------------- | --------------------------- |
| `<Esc>` / `q`     | close                       |
| `<CR>`            | jump to match               |
| `<C-R>`           | Replace All                 |
| `Alt+h` / `Alt+l` | switch panel column         |
| `Alt+j` / `Alt+k` | next / previous panel       |

Troubleshooting: `:checkhealth vscode-search-replace`

## 🧪 Development

The test suite runs headless on mini.test (same harness as `flash.nvim`):

```sh
nvim -l tests/minit.lua --minitest
```

## 🙏 References

- [NuiComponents Showcase](https://nui-components.grapp.dev/docs/showcase) — the
  component library this UI is built on
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — UI primitives
