---@toc_entry Picker
---@tag haunt-picker
---@text
--- # Picker ~
---
--- The picker provides an interactive interface to browse and manage bookmarks.
--- Supports Snacks.nvim (https://github.com/folke/snacks.nvim) and
--- Telescope.nvim (https://github.com/nvim-telescope/telescope.nvim).
--- Falls back to vim.ui.select for basic functionality if neither is available.
---
--- Configure which picker to use via |HauntConfig|.picker:
---   - `"auto"` (default): Try Snacks first, then Telescope, then vim.ui.select
---   - `"snacks"`: Use Snacks.nvim picker
---   - `"telescope"`: Use Telescope.nvim picker
---
--- Picker actions: ~
---   - `<CR>`: Jump to the selected bookmark
---   - `d` (normal mode): Delete the selected bookmark
---   - `a` (normal mode): Edit the bookmark's annotation
---
--- The keybindings can be customized via |HauntConfig|.picker_keys.

---@class PickerRouter
---@field show fun(opts?: table) Show the bookmark picker

---@type PickerRouter
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
---@type HauntModule|nil
local haunt = nil

---@private
local function ensure_modules()
	if not haunt then
		haunt = require("haunt")
	end
end

--- Open the bookmark picker.
---
--- Displays all bookmarks in an interactive picker. The picker used depends
--- on the |HauntConfig|.picker setting:
---   - `"auto"` (default): Try Snacks first, then Telescope, then vim.ui.select
---   - `"snacks"`: Use Snacks.nvim picker
---   - `"telescope"`: Use Telescope.nvim picker
---
--- Allows jumping to, deleting, or editing bookmark annotations.
---
--- Note: The opts parameter is passed directly to the underlying picker
--- implementation. It is up to the user to ensure they're passing the
--- correct type for their configured picker. Consider annotating the type
--- yourself, e.g.:
--- >lua
---   ---@type snacks.picker.Config
---   local opts = { ... }
---   require('haunt.picker').show(opts)
--- <
---
---@usage >lua
---   -- Show the picker
---   require('haunt.picker').show()
---<
---@param opts? table Options passed to the underlying picker
function M.show(opts)
	ensure_modules()
	---@cast haunt -nil

	local cfg = haunt.get_config()
	local picker_type = cfg.picker or "auto"

	-- Load picker implementations
	local snacks_picker = require("haunt.picker.snacks")
	local telescope_picker = require("haunt.picker.telescope")
	local fallback_picker = require("haunt.picker.fallback")

	-- Set parent module reference for reopening after edit
	snacks_picker.set_picker_module(M)
	telescope_picker.set_picker_module(M)

	-- Handle explicit picker selection
	if picker_type == "snacks" then
		if not snacks_picker.show(opts) then
			vim.notify("haunt.nvim: Snacks.nvim is not available", vim.log.levels.WARN)
		end
		return
	end

	if picker_type == "telescope" then
		if not telescope_picker.show(opts) then
			vim.notify("haunt.nvim: Telescope.nvim is not available", vim.log.levels.WARN)
		end
		return
	end

	-- Auto mode: try Snacks first, then Telescope, then vim.ui.select fallback
	if snacks_picker.show(opts) then
		return
	end

	if telescope_picker.show(opts) then
		return
	end

	fallback_picker.show()
end

return M
