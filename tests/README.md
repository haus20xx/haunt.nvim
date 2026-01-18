# Tests

## Infrastructure

Tests run via [mini.test](https://github.com/echasnovski/mini.test) with [luassert](https://github.com/lunarmodules/luassert):

```bash
./scripts/test
```

- `minit.lua` - Uses lazy.nvim's bootstrap to install mini.test and luassert, then runs tests
  * This makes more sense if you look at the .tests directory after running once
- `scripts/test` - Runs `nvim -l tests/minit.lua --minitest`
- `.tests/` - Generated directory for test dependencies (gitignored)

## Conventions

- Files named `*_spec.lua`
- Use `describe`/`it` blocks with `luassert` assertions
- Reload modules in `before_each` for isolation:
  ```lua
  before_each(function()
      package.loaded["haunt.api"] = nil
      api = require("haunt.api")
  end)
  ```
- Create temp buffers with `vim.api.nvim_create_buf(false, true)`, clean up in `after_each`
- Mock vim functions by saving/restoring originals:
  ```lua
  local original_input = vim.fn.input
  vim.fn.input = function() return "mocked" end
  -- test...
  vim.fn.input = original_input
  ```
