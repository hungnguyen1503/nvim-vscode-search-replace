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
end)
