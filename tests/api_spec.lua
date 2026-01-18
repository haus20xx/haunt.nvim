---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

describe("haunt.api", function()
	local api
	local display

	-- Helper to create a test buffer
	local function create_test_buffer(lines)
		local bufnr = vim.api.nvim_create_buf(false, false)
		local test_file = vim.fn.tempname() .. ".lua"
		vim.api.nvim_buf_set_name(bufnr, test_file)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "Line 1", "Line 2", "Line 3" })
		vim.api.nvim_set_current_buf(bufnr)
		return bufnr, test_file
	end

	-- Helper to cleanup buffer
	local function cleanup_buffer(bufnr, test_file)
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
		if test_file then
			vim.fn.delete(test_file)
		end
	end

	before_each(function()
		package.loaded["haunt.api"] = nil
		package.loaded["haunt.display"] = nil
		package.loaded["haunt.persistence"] = nil
		package.loaded["haunt.config"] = nil
		api = require("haunt.api")
		display = require("haunt.display")
		local config = require("haunt.config")
		config.setup()
		api._reset_for_testing() -- Clear any persisted bookmarks
	end)

	describe("toggle", function()
		local bufnr, test_file

		before_each(function()
			bufnr, test_file = create_test_buffer()
		end)

		after_each(function()
			cleanup_buffer(bufnr, test_file)
		end)

		it("returns false when no bookmark exists at line", function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })

			local ok = api.toggle()
			assert.is_false(ok)

			local bookmarks = api.get_bookmarks()
			assert.are.equal(0, #bookmarks)
		end)
	end)

	describe("annotate", function()
		local bufnr, test_file
		local original_input

		before_each(function()
			bufnr, test_file = create_test_buffer()
			original_input = vim.fn.input
		end)

		after_each(function()
			vim.fn.input = original_input
			cleanup_buffer(bufnr, test_file)
		end)

		it("creates bookmark with annotation", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.fn.input = function()
				return "Test annotation"
			end

			api.annotate()

			local bookmarks = api.get_bookmarks()
			assert.are.equal(1, #bookmarks)
			assert.are.equal("Test annotation", bookmarks[1].note)
		end)

		it("updates existing annotation", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			-- First annotation
			vim.fn.input = function()
				return "First note"
			end
			api.annotate()

			-- Update annotation
			vim.fn.input = function()
				return "Updated note"
			end
			api.annotate()

			local bookmarks = api.get_bookmarks()
			assert.are.equal(1, #bookmarks)
			assert.are.equal("Updated note", bookmarks[1].note)
		end)

		it("accepts text parameter to skip input", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			api.annotate("Direct annotation")

			local bookmarks = api.get_bookmarks()
			assert.are.equal(1, #bookmarks)
			assert.are.equal("Direct annotation", bookmarks[1].note)
		end)
	end)

	describe("delete", function()
		local bufnr, test_file

		before_each(function()
			bufnr, test_file = create_test_buffer()
		end)

		after_each(function()
			cleanup_buffer(bufnr, test_file)
		end)

		it("removes existing bookmark", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test")

			local before = api.get_bookmarks()
			assert.are.equal(1, #before)

			local ok = api.delete()
			assert.is_true(ok)

			local after = api.get_bookmarks()
			assert.are.equal(0, #after)
		end)

		it("returns false when no bookmark exists", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			local ok = api.delete()
			assert.is_false(ok)
		end)
	end)

	describe("navigation", function()
		local bufnr, test_file

		before_each(function()
			bufnr, test_file = create_test_buffer({ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" })

			-- Create bookmarks at lines 1, 3, 5
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Bookmark 1")
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			api.annotate("Bookmark 3")
			vim.api.nvim_win_set_cursor(0, { 5, 0 })
			api.annotate("Bookmark 5")
		end)

		after_each(function()
			cleanup_buffer(bufnr, test_file)
		end)

		local next_cases = {
			{ from = 1, expected = 3, desc = "line 1 to line 3" },
			{ from = 3, expected = 5, desc = "line 3 to line 5" },
			{ from = 5, expected = 1, desc = "line 5 wraps to line 1" },
			{ from = 2, expected = 3, desc = "line 2 (no bookmark) to line 3" },
		}

		for _, case in ipairs(next_cases) do
			it("next jumps from " .. case.desc, function()
				vim.api.nvim_win_set_cursor(0, { case.from, 0 })
				api.next()
				local pos = vim.api.nvim_win_get_cursor(0)
				assert.are.equal(case.expected, pos[1])
			end)
		end

		local prev_cases = {
			{ from = 5, expected = 3, desc = "line 5 to line 3" },
			{ from = 3, expected = 1, desc = "line 3 to line 1" },
			{ from = 1, expected = 5, desc = "line 1 wraps to line 5" },
			{ from = 4, expected = 3, desc = "line 4 (no bookmark) to line 3" },
		}

		for _, case in ipairs(prev_cases) do
			it("prev jumps from " .. case.desc, function()
				vim.api.nvim_win_set_cursor(0, { case.from, 0 })
				api.prev()
				local pos = vim.api.nvim_win_get_cursor(0)
				assert.are.equal(case.expected, pos[1])
			end)
		end
	end)

	describe("clear", function()
		local bufnr1, test_file1, bufnr2, test_file2

		before_each(function()
			bufnr1, test_file1 = create_test_buffer({ "File1 Line 1", "File1 Line 2" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("File1 Bookmark 1")
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			api.annotate("File1 Bookmark 2")

			bufnr2, test_file2 = create_test_buffer({ "File2 Line 1" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("File2 Bookmark")
		end)

		after_each(function()
			cleanup_buffer(bufnr1, test_file1)
			cleanup_buffer(bufnr2, test_file2)
		end)

		it("clears only current file bookmarks", function()
			local before = api.get_bookmarks()
			assert.are.equal(3, #before)

			vim.api.nvim_set_current_buf(bufnr1)
			local ok = api.clear()
			assert.is_true(ok)

			local after = api.get_bookmarks()
			assert.are.equal(1, #after)
		end)
	end)

	describe("clear_all", function()
		local bufnr, test_file
		local original_confirm

		before_each(function()
			bufnr, test_file = create_test_buffer()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Bookmark 1")
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			api.annotate("Bookmark 2")

			original_confirm = vim.fn.confirm
		end)

		after_each(function()
			vim.fn.confirm = original_confirm
			cleanup_buffer(bufnr, test_file)
		end)

		it("clears all bookmarks when confirmed", function()
			vim.fn.confirm = function()
				return 1
			end -- Yes

			local before = api.get_bookmarks()
			assert.are.equal(2, #before)

			local ok = api.clear_all()
			assert.is_true(ok)

			local after = api.get_bookmarks()
			assert.are.equal(0, #after)
		end)

		it("does not clear when cancelled", function()
			vim.fn.confirm = function()
				return 2
			end -- No

			local before = api.get_bookmarks()
			assert.are.equal(2, #before)

			local ok = api.clear_all()
			assert.is_false(ok)

			local after = api.get_bookmarks()
			assert.are.equal(2, #after)
		end)
	end)

	describe("save / load", function()
		local bufnr, test_file

		before_each(function()
			bufnr, test_file = create_test_buffer()
		end)

		after_each(function()
			cleanup_buffer(bufnr, test_file)
		end)

		it("persists bookmarks across reload", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Persisted bookmark")

			local save_ok = api.save()
			assert.is_true(save_ok)

			-- Reload module
			package.loaded["haunt.api"] = nil
			local api2 = require("haunt.api")

			local load_ok = api2.load()
			assert.is_true(load_ok)

			local bookmarks = api2.get_bookmarks()
			assert.are.equal(1, #bookmarks)
			assert.are.equal(1, bookmarks[1].line)
		end)
	end)
end)
