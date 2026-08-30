if vim.g.did_load_vscode_search_replace then
    return
end
vim.g.did_load_vscode_search_replace = true

vim.api.nvim_create_user_command("SearchReplace", function()
    require("vscode-search-replace").open()
end, { desc = "VS Code-style search & replace" })

vim.api.nvim_set_hl(0, "VSCodeSearchOld", { link = "DiffDelete", default = true })
vim.api.nvim_set_hl(0, "VSCodeSearchNew", { link = "DiffAdd", default = true })
vim.api.nvim_set_hl(0, "NuiComponentsButtonActive", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "NuiComponentsButtonFocused", { link = "CursorLine", default = true })
vim.api.nvim_set_hl(0, "NuiComponentsCheckboxLabelChecked", { link = "Directory", default = true })
vim.api.nvim_set_hl(0, "NuiComponentsCheckboxIconChecked", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "NuiComponentsTreeNodeFocused", { link = "IncSearch", default = true })
