---@meta

---Log functions provided by prise
---@class PriseLog
---@field debug fun(msg: string) Log a debug message
---@field info fun(msg: string) Log an info message
---@field warn fun(msg: string) Log a warning message
---@field err fun(msg: string) Log an error message
---@field error fun(msg: string) Log an error message (alias)

---Spawn options for creating new PTYs
---@class SpawnOptions
---@field cwd? string Working directory for the new process

---The prise module provides core functionality for the terminal multiplexer
---@class prise
---@field log PriseLog Logging functions
---@field platform "macos"|"linux"|"windows"|"unknown" Current platform
---@field keybind KeybindModule Keybind compilation and matching
local prise = {}

---Load the tiling UI module
---@return PriseUI
function prise.tiling() end

---Create a terminal widget that displays a PTY
---@param opts TerminalOpts
---@return table Terminal widget
function prise.Terminal(opts) end

---Create a text widget with optional styling and segments
---@param opts string|TextSegment[]|TextOpts
---@return table Text widget
function prise.Text(opts) end

---Create a column layout that arranges children vertically
---@param opts table[]|LayoutOpts
---@return table Column widget
function prise.Column(opts) end

---Create a row layout that arranges children horizontally
---@param opts table[]|LayoutOpts
---@return table Row widget
function prise.Row(opts) end

---Create a stacked layout that overlays children on top of each other
---@param opts table[]|LayoutOpts
---@return table Stack widget
function prise.Stack(opts) end

---Create a positioned widget that places a child at absolute coordinates
---@param opts PositionedOpts
---@return table Positioned widget
function prise.Positioned(opts) end

---Create a text input widget for capturing user input
---@param opts TextInputOpts
---@return table TextInput widget
function prise.TextInput(opts) end

---Create a list widget with items and optional selection
---@param opts ListOpts|string[]
---@return table List widget
function prise.List(opts) end

---Create a box widget with border and styling options
---@param opts BoxOpts
---@return table Box widget
function prise.Box(opts) end

---Create a padding widget that adds spacing around a child
---@param opts PaddingOpts
---@return table Padding widget
function prise.Padding(opts) end

---Set a timeout to call a function after a delay
---@param ms integer Milliseconds to wait
---@param callback fun() Function to call
---@return Timer
function prise.set_timeout(ms, callback) end

---Exit the application (deletes session)
function prise.exit() end

---Spawn a new PTY process
---@param opts? SpawnOptions
function prise.spawn(opts) end

---Request a frame redraw
function prise.request_frame() end

---Detach from the current session
---@param session_name? string Optional session name to switch to
function prise.detach(session_name) end

---Get the next available session name
---@return string
function prise.next_session_name() end

---Trigger an auto-save of the session
function prise.save() end

---Get the current session name
---@return string?
function prise.get_session_name() end

---Rename the current session
---@param new_name string
function prise.rename_session(new_name) end

---List all available sessions
---@return string[]
function prise.list_sessions() end

---Switch to a different session
---@param target_session string The session name to switch to
function prise.switch_session(target_session) end

---Create a new TextInput handle
---@return TextInput
function prise.create_text_input() end

---Get the grapheme width of a string (for proper Unicode handling)
---@param str string
---@return integer
function prise.gwidth(str) end

---Get the current time formatted as HH:MM
---@return string
function prise.get_time() end

---Get the git branch for a directory
---@param cwd string The directory to check
---@return string? The branch name, or nil if not a git repo
function prise.get_git_branch(cwd) end

return prise
