-- vscode-search-replace engine: pure search/replace logic over ripgrep + Vim
-- substitution. No UI imports (nui lives in vscode-search-replace.ui).
--
-- Shared params table (contract with vscode-search-replace.ui):
--   pattern         = string,   -- raw user text
--   replacement     = string,   -- raw; \1..\9 + \0 capture refs in regex mode
--   regex           = boolean,  -- false → -F / \V literal
--   case_sensitive  = boolean,  -- false → -i / \c
--   whole_word      = boolean,  -- false → no -w / no word-boundary wrap
--   preserve_case   = boolean,  -- adapt the replacement to each match's casing
--   include         = string,   -- comma-separated paths/globs; "" = all
--   path            = string,   -- absolute search root (cwd at open)
--   no_ignore       = boolean,  -- include gitignored files (--no-ignore)
--   hidden          = boolean,  -- include hidden files (--hidden)

local M = {}

local MAX_STORED = 1000 -- default per-search storage cap (opts.max_stored)

-- Throttle for streamed partial deliveries (ms): a hot pattern updates the
-- UI about five times a second instead of once per output chunk.
local DELIVER_MS = 200

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
    local cmd = { "rg", "--json", "--no-heading", "--color", "never", "--line-number", "--no-messages" }
    if not params.case_sensitive then
        cmd[#cmd + 1] = "-i"
    end
    if not params.regex then
        cmd[#cmd + 1] = "-F"
    end
    if params.whole_word then
        cmd[#cmd + 1] = "--word-regexp"
    end
    if params.no_ignore then
        cmd[#cmd + 1] = "--no-ignore"
    end
    if params.hidden then
        cmd[#cmd + 1] = "--hidden"
    end
    -- The scope toggles make rg walk hidden/ignored trees; without this,
    -- --hidden drags the whole .git object store into every search. A later
    -- user glob naming .git still wins (rg gives precedence to the last
    -- matching glob), and "dir/" only ever matches directories.
    cmd[#cmd + 1] = "--glob"
    cmd[#cmd + 1] = "!.git/"
    if params.include and params.include ~= "" then
        -- VS Code-style normalization: rg --glob matches RELATIVE to the
        -- walk root, so an absolute entry under the search root or a
        -- "/workspace-relative" one is converted before it silently matches
        -- nothing (measured: pasted absolute paths gave searches=0).
        local root = strip_trailing_slash(norm_slashes(params.path or "")):lower()
        for part in (params.include .. ","):gmatch("([^,]*)") do
            local entry = vim.trim(norm_slashes(part))
            entry = strip_trailing_slash(entry)
            if entry ~= "" then
                local low = entry:lower()
                if root ~= "" and low == root then
                    entry = nil -- the entry IS the root: already covered
                elseif root ~= "" and low:sub(1, #root + 1) == root .. "/" then
                    entry = entry:sub(#root + 2)
                elseif entry:sub(1, 1) == "/" and root:sub(1, 1) ~= "/" then
                    -- "/src" on Windows reads as workspace-relative; on
                    -- POSIX it is a genuine absolute path: pass through.
                    entry = entry:sub(2)
                end
                if entry and entry ~= "" then
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
                        if entry:find("/") then
                            -- "src/mcu" below the walk root (nested folders)
                            -- should still match, VS Code style.
                            cmd[#cmd + 1] = "--glob"
                            cmd[#cmd + 1] = "**/" .. entry .. "/**"
                        end
                    end
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
            -- \V (nomagic): \< \> ARE word boundaries here, and a literal can't
            -- alternate, so no %(...) wrapper is needed around the pattern.
            pat = [[\V\<]] .. vim.fn.escape(params.pattern, [[\\]]) .. [[\>]]
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

--- Vim substitute() replacement specials expanded against one match.
--- Mirrors the plain (non-preserve) path exactly: the plain path runs
--- to_vim_repl() first, so a literal '%' or '&' from the user is ALWAYS
--- literal here too; recognised escapes are \\ \n \r \t and the \0..\9
--- back-references; any other \X yields the literal X; a lone trailing
--- backslash stays literal. Byte-wise scan is UTF-8 safe (the split
--- characters are ASCII-only).
---@param raw string   -- user replacement, unescaped
---@param full string  -- submatch(0)
---@param caps string[] -- submatch(1..9) ("" for non-participating)
---@return string
function M.expand_repl(raw, full, caps)
    local out = {}
    local i, n = 1, #raw
    while i <= n do
        local b = raw:byte(i)
        if b == 92 and i < n then
            local c = raw:sub(i + 1, i + 1)
            local d = c:match("%d") and c:byte() - 48 or nil
            if d == 0 then
                out[#out + 1] = full
            elseif d then
                out[#out + 1] = caps[d] or ""
            elseif c == "n" then
                out[#out + 1] = "\n"
            elseif c == "r" then
                out[#out + 1] = "\r"
            elseif c == "t" then
                out[#out + 1] = "\t"
            else
                out[#out + 1] = c
            end
            i = i + 2
        elseif b == 92 then
            out[#out + 1] = "\\"
            i = i + 1
        else
            out[#out + 1] = raw:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

--- Recase `text` to the shape of the matched word `match` (VS Code's
--- Preserve-case rules, ASCII-focused but UTF-8-safe via vim.fn):
---   ALL-CAPS match  -> replacement uppercased   (FOO + bar -> BAR)
---   Title match     -> replacement title-cased  (Foo + bar -> Bar)
---   anything else   -> replacement as typed.
---@param text string
---@param match string
---@return string
function M.apply_preserve_case(text, match)
    if text == "" or match == "" then
        return text
    end
    local m_up = vim.fn.toupper(match)
    local m_low = vim.fn.tolower(match)
    if match == m_up and match ~= m_low then
        return vim.fn.toupper(text)
    end
    local first = vim.fn.strpart(match, 0, 1)
    local rest = vim.fn.strpart(match, 1, math.max(0, vim.fn.strchars(match) - 1))
    if first == vim.fn.toupper(first) and first ~= vim.fn.tolower(first) and rest == vim.fn.tolower(rest) then
        local t_first = vim.fn.strpart(text, 0, 1)
        local t_rest = vim.fn.strpart(text, 1, math.max(0, vim.fn.strchars(text) - 1))
        return vim.fn.toupper(t_first) .. vim.fn.tolower(t_rest)
    end
    return text
end

--- Callback for the \= expression built by M.preserve_expr: expand the raw
--- replacement against THIS match, then recase it. MUST stay reachable via
--- v:lua.require'vscode-search-replace.engine'.
---@param full string
---@param caps string[]
---@param raw string
---@return string
function M.preserve_submatch(full, caps, raw)
    return M.apply_preserve_case(M.expand_repl(raw, full, caps), full or "")
end

--- The substitute() replacement string for preserve-case mode: a
--- sub-replace-expression whose evaluation calls back into Lua per match.
--- The user text is embedded as a VimL single-quoted literal (quotes
--- doubled), so it can never break out of the expression.
---@param raw string
---@return string
function M.preserve_expr(raw)
    local lit = "'" .. (raw:gsub("'", "''")) .. "'"
    return "\\=v:lua.require'vscode-search-replace.engine'.preserve_submatch("
        .. "submatch(0), map(range(1, 9), 'submatch(v:val)'), "
        .. lit
        .. ")"
end

--- Apply the search/replace to a single line using Vim regex semantics.
--- Broken regexes fall back to the line unchanged (rg already validated the
--- pattern for line selection; this only guards apply-time crashes).
---@param line string
---@param params table
---@return string
function M.substitute_line(line, params)
    local repl
    if params.preserve_case then
        repl = M.preserve_expr(params.replacement or "")
    else
        repl = M.to_vim_repl(params.replacement or "")
    end
    local ok, result = pcall(vim.fn.substitute, line, M.build_vim_pattern(params), repl, "g")
    if not ok or type(result) ~= "string" then
        return line
    end
    return result
end

--- Run an async ripgrep search, streaming results as rg emits them.
--- on_done MAY BE CALLED MULTIPLE TIMES: partial deliveries carry
--- res.final == false (throttled to ~one per DELIVER_MS while matches land),
--- then exactly one final delivery carries res.final == true (also for the
--- empty-pattern short-circuit and for errors).
--- opts:
---   max_stored -- storage cap (default MAX_STORED). Once reached rg is
---                killed early and res.truncated set: hot patterns neither
---                flood the UI nor freeze the parse. Replace All recounts
---                with a larger cap.
---   stream     -- false disables partial deliveries (count-only runs).
---@param params table
---@param on_done fun(res: table)
---@param opts? table
function M.search(params, on_done, opts)
    opts = opts or {}
    local cap = opts.max_stored or MAX_STORED
    local do_stream = opts.stream ~= false

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
        on_done({ files = {}, total = 0, ms = 0, final = true })
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

    -- Run rg from the search root so relative --glob entries anchor there
    -- deterministically, whatever Neovim's own cwd happens to be.
    local st = params.path and vim.uv.fs_stat(params.path) or nil
    local sys_cwd = (st and st.type == "directory") and params.path
        or (params.path:match("^(.*)[/\\][^/\\]+$"))

    local res = { files = {}, total = 0, ms = 0 }
    local by_path = {}
    local killed_for_cap = false

    -- One decoded rg "match" event -> stored row. The body mirrors the old
    -- batch parser exactly (byte-offset conversions, preview rules).
    local function store(d)
        local data = d.data
        if not data then
            return false
        end
        if res.total >= cap then
            -- Cap reached: stop storing/counting (total stays at the cap,
            -- which the UI words as "cap+") and make rg stop, too. The exit
            -- callback still delivers this truncated final result.
            res.truncated = true
            if not killed_for_cap then
                killed_for_cap = true
                if sys_handle then
                    pcall(function()
                        sys_handle:kill("sigterm")
                    end)
                end
            end
            return false
        end
        res.total = res.total + 1
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
        return true
    end
    -- Prefilter on the RAW line first (rg always emits "type" first): the
    -- bulk of a hot pattern's output then costs one substring test per line
    -- instead of a JSON decode. Returns true when a match was stored.
    local function handle_line(line)
        if line:find('"type":"match"', 1, true) then
            if res.truncated then
                return false
            end
            local ok, d = pcall(vim.json.decode, line)
            if ok and type(d) == "table" and d.type == "match" then
                return store(d)
            end
            return false
        end
        if not res.truncated and line:find('"type":"summary"', 1, true) then
            local ok, d = pcall(vim.json.decode, line)
            if ok and type(d) == "table" and d.data and d.data.stats then
                res.searches = d.data.stats.searches
            end
        end
        return false
    end

    -- The vim.system reader runs in a FAST-EVENT context where vim.fn — e.g.
    -- substitute() via store() — is not allowed (empirically verified on
    -- Nvim 0.12.4): chunks are line-buffered here and parsed by a scheduled
    -- drain on the main loop instead.
    local buf = ""
    local queue = {}
    local drain_pending = false
    local last_deliver = t0
    local deliver_pending = false

    local function deliver()
        deliver_pending = false
        if token ~= req_token or res.final or not do_stream then
            return
        end
        last_deliver = vim.uv.now()
        res.ms = last_deliver - t0
        res.final = false
        on_done(res)
    end

    local function drain()
        drain_pending = false
        if token ~= req_token then
            return
        end
        local found = false
        for i = 1, #queue do
            if handle_line(queue[i]) then
                found = true
            end
        end
        queue = {}
        if not found or not do_stream then
            return
        end
        local wait = DELIVER_MS - (vim.uv.now() - last_deliver)
        if wait <= 0 then
            deliver()
        elseif not deliver_pending then
            deliver_pending = true
            vim.defer_fn(deliver, wait)
        end
    end

    sys_handle = vim.system(cmd, {
        text = false,
        cwd = sys_cwd,
        stdout = function(_, chunk)
            if token ~= req_token or not chunk then
                return
            end
            buf = buf .. chunk
            local nl = buf:find("\n", 1, true)
            while nl do
                local line = buf:sub(1, nl - 1)
                buf = buf:sub(nl + 1)
                if line ~= "" then
                    queue[#queue + 1] = line:gsub("\r$", "")
                end
                nl = buf:find("\n", 1, true)
            end
            if #queue > 0 and not drain_pending then
                drain_pending = true
                vim.schedule(drain)
            end
        end,
    }, function(out)
        if token ~= req_token then
            return -- a newer search superseded this one
        end
        sys_handle = nil
        -- Fast-event context again: the final parse/delivery is deferred to
        -- the next main-loop iteration.
        vim.schedule(function()
            if token ~= req_token then
                return
            end
            -- rg exit codes: 0 = matches, 1 = no matches (NOT an error),
            -- >=2 = error. A cap-triggered SIGTERM exit is a normal end.
            if (out.code or 0) >= 2 and not killed_for_cap then
                local err = (out.stderr or ""):match("[^\r\n]+")
                res.error = err or ("rg exit code " .. tostring(out.code))
                res.ms = vim.uv.now() - t0
                res.final = true
                on_done(res)
                return
            end
            -- Drain the tail: all stdout callbacks complete before the exit
            -- callback runs (verified on Nvim 0.12.4), so queue + possible
            -- unterminated last line is the complete data.
            if buf ~= "" then
                queue[#queue + 1] = buf:gsub("\r$", "")
                buf = ""
            end
            for i = 1, #queue do
                handle_line(queue[i])
            end
            queue = {}
            deliver_pending = false
            res.ms = vim.uv.now() - t0
            res.final = true
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
