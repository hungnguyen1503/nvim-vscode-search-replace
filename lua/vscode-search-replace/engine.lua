-- vscode-search-replace engine: pure search/replace logic over ripgrep + Vim
-- substitution. No UI imports (nui lives in vscode-search-replace.ui).
--
-- Shared params table (contract with vscode-search-replace.ui):
--   pattern         = string,   -- raw user text
--   replacement     = string,   -- raw; \1..\9 + \0 capture refs in regex mode
--   regex           = boolean,  -- false → -F / \V literal
--   case_sensitive  = boolean,  -- false → -i / \c
--   whole_word      = boolean,  -- false → no -w / no word-boundary wrap
--   include         = string,   -- comma-separated paths/globs; "" = all
--   path            = string,   -- absolute search root (cwd at open)

local M = {}

local MAX_STORED = 1000

-- Latest search token: stale vim.system callbacks are ignored once a newer
-- search has been requested (debounced live search races).
local req_token = 0
local sys_handle = nil

local function norm_slashes(s)
    return (s:gsub("\\", "/"))
end

local function strip_trailing_slash(s)
    return (s:gsub("/+$", ""))
end

local function is_absolute(p)
    return p:match("^%a:/") ~= nil or p:sub(1, 1) == "/"
end

--- Build the ripgrep argv for a search.
---@param params table
---@return string[]
function M.build_rg_cmd(params)
    local cmd = { "rg", "--json", "--no-heading", "--color", "never", "--line-number" }
    if not params.case_sensitive then
        cmd[#cmd + 1] = "-i"
    end
    if not params.regex then
        cmd[#cmd + 1] = "-F"
    end
    if params.whole_word then
        cmd[#cmd + 1] = "--word-regexp"
    end
    if params.include and params.include ~= "" then
        for part in (params.include .. ","):gmatch("([^,]*)") do
            local entry = vim.trim(norm_slashes(part))
            entry = strip_trailing_slash(entry)
            if entry ~= "" then
                -- A real glob (contains * ? [ or !) is passed once; a plain
                -- path needs its own "/**" companion so rg recurses into it.
                if entry:find("[%*%?%[%!]") then
                    cmd[#cmd + 1] = "--glob"
                    cmd[#cmd + 1] = entry
                else
                    cmd[#cmd + 1] = "--glob"
                    cmd[#cmd + 1] = entry
                    cmd[#cmd + 1] = "--glob"
                    cmd[#cmd + 1] = entry .. "/**"
                end
            end
        end
    end
    cmd[#cmd + 1] = "-e"
    cmd[#cmd + 1] = params.pattern or ""
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = params.path
    return cmd
end

--- Build the Vim regex equivalent of params.pattern.
--- NOTE: rg decides WHICH lines match (Rust regex); this pattern decides how a
--- line substitutes. Common constructs agree; neither dialect has lookaround.
---@param params table
---@return string
function M.build_vim_pattern(params)
    local pat
    if params.whole_word then
        if params.regex then
            -- very-magic uses bare %(...) and unbackslashed < > (there, \<
            -- matches a LITERAL '<'). The inner group keeps user \1..\9
            -- unshifted and bounds a top-level alternation, matching
            -- rg --word-regexp's \b(?:P)\b semantics.
            pat = [[\v%(<%(]] .. params.pattern .. [[)>)]]
        else
            pat = [[\V\%(\<]] .. vim.fn.escape(params.pattern, [[\\]]) .. [[\>\)]]
        end
    elseif params.regex then
        pat = [[\v]] .. params.pattern
    else
        pat = [[\V]] .. vim.fn.escape(params.pattern, [[\\]])
    end
    return pat .. (params.case_sensitive and [[\C]] or [[\c]])
end

--- Convert a user replacement string to a Vim substitute() replacement.
--- Escapes the Vim-replacement specials (% is escaped defensively, & is the
--- whole-match char) first, in that order, since the gsub replacement strings
--- themselves interpret "%".
--- NOTE (empirically verified on Nvim 0.12.4, supersedes the plan's draft
--- mapping \1..\9→%1..\9 / \0→&): substitute() ONLY expands the backslash
--- form in the replacement string — "%1" is inserted literally, while the
--- user's "\1"..\9"/"\0" are already valid Vim back-references and pass
--- through unchanged.
---@param repl string
---@return string
function M.to_vim_repl(repl)
    local s = repl:gsub("%%", "\\%%") -- literal % first
    s = s:gsub("&", "\\&") -- literal & (would mean the whole match)
    return s
end

--- Apply the search/replace to a single line using Vim regex semantics.
--- Broken regexes fall back to the line unchanged (rg already validated the
--- pattern for line selection; this only guards apply-time crashes).
---@param line string
---@param params table
---@return string
function M.substitute_line(line, params)
    local repl = M.to_vim_repl(params.replacement or "")
    local ok, result = pcall(vim.fn.substitute, line, M.build_vim_pattern(params), repl, "g")
    if not ok or type(result) ~= "string" then
        return line
    end
    return result
end

--- Run an async ripgrep search.
---@param params table
---@param on_done fun(res: table)
function M.search(params, on_done)
    -- Bump the token even on the synchronous paths so a still-running
    -- previous rg cannot deliver stale results afterwards.
    req_token = req_token + 1
    if not params.pattern or params.pattern == "" then
        if sys_handle then
            pcall(function()
                sys_handle:kill("sigterm")
            end)
            sys_handle = nil
        end
        on_done({ files = {}, total = 0, ms = 0 })
        return
    end
    local token = req_token
    if sys_handle then
        pcall(function()
            sys_handle:kill("sigterm")
        end)
        sys_handle = nil
    end

    local cmd = M.build_rg_cmd(params)
    local t0 = vim.uv.now()
    local root = strip_trailing_slash(norm_slashes(params.path))

    sys_handle = vim.system(cmd, { text = false }, function(out)
        if token ~= req_token then
            return -- a newer search superseded this one
        end
        sys_handle = nil
        -- vim.system callbacks run in a fast-event context where vim.fn
        -- (substitute(), readfile(), the UI redraws in on_done, ...) are not
        -- allowed; defer processing to the next main-loop iteration.
        vim.schedule(function()
            if token ~= req_token then
                return
            end
            local res = { files = {}, total = 0, ms = vim.uv.now() - t0 }

            -- rg exit codes: 0 = matches, 1 = no matches (NOT an error), >=2 = error.
            if (out.code or 0) >= 2 then
                local err = (out.stderr or ""):match("[^\r\n]+")
                res.error = err or ("rg exit code " .. tostring(out.code))
                on_done(res)
                return
            end

            local by_path = {}
            local stdout = out.stdout or ""
            for _, raw_line in ipairs(vim.split(stdout, "\n", true)) do
                local line = raw_line:gsub("\r$", "")
                if line ~= "" then
                    local ok, d = pcall(vim.json.decode, line)
                    if ok and type(d) == "table" and d.type == "match" then
                        local data = d.data
                        if data then
                            res.total = res.total + 1
                            if res.total <= MAX_STORED then
                                local raw = norm_slashes((data.path and data.path.text) or "")
                                local abs = is_absolute(raw) and raw or (root .. "/" .. raw)
                                local lines = data.lines or {}
                                -- rg includes the line terminator in lines.text/bytes
                                local text = lines.text
                                    or (lines.bytes and vim.base64.decode(lines.bytes))
                                    or ""
                                text = text:gsub("[\r\n]+$", "")
                                local sm = data.submatches and data.submatches[1]
                                local m = {
                                    lnum = data.line_number,
                                    text = text,
                                    -- 1-based inclusive start, exclusive end (byte
                                    -- offsets from rg, which are 0-based):
                                    start = sm and (sm.start + 1) or nil,
                                    ["end"] = sm and (sm["end"] + 1) or nil,
                                }
                                if params.replacement ~= nil and params.replacement ~= "" then
                                    local new = M.substitute_line(text, params)
                                    if new ~= text then
                                        m.new = new
                                    end
                                end
                                local f = by_path[abs]
                                if not f then
                                    local rel = abs
                                    if abs:sub(1, #root) == root then
                                        rel = abs:sub(#root + 2)
                                        -- search root IS the file (current-file mode): no suffix
                                        if rel == "" then
                                            rel = abs:match("[^/]+$")
                                        end
                                    end
                                    f = { path = abs, rel = rel, matches = {} }
                                    by_path[abs] = f
                                    table.insert(res.files, f)
                                end
                                table.insert(f.matches, m)
                            else
                                res.truncated = true
                            end
                        end
                    end
                end
            end
            on_done(res)
        end)
    end)
end

--- Abandon any in-flight search: supersede its token and kill the rg
--- process. A scheduled-but-not-yet-run result callback fails its token
--- check and is dropped. Used when the UI closes so no render ever lands
--- on a destroyed renderer.
function M.cancel()
    req_token = req_token + 1
    if sys_handle then
        pcall(function()
            sys_handle:kill("sigterm")
        end)
        sys_handle = nil
    end
end

--- Apply the substitutions captured in a search result back to disk.
--- Files are read and rewritten in BINARY mode with the trailing-"" element
--- that readfile("b") appends for a final newline re-inserted on write, so
--- line endings (\r in CRLF files, mixed EOLs) and the presence/absence of a
--- final newline are preserved byte-exact (verified empirically on Nvim
--- 0.12.4; supersedes the plan's writefile-final-newline edge note, which
--- text-mode readfile/writefile would otherwise hit — text-mode readfile
--- silently drops \r and writefile always appends a final newline).
---@param res table -- result from M.search
---@param params table
---@return table -- { written = {path...}, failed = { {path, reason}... } }
function M.apply(res, params)
    local out = { written = {}, failed = {} }
    if not res or not res.files then
        return out
    end
    for _, f in ipairs(res.files) do
        local ok_read, lines = pcall(vim.fn.readfile, f.path, "b")
        if not ok_read or type(lines) ~= "table" then
            table.insert(out.failed, { path = f.path, reason = "could not read file" })
        else
            local had_final_nl = #lines > 0 and lines[#lines] == ""
            if had_final_nl then
                lines[#lines] = nil
            end
            local stale = false
            for _, m in ipairs(f.matches) do
                local cur = lines[m.lnum]
                -- CRLF files: binary readfile keeps the "\r", rg's match text
                -- (terminator-stripped) omits it.
                if cur ~= m.text and cur ~= m.text .. "\r" then
                    stale = true
                    break
                end
            end
            if stale then
                table.insert(out.failed, { path = f.path, reason = "file changed since search" })
            else
                local changed = 0
                for _, m in ipairs(f.matches) do
                    -- Substitute from the FILE's own line so any trailing "\r"
                    -- survives the rewrite.
                    local new = M.substitute_line(lines[m.lnum], params)
                    if new ~= lines[m.lnum] then
                        lines[m.lnum] = new
                        changed = changed + 1
                    end
                end
                if changed > 0 then
                    if had_final_nl then
                        lines[#lines + 1] = ""
                    end
                    local ok_write = pcall(vim.fn.writefile, lines, f.path, "b")
                    if ok_write then
                        table.insert(out.written, f.path)
                    else
                        table.insert(out.failed, { path = f.path, reason = "could not write file" })
                    end
                end
            end
        end
    end
    vim.cmd("checktime")
    return out
end

return M
