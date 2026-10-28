-- Example usage of UILib (Roblox / Luau)
local Library = loadstring(readfile("UILib.lua"))()   -- or: require(path.to.UILib)

local Window = Library.new{
	Title  = "MyMenu",
	Accent = Color3.fromRGB(111, 130, 214),
	User   = {
		Name   = "You",          -- shown bottom-left (defaults to your Roblox display name)
		Tag    = "@player",
		-- Avatar = 1234567,     -- userId, or an "rbxassetid://..." string
		OnClick = function(win) print("profile clicked") end,
		Buttons = {              -- shown in the popup when you click the profile
			{ Text = "View profile", Callback = function() print("profile") end },
			{ Text = "Log out",      Callback = function() print("logout") end },
		},
	},
}

-- Tabs live along the bottom. Use Icon = "rbxassetid://<id>" or a text Glyph.
local Combat = Window:AddTab{ Name = "Combat",  Glyph = "C" }
local Visual = Window:AddTab{ Name = "Visuals", Glyph = "V" }

local s = Combat:AddSection{ Side = "Left" }
s:AddToggle{ Name = "Enabled", Bold = true, Default = true, Flag = "CombatEnabled", Callback = function(v) print("enabled", v) end }
s:AddSlider{ Name = "Range", Min = 0, Max = 50, Default = 12, Decimals = 1, Suffix = " st", Flag = "Range" }
s:AddKeybind{ Name = "Trigger key", Default = Enum.KeyCode.E, Flag = "TriggerKey", Callback = function() print("pressed") end }
s:AddDropdown{ Name = "Mode", Options = { "Legit", "Rage", "Custom" }, Default = "Legit", Flag = "Mode" }

local s2 = Combat:AddSection{ Side = "Right" }
s2:AddColorPicker{ Name = "Highlight color", Default = Color3.fromRGB(255, 80, 80), Flag = "Highlight" }
s2:AddTextBox{ Name = "Target name", Placeholder = "Target name", Flag = "Target" }
s2:AddButton{ Name = "Say hi", Callback = function() Window:Notify{ Title = "Hello", Text = "Button pressed", Duration = 3 } end }

Visual:AddSection{ Side = "Left", Title = "ESP" }:AddToggle{ Name = "Boxes", Flag = "Boxes" }

-- Settings tab (menu scale, menu key, animation speed, notifications, accent/palette,
-- watermark, keybind list, cursor options, unlock mouse, configs, walkthrough). Call LAST.
Window:AddSettingsTab()

Window:Notify{ Title = "Loaded", Text = "Press Insert to toggle the menu" }
