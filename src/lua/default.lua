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
    local main_view
    if state.pty then
        main_view = prise.Surface({ pty = state.pty })
    else
        main_view = prise.Surface({ pty = 1 })
    end

    return prise.Column({
        cross_axis_align = "stretch",
        children = {
            main_view,
            prise.Text({
                text = " Prise Terminal ",
                style = { bg = "white", fg = "black" },
            }),
        },
    })
end

return M
