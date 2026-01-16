--- Picker Integration for Haunt.nvim
---
--- This module implements a picker source for Snacks.nvim that displays all
--- bookmarks across files in the current repository/branch.
---
--- Features:
--- - Lists all bookmarks with file paths, line numbers, and annotations
--- - Jump to bookmarks with <CR>
--- - Delete bookmarks with 'd' key (configurable via setup)
--- - Edit bookmark annotations with 'a' key (configurable via setup)
--- - Automatically refreshes picker after modifications
--- - Handles cases where Snacks.nvim is not installed
---
--- Usage:
---   local picker = require('haunt.picker')
---   picker.show()  -- Opens the picker with all bookmarks
---
--- Integration with Snacks.nvim:
---   The picker uses Snacks.nvim's picker API to provide a consistent
---   user experience with other Snacks pickers. Items are formatted with
---   syntax highlighting and the picker supports custom actions.
---
---@class haunt.Picker
local M = {}

-- Required modules (loaded lazily)
---@type haunt.Api?
local api = nil
---@type haunt.Module?
local haunt = nil

--- Lazy load required modules
local function ensure_modules()
	if not api then
		api = require("haunt.api")
	end
	if not haunt then
		haunt = require("haunt")
	end
end

--- Execute a callback with buffer context temporarily switched
--- Switches to the target buffer, sets cursor position, executes callback, then safely restores
--- Uses pcall and validation to prevent errors when restoring picker buffer state
---@param bufnr number Target buffer number
---@param line number Line number to set cursor to
---@param callback function Function to execute in the target buffer context
---@return any The return value of the callback
local function with_buffer_context(bufnr, line, callback)
	-- Save current buffer and window
	local current_bufnr = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()
	local cursor_saved = vim.api.nvim_win_get_cursor(current_win)

	-- Ensure target buffer is loaded
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		vim.fn.bufload(bufnr)
	end

	-- Switch to target buffer
	vim.api.nvim_set_current_buf(bufnr)

	-- Move cursor to the bookmark line (with validation)
	-- Clamp line to valid range to avoid "Cursor position outside buffer" error
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local safe_line = math.min(math.max(1, line), line_count)
	pcall(vim.api.nvim_win_set_cursor, current_win, { safe_line, 0 })

	-- Execute the callback
	local result = callback()

	-- Safely restore original buffer with validation
	-- The picker buffer might not be in a valid state to restore, so use pcall
	if vim.api.nvim_buf_is_valid(current_bufnr) and vim.api.nvim_buf_is_loaded(current_bufnr) then
		-- Attempt to restore buffer - use pcall to handle any state errors
		pcall(vim.api.nvim_set_current_buf, current_bufnr)

		-- Only restore cursor if we successfully switched back to the original buffer
		if vim.api.nvim_get_current_buf() == current_bufnr then
			pcall(vim.api.nvim_win_set_cursor, current_win, cursor_saved)
		end
	end

	return result
end

--- Open the bookmark picker using Snacks.nvim
--- Displays all bookmarks with actions to open, delete, or edit annotations
---@return nil
function M.show()
	ensure_modules()
	---@cast api -nil
	---@cast haunt -nil

	-- Check if Snacks is available
	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("haunt.nvim: Snacks.nvim is not installed", vim.log.levels.ERROR)
		return
	end

	-- Check if there are any bookmarks
	local initial_bookmarks = api.get_bookmarks()
	if #initial_bookmarks == 0 then
		vim.notify("haunt.nvim: No bookmarks found", vim.log.levels.INFO)
		return
	end

	-- Get keybinding configuration
	local config = haunt.get_config()
	local picker_keys = config.picker_keys
		or {
			delete = { key = "d", mode = { "n" } },
			edit_annotation = { key = "a", mode = { "n" } },
		}

	-- Build keys table for Snacks picker in the correct format
	-- Keys need to be in both input and list windows so they work regardless of focus
	local input_keys = {}
	local list_keys = {}

	if picker_keys.delete then
		local key = picker_keys.delete.key or "d"
		local mode = picker_keys.delete.mode or { "n" }
		input_keys[key] = { "delete", mode = mode }
		list_keys[key] = { "delete", mode = mode }
	end

	if picker_keys.edit_annotation then
		local key = picker_keys.edit_annotation.key or "a"
		local mode = picker_keys.edit_annotation.mode or { "n" }
		input_keys[key] = { "edit_annotation", mode = mode }
		list_keys[key] = { "edit_annotation", mode = mode }
	end

	-- Create picker with custom actions
	Snacks.picker({
		-- Use a finder function so picker:refresh() works correctly
		finder = function()
			local bookmarks = api.get_bookmarks()
			local items = {}
			for i, bookmark in ipairs(bookmarks) do
				table.insert(items, {
					idx = i,
					score = i,
					file = bookmark.file,
					pos = { bookmark.line, 0 }, -- Position in file (line, col)
					note = bookmark.note,
					id = bookmark.id, -- Include bookmark ID for direct deletion
				})
			end
			return items
		end,
		-- Custom format that extends Snacks' file formatter with annotation
		format = function(item, picker)
			-- Use Snacks' file formatter as base
			local ret = Snacks.picker.format.file(item, picker)

			-- Add annotation if present (no extra space)
			if item.note and item.note ~= "" then
				ret[#ret + 1] = { item.note, "SnacksPickerComment" }
			end

			return ret
		end,
		formatters = {
			file = {
				filename_first = true, -- Display filename before the file path
				truncate = 60, -- Truncate the file path to roughly this length
			},
		},
		confirm = function(picker, item)
			if not item then
				return
			end
			picker:close()

			-- Open the file
			local bufnr = vim.fn.bufnr(item.file)
			if bufnr == -1 then
				-- File not loaded, open it
				vim.cmd("edit " .. vim.fn.fnameescape(item.file))
			else
				-- File already loaded, switch to it
				vim.cmd("buffer " .. bufnr)
			end

			-- Jump to the line
			vim.api.nvim_win_set_cursor(0, { item.line, 0 })

			-- Center the cursor
			vim.cmd("normal! zz")
		end,
		actions = {
			-- Delete bookmark action
			delete = function(picker, item)
				if not item then
					return
				end

				-- Delete the bookmark by its ID (no need for buffer context)
				local success = api.delete_by_id(item.id)

				if not success then
					vim.notify("haunt.nvim: Failed to delete bookmark", vim.log.levels.WARN)
					return
				end

				-- Check if there are any bookmarks left
				local remaining = api.get_bookmarks()
				if #remaining == 0 then
					picker:close()
					vim.notify("haunt.nvim: No bookmarks remaining", vim.log.levels.INFO)
					return
				end

				-- Refresh the picker to show updated list
				picker:refresh()
			end,

			-- Edit annotation action
			edit_annotation = function(picker, item)
				if not item then
					return
				end

				-- Prompt for new annotation
				local default_text = item.note or ""

				-- Close picker temporarily to show input prompt clearly
				picker:close()

				local annotation = vim.fn.input({
					prompt = "Annotation: ",
					default = default_text,
				})

				-- If user cancelled (ESC), annotation will be empty string
				-- Only proceed if something was entered or if clearing existing annotation
				if annotation == "" and default_text == "" then
					-- User cancelled with no existing annotation, reopen picker
					M.show()
					return
				end

				-- Open the file in a buffer if not already open
				local bufnr = vim.fn.bufnr(item.file)
				if bufnr == -1 then
					bufnr = vim.fn.bufadd(item.file)
					vim.fn.bufload(bufnr)
				end

				-- Use helper to execute annotate in the buffer context
				with_buffer_context(bufnr, item.line, function()
					api.annotate(annotation)
				end)

				-- Reopen the picker with updated data
				M.show()
			end,
		},
		win = {
			input = {
				keys = input_keys,
			},
			list = {
				keys = list_keys,
			},
		},
	})
end

return M
