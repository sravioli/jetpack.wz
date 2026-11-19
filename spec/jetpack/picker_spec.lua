local wezterm = require "wezterm"

local function window()
  local w = { performed = {}, toasts = {}, clipboard = nil, table_name = nil }
  function w:window_id()
    return 1
  end
  function w:perform_action(action)
    self.performed[#self.performed + 1] = action
    if action.action == "ActivateKeyTable" then
      self.table_name = action.args.name
    elseif action._action == "PopKeyTable" then
      self.table_name = nil
    end
  end
  function w:active_key_table()
    return self.table_name
  end
  function w:effective_config()
    return { key_tables = { jetpack_picker = {} } }
  end
  function w:toast_notification(_, msg)
    self.toasts[#self.toasts + 1] = msg
  end
  function w:copy_to_clipboard(text)
    self.clipboard = text
  end
  w.statuses = {}
  function w:set_right_status(text)
    self.statuses[#self.statuses + 1] = text
  end
  return w
end

describe("jetpack.picker", function()
  local picker, config, ops

  before_each(function()
    wezterm._reset()
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    config = require "jetpack.config"
    config.parse()
    ops = require "jetpack.ops"
    picker = require "jetpack.picker"
  end)

  local row = {
    id = "a/demo",
    name = "demo",
    url = "https://github.com/a/demo",
    state = "update",
    locked = { commit = "1111111111", ref = "1.0.0" },
    available = { commit = "2222222222", ref = "1.1.0" },
  }

  local function status_rows()
    return {
      {
        id = "a/ok",
        name = "ok.wz",
        state = "ok",
        url = "u",
        locked = { commit = "aaaaaaa1", ref = "2.0.0" },
      },
      row,
      {
        id = "a/gone",
        name = "gone",
        state = "missing",
        url = "u",
        locked = { commit = "bbbbbbb2", ref = "0.1.0" },
      },
      {
        id = "a/two",
        name = "two",
        state = "update",
        url = "u",
        locked = { commit = "ccccccc3", ref = "3.0.0" },
        available = { commit = "ddddddd4", ref = "3.1.0", at = os.time() - 120 },
      },
      { id = "a/dev", name = "dev", state = "local", url = "u", path = "/src/dev" },
    }
  end

  it("labels a row with aligned columns and plain state words", function()
    local cfg = config.get().picker
    assert.equal("*  demo  1.0.0 → 1.1.0  update available", picker.label(row, cfg))
    assert.equal(
      "*  demo    1.0.0 → 1.1.0    update available",
      picker.label(row, cfg, { name = 6, version = 15 })
    )
    local drift =
      { name = "x", state = "drift", locked = { commit = "abcdef1234" }, head = "9999999" }
    assert.equal(
      "!  x  at 9999999, locked abcdef1  not at its locked version",
      picker.label(drift, config.parse({ picker = { icons = false } }).picker)
    )
  end)

  it("summarizes what needs attention and when updates were checked", function()
    assert.equal(
      "5 plugins · 2 updates available · 1 needs fixing · checked 2m ago",
      picker.summary_line(status_rows())
    )
    local fine = { { id = "a", name = "a", state = "ok", locked = { commit = "1" } } }
    assert.equal(
      "1 plugin · all at their locked versions · not checked for updates yet",
      picker.summary_line(fine)
    )
  end)

  it("shows only the bulk rows that apply, then plugins needing attention first", function()
    local choices = picker.choices(status_rows(), config.get().picker, 0)
    local ids = {}
    for _, c in ipairs(choices) do
      ids[#ids + 1] = c.id
    end
    assert.same({
      "op:update",
      "op:choose",
      "op:fix",
      "op:check",
      "op:doctor",
      "sep",
      "plugin:a/demo",
      "plugin:a/two",
      "plugin:a/gone",
      "plugin:a/ok",
      "plugin:a/dev",
    }, ids)
    assert.equal("*  Update all 2       demo, two", choices[1].label)
    assert.equal("*  Fix 1 plugin       install 1", choices[3].label)
    assert.equal("*  Check for updates  last checked 2m ago", choices[4].label)

    -- One update: named directly, no checklist; nothing to fix; orphans offered.
    local one = picker.choices({ row }, config.get().picker, 2)
    assert.equal("*  Update demo        1.0.0 → 1.1.0", one[1].label)
    assert.equal("op:check", one[2].id)
    assert.equal("op:clean", one[3].id)
    assert.equal("*  Check for updates  never checked", one[2].label)
  end)

  it("offers only the actions that fit each state", function()
    local function ids(r)
      local out = {}
      for _, item in ipairs(picker.menu_items(r)) do
        out[#out + 1] = item.id
      end
      return out
    end
    assert.same({ "update", "changes", "check", "browse", "copy" }, ids(row))
    local updated_once = { state = "ok", locked = { commit = "1", prev = "0", prev_ref = "0.9.0" } }
    assert.same({ "check", "update", "undo", "browse", "copy" }, ids(updated_once))
    assert.same(
      { "install", "browse", "copy" },
      ids { state = "missing", locked = { commit = "1" } }
    )
    assert.same(
      { "restore", "update", "browse", "copy" },
      ids { state = "drift", locked = { commit = "1" } }
    )
    assert.same({ "update", "browse" }, ids { state = "unlocked" })
    assert.same(
      { "browse", "copy", "copy_path" },
      ids { state = "dirty", locked = { commit = "1" } }
    )
    assert.same({ "copy_path" }, ids { state = "local" })
    assert.equal("Update to 1.1.0", picker.menu_items(row)[1].text)
    assert.equal("locked at 1.0.0; 1.1.0 is available", picker.describe(row))
  end)

  it("opens a plugin's menu on Enter, with shortcuts shown, and Back returns", function()
    ops.status = function()
      return { row }
    end
    ops.orphans = function()
      return {}
    end
    picker.key_table_ready = true
    local w = window()
    picker.open(w, {})
    local main = w.performed[#w.performed]
    assert.matches("^1 plugin · 1 update available", main.args.description)
    main.args.action.callback(w, {}, "plugin:a/demo")
    local menu = w.performed[#w.performed]
    assert.equal("Jetpack: demo", menu.args.title)
    assert.equal("*  Update to 1.1.0         Ctrl+U", menu.args.choices[1].label)
    assert.equal("back", menu.args.choices[#menu.args.choices].id)
    menu.args.action.callback(w, {}, "back")
    wezterm._run_timers()
    assert.equal("Jetpack", w.performed[#w.performed].args.title)
  end)

  it("aligns the columns of result rows", function()
    local cfg = require("jetpack.config").get().picker
    local widths = { name = 6, what = 7 }
    local a = picker.result_label(
      { ok = true, name = "a.wz", action = "updated", detail = "1 → 2" },
      cfg,
      widths
    )
    local b = picker.result_label(
      { ok = true, name = "bb.wz", action = "current", detail = "3" },
      cfg,
      widths
    )
    assert.equal(a:find("1 → 2", 1, true), b:find("3", 1, true))
  end)

  local function press(w, action)
    for _, k in ipairs(picker.key_table()) do
      if k.desc == action then
        k.action.callback(w, {})
        return
      end
    end
    error("no key for " .. action)
  end

  it("runs a shortcut inside a plugin's menu on that plugin", function()
    local updated
    ops.update = function(ids)
      updated = ids
      return {}
    end
    picker.key_table_ready = true
    local w = window()
    picker.menu(w, {}, row)
    assert.equal("jetpack_picker", w.table_name)
    local menu = w.performed[#w.performed]
    press(w, "update")
    -- Whatever row is highlighted (here "Check again"), the key wins.
    menu.args.action.callback(w, {}, "check")
    assert.same({ "a/demo" }, updated)

    -- The results view holds the table so a stray or repeated shortcut is
    -- swallowed instead of reaching the selector (which would take it as a
    -- choice and close).
    local results = w.performed[#w.performed]
    assert.equal("Jetpack: updating demo", results.args.title)
    assert.equal("jetpack_picker", w.table_name)
    local before = #w.performed
    press(w, "check")
    assert.equal(before, #w.performed)
    results.args.action.callback(w, {}, nil)
    assert.is_nil(w.table_name)
  end)

  it("does not run a bulk row when a shortcut is pressed on it", function()
    local updated, checked = false, false
    ops.update = function()
      updated = true
      return {}
    end
    ops.check = function()
      checked = true
      return {}
    end
    ops.status = function()
      return { row }
    end
    ops.orphans = function()
      return {}
    end
    picker.key_table_ready = true
    local w = window()
    picker.open(w, {})
    local main = w.performed[#w.performed]
    assert.equal("op:update", main.args.choices[1].id)
    press(w, "restore")
    main.args.action.callback(w, {}, "op:update")
    assert.is_false(updated)
    wezterm._run_timers()
    assert.matches("^Highlight a plugin first", w.performed[#w.performed].args.description)

    picker.open(w, {})
    main = w.performed[#w.performed]
    press(w, "check")
    main.args.action.callback(w, {}, "op:update")
    assert.is_false(updated)
    assert.is_true(checked)
  end)

  it("records the open view for the status bar", function()
    local state = require "jetpack.state"
    ops.status = function()
      return { row }
    end
    ops.orphans = function()
      return {}
    end
    local w = window()
    picker.open(w, {})
    assert.equal("plugin list", state.get_view(1))
    local main = w.performed[#w.performed]
    main.args.action.callback(w, {}, "plugin:a/demo")
    assert.equal("demo", state.get_view(1))
    local menu = w.performed[#w.performed]
    local seen
    ops.check = function()
      seen = state.get_view(1)
      return {}
    end
    menu.args.action.callback(w, {}, "check")
    assert.equal("checking demo…", seen)
    assert.equal("results", state.get_view(1))
    w.performed[#w.performed].args.action.callback(w, {}, nil)
    assert.is_nil(state.get_view(1))
  end)

  it("lists unpinned plugins with spec lines to copy", function()
    local state = require "jetpack.state"
    for _, url in ipairs { "https://github.com/sravioli/warden.wz", "https://example.com/x/y" } do
      local key = require("jetpack.spec").url_key(url)
      state.unmanaged[key] = url
      state.unmanaged_order[#state.unmanaged_order + 1] = key
    end
    assert.equal(
      "1 plugin · 1 update available · 2 not pinned · not checked for updates yet",
      picker.summary_line { row }
    )
    local choices, rows, g = picker.choices({ row }, config.get().picker, 0)
    local found
    for _, c in ipairs(choices) do
      if c.id == "op:unmanaged" then
        found = c
      end
    end
    assert.equal("*  2 plugins are not pinned  warden.wz, y", found.label)
    local w = window()
    picker.dispatch(nil, w, {}, "op:unmanaged", rows, g)
    local list = w.performed[#w.performed]
    assert.equal("Jetpack: not pinned", list.args.title)
    list.args.action.callback(w, {}, "copy_all")
    assert.equal(
      '{ "sravioli/warden.wz", version = "*" },\n{ url = "https://example.com/x/y" },',
      w.clipboard
    )
  end)

  it("lets a checklist choose which updates to apply", function()
    local updated
    ops.update = function(ids)
      updated = ids
      return {}
    end
    ops.status = function()
      return status_rows()
    end
    ops.orphans = function()
      return {}
    end
    local w = window()
    local _, rows, g = picker.choices(status_rows(), config.get().picker, 0)
    picker.dispatch(nil, w, {}, "op:choose", rows, g)
    local list = w.performed[#w.performed]
    assert.equal("*  Update selected (2)", list.args.choices[1].label)
    assert.matches("^%*  demo  1.0.0 → 1.1.0", list.args.choices[2].label)
    list.args.action.callback(w, {}, "toggle:a/demo")
    wezterm._run_timers()
    list = w.performed[#w.performed]
    assert.equal("*  Update selected (1)", list.args.choices[1].label)
    list.args.action.callback(w, {}, "go")
    assert.same({ "a/two" }, updated)
  end)

  it("builds the key table from config, honouring disabled keys", function()
    local keys = picker.key_table(config.parse({ picker = { keys = { copy = false } } }).picker)
    local names = {}
    for _, k in ipairs(keys) do
      names[#names + 1] = k.desc
    end
    assert.same({ "update", "restore", "check", "browse" }, names)
  end)

  local function updated_report()
    return {
      { id = "a/demo", name = "demo", action = "updated", ok = true, detail = "1.0.0 → 1.1.0" },
    }
  end

  local function open_and_update(w)
    local called
    ops.status = function()
      return { row }
    end
    ops.orphans = function()
      return {}
    end
    ops.update = function(ids)
      called = ids
      ops.on_progress(1, 1, "demo", "updating")
      return updated_report()
    end
    picker.key_table_ready = true
    picker.open(w, {})
    picker.key_table()[1].action.callback(w, {})
    local selector = w.performed[#w.performed - 1]
    selector.args.action.callback(w, {}, "plugin:a/demo")
    return called
  end

  it("reloads at once after changing code, then shows the results from the new state", function()
    local w = window()
    assert.same({ "a/demo" }, open_and_update(w))
    assert.is_nil(w.table_name)
    assert.equal("reload_configuration", wezterm._calls[#wezterm._calls].fn)
    local before = #w.performed
    assert.not_equal("InputSelector", w.performed[before].action)

    -- The reloaded state: a handler waits for the reloads to settle.
    function w:active_pane()
      return {}
    end
    picker.register_reloaded()
    wezterm.emit("window-config-reloaded", w, {})
    assert.equal(before, #w.performed)
    wezterm._run_timers()
    local results = w.performed[#w.performed]
    assert.equal("InputSelector", results.action)
    assert.equal("Jetpack: updating demo", results.args.title)
    assert.equal("back", results.args.choices[1].id)
    assert.equal("*  Undo this update", results.args.choices[2].label)
    assert.equal("*  demo  updated  1.0.0 → 1.1.0", results.args.choices[3].label)
    assert.is_nil(wezterm.GLOBAL["jetpack.results"])

    -- Shown once, even when another reload follows.
    wezterm.emit("window-config-reloaded", w, {})
    wezterm._run_timers()
    assert.equal(results, w.performed[#w.performed])
  end)

  it("shows results at once when nothing changed, and Back reopens the picker", function()
    local w = window()
    ops.status = function()
      return { row }
    end
    ops.orphans = function()
      return {}
    end
    picker.run(w, {}, "checking", function()
      return { { id = "a/demo", name = "demo", action = "current", ok = true, detail = "1.0.0" } }
    end)
    local results = w.performed[#w.performed]
    assert.equal("Jetpack: checking", results.args.title)
    for _, c in ipairs(wezterm._calls) do
      assert.not_equal("reload_configuration", c.fn)
    end
    results.args.action.callback(w, {}, "back")
    wezterm._run_timers()
    assert.equal("Jetpack", w.performed[#w.performed].args.title)
  end)

  it("shows progress in the right status without mosaic", function()
    local w = window()
    open_and_update(w)
    assert.equal(" jetpack: updating demo… ", w.statuses[1])
    assert.equal(" jetpack: updating demo 1/1 ", w.statuses[2])
    assert.equal("", w.statuses[#w.statuses])
  end)

  it("sends progress to mosaic's notice slot when mosaic is loaded", function()
    package.loaded["mosaic.api"] = {}
    local w = window()
    open_and_update(w)
    package.loaded["mosaic.api"] = nil
    local texts = {}
    for _, e in ipairs(wezterm._emitted) do
      if e.name == "mosaic-notify" then
        texts[#texts + 1] = e.args[3]
      end
    end
    assert.same(
      { "jetpack: updating demo…", "jetpack: updating demo 1/1", "jetpack: updated 1" },
      texts
    )
    assert.equal(0, #w.statuses)
  end)

  it("ends the log pane's command when the results are left; no pane is closed directly", function()
    local split_args
    local log = {
      pane_id = function()
        return 42
      end,
    }
    local alive = true
    wezterm.mux = {
      get_pane = function(id)
        return id == 42 and alive and log or nil
      end,
    }
    local root = os.tmpname()
    os.remove(root)
    os.execute(("mkdir -p '%s'"):format(root))
    config.parse { root = root, picker = { log_pane = true } }
    local w = window()
    local pane = {
      split = function(_, args)
        split_args = args.args
        return log
      end,
    }
    ops.check = function()
      return { { id = "a/demo", name = "demo", action = "current", ok = true } }
    end
    picker.run(w, pane, "checking", ops.check)
    assert.equal(42, wezterm.GLOBAL["jetpack.log_pane"])
    assert.equal("sh", split_args[1])
    local done = split_args[#split_args]
    assert.equal(root .. "/jetpack.log.done", done)
    -- A second run reuses the open pane instead of splitting again.
    pane.split = function()
      error "split twice"
    end
    picker.run(w, pane, "checking", ops.check)
    w.performed[#w.performed].args.action.callback(w, pane, nil)
    assert.truthy(io.open(done))
    assert.is_nil(wezterm.GLOBAL["jetpack.log_pane"])
    for _, a in ipairs(w.performed) do
      assert.not_equal("CloseCurrentPane", a.action)
    end
    wezterm.mux = nil
    os.execute(("rm -rf '%s'"):format(root))
  end)

  it("runs the log pane command until the marker appears, then exits 0", function()
    local root = os.tmpname()
    os.remove(root)
    os.execute(("mkdir -p '%s'"):format(root))
    config.parse { root = root, picker = { log_pane = true } }
    local args
    local w = window()
    picker.run(
      w,
      {
        split = function(_, a)
          args = a.args
          return nil
        end,
      },
      "checking",
      function()
        return {}
      end
    )
    local cmd = {}
    for i, a in ipairs(args) do
      cmd[i] = "'" .. a:gsub("'", "'\\''") .. "'"
    end
    local h = io.popen(
      ("(sleep 0.5; touch '%s') & %s"):format(args[#args], table.concat(cmd, " "))
        .. "; echo exit=$?"
    )
    local out = h:read "*a"
    h:close()
    assert.matches("jetpack: checking", out)
    assert.matches("exit=0", out)
    assert.is_nil(io.open(args[#args]))
    os.execute(("rm -rf '%s'"):format(root))
  end)

  it("copies the locked commit", function()
    local w = window()
    picker.dispatch("copy", w, {}, "plugin:a/demo", { ["plugin:a/demo"] = row })
    assert.equal("1111111111", w.clipboard)
  end)
end)
