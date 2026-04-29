---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.migration", function()
	local migration
	local persistence
	local config
	local project_mock = require("tests.helpers.project_mock")

	-- Real captured items.
	local notifications
	local original_notify

	-- Per-test fake fixtures.
	local fake_data_dir
	local fake_project_root
	local fake_project_id
	local fake_branch

	--- Compute the v1 path the same way migration.lua does internally.
	---@param project_root string
	---@param branch string|nil
	---@param data_dir string
	---@param per_branch boolean
	local function v1_path_for(project_root, branch, data_dir, per_branch)
		if not per_branch then
			return data_dir .. vim.fn.sha256(project_root):sub(1, 12) .. ".json"
		end
		local b = branch or "__default__"
		local key = project_root .. "|" .. b
		return data_dir .. vim.fn.sha256(key):sub(1, 12) .. ".json"
	end

	--- Write a JSON file as the given table.
	---@param path string
	---@param tbl table
	local function write_json(path, tbl)
		local json_str = vim.json.encode(tbl)
		vim.fn.writefile({ json_str }, path)
	end

	--- Read a JSON file back as a table.
	---@param path string
	---@return table data
	local function read_json(path)
		local lines = vim.fn.readfile(path)
		local json_str = table.concat(lines, "\n")
		return vim.json.decode(json_str)
	end

	--- Find a captured notification whose message contains `needle`.
	---@param needle string
	---@return table|nil entry
	local function find_notification(needle)
		for _, n in ipairs(notifications) do
			if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
				return n
			end
		end
		return nil
	end

	before_each(function()
		helpers.reset_modules()
		package.loaded["haunt.migration"] = nil

		config = require("haunt.config")
		config.setup({ per_branch_bookmarks = true })

		persistence = require("haunt.persistence")
		migration = require("haunt.migration")

		-- Create a hermetic temp data dir.
		fake_data_dir = vim.fn.tempname() .. "_haunt_migration_test/"
		vim.fn.mkdir(fake_data_dir, "p")

		fake_project_root = "/fake/proj"
		fake_project_id = "rootcommit-abcdef"
		fake_branch = "main"

		project_mock.set({
			root = fake_project_root,
			branch = fake_branch,
			project_id = fake_project_id,
		})

		persistence.set_data_dir(fake_data_dir)

		-- Capture vim.notify calls.
		notifications = {}
		original_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
	end)

	after_each(function()
		project_mock.restore()
		if persistence then
			persistence.set_data_dir(nil)
		end

		vim.notify = original_notify

		if fake_data_dir and vim.fn.isdirectory(fake_data_dir) == 1 then
			vim.fn.delete(fake_data_dir, "rf")
		end
	end)

	it("migrates v1 file with all in-project bookmarks to v2", function()
		local old_path = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		local new_path = persistence.get_storage_path()

		assert.are_not.equal(old_path, new_path)

		write_json(old_path, {
			version = 1,
			bookmarks = {
				{ file = "/fake/proj/src/main.lua", line = 10, id = "id1", note = "First" },
				{ file = "/fake/proj/lib/util.lua", line = 5, id = "id2" },
			},
		})

		migration.migrate_current_project()

		assert.are.equal(1, vim.fn.filereadable(new_path))
		local data = read_json(new_path)
		assert.are.equal(2, data.version)
		assert.are.equal(2, #data.bookmarks)
		assert.are.equal("src/main.lua", data.bookmarks[1].file)
		assert.is_nil(data.bookmarks[1].absolute)
		assert.are.equal("lib/util.lua", data.bookmarks[2].file)
		assert.is_nil(data.bookmarks[2].absolute)

		-- Old file renamed, backup exists.
		assert.are.equal(0, vim.fn.filereadable(old_path))
		assert.are.equal(1, vim.fn.filereadable(old_path .. ".v1.bak"))

		assert.is_not_nil(find_notification("migrated 2 bookmarks"))
	end)

	it("preserves out-of-project bookmarks with absolute=true", function()
		local old_path = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		local new_path = persistence.get_storage_path()

		write_json(old_path, {
			version = 1,
			bookmarks = {
				{ file = "/fake/proj/src/main.lua", line = 10, id = "in1" },
				{ file = "/etc/hosts", line = 1, id = "out1" },
			},
		})

		migration.migrate_current_project()

		local data = read_json(new_path)
		assert.are.equal(2, data.version)
		assert.are.equal(2, #data.bookmarks)

		-- In-project bookmark.
		assert.are.equal("src/main.lua", data.bookmarks[1].file)
		assert.is_nil(data.bookmarks[1].absolute)

		-- Out-of-project bookmark preserved with absolute=true.
		assert.are.equal("/etc/hosts", data.bookmarks[2].file)
		assert.is_true(data.bookmarks[2].absolute)

		assert.is_not_nil(find_notification("1 relative, 1 absolute"))
	end)

	it("aborts when v2 file already exists at new path", function()
		local old_path = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		local new_path = persistence.get_storage_path()

		write_json(old_path, {
			version = 1,
			bookmarks = {
				{ file = "/fake/proj/src/main.lua", line = 10, id = "id1" },
			},
		})
		write_json(new_path, {
			version = 2,
			bookmarks = {
				{ file = "existing.lua", line = 1, id = "preexisting" },
			},
		})

		migration.migrate_current_project()

		-- Old file untouched (still v1).
		assert.are.equal(1, vim.fn.filereadable(old_path))
		assert.are.equal(0, vim.fn.filereadable(old_path .. ".v1.bak"))
		local old_data = read_json(old_path)
		assert.are.equal(1, old_data.version)

		-- New v2 file unchanged (still has the pre-existing entry).
		local new_data = read_json(new_path)
		assert.are.equal(1, #new_data.bookmarks)
		assert.are.equal("preexisting", new_data.bookmarks[1].id)

		-- Saw the refusal notify.
		local refusal = find_notification("refusing to overwrite")
		assert.is_not_nil(refusal)
		assert.are.equal(vim.log.levels.ERROR, refusal.level)
	end)

	it("is a no-op (info-level) when no v1 file exists at old path", function()
		local old_path = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		local new_path = persistence.get_storage_path()

		-- Sanity: nothing on disk to start.
		assert.are.equal(0, vim.fn.filereadable(old_path))
		assert.are.equal(0, vim.fn.filereadable(new_path))

		migration.migrate_current_project()

		assert.are.equal(0, vim.fn.filereadable(old_path))
		assert.are.equal(0, vim.fn.filereadable(new_path))
		assert.are.equal(0, vim.fn.filereadable(old_path .. ".v1.bak"))

		local n = find_notification("no v1 file found")
		assert.is_not_nil(n)
		assert.are.equal(vim.log.levels.INFO, n.level)
	end)

	it("aborts when file at old path is not version=1", function()
		local old_path = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		local new_path = persistence.get_storage_path()

		-- Seed a v2 file at the OLD path - migration should refuse to touch it.
		write_json(old_path, {
			version = 2,
			bookmarks = {
				{ file = "src/main.lua", line = 1, id = "v2-already" },
			},
		})

		migration.migrate_current_project()

		-- Old file untouched.
		assert.are.equal(1, vim.fn.filereadable(old_path))
		assert.are.equal(0, vim.fn.filereadable(old_path .. ".v1.bak"))
		-- New path was NOT created.
		assert.are.equal(0, vim.fn.filereadable(new_path))

		local err = find_notification("expected version=1")
		assert.is_not_nil(err)
		assert.are.equal(vim.log.levels.ERROR, err.level)
	end)

	it("warns and aborts when not in a git repo", function()
		project_mock.set({ root = nil, branch = nil, project_id = "fallback" })

		-- Compute what the path WOULD be if there were a repo, so we can verify
		-- nothing got written there either.
		local hypothetical_old = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		write_json(hypothetical_old, {
			version = 1,
			bookmarks = {
				{ file = "/fake/proj/src/main.lua", line = 10, id = "id1" },
			},
		})

		migration.migrate_current_project()

		-- Old file remains untouched (no rename, no backup).
		assert.are.equal(1, vim.fn.filereadable(hypothetical_old))
		assert.are.equal(0, vim.fn.filereadable(hypothetical_old .. ".v1.bak"))

		local warn = find_notification("not in a git repo")
		assert.is_not_nil(warn)
		assert.are.equal(vim.log.levels.WARN, warn.level)
	end)

	it("strips runtime-only extmark fields when migrating", function()
		local old_path = v1_path_for(fake_project_root, fake_branch, fake_data_dir, true)
		local new_path = persistence.get_storage_path()

		write_json(old_path, {
			version = 1,
			bookmarks = {
				{
					file = "/fake/proj/src/main.lua",
					line = 10,
					id = "id1",
					note = "kept",
					extmark_id = 123,
					annotation_extmark_id = 456,
				},
			},
		})

		migration.migrate_current_project()

		local data = read_json(new_path)
		assert.are.equal(1, #data.bookmarks)
		assert.are.equal("src/main.lua", data.bookmarks[1].file)
		assert.are.equal(10, data.bookmarks[1].line)
		assert.are.equal("id1", data.bookmarks[1].id)
		assert.are.equal("kept", data.bookmarks[1].note)
		assert.is_nil(data.bookmarks[1].extmark_id)
		assert.is_nil(data.bookmarks[1].annotation_extmark_id)
	end)
end)
