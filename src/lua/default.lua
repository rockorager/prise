local prise = require("prise")

local state = {
    pty = nil,
}

local M = {}

function M.update(event)
    if event.type == "pty_attach" then
        state.pty = event.data.pty
    end
end

function M.view()
    if state.pty then
        return prise.Surface({ pty = state.pty })
    end

    return prise.Surface({ pty = 1 })
end

return M
