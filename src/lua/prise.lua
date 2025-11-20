local M = {}

function M.Surface(opts)
    return {
        type = "surface",
        pty = opts.pty,
    }
end

return M
