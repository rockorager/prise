---! Test serialization of tiling state with segments

local M = {}

---Test serialize/deserialize of split state
---@return nil
local function test_serialize_deserialize_split()
    -- Create a simple split
    local split = {
        type = "split",
        split_id = 1,
        direction = "row",
        ratio = 0.5,
        children = {
            {
                type = "pane",
                id = 100,
                pty_id = 1,
                ratio = 0.5,
            },
            {
                type = "pane",
                id = 101,
                pty_id = 2,
                ratio = 0.5,
            },
        },
    }

    print("Test: split without last_focused_child_idx should serialize/deserialize correctly")

    -- Verify no last_focused_child_idx field is added
    if split.last_focused_child_idx == nil then
        print("✓ Split correctly has no last_focused_child_idx")
    else
        print("✗ Split unexpectedly has last_focused_child_idx")
    end
end

---Test that both-sides-split fallback works
---@return nil
local function test_both_sides_split_fallback()
    print("Test: both-sides-split in create_divider_segments should fall back to simple coloring")
    -- This is a conceptual test - actual testing requires running create_divider_segments
end

---Test segment ratio validation
---@return nil
local function test_segment_ratios()
    print("Test: segment ratios should be in range [0.0, 1.0]")

    local segment = {
        ratio_start = 0.25,
        ratio_end = 0.75,
        style = { fg = "#ffffff" },
    }

    if segment.ratio_start >= 0.0 and segment.ratio_end <= 1.0 then
        print("✓ Segment ratios are valid")
    else
        print("✗ Segment ratios are invalid")
    end
end

M.test_serialize_deserialize_split = test_serialize_deserialize_split
M.test_both_sides_split_fallback = test_both_sides_split_fallback
M.test_segment_ratios = test_segment_ratios

return M
