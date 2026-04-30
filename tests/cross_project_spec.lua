---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")
local project_mock = require("tests.helpers.project_mock")

--- Read and decode a v2 storage file. Returns the bookmarks array.
local function read_storage(path)
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local lines = vim.fn.readfile(path)
	local data = vim.json.decode(table.concat(lines, "\n"))
	return data and data.bookmarks
end

describe("cross-project cd handling", function()
	local persistence
	local store
	local api
	local project
	local data_dir

	before_each(function()
		helpers.reset_modules()
		data_dir = helpers.create_temp_data_dir()

		persistence = require("haunt.persistence")
		persistence.set_data_dir(data_dir)

		store = require("haunt.store")
		api = require("haunt.api")
		project = require("haunt.project")
		api._reset_for_testing()
	end)

	after_each(function()
		project_mock.restore()
		helpers.cleanup_temp_dir(data_dir)
	end)

	describe("global :cd into a different project", function()
		it("saves the previous project's bookmarks under their original storage path", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			-- Touch the store so it stamps onto project A.
			store.reload()
			local path_a = persistence.get_storage_path()

			store.add_bookmark({
				file = "/proj-a/file.lua",
				line = 10,
				id = "/proj-a/file.lua:10",
				note = "from project A",
				absolute = true,
			})

			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			project.handle_dir_change("global")

			local saved = read_storage(path_a)
			assert.is_not_nil(saved, "expected A's storage file to exist after cd")
			assert.are.equal(1, #saved)
			assert.are.equal("from project A", saved[1].note)
		end)

		it("swaps the in-memory store to the new project", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()
			store.add_bookmark({
				file = "/proj-a/file.lua",
				line = 10,
				id = "/proj-a/file.lua:10",
				note = "from project A",
				absolute = true,
			})

			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			project.handle_dir_change("global")

			-- B has no storage file yet, so its store is empty.
			local current = api.get_bookmarks()
			assert.are.equal(0, #current, "store should be reset to B's empty state")
		end)

		it("loads B's existing bookmarks if B has a storage file", function()
			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			local path_b = persistence.get_storage_path()
			helpers.create_bookmarks_file(data_dir, {
				{ file = "/proj-b/file.lua", line = 5, id = "b1", note = "from project B", absolute = true },
			}, path_b:match("([0-9a-f]+)%.json$"))

			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()

			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			project.handle_dir_change("global")

			local current = api.get_bookmarks()
			assert.are.equal(1, #current)
			assert.are.equal("from project B", current[1].note)
		end)

		it("subsequent saves go to the new project's storage path", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()
			local path_a = persistence.get_storage_path()

			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			local path_b = persistence.get_storage_path()
			project.handle_dir_change("global")

			store.add_bookmark({
				file = "/proj-b/file.lua",
				line = 3,
				id = "/proj-b/file.lua:3",
				note = "in B now",
				absolute = true,
			})
			store.save()

			local saved_b = read_storage(path_b)
			assert.is_not_nil(saved_b, "expected B's storage file to exist")
			assert.are.equal(1, #saved_b)
			assert.are.equal("in B now", saved_b[1].note)

			-- A's file must NOT have B's bookmark.
			local saved_a = read_storage(path_a)
			if saved_a then
				for _, bm in ipairs(saved_a) do
					assert.are_not.equal("in B now", bm.note)
				end
			end
		end)
	end)

	describe("cd into a non-repo directory", function()
		it("treats it as a project change (saves A, swaps store)", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()
			local path_a = persistence.get_storage_path()
			store.add_bookmark({
				file = "/proj-a/file.lua",
				line = 1,
				id = "/proj-a/file.lua:1",
				note = "from project A",
				absolute = true,
			})

			project_mock.set({ root = nil, branch = nil, project_id = "/home/user/Downloads" })
			project.handle_dir_change("global")

			local saved = read_storage(path_a)
			assert.is_not_nil(saved)
			assert.are.equal(1, #saved)

			local current = api.get_bookmarks()
			assert.are.equal(0, #current)
		end)
	end)

	describe(":lcd / :tcd (window/tab-local cd)", function()
		it("does NOT swap the store on window-local cd", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()
			store.add_bookmark({
				file = "/proj-a/file.lua",
				line = 1,
				id = "/proj-a/file.lua:1",
				note = "from project A",
				absolute = true,
			})

			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			project.handle_dir_change("window")

			local current = api.get_bookmarks()
			assert.are.equal(1, #current, "lcd must not swap the store")
			assert.are.equal("from project A", current[1].note)
		end)

		it("does NOT swap the store on tab-local cd", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()
			store.add_bookmark({
				file = "/proj-a/file.lua",
				line = 1,
				id = "/proj-a/file.lua:1",
				note = "from project A",
				absolute = true,
			})

			project_mock.set({ root = "/proj-b", branch = "main", project_id = "proj-b-id" })
			project.handle_dir_change("tabpage")

			local current = api.get_bookmarks()
			assert.are.equal(1, #current, "tcd must not swap the store")
		end)
	end)

	describe("global cd within the same project", function()
		it("is a no-op (cd into a subdir does not churn the store)", function()
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			store.reload()
			store.add_bookmark({
				file = "/proj-a/file.lua",
				line = 1,
				id = "/proj-a/file.lua:1",
				note = "stable bookmark",
				absolute = true,
			})

			-- Same project_id (cd into ~/proj-a/frontend resolves to same toplevel).
			project_mock.set({ root = "/proj-a", branch = "main", project_id = "proj-a-id" })
			project.handle_dir_change("global")

			local current = api.get_bookmarks()
			assert.are.equal(1, #current)
			assert.are.equal("stable bookmark", current[1].note)
		end)
	end)
end)
