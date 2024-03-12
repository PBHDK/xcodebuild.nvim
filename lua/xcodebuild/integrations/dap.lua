---@mod xcodebuild.integrations.dap DAP Integration
---@tag xcodebuild.dap
---@brief [[
---This module is responsible for the integration with `nvim-dap` plugin.
---
---It provides functions to start the debugger and to manage its state.
---
---To configure `nvim-dap` for development:
---
---  1. Download `codelldb` VS Code plugin from: https://github.com/vadimcn/codelldb/releases
---     For macOS use darwin version. Just unzip vsix file and set paths below.
---  2. Install also `nvim-dap-ui` for a nice GUI to debug.
---  3. Make sure to enable console window from `nvim-dap-ui` to see simulator logs.
---
---Sample `nvim-dap` configuration:
--->lua
---    return {
---      "mfussenegger/nvim-dap",
---      dependencies = {
---        "wojciech-kulik/xcodebuild.nvim"
---      },
---      config = function()
---        local xcodebuild = require("xcodebuild.integrations.dap")
---        -- SAMPLE PATH, change it to your local codelldb path
---        local codelldbPath = "/YOUR_PATH/codelldb-aarch64-darwin/extension/adapter/codelldb"
---
---        xcodebuild.setup(codelldbPath)
---
---        vim.keymap.set("n", "<leader>dd", xcodebuild.build_and_debug, { desc = "Build & Debug" })
---        vim.keymap.set("n", "<leader>dr", xcodebuild.debug_without_build, { desc = "Debug Without Building" })
---        vim.keymap.set("n", "<leader>dt", xcodebuild.debug_tests, { desc = "Debug Tests" })
---        vim.keymap.set("n", "<leader>dT", xcodebuild.debug_class_tests, { desc = "Debug Class Tests" })
---        vim.keymap.set("n", "<leader>b", xcodebuild.toggle_breakpoint, { desc = "Toggle Breakpoint" })
---        vim.keymap.set("n", "<leader>B", xcodebuild.toggle_message_breakpoint, { desc = "Toggle Message Breakpoint" })
---        vim.keymap.set("n", "<leader>dx", xcodebuild.terminate_session, { desc = "Terminate Debugger" })
---      end,
---    }
---<
---
---See:
---  https://github.com/mfussenegger/nvim-dap
---  https://github.com/rcarriga/nvim-dap-ui
---  https://github.com/vadimcn/codelldb
---
---@brief ]]

local util = require("xcodebuild.util")
local helpers = require("xcodebuild.helpers")
local constants = require("xcodebuild.core.constants")
local notifications = require("xcodebuild.broadcasting.notifications")
local projectConfig = require("xcodebuild.project.config")
local device = require("xcodebuild.platform.device")
local actions = require("xcodebuild.actions")
local remoteDebugger = require("xcodebuild.integrations.remote_debugger")

local M = {}

---Checks if the project is configured.
---If not, it sends an error notification.
---@return boolean
local function validate_project()
  if not projectConfig.is_project_configured() then
    notifications.send_error("The project is missing some details. Please run XcodebuildSetup first.")
    return false
  end

  return true
end

---Sets the remote debugger mode based on the OS version.
local function set_remote_debugger_mode()
  local majorVersion = helpers.get_major_os_version()

  if majorVersion and majorVersion < 17 then
    remoteDebugger.set_mode(remoteDebugger.LEGACY_MODE)
  else
    remoteDebugger.set_mode(remoteDebugger.SECURED_MODE)
  end
end

---Starts `nvim-dap` debug session. It connects to `codelldb`.
local function start_dap()
  local loadedDap, dap = pcall(require, "dap")
  if not loadedDap then
    error("xcodebuild.nvim: Could not load nvim-dap plugin")
    return
  end

  dap.run(dap.configurations.swift[1])
end

---Builds, installs and runs the project. Also, it starts the debugger.
---@param callback function|nil
function M.build_and_debug(callback)
  local loadedDap, dap = pcall(require, "dap")
  if not loadedDap then
    notifications.send_error("Could not load nvim-dap plugin")
    return
  end

  if not validate_project() then
    return
  end

  local isDevice = projectConfig.settings.platform == constants.Platform.IOS_PHYSICAL_DEVICE
  local isMacOS = projectConfig.settings.platform == constants.Platform.MACOS
  local isSimulator = projectConfig.settings.platform == constants.Platform.IOS_SIMULATOR

  if isSimulator or isMacOS then
    device.kill_app()
  end

  if isSimulator then
    start_dap()
  end

  local projectBuilder = require("xcodebuild.project.builder")

  projectBuilder.build_project({}, function(report)
    local success = util.is_empty(report.buildErrors)
    if not success then
      if dap.session() then
        dap.terminate()
      end

      local loadedDapui, dapui = pcall(require, "dapui")
      if loadedDapui then
        dapui.close()
      end
      return
    end

    if isDevice then
      device.install_app(function()
        set_remote_debugger_mode()
        remoteDebugger.start_remote_debugger(callback)
      end)
    else
      device.run_app(isMacOS, callback)
    end
  end)
end

---It only installs the app and starts the debugger without building
---the project.
---@param callback function|nil
function M.debug_without_build(callback)
  if not validate_project() then
    return
  end

  local isDevice = projectConfig.settings.platform == constants.Platform.IOS_PHYSICAL_DEVICE
  local isSimulator = projectConfig.settings.platform == constants.Platform.IOS_SIMULATOR

  if isDevice then
    device.install_app(function()
      set_remote_debugger_mode()
      remoteDebugger.start_remote_debugger(callback)
    end)
  else
    device.kill_app()
    if isSimulator then
      start_dap()
    end
    device.run_app(true, callback)
  end
end

---Attaches the debugger to the running application when tests are starting.
---
---Tests are controlled by `xcodebuild` tool, so we can't request waiting
---for the debugger to attach. Instead, we listen to the
---`XcodebuildTestsStatus` to start the debugger.
---
---When `XcodebuildTestsFinished` or `XcodebuildActionCancelled` is received,
---we terminate the debugger session.
---If build failed, we stop waiting for events.
function M.attach_debugger_for_tests()
  local loadedDap, dap = pcall(require, "dap")
  if not loadedDap then
    notifications.send_error("Could not load nvim-dap plugin")
    return
  end

  if projectConfig.settings.platform == constants.Platform.IOS_PHYSICAL_DEVICE then
    notifications.send_error(
      "Debugging tests on physical devices is not supported. Please use the simulator."
    )
    return
  end

  if not validate_project() then
    return
  end

  local group = vim.api.nvim_create_augroup("XcodebuildAttachingDebugger", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "XcodebuildTestsStatus",
    once = true,
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
      start_dap()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "XcodebuildTestsFinished", "XcodebuildActionCancelled" },
    once = true,
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)

      if dap.session() then
        dap.terminate()
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "XcodebuildBuildFinished",
    once = true,
    callback = function(event)
      if not event.data.success then
        vim.api.nvim_del_augroup_by_id(group)
      end
    end,
  })
end

---Starts the debugger and runs all tests.
function M.debug_tests()
  actions.run_tests()
  M.attach_debugger_for_tests()
end

---Starts the debugger and runs all tests in the target.
function M.debug_target_tests()
  actions.run_target_tests()
  M.attach_debugger_for_tests()
end

---Starts the debugger and runs all tests in the class.
function M.debug_class_tests()
  actions.run_class_tests()
  M.attach_debugger_for_tests()
end

---Starts the debugger and runs the current test.
function M.debug_func_test()
  actions.run_func_test()
  M.attach_debugger_for_tests()
end

---Starts the debugger and runs the selected tests.
function M.debug_selected_tests()
  actions.run_selected_tests()
  M.attach_debugger_for_tests()
end

---Starts the debugger and re-runs the failing tests.
function M.debug_failing_tests()
  actions.run_failing_tests()
  M.attach_debugger_for_tests()
end

---Returns path to the built application.
---@return string
function M.get_program_path()
  return projectConfig.settings.appPath
end

---Waits for the application to start and returns its PID.
---@return thread|nil # coroutine with pid
function M.wait_for_pid()
  local co = coroutine
  local productName = projectConfig.settings.productName
  local xcode = require("xcodebuild.core.xcode")

  if not productName then
    notifications.send_error("You must build the application first")
    return
  end

  return co.create(function(dap_run_co)
    local pid = nil

    notifications.send("Attaching debugger...")
    for _ = 1, 10 do
      util.shell("sleep 1")
      pid = xcode.get_app_pid(productName)

      if tonumber(pid) then
        break
      end
    end

    if not tonumber(pid) then
      notifications.send_error("Launching the application timed out")

      ---@diagnostic disable-next-line: deprecated
      co.close(dap_run_co)
    end

    co.resume(dap_run_co, pid)
  end)
end

---Clears the DAP console buffer.
function M.clear_console()
  local success, dapui = pcall(require, "dapui")
  if not success then
    return
  end

  local bufnr = dapui.elements.console.buffer()
  if not bufnr then
    return
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---Updates the DAP console buffer with the given output.
---It also automatically scrolls to the last line if
---the cursor is in a different window or if the cursor
---is not on the last line.
---@param output string[]
---@param append boolean|nil # if true, appends the output to the last line
function M.update_console(output, append)
  local success, dapui = pcall(require, "dapui")
  if not success then
    return
  end

  local bufnr = dapui.elements.console.buffer()
  if not bufnr then
    return
  end

  if util.is_empty(output) then
    return
  end

  vim.bo[bufnr].modifiable = true

  local autoscroll = false
  local winnr = vim.fn.win_findbuf(bufnr)[1]
  if winnr then
    local currentWinnr = vim.api.nvim_get_current_win()
    local lastLine = vim.api.nvim_buf_line_count(bufnr)
    local currentLine = vim.api.nvim_win_get_cursor(winnr)[1]
    autoscroll = currentWinnr ~= winnr or currentLine == lastLine
  end

  if append then
    local lastLine = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
    output[1] = lastLine .. output[1]
    vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, output)
  else
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, output)
  end

  if autoscroll then
    vim.api.nvim_win_call(winnr, function()
      vim.cmd("normal! G")
    end)
  end

  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---Returns the `coodelldb` configuration for `nvim-dap`.
---@return table[]
---@usage lua [[
---require("dap").configurations.swift = require("xcodebuild.integrations.dap").get_swift_configuration()
---@usage ]]
function M.get_swift_configuration()
  return {
    {
      name = "iOS App Debugger",
      type = "codelldb",
      request = "attach",
      program = M.get_program_path,
      cwd = "${workspaceFolder}",
      stopOnEntry = false,
      waitFor = true,
    },
  }
end

---Returns the `codelldb` adapter for `nvim-dap`.
---
---Examples:
---  {codelldbPath} - `/your/path/to/codelldb-aarch64-darwin/extension/adapter/codelldb`
---  {lldbPath} - (default) `/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/LLDB`
---@param codelldbPath string
---@param lldbPath string|nil
---@param port number|nil
---@return table
---@usage lua [[
---require("dap").adapters.codelldb = require("xcodebuild.integrations.dap")
---  .get_codelldb_adapter("path/to/codelldb")
---@usage ]]
function M.get_codelldb_adapter(codelldbPath, lldbPath, port)
  return {
    type = "server",
    port = "13000",
    executable = {
      command = codelldbPath,
      args = {
        "--port",
        port or "13000",
        "--liblldb",
        lldbPath or "/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/LLDB",
      },
    },
  }
end

---Reads breakpoints from the `.nvim/xcodebuild/breakpoints.json` file.
---Returns breakpoints or nil if the file is missing.
---@return table|nil
local function read_breakpoints()
  local breakpointsPath = require("xcodebuild.project.appdata").breakpoints_filepath
  local success, content = util.readfile(breakpointsPath)

  if not success or util.is_empty(content) then
    return nil
  end

  return vim.fn.json_decode(content)
end

---Saves breakpoints to `.nvim/xcodebuild/breakpoints.json` file.
function M.save_breakpoints()
  local breakpoints = read_breakpoints() or {}
  local breakpointsPerBuffer = require("dap.breakpoints").get()

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    breakpoints[vim.api.nvim_buf_get_name(bufnr)] = breakpointsPerBuffer[bufnr]
  end

  local breakpointsPath = require("xcodebuild.project.appdata").breakpoints_filepath
  local fp = io.open(breakpointsPath, "w")

  if fp then
    fp:write(vim.fn.json_encode(breakpoints))
    fp:close()
  end
end

---Loads breakpoints from `.nvim/xcodebuild/breakpoints.json` file and sets them
---in {bufnr} or in all loaded buffers if {bufnr} is nil.
---@param bufnr number|nil
function M.load_breakpoints(bufnr)
  local breakpoints = read_breakpoints()
  if not breakpoints then
    return
  end

  local buffers = bufnr and { bufnr } or vim.api.nvim_list_bufs()

  for _, buf in ipairs(buffers) do
    local fileName = vim.api.nvim_buf_get_name(buf)

    if breakpoints[fileName] then
      for _, bp in pairs(breakpoints[fileName]) do
        local opts = {
          condition = bp.condition,
          log_message = bp.logMessage,
          hit_condition = bp.hitCondition,
        }
        require("dap.breakpoints").set(opts, tonumber(buf), bp.line)
      end
    end
  end
end

---Toggles a breakpoint in the current line and saves breakpoints to disk.
function M.toggle_breakpoint()
  require("dap").toggle_breakpoint()
  M.save_breakpoints()
end

---Toggles a breakpoint with a log message in the current line and saves breakpoints to disk.
---To print a variable, wrap it with {}: `{myObject.myProperty}`.
function M.toggle_message_breakpoint()
  require("dap").set_breakpoint(nil, nil, vim.fn.input("Breakpoint message: "))
  M.save_breakpoints()
end

---Terminates the debugger session, cancels the current action, and closes the `nvim-dap-ui`.
function M.terminate_session()
  if require("dap").session() then
    require("dap").terminate()
  end

  require("xcodebuild.actions").cancel()

  local success, dapui = pcall(require, "dapui")
  if success then
    dapui.close()
  end
end

---Sets up the adapter and configuration for the `nvim-dap` plugin.
---{codelldbPath} - path to the `codelldb` binary.
---
---Sample {codelldbPath} - `/your/path/to/codelldb-aarch64-darwin/extension/adapter/codelldb`
---{loadBreakpoints} - if true or nil, sets up an autocmd to load breakpoints when a Swift file is opened.
---@param codelldbPath string
---@param loadBreakpoints boolean|nil default: true
function M.setup(codelldbPath, loadBreakpoints)
  local dap = require("dap")
  dap.configurations.swift = M.get_swift_configuration()
  dap.adapters.codelldb = M.get_codelldb_adapter(codelldbPath)

  if loadBreakpoints ~= false then
    vim.api.nvim_create_autocmd({ "BufReadPost" }, {
      group = vim.api.nvim_create_augroup("xcodebuild-integrations-dap", { clear = true }),
      pattern = "*.swift",
      callback = function(event)
        M.load_breakpoints(event.buf)
      end,
    })
  end

  local orig_notify = require("dap.utils").notify
  ---@diagnostic disable-next-line: duplicate-set-field
  require("dap.utils").notify = function(msg, log_level)
    if not string.find(msg, "Either the adapter is slow", 1, true) then
      orig_notify(msg, log_level)
    end
  end
end

return M
