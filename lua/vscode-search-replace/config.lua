local M = {}

---@class VscrOpts
---@field position? "center"|"top"|"bottom"|"left"|"right"  float anchor
---@field width? number    -- <=1: fraction of editor columns; >1: absolute columns
---@field height? number   -- <=1: fraction of editor lines; >1: absolute lines
---@field debounce? number -- ms after the last keystroke before re-searching
---@field icons? VscrIcons -- glyph overrides for the tree chevrons and box labels

---@class VscrIcons
---@field tree_expanded? string  -- chevron before an expanded file row (default \u{F107})
---@field tree_collapsed? string -- chevron before a collapsed file row (default \u{F105})
---@field replace_mode? string   -- \u{21C4} box left of Search
---@field replace_all? string    -- \u{21C9} Replace All box
---@field case? string           -- Aa box
---@field whole_word? string     -- ab box
---@field regex? string          -- .* box
---@field no_ignore? string      -- I box (include git-ignored files, Alt+I)
---@field hidden? string         -- H box (include hidden files, Ctrl+H)
---@field preserve_case? string  -- AB box
local defaults = {
    position = "center",
    width = 0.9,
    height = 0.85,
    debounce = 300,
    icons = {
        tree_expanded = "\u{F107}",
        tree_collapsed = "\u{F105}",
        replace_mode = "\u{21C4}", -- ⇄
        replace_all = "\u{21C9}", -- ⇉
        case = "Aa",
        whole_word = "ab",
        regex = ".*",
        no_ignore = "I",
        hidden = "H",
        preserve_case = "AB",
    },
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
    if type(options.icons) ~= "table" then
        vim.notify('vscode-search-replace: "icons" must be a table, using defaults', vim.log.levels.WARN)
        options.icons = vim.deepcopy(defaults.icons)
    else
        for key, def in pairs(defaults.icons) do
            if options.icons[key] ~= nil and type(options.icons[key]) ~= "string" then
                vim.notify(
                    ('vscode-search-replace: icon "%s" must be a string, using default'):format(key),
                    vim.log.levels.WARN
                )
                options.icons[key] = def
            end
        end
    end
end

function M.get()
    return options
end

return M
