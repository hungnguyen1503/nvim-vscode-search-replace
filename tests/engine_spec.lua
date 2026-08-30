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
    vim.fn.writefile(lines, vim.fs.joinpath(dir, name), "b")
  end
  return dir
end

local function run_search(dir, o)
  local res, done
  engine.search(params(vim.tbl_extend("force", { path = dir }, o)), function(r)
    res = r
    done = true
  end)
  local ok = vim.wait(10000, function() return done end)
  assert(ok, "search timed out")
  assert.is_nil(res.error)
  return res
end

describe("engine.build_rg_cmd", function()
  it("always passes machine flags and a -e/-- separator", function()
    local cmd = engine.build_rg_cmd(params({ pattern = "x", path = "/tmp/p" }))
    assert.are.same({ "rg", "--json", "--no-heading", "--color", "never", "--line-number" }, { unpack(cmd, 1, 6) })
    assert.are.same({ "-e", "x", "--", "/tmp/p" }, { unpack(cmd, #cmd - 3) })
  end)

  it("adds -F/-i for literal / case-insensitive modes", function()
    local has = function(cmd, flag) return vim.list_contains(cmd, flag) end
    assert.is_true(has(engine.build_rg_cmd(params({ regex = false, case_sensitive = true, pattern = "x", path = "." })), "-F"))
    assert.is_not_true(has(engine.build_rg_cmd(params({ regex = true, case_sensitive = true, pattern = "x", path = "." })), "-F"))
    assert.is_true(has(engine.build_rg_cmd(params({ regex = true, case_sensitive = false, pattern = "x", path = "." })), "-i"))
  end)

  it("globs live before the pattern; plain paths get a /** companion", function()
    local cmd = engine.build_rg_cmd(params({ pattern = "x", path = ".", include = "src,*.lua," }))
    local gi
    for i = 1, #cmd do
      if cmd[i] == "--glob" then
        gi = i
        break
      end
    end
    assert(gi, "no --glob in " .. table.concat(cmd, " "))
    assert.are.same({ "--glob", "src", "--glob", "src/**", "--glob", "*.lua" }, { unpack(cmd, gi, gi + 5) })
  end)
end)

describe("engine pattern/replacement translation", function()
  it("wraps regex in \\v and literal in \\V with backslash escaping", function()
    assert.are.equal([[\v(foo)\C]], engine.build_vim_pattern(params({ regex = true, pattern = "(foo)" })))
    -- \V makes "." literal already; only backslashes get escaped
    assert.are.equal([[\Vfoo.bar\c]], engine.build_vim_pattern(params({ regex = false, case_sensitive = false, pattern = "foo.bar" })))
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
  end)
end
