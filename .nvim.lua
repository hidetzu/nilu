-- Nilu's syntax is Lua 5.5's: open .nilu files as Lua in this repository.
-- Neovim reads this file only with 'exrc' set, once you have trusted it (:trust).
vim.filetype.add({ extension = { nilu = "lua" } })
