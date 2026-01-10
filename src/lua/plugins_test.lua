local plugins = require("plugins")

-- Test: normalize_spec parses user/repo correctly
local function test_setup_normalizes_specs()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "testuser/testrepo" },
        { "another/plugin", name = "custom-name", branch = "dev" },
    })

    assert(plugins.specs["testrepo"] ~= nil, "testrepo should be registered")
    assert(plugins.specs["testrepo"].user == "testuser", "user should be testuser")
    assert(plugins.specs["testrepo"].repo_name == "testrepo", "repo_name should be testrepo")
    assert(plugins.specs["testrepo"].branch == "HEAD", "default branch should be HEAD")

    assert(plugins.specs["custom-name"] ~= nil, "custom-name should be registered")
    assert(plugins.specs["custom-name"].branch == "dev", "branch should be dev")

    print("PASS: test_setup_normalizes_specs")
end

-- Test: key triggers are indexed
local function test_key_triggers()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "user/plugin1", keys = { "<leader>g", "<leader>b" } },
        { "user/plugin2", keys = "<leader>g" },
    })

    assert(plugins.key_triggers["<leader>g"] ~= nil, "key trigger should exist")
    assert(#plugins.key_triggers["<leader>g"] == 2, "should have 2 plugins for <leader>g")
    assert(plugins.key_triggers["<leader>b"] ~= nil, "key trigger should exist")
    assert(#plugins.key_triggers["<leader>b"] == 1, "should have 1 plugin for <leader>b")

    print("PASS: test_key_triggers")
end

-- Test: event triggers are indexed
local function test_event_triggers()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "user/plugin1", event = "UI_READY" },
        { "user/plugin2", event = { "UI_READY", "VeryLazy" } },
    })

    assert(plugins.event_triggers["UI_READY"] ~= nil, "event trigger should exist")
    assert(#plugins.event_triggers["UI_READY"] == 2, "should have 2 plugins for UI_READY")
    assert(plugins.event_triggers["VeryLazy"] ~= nil, "event trigger should exist")
    assert(#plugins.event_triggers["VeryLazy"] == 1, "should have 1 plugin for VeryLazy")

    print("PASS: test_event_triggers")
end

-- Test: hook system works
local function test_hooks()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    local called = false
    local received_payload = nil

    plugins.on("test_hook", function(payload)
        called = true
        received_payload = payload
    end)

    plugins.emit("test_hook", { foo = "bar" })

    assert(called, "hook should be called")
    assert(received_payload.foo == "bar", "payload should be passed")

    print("PASS: test_hooks")
end

-- Test: off removes hook
local function test_off()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    local call_count = 0
    local handler = function()
        call_count = call_count + 1
    end

    plugins.on("test_hook", handler)
    plugins.emit("test_hook")
    assert(call_count == 1, "should be called once")

    plugins.off("test_hook", handler)
    plugins.emit("test_hook")
    assert(call_count == 1, "should still be 1 after off")

    print("PASS: test_off")
end

-- Test: list returns sorted plugin names
local function test_list()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "user/zebra" },
        { "user/alpha" },
        { "user/beta" },
    })

    local names = plugins.list()
    assert(names[1] == "alpha", "first should be alpha")
    assert(names[2] == "beta", "second should be beta")
    assert(names[3] == "zebra", "third should be zebra")

    print("PASS: test_list")
end

-- Test: info returns plugin info
local function test_info()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "user/testplugin", branch = "main", lazy = false },
    })

    local info = plugins.info("testplugin")
    assert(info ~= nil, "info should exist")
    assert(info.name == "testplugin", "name should match")
    assert(info.repo == "user/testplugin", "repo should match")
    assert(info.branch == "main", "branch should match")
    assert(info.lazy == false, "lazy should be false")

    local missing = plugins.info("nonexistent")
    assert(missing == nil, "missing plugin should return nil")

    print("PASS: test_info")
end

-- Test: is_loaded returns correct status
local function test_is_loaded()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "user/testplugin" },
    })

    assert(plugins.is_loaded("testplugin") == false, "should not be loaded initially")

    plugins.loaded["testplugin"] = true
    assert(plugins.is_loaded("testplugin") == true, "should be loaded after marking")

    plugins.loaded["testplugin"] = false
    assert(plugins.is_loaded("testplugin") == false, "should not be loaded when false")

    print("PASS: test_is_loaded")
end

-- Test: enabled function is called
local function test_enabled_function()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    local enabled_called = false

    plugins.setup({
        {
            "user/testplugin",
            enabled = function()
                enabled_called = true
                return false
            end,
        },
    })

    local info = plugins.info("testplugin")
    assert(enabled_called, "enabled function should be called")
    assert(info.enabled == false, "should be disabled")

    print("PASS: test_enabled_function")
end

-- Test: local path plugins are recognized
local function test_local_path_plugins()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "./my-local-plugin" },
        { "../parent-plugin", name = "parent" },
        { "/absolute/path/plugin" },
        { "~/home-plugin" },
    })

    -- Check ./my-local-plugin
    assert(plugins.specs["my-local-plugin"] ~= nil, "my-local-plugin should be registered")
    assert(plugins.specs["my-local-plugin"].is_local == true, "should be local")
    assert(plugins.specs["my-local-plugin"].dir == "./my-local-plugin", "dir should be set")

    -- Check ../parent-plugin with custom name
    assert(plugins.specs["parent"] ~= nil, "parent should be registered")
    assert(plugins.specs["parent"].is_local == true, "should be local")

    -- Check /absolute/path/plugin
    assert(plugins.specs["plugin"] ~= nil, "plugin should be registered")
    assert(plugins.specs["plugin"].is_local == true, "should be local")
    assert(plugins.specs["plugin"].dir == "/absolute/path/plugin", "dir should be absolute")

    -- Check ~/home-plugin (tilde expansion)
    assert(plugins.specs["home-plugin"] ~= nil, "home-plugin should be registered")
    assert(plugins.specs["home-plugin"].is_local == true, "should be local")
    local home = os.getenv("HOME")
    if home then
        assert(plugins.specs["home-plugin"].dir == home .. "/home-plugin", "dir should be expanded")
    end

    print("PASS: test_local_path_plugins")
end

-- Test: info returns correct data for local plugins
local function test_local_plugin_info()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "/path/to/my-plugin", lazy = false },
    })

    local info = plugins.info("my-plugin")
    assert(info ~= nil, "info should exist")
    assert(info.is_local == true, "should be local")
    assert(info.dir == "/path/to/my-plugin", "dir should match")
    assert(info.repo == nil, "repo should be nil for local plugins")
    assert(info.branch == nil, "branch should be nil for local plugins")

    print("PASS: test_local_plugin_info")
end

-- Test: remote plugins have correct fields
local function test_remote_plugin_info()
    plugins.specs = {}
    plugins.loaded = {}
    plugins.hooks = {}
    plugins.key_triggers = {}
    plugins.event_triggers = {}

    plugins.setup({
        { "user/remote-plugin", branch = "main" },
    })

    local info = plugins.info("remote-plugin")
    assert(info ~= nil, "info should exist")
    assert(info.is_local == false, "should not be local")
    assert(info.repo == "user/remote-plugin", "repo should match")
    assert(info.branch == "main", "branch should match")
    assert(info.source == "user/remote-plugin", "source should match")

    print("PASS: test_remote_plugin_info")
end

-- Run all tests
test_setup_normalizes_specs()
test_key_triggers()
test_event_triggers()
test_hooks()
test_off()
test_list()
test_info()
test_is_loaded()
test_enabled_function()
test_local_path_plugins()
test_local_plugin_info()
test_remote_plugin_info()

print("\nAll plugins tests passed!")
