local M = {}

--- Configure the plugin. See vscode-search-replace.config for fields.
function M.setup(opts)
    require("vscode-search-replace.config").setup(opts)
end

local state -- nil when UI closed: { close = function() end }

-- First line of the visual selection (rg is line-based, so a multiline
-- selection searches its first row); falls back to the word under cursor.
local function selected_or_word()
    local mode = vim.fn.mode():sub(1, 1)
    -- getregion's opts.type takes the VISUAL MODE CHAR ("v"/"V"/"\22"), not
    -- the "char"/"line"/"block" words
    if mode == "v" or mode == "V" or mode == "\22" then
        local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."),
            { type = mode, exclude_eol = true })
        if region[1] and region[1] ~= "" then
            return region[1]
        end
    end
    return vim.fn.expand("<cword>")
end

--- opts: { file = search current file only, word = prefill pattern from
--- visual selection / cword, pattern = explicit pattern string }
function M.open(opts)
    opts = opts or {}
    if state then
        state.close()
        return
    end

    local pattern = opts.pattern
    if pattern == nil and opts.word then
        pattern = selected_or_word()
    end

    local path = vim.uv.cwd()
    if opts.file then
        path = vim.api.nvim_buf_get_name(0)
        if path == "" or path:find("^no-name") then
            vim.notify("vscode-search-replace: current buffer has no file on disk", vim.log.levels.WARN)
            return
        end
    end

    local orig_win = vim.api.nvim_get_current_win()
    state = require("vscode-search-replace.ui").create({
        path = path,
        file_mode = opts.file or false,
        pattern = (pattern ~= nil and pattern ~= "") and pattern or nil,
        on_jumpto = function(file, lnum)
            -- The UI has closed itself by now; open the file in the window that
            -- was current before the float and position the cursor via the API
            -- (`:edit {lnum} {file}` is not valid — the whole arg is a filename).
            local w = vim.api.nvim_win_is_valid(orig_win) and orig_win or vim.api.nvim_get_current_win()
            vim.api.nvim_win_call(w, function()
                vim.cmd("edit " .. vim.fn.fnameescape(file))
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
                vim.cmd("normal! zz")
            end)
        end,
        on_closed = function()
            state = nil
        end,
    })
end

return M
