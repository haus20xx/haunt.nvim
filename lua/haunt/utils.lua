---@class UtilsModule
---@field normalize_filepath fun(path: string): string
---@field validate_buffer_for_bookmarks fun(bufnr: number): boolean, string|nil
---@field ensure_buffer_for_file fun(filepath: string): number|nil, string|nil
---@field toggle_quickfix fun(): nil
---@field to_relative fun(absolute_path: string, project_root: string): string|nil
---@field to_absolute fun(relative_path: string, project_root: string): string
---@field is_within_project fun(absolute_path: string, project_root: string): boolean

---@type UtilsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Normalize a file path to absolute form
--- Ensures consistent path representation for comparisons
---@param path string The file path to normalize
---@return string normalized_path The absolute file path
function M.normalize_filepath(path)
	if path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

--- Validate that a buffer can have bookmarks
--- Checks for empty filepath, special buffers, buffer types, and modifiable status
---@param bufnr number Buffer number to validate
---@return boolean valid True if buffer can have bookmarks
---@return string|nil error_msg Error message if validation fails
function M.validate_buffer_for_bookmarks(bufnr)
	-- Check if buffer exists and is valid
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "Invalid buffer"
	end

	-- Get buffer filepath
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	-- Check if buffer has a name
	if filepath == "" then
		return false, "Cannot bookmark unnamed buffer"
	end

	-- Check buffer type (only normal files can have bookmarks)
	local buftype = vim.bo[bufnr].buftype
	if buftype ~= "" then
		return false, "Cannot bookmark special buffers (terminal, help, etc.)"
	end

	-- Check if buffer is modifiable
	if not vim.bo[bufnr].modifiable then
		return false, "Cannot bookmark read-only buffer"
	end

	-- Check for special buffer schemes (term://, fugitive://, etc.)
	if filepath:match("^%w+://") then
		return false, "Cannot bookmark special buffers (protocol schemes)"
	end

	return true, nil
end

--- Ensure a buffer exists and is loaded for a file path
--- Creates the buffer if it doesn't exist and loads it
---@param filepath string The file path to get/create a buffer for
---@return number|nil bufnr The buffer number, or nil if failed
---@return string|nil error_msg Error message if validation fails
function M.ensure_buffer_for_file(filepath)
	local bufnr = vim.fn.bufnr(filepath)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(filepath)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "Failed to create buffer for file: " .. filepath
	end

	vim.fn.bufload(bufnr)

	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return nil, "Failed to load buffer for file: " .. filepath
	end

	return bufnr, nil
end

function M.toggle_quickfix()
	for _, w in ipairs(vim.fn.getwininfo()) do
		if w.quickfix == 1 then
			vim.cmd("cclose")
			return
		end
	end
	vim.cmd("copen")
end

--- Strip a trailing slash from a path, unless the path is just "/"
---@param path string
---@return string
local function strip_trailing_slash(path)
	if #path > 1 and path:sub(-1) == "/" then
		return path:sub(1, -2)
	end
	return path
end

--- Convert an absolute path to a path relative to project_root
--- Returns nil if absolute_path is outside project_root or equals it.
--- The project root itself is a directory and not a meaningful bookmark
--- target, so equality returns nil rather than ".".
--- Performs textual normalization only (does not resolve symlinks).
---@param absolute_path string An absolute file path
---@param project_root string The project root directory (absolute)
---@return string|nil relative_path Relative path, or nil if outside or equal
function M.to_relative(absolute_path, project_root)
	if absolute_path == nil or project_root == nil then
		return nil
	end

	local norm_path = strip_trailing_slash(vim.fs.normalize(absolute_path))
	local norm_root = strip_trailing_slash(vim.fs.normalize(project_root))

	if norm_path == norm_root then
		return nil
	end

	-- Match prefix only at a directory boundary to avoid /proj matching /proj-other
	local prefix = norm_root .. "/"
	if norm_path:sub(1, #prefix) ~= prefix then
		return nil
	end

	local relative = norm_path:sub(#prefix + 1)
	-- Sanity check: a relative path that climbs out is not within the project
	if relative == "" or relative:sub(1, 2) == ".." then
		return nil
	end

	return relative
end

--- Convert a project-relative path to an absolute path
--- Joins project_root and relative_path and normalizes the result.
---@param relative_path string A path relative to project_root
---@param project_root string The project root directory (absolute)
---@return string absolute_path The normalized absolute path
function M.to_absolute(relative_path, project_root)
	local norm_root = strip_trailing_slash(vim.fs.normalize(project_root))
	if relative_path == "." or relative_path == "" then
		return norm_root
	end
	return vim.fs.normalize(norm_root .. "/" .. relative_path)
end

--- Check whether absolute_path lives within project_root
--- Comparison is textual (no symlink resolution).
---@param absolute_path string An absolute file path
---@param project_root string The project root directory (absolute)
---@return boolean within True if absolute_path == project_root or is a descendant
function M.is_within_project(absolute_path, project_root)
	if absolute_path == nil or project_root == nil then
		return false
	end

	local norm_path = strip_trailing_slash(vim.fs.normalize(absolute_path))
	local norm_root = strip_trailing_slash(vim.fs.normalize(project_root))

	if norm_path == norm_root then
		return true
	end

	local prefix = norm_root .. "/"
	return norm_path:sub(1, #prefix) == prefix
end

return M
