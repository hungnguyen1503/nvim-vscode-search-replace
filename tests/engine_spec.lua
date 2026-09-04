local engine = require("vscode-search-replace.engine")
local assert = require("luassert")

local function params(o)
  return setmetatable(o or {}, { __index = { regex = false, case_sensitive = true, include = "" } })
end

-- Fresh throwaway project directory; written files are absolute-pathed.
local function fixture(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for name, lines in pairs(files) do
    local p = vim.fs.joinpath(dir, name)
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    vim.fn.writefile(lines, p, "b")
  end
  return dir
end

local function run_search(dir, o, sopts)
  local res
  engine.search(params(vim.tbl_extend("force", { path = dir }, o)), function(r)
    res = r
  end, sopts)
  -- on_done may fire repeatedly while streaming; the contract is that the
  -- LAST call carries final=true.
  local ok = vim.wait(10000, function() return res and res.final end)
  assert(ok, "search timed out")
  assert.is_nil(res.error)
  return res
end

describe("engine.build_rg_cmd", function()
  -- every user --glob value, skipping the built-in .git exclusion
  local function user_globs(cmd)
    local g = {}
    for i = 1, #cmd - 1 do
      if cmd[i] == "--glob" and cmd[i + 1] ~= "!.git/" then
        g[#g + 1] = cmd[i + 1]
      end
    end
    return g
  end
  it("always passes machine flags and a -e/-- separator", function()
    local cmd = engine.build_rg_cmd(params({ pattern = "x", path = "/tmp/p" }))
    assert.are.same(
      { "rg", "--json", "--no-heading", "--color", "never", "--line-number", "--no-messages" },
      { unpack(cmd, 1, 7) }
    )
    assert.are.same({ "-e", "x", "--", "/tmp/p" }, { unpack(cmd, #cmd - 3) })
  end)

  it("adds -F/-i for literal / case-insensitive modes", function()
    local has = function(cmd, flag) return vim.list_contains(cmd, flag) end
    assert.is_true(has(engine.build_rg_cmd(params({ regex = false, case_sensitive = true, pattern = "x", path = "." })), "-F"))
    assert.is_not_true(has(engine.build_rg_cmd(params({ regex = true, case_sensitive = true, pattern = "x", path = "." })), "-F"))
    assert.is_true(has(engine.build_rg_cmd(params({ regex = true, case_sensitive = false, pattern = "x", path = "." })), "-i"))
  end)

  it("adds --word-regexp after -F when whole_word is set", function()
    local cmd = engine.build_rg_cmd(params({ whole_word = true, case_sensitive = false, pattern = "foo", path = "." }))
    assert.are.same(
      { "rg", "--json", "--no-heading", "--color", "never", "--line-number", "--no-messages",
        "-i", "-F", "--word-regexp", "--glob", "!.git/", "-e", "foo", "--", "." },
      cmd
    )
  end)

  it("the .git exclusion precedes user globs; plain paths get a /** companion", function()
    local cmd = engine.build_rg_cmd(params({ pattern = "x", path = ".", include = "src,*.lua," }))
    local gi
    for i = 1, #cmd - 1 do
      if cmd[i] == "--glob" and cmd[i + 1] == "!.git/" then
        gi = i
        break
      end
    end
    assert(gi, "no .git exclusion in " .. table.concat(cmd, " "))
    assert.are.same(
      { "--glob", "!.git/", "--glob", "src", "--glob", "src/**", "--glob", "*.lua" },
      { unpack(cmd, gi, gi + 7) }
    )
    -- exclusion lives inside the glob section, before -e
    for i = 1, #cmd do
      if cmd[i] == "-e" then
        assert.is_true(gi < i, ".git glob after the pattern?")
        break
      end
    end
  end)

  it("adds --no-ignore / --hidden only when the toggles set them; .git is always excluded", function()
    local has = function(cmd, flag) return vim.list_contains(cmd, flag) end
    local base = { pattern = "x", path = "." }
    local off = engine.build_rg_cmd(params(base))
    assert.is_false(has(off, "--no-ignore"))
    assert.is_false(has(off, "--hidden"))
    assert.is_true(has(off, "!.git/"))
    local on = vim.tbl_extend("force", base, { no_ignore = true, hidden = true })
    local cmd = engine.build_rg_cmd(params(on))
    assert.is_true(has(cmd, "--no-ignore"))
    assert.is_true(has(cmd, "--hidden"))
    assert.is_true(has(cmd, "!.git/"))
  end)

  it("normalizes an absolute include under the search root to relative globs", function()
    local cmd = engine.build_rg_cmd(
      params({ pattern = "x", path = "C:/repo/app", include = "C:/repo/app/src/mcu" })
    )
    assert.are.same({ "src/mcu", "src/mcu/**", "**/src/mcu/**" }, user_globs(cmd))
  end)

  it("drops an include equal to the root and strips workspace-relative slashes on Windows", function()
    local root_only = engine.build_rg_cmd(
      params({ pattern = "x", path = "C:/repo/app/", include = "C:/repo/app" })
    )
    assert.are.same({ "!.git/" }, (function()
      local g = {}
      for i = 1, #root_only - 1 do
        if root_only[i] == "--glob" then g[#g + 1] = root_only[i + 1] end
      end
      return g
    end)())
    local ws_rel = engine.build_rg_cmd(
      params({ pattern = "x", path = "C:/repo/app", include = "/src" })
    )
    assert.are.same({ "src", "src/**" }, user_globs(ws_rel))
  end)
end)

describe("engine pattern/replacement translation", function()
  it("wraps regex in \\v and literal in \\V with backslash escaping", function()
    assert.are.equal([[\v(foo)\C]], engine.build_vim_pattern(params({ regex = true, pattern = "(foo)" })))
    -- \V makes "." literal already; only backslashes get escaped
    assert.are.equal([[\Vfoo.bar\c]], engine.build_vim_pattern(params({ regex = false, case_sensitive = false, pattern = "foo.bar" })))
  end)

  it("whole-word wraps bounds without shifting user capture groups", function()
    assert.are.equal([[\v%(<%(a|b)>)\C]], engine.build_vim_pattern(params({ regex = true, whole_word = true, pattern = "a|b" })))
    assert.are.equal(
      [[\V\<foo.bar\>\c]],
      engine.build_vim_pattern(params({ regex = false, case_sensitive = false, whole_word = true, pattern = "foo.bar" }))
    )
    -- word boundaries require the match start/end be keyword chars, so wrap a
    -- real word (foo_bar); the inner %() is non-capturing so \1 stays the first
    -- user group (a capturing wrapper would yield "foo_bar|foo").
    assert.are.equal(
      "pre foo|bar post",
      engine.substitute_line("pre foo_bar post", params({ regex = true, whole_word = true, pattern = [[(\w+)_(\w+)]], replacement = [[\1|\2]] }))
    )
  end)

  it("whole-word literal substitute skips foo_bar and bazfoo", function()
    assert.are.equal(
      "X foo_bar bazfoo",
      engine.substitute_line("foo foo_bar bazfoo", params({ whole_word = true, replacement = "X", pattern = "foo" }))
    )
  end)

  it("escapes & and % in replacements; \\1 passes through (substitute expands it)", function()
    assert.are.equal([[a\&b\%c\1]], engine.to_vim_repl([[a&b%c\1]]))
  end)

  it("substitutes literal dots and case-insensitively", function()
    assert.are.equal("X-a", engine.substitute_line("a.b-a", params({ replacement = "X", pattern = "a.b" })))
    -- "cook" under \c matches all four letters of "Cook"
    assert.are.equal("X", engine.substitute_line("Cook", params({ case_sensitive = false, replacement = "X", pattern = "cook" })))
  end)

  it("supports \\1..\\9 capture references in regex mode", function()
    assert.are.equal(
      "bar foo",
      engine.substitute_line("foo bar", params({ regex = true, pattern = "(foo) (bar)", replacement = "\\2 \\1" }))
    )
  end)

  it("returns the line unchanged for broken regexes (apply-time crash guard)", function()
    assert.are.equal("intact(line", engine.substitute_line("intact(line", params({ regex = true, pattern = "(unclosed", replacement = "x" })))
  end)
end)

describe("engine preserve_case", function()
  local function pc(o)
    return params(vim.tbl_extend("force", { preserve_case = true, case_sensitive = false }, o))
  end

  it("recases ALLCAPS and Title matches; others keep the typed replacement", function()
    assert.are.equal("bar BAR Bar baz", engine.substitute_line("foo FOO Foo baz", pc({ pattern = "foo", replacement = "bar" })))
  end)

  it("mixed-case matches leave the replacement untouched", function()
    assert.are.equal("BAR bar bar", engine.substitute_line("FOO fOO foo", pc({ pattern = "foo", replacement = "bar" })))
  end)

  it("expands \\0..\\9 and keeps & literal like the plain path", function()
    assert.are.equal("OOF oof", engine.substitute_line("FOO foo", pc({ pattern = "(f)(oo)", regex = true, replacement = "\\2\\1" })))
    assert.are.equal("a&b & A&B", engine.substitute_line("foo & FOO", pc({ pattern = "foo", replacement = "a&b" })))
  end)

  it("survives single quotes in the replacement (VimL literal escaping)", function()
    assert.are.equal("it's it's", engine.substitute_line("it's foo", pc({ pattern = "foo", replacement = "it's" })))
  end)

  it("digit/symbol-only matches apply no case rule", function()
    assert.are.equal("x foo", engine.substitute_line("123 foo", pc({ pattern = "123", replacement = "x" })))
  end)

  it("composes with whole_word", function()
    assert.are.equal("X foo_bar baz", engine.substitute_line("FOO foo_bar baz", pc({ pattern = "foo", whole_word = true, replacement = "x" })))
  end)

  it("expand_repl mirrors substitute() replacement semantics", function()
    assert.are.equal("aQb\\c\nd", engine.expand_repl([[a\1b\\c\nd]], "Z", { "Q" }))
    assert.are.equal("&0", engine.expand_repl([[&0]], "Z0", {})) -- & stays literal (plain path escapes it)
    assert.are.equal("Z0", engine.expand_repl([[\0]], "Z0", {})) -- \0 is the whole-match back-reference
  end)
end)

-- the disk-writing suite needs ripgrep (CI installs it)
if vim.fn.executable("rg") == 1 then
  describe("engine search + apply", function()
    it("finds matches with line numbers and previews the replacement", function()
      local dir = fixture({
        ["a.lua"] = { "local function load_data()", "return load_data", "" },
        ["b.md"] = { "function docs only", "" },
      })
      local res = run_search(dir, { pattern = "function", replacement = "method" })
      assert.are.equal(2, res.total)
      local by_name = {}
      for _, f in ipairs(res.files) do
        by_name[vim.fn.fnamemodify(f.path, ":t")] = f
      end
      assert.are.equal(1, #by_name["a.lua"].matches)
      assert.are.equal(1, #by_name["b.md"].matches)
      local m = by_name["a.lua"].matches[1]
      assert.are.equal(1, m.lnum)
      assert.are.equal("local function load_data()", m.text)
      assert.are.equal("local method load_data()", m.new)
    end)

    it("honors the include filter", function()
      local dir = fixture({
        ["x.lua"] = { "needle", "" },
        ["y.md"] = { "needle", "" },
      })
      local res = run_search(dir, { pattern = "needle", include = "*.lua" })
      assert.are.equal(1, res.total)
      assert.matches("%.lua$", res.files[1].path)
    end)

    it("replaces on disk preserving CRLF and a missing final newline byte-exact", function()
      local dir = fixture({ ["win.txt"] = { "foo one\r", "two foo\r" } })
      local file = vim.fs.joinpath(dir, "win.txt")
      local res = run_search(dir, { pattern = "foo", replacement = "bar", include = "win.txt" })
      assert.are.equal(2, res.total)
      local out = engine.apply(res, params({ pattern = "foo", replacement = "bar", include = "win.txt" }))
      assert.are.equal(1, #out.written)
      assert.same({}, out.failed)
      assert.are.same({ "bar one\r", "two bar\r" }, vim.fn.readfile(file, "b"))
    end)

    it("preserves a final newline when present", function()
      local dir = fixture({ ["nl.txt"] = { "hello", "" } })
      local file = vim.fs.joinpath(dir, "nl.txt")
      local res = run_search(dir, { pattern = "hello", replacement = "bye", include = "nl.txt" })
      engine.apply(res, params({ pattern = "hello", replacement = "bye", include = "nl.txt" }))
      assert.are.same({ "bye", "" }, vim.fn.readfile(file, "b"))
    end)

    it("refuses to write a file that changed since the search", function()
      local dir = fixture({ ["s.txt"] = { "target one", "target two", "" } })
      local file = vim.fs.joinpath(dir, "s.txt")
      local res = run_search(dir, { pattern = "target", replacement = "done", include = "s.txt" })
      vim.fn.writefile({ "target one", "changed line", "" }, file, "b")
      local out = engine.apply(res, params({ pattern = "target", replacement = "done", include = "s.txt" }))
      assert.are.equal(0, #out.written)
      assert.are.equal(1, #out.failed)
      assert.matches("file changed since search", out.failed[1].reason)
    end)

    it("cancel() drops the in-flight callback", function()
      local dir = fixture({ ["big.lua"] = (function()
        local l = {}
        for i = 1, 5000 do l[i] = "line " .. i .. " needle" end
        return l
      end)(), ["more.lua"] = { "needle", "" } })
      local fired = false
      engine.search(params({ path = dir, pattern = "needle" }), function() fired = true end)
      engine.cancel()
      vim.wait(1500, function() return false end)
      assert.is_false(fired)
    end)

    it("whole_word narrows matched lines end-to-end on disk", function()
      -- total counts matched LINES; the embedded-only file drops out under -w
      local dir = fixture({
        ["hit.txt"] = { "standalone foo here", "" },
        ["miss.txt"] = { "foo_bar bazfoo", "" },
      })
      local base = { pattern = "foo", case_sensitive = false, replacement = "X" }
      assert.are.equal(2, run_search(dir, base).total)
      local res = run_search(dir, vim.tbl_extend("keep", base, { whole_word = true }))
      assert.are.equal(1, res.total)
      assert.matches("hit.txt$", res.files[1].path)
      assert.are.equal("standalone X here", res.files[1].matches[1].new)
      local out = engine.apply(res, params(vim.tbl_extend("keep", base, { whole_word = true })))
      assert.are.equal(1, #out.written)
      assert.are.same({ "standalone X here", "" }, vim.fn.readfile(vim.fs.joinpath(dir, "hit.txt"), "b"))
      assert.are.same({ "foo_bar bazfoo", "" }, vim.fn.readfile(vim.fs.joinpath(dir, "miss.txt"), "b"))
    end)

    it("preserve_case rewrites the file with per-match casing end-to-end", function()
      local dir = fixture({ ["c.txt"] = { "foo FOO Foo keep", "" } })
      local base = { pattern = "foo", replacement = "bar", include = "c.txt", preserve_case = true, case_sensitive = false }
      local res = run_search(dir, base)
      assert.are.equal("bar BAR Bar keep", res.files[1].matches[1].new)
      local out = engine.apply(res, params(base))
      assert.are.equal(1, #out.written)
      assert.are.same({ "bar BAR Bar keep", "" }, vim.fn.readfile(vim.fs.joinpath(dir, "c.txt"), "b"))
    end)

    it("streams: intermediate deliveries carry final=false, the last one final=true", function()
      local lines = {}
      for i = 1, 3000 do
        lines[i] = "line " .. i .. " needle"
      end
      local dir = fixture({ ["big.lua"] = lines })
      local calls = {}
      -- every delivery passes the SAME res table; snapshot primitives so the
      -- per-call assertions observe the state at callback time.
      engine.search(params({ path = dir, pattern = "needle" }), function(r)
        calls[#calls + 1] = { final = r.final, total = r.total, searches = r.searches }
      end, { max_stored = 5000 })
      vim.wait(10000, function() return calls[#calls] and calls[#calls].final end)
      local last = calls[#calls]
      assert.is_true(last.final)
      assert.are.equal(3000, last.total)
      assert.is_true((last.searches or 0) >= 1)
      local prev = 0
      for i = 1, #calls - 1 do
        assert.is_not_true(calls[i].final)
        assert.is_true(calls[i].total >= prev)
        prev = calls[i].total
      end
    end)

    it("stops storing at opts.max_stored and flags the result truncated", function()
      local lines = {}
      for i = 1, 4000 do
        lines[i] = "needle " .. i
      end
      local dir = fixture({ ["cap.txt"] = lines })
      local res = run_search(dir, { pattern = "needle" }, { max_stored = 250 })
      assert.is_true(res.truncated)
      assert.are.equal(250, res.total)
      local stored = 0
      for _, f in ipairs(res.files) do
        stored = stored + #f.matches
      end
      assert.are.equal(250, stored)
    end)

    it("an absolute include entry filters to that subtree end-to-end", function()
      local dir = fixture({
        ["root.txt"] = { "needle", "" },
        ["sub/in.txt"] = { "needle", "" },
      })
      local res = run_search(dir, { pattern = "needle", include = dir .. "/sub" })
      assert.are.equal(1, res.total)
      assert.matches("in.txt$", res.files[1].path)
    end)

    it("exposes searches so the UI can flag an include typo vs a real zero", function()
      local dir = fixture({ ["only.lua"] = { "needle", "" } })
      local res = run_search(dir, { pattern = "needle", include = "*.nomatch" })
      assert.are.equal(0, res.total)
      assert.are.equal(0, res.searches)
    end)

    it("opts.stream = false delivers exactly one final, fully-stored result", function()
      local dir = fixture({ ["s.lua"] = { "needle a", "needle b", "" } })
      local calls, res = 0, nil
      engine.search(params({ path = dir, pattern = "needle" }), function(r)
        calls = calls + 1
        res = r
      end, { stream = false })
      vim.wait(10000, function() return res and res.final end)
      assert.are.equal(1, calls)
      assert.are.equal(2, res.total)
      assert.are.equal(1, #res.files)
      assert.are.equal(2, #res.files[1].matches)
    end)
  end)
end
