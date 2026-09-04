local M = {}

---@class VscrOpts
---@field position? "center"|"top"|"bottom"|"left"|"right"  float anchor
---@field width? number    -- <=1: fraction of editor columns; >1: absolute columns
---@field height? number   -- <=1: fraction of editor lines; >1: absolute lines
---@field debounce? number -- ms after the last keystroke before re-searching
---@field icons? VscrIcons -- glyph overrides for the tree chevrons and box labels
---@field keymap? VscrKeymap -- panel keybindings; false unbinds an action

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

---@class VscrKeymap
---@field next_panel? string|false           -- "<Tab>" next panel
---@field prev_panel? string|false           -- "<S-Tab>" previous panel
---@field field_next? string|false           -- "<A-j>" next text field
---@field field_prev? string|false           -- "<A-k>" previous text field
---@field to_tree? string|false              -- "<A-l>" focus results tree
---@field to_field? string|false             -- "<A-h>" tree -> last field (else -> tree)
---@field focus_results? string|false        -- "<CR>" in Search: run search / jump to tree
---@field toggle_case? string|false          -- "<A-c>" Aa box
---@field toggle_whole_word? string|false    -- "<A-w>" ab box
---@field toggle_regex? string|false         -- "<A-r>" .* box
---@field toggle_no_ignore? string|false     -- "<A-I>" I box (shifted Alt chord)
---@field toggle_hidden? string|false        -- "<A-H>" H box (shifted Alt chord)
---@field toggle_preserve_case? string|false -- "<A-p>" AB box (replace mode only)
---@field replace_all? string|false          -- "<C-A-CR>" Replace All
---@field search_method? string|false        -- "<C-g>" live <-> on-demand search
---@field collapse_all? string|false         -- "zc" collapse/expand all files
---@field help? string|false                 -- "?" keymap help overlay
---@field close? string|string[]|false       -- {"q","<leader>fs","<leader>S"}; Esc always closes

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
    -- Panel keybindings. Every value is a Neovim keycoded string ("<A-c>",
    -- "zc", "<leader>fs") or false to unbind; omitted keys keep defaults.
    -- NOT configurable (built into nui/the dialogs): Esc close, Enter/Space
    -- activation, tree j/k, the Yes/No dialog keys.
    keymap = {
        next_panel = "<Tab>",
        prev_panel = "<S-Tab>",
        field_next = "<A-j>",
        field_prev = "<A-k>",
        to_tree = "<A-l>",
        to_field = "<A-h>",
        focus_results = "<CR>",
        toggle_case = "<A-c>",
        toggle_whole_word = "<A-w>",
        toggle_regex = "<A-r>",
        toggle_no_ignore = "<A-I>",
        toggle_hidden = "<A-H>",
        toggle_preserve_case = "<A-p>",
        replace_all = "<C-A-CR>",
        search_method = "<C-g>",
        collapse_all = "zc",
        help = "?",
        close = { "q", "<leader>fs", "<leader>S" },
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
    if type(options.keymap) ~= "table" then
        vim.notify('vscode-search-replace: "keymap" must be a table, using defaults', vim.log.levels.WARN)
        options.keymap = vim.deepcopy(defaults.keymap)
    else
        for key, def in pairs(defaults.keymap) do
            if key ~= "close" then
                local v = options.keymap[key]
                -- false = unbind; anything but a string/false is bad input
                if v ~= nil and v ~= false and type(v) ~= "string" then
                    vim.notify(
                        ('vscode-search-replace: keymap "%s" must be a string or false, using default'):format(key),
                        vim.log.levels.WARN
                    )
                    options.keymap[key] = def
                end
            end
        end
        -- tbl_deep_extend MERGES arrays (a 1-element user list would inherit
        -- the default tail), so "close" is rebuilt from the user's raw value.
        -- `and/or` chains swallow a literal false, so pick raw explicitly.
        local raw
        if type(opts) == "table" and type(opts.keymap) == "table" then
            raw = opts.keymap.close
        end
        local ok_list = type(raw) == "table" and #raw > 0
        if ok_list then
            for _, k in ipairs(raw) do
                if type(k) ~= "string" then
                    ok_list = false
                end
            end
        end
        if raw == nil then
            options.keymap.close = vim.deepcopy(defaults.keymap.close)
        elseif raw == false then
            options.keymap.close = false
        elseif type(raw) == "string" then
            options.keymap.close = { raw }
        elseif ok_list then
            options.keymap.close = vim.deepcopy(raw)
        else
            vim.notify(
                'vscode-search-replace: keymap "close" must be a string, list of strings, or false, using default',
                vim.log.levels.WARN
            )
            options.keymap.close = vim.deepcopy(defaults.keymap.close)
        end
    end
end

function M.get()
    return options
end

return M
