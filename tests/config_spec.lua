local config = require("vscode-search-replace.config")
local assert = require("luassert")

describe("config", function()
  before_each(function()
    config.setup()
  end)

  it("has the documented defaults", function()
    assert.same("center", config.get().position)
    assert.same(0.9, config.get().width)
    assert.same(0.85, config.get().height)
    assert.same(300, config.get().debounce)
  end)

  it("merges partial options", function()
    config.setup({ position = "left", width = 120 })
    assert.same("left", config.get().position)
    assert.same(120, config.get().width)
    -- untouched options keep defaults
    assert.same(0.85, config.get().height)
    assert.same(300, config.get().debounce)
  end)

  it("resets to defaults on every setup() (no stale keys)", function()
    config.setup({ debounce = 0 })
    assert.same(0, config.get().debounce)
    config.setup({})
    assert.same(300, config.get().debounce)
  end)

  it("warns and falls back to center on unknown position", function()
    local msgs = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg = msg, level = level }
    end
    config.setup({ position = "nowhere" })
    vim.notify = notify

    assert.are.equal(1, #msgs)
    assert.are.equal(vim.log.levels.WARN, msgs[1].level)
    assert.matches("unknown position", msgs[1].msg)
    assert.same("center", config.get().position)
  end)

  it("defines a layout position for every documented anchor", function()
    for _, pos in ipairs({ "center", "top", "bottom", "left", "right" }) do
      assert.is_not_nil(config.POSITIONS[pos])
    end
  end)

  it("defaults the fzf-lua toggle icons to I and H", function()
    assert.same("I", config.get().icons.no_ignore)
    assert.same("H", config.get().icons.hidden)
  end)

  it("has documented icon defaults", function()
    local icons = config.get().icons
    assert.same("Aa", icons.case)
    assert.same("ab", icons.whole_word)
    assert.same(".*", icons.regex)
    assert.same("AB", icons.preserve_case)
    assert.same("\u{21C4}", icons.replace_mode)
    assert.same("\u{21C9}", icons.replace_all)
    assert.same("\u{F107}", icons.tree_expanded)
    assert.same("\u{F105}", icons.tree_collapsed)
  end)

  it("merges partial icon overrides", function()
    config.setup({ icons = { case = "CC" } })
    assert.same("CC", config.get().icons.case)
    -- untouched icons keep defaults (deep merge)
    assert.same("ab", config.get().icons.whole_word)
    assert.same("\u{21C4}", config.get().icons.replace_mode)
  end)

  it("resets custom icons on the next setup()", function()
    config.setup({ icons = { case = "CC" } })
    assert.same("CC", config.get().icons.case)
    config.setup({})
    assert.same("Aa", config.get().icons.case)
  end)

  it("accepts an empty-string icon override without warning", function()
    local msgs = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg = msg, level = level }
    end
    config.setup({ icons = { tree_collapsed = "" } })
    vim.notify = notify

    assert.are.equal(0, #msgs)
    assert.same("", config.get().icons.tree_collapsed)
    assert.same("\u{F107}", config.get().icons.tree_expanded)
  end)

  it("warns and keeps defaults for bad icon values", function()
    local msgs = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg = msg, level = level }
    end
    config.setup({ icons = "nope" })
    assert.are.equal(1, #msgs)
    assert.are.equal(vim.log.levels.WARN, msgs[1].level)
    assert.matches('"icons"', msgs[1].msg)
    assert.same("Aa", config.get().icons.case)

    msgs = {}
    -- a non-string value warns; a valid sibling in the same call survives
    config.setup({ icons = { case = 42, regex = "?" } })
    vim.notify = notify
    assert.are.equal(1, #msgs)
    assert.are.equal(vim.log.levels.WARN, msgs[1].level)
    assert.matches('icon "case"', msgs[1].msg)
    assert.same("Aa", config.get().icons.case)
    assert.same("?", config.get().icons.regex)
  end)

  -- Run fn(msgs-captured) around setup and restore vim.notify.
  local function with_notify(fn)
    local msgs = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg = msg, level = level }
    end
    fn()
    vim.notify = notify
    return msgs
  end

  it("has documented keymap defaults", function()
    local km = config.get().keymap
    assert.same("<Tab>", km.next_panel)
    assert.same("<S-Tab>", km.prev_panel)
    assert.same("<A-j>", km.field_next)
    assert.same("<A-k>", km.field_prev)
    assert.same("<A-l>", km.to_tree)
    assert.same("<A-h>", km.to_field)
    assert.same("<CR>", km.focus_results)
    assert.same("<A-c>", km.toggle_case)
    assert.same("<A-w>", km.toggle_whole_word)
    assert.same("<A-r>", km.toggle_regex)
    assert.same("<A-I>", km.toggle_no_ignore)
    assert.same("<A-H>", km.toggle_hidden)
    assert.same("<A-p>", km.toggle_preserve_case)
    assert.same("<C-A-CR>", km.replace_all)
    assert.same("<C-g>", km.search_method)
    assert.same("zc", km.collapse_all)
    assert.same("?", km.help)
    assert.same({ "q", "<leader>fs", "<leader>S" }, km.close)
  end)

  it("merges partial keymap overrides", function()
    config.setup({ keymap = { toggle_case = "<C-c>" } })
    assert.same("<C-c>", config.get().keymap.toggle_case)
    -- untouched keys keep defaults (deep merge)
    assert.same("<A-r>", config.get().keymap.toggle_regex)
    assert.same("zc", config.get().keymap.collapse_all)
  end)

  it("accepts false to unbind a keymap action", function()
    local msgs = with_notify(function()
      config.setup({ keymap = { collapse_all = false } })
    end)
    assert.are.equal(0, #msgs)
    assert.same(false, config.get().keymap.collapse_all)
  end)

  it("normalizes close overrides and rebuilds (never array-merges) them", function()
    config.setup({ keymap = { close = "<leader>cs" } })
    assert.same({ "<leader>cs" }, config.get().keymap.close)

    config.setup({ keymap = { close = { "q", "<leader>cs" } } })
    assert.same({ "q", "<leader>cs" }, config.get().keymap.close)

    config.setup({ keymap = { close = false } })
    assert.same(false, config.get().keymap.close)
  end)

  it("resets custom keys on the next setup()", function()
    config.setup({ keymap = { toggle_case = "<C-c>", collapse_all = false } })
    config.setup({})
    assert.same("<A-c>", config.get().keymap.toggle_case)
    assert.same("zc", config.get().keymap.collapse_all)
    assert.same({ "q", "<leader>fs", "<leader>S" }, config.get().keymap.close)
  end)

  it("warns and keeps defaults for bad keymap values", function()
    local msgs = with_notify(function()
      config.setup({ keymap = "nope" })
    end)
    assert.are.equal(1, #msgs)
    assert.are.equal(vim.log.levels.WARN, msgs[1].level)
    assert.matches('"keymap"', msgs[1].msg)
    assert.same("<A-c>", config.get().keymap.toggle_case)

    msgs = with_notify(function()
      -- a non-string/non-false value warns; valid siblings survive
      config.setup({ keymap = { toggle_case = 42, toggle_regex = "<C-r>" } })
    end)
    assert.are.equal(1, #msgs)
    assert.matches('keymap "toggle_case"', msgs[1].msg)
    assert.same("<A-c>", config.get().keymap.toggle_case)
    assert.same("<C-r>", config.get().keymap.toggle_regex)

    msgs = with_notify(function()
      config.setup({ keymap = { close = { "q", 7 } } })
    end)
    assert.are.equal(1, #msgs)
    assert.matches('keymap "close"', msgs[1].msg)
    assert.same({ "q", "<leader>fs", "<leader>S" }, config.get().keymap.close)

    msgs = with_notify(function()
      config.setup({ keymap = { close = {} } })
    end)
    assert.are.equal(1, #msgs)
    assert.matches('keymap "close"', msgs[1].msg)
    assert.same({ "q", "<leader>fs", "<leader>S" }, config.get().keymap.close)
  end)
end)
