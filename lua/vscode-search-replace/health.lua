local M = {}

function M.check()
    vim.health.start("vscode-search-replace")
    local v = vim.version()
    if v.major == 0 and v.minor < 10 then
        vim.health.warn("Neovim >= 0.10 recommended (vim.uv / vim.system)")
    else
        vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
    end
    if vim.fn.executable("rg") == 1 then
        local out = vim.system({ "rg", "--version" }, { text = true }):wait()
        local first = (out.stdout or ""):match("[^\r\n]+")
        vim.health.ok("ripgrep found: " .. (first or "?"))
    else
        vim.health.error("`rg` (ripgrep) not found on PATH — searches will fail")
    end
end

return M
