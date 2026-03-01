--[[
    Proper 3rd Person Camera
    REFramework plugin for Resident Evil 9: Requiem

    Pulls the third-person camera further back for a wider view of the
    action, inspired by the classic Max Payne camera style. Modifies
    the game's internal GazeDistance parameter so wall collision is
    handled natively by the engine.

    Only movement states are affected (walking, running, crouching).
    Aiming, cutscenes, gimmicks, and all other states keep their
    original camera distance.

    Requires: REFramework (https://github.com/praydog/REFramework)
--]]

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local CONFIG_FILE     = "requiem_cam_dist.json"
local DEFAULT_CONFIG  = { enabled = true, distance_multiplier = 3.0 }
local WARMUP_FRAMES   = 120
local RETRY_INTERVAL  = 60

local config = {}
for key, default in pairs(DEFAULT_CONFIG) do config[key] = default end
do
    local saved = json.load_file(CONFIG_FILE)
    if type(saved) == "table" then
        for key in pairs(DEFAULT_CONFIG) do
            if saved[key] ~= nil then config[key] = saved[key] end
        end
    end
end

---------------------------------------------------------------------------
-- Movement states whose camera distance should be extended.
-- Every other state (aiming, cutscenes, gimmicks, death, etc.) is
-- left untouched so it behaves exactly like vanilla.
---------------------------------------------------------------------------
local MOVEMENT_STATES = {
    Normal       = true,
    Run          = true,
    Crouch       = true,
    AutoWalk     = true,
    CrouchAutoWalk = true,
    OnStair      = true,
    CrouchOnStair  = true,
    LeftNormal   = true,
    LeftCrouch   = true,
    MeleeRun     = true,
}

---------------------------------------------------------------------------
-- Safe accessors — every game-object call goes through pcall so a
-- single stale reference can never crash the script or kill the callback.
---------------------------------------------------------------------------
local function safe_call(obj, method, ...)
    if not obj then return nil end
    local ok, result = pcall(obj.call, obj, method, ...)
    return ok and result or nil
end

local function safe_get(obj, field)
    if not obj then return nil end
    local ok, result = pcall(obj.get_field, obj, field)
    return ok and result or nil
end

local function safe_set(obj, field, value)
    if not obj then return end
    pcall(obj.set_field, obj, field, value)
end

---------------------------------------------------------------------------
-- Cutscene detection via app.GuiManager situation type.
-- Values: Normal = 0, CutScene = 1, Movie = 2
---------------------------------------------------------------------------
local cached_gui_getter = nil

local function is_in_cutscene()
    local gui_manager = sdk.get_managed_singleton("app.GuiManager")
    if not gui_manager then return false end

    if not cached_gui_getter then
        for _, getter in ipairs({"get_CurrentSituationType", "get_SituationType"}) do
            if safe_call(gui_manager, getter) ~= nil then
                cached_gui_getter = getter
                break
            end
        end
    end
    if not cached_gui_getter then return false end

    local situation = safe_call(gui_manager, cached_gui_getter)
    return situation == 1 or situation == 2
end

---------------------------------------------------------------------------
-- Camera parameter access.
--
-- Object path (discovered via REFramework Object Explorer):
--   app.CameraSystem (singleton)
--     .getCameraBlender(0)
--       .<BusyCameraController>k__BackingField  (PlayerTPSCameraController)
--         ._TPSCameraSettingUserData
--           ._DefaultSettingParam / ._SettingList[i]
--             ._Default  (PlayerCameraTPSActionParamUserData)
--               ._PositionUserData._Param  (TPSCameraParam)
--                 ._GazeDistance  (float)
---------------------------------------------------------------------------
local function get_tps_setting_data()
    local camera_system = sdk.get_managed_singleton("app.CameraSystem")
    if not camera_system then return nil end

    local blender    = safe_call(camera_system, "getCameraBlender", 0)
    local controller = safe_get(blender, "<BusyCameraController>k__BackingField")
    if not controller then return nil end

    local type_def = controller:get_type_definition()
    if not type_def or not type_def:get_full_name():find("TPS") then return nil end

    return safe_get(controller, "_TPSCameraSettingUserData")
end

local function read_gaze_param(action_param_data)
    local position_data = safe_get(action_param_data, "_PositionUserData")
    local tps_param     = safe_get(position_data, "_Param")
    local gaze_distance = safe_get(tps_param, "_GazeDistance")

    if type(gaze_distance) == "number" and gaze_distance > 0 then
        return tps_param, gaze_distance
    end
    return nil, nil
end

local function get_state_name(state_object)
    local raw = safe_call(state_object, "ToString")
    if type(raw) ~= "string" then return nil end
    return raw:match("%.([^%.]+)$") or raw
end

---------------------------------------------------------------------------
-- State map: built once after gameplay starts.
-- Stores only indices, names, and original float values — no game-object
-- references are kept across frames, which prevents shutdown crashes.
--
--   state_entries[i] = { name = "Run", original_gaze = 2.0 }
--
-- Only entries for MOVEMENT_STATES are recorded.
---------------------------------------------------------------------------
local state_entries      = {}
local default_gaze       = nil
local is_initialised     = false
local is_alive           = true

local function build_state_map()
    local setting_data = get_tps_setting_data()
    if not setting_data then return false end

    state_entries = {}
    default_gaze  = nil

    -- Default setting (used for Normal when no per-state override exists)
    local default_setting = safe_get(setting_data, "_DefaultSettingParam")
    if default_setting then
        local _, gaze = read_gaze_param(safe_get(default_setting, "_Default"))
        if gaze then default_gaze = gaze end
    end

    -- Per-state settings list
    local setting_list = safe_get(setting_data, "_SettingList")
    if not setting_list then return default_gaze ~= nil end

    local count = safe_get(setting_list, "_size") or 0
    for i = 0, count - 1 do
        local entry = safe_call(setting_list, "get_Item", i)
        if entry then
            local name      = get_state_name(safe_get(entry, "_State"))
            local _, gaze   = read_gaze_param(safe_get(entry, "_Default"))
            if name and gaze and MOVEMENT_STATES[name] then
                state_entries[i] = { name = name, original_gaze = gaze }
            end
        end
    end

    return next(state_entries) ~= nil or default_gaze ~= nil
end

---------------------------------------------------------------------------
-- Write modified gaze values for every tracked movement state.
-- Re-traverses the full object path each frame so no game-object
-- references survive between frames.
---------------------------------------------------------------------------
local function write_gaze_values(multiplier)
    local setting_data = get_tps_setting_data()
    if not setting_data then return end

    -- Default param
    if default_gaze then
        local default_setting = safe_get(setting_data, "_DefaultSettingParam")
        if default_setting then
            local param = read_gaze_param(safe_get(default_setting, "_Default"))
            if param then
                safe_set(param, "_GazeDistance", default_gaze * multiplier)
            end
        end
    end

    -- Per-state params
    local setting_list = safe_get(setting_data, "_SettingList")
    if not setting_list then return end

    for index, entry in pairs(state_entries) do
        local item  = safe_call(setting_list, "get_Item", index)
        local param = item and read_gaze_param(safe_get(item, "_Default"))
        if param then
            safe_set(param, "_GazeDistance", entry.original_gaze * multiplier)
        end
    end
end

---------------------------------------------------------------------------
-- Frame update — single pre-LateUpdate callback.
-- Enabled + gameplay  -> write multiplied gaze values
-- Disabled / cutscene -> write original values (multiplier = 1)
---------------------------------------------------------------------------
local frame_count = 0

re.on_pre_application_entry("LateUpdateBehavior", function()
    if not is_alive then return end
    frame_count = frame_count + 1

    if not is_initialised then
        if frame_count < WARMUP_FRAMES then return end
        if frame_count % RETRY_INTERVAL ~= 0 then return end
        is_initialised = build_state_map()
        return
    end

    if config.enabled and not is_in_cutscene() then
        write_gaze_values(math.max(1.0, config.distance_multiplier))
    else
        write_gaze_values(1.0)
    end
end)

---------------------------------------------------------------------------
-- REFramework UI
---------------------------------------------------------------------------
re.on_draw_ui(function()
    if imgui.tree_node("Proper 3rd Person Camera") then
        local changed
        changed, config.enabled = imgui.checkbox("Enabled", config.enabled)
        changed, config.distance_multiplier = imgui.slider_float(
            "Distance Multiplier", config.distance_multiplier, 1.0, 3.0, "%.2f")

        if is_initialised and default_gaze then
            imgui.text(string.format("Base: %.2f m   Effective: %.2f m",
                default_gaze, default_gaze * config.distance_multiplier))
        else
            imgui.text("Waiting for camera...")
        end
        imgui.tree_pop()
    end
end)

---------------------------------------------------------------------------
-- Persistence & cleanup
---------------------------------------------------------------------------
re.on_config_save(function()
    json.dump_file(CONFIG_FILE, config)
end)

re.on_script_reset(function()
    is_alive = false
    state_entries  = {}
    default_gaze   = nil
    is_initialised = false
end)
