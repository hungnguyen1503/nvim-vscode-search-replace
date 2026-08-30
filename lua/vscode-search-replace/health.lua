local M = {}

-- The vim.health.start/ok/warn/error surface appeared in Nvim 0.11; 0.10 only
-- ships the report_* functions. The plugin itself runs on 0.10 (vim.uv,
-- vim.system), so support both instead of crashing :checkhealth there.
local hs, hp = vim.health.start, vim.health
if not hs then
    hs = vim.health.report_start
    hp = {
        ok = vim.health.report_ok,
        warn = vim.health.report_warn,
        error = vim.health.report_error,
    }
end

function M.check()
    hs("vscode-search-replace")
    local v = vim.version()
    if v.major == 0 and v.minor < 10 then
        hp.warn("Neovim >= 0.10 recommended (vim.uv / vim.system)")
    else
        hp.ok(string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch))
    end
    if vim.fn.executable("rg") == 1 then
        local out = vim.system({ "rg", "--version" }, { text = true }):wait()
        local first = (out.stdout or ""):match("[^\r\n]+")
        hp.ok("ripgrep found: " .. (first or "?"))
    else
        hp.error("`rg` (ripgrep) not found on PATH — searches will fail")
    end
end

return M
