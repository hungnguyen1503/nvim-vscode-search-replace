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
    local icons = cfg.icons
    -- Sizes resolve to numbers at open time: the renderer needs numeric
    -- sizes (flex layout children read parent:get_size() raw; nui.layout
    -- percentage strings never resolve for them — size.lua:172).
    -- Fraction of the editor when <=1, absolute cells when >1.
    local function dim(v, full)
        return math.min(v <= 1 and math.floor(full * v) or math.floor(v), full)
    end
    local closed = false
    local debounce_timer
    -- forward: the Replace All dialog must die with the panel (on_unmount)
    local confirm_buf, confirm_win
    local close_confirm
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
            close_confirm()
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
        whole_word = false,
        preserve_case = false,
        include = "",
        path = opts.path,
    }
    -- the toggle FILL repaints through reactive props: an `is_active =
    -- <SignalValue>` prop re-renders the button whenever the field is written.
    local toggles = n.create_signal({ case = false, regex = false, whole = false, replace = false, preserve = false })
    -- Fresh instance per consumer: :map mutates the SignalValue it is called on.
    local function hidden_unless_replace()
        return toggles.replace:dup():map(function(v)
            return not v
        end)
    end
    local tree_data = {}
    local last_res = nil
    local close, schedule, run_search, render_results
    local tree_comp
    local attach_panel_maps
    local toggle_help

    -- ── Mouse support ──────────────────────────────────────────────────────
    -- nvim resolves a mouse release against the buffer of the window that is
    -- CURRENT at release time; the press focuses natively, but while the
    -- panel is mid-repaint (a search result re-render) that focus move is
    -- deferred and the release arrives on the PREVIOUS component's buffer.
    -- So: every armed buffer carries the SAME dispatcher, and the dispatcher
    -- resolves the hit by mouse POSITION (window id first, then buffer
    -- identity, which survives popup re-creation) — never by which buffer's
    -- map happened to fire. (Extmark "buttons" are NOT an API; probed live.)
    local click_targets = {}
    local function dispatch_release()
        local mp = vim.fn.getmousepos()
        for i = #click_targets, 1, -1 do
            local tgt = click_targets[i]
            local comp = tgt.comp
            local ok = false
            if comp.winid and vim.api.nvim_win_is_valid(comp.winid) then
                ok = mp.winid == comp.winid
            end
            if not ok and comp.bufnr and vim.api.nvim_win_is_valid(mp.winid) then
                ok = vim.api.nvim_win_get_buf(mp.winid) == comp.bufnr
            end
            if ok then
                tgt.fire(mp)
                return
            end
        end
    end
    local function arm_mouse(comp, fire)
        for i = #click_targets, 1, -1 do
            if click_targets[i].comp == comp then
                table.remove(click_targets, i)
            end
        end
        table.insert(click_targets, { comp = comp, fire = fire })
        vim.keymap.set({ "n", "i" }, "<LeftRelease>", dispatch_release, {
            buffer = comp.bufnr,
            noremap = true,
        })
    end
    -- Fire an action only once `comp`'s window is actually current (the
    -- native press focus move may still be pending during a repaint).
    local function when_focused(comp, action)
        local tries = 0
        local function go()
            tries = tries + 1
            if comp.winid and vim.api.nvim_win_is_valid(comp.winid)
                and vim.api.nvim_get_current_win() == comp.winid then
                action()
            elseif tries < 100 then
                vim.schedule(go)
            end
        end
        vim.schedule(go)
    end
    -- Text inputs: the click already placed the cursor natively; just make
    -- sure typing can start (the release may arrive in normal mode, or with
    -- the focus move still queued behind a repaint).
    local function arm_input(comp)
        arm_mouse(comp, function()
            when_focused(comp, function()
                if vim.fn.mode():sub(1, 1) ~= "i" then
                    vim.cmd("startinsert!")
                end
            end)
        end)
    end

    close = function()
        if closed then
            return
        end
        renderer:close()
    end
    -- ── Replace All confirmation (Yes/No dialog) ───────────────────────────
    -- vim.fn.confirm sits on the command line with Yes/Cancel and has no
    -- mouse support; this floats a real dialog above the panel, keyboard
    -- (y/n, Enter/Esc) AND clickable (its box borders are buffer TEXT, so
    -- even them the whole 3-line box is a hit target).
    close_confirm = function()
        if confirm_win and vim.api.nvim_win_is_valid(confirm_win) then
            vim.api.nvim_win_close(confirm_win, true)
        end
        confirm_buf, confirm_win = nil, nil
    end
    local function open_confirm(msg, on_yes)
        if confirm_win and vim.api.nvim_win_is_valid(confirm_win) then
            return
        end
        local gap = 4
        local boxes = 5 + gap + 4
        local w = math.max(#msg, boxes + 2)
        local yes_x = math.floor((w - boxes) / 2)
        local no_x = yes_x + 5 + gap
        local function pad(s)
            return s .. (" "):rep(math.max(0, w - #s))
        end
        local lines = {
            pad(msg),
            (" "):rep(w),
            pad((" "):rep(yes_x) .. "╭───╮" .. (" "):rep(gap) .. "╭──╮"),
            pad((" "):rep(yes_x) .. "│Yes│" .. (" "):rep(gap) .. "│No│"),
            pad((" "):rep(yes_x) .. "╰───╯" .. (" "):rep(gap) .. "╰──╯"),
        }
        confirm_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = confirm_buf })
        local back = vim.api.nvim_get_current_win()
        local hh = #lines + 2
        confirm_win = vim.api.nvim_open_win(confirm_buf, true, {
            relative = "editor",
            row = math.floor((vim.o.lines - hh) / 2),
            col = math.floor((vim.o.columns - (w + 2)) / 2),
            width = w,
            height = #lines,
            border = "rounded",
            style = "minimal",
            zindex = 300,
        })
        vim.api.nvim_buf_set_lines(confirm_buf, 0, -1, false, lines)
        -- enter=true is ignored when we are called from a mouse-release
        -- handler (nvim refuses focus changes inside mapping callbacks), so
        -- the dialog's own buffer-local key/LeftRelease maps would never be
        -- the lookup context. Claim focus as soon as the handler unwinds.
        vim.schedule(function()
            if confirm_win and vim.api.nvim_win_is_valid(confirm_win) then
                pcall(vim.api.nvim_set_current_win, confirm_win)
            end
        end)
        local function answer(yes)
            close_confirm()
            if back and vim.api.nvim_win_is_valid(back) then
                vim.api.nvim_set_current_win(back)
            end
            if yes then
                on_yes()
            end
        end
        for _, k in ipairs({ "y", "Y", "<CR>" }) do
            vim.keymap.set("n", k, function()
                answer(true)
            end, { buffer = confirm_buf, nowait = true })
        end
        for _, k in ipairs({ "n", "N", "q", "<Esc>" }) do
            vim.keymap.set("n", k, function()
                answer(false)
            end, { buffer = confirm_buf, nowait = true })
        end
        vim.keymap.set({ "n", "i" }, "<LeftRelease>", function()
            local mp = vim.fn.getmousepos()
            local wi = confirm_win and vim.api.nvim_win_is_valid(confirm_win)
                and vim.fn.getwininfo(confirm_win)[1]
            if not wi or mp.winid ~= confirm_win then
                return
            end
            -- getmousepos().line/column mis-map cells once a row contains
            -- ambiguous-width box glyphs (U+2500 family), so hit-test in
            -- SCREEN cells instead: winrow/wincol are the 1-based window
            -- origin (border cell), so r/c equal buffer row/col + 1. The
            -- boxes occupy visual rows 3..5, Yes cols yes_x+1..yes_x+5,
            -- No cols no_x+1..no_x+4.
            local r = mp.screenrow - wi.winrow
            local c = mp.screencol - wi.wincol
            if r < 3 or r > 5 then
                return
            end
            if c >= yes_x + 1 and c < yes_x + 6 then
                answer(true)
            elseif c >= no_x + 1 and c < no_x + 5 then
                answer(false)
            end
        end, { buffer = confirm_buf, noremap = true })
    end
    local function replace_all()
        if params.pattern == "" or params.replacement == "" or not last_res or last_res.total == 0 then
            status.text = "Nothing to replace"
            return
        end
        local prompt = ("Replace %d matches in %d files?"):format(last_res.total, #last_res.files)
        open_confirm(prompt, function()
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
        end)
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
            line:append(Text((node:is_expanded() and (icons.tree_expanded .. " ") or (icons.tree_collapsed .. " ")) .. node.rel .. "  (" .. node.count .. ")", "Directory"))
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
        -- click a result row to select it: resolve the clicked buffer line
        -- to its tree node and run the real select action (see below).
        on_mount = function(self)
            arm_mouse(self, function(mp)
                when_focused(self, function()
                    -- A click does not move the tree's STORED focused
                    -- node (only key navigation does), and synthesizing
                    -- <CR> would activate that stale node — resolve the
                    -- clicked buffer line to its node and select it.
                    local tree = self:get_tree()
                    local node = tree and tree:get_node(math.max(1, mp.line))
                    if node then
                        self:set_focused_node(node)
                        local actions = self:get_actions()
                        if actions and actions.on_select then
                            actions.on_select()
                        end
                    end
                end)
            end)
        end,
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

    -- zc: VS Code "collapse all files", toggling to expand-all when every
    -- file section is already collapsed. Line/preview children keep their
    -- expanded state, so re-expanding a file reveals previews as rendered.
    local function toggle_collapse_all()
        if #tree_data == 0 then
            return
        end
        local any_open = false
        for _, file_node in ipairs(tree_data) do
            any_open = any_open or file_node:is_expanded()
        end
        for _, file_node in ipairs(tree_data) do
            if any_open then
                file_node:collapse()
            else
                file_node:expand()
            end
        end
        -- get_tree():render() is the SAME incremental path on_select uses for
        -- a single file: set_nodes() cannot be called twice over the same
        -- node objects (initialize_nodes appends to _child_ids and drops
        -- __children), so redraw() here would corrupt nui's id map.
        local tree = tree_comp:get_tree()
        if tree then
            tree:render()
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

    -- flex=1: it lives inside the horizontal columns row now (with the toggle
    -- boxes), so it needs to claim the leftover width; without it the
    -- bordered input collapses to a 3x3 box.
    local ti_search = n.text_input({
        autofocus = true,
        max_lines = 1,
        flex = 1,
        border_label = "Search",
        placeholder = "search text",
        value = opts.pattern or "",
        on_change = function(value)
            params.pattern = value
            schedule()
        end,
        on_mount = function(self)
            arm_input(self)
        end,
    })
    -- VS Code find-widget look: every toggle is a small rounded box whose
    -- interior FILLS while the option is ON. nui-components Button paints
    -- `is_active` with the NuiComponentsButton{Active,Focused} highlight
    -- groups — the library defines none of them — so define the fill here
    -- (default = true: a user/theme override still wins). A bordered box is
    -- exactly as tall as the bordered Search input, so the row aligns without
    -- the old checkboxes' top-padding hack.
    vim.api.nvim_set_hl(0, "NuiComponentsButtonActive", { reverse = true, default = true })
    vim.api.nvim_set_hl(0, "NuiComponentsButtonFocused", { underline = true, default = true })

    -- field = toggles key; param = params key the engine reads (nil for the
    -- replace-mode button, which only reveals widgets); guard = predicate
    -- that blocks the GLOBAL hotkey while the box itself is hidden.
    local function toggle_button(field, param, label, key, extra, guard)
        local function press()
            if guard and not guard() then
                return
            end
            local value = not toggles:get_value()[field]
            toggles[field] = value
            if param then
                params[param] = value
            end
            if extra then
                extra(value)
            end
        end
        return n.button({
            label = label,
            border_style = "rounded",
            is_active = toggles[field],
            global_press_key = key,
            on_press = press,
            on_mount = function(self)
                arm_mouse(self, press)
            end,
        })
    end
    local tb_case = toggle_button("case", "case_sensitive", icons.case, "<A-c>", schedule)
    local tb_regex = toggle_button("regex", "regex", icons.regex, "<A-r>", schedule)
    -- ab is ALWAYS mounted (VS Code keeps its whole-word button permanent):
    -- showing/hiding it would re-flow the flex row and resize the search box
    -- on every mode switch, which is exactly what a find widget must not do.
    local tb_whole = toggle_button("whole", "whole_word", icons.whole_word, "<A-w>", schedule)
    -- The replace-mode toggle is an ICON box (VS Code shows a chevron there,
    -- not the word): ⇄ sits RIGHT of Search — the first Tab stop after the
    -- input (VS Code's find-widget flow: search → Tab → toggle) — and
    -- reveals/hides the replace ROW (Replace input · AB · ⇉). Leaving replace
    -- mode also drops preserve-case so a hidden box can never silently reshape
    -- replacements.
    local tb_mode = toggle_button("replace", nil, icons.replace_mode, nil, function(value)
        if not value and toggles:get_value().preserve then
            toggles.preserve = false
            params.preserve_case = false
            schedule()
        end
        -- Re-attach Alt/? maps so the freshly visible widgets participate.
        -- defer (not schedule): the renderer recomputes its focusable list
        -- in its OWN queued redraw; attaching one tick later sees the new
        -- widgets instead of the stale pre-toggle list.
        vim.defer_fn(attach_panel_maps, 60)
    end)
    -- discoverability for the keymap overlay: the panel-local `?` mapping
    -- works, but a visible box tells the user the help exists. Same float.
    local tb_help = n.button({
        label = icons.help,
        border_style = "rounded",
        on_press = function(self)
            toggle_help(self.winid)
        end,
        on_mount = function(self)
            arm_mouse(self, function()
                toggle_help(self.winid)
            end)
        end,
    })
    -- VS Code's preserve-case ("AB") box lives in the REPLACE ROW (hidden
    -- with it); its Alt+P hotkey is guarded because global_press_key also
    -- fires while the row is hidden.
    local tb_preserve = toggle_button("preserve", "preserve_case", icons.preserve_case, "<A-p>", schedule, function()
        return toggles:get_value().replace
    end)
    local ti_replace = n.text_input({
        border_label = "Replace",
        max_lines = 1,
        -- flex=1: shares the replace row with the AB and ⇉ boxes
        flex = 1,
        on_change = function(value)
            params.replacement = value
            schedule()
        end,
        on_mount = function(self)
            arm_input(self)
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
        on_mount = function(self)
            arm_input(self)
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
    -- Replace All becomes the VS Code-style double-arrow ICON box ⇉; it
    -- lives in the replace row and asks a Yes/No dialog before applying.
    local btn_replace = n.button({
        label = icons.replace_all,
        border_style = "rounded",
        -- <C-A-CR> normalizes to <M-C-CR> (Neovim multi-modifier keycodes;
        -- delivered by kitty-keyboard/CSI-u terminals such as WezTerm).
        global_press_key = "<C-A-CR>",
        on_press = replace_all,
        on_mount = function(self)
            arm_mouse(self, replace_all)
        end,
    })

    -- 50/50 split: the search row (input + ⇄ + ab + Aa + .* + ?) needs the
    -- sidebar wide enough that flex=1 still leaves a usable input at ~80-col
    -- terminals; the tree truncates gracefully. The replace row hides as a
    -- WHOLE ROW (is_hidden walks the parent chain, so its children leave the
    -- layout AND the Tab cycle with it — no blank row while search-only).
    local sidebar = n.form(
        { flex = 50 },
        n.columns(
            { flex = 0, size = 1 },
            ti_search,
            -- one blank column keeps every box border clear of its neighbours
            n.gap(1),
            tb_mode,
            n.gap(1),
            tb_whole,
            n.gap(1),
            tb_case,
            n.gap(1),
            tb_regex,
            n.gap(1),
            tb_help
        ),
        n.columns(
            { flex = 0, size = 1, hidden = hidden_unless_replace() },
            ti_replace,
            n.gap(1),
            tb_preserve,
            n.gap(1),
            btn_replace
        ),
        ti_include
    )

    local status_par = n.paragraph({ lines = status.text, is_focusable = false, size = 1 })
    local right = n.rows({ flex = 50 }, status_par, tree_comp)
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
    local ns_help = vim.api.nvim_create_namespace("vscode-search-replace-help")
    local HELP_HEADER = "vscode-search-replace — keymaps"
    -- Sections, not a flat list: the overlay is the discoverability surface,
    -- so group rows by intent and color keys apart from descriptions.
    -- Descriptions interpolate cfg.icons so the help always names the glyphs
    -- the panel actually shows.
    local HELP_SECTIONS = {
        { "Navigation", {
            { "<Tab> / <S-Tab>", "next / previous panel" },
            { "Alt+h / Alt+l", "sidebar <-> results tree" },
            { "Alt+j / Alt+k", "previous / next panel" },
            { "Enter / Space / click", "activate the focused widget" },
        } },
        { "Search", {
            { "Alt+C", ("toggle %s  match case"):format(icons.case) },
            { "Alt+W", ("toggle %s  whole word"):format(icons.whole_word) },
            { "Alt+R", ("toggle %s  regular expression"):format(icons.regex) },
            { ("%s box"):format(icons.replace_mode), "show/hide the replace row" },
        } },
        { "Replace", {
            { "Alt+P", ("toggle %s  preserve case"):format(icons.preserve_case) },
            { ("Ctrl+Alt+Enter / %s box"):format(icons.replace_all), "Replace All" },
            { "y / n  ·  Enter / Esc", "answer the Replace All dialog" },
        } },
        { "Results", {
            { "j / k", "move between rows" },
            { "Enter / click", "jump to the selected match" },
            { "zc", "collapse all files — press again to expand" },
        } },
        { "General", {
            { ("? / the %s box"):format(icons.help), "show/hide this help" },
            { "q / Esc / <leader>fs", "close the panel" },
        } },
    }
    local help_buf, help_win = nil, nil
    local function close_help()
        if help_win and vim.api.nvim_win_is_valid(help_win) then
            vim.api.nvim_win_close(help_win, true)
        end
        help_win, help_buf = nil, nil
    end
    toggle_help = function(back_win)
        if help_win and vim.api.nvim_win_is_valid(help_win) then
            close_help()
            if back_win and vim.api.nvim_win_is_valid(back_win) then
                vim.api.nvim_set_current_win(back_win)
            end
            return
        end
        help_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = help_buf })
        local lines = { HELP_HEADER }
        -- row is the 0-based index the line WILL have once appended
        local marks = { { row = 0, col = #HELP_HEADER, hl = "Label" } }
        for _, section in ipairs(HELP_SECTIONS) do
            table.insert(lines, "")
            table.insert(marks, { row = #lines, col = #section[1], hl = "Function" })
            table.insert(lines, section[1])
            for _, kv in ipairs(section[2]) do
                local key, desc = kv[1], kv[2]
                table.insert(marks, { row = #lines, col = #key, hl = "Special" })
                -- Pad by DISPLAY width: "⇄" is 3 bytes but 1 cell, so %-24s
                -- would misalign the row.
                table.insert(lines, key .. (" "):rep(math.max(1, 24 - vim.fn.strwidth(key))) .. desc)
            end
        end
        -- clamp so a short editor can never fail nvim_open_win
        local w = math.min(70, vim.o.columns - 4)
        local h = math.min(#lines + 2, vim.o.lines - 2)
        help_win = vim.api.nvim_open_win(help_buf, true, {
            relative = "editor",
            row = math.floor((vim.o.lines - h) / 2),
            col = math.floor((vim.o.columns - w) / 2),
            width = w,
            height = h,
            border = "rounded",
            style = "minimal",
            zindex = 300,
        })
        vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
        for _, m in ipairs(marks) do
            vim.api.nvim_buf_set_extmark(help_buf, ns_help, m.row, 0, { end_col = m.col, hl_group = m.hl })
        end
        for _, k in ipairs({ "?", "q", "<Esc>", "i" }) do
            vim.keymap.set("n", k, function()
                toggle_help(back_win)
            end, { buffer = help_buf, nowait = true })
        end
    end

    -- Walk by LIVE index (renderer recomputes get_focusable_components() on
    -- every redraw) instead of captured next/prev closures: a widget shown or
    -- hidden after the last attach can then never be skipped or mis-wired.
    -- attach_panel_maps still re-registers maps on freshly visible components
    -- (c:map re-registration is idempotent).
    local function sibling(cur, dir)
        local list = renderer:get_focusable_components()
        for i, x in ipairs(list) do
            if x == cur then
                return list[(i - 1 + dir) % #list + 1]
            end
        end
        return list[1]
    end
    attach_panel_maps = function()
        for _, c in ipairs(renderer:get_focusable_components()) do
            c:map("n", "?", function()
                toggle_help(c.winid)
            end, { noremap = true })
            c:map("n", "zc", toggle_collapse_all, { noremap = true })
            for _, m in ipairs({ "n", "i" }) do
                c:map(m, "<A-j>", function()
                    focus_component(sibling(c, 1))
                end, { noremap = true })
                c:map(m, "<A-k>", function()
                    focus_component(sibling(c, -1))
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
    end
    attach_panel_maps()

    -- prefill from cword/selection: search immediately, skip the debounce
    if params.pattern ~= "" then
        run_search()
    end
    -- n+i so the toggle closes from inside the (insert-mode) text inputs;
    -- buffer-local maps win over the global <leader>fs opener while mounted.
    renderer:add_mappings({
        { mode = "n", key = "q", handler = close },
        { mode = { "n", "i" }, key = "<leader>S", handler = close },
        { mode = { "n", "i" }, key = "<leader>fs", handler = close },
    })

    return { close = close }
end

return M
