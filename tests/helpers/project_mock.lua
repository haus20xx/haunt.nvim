--- Test helper for injecting fake project info into haunt.project.
---
--- haunt.project caches `{root, branch, project_id}` and exposes only
--- `get_info()` to production code. Tests need to control those values
--- without a real git repository.
---
--- Strategy: replace `get_info` itself with a function that returns the
--- mocked info. This survives `M.invalidate()` calls from production code
--- (e.g. the cd-handling autocmd flow), which a cache-only mock would not.
---
--- Usage:
---     local project_mock = require("tests.helpers.project_mock")
---
---     project_mock.set({ root = "/tmp", branch = "main", project_id = "x" })
---     -- ... assertions ...
---     project_mock.restore()
---
--- Or scoped:
---     project_mock.with({ root = "/tmp", branch = "main", project_id = "x" }, function()
---       -- ... assertions ...
---     end)

local M = {}

---@type fun(): ProjectInfo|nil
local _original_get_info = nil

---@param info ProjectInfo
function M.set(info)
	local project = require("haunt.project")
	if _original_get_info == nil then
		_original_get_info = project.get_info
	end
	project.get_info = function()
		return info
	end
end

--- Drop the injected info; restore the real `get_info` and clear the cache.
function M.restore()
	local project = require("haunt.project")
	if _original_get_info ~= nil then
		project.get_info = _original_get_info
		_original_get_info = nil
	end
	project.invalidate()
end

--- Run `fn` with the given project info injected, restoring on exit.
---@param info ProjectInfo
---@param fn fun()
function M.with(info, fn)
	M.set(info)
	local ok, err = pcall(fn)
	M.restore()
	if not ok then
		error(err)
	end
end

return M
