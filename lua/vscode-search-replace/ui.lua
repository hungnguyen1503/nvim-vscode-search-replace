-- Global search & replace UI built on nui-components.
-- Pure search/replace logic lives in vscode-search-replace.engine (contract: build_rg_cmd,
-- search, build_vim_pattern, to_vim_repl, substitute_line, apply).

local M = {}

local n = require("nui-components")
local engine = require("vscode-search-replace.engine")
local config = require("vscode-search-replace.config")
local Text = require("nui.text")

function M.create(opts)
    local cfg = config.get()
    -- Sizes resolve to numbers at open time: the renderer needs numeric
    -- sizes (flex layout children read parent:get_size() raw; nui.layout
    -- percentage strings never resolve for them — size.lua:172).
    -- Fraction of the editor when <=1, absolute cells when >1.
    local function dim(v, full)
        return math.min(v <= 1 and math.floor(full * v) or math.floor(v), full)
    end
    local closed = false
    local debounce_timer
    local renderer = n.create_renderer({
        width = dim(cfg.width, vim.o.columns),
        height = dim(cfg.height, vim.o.lines),
        -- nui layout {row, col} percentage position (nui/layout/utils.lua:30-59)
        position = config.POSITIONS[cfg.position],
        -- Teardown MUST hang off on_unmount, not our close() wrapper: the
        -- renderer's built-in <Esc> handler calls Renderer:close() directly
        -- (renderer.lua:237), bypassing any wrapper. on_unmount fires from
        -- close() on every path (Esc, q, toggle, jump), cancelling the
        -- debounce timer and any in-flight rg BEFORE popups are destroyed —
        -- otherwise their callbacks redraw a dead window ("vim.schedule
        -- callback" nvim_set_option_value error).
        on_unmount = function()
            closed = true
            if debounce_timer then
                debounce_timer:stop()
            end
            engine.cancel()
            opts.on_closed()
        end,
    })

    -- signals wrap an OBJECT; reading a field yields the SignalValue the props
    -- layer subscribes to, writing updates it. Only strings/numbers as fields
    -- (never n.node trees: Signal.create vim.deepcopies, stripping metatables).
    local empty_msg = opts.file_mode
        and ("Enter text to search in " .. vim.fn.fnamemodify(opts.path, ":t"))
        or "Enter search text"
    local status = n.create_signal({ text = empty_msg })
    local params = {
        pattern = opts.pattern or "",
        replacement = "",
        regex = false,
        case_sensitive = false,
        include = "",
        path = opts.path,
    }
    -- checkbox signs repaint only through reactive props: Component:set_current_value
    -- does not redraw; a `value = <SignalValue>` prop makes the popup re-render.
    local toggles = n.create_signal({ case = false, regex = false })
    local tree_data = {}
    local last_res = nil
    local close, schedule, run_search, render_results
    local tree_comp

    close = function()
        if closed then
            return
        end
        renderer:close()
    end
    local function replace_all()
        if params.pattern == "" or params.replacement == "" or not last_res or last_res.total == 0 then
            status.text = "Nothing to replace"
            return
        end
        local prompt = ("Replace %d matches in %d files?"):format(last_res.total, #last_res.files)
        if vim.fn.confirm(prompt, "&Yes\n&Cancel", 2) ~= 1 then
            return
        end
        local r = engine.apply(last_res, params)
        local skipped = {}
        for _, f in ipairs(r.failed or {}) do
            table.insert(skipped, f.path .. " (" .. f.reason .. ")")
        end
        vim.notify(
            ("vscode-search-replace: replaced in %d file(s)%s"):format(
                #(r.written or {}),
                #skipped > 0 and ("; skipped: " .. table.concat(skipped, ", ")) or ""
            )
        )
        run_search()
    end

    local function on_select(node, component)
        if node.kind == "file" then
            if node:is_expanded() then
                node:collapse()
            else
                node:expand()
            end
            component:get_tree():render()
        else
            -- line and preview nodes both carry path + lnum
            close()
            opts.on_jumpto(node.path, node.lnum)
        end
    end

    -- Long match lines must not rely on window cropping (the match can be
    -- scrolled out of sight entirely): slice the TEXT around the match so
    -- it is always rendered, with "…" marking removed head/tail.
    local function clip(text, s, e, avail)
        if avail < 8 or #text <= avail then
            return text, s, e, false, false
        end
        local start = math.max(1, (s or 1) - 1 - math.floor(avail * 0.3))
        local stop = math.min(#text, start + avail - 1)
        if stop - start + 1 < avail then
            start = math.max(1, stop - avail + 1)
        end
        -- never cut through a UTF-8 sequence
        while start < #text and text:byte(start) >= 0x80 and text:byte(start) < 0xC0 do
            start = start + 1
        end
        while stop > 1 and text:byte(stop) >= 0x80 and text:byte(stop) < 0xC0 do
            stop = stop - 1
        end
        return text:sub(start, stop), s and (s - start + 1), e and (e - start + 1),
            start > 1, stop < #text
    end

    local function avail_width(node)
        local width = 64
        if tree_comp and tree_comp.winid and vim.api.nvim_win_is_valid(tree_comp.winid) then
            width = vim.api.nvim_win_get_width(tree_comp.winid)
        end
        -- 2 per depth level + "NNNN │ " gutter + a column of breathing room
        return width - 2 * (node:get_depth() - 1) - 8 - 1
    end

    local function prepare_node(node, line)
        line:append(("  "):rep(node:get_depth() - 1))
        if node.kind == "file" then
            line:append(Text((node:is_expanded() and " " or " ") .. node.rel .. "  (" .. node.count .. ")", "Directory"))
        elseif node.kind == "line" then
            line:append(Text(("%4d │ "):format(node.lnum), "LineNr"))
            local text, s, e, head, tail = clip(node.text, node.start, node["end"], avail_width(node))
            if head then
                line:append(Text("…", "Comment"))
            end
            if params.replacement == "" then
                if s and e then
                    -- rg reports byte offsets: prefix plain, match IncSearch, suffix plain
                    line:append(Text(text:sub(1, s - 1)))
                    line:append(Text(text:sub(s, e - 1), "IncSearch"))
                    line:append(Text(text:sub(e)))
                else
                    line:append(Text(text))
                end
            else
                line:append(Text(text, "VSCodeSearchOld"))
            end
            if tail then
                line:append(Text("…", "Comment"))
            end
        elseif node.kind == "preview" then
            line:append(Text("     │ ", "LineNr"))
            local text = node.text
            local width = avail_width(node)
            if #text > width and width >= 8 then
                text = text:sub(1, width - 1)
            end
            line:append(Text(text, "VSCodeSearchNew"))
            if node.text ~= text then
                line:append(Text("…", "Comment"))
            end
        end
        -- MUST return the line: nui.tree renders _height=0 for nil returns
        return line
    end

    tree_comp = n.tree({
        data = tree_data,
        prepare_node = prepare_node,
        on_select = on_select,
        border_label = "Results",
        -- flex required: Tree defaults to size=1 (one content row) and Size:get
        -- only consults flex when present (component/size.lua:253)
        flex = 1,
    })

    render_results = function(res)
        if res.error then
            status.text = "rg: " .. res.error
        elseif params.pattern == "" then
            status.text = empty_msg
        else
            status.text = ("Total: %d matches, time: %.2fs%s"):format(
                res.total,
                (res.ms or 0) / 1000,
                res.truncated and " (first 1000 shown)" or ""
            )
        end

        -- refresh in place: mutate the SAME array tree_comp was built with
        for i = #tree_data, 1, -1 do
            tree_data[i] = nil
        end
        local expand_all = #(res.files or {}) <= 10
        for _, f in ipairs(res.files or {}) do
            local children = {}
            for _, m in ipairs(f.matches or {}) do
                local preview = {}
                if m.new then
                    table.insert(preview, n.node({
                        id = f.path .. ":" .. m.lnum .. ":p",
                        kind = "preview",
                        path = f.path,
                        lnum = m.lnum,
                        text = m.new,
                    }))
                end
                local line_node = n.node({
                    id = f.path .. ":" .. m.lnum,
                    kind = "line",
                    path = f.path,
                    lnum = m.lnum,
                    text = m.text,
                    start = m.start,
                    ["end"] = m["end"],
                }, preview)
                -- nodes default to _is_expanded=false (nui/tree Tree.Node);
                -- the preview child only renders when the line node is expanded
                line_node:expand()
                table.insert(children, line_node)
            end
            local file_node = n.node({
                id = "f:" .. f.path,
                kind = "file",
                rel = f.rel,
                path = f.path,
                count = #f.matches,
            }, children)
            if expand_all or #tree_data < 3 then
                file_node:expand()
            else
                file_node:collapse()
            end
            table.insert(tree_data, file_node)
        end
        tree_comp:redraw()
        -- focus_item() reads the popup window's REAL cursor row; after a
        -- full data refresh it can be out of range → clamp to first row.
        if tree_comp.winid and vim.api.nvim_win_is_valid(tree_comp.winid) then
            pcall(vim.api.nvim_win_set_cursor, tree_comp.winid, { 1, 0 })
        end
    end

    run_search = function()
        if closed then
            return
        end
        engine.search(params, function(res)
            if closed then
                return
            end
            last_res = res
            render_results(res)
        end)
    end

    -- shared trailing-edge debounce (vim.debounce is not in the Nvim 0.12 core;
    -- configured-ms restart timer): every input/toggle funnels through this
    debounce_timer = vim.uv.new_timer()
    schedule = function()
        debounce_timer:stop()
        debounce_timer:start(cfg.debounce, 0, vim.schedule_wrap(run_search))
    end

    local ti_search = n.text_input({
        autofocus = true,
        max_lines = 1,
        border_label = "Search",
        placeholder = "search text",
        value = opts.pattern or "",
        on_change = function(value)
            params.pattern = value
            schedule()
        end,
    })
    local cb_case = n.checkbox({
        label = "Aa",
        value = toggles.case,
        on_change = function(value)
            params.case_sensitive = value
            toggles.case = value
            schedule()
        end,
    })
    local cb_regex = n.checkbox({
        label = ".*",
        value = toggles.regex,
        on_change = function(value)
            params.regex = value
            toggles.regex = value
            schedule()
        end,
    })
    local ti_replace = n.text_input({
        border_label = "Replace",
        max_lines = 1,
        on_change = function(value)
            params.replacement = value
            schedule()
        end,
    })
    local ti_include = n.text_input({
        border_label = "Files to Include",
        max_lines = 1,
        placeholder = "lua/hls, lua/mappings",
        on_change = function(value)
            params.include = value
            schedule()
        end,
    })

    -- Library-bug shield (nui-components text-input.lua:210/205 +
    -- component/init.lua:400): on_update/modify_buffer_content vim.schedule a
    -- buffer write with NO mounted check, so the callback orphaned by the
    -- final keystroke before close runs after Popup:_buf_destroy() force-deleted
    -- the buffer -> "vim.schedule callback ... nvim_buf_set_lines" error.
    -- Per-instance overrides gate every deferred write on buffer validity
    -- (shadowing, not patching, the shared metatable).
    local function shield_text_input(c)
        c.on_update = function(self)
            local m = vim.fn.mode()
            local cur_win = vim.api.nvim_get_current_win()
            if not (cur_win == self.winid and m == "i") then
                vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(self.bufnr or -1) then
                        return
                    end
                    if self:_is_next_line_allowed() or self:is_first_render() then
                        local lines = self:get_lines()
                        if vim.api.nvim_buf_is_valid(self.bufnr or -1) then
                            vim.api.nvim_buf_set_lines(self.bufnr, 0, #lines, false, lines)
                        end
                    end
                end)
            end
        end
        c.modify_buffer_content = function(self, modify_fn)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(self.bufnr or -1) then
                    return
                end
                self:set_buffer_option("modifiable", true)
                modify_fn()
                self:set_buffer_option("modifiable", false)
            end)
        end
    end
    shield_text_input(ti_search)
    shield_text_input(ti_replace)
    shield_text_input(ti_include)
    local btn_replace = n.button({
        label = "Replace All",
        global_press_key = "<C-R>",
        on_press = replace_all,
    })

    local sidebar = n.form(
        { flex = 40 },
        ti_search,
        n.columns(
            { flex = 0, size = 1 },
            cb_case,
            n.gap(1),
            cb_regex
        ),
        ti_replace,
        ti_include,
        n.columns(
            { flex = 0 },
            btn_replace
        )
    )

    local status_par = n.paragraph({ lines = status.text, is_focusable = false, size = 1 })
    local right = n.rows({ flex = 60 }, status_par, tree_comp)

    -- flex=1 REQUIRED: columns() with props lacking size/flex treats the props
    -- table itself as a child (nui-components init.lua normalize_layout_props)
    renderer:render(n.columns({ flex = 1 }, sidebar, right))

    -- ── Panel navigation (Alt+h/j/k/l) ─────────────────────────────────────
    -- Alt+j/k walk the renderer focus order (same list Tab cycles); Alt+l
    -- jumps into the results tree (plain j/k + <CR> move/select natively —
    -- nui-components/tree.lua:111-113); Alt+h returns to the last sidebar
    -- widget. Text inputs re-enter insert mode on arrival, everything else
    -- normal mode. Maps go on each component popup (renderer:add_mappings
    -- only covers the root buffer).
    local text_inputs = { [ti_search] = true, [ti_replace] = true, [ti_include] = true }
    local last_field = ti_search

    local function focus_component(c)
        if not c then
            return
        end
        if c ~= tree_comp then
            last_field = c
        end
        c:focus()
        if text_inputs[c] then
            vim.cmd("startinsert!")
        else
            vim.cmd("stopinsert")
        end
    end

    -- Walk by CAPTURED index, not runtime is_focused() scans: the renderer's
    -- own Tab handlers bind per-component closures the same way (a component's
    -- _private.focused flag is not dependable here, and a silently no-op'd
    -- Alt key would leak ESC+char into the focused widget).
    -- nui's Popup:map takes a single mode STRING (nui/utils/keymap.lua:112),
    -- unlike renderer:add_mappings which accepts mode tables.
    local list = renderer:get_focusable_components()
    for idx, c in ipairs(list) do
        local next_c = list[idx + 1] or list[1]
        local prev_c = list[idx - 1] or list[#list]
        for _, m in ipairs({ "n", "i" }) do
            c:map(m, "<A-j>", function()
                focus_component(next_c)
            end, { noremap = true })
            c:map(m, "<A-k>", function()
                focus_component(prev_c)
            end, { noremap = true })
            -- h and l both switch columns: sidebar -> tree, tree -> last field
            c:map(m, "<A-l>", function()
                focus_component(tree_comp)
            end, { noremap = true })
            c:map(m, "<A-h>", function()
                if c == tree_comp then
                    focus_component(last_field)
                else
                    focus_component(tree_comp)
                end
            end, { noremap = true })
        end
    end

    -- prefill from cword/selection: search immediately, skip the debounce
    if params.pattern ~= "" then
        run_search()
    end
    -- n+i so the toggle closes from inside the (insert-mode) text inputs;
    -- buffer-local maps win over the global <leader>S opener while mounted.
    renderer:add_mappings({
        { mode = "n", key = "q", handler = close },
        { mode = { "n", "i" }, key = "<leader>S", handler = close },
        { mode = { "n", "i" }, key = "<C-F>", handler = close },
        { mode = { "n", "i" }, key = "<C-S-F>", handler = close },
        { mode = { "n", "i" }, key = "<leader>fs", handler = close },
    })

    return { close = close }
end

return M
