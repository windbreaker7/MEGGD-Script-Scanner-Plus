-- ==========================================
-- MEGGD Script Scanner Mobile - Enhanced
-- Original by: MEGGD
-- Enhancements: Claude (Anthropic)
-- ==========================================

local user_input_service = game:GetService("UserInputService")
local tween_service = game:GetService("TweenService")
local run_service = game:GetService("RunService")
local text_service = game:GetService("TextService")
local core_gui = game:GetService("CoreGui")
local http_service = game:GetService("HttpService")

local current_theme = {
    bg = Color3.fromRGB(30, 30, 30),
    element_bg = Color3.fromRGB(37, 37, 38),
    border = Color3.fromRGB(62, 62, 66),
    text = Color3.fromRGB(212, 212, 212),
    accent = Color3.fromRGB(10, 119, 215)
}

local type_colors = {
    LocalScript = Color3.fromRGB(86, 156, 214),
    ModuleScript = Color3.fromRGB(78, 201, 176),
    Script = Color3.fromRGB(197, 134, 192)
}

local flat_image = "rbxassetid://2790382281"
local decompile_cache = {}
local button_colors = {}
local active_search_terms = {}
local active_search_id = 0
local http_request = request or http_request or (http and http.request)

local setting_decompiler = "lua.expert"
local setting_remove_comments = false
local setting_use_regex = false
local setting_font_size = 14
local setting_filter_types = { LocalScript = true, ModuleScript = true, Script = true }
local setting_sort_mode = "matches" -- "matches" | "name" | "path"
local setting_max_workers = 10        -- concurrent decompile workers
local setting_scan_scope = {          -- which services to scan
    game          = true,
    PlayerScripts = false,
    ReplicatedStorage = false,
    ServerScriptService = false,
    workspace     = false,
}
local CACHE_MAX = 150                  -- max decompile cache entries
local cache_order = {}                 -- LRU eviction order

local search_history = {}
local MAX_HISTORY = 10

local current_results = {} -- {script, count, hash, path, color}
local bookmarks = {}       -- { [path] = result_entry }
local active_decompile_text = ""
local result_count_label = nil

-- ==========================================
-- HELPERS
-- ==========================================

local function create_instance(class_name, properties)
    local instance = Instance.new(class_name)
    for property, value in pairs(properties) do
        instance[property] = value
    end
    return instance
end

local function clamp_pos(x, y, width, height)
    local vp = workspace.CurrentCamera.ViewportSize
    local max_x = math.max(0, vp.X - width)
    local max_y = math.max(0, vp.Y - height)
    return math.clamp(x, 0, max_x), math.clamp(y, 0, max_y)
end

local function escape_pattern(text)
    return text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function case_insensitive_pattern(pattern)
    return pattern:gsub("(%a)", function(v)
        return "[" .. v:upper() .. v:lower() .. "]"
    end)
end

local function format_bytes(n)
    if n < 1024 then return n .. " B"
    elseif n < 1024*1024 then return string.format("%.1f KB", n/1024)
    else return string.format("%.1f MB", n/(1024*1024)) end
end

-- LRU cache helper: evict oldest when over limit
local function cache_set(script_inst, value)
    if not decompile_cache[script_inst] then
        table.insert(cache_order, script_inst)
        -- Evict oldest entries (skip destroyed instances)
        while #cache_order > CACHE_MAX do
            local oldest = table.remove(cache_order, 1)
            decompile_cache[oldest] = nil
        end
    end
    -- Don't cache if instance is gone
    if typeof(script_inst) == "Instance" and not script_inst.Parent and
       not (getscripts and table.find(getscripts(), script_inst)) then
        return
    end
    decompile_cache[script_inst] = value
end

local function push_history(term)
    if term == "" then return end
    for i, v in ipairs(search_history) do
        if v == term then table.remove(search_history, i) break end
    end
    table.insert(search_history, 1, term)
    if #search_history > MAX_HISTORY then
        table.remove(search_history)
    end
end

-- ==========================================
-- GUI STRUCTURE
-- ==========================================

local gui_parent = gethui and gethui() or core_gui
local screen_gui = create_instance("ScreenGui", {
    Name = "meggd_scanner_enhanced",
    Parent = gui_parent,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling
})

local main_gui = create_instance("Frame", {
    Name = "main_container",
    Parent = screen_gui,
    BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 2,
    BorderColor3 = current_theme.border,
    Position = UDim2.new(0.5, -210, 0.5, -185),
    Size = UDim2.new(0, 420, 0, 370),
    Active = true,
    ClipsDescendants = true,
    ZIndex = 10
})

local warning_container = create_instance("Frame", {
    Name = "warning_container",
    Parent = screen_gui,
    BackgroundTransparency = 1,
    Size = UDim2.new(0, 260, 1, 0),
    Position = UDim2.new(0, 0, 0, 0),
    ZIndex = 1,
    ClipsDescendants = true
})

local resize_handle = create_instance("Frame", {
    Name = "resize_handle",
    Parent = screen_gui,
    BackgroundTransparency = 1,
    Size = UDim2.new(0, 20, 0, 20),
    Active = true,
    ZIndex = 11,
    AnchorPoint = Vector2.new(0, 0)
})

local handle_part_h = create_instance("Frame", {
    Parent = resize_handle,
    BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 1, -4),
    Size = UDim2.new(1, 0, 0, 4)
})

local handle_part_v = create_instance("Frame", {
    Parent = resize_handle,
    BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0,
    Position = UDim2.new(1, -4, 0, 0),
    Size = UDim2.new(0, 4, 1, 0)
})

local function update_positions()
    resize_handle.Position = UDim2.new(
        0, main_gui.AbsolutePosition.X + main_gui.AbsoluteSize.X - 2,
        0, main_gui.AbsolutePosition.Y + main_gui.AbsoluteSize.Y - 2
    )
    warning_container.Position = UDim2.new(
        0, main_gui.AbsolutePosition.X + main_gui.AbsoluteSize.X + 8,
        0, main_gui.AbsolutePosition.Y
    )
end

main_gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(update_positions)
main_gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(update_positions)
task.spawn(function()
    task.wait()
    update_positions()
    local ix, iy = clamp_pos(main_gui.AbsolutePosition.X, main_gui.AbsolutePosition.Y, main_gui.AbsoluteSize.X, main_gui.AbsoluteSize.Y)
    main_gui.Position = UDim2.new(0, ix, 0, iy)
end)

-- Missing function warnings
local missing_funcs = {}
if not getscriptbytecode then table.insert(missing_funcs, "getscriptbytecode") end
if not http_request then table.insert(missing_funcs, "request") end
if not getscripthash then table.insert(missing_funcs, "getscripthash") end
if not getscripts then table.insert(missing_funcs, "getscripts") end
if not getnilinstances then table.insert(missing_funcs, "getnilinstances") end
if not getloadedmodules then table.insert(missing_funcs, "getloadedmodules") end
if not getrunningscripts then table.insert(missing_funcs, "getrunningscripts") end

if #missing_funcs > 0 then
    local y_off = 10
    for i, func_name in ipairs(missing_funcs) do
        local w_frame = create_instance("Frame", {
            Parent = warning_container,
            BackgroundColor3 = current_theme.element_bg,
            BorderColor3 = Color3.fromRGB(255, 255, 255),
            BorderSizePixel = 2,
            Size = UDim2.new(0, 240, 0, 44),
            Position = UDim2.new(0, -260, 0, y_off),
            ZIndex = 1
        })
        create_instance("TextLabel", {
            Parent = w_frame,
            BackgroundTransparency = 1,
            Position = UDim2.new(0, 8, 0, 0),
            Size = UDim2.new(1, -16, 1, 0),
            Font = Enum.Font.Arcade,
            TextSize = 13,
            RichText = true,
            TextWrapped = true,
            Text = '<font color="rgb(255,0,0)">Missing: </font><font color="rgb(255,255,0)">' .. func_name .. '</font>',
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            ZIndex = 2
        })
        tween_service:Create(w_frame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Position = UDim2.new(0, 0, 0, y_off)
        }):Play()
        y_off = y_off + 54
        task.delay(2.5 + (i * 0.2), function()
            if w_frame and w_frame.Parent then
                local tw_out = tween_service:Create(w_frame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                    Position = UDim2.new(0, -260, 0, w_frame.Position.Y.Offset)
                })
                tw_out:Play()
                tw_out.Completed:Connect(function()
                    if w_frame and w_frame.Parent then w_frame:Destroy() end
                end)
            end
        end)
    end
end

-- ==========================================
-- BASE64 + DECOMPILERS
-- ==========================================

local base64_encoder = (crypt and crypt.base64encode) or function(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x)
        local r, byte = '', x:byte()
        for i = 8, 1, -1 do r = r .. (byte % 2^i - byte % 2^(i-1) > 0 and '1' or '0') end
        return r
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i,i) == '1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({'', '==', '='})[#data % 3 + 1])
end

getgenv().api_decompile_expert = function(scr)
    if not getscriptbytecode then return "-- getscriptbytecode not supported" end
    if not http_request then return "-- http requests not supported" end
    local ok, bytecode = pcall(getscriptbytecode, scr)
    if not ok then return "-- failed to read bytecode\n--[[\n" .. tostring(bytecode) .. "\n--]]" end
    local res = http_request({
        Url = "https://api.lua.expert/decompile",
        Method = "POST",
        Headers = { ["content-type"] = "application/json" },
        Body = http_service:JSONEncode({ script = base64_encoder(bytecode) })
    })
    if not res or res.StatusCode ~= 200 then
        if res and res.StatusCode == 429 then return "-- api rate limit reached (500/min)" end
        return "-- api request error\n--[[\n" .. (res and res.Body or "no response") .. "\n--]]"
    end
    return res.Body
end

getgenv().api_decompile_shiny = function(scr)
    if not getscriptbytecode then return "-- getscriptbytecode not supported" end
    if not http_request then return "-- http requests not supported" end
    local ok, bytecode = pcall(getscriptbytecode, scr)
    if not ok then return "-- failed to read bytecode\n--[[\n" .. tostring(bytecode) .. "\n--]]" end
    local res = http_request({
        Url = "https://decompile-r3lh.onrender.com/luau/decompile",
        Method = "POST",
        Body = base64_encoder(bytecode)
    })
    if not res or res.StatusCode ~= 200 then
        return "-- api request error\n--[[\n" .. (res and res.Body or "no response") .. "\n--]]"
    end
    return res.Body
end

getgenv().api_decompile_ironbrew = function(scr)
    if not getscriptbytecode then return "-- getscriptbytecode not supported" end
    if not http_request then return "-- http requests not supported" end
    local ok, bytecode = pcall(getscriptbytecode, scr)
    if not ok then return "-- failed to read bytecode\n--[[\n" .. tostring(bytecode) .. "\n--]]" end
    local res = http_request({
        Url = "https://hook.eu2.make.com/decompile",
        Method = "POST",
        Headers = { ["content-type"] = "application/json" },
        Body = http_service:JSONEncode({ bytecode = base64_encoder(bytecode) })
    })
    if not res or res.StatusCode ~= 200 then
        return "-- api request error\n--[[\n" .. (res and res.Body or "no response") .. "\n--]]"
    end
    return res.Body
end

local function do_decompile(script_instance)
    if setting_decompiler == "Shiny" then
        return api_decompile_shiny(script_instance)
    elseif setting_decompiler == "IronBrew" then
        return api_decompile_ironbrew(script_instance)
    else
        return api_decompile_expert(script_instance)
    end
end

-- ==========================================
-- PIXEL ICON HELPER
-- ==========================================

local function draw_pixel_icon(parent, map, color, p_size)
    local pixel_size = p_size or 2
    local width = #map[1] * pixel_size
    local height = #map * pixel_size
    local container = create_instance("Frame", {
        Parent = parent,
        BackgroundTransparency = 1,
        Size = UDim2.new(0, width, 0, height),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0.5, 0.5)
    })
    for y, row in ipairs(map) do
        local x = 1
        while x <= #row do
            if row:sub(x, x) == "1" then
                local start_x = x
                while x + 1 <= #row and row:sub(x + 1, x + 1) == "1" do x = x + 1 end
                local segment_width = (x - start_x + 1) * pixel_size
                create_instance("Frame", {
                    Parent = container,
                    BackgroundColor3 = color,
                    BorderSizePixel = 0,
                    Position = UDim2.new(0, (start_x - 1) * pixel_size, 0, (y - 1) * pixel_size),
                    Size = UDim2.new(0, segment_width, 0, pixel_size)
                })
            end
            x = x + 1
        end
    end
    return container
end

-- ==========================================
-- TOP BAR
-- ==========================================

local top_bar = create_instance("Frame", {
    Parent = main_gui,
    BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 46),
    ClipsDescendants = true
})

local meggd_badge = create_instance("Frame", {
    Parent = top_bar,
    BackgroundColor3 = Color3.fromRGB(0, 150, 255),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 10, 0, 7),
    Size = UDim2.new(0, 50, 0, 14)
})
create_instance("TextLabel", {
    Parent = meggd_badge, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.Arcade,
    Text = "MEGGD", TextColor3 = Color3.fromRGB(255,255,255), TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center
})

create_instance("TextLabel", {
    Parent = top_bar, BackgroundTransparency = 1,
    Position = UDim2.new(0, 64, 0, 7), Size = UDim2.new(0, 60, 0, 14),
    Font = Enum.Font.Arcade, Text = "V2.2.0",
    TextColor3 = Color3.fromRGB(160, 205, 230), TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center
})

create_instance("TextLabel", {
    Parent = top_bar, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, 20), Size = UDim2.new(0, 200, 0, 18),
    Font = Enum.Font.Arcade, Text = "Script Scanner",
    TextColor3 = current_theme.text, TextSize = 18,
    TextXAlignment = Enum.TextXAlignment.Left
})

local close_button = create_instance("TextButton", {
    Parent = top_bar, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -38, 0, 8), Size = UDim2.new(0, 30, 0, 30),
    Text = "", AutoButtonColor = false
})
button_colors[close_button] = current_theme.bg

local hide_button = create_instance("TextButton", {
    Parent = top_bar, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -72, 0, 8), Size = UDim2.new(0, 30, 0, 30),
    Text = "", AutoButtonColor = false
})
button_colors[hide_button] = current_theme.bg

local settings_button = create_instance("TextButton", {
    Parent = top_bar, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -106, 0, 8), Size = UDim2.new(0, 30, 0, 30),
    Text = "", AutoButtonColor = false
})
button_colors[settings_button] = current_theme.bg

-- R-SPY button (Remote Spy)
local rspy_nav_btn = create_instance("TextButton", {
    Parent = top_bar, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.accent, BorderSizePixel = 1,
    Position = UDim2.new(1, -140, 0, 8), Size = UDim2.new(0, 30, 0, 30),
    Font = Enum.Font.Arcade, Text = "RS",
    TextColor3 = current_theme.accent, TextSize = 11,
    AutoButtonColor = false,
})
button_colors[rspy_nav_btn] = current_theme.element_bg

local floating_hide = create_instance("TextButton", {
    Parent = screen_gui, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 2,
    Size = UDim2.new(0, 0, 0, 0), Position = UDim2.new(0, 0, 0, 0),
    Text = "", AutoButtonColor = false, Visible = false, ZIndex = 50
})
button_colors[floating_hide] = current_theme.bg

draw_pixel_icon(close_button, {
    "10000001","01000010","00100100","00011000",
    "00011000","00100100","01000010","10000001"
}, Color3.fromRGB(220, 60, 60), 2)

draw_pixel_icon(hide_button, {
    "000011110001","001100001110","010011110110",
    "100110011001","100100011001","100110111001",
    "010011110010","001110001100","100011110000"
}, current_theme.text, 2)

draw_pixel_icon(floating_hide, {
    "000011110000","001100001100","010011110010",
    "100110011001","100100001001","100110011001",
    "010011110010","001100001100","000011110000"
}, current_theme.text, 2)

draw_pixel_icon(settings_button, {
    "01011010","11111111","01100110","11000011",
    "11000011","01100110","11111111","01011010"
}, current_theme.text, 2)

-- ==========================================
-- SEARCH BAR + FILTER ROW
-- ==========================================

local search_container = create_instance("Frame", {
    Parent = main_gui, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 56),
    Size = UDim2.new(1, -20, 0, 30), ClipsDescendants = true
})

local search_box = create_instance("TextBox", {
    Parent = search_container, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Size = UDim2.new(1, -84, 1, 0), Font = Enum.Font.Arcade,
    PlaceholderText = "SEARCH... (comma sep, -exclude)", Text = "",
    TextColor3 = current_theme.text, PlaceholderColor3 = current_theme.border,
    TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false
})
create_instance("UIPadding", { Parent = search_box, PaddingLeft = UDim.new(0, 10) })

-- History button
local history_button = create_instance("TextButton", {
    Parent = search_container, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -84, 0, 0), Size = UDim2.new(0, 40, 1, 0),
    Text = "HIS", Font = Enum.Font.Arcade, TextColor3 = current_theme.text,
    TextSize = 11, AutoButtonColor = false
})
button_colors[history_button] = current_theme.element_bg

local search_button = create_instance("TextButton", {
    Parent = search_container, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0, Position = UDim2.new(1, -40, 0, 0),
    Size = UDim2.new(0, 40, 1, 0), Text = "", AutoButtonColor = false
})
button_colors[search_button] = current_theme.accent

-- Cancel button (shown during loading)
local cancel_button = create_instance("TextButton", {
    Parent = search_container, BackgroundColor3 = Color3.fromRGB(160, 40, 40),
    BorderSizePixel = 0, Position = UDim2.new(1, -40, 0, 0),
    Size = UDim2.new(0, 40, 1, 0), Font = Enum.Font.Arcade,
    Text = "✕", TextColor3 = Color3.new(1,1,1), TextSize = 16,
    AutoButtonColor = false, Visible = false
})
button_colors[cancel_button] = Color3.fromRGB(160, 40, 40)

local icon_search = draw_pixel_icon(search_button, {
    "000011110000","000100001000","001000000100",
    "001000000100","001000000100","000100001000",
    "000011110000","000000011000","000000001100",
    "000000000110","000000000011"
}, current_theme.text, 2)

local icon_loading = draw_pixel_icon(search_button, {
    "00111100","01000010","10000001","10000000",
    "10000000","10000001","01000010","00111100"
}, current_theme.text, 2)
icon_loading.Visible = false

-- Filter row (type filters + sort)
local filter_row = create_instance("Frame", {
    Parent = main_gui, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 90),
    Size = UDim2.new(1, -20, 0, 22)
})

local filter_buttons = {}
local filter_x = 0
for _, ftype in ipairs({"LocalScript", "ModuleScript", "Script"}) do
    local short = ftype == "LocalScript" and "LOCAL" or ftype == "ModuleScript" and "MODULE" or "SERVER"
    local fbtn = create_instance("TextButton", {
        Parent = filter_row, BackgroundColor3 = type_colors[ftype],
        BorderSizePixel = 0, Position = UDim2.new(0, filter_x, 0, 0),
        Size = UDim2.new(0, ftype == "ModuleScript" and 72 or 58, 1, 0),
        Text = short, Font = Enum.Font.Arcade,
        TextColor3 = Color3.fromRGB(255,255,255), TextSize = 11,
        AutoButtonColor = false
    })
    filter_buttons[ftype] = fbtn
    button_colors[fbtn] = type_colors[ftype]
    filter_x = filter_x + (ftype == "ModuleScript" and 76 or 62)
end

-- Sort button — color changes to accent when non-default sort is active
local sort_mode_labels = { matches = "SORT:MATCH", name = "SORT:NAME", path = "SORT:PATH" }
local sort_button = create_instance("TextButton", {
    Parent = filter_row, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -80, 0, 0), Size = UDim2.new(0, 80, 1, 0),
    Text = "SORT:MATCH", Font = Enum.Font.Arcade,
    TextColor3 = current_theme.text, TextSize = 10, AutoButtonColor = false
})
button_colors[sort_button] = current_theme.element_bg

local function update_sort_button()
    sort_button.Text = sort_mode_labels[setting_sort_mode] or "SORT:?"
    -- Highlight if not default
    local is_default = setting_sort_mode == "matches"
    sort_button.BackgroundColor3 = is_default and current_theme.element_bg or current_theme.accent
    sort_button.TextColor3 = is_default and current_theme.text or Color3.new(1,1,1)
    button_colors[sort_button] = sort_button.BackgroundColor3
end

-- Result count label
result_count_label = create_instance("TextLabel", {
    Parent = main_gui, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, 116), Size = UDim2.new(1, -100, 0, 14),
    Font = Enum.Font.Arcade, Text = "",
    TextColor3 = Color3.fromRGB(120, 120, 120), TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left
})

-- Export results button
local export_btn = create_instance("TextButton", {
    Parent = main_gui, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -90, 0, 114), Size = UDim2.new(0, 80, 0, 16),
    Font = Enum.Font.Arcade, Text = "EXPORT",
    TextColor3 = current_theme.text, TextSize = 10,
    AutoButtonColor = false,
})
button_colors[export_btn] = current_theme.element_bg

-- Search-in-results filter bar
local filter_results_box = create_instance("TextBox", {
    Parent = main_gui, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 10, 0, 114), Size = UDim2.new(1, -20, 0, 16),
    Font = Enum.Font.Arcade,
    PlaceholderText = "FILTER RESULTS...", Text = "",
    TextColor3 = current_theme.text,
    PlaceholderColor3 = current_theme.border,
    TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false
})
create_instance("UIPadding", { Parent = filter_results_box, PaddingLeft = UDim.new(0, 6) })

local results_filter_term = ""

filter_results_box:GetPropertyChangedSignal("Text"):Connect(function()
    results_filter_term = string.lower(filter_results_box.Text)
    render_results()
end)

-- ==========================================
-- CONTENT AREA
-- ==========================================

local content_area = create_instance("Frame", {
    Parent = main_gui, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 134),
    Size = UDim2.new(1, -20, 1, -144), ClipsDescendants = false
})
-- Note: filter_results_box sits at y=114, content_area starts at y=134

local results_scroll = create_instance("ScrollingFrame", {
    Parent = content_area, Active = true,
    BackgroundColor3 = current_theme.bg, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 1, 0), CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 12, ScrollBarImageColor3 = current_theme.accent,
    BottomImage = flat_image, MidImage = flat_image, TopImage = flat_image,
    ClipsDescendants = true, ElasticBehavior = Enum.ElasticBehavior.Never
})

local results_layout = create_instance("UIListLayout", {
    Parent = results_scroll, SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 5)
})
results_layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    results_scroll.CanvasSize = UDim2.new(0, 0, 0, results_layout.AbsoluteContentSize.Y)
end)

-- Empty state label
local empty_label = create_instance("TextLabel", {
    Parent = results_scroll, BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 60), Position = UDim2.new(0, 0, 0, 20),
    Font = Enum.Font.Arcade, Text = "NO RESULTS FOUND",
    TextColor3 = Color3.fromRGB(80, 80, 80), TextSize = 16,
    TextXAlignment = Enum.TextXAlignment.Center,
    Visible = false
})

-- ==========================================
-- HISTORY DROPDOWN
-- ==========================================

local history_dropdown = create_instance("Frame", {
    Parent = main_gui, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 10, 0, 86), Size = UDim2.new(1, -20, 0, 0),
    ClipsDescendants = true, ZIndex = 20, Visible = false
})
local history_layout = create_instance("UIListLayout", {
    Parent = history_dropdown, SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 1)
})

-- ==========================================
-- CODE VIEW
-- ==========================================

local code_view_container = create_instance("Frame", {
    Parent = content_area, BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, 0), Visible = false,
    ClipsDescendants = true
})

local code_top_bar = create_instance("Frame", {
    Parent = code_view_container, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 30), ClipsDescendants = true
})

local back_button = create_instance("TextButton", {
    Parent = code_top_bar, BackgroundColor3 = current_theme.border,
    BorderSizePixel = 0, Position = UDim2.new(0, 5, 0, 5),
    Size = UDim2.new(0, 50, 0, 20), Font = Enum.Font.Arcade,
    Text = "BACK", TextColor3 = current_theme.text, TextSize = 13,
    AutoButtonColor = false
})
button_colors[back_button] = current_theme.border

local copy_button = create_instance("TextButton", {
    Parent = code_top_bar, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0, Position = UDim2.new(1, -110, 0, 5),
    Size = UDim2.new(0, 50, 0, 20), Text = "", AutoButtonColor = false
})
button_colors[copy_button] = current_theme.accent

local icon_copy = draw_pixel_icon(copy_button, {
    "000111111100","000100000100","011111110100",
    "010000010100","010000010100","010000010100",
    "010000011100","010000010000","011111110000"
}, current_theme.text, 2)

local icon_success = draw_pixel_icon(copy_button, {
    "000000000011","000000000110","000000001100",
    "000000011000","000000110000","001101100000",
    "000111000000","000010000000"
}, Color3.fromRGB(80, 220, 120), 2)
icon_success.Visible = false

-- Save to file button
local save_button = create_instance("TextButton", {
    Parent = code_top_bar, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -57, 0, 5), Size = UDim2.new(0, 50, 0, 20),
    Font = Enum.Font.Arcade, Text = "SAVE",
    TextColor3 = current_theme.text, TextSize = 13, AutoButtonColor = false
})
button_colors[save_button] = current_theme.element_bg

local lines_info = create_instance("TextLabel", {
    Parent = code_top_bar, BackgroundTransparency = 1,
    Position = UDim2.new(0, 58, 0, 0), Size = UDim2.new(0, 100, 1, 0),
    Font = Enum.Font.Arcade, Text = "LINES: 0",
    TextColor3 = current_theme.text, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left
})

-- Find in code bar
local find_bar = create_instance("Frame", {
    Parent = code_view_container, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, 30),
    Size = UDim2.new(1, 0, 0, 26), ClipsDescendants = true
})

local find_box = create_instance("TextBox", {
    Parent = find_bar, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 5, 0, 3), Size = UDim2.new(1, -100, 0, 20),
    Font = Enum.Font.Arcade, PlaceholderText = "Find in code...",
    Text = "", TextColor3 = current_theme.text,
    PlaceholderColor3 = current_theme.border, TextSize = 13,
    ClearTextOnFocus = false
})
create_instance("UIPadding", { Parent = find_box, PaddingLeft = UDim.new(0, 6) })

local find_prev = create_instance("TextButton", {
    Parent = find_bar, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -92, 0, 3), Size = UDim2.new(0, 40, 0, 20),
    Font = Enum.Font.Arcade, Text = "PREV",
    TextColor3 = current_theme.text, TextSize = 11, AutoButtonColor = false
})
button_colors[find_prev] = current_theme.element_bg

local find_next = create_instance("TextButton", {
    Parent = find_bar, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0, Position = UDim2.new(1, -48, 0, 3),
    Size = UDim2.new(0, 42, 0, 20), Font = Enum.Font.Arcade,
    Text = "NEXT", TextColor3 = current_theme.text, TextSize = 11,
    AutoButtonColor = false
})
button_colors[find_next] = current_theme.accent

local find_results_label = create_instance("TextLabel", {
    Parent = find_bar, BackgroundTransparency = 1,
    Position = UDim2.new(1, -92, 0, 0), Size = UDim2.new(0, 40, 1, 0),
    Font = Enum.Font.Arcade, Text = "",
    TextColor3 = Color3.fromRGB(120, 120, 120), TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Center, Visible = false
})

local code_area = create_instance("Frame", {
    Parent = code_view_container, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, 56),
    Size = UDim2.new(1, 0, 1, -56), ClipsDescendants = true
})

local line_numbers_scroll = create_instance("ScrollingFrame", {
    Parent = code_area, Active = false,
    BackgroundColor3 = current_theme.element_bg, BorderSizePixel = 0,
    Size = UDim2.new(0, 45, 1, 0), CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.Y,
    ElasticBehavior = Enum.ElasticBehavior.Never, ScrollingEnabled = false
})
create_instance("UIListLayout", {
    Parent = line_numbers_scroll, SortOrder = Enum.SortOrder.LayoutOrder
})

local code_scroll = create_instance("ScrollingFrame", {
    Parent = code_area, Active = true,
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Position = UDim2.new(0, 50, 0, 0), Size = UDim2.new(1, -50, 1, 0),
    CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 12,
    ScrollBarImageColor3 = current_theme.accent,
    BottomImage = flat_image, MidImage = flat_image, TopImage = flat_image,
    ScrollingDirection = Enum.ScrollingDirection.XY,
    ElasticBehavior = Enum.ElasticBehavior.Never
})
local code_layout = create_instance("UIListLayout", {
    Parent = code_scroll, SortOrder = Enum.SortOrder.LayoutOrder
})

code_layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    local max_width = 0
    for _, child in ipairs(code_scroll:GetChildren()) do
        if child:IsA("Frame") and child.AbsoluteSize.X > max_width then
            max_width = child.AbsoluteSize.X
        end
    end
    code_scroll.CanvasSize = UDim2.new(0, max_width, 0, code_layout.AbsoluteContentSize.Y)
    line_numbers_scroll.CanvasSize = UDim2.new(0, 0, 0, code_layout.AbsoluteContentSize.Y)
end)

code_scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    line_numbers_scroll.CanvasPosition = Vector2.new(0, code_scroll.CanvasPosition.Y)
end)

-- ==========================================
-- SETTINGS PANEL
-- ==========================================

local settings_container = create_instance("Frame", {
    Parent = content_area, BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, 0), Visible = false,
    ClipsDescendants = false
})

local settings_back_button = create_instance("TextButton", {
    Parent = settings_container, BackgroundColor3 = current_theme.border,
    BorderSizePixel = 0, Position = UDim2.new(0, 5, 0, 5),
    Size = UDim2.new(0, 60, 0, 20), Font = Enum.Font.Arcade,
    Text = "BACK", TextColor3 = current_theme.text, TextSize = 14,
    AutoButtonColor = false
})
button_colors[settings_back_button] = current_theme.border

-- Decompiler dropdown
create_instance("TextLabel", {
    Parent = settings_container, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, 32), Size = UDim2.new(1, -20, 0, 16),
    Font = Enum.Font.Arcade, Text = "Decompile Mode",
    TextColor3 = current_theme.text, TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left
})

local dropdown_main = create_instance("TextButton", {
    Parent = settings_container, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 10, 0, 52), Size = UDim2.new(1, -20, 0, 26),
    Text = "", AutoButtonColor = false
})
button_colors[dropdown_main] = current_theme.bg

local dropdown_text = create_instance("TextLabel", {
    Parent = dropdown_main, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, 0), Size = UDim2.new(1, -40, 1, 0),
    Font = Enum.Font.Arcade, Text = "lua.expert",
    TextColor3 = current_theme.text, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left
})

local icon_arrow_down = draw_pixel_icon(dropdown_main, {
    "1111111","0111110","0011100","0001000"
}, current_theme.text, 2)
icon_arrow_down.Position = UDim2.new(1, -15, 0.5, 0)

local dropdown_list = create_instance("Frame", {
    Parent = settings_container, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 10, 0, 77), Size = UDim2.new(1, -20, 0, 0),
    ClipsDescendants = true, ZIndex = 10, Visible = false, Active = true
})

local decompiler_options = {"lua.expert", "Shiny", "IronBrew"}
local decompiler_btns = {}
for i, name in ipairs(decompiler_options) do
    local btn = create_instance("TextButton", {
        Parent = dropdown_list, BackgroundColor3 = current_theme.bg,
        BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, (i-1)*26),
        Size = UDim2.new(1, 0, 0, 26), Font = Enum.Font.Arcade,
        Text = " " .. name, TextColor3 = current_theme.text, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 11, AutoButtonColor = false
    })
    button_colors[btn] = current_theme.bg
    decompiler_btns[name] = btn
end

-- Font size slider
local font_label_y = 88
create_instance("TextLabel", {
    Parent = settings_container, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, font_label_y), Size = UDim2.new(1, -20, 0, 16),
    Font = Enum.Font.Arcade, Text = "Font Size: 14",
    TextColor3 = current_theme.text, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    Name = "FontSizeLabel"
})

local font_size_label = settings_container:FindFirstChild("FontSizeLabel")

local font_slider_track = create_instance("Frame", {
    Parent = settings_container, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 10, 0, font_label_y + 20), Size = UDim2.new(1, -20, 0, 16),
    Active = true
})

local font_slider_fill = create_instance("Frame", {
    Parent = font_slider_track, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0, Size = UDim2.new(0.33, 0, 1, 0)
})

-- Remove comments checkbox
local checkbox_y = font_label_y + 46
create_instance("TextLabel", {
    Parent = settings_container, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, checkbox_y), Size = UDim2.new(1, -50, 0, 20),
    Font = Enum.Font.Arcade, Text = "Hide comments",
    TextColor3 = current_theme.text, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left
})

local checkbox_frame = create_instance("TextButton", {
    Parent = settings_container, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -30, 0, checkbox_y), Size = UDim2.new(0, 20, 0, 20),
    Text = "", AutoButtonColor = false
})
button_colors[checkbox_frame] = current_theme.bg

local checkbox_inner = create_instance("Frame", {
    Parent = checkbox_frame, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0, Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.new(0, 0, 0, 0), AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundTransparency = 1
})

-- Regex checkbox
local regex_y = checkbox_y + 28
create_instance("TextLabel", {
    Parent = settings_container, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, regex_y), Size = UDim2.new(1, -50, 0, 20),
    Font = Enum.Font.Arcade, Text = "Regex search mode",
    TextColor3 = current_theme.text, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left
})

local regex_frame = create_instance("TextButton", {
    Parent = settings_container, BackgroundColor3 = current_theme.bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(1, -30, 0, regex_y), Size = UDim2.new(0, 20, 0, 20),
    Text = "", AutoButtonColor = false
})
button_colors[regex_frame] = current_theme.bg

local regex_inner = create_instance("Frame", {
    Parent = regex_frame, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0, Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.new(0, 0, 0, 0), AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundTransparency = 1
})

-- Worker count slider
local worker_label_y = regex_y + 32
local worker_label = create_instance("TextLabel", {
    Parent = settings_container, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, worker_label_y),
    Size = UDim2.new(1, -20, 0, 16),
    Font = Enum.Font.Arcade, Text = "Workers: 10",
    TextColor3 = current_theme.text, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    Name = "WorkerLabel"
})

local worker_track = create_instance("Frame", {
    Parent = settings_container, BackgroundColor3 = current_theme.element_bg,
    BorderColor3 = current_theme.border, BorderSizePixel = 1,
    Position = UDim2.new(0, 10, 0, worker_label_y + 20),
    Size = UDim2.new(1, -20, 0, 16), Active = true
})

local worker_fill = create_instance("Frame", {
    Parent = worker_track, BackgroundColor3 = current_theme.accent,
    BorderSizePixel = 0,
    -- default 10 out of range 1-30 → (10-1)/(30-1) ≈ 0.31
    Size = UDim2.new(0.31, 0, 1, 0)
})

local function update_worker_slider(abs_x)
    local pct = math.clamp((abs_x - worker_track.AbsolutePosition.X) / worker_track.AbsoluteSize.X, 0, 1)
    setting_max_workers = math.floor(1 + pct * 29)  -- range 1-30
    worker_fill.Size = UDim2.new(pct, 0, 1, 0)
    worker_label.Text = "Workers: " .. setting_max_workers
end

worker_track.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then
        update_worker_slider(input.Position.X)
    end
end)
worker_track.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then
        update_worker_slider(input.Position.X)
    end
end)

-- Scan scope toggles
local scope_y = worker_label_y + 46
create_instance("TextLabel", {
    Parent = settings_container, BackgroundTransparency = 1,
    Position = UDim2.new(0, 10, 0, scope_y),
    Size = UDim2.new(1, -20, 0, 14),
    Font = Enum.Font.Arcade, Text = "Scan Scope",
    TextColor3 = current_theme.text, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left
})

local scope_options = {
    { key = "game",               label = "FULL" },
    { key = "PlayerScripts",      label = "PLAYER" },
    { key = "ReplicatedStorage",  label = "REPLICATED" },
    { key = "workspace",          label = "WORKSPACE" },
}
local scope_btns = {}
local scope_x = 10
local scope_row_y = scope_y + 18
for _, opt in ipairs(scope_options) do
    local active = setting_scan_scope[opt.key]
    local btn = create_instance("TextButton", {
        Parent = settings_container,
        BackgroundColor3 = active and current_theme.accent or current_theme.element_bg,
        BorderColor3 = current_theme.border, BorderSizePixel = 1,
        Position = UDim2.new(0, scope_x, 0, scope_row_y),
        Size = UDim2.new(0, #opt.label * 7 + 10, 0, 18),
        Font = Enum.Font.Arcade, Text = opt.label,
        TextColor3 = Color3.new(1,1,1), TextSize = 10,
        AutoButtonColor = false,
    })
    scope_btns[opt.key] = btn
    button_colors[btn] = btn.BackgroundColor3
    scope_x = scope_x + #opt.label * 7 + 14

    local function toggle_scope()
        -- If FULL is toggled on, turn off others; if other toggled, turn off FULL
        if opt.key == "game" then
            setting_scan_scope.game = not setting_scan_scope.game
            if setting_scan_scope.game then
                for _, o in ipairs(scope_options) do
                    if o.key ~= "game" then
                        setting_scan_scope[o.key] = false
                        scope_btns[o.key].BackgroundColor3 = current_theme.element_bg
                        button_colors[scope_btns[o.key]] = current_theme.element_bg
                    end
                end
            end
        else
            setting_scan_scope[opt.key] = not setting_scan_scope[opt.key]
            if setting_scan_scope[opt.key] then
                setting_scan_scope.game = false
                scope_btns.game.BackgroundColor3 = current_theme.element_bg
                button_colors[scope_btns.game] = current_theme.element_bg
            end
        end
        btn.BackgroundColor3 = setting_scan_scope[opt.key] and current_theme.accent or current_theme.element_bg
        button_colors[btn] = btn.BackgroundColor3
    end
    btn.MouseButton1Click:Connect(toggle_scope)
    btn.TouchTap:Connect(toggle_scope)
end

-- Clear cache button
local clear_cache_btn = create_instance("TextButton", {
    Parent = settings_container, BackgroundColor3 = Color3.fromRGB(120, 40, 40),
    BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, scope_row_y + 28),
    Size = UDim2.new(1, -20, 0, 22), Font = Enum.Font.Arcade,
    Text = "CLEAR DECOMPILE CACHE (0 entries)", TextColor3 = Color3.fromRGB(255,255,255),
    TextSize = 12, AutoButtonColor = false
})
button_colors[clear_cache_btn] = Color3.fromRGB(120, 40, 40)

-- ==========================================
-- SCROLLBAR INTERACTIVE
-- ==========================================

local function make_scrollbar_interactive(scroll_frame)
    local is_dragging = false
    local drag_start_y, start_canvas_pos = 0, 0
    scroll_frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            local rect = scroll_frame.AbsolutePosition
            local size = scroll_frame.AbsoluteSize
            local thickness = scroll_frame.ScrollBarThickness
            if input.Position.X >= rect.X + size.X - thickness - 5 then
                is_dragging = true
                drag_start_y = input.Position.Y
                start_canvas_pos = scroll_frame.CanvasPosition.Y
                local h, s, v = current_theme.accent:ToHSV()
                tween_service:Create(scroll_frame, TweenInfo.new(0.15), {
                    ScrollBarImageColor3 = Color3.fromHSV(h, s * 0.5, math.min(1, v * 1.5))
                }):Play()
            end
        end
    end)
    user_input_service.InputChanged:Connect(function(input)
        if is_dragging and input.UserInputType == Enum.UserInputType.Touch then
            local size = scroll_frame.AbsoluteSize
            local content_size = scroll_frame.CanvasSize.Y.Offset
            local max_scroll = math.max(0, content_size - size.Y)
            if max_scroll > 0 then
                local delta_y = input.Position.Y - drag_start_y
                local scroll_ratio = max_scroll / size.Y
                local new_pos = math.clamp(start_canvas_pos + (delta_y * scroll_ratio * 1.5), 0, max_scroll)
                scroll_frame.CanvasPosition = Vector2.new(scroll_frame.CanvasPosition.X, new_pos)
            end
        end
    end)
    user_input_service.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch and is_dragging then
            is_dragging = false
            tween_service:Create(scroll_frame, TweenInfo.new(0.2), {
                ScrollBarImageColor3 = current_theme.accent
            }):Play()
        end
    end)
end

make_scrollbar_interactive(results_scroll)
make_scrollbar_interactive(code_scroll)

-- ==========================================
-- BUTTON HELPERS
-- ==========================================

local function animate_button(button)
    local orig = button_colors[button] or button.BackgroundColor3
    tween_service:Create(button, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3 = current_theme.text}):Play()
    task.delay(0.1, function()
        if button.Parent then
            tween_service:Create(button, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3 = orig}):Play()
        end
    end)
end

local function bind_tap(button, callback)
    button.AutoButtonColor = false
    local start_pos, start_time = nil, 0
    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            start_pos = input.Position
            start_time = os.clock()
        end
    end)
    button.InputEnded:Connect(function(input)
        if start_pos and input.UserInputType == Enum.UserInputType.Touch then
            local delta = (input.Position - start_pos).Magnitude
            if delta < 10 and (os.clock() - start_time) < 0.5 then
                animate_button(button)
                callback()
            end
            start_pos = nil
        end
    end)
end

-- ==========================================
-- LOADING STATE
-- ==========================================

local loading_conn
local function set_search_state(state)
    if state == "search" then
        if loading_conn then loading_conn:Disconnect() loading_conn = nil end
        icon_loading.Visible = false
        icon_search.Visible = true
        icon_loading.Rotation = 0
        search_button.Visible = true
        cancel_button.Visible = false
    elseif state == "loading" then
        icon_search.Visible = false
        icon_loading.Visible = true
        search_button.Visible = false
        cancel_button.Visible = true
        if not loading_conn then
            loading_conn = run_service.RenderStepped:Connect(function(dt)
                icon_loading.Rotation = icon_loading.Rotation + (dt * 360)
            end)
        end
    end
end

-- ==========================================
-- SYNTAX HIGHLIGHT
-- ==========================================

local function syntax_highlight(text)
    local highlighted = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local patterns = {
        {"(%b\"\")", "#ce9178"},
        {"(%b'')", "#ce9178"},
        {"(%-%-[^\n]*)", "#6a9955"}
    }
    for _, pd in ipairs(patterns) do
        highlighted = highlighted:gsub(pd[1], "<font color=\"" .. pd[2] .. "\">%1</font>")
    end
    local kw_blue = {"local","function","return","end","nil","true","false","and","or","not"}
    for _, kw in ipairs(kw_blue) do
        highlighted = highlighted:gsub("%f[%w]" .. kw .. "%f[%W]", "<font color=\"#569cd6\">" .. kw .. "</font>")
    end
    local kw_purple = {"if","then","else","elseif","for","while","do","in"}
    for _, kw in ipairs(kw_purple) do
        highlighted = highlighted:gsub("%f[%w]" .. kw .. "%f[%W]", "<font color=\"#c586c0\">" .. kw .. "</font>")
    end
    highlighted = highlighted:gsub("%f[%w](%d+)%f[%W]", "<font color=\"#b5cea8\">%1</font>")
    return highlighted
end

-- ==========================================
-- FIND IN CODE
-- ==========================================

local find_matches = {}
local find_current_idx = 0

local function do_find_in_code()
    find_matches = {}
    find_current_idx = 0
    local term = find_box.Text
    if term == "" then
        find_results_label.Visible = false
        return
    end
    local lines = string.split(active_decompile_text, "\n")
    local pattern = setting_use_regex and term or escape_pattern(term)
    for i, line in ipairs(lines) do
        if string.find(string.lower(line), string.lower(pattern)) then
            table.insert(find_matches, i)
        end
    end
    if #find_matches == 0 then
        find_results_label.Text = "0/0"
        find_results_label.Visible = true
        return
    end
    find_current_idx = 1
    find_results_label.Visible = true
    find_results_label.Text = "1/" .. #find_matches

    -- Scroll to line
    local line_height = text_service:GetTextSize("A", setting_font_size, Enum.Font.Arcade, Vector2.new(100000, 100000)).Y
    local target_y = (find_matches[1] - 1) * line_height
    code_scroll.CanvasPosition = Vector2.new(code_scroll.CanvasPosition.X, math.max(0, target_y - 40))
end

local function navigate_find(direction)
    if #find_matches == 0 then return end
    find_current_idx = find_current_idx + direction
    if find_current_idx < 1 then find_current_idx = #find_matches end
    if find_current_idx > #find_matches then find_current_idx = 1 end
    find_results_label.Text = find_current_idx .. "/" .. #find_matches
    local line_height = text_service:GetTextSize("A", setting_font_size, Enum.Font.Arcade, Vector2.new(100000, 100000)).Y
    local target_y = (find_matches[find_current_idx] - 1) * line_height
    code_scroll.CanvasPosition = Vector2.new(code_scroll.CanvasPosition.X, math.max(0, target_y - 40))
end

bind_tap(find_next, function() navigate_find(1) end)
bind_tap(find_prev, function() navigate_find(-1) end)
find_box:GetPropertyChangedSignal("Text"):Connect(function()
    task.delay(0.4, function()
        if find_box.Text ~= "" then do_find_in_code() end
    end)
end)

-- ==========================================
-- VIEW CODE
-- ==========================================

local current_viewed_script = nil

local function view_code(script_instance)
    current_viewed_script = script_instance
    results_scroll.Visible = false
    settings_container.Visible = false
    code_view_container.Visible = true
    lines_info.Text = "DECOMPILING..."
    find_box.Text = ""
    find_results_label.Visible = false
    find_matches = {}

    for _, child in ipairs(code_scroll:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end
    for _, child in ipairs(line_numbers_scroll:GetChildren()) do
        if child:IsA("TextLabel") then child:Destroy() end
    end
    code_scroll.CanvasPosition = Vector2.new(0, 0)
    line_numbers_scroll.CanvasPosition = Vector2.new(0, 0)
    active_decompile_text = ""

    task.spawn(function()
        local code = decompile_cache[script_instance]
        local decompile_status = "cached"
        if not code then
            local success, source = pcall(do_decompile, script_instance)
            if not success or type(source) ~= "string" or source == "" then
                source = "-- FAILED TO DECOMPILE OR EMPTY
-- Error: " .. tostring(source)
                decompile_status = "failed"
            else
                decompile_status = "success"
            end
            code = source
            if decompile_status == "success" then cache_set(script_instance, code) end
        end
        -- Visual status feedback
        if decompile_status == "failed" then
            lines_info.TextColor3 = Color3.fromRGB(200, 80, 80)
        elseif decompile_status == "success" then
            lines_info.TextColor3 = Color3.fromRGB(80, 200, 80)
            task.delay(2, function()
                if lines_info.Parent then
                    lines_info.TextColor3 = current_theme.text
                end
            end)
        else
            lines_info.TextColor3 = current_theme.text
        end

        code = string.gsub(code, "\r", "")
        code = string.gsub(code, "\t", "    ")

        if setting_remove_comments then
            code = string.gsub(code, "%-%-[^\n]*", "")
            local clean_lines = {}
            for _, line in ipairs(string.split(code, "\n")) do
                if string.match(line, "%S") then
                    table.insert(clean_lines, line)
                end
            end
            code = table.concat(clean_lines, "\n")
        end

        active_decompile_text = code
        local lines = string.split(code, "\n")
        local lines_count = #lines

        -- Get bytecode size
        local size_text = ""
        if getscriptbytecode then
            local ok, bc = pcall(getscriptbytecode, script_instance)
            if ok then size_text = "  |  " .. format_bytes(#bc) end
        end
        lines_info.Text = "LINES: " .. tostring(lines_count) .. size_text

        local chunk_size = 50
        local line_height = text_service:GetTextSize("A", setting_font_size, Enum.Font.Arcade, Vector2.new(100000, 100000)).Y

        for i = 1, lines_count, chunk_size do
            local chunk_lines, chunk_nums = {}, {}
            for j = i, math.min(i + chunk_size - 1, lines_count) do
                table.insert(chunk_lines, lines[j])
                table.insert(chunk_nums, tostring(j))
            end

            local text_chunk = table.concat(chunk_lines, "\n")
            local nums_chunk = table.concat(chunk_nums, "\n")

            create_instance("TextLabel", {
                Parent = line_numbers_scroll, BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.Y,
                Size = UDim2.new(1, 0, 0, 0),
                Font = Enum.Font.Arcade,
                Text = nums_chunk, TextColor3 = Color3.fromRGB(100, 100, 100),
                TextSize = setting_font_size,
                TextXAlignment = Enum.TextXAlignment.Right,
                TextYAlignment = Enum.TextYAlignment.Top
            })

            local chunk_frame = create_instance("Frame", {
                Parent = code_scroll, BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(0, 0, 0, 0)
            })

            -- Highlight search terms
            if active_search_terms and #active_search_terms > 0 then
                for k, line_text in ipairs(chunk_lines) do
                    for _, term in ipairs(active_search_terms) do
                        if term.exclude then continue end  -- don't highlight excluded terms
                        local ttext = type(term) == "table" and term.text or term
                        local pattern = setting_use_regex and ttext or case_insensitive_pattern(escape_pattern(ttext))
                        local init = 1
                        while true do
                            local ms, me = string.find(line_text, pattern, init)
                            if not ms then break end
                            local prefix_text = string.sub(line_text, 1, ms - 1)
                            local matched_part = string.sub(line_text, ms, me)
                            local x_offset = #prefix_text > 0 and text_service:GetTextSize(prefix_text, setting_font_size, Enum.Font.Arcade, Vector2.new(100000, 100000)).X or 0
                            local match_width = text_service:GetTextSize(matched_part, setting_font_size, Enum.Font.Arcade, Vector2.new(100000, 100000)).X
                            create_instance("Frame", {
                                Parent = chunk_frame, BackgroundColor3 = Color3.fromRGB(80, 130, 90),
                                BackgroundTransparency = 0.5, BorderSizePixel = 0,
                                Position = UDim2.new(0, x_offset, 0, (k - 1) * line_height),
                                Size = UDim2.new(0, match_width, 0, line_height), ZIndex = 1
                            })
                            init = me + 1
                        end
                    end
                end
            end

            create_instance("TextLabel", {
                Parent = chunk_frame, BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(0, 0, 0, 0),
                Font = Enum.Font.Arcade, Text = syntax_highlight(text_chunk),
                TextColor3 = current_theme.text, TextSize = setting_font_size,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Top,
                RichText = true, TextWrapped = false, ZIndex = 2
            })
        end
    end)
end

bind_tap(back_button, function()
    code_view_container.Visible = false
    results_scroll.Visible = true
end)

bind_tap(copy_button, function()
    if setclipboard then
        setclipboard(active_decompile_text)
        icon_copy.Visible = false
        icon_success.Visible = true
        task.delay(1.5, function()
            icon_copy.Visible = true
            icon_success.Visible = false
        end)
    end
end)

bind_tap(save_button, function()
    if writefile and current_viewed_script then
        local safe_name = current_viewed_script.Name:gsub("[^%w_%-]", "_")
        local fname = safe_name .. "_decompiled.lua"
        pcall(writefile, fname, active_decompile_text)
        save_button.Text = "SAVED!"
        task.delay(1.5, function() save_button.Text = "SAVE" end)
    else
        save_button.Text = "N/A"
        task.delay(1.5, function() save_button.Text = "SAVE" end)
    end
end)

-- ==========================================
-- SORT + RENDER RESULTS
-- ==========================================

local function render_results()
    for _, child in ipairs(results_scroll:GetChildren()) do
        if child:IsA("Frame") or child:IsA("TextButton") then child:Destroy() end
    end
    results_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)

    local sorted = {}
    for _, r in ipairs(current_results) do table.insert(sorted, r) end

    if setting_sort_mode == "matches" then
        table.sort(sorted, function(a, b) return a.count > b.count end)
    elseif setting_sort_mode == "name" then
        table.sort(sorted, function(a, b) return a.name < b.name end)
    elseif setting_sort_mode == "path" then
        table.sort(sorted, function(a, b) return a.path < b.path end)
    end

    empty_label.Visible = #sorted == 0
    result_count_label.Text = #sorted > 0 and ("Found " .. #sorted .. " result" .. (#sorted == 1 and "" or "s")) or ""

    for order, r in ipairs(sorted) do
        local result_frame = create_instance("Frame", {
            Name = "Result", Parent = results_scroll,
            BackgroundColor3 = current_theme.element_bg,
            BorderColor3 = current_theme.border, BorderSizePixel = 1,
            Size = UDim2.new(1, -10, 0, 62), LayoutOrder = order
        })
        button_colors[result_frame] = current_theme.element_bg

        -- Script name + type
        create_instance("TextLabel", {
            Parent = result_frame, BackgroundTransparency = 1,
            Position = UDim2.new(0, 10, 0, 4), Size = UDim2.new(0.75, 0, 0, 14),
            Font = Enum.Font.Arcade,
            Text = r.name .. " (" .. r.class .. ")",
            TextColor3 = r.color, TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd
        })

        -- Hash
        create_instance("TextLabel", {
            Parent = result_frame, BackgroundTransparency = 1,
            Position = UDim2.new(0, 10, 0, 20), Size = UDim2.new(0.75, 0, 0, 12),
            Font = Enum.Font.Arcade, Text = r.hash,
            TextColor3 = Color3.fromRGB(120, 120, 120), TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left
        })

        -- Full path
        create_instance("TextLabel", {
            Parent = result_frame, BackgroundTransparency = 1,
            Position = UDim2.new(0, 10, 0, 34), Size = UDim2.new(1, -120, 0, 12),
            Font = Enum.Font.Arcade, Text = "PATH: " .. r.path,
            TextColor3 = Color3.fromRGB(90, 90, 90), TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd
        })

        -- Size + running state
        local state_text = ""
        if r.script and r.script.Parent then
            state_text = " | ACTIVE"
        end
        create_instance("TextLabel", {
            Parent = result_frame, BackgroundTransparency = 1,
            Position = UDim2.new(0, 10, 0, 48), Size = UDim2.new(0.6, 0, 0, 12),
            Font = Enum.Font.Arcade, Text = r.size .. state_text,
            TextColor3 = Color3.fromRGB(90, 150, 90), TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left
        })

        -- Match count
        create_instance("TextLabel", {
            Parent = result_frame, BackgroundTransparency = 1,
            Position = UDim2.new(1, -100, 0, 0), Size = UDim2.new(0, 90, 1, 0),
            Font = Enum.Font.Arcade, Text = tostring(r.count) .. " MATCH",
            TextColor3 = current_theme.accent, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Right
        })

        local click_btn = create_instance("TextButton", {
            Parent = result_frame, BackgroundTransparency = 1,
            Size = UDim2.new(0.75, 0, 1, 0), Text = ""
        })
        bind_tap(click_btn, function() view_code(r.script) end)

        -- Copy full path button
        local copy_path_btn = create_instance("TextButton", {
            Parent = result_frame,
            BackgroundColor3 = current_theme.border,
            BorderSizePixel = 0,
            Position = UDim2.new(0, 10, 1, -18),
            Size = UDim2.new(0, 60, 0, 14),
            Font = Enum.Font.Arcade,
            Text = "COPY PATH",
            TextColor3 = current_theme.text,
            TextSize = 9,
            AutoButtonColor = false,
            ZIndex = 3,
        })
        button_colors[copy_path_btn] = current_theme.border
        bind_tap(copy_path_btn, function()
            if setclipboard then
                setclipboard(r.path)
                copy_path_btn.Text = "COPIED!"
                copy_path_btn.BackgroundColor3 = current_theme.accent
                task.delay(1.5, function()
                    if copy_path_btn.Parent then
                        copy_path_btn.Text = "COPY PATH"
                        copy_path_btn.BackgroundColor3 = current_theme.border
                    end
                end)
            end
        end)

        -- Bookmark button (star)
        local is_bookmarked = bookmarks[r.path] ~= nil
        local bm_btn = create_instance("TextButton", {
            Parent = result_frame,
            BackgroundColor3 = is_bookmarked and Color3.fromRGB(200, 160, 0) or current_theme.border,
            BorderSizePixel = 0,
            Position = UDim2.new(0, 74, 1, -18),
            Size = UDim2.new(0, 24, 0, 14),
            Font = Enum.Font.Arcade,
            Text = "★",
            TextColor3 = Color3.new(1,1,1),
            TextSize = 11,
            AutoButtonColor = false,
            ZIndex = 3,
        })
        button_colors[bm_btn] = bm_btn.BackgroundColor3
        bind_tap(bm_btn, function()
            if bookmarks[r.path] then
                bookmarks[r.path] = nil
                bm_btn.BackgroundColor3 = current_theme.border
                button_colors[bm_btn] = current_theme.border
            else
                bookmarks[r.path] = r
                bm_btn.BackgroundColor3 = Color3.fromRGB(200, 160, 0)
                button_colors[bm_btn] = Color3.fromRGB(200, 160, 0)
            end
        end)
    end
end

-- Sort cycle
local sort_modes = {"matches", "name", "path"}
local sort_idx = 1
bind_tap(sort_button, function()
    sort_idx = sort_idx % #sort_modes + 1
    setting_sort_mode = sort_modes[sort_idx]
    update_sort_button()
    render_results()
end)
-- Init sort button state
update_sort_button()

-- Filter toggles
for ftype, fbtn in pairs(filter_buttons) do
    bind_tap(fbtn, function()
        setting_filter_types[ftype] = not setting_filter_types[ftype]
        fbtn.BackgroundTransparency = setting_filter_types[ftype] and 0 or 0.6
        -- Re-filter current_results visually (re-render only matching types)
        render_results()
    end)
end

-- ==========================================
-- HISTORY DROPDOWN LOGIC
-- ==========================================

local history_open = false

local function rebuild_history_ui()
    for _, c in ipairs(history_dropdown:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("Frame") then c:Destroy() end
    end
    if #search_history == 0 then
        create_instance("TextLabel", {
            Parent = history_dropdown, BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 26),
            Font = Enum.Font.Arcade, Text = "No history yet",
            TextColor3 = Color3.fromRGB(100,100,100), TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Center
        })
    end
    for i, term in ipairs(search_history) do
        local hbtn = create_instance("TextButton", {
            Parent = history_dropdown, BackgroundColor3 = current_theme.element_bg,
            BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 26),
            Font = Enum.Font.Arcade, Text = " " .. term,
            TextColor3 = current_theme.text, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21,
            AutoButtonColor = false, LayoutOrder = i
        })
        button_colors[hbtn] = current_theme.element_bg
        bind_tap(hbtn, function()
            search_box.Text = term
            history_open = false
            history_dropdown.Visible = false
            tween_service:Create(history_dropdown, TweenInfo.new(0.15), {Size = UDim2.new(1, -20, 0, 0)}):Play()
        end)
    end
end

bind_tap(history_button, function()
    history_open = not history_open
    rebuild_history_ui()
    local target_h = math.min(#search_history, 5) * 26
    if #search_history == 0 then target_h = 26 end
    if history_open then
        history_dropdown.Visible = true
        tween_service:Create(history_dropdown, TweenInfo.new(0.2), {Size = UDim2.new(1, -20, 0, target_h)}):Play()
    else
        local tw = tween_service:Create(history_dropdown, TweenInfo.new(0.15), {Size = UDim2.new(1, -20, 0, 0)})
        tw:Play()
        tw.Completed:Connect(function() if not history_open then history_dropdown.Visible = false end end)
    end
end)

-- ==========================================
-- SEARCH LOGIC
-- ==========================================

local search_thread

local function perform_search()
    if search_thread then task.cancel(search_thread) end
    current_results = {}
    render_results()
    result_count_label.Text = ""
    clear_cache_btn.Text = "CLEAR DECOMPILE CACHE (" .. #cache_order .. " entries)"

    local raw_query = search_box.Text
    if raw_query == "" then
        active_search_terms = {}
        -- Don't wipe results — keep last search visible
        return
    end

    push_history(raw_query)

    local terms = {}          -- { text, exclude }
    for term in raw_query:gmatch("[^,]+") do
        local t = term:match("^%s*(.-)%s*$")
        if #t > 0 then
            local is_exclude = t:sub(1,1) == "-"
            local text = is_exclude and t:sub(2) or t
            if #text > 0 then
                table.insert(terms, { text = string.lower(text), exclude = is_exclude })
                if #terms >= 25 then break end
            end
        end
    end
    if #terms == 0 then active_search_terms = {} return end

    active_search_terms = terms
    set_search_state("loading")
    result_count_label.Text = "Searching..."
    -- Clear the results filter so previous filter doesn't hide new results
    filter_results_box.Text = ""
    results_filter_term = ""

    active_search_id = os.clock()
    local search_id = active_search_id

    search_thread = task.spawn(function()
        local all_scripts_set = {}
        local all_scripts = {}

        local function add_script(scr)
            if typeof(scr) == "Instance"
                and (scr:IsA("LocalScript") or scr:IsA("ModuleScript") or scr:IsA("Script"))
                and setting_filter_types[scr.ClassName]
                and not all_scripts_set[scr]
            then
                all_scripts_set[scr] = true
                table.insert(all_scripts, scr)
            end
        end

        -- Collect scripts based on scan scope setting
        if setting_scan_scope.game then
            local descendants = game:GetDescendants()
            for i = 1, #descendants do
                add_script(descendants[i])
                if i % 5000 == 0 then task.wait() end
            end
        else
            -- Scan only selected services
            local targets = {}
            if setting_scan_scope.PlayerScripts then
                local ps = game:GetService("Players").LocalPlayer
                if ps then
                    local psc = ps:FindFirstChild("PlayerScripts")
                    if psc then table.insert(targets, psc) end
                end
            end
            if setting_scan_scope.ReplicatedStorage then
                table.insert(targets, game:GetService("ReplicatedStorage"))
            end
            if setting_scan_scope.workspace then
                table.insert(targets, workspace)
            end
            for _, root in ipairs(targets) do
                local descs = root:GetDescendants()
                for i, d in ipairs(descs) do
                    add_script(d)
                    if i % 2000 == 0 then task.wait() end
                end
            end
        end
        if getscripts then for _, scr in ipairs(getscripts()) do add_script(scr) end end
        if getnilinstances then for _, scr in ipairs(getnilinstances()) do add_script(scr) end end
        if getloadedmodules then for _, scr in ipairs(getloadedmodules()) do add_script(scr) end end
        if getrunningscripts then for _, scr in ipairs(getrunningscripts()) do add_script(scr) end end

        -- Semaphore: use a channel-like pattern instead of polling task.wait(0.1)
        local worker_sem = 0
        local worker_signal = Instance.new("BindableEvent")

        local function worker_acquire()
            while worker_sem >= setting_max_workers do
                worker_signal.Event:Wait()
            end
            worker_sem = worker_sem + 1
        end

        local function worker_release()
            worker_sem = worker_sem - 1
            worker_signal:Fire()
        end

        for i = 1, #all_scripts do
            if active_search_id ~= search_id then break end

            local script_instance = all_scripts[i]
            local s, bytecode = pcall(getscriptbytecode, script_instance)
            local bytecode_lower = (s and type(bytecode) == "string") and string.lower(bytecode) or ""
            local name_lower = string.lower(script_instance.Name)

            local match_all = true
            for _, term in ipairs(terms) do
                local pattern = setting_use_regex and term.text or escape_pattern(term.text)
                local found = string.find(name_lower, pattern) or string.find(bytecode_lower, pattern)
                if term.exclude then
                    -- Exclude: if found → reject this script
                    if found then match_all = false break end
                else
                    -- Include: must be found
                    if not found then match_all = false break end
                end
            end

            if match_all then
                worker_acquire()

                task.spawn(function()
                    local code = decompile_cache[script_instance]
                    if not code then
                        local ok, res = pcall(do_decompile, script_instance)
                        if ok and type(res) == "string" and #res > 0 then
                            code = res
                            cache_set(script_instance, code)
                        end
                    end

                    local total_count = 0
                    local code_lower2 = code and string.lower(code) or ""

                    for _, term in ipairs(terms) do
                        if term.exclude then continue end  -- don't count exclusion hits
                        local pattern = setting_use_regex and term.text or escape_pattern(term.text)
                        local name_hit = string.find(name_lower, pattern)
                        local _, code_count = string.gsub(code_lower2, pattern, "")
                        if name_hit then total_count = total_count + 1 end
                        total_count = total_count + code_count
                    end

                    if active_search_id == search_id and total_count > 0 then
                        local hash_text = "HASH: N/A"
                        if getscripthash then
                            pcall(function()
                                local h = getscripthash(script_instance)
                                if h then hash_text = "HASH: " .. h end
                            end)
                        end

                        local size_text = "SIZE: N/A"
                        if s and type(bytecode) == "string" then
                            size_text = "SIZE: " .. format_bytes(#bytecode)
                        end

                        table.insert(current_results, {
                            script = script_instance,
                            name = script_instance.Name,
                            class = script_instance.ClassName,
                            count = total_count,
                            hash = hash_text,
                            path = script_instance:GetFullName(),
                            color = type_colors[script_instance.ClassName] or current_theme.text,
                            size = size_text
                        })
                        render_results()
                    end

                    worker_release()
                end)
            end

            if i % 250 == 0 then task.wait() end
        end

        while worker_sem > 0 and active_search_id == search_id do
            worker_signal.Event:Wait()
        end
        worker_signal:Destroy()

        task.wait(0.3)
        if active_search_id == search_id then
            set_search_state("search")
        end
    end)
end

bind_tap(search_button, function()
    if code_view_container.Visible then
        code_view_container.Visible = false
        results_scroll.Visible = true
    end
    if settings_container.Visible then
        settings_container.Visible = false
        results_scroll.Visible = true
    end
    perform_search()
end)

bind_tap(cancel_button, function()
    if search_thread then task.cancel(search_thread) search_thread = nil end
    active_search_id = -1  -- invalidate any running workers
    set_search_state("search")
    result_count_label.Text = "Search cancelled — " .. #current_results .. " partial results"
end)

bind_tap(export_btn, function()
    if not writefile then
        export_btn.Text = "N/A"
        task.delay(1.5, function() if export_btn.Parent then export_btn.Text = "EXPORT" end end)
        return
    end
    if #current_results == 0 then
        export_btn.Text = "EMPTY"
        task.delay(1.5, function() if export_btn.Parent then export_btn.Text = "EXPORT" end end)
        return
    end
    local lines = {"-- MEGGD Script Scanner Export", "-- Query: " .. search_box.Text, "-- " .. os.date(), ""}
    for _, r in ipairs(current_results) do
        table.insert(lines, r.class .. " | " .. r.name .. " | " .. r.count .. " matches")
        table.insert(lines, "  PATH: " .. r.path)
        table.insert(lines, "  " .. r.hash .. " | " .. r.size)
        table.insert(lines, "")
    end
    -- Also include bookmarks
    local bm_count = 0
    for _ in pairs(bookmarks) do bm_count = bm_count + 1 end
    if bm_count > 0 then
        table.insert(lines, "-- BOOKMARKS (" .. bm_count .. ")")
        for path, r in pairs(bookmarks) do
            table.insert(lines, r.class .. " | " .. r.name)
            table.insert(lines, "  PATH: " .. path)
            table.insert(lines, "")
        end
    end
    local fname = "scanner_export_" .. os.time() .. ".txt"
    pcall(writefile, fname, table.concat(lines, "
"))
    export_btn.Text = "SAVED!"
    export_btn.BackgroundColor3 = current_theme.accent
    task.delay(2, function()
        if export_btn.Parent then
            export_btn.Text = "EXPORT"
            export_btn.BackgroundColor3 = current_theme.element_bg
        end
    end)
end)

-- ==========================================
-- SETTINGS INTERACTIONS
-- ==========================================

local is_dropdown_open = false
bind_tap(dropdown_main, function()
    is_dropdown_open = not is_dropdown_open
    tween_service:Create(icon_arrow_down, TweenInfo.new(0.2), {Rotation = is_dropdown_open and 180 or 0}):Play()
    if is_dropdown_open then
        dropdown_list.Visible = true
        tween_service:Create(dropdown_list, TweenInfo.new(0.2), {Size = UDim2.new(1, -20, 0, #decompiler_options * 26)}):Play()
    else
        local tw = tween_service:Create(dropdown_list, TweenInfo.new(0.2), {Size = UDim2.new(1, -20, 0, 0)})
        tw:Play()
        tw.Completed:Connect(function() if not is_dropdown_open then dropdown_list.Visible = false end end)
    end
end)

local function select_decompiler(name)
    if setting_decompiler ~= name then decompile_cache = {} end
    setting_decompiler = name
    dropdown_text.Text = name
    is_dropdown_open = false
    tween_service:Create(icon_arrow_down, TweenInfo.new(0.2), {Rotation = 0}):Play()
    local tw = tween_service:Create(dropdown_list, TweenInfo.new(0.2), {Size = UDim2.new(1, -20, 0, 0)})
    tw:Play()
    tw.Completed:Connect(function() if not is_dropdown_open then dropdown_list.Visible = false end end)
end

for name, btn in pairs(decompiler_btns) do
    bind_tap(btn, function() select_decompiler(name) end)
end

-- Font size slider
local is_dragging_font = false
local font_sizes = {10, 12, 13, 14, 16, 18, 20}
font_slider_track.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then
        is_dragging_font = true
    end
end)
user_input_service.InputChanged:Connect(function(input)
    if is_dragging_font and input.UserInputType == Enum.UserInputType.Touch then
        local track_pos = font_slider_track.AbsolutePosition.X
        local track_w = font_slider_track.AbsoluteSize.X
        local ratio = math.clamp((input.Position.X - track_pos) / track_w, 0, 1)
        local idx = math.clamp(math.round(ratio * (#font_sizes - 1)) + 1, 1, #font_sizes)
        setting_font_size = font_sizes[idx]
        font_slider_fill.Size = UDim2.new((idx-1) / (#font_sizes-1), 0, 1, 0)
        if font_size_label then font_size_label.Text = "Font Size: " .. setting_font_size end
    end
end)
user_input_service.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then is_dragging_font = false end
end)

-- Checkboxes
bind_tap(checkbox_frame, function()
    setting_remove_comments = not setting_remove_comments
    if setting_remove_comments then
        tween_service:Create(checkbox_inner, TweenInfo.new(0.2), {Size = UDim2.new(0, 12, 0, 12), BackgroundTransparency = 0}):Play()
    else
        tween_service:Create(checkbox_inner, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 1}):Play()
    end
end)

bind_tap(regex_frame, function()
    setting_use_regex = not setting_use_regex
    if setting_use_regex then
        tween_service:Create(regex_inner, TweenInfo.new(0.2), {Size = UDim2.new(0, 12, 0, 12), BackgroundTransparency = 0}):Play()
    else
        tween_service:Create(regex_inner, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 1}):Play()
    end
end)

bind_tap(clear_cache_btn, function()
    local count = #cache_order
    decompile_cache = {}
    cache_order = {}
    clear_cache_btn.Text = "CLEAR DECOMPILE CACHE (cleared " .. count .. ")"
    task.delay(2, function()
        clear_cache_btn.Text = "CLEAR DECOMPILE CACHE (0 entries)"
    end)
end)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return t
end

local function rspy_get_path(instance)
    local parts = {}
    local cur = instance
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return "game." .. table.concat(parts, ".")
end

local function rspy_format_args(args)
    -- args[1] is self (the remote), so skip it
    local parts = {}
    for i = 2, #args do
        table.insert(parts, rspy_serialize(args[i]))
    end
    return #parts > 0 and table.concat(parts, ", ") or "(no args)"
end

local function rspy_get_source(remote)
    -- Try to decompile the script that owns this remote
    -- Walk up the hierarchy to find a Script/LocalScript
    local cur = remote.Parent
    while cur do
        if cur:IsA("LuaSourceContainer") then
            local cached = decompile_cache[cur]
            if cached then return cached end
            local src = pcall_decompile(cur)
            if src then
                decompile_cache[cur] = src
                return src
            end
            return "-- decompile failed"
        end
        cur = cur.Parent
    end
    return "-- no script found"
end

-- ── Remote Spy UI ────────────────────────────────

local rspy_container = create_instance("Frame", {
    Parent = content_area,
    BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 1, 0),
    Visible = false,
    ClipsDescendants = true,
})

-- Top bar
local rspy_topbar = create_instance("Frame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 32),
})

local rspy_back_btn = create_instance("TextButton", {
    Parent = rspy_topbar,
    BackgroundColor3 = current_theme.border,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 4, 0, 4),
    Size = UDim2.new(0, 55, 0, 24),
    Font = Enum.Font.Arcade,
    Text = "BACK",
    TextColor3 = current_theme.text,
    TextSize = 13,
    AutoButtonColor = false,
})
button_colors[rspy_back_btn] = current_theme.border

local rspy_toggle_btn = create_instance("TextButton", {
    Parent = rspy_topbar,
    BackgroundColor3 = Color3.fromRGB(60, 120, 60),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 64, 0, 4),
    Size = UDim2.new(0, 70, 0, 24),
    Font = Enum.Font.Arcade,
    Text = "START",
    TextColor3 = Color3.fromRGB(255,255,255),
    TextSize = 13,
    AutoButtonColor = false,
})

local rspy_clear_btn = create_instance("TextButton", {
    Parent = rspy_topbar,
    BackgroundColor3 = Color3.fromRGB(120, 40, 40),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 139, 0, 4),
    Size = UDim2.new(0, 55, 0, 24),
    Font = Enum.Font.Arcade,
    Text = "CLEAR",
    TextColor3 = Color3.fromRGB(255,255,255),
    TextSize = 13,
    AutoButtonColor = false,
})

local rspy_status = create_instance("TextLabel", {
    Parent = rspy_topbar,
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 200, 0, 0),
    Size = UDim2.new(1, -204, 1, 0),
    Font = Enum.Font.Arcade,
    Text = "● STOPPED",
    TextColor3 = Color3.fromRGB(150,150,150),
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
})

-- Method toggles row
local rspy_methods_bar = create_instance("Frame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0, 32),
    Size = UDim2.new(1, 0, 0, 28),
})

local rspy_method_btns = {}
local method_list = {"FireServer", "InvokeServer", "FireAllClients", "FireClient"}
for i, method in ipairs(method_list) do
    local on = rspy_methods[method]
    local btn = create_instance("TextButton", {
        Parent = rspy_methods_bar,
        BackgroundColor3 = on and current_theme.accent or current_theme.border,
        BorderSizePixel = 0,
        Position = UDim2.new(0, (i-1) * 80 + 4, 0, 4),
        Size = UDim2.new(0, 76, 0, 20),
        Font = Enum.Font.Arcade,
        Text = method == "FireServer" and "FireSvr" or
               method == "InvokeServer" and "InvkSvr" or
               method == "FireAllClients" and "FireAll" or "FireCli",
        TextColor3 = Color3.fromRGB(255,255,255),
        TextSize = 11,
        AutoButtonColor = false,
    })
    rspy_method_btns[method] = btn
    btn.MouseButton1Click:Connect(function()
        rspy_methods[method] = not rspy_methods[method]
        btn.BackgroundColor3 = rspy_methods[method] and current_theme.accent or current_theme.border
    end)
end

-- Tab bar (scrollable, shows one button per unique remote)
local rspy_tabbar = create_instance("ScrollingFrame", {
    Parent = rspy_container,
    BackgroundColor3 = Color3.fromRGB(22, 22, 22),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0, 60),
    Size = UDim2.new(1, 0, 0, 28),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 0,
    ScrollingDirection = Enum.ScrollingDirection.X,
    ElasticBehavior = Enum.ElasticBehavior.Never,
})
local rspy_tabbar_layout = create_instance("UIListLayout", {
    Parent = rspy_tabbar,
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 2),
})
rspy_tabbar_layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    rspy_tabbar.CanvasSize = UDim2.new(0, rspy_tabbar_layout.AbsoluteContentSize.X, 0, 0)
end)

-- Content area: split view (args top, source bottom)
local rspy_content = create_instance("Frame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0, 88),
    Size = UDim2.new(1, 0, 1, -88),
    ClipsDescendants = true,
})

-- Top half: log entries for active tab
local rspy_log_scroll = create_instance("ScrollingFrame", {
    Parent = rspy_content,
    BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0.45, 0),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 6,
    ScrollBarImageColor3 = current_theme.accent,
    BottomImage = flat_image, MidImage = flat_image, TopImage = flat_image,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ElasticBehavior = Enum.ElasticBehavior.Never,
})
local rspy_log_layout = create_instance("UIListLayout", {
    Parent = rspy_log_scroll,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 1),
})
rspy_log_layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    rspy_log_scroll.CanvasSize = UDim2.new(0, 0, 0, rspy_log_layout.AbsoluteContentSize.Y)
end)

-- Divider label
local rspy_divider = create_instance("Frame", {
    Parent = rspy_content,
    BackgroundColor3 = current_theme.border,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0.45, 0),
    Size = UDim2.new(1, 0, 0, 18),
})
create_instance("TextLabel", {
    Parent = rspy_divider,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 1, 0),
    Font = Enum.Font.Arcade,
    Text = "── DECOMPILED SOURCE ──",
    TextColor3 = current_theme.text,
    TextSize = 11,
})

-- Bottom half: decompiled source viewer
local rspy_source_scroll = create_instance("ScrollingFrame", {
    Parent = rspy_content,
    BackgroundColor3 = Color3.fromRGB(20, 20, 20),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0.45, 18),
    Size = UDim2.new(1, 0, 0.55, -18),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 6,
    ScrollBarImageColor3 = current_theme.accent,
    BottomImage = flat_image, MidImage = flat_image, TopImage = flat_image,
    ScrollingDirection = Enum.ScrollingDirection.XY,
    ElasticBehavior = Enum.ElasticBehavior.Never,
})
local rspy_source_text = create_instance("TextLabel", {
    Parent = rspy_source_scroll,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 0),
    Font = Enum.Font.Code,
    Text = "-- Click a log entry to see decompiled source",
    TextColor3 = Color3.fromRGB(180, 180, 180),
    TextSize = setting_font_size,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextWrapped = false,
    RichText = false,
})

-- ── Tab management ───────────────────────────────

local function rspy_update_source(src)
    rspy_source_text.Text = src or "-- no source"
    local ts = text_service:GetTextSize(
        rspy_source_text.Text, setting_font_size,
        Enum.Font.Code, Vector2.new(9999, 9999)
    )
    rspy_source_scroll.CanvasSize = UDim2.new(0, ts.X + 10, 0, ts.Y + 10)
    rspy_source_text.Size = UDim2.new(0, math.max(ts.X + 10, rspy_source_scroll.AbsoluteSize.X), 0, ts.Y + 10)
end

local function rspy_add_log_entry(remote_path, method, args_str, source)
    -- Update call count on tab button label
    local tab = rspy_tabs[remote_path]
    if tab then
        tab.count = (tab.count or 0) + 1
        rspy_call_counts[remote_path] = tab.count
        local parts     = string.split(remote_path, ".")
        local short     = parts[#parts]
        local elapsed   = rspy_first_call[remote_path] and string.format("%.1fs", os.clock() - rspy_first_call[remote_path]) or "?"
        local freq_text = tab.count .. "x"
        -- Show: ShortName (Nx)
        tab.btn.Text = short .. " (" .. freq_text .. ")"
        tab.btn.Size = UDim2.new(0, math.clamp(#tab.btn.Text * 7 + 12, 70, 180), 1, -2)
    end
    local tab = rspy_tabs[remote_path]
    if not tab then return end

    local entry_count = #tab.entries
    local t = os.date("%H:%M:%S")
    local entry = create_instance("TextButton", {
        Parent = rspy_log_scroll,
        BackgroundColor3 = entry_count % 2 == 0 and current_theme.bg or current_theme.element_bg,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 36),
        LayoutOrder = entry_count + 1,
        AutoButtonColor = false,
        Text = "",
    })

    create_instance("TextLabel", {
        Parent = entry,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 6, 0, 2),
        Size = UDim2.new(1, -8, 0, 16),
        Font = Enum.Font.Arcade,
        Text = "[" .. t .. "] " .. method,
        TextColor3 = current_theme.accent,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    })

    create_instance("TextLabel", {
        Parent = entry,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 6, 0, 18),
        Size = UDim2.new(1, -8, 0, 14),
        Font = Enum.Font.Code,
        Text = args_str,
        TextColor3 = Color3.fromRGB(200, 200, 150),
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })

    entry.MouseButton1Click:Connect(function()
        -- Highlight selected entry
        for _, e in pairs(tab.entries) do
            e.BackgroundColor3 = current_theme.bg
        end
        entry.BackgroundColor3 = Color3.fromRGB(30, 60, 100)
        rspy_update_source(source)
    end)

    table.insert(tab.entries, entry)

    -- Auto-scroll to bottom if active tab
    if rspy_active_tab == remote_path then
        task.defer(function()
            rspy_log_scroll.CanvasPosition = Vector2.new(
                0, rspy_log_layout.AbsoluteContentSize.Y
            )
        end)
    end
end

local function rspy_show_tab(remote_path)
    rspy_active_tab = remote_path

    -- Clear log scroll and repopulate with this tab's entries
    for _, child in pairs(rspy_log_scroll:GetChildren()) do
        if child:IsA("GuiObject") and not child:IsA("UIListLayout") then
            child.Parent = nil
        end
    end

    local tab = rspy_tabs[remote_path]
    if tab then
        for _, entry in ipairs(tab.entries) do
            entry.Parent = rspy_log_scroll
        end
    end

    rspy_update_source("-- Click a log entry to see decompiled source")

    -- Update tab button highlights
    for path, t in pairs(rspy_tabs) do
        t.btn.BackgroundColor3 = path == remote_path
            and current_theme.accent or current_theme.border
    end
end

local function rspy_ensure_tab(remote_path)
    if rspy_tabs[remote_path] then return end

    -- Shorten name for display
    local parts = string.split(remote_path, ".")
    local short  = parts[#parts]

    local btn = create_instance("TextButton", {
        Parent = rspy_tabbar,
        BackgroundColor3 = current_theme.border,
        BorderSizePixel = 0,
        Size = UDim2.new(0, math.clamp(#short * 8 + 16, 60, 160), 1, -2),
        Font = Enum.Font.Arcade,
        Text = short,
        TextColor3 = current_theme.text,
        TextSize = 11,
        AutoButtonColor = false,
        LayoutOrder = #rspy_tab_order + 1,
    })

    rspy_tabs[remote_path] = { btn = btn, entries = {}, count = 0 }
    table.insert(rspy_tab_order, remote_path)
    rspy_first_call[remote_path] = os.clock()

    btn.MouseButton1Click:Connect(function()
        rspy_show_tab(remote_path)
    end)

    -- Auto-show first tab
    if #rspy_tab_order == 1 then
        rspy_show_tab(remote_path)
    end
end

-- ── Hook ─────────────────────────────────────────

local rspy_old_namecall
rspy_old_namecall = hookmetamethod(game, "__namecall", newcclosure(function(...)
    local args   = {...}
    local self   = args[1]
    local method = getnamecallmethod()

    if rspy_enabled and rspy_methods[method]
        and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction"))
        and not checkcaller()
    then
        task.defer(function()
            local remote_path = pcall(rspy_get_path, self) and rspy_get_path(self) or self.Name
            rspy_ensure_tab(remote_path)

            local args_str = pcall(rspy_format_args, args) and rspy_format_args(args) or "(error reading args)"
            local source    = rspy_get_source(self)

            local entry = {
                remote_path = remote_path,
                method      = method,
                args_str    = args_str,
                source      = source,
                time        = os.time(),
            }
            table.insert(rspy_log, entry)

            -- Only add to UI if this is the active tab or any tab
            rspy_add_log_entry(remote_path, method, args_str, source)
        end)
    end

    return rspy_old_namecall(...)
end))

-- ── Controls ─────────────────────────────────────

rspy_toggle_btn.MouseButton1Click:Connect(function()
    rspy_enabled = not rspy_enabled
    if rspy_enabled then
        rspy_toggle_btn.Text = "STOP"
        rspy_toggle_btn.BackgroundColor3 = Color3.fromRGB(140, 50, 50)
        rspy_status.Text = "● LISTENING"
        rspy_status.TextColor3 = Color3.fromRGB(80, 220, 80)
    else
        rspy_toggle_btn.Text = "START"
        rspy_toggle_btn.BackgroundColor3 = Color3.fromRGB(60, 120, 60)
        rspy_status.Text = "● STOPPED"
        rspy_status.TextColor3 = Color3.fromRGB(150, 150, 150)
    end
end)

rspy_clear_btn.MouseButton1Click:Connect(function()
    -- Clear all tabs, entries, and log
    for _, tab in pairs(rspy_tabs) do
        tab.btn:Destroy()
        for _, e in pairs(tab.entries) do
            e:Destroy()
        end
    end
    rspy_tabs     = {}
    rspy_tab_order = {}
    rspy_log      = {}
    rspy_active_tab = nil
    rspy_update_source("-- Click a log entry to see decompiled source")
end)

rspy_back_btn.MouseButton1Click:Connect(function()
    rspy_container.Visible = false
    results_scroll.Visible = true
end)


-- ==========================================
-- REMOTE SPY (v1.4.0)
-- Intercepts RemoteEvent/RemoteFunction calls
-- Shows args + decompiled source per remote
-- ==========================================

local remote_spy_enabled   = false
local remote_spy_log       = {}   -- { id, name, path, method, args_str, source, time }
local remote_spy_tabs      = {}   -- { id -> { btn, panel } }
local remote_spy_id_counter = 0
local remote_spy_active_tab = nil

-- Which methods to intercept (user toggleable)
local spy_methods = {
    FireServer        = true,
    InvokeServer      = true,
    FireAllClients    = false,
    FireClient        = false,
}

-- Helper: serialise args to a readable string
local function serialize_args(args)
    local parts = {}
    for i = 2, #args do  -- skip self (args[1])
        local v = args[i]
        local t = typeof(v)
        if t == "string" then
            table.insert(parts, '"' .. tostring(v):sub(1, 60) .. '"')
        elseif t == "Instance" then
            table.insert(parts, "[Instance] " .. v:GetFullName())
        elseif t == "table" then
            table.insert(parts, "[table] " .. http_service:JSONEncode(v):sub(1, 80))
        elseif t == "Vector3" then
            table.insert(parts, string.format("Vector3(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z))
        elseif t == "CFrame" then
            table.insert(parts, "CFrame(...)")
        else
            table.insert(parts, tostring(v):sub(1, 60))
        end
    end
    return table.concat(parts, ", ")
end

-- Helper: get script path that fired the remote via debug.info
local function get_caller_path()
    -- Walk up the call stack to find the game script (not our hook)
    for level = 2, 10 do
        local ok, src = pcall(function() return debug.info(level, "s") end)
        if not ok or not src then break end
        if src ~= "[C]" and not src:find("MEGGD") and src ~= "" then
            return src
        end
    end
    return "unknown"
end

-- ── UI: RemoteSpy container ──────────────────────────────────────────────────

local rspy_container = create_instance("Frame", {
    Parent = content_area,
    BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 1, 0),
    Visible = false,
    ClipsDescendants = true,
})

-- Top bar: controls
local rspy_topbar = create_instance("Frame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 28),
})

local rspy_toggle_btn = create_instance("TextButton", {
    Parent = rspy_topbar,
    BackgroundColor3 = Color3.fromRGB(60, 140, 60),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 4, 0, 4),
    Size = UDim2.new(0, 60, 0, 20),
    Font = Enum.Font.Arcade,
    Text = "START",
    TextColor3 = Color3.new(1,1,1),
    TextSize = 12,
    AutoButtonColor = false,
})

local rspy_clear_btn = create_instance("TextButton", {
    Parent = rspy_topbar,
    BackgroundColor3 = Color3.fromRGB(140, 40, 40),
    BorderSizePixel = 0,
    Position = UDim2.new(0, 68, 0, 4),
    Size = UDim2.new(0, 50, 0, 20),
    Font = Enum.Font.Arcade,
    Text = "CLEAR",
    TextColor3 = Color3.new(1,1,1),
    TextSize = 12,
    AutoButtonColor = false,
})

local rspy_status = create_instance("TextLabel", {
    Parent = rspy_topbar,
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 122, 0, 0),
    Size = UDim2.new(1, -126, 1, 0),
    Font = Enum.Font.Arcade,
    Text = "● IDLE",
    TextColor3 = Color3.fromRGB(120, 120, 120),
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
})

-- Method toggles
local rspy_method_bar = create_instance("Frame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0, 28),
    Size = UDim2.new(1, 0, 0, 24),
})

local method_toggle_btns = {}
local method_names = {"FireServer", "InvokeServer", "FireAllClients", "FireClient"}
local method_x = 4
for _, mname in ipairs(method_names) do
    local active = spy_methods[mname]
    local btn = create_instance("TextButton", {
        Parent = rspy_method_bar,
        BackgroundColor3 = active and current_theme.accent or current_theme.border,
        BorderSizePixel = 0,
        Position = UDim2.new(0, method_x, 0, 3),
        Size = UDim2.new(0, #mname * 7 + 8, 0, 18),
        Font = Enum.Font.Arcade,
        Text = mname,
        TextColor3 = Color3.new(1,1,1),
        TextSize = 10,
        AutoButtonColor = false,
    })
    method_toggle_btns[mname] = btn
    method_x = method_x + #mname * 7 + 12

    btn.MouseButton1Click:Connect(function()
        spy_methods[mname] = not spy_methods[mname]
        btn.BackgroundColor3 = spy_methods[mname] and current_theme.accent or current_theme.border
    end)
    btn.TouchTap:Connect(function()
        spy_methods[mname] = not spy_methods[mname]
        btn.BackgroundColor3 = spy_methods[mname] and current_theme.accent or current_theme.border
    end)
end

-- Left: tab list (scrollable)
local rspy_tab_list = create_instance("ScrollingFrame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.element_bg,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 0, 0, 52),
    Size = UDim2.new(0, 130, 1, -52),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = current_theme.accent,
    BottomImage = flat_image, MidImage = flat_image, TopImage = flat_image,
    ScrollingDirection = Enum.ScrollingDirection.Y,
})
create_instance("UIListLayout", {
    Parent = rspy_tab_list,
    SortOrder = Enum.SortOrder.LayoutOrder,
})

-- Right: detail panel
local rspy_detail = create_instance("ScrollingFrame", {
    Parent = rspy_container,
    BackgroundColor3 = current_theme.bg,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 130, 0, 52),
    Size = UDim2.new(1, -130, 1, -52),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ScrollBarThickness = 8,
    ScrollBarImageColor3 = current_theme.accent,
    BottomImage = flat_image, MidImage = flat_image, TopImage = flat_image,
    ScrollingDirection = Enum.ScrollingDirection.Y,
})
local rspy_detail_layout = create_instance("UIListLayout", {
    Parent = rspy_detail,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 4),
})
rspy_detail_layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    rspy_detail.CanvasSize = UDim2.new(0, 0, 0, rspy_detail_layout.AbsoluteContentSize.Y + 8)
end)

local rspy_placeholder = create_instance("TextLabel", {
    Parent = rspy_detail,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 40),
    Font = Enum.Font.Arcade,
    Text = "No remote selected",
    TextColor3 = current_theme.border,
    TextSize = 13,
    LayoutOrder = 0,
})

-- ── UI helpers ───────────────────────────────────────────────────────────────

local function make_detail_label(parent, text, color, order, fontSize)
    local lbl = create_instance("TextLabel", {
        Parent = parent,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -8, 0, 0),
        Position = UDim2.new(0, 4, 0, 0),
        Font = Enum.Font.Code,
        Text = text,
        TextColor3 = color or current_theme.text,
        TextSize = fontSize or 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = order or 0,
    })
    return lbl
end

-- Show a remote entry's full detail in the right panel
local function show_rspy_detail(entry)
    -- Clear existing detail
    for _, c in pairs(rspy_detail:GetChildren()) do
        if c:IsA("GuiObject") and c ~= rspy_placeholder then c:Destroy() end
    end
    rspy_placeholder.Visible = false

    -- Remote name + method
    make_detail_label(rspy_detail,
        "📡 " .. entry.method .. " — " .. entry.name,
        current_theme.accent, 1, 13)

    -- Full path
    make_detail_label(rspy_detail,
        "Path: " .. entry.path,
        Color3.fromRGB(150, 150, 150), 2, 11)

    -- Timestamp
    make_detail_label(rspy_detail,
        "Time: " .. entry.time,
        Color3.fromRGB(120, 120, 120), 3, 11)

    -- Args
    make_detail_label(rspy_detail,
        "── Args ──",
        current_theme.border, 4, 11)
    make_detail_label(rspy_detail,
        entry.args_str ~= "" and entry.args_str or "(no args)",
        Color3.fromRGB(206, 145, 120), 5, 12)

    -- Source header
    make_detail_label(rspy_detail,
        "── Decompiled Source ──",
        current_theme.border, 6, 11)

    if entry.source then
        -- Syntax-colored source (simple: just show as-is in code font)
        local src_lbl = make_detail_label(rspy_detail,
            entry.source,
            Color3.fromRGB(212, 212, 212), 7, 11)
        src_lbl.Font = Enum.Font.Code
    else
        local decomp_lbl = make_detail_label(rspy_detail,
            "Decompiling...", Color3.fromRGB(150, 150, 150), 7, 11)

        -- Decompile async
        task.spawn(function()
            local caller_script = entry.caller_script
            if caller_script and caller_script:IsA("LuaSourceContainer") then
                local source = do_decompile(caller_script)
                entry.source = source
                if decomp_lbl and decomp_lbl.Parent then
                    decomp_lbl.Text = source or "-- failed to decompile"
                    decomp_lbl.Font = Enum.Font.Code
                end
            else
                if decomp_lbl and decomp_lbl.Parent then
                    decomp_lbl.Text = "-- caller script not accessible"
                end
            end
        end)
    end
end

-- Add a new tab entry for a caught remote
local function add_rspy_entry(entry)
    remote_spy_log[entry.id] = entry

    -- Tab button in left list
    local tab_btn = create_instance("TextButton", {
        Parent = rspy_tab_list,
        BackgroundColor3 = current_theme.element_bg,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 36),
        Font = Enum.Font.Arcade,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = -entry.id,  -- newest on top
    })

    -- Method badge color
    local method_color = entry.method == "FireServer"   and Color3.fromRGB(86, 156, 214)
                      or entry.method == "InvokeServer" and Color3.fromRGB(78, 201, 176)
                      or Color3.fromRGB(197, 134, 192)

    create_instance("TextLabel", {
        Parent = tab_btn,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 4, 0, 2),
        Size = UDim2.new(1, -8, 0, 14),
        Font = Enum.Font.Arcade,
        Text = entry.name:sub(1, 16),
        TextColor3 = Color3.new(1,1,1),
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })

    create_instance("TextLabel", {
        Parent = tab_btn,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 4, 0, 18),
        Size = UDim2.new(1, -8, 0, 14),
        Font = Enum.Font.Arcade,
        Text = entry.method,
        TextColor3 = method_color,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    })

    -- Highlight active tab
    local function select_tab()
        if remote_spy_active_tab then
            remote_spy_active_tab.BackgroundColor3 = current_theme.element_bg
        end
        tab_btn.BackgroundColor3 = current_theme.accent
        remote_spy_active_tab = tab_btn
        show_rspy_detail(entry)
    end

    tab_btn.MouseButton1Click:Connect(select_tab)
    tab_btn.TouchTap:Connect(select_tab)

    -- Update tab list canvas size
    rspy_tab_list.CanvasSize = UDim2.new(0, 0, 0,
        rspy_tab_list:FindFirstChildOfClass("UIListLayout").AbsoluteContentSize.Y)

    -- Auto-select if first or newest
    select_tab()

    remote_spy_tabs[entry.id] = tab_btn
end

-- ── Hook ─────────────────────────────────────────────────────────────────────

local rspy_hook_active = false
local rspy_old_namecall = nil

local function start_rspy_hook()
    if rspy_hook_active then return end
    rspy_hook_active = true

    rspy_old_namecall = hookmetamethod(game, "__namecall", newcclosure(function(...)
        local args   = {...}
        local self   = args[1]
        local method = getnamecallmethod()

        -- Only intercept enabled methods on RemoteEvent/RemoteFunction
        if spy_methods[method] and not checkcaller() then
            if self:IsA("RemoteEvent") or self:IsA("RemoteFunction") then
                task.spawn(function()
                    remote_spy_id_counter = remote_spy_id_counter + 1

                    -- Try to find the calling script
                    local caller_script = nil
                    for level = 2, 12 do
                        local ok, src = pcall(debug.info, level, "s")
                        if not ok then break end
                        -- Try to get the actual script instance via getscripts()
                        if getgenv().getscripts then
                            for _, s in pairs(getscripts()) do
                                if s.Name == src or s:GetFullName() == src then
                                    caller_script = s
                                    break
                                end
                            end
                        end
                        if caller_script then break end
                    end

                    local entry = {
                        id            = remote_spy_id_counter,
                        name          = self.Name,
                        path          = self:GetFullName(),
                        method        = method,
                        args_str      = serialize_args(args),
                        source        = nil,
                        caller_script = caller_script,
                        time          = os.date("%H:%M:%S"),
                    }

                    -- Only add if RemoteSpy UI is visible (avoid stacking up hidden)
                    if remote_spy_enabled then
                        add_rspy_entry(entry)
                    end
                end)
            end
        end

        return rspy_old_namecall(...)
    end))
end

local function stop_rspy_hook()
    if not rspy_hook_active or not rspy_old_namecall then return end
    hookmetamethod(game, "__namecall", rspy_old_namecall)
    rspy_old_namecall = nil
    rspy_hook_active = false
end

-- ── Toggle / Clear ───────────────────────────────────────────────────────────

rspy_toggle_btn.MouseButton1Click:Connect(function()
    remote_spy_enabled = not remote_spy_enabled
    if remote_spy_enabled then
        start_rspy_hook()
        rspy_toggle_btn.Text = "STOP"
        rspy_toggle_btn.BackgroundColor3 = Color3.fromRGB(140, 60, 60)
        rspy_status.Text = "● LISTENING"
        rspy_status.TextColor3 = Color3.fromRGB(80, 220, 80)
    else
        stop_rspy_hook()
        rspy_toggle_btn.Text = "START"
        rspy_toggle_btn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
        rspy_status.Text = "● IDLE"
        rspy_status.TextColor3 = Color3.fromRGB(120, 120, 120)
    end
end)
rspy_toggle_btn.TouchTap:Connect(function()
    rspy_toggle_btn.MouseButton1Click:Fire()
end)

rspy_clear_btn.MouseButton1Click:Connect(function()
    for _, c in pairs(rspy_tab_list:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
    for _, c in pairs(rspy_detail:GetChildren()) do
        if c:IsA("GuiObject") and c ~= rspy_placeholder then c:Destroy() end
    end
    remote_spy_log  = {}
    remote_spy_tabs = {}
    remote_spy_id_counter = 0
    remote_spy_active_tab = nil
    rspy_placeholder.Visible = true
    rspy_status.Text = (remote_spy_enabled and "● LISTENING" or "● IDLE") .. " — cleared"
end)
rspy_clear_btn.TouchTap:Connect(function()
    rspy_clear_btn.MouseButton1Click:Fire()
end)


print("MEGGD Script Scanner Enhanced V1.4.0 - Loaded")
