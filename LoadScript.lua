local uis = game:GetService("UserInputService")

local is_mobile = uis.TouchEnabled and not uis.KeyboardEnabled
print("Loading...")
if is_mobile then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/windbreaker7/MEGGD-Script-Scanner/refs/heads/main/Device/MEGGD_Script_Scanner(Mobile).lua", true))()
else
    loadstring(game:HttpGet("https://raw.githubusercontent.com/windbreaker7/MEGGD-Script-Scanner/refs/heads/main/Device/MEGGD_Script_Scanner(PC).lua", true))()
end
