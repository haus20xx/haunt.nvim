---@toc_entry Migration Module
---@tag haunt-migration
---@tag Migration
---@text
--- # Migration Module ~
---
--- Provides one-shot migration from the v1 on-disk bookmark format
--- (absolute paths, repo-path-keyed filename) to the v2 format
--- (project-relative paths, root-commit-keyed filename).
---
--- The v2 format is now what `haunt.persistence` writes and reads. Existing
--- v1 files on disk are left alone and will refuse to load until they have
--- been migrated. This module exposes a single entry point,
--- `migrate_current_project()`, which converts the current project's v1
--- file in place: writing the new v2 file at the new storage path, and
--- renaming the old file to `<old>.v1.bak` (rather than deleting it) so
--- the user can roll back if needed.
---
--- The `:HauntMigrate` user command (registered separately) is the
--- intended invocation point.

---@class MigrationModule
---@field migrate_current_project fun()

---@private
---@type MigrationModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Compute the OLD (v1) storage path for the current project.
---
--- Replicates the v1 keying scheme so we can find the existing file:
---   - sha256(project_root .. "|" .. branch):sub(1, 12) when per_branch_bookmarks
---   - sha256(project_root):sub(1, 12) otherwise
---
--- v1 used `repo_root` (the git toplevel, falling back to cwd) as the key.
--- Migration always requires a project root, so the caller must have
--- already resolved a non-nil project_root before calling this.
---@param project_root string Absolute path to the project root
---@param branch string|nil Branch name (or nil to fall back to "__default__")
---@param data_dir string Data directory (with trailing slash)
---@param per_branch boolean Whether per-branch bookmarks are enabled
---@return string old_path The absolute path of the v1 storage file
local function compute_old_path(project_root, branch, data_dir, per_branch)
	if not per_branch then
		local hash = vim.fn.sha256(project_root):sub(1, 12)
		return data_dir .. hash .. ".json"
	end

	local b = branch or "__default__"
	local key = project_root .. "|" .. b
	local hash = vim.fn.sha256(key):sub(1, 12)
	return data_dir .. hash .. ".json"
end

--- Decode JSON file contents.
---@param path string
---@return table|nil data Parsed table, or nil on error
---@return string|nil err Error message on failure
local function read_json_file(path)
	local read_ok, lines = pcall(vim.fn.readfile, path)
	if not read_ok then
		return nil, "failed to read file: " .. path
	end

	local json_str = table.concat(lines, "\n")
	local decode_ok, data = pcall(vim.json.decode, json_str)
	if not decode_ok then
		return nil, "JSON decode failed: " .. tostring(data)
	end

	if type(data) ~= "table" then
		return nil, "invalid data structure (not a table)"
	end

	return data, nil
end

--- Walk the v1 bookmarks and produce the v2 transformed list.
--- - In-project files become relative.
--- - Out-of-project files keep their absolute path with absolute=true.
--- - Runtime-only fields (extmark_id, annotation_extmark_id) are stripped.
---@param v1_bookmarks table[] Bookmarks from the v1 file
---@param project_root string Project root absolute path
---@return table[] transformed
---@return number relative_count
---@return number absolute_count
local function transform_bookmarks(v1_bookmarks, project_root)
	local utils = require("haunt.utils")
	local transformed = {}
	local relative_count = 0
	local absolute_count = 0

	for i, bookmark in ipairs(v1_bookmarks) do
		local entry = {
			line = bookmark.line,
			note = bookmark.note,
			id = bookmark.id,
		}

		if utils.is_within_project(bookmark.file, project_root) then
			local relative = utils.to_relative(bookmark.file, project_root)
			if relative then
				entry.file = relative
				relative_count = relative_count + 1
			else
				-- Defensive fallback: should not happen given is_within_project
				-- already returned true, but keep absolute behaviour just in case.
				entry.file = bookmark.file
				entry.absolute = true
				absolute_count = absolute_count + 1
			end
		else
			entry.file = bookmark.file
			entry.absolute = true
			absolute_count = absolute_count + 1
		end

		transformed[i] = entry
	end

	return transformed, relative_count, absolute_count
end

--- Migrate the current project's v1 bookmark file to v2.
---
--- High-level steps:
---   1. Resolve project_root (must be a git repo).
---   2. Compute OLD v1 path and NEW v2 path.
---   3. Bail if they're equal (project_id has fallen back to repo path).
---   4. Bail if no v1 file exists (info-level, not an error).
---   5. Read the v1 file; refuse to migrate if not version=1.
---   6. Refuse to overwrite an existing v2 file at the new path.
---   7. Transform bookmarks (relative when in-project, absolute=true otherwise).
---   8. Write the v2 file.
---   9. Rename the old file to `<old>.v1.bak`. If rename fails, warn but
---      do not delete.
---   10. Notify success with a count summary.
function M.migrate_current_project()
	-- Lazy requires to mirror the convention used elsewhere and avoid
	-- circular-dep risk with persistence.
	local persistence = require("haunt.persistence")
	local config = require("haunt.config").get()

	local info = require("haunt.project").get_info()
	if not info.root then
		vim.notify("haunt.nvim: not in a git repo, cannot migrate", vim.log.levels.WARN)
		return
	end

	local data_dir = persistence.ensure_data_dir()
	local per_branch = config.per_branch_bookmarks

	local old_path = compute_old_path(info.root, info.branch, data_dir, per_branch)
	local new_path = persistence.get_storage_path()

	if old_path == new_path then
		vim.notify("haunt.nvim: nothing to migrate (storage path unchanged)", vim.log.levels.INFO)
		return
	end

	if vim.fn.filereadable(old_path) ~= 1 then
		vim.notify("haunt.nvim: no v1 file found to migrate at " .. old_path, vim.log.levels.INFO)
		return
	end

	local data, err = read_json_file(old_path)
	if not data then
		vim.notify(
			"haunt.nvim: failed to parse v1 file at " .. old_path .. ": " .. tostring(err),
			vim.log.levels.ERROR
		)
		return
	end

	if data.version ~= 1 then
		vim.notify(
			"haunt.nvim: refusing to migrate file at "
				.. old_path
				.. ": expected version=1, got "
				.. tostring(data.version),
			vim.log.levels.ERROR
		)
		return
	end

	if type(data.bookmarks) ~= "table" then
		vim.notify(
			"haunt.nvim: refusing to migrate file at " .. old_path .. ": missing or invalid bookmarks field",
			vim.log.levels.ERROR
		)
		return
	end

	if vim.fn.filereadable(new_path) == 1 then
		vim.notify(
			"haunt.nvim: v2 file already exists at " .. new_path .. ", refusing to overwrite",
			vim.log.levels.ERROR
		)
		return
	end

	local transformed, relative_count, absolute_count = transform_bookmarks(data.bookmarks, info.root)

	local v2_data = {
		version = 2,
		bookmarks = transformed,
	}

	local encode_ok, json_str = pcall(vim.json.encode, v2_data)
	if not encode_ok then
		vim.notify("haunt.nvim: JSON encoding failed: " .. tostring(json_str), vim.log.levels.ERROR)
		return
	end

	-- vim.fn.writefile returns -1 on failure rather than throwing, so check both.
	local write_ok, write_ret = pcall(vim.fn.writefile, { json_str }, new_path)
	if not write_ok or write_ret == -1 then
		vim.notify("haunt.nvim: failed to write v2 file at " .. new_path, vim.log.levels.ERROR)
		return
	end

	-- Rename the old file to <old>.v1.bak rather than deleting it.
	-- If the rename fails, log a warning but leave the old file alone.
	local backup_path = old_path .. ".v1.bak"
	local rename_ok, rename_err = pcall(function()
		return vim.uv.fs_rename(old_path, backup_path)
	end)
	if not rename_ok or rename_err == false then
		-- os.rename returns true on success or nil + err on failure.
		local os_ok, os_ret = pcall(os.rename, old_path, backup_path)
		if not os_ok or os_ret ~= true then
			vim.notify(
				"haunt.nvim: migrated to v2 but failed to rename old file to "
					.. backup_path
					.. " (left in place)",
				vim.log.levels.WARN
			)
		end
	end

	local total = relative_count + absolute_count
	vim.notify(
		string.format(
			"haunt.nvim: migrated %d bookmarks to v2 (%d relative, %d absolute)",
			total,
			relative_count,
			absolute_count
		),
		vim.log.levels.INFO
	)
end

return M
