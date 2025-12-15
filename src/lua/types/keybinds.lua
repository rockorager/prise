---@meta

---@class PriseKeybind
---@field key string the key (e.g., "k", "p", "Enter")
---@field ctrl? boolean require ctrl modifier
---@field alt? boolean require alt modifier
---@field shift? boolean require shift modifier
---@field super? boolean require super/cmd modifier

---@class PriseDirectKeybind
---@field key string the key (e.g., "h", "j", "k", "l")
---@field ctrl? boolean require ctrl modifier
---@field alt? boolean require alt modifier
---@field shift? boolean require shift modifier
---@field super? boolean require super/cmd modifier
---@field action string action name to execute (e.g., "focus_left", "resize_right")
---@field params? table optional parameters for the action

---@class PriseKeybinds
---@field leader? PriseKeybind key to enter command mode (default: super+k)
---@field palette? PriseKeybind key to open command palette (default: super+p)
---@field direct? PriseDirectKeybind[] direct keybindings that bypass prefix mode
