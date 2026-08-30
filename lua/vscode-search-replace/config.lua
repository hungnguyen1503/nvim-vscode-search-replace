local M = {}

---@class VscrOpts
---@field position? "center"|"top"|"bottom"|"left"|"right"  float anchor
---@field width? number    -- <=1: fraction of editor columns; >1: absolute columns
---@field height? number   -- <=1: fraction of editor lines; >1: absolute lines
---@field debounce? number -- ms after the last keystroke before re-searching
local defaults = {
    position = "center",
    width = 0.9,
    height = 0.85,
    debounce = 300,
}

local options = vim.deepcopy(defaults)

-- nui layout positions: {row, col} percentages of the free space
-- (nui/layout/utils.lua:30-59 — calculate_window_position).
M.POSITIONS = {
    center = "50%", -- scalar = {row="50%", col="50%"}
    top = { row = "0%", col = "50%" },
    bottom = { row = "100%", col = "50%" },
    left = { row = "50%", col = "0%" },
    right = { row = "50%", col = "100%" },
}

function M.setup(opts)
    options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
    if not M.POSITIONS[options.position] then
        vim.notify(
            string.format(
                'vscode-search-replace: unknown position "%s", using "center"',
                tostring(options.position)
            ),
            vim.log.levels.WARN
        )
        options.position = "center"
    end
end

function M.get()
    return options
end

return M
