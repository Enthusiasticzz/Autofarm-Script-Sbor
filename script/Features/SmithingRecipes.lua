-- SmithingRecipes reads the game's crafting recipes and answers what can be
-- crafted right now. Shared by AutoSmithing (which recipe to craft next, and
-- what each recipe in its Recipe Status list is waiting on).
--
-- A recipe is a child of ReplicatedStorage.CraftingRecipes holding
--   CraftingSkill  the SmithingSkill a player needs to craft it
--   CraftType      the kind of craft
--   <Material>     a number value per material: how many one craft uses
-- The crafted item is assumed to be named like the recipe ("Iron Ingot").
--
-- What an item is comes from the game's assets, Commons.getAssets(true)
-- from CoreCommons: Assets[Name].Value is its type, and its children
-- LVL, Skill, DMG, DEF and DEX its stats. A Bound child means it cannot
-- be traded.
return {
    Name = "SmithingRecipes",
    Dependencies = {"Runtime", "SaveConfig"},

    Start = function(Context)
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local CONFIG = Context.CONFIG

        local SKILL_STAT = "SmithingSkill"
        --// Recipe children that are settings rather than materials.
        local NON_MATERIALS = { CraftType = true, CraftingSkill = true }
        --// Assets that could not be read are tried again after this long.
        local ASSETS_RETRY_SECONDS = 10
        --// An item with no type in the assets is filed under this.
        local UNKNOWN_TYPE = "Other"

        local Recipes = {
            Name = "SmithingRecipes",
            UNKNOWN_TYPE = UNKNOWN_TYPE,
            S = {
                --// Recipe name -> parsed recipe; nil until read, and dropped
                --// whenever the recipe folder changes.
                Cache = nil,
                Folder = nil,
                Connections = {},
                Assets = nil,
                AssetsRetryAt = 0,
                --// Item name -> GetItemInfo result (false when not an asset).
                ItemInfo = {},
            },
        }

        local S = Recipes.S

        local function GetAssets()
            if S.Assets or os.clock() < S.AssetsRetryAt then
                return S.Assets
            end

            local Module = Replicated:FindFirstChild("CoreCommons", true)
            local Ok, Assets = pcall(function()
                local Commons = Module and require(Module)
                return Commons and Commons.getAssets and Commons.getAssets(true)
            end)

            if Ok and type(Assets) == "table" then
                S.Assets = Assets
                table.clear(S.ItemInfo)
            else
                S.AssetsRetryAt = os.clock() + ASSETS_RETRY_SECONDS

                if not S.WarnedAssets then
                    S.WarnedAssets = true
                    warn("[SmithingRecipes] Could not read the game's assets:", Assets)
                end
            end

            return S.Assets
        end

        --// The game's assets (item name -> asset), or nil while they cannot
        --// be read. Shared with the Asset Explorer.
        function Recipes:GetAssets()
            return GetAssets()
        end

        --// An asset is an Instance with value children; a plain table of the
        --// same shape is read the same way.
        local function GetChild(Asset, ChildName)
            if typeof(Asset) == "Instance" then
                return Asset:FindFirstChild(ChildName)
            end

            return type(Asset) == "table" and Asset[ChildName] or nil
        end

        --// The Value of a child of Asset, or nil when it has none.
        local function ReadChild(Asset, ChildName)
            local Child = GetChild(Asset, ChildName)

            if not Child then
                return nil
            end

            local Ok, Value = pcall(function()
                return Child.Value
            end)

            return Ok and Value or nil
        end

        local function ReadItemInfo(Asset)
            local Ok, Type = pcall(function()
                return Asset.Value
            end)

            Type = Ok and Type ~= nil and tostring(Type) or ""

            return {
                Type = Type ~= "" and Type or UNKNOWN_TYPE,
                Level = ReadChild(Asset, "LVL"),
                Skill = ReadChild(Asset, "Skill"),
                DMG = ReadChild(Asset, "DMG"),
                DEF = ReadChild(Asset, "DEF"),
                DEX = ReadChild(Asset, "DEX"),
                Bound = GetChild(Asset, "Bound") ~= nil,
            }
        end

        --// What the game's assets say about an item: { Type, Level, Skill,
        --// DMG, DEF, DEX, Bound }, the stats nil when it has none. Nil when
        --// the item is not in the assets or they cannot be read.
        function Recipes:GetItemInfo(Name)
            local Cached = S.ItemInfo[Name]

            if Cached ~= nil then
                return Cached or nil
            end

            local Assets = GetAssets()

            if not Assets then
                return nil
            end

            local Asset = Assets[Name]
            local IsAsset = typeof(Asset) == "Instance" or type(Asset) == "table"
            local Info = IsAsset and ReadItemInfo(Asset) or false

            S.ItemInfo[Name] = Info
            return Info or nil
        end

        --// The item's type for filtering; UNKNOWN_TYPE when it has none.
        function Recipes:GetItemType(Name)
            local Info = self:GetItemInfo(Name)
            return Info and Info.Type or UNKNOWN_TYPE
        end

        local function ReadRecipe(Recipe)
            local Skill = Recipe:FindFirstChild("CraftingSkill")
            local CraftType = Recipe:FindFirstChild("CraftType")

            if not Skill or not CraftType then
                return nil
            end

            local Materials = {}

            for _, Child in ipairs(Recipe:GetChildren()) do
                if not NON_MATERIALS[Child.Name]
                    and (Child:IsA("NumberValue") or Child:IsA("IntValue"))
                    and Child.Value > 0
                then
                    table.insert(Materials, { Name = Child.Name, Amount = Child.Value })
                end
            end

            table.sort(Materials, function(A, B)
                return A.Name < B.Name
            end)

            return {
                Name = Recipe.Name,
                CraftType = tostring(CraftType.Value),
                Skill = tonumber(Skill.Value) or 0,
                Materials = Materials,
            }
        end

        --// Watches the folder so a recipe added or removed (or the folder
        --// being replaced) is read again on the next question.
        local function GetCache()
            local Folder = Replicated:FindFirstChild("CraftingRecipes")

            if Folder ~= S.Folder then
                for _, Connection in ipairs(S.Connections) do
                    Connection:Disconnect()
                end

                table.clear(S.Connections)
                S.Folder = Folder
                S.Cache = nil

                if Folder then
                    local function Invalidate()
                        S.Cache = nil
                    end

                    table.insert(S.Connections, Folder.ChildAdded:Connect(Invalidate))
                    table.insert(S.Connections, Folder.ChildRemoved:Connect(Invalidate))
                end
            end

            if not S.Cache then
                S.Cache = {}

                for _, Recipe in ipairs(Folder and Folder:GetChildren() or {}) do
                    local Parsed = ReadRecipe(Recipe)

                    if Parsed then
                        S.Cache[Parsed.Name] = Parsed
                    end
                end
            end

            return S.Cache
        end

        function Recipes:Get(Name)
            return GetCache()[Name]
        end

        --// Every recipe, easiest first.
        function Recipes:GetAll()
            local List = {}

            for _, Recipe in pairs(GetCache()) do
                table.insert(List, Recipe)
            end

            table.sort(List, function(A, B)
                if A.Skill ~= B.Skill then
                    return A.Skill < B.Skill
                end

                return A.Name < B.Name
            end)

            return List
        end

        --// Every material any recipe uses, sorted.
        function Recipes:GetMaterialNames()
            local Seen = {}
            local Names = {}

            for _, Recipe in pairs(GetCache()) do
                for _, Material in ipairs(Recipe.Materials) do
                    if not Seen[Material.Name] then
                        Seen[Material.Name] = true
                        table.insert(Names, Material.Name)
                    end
                end
            end

            table.sort(Names)
            return Names
        end

        function Recipes:GetSkillValue()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            return PlayerStats and PlayerStats:FindFirstChild(SKILL_STAT)
        end

        function Recipes:GetSkill()
            local Skill = self:GetSkillValue()
            return Skill and tonumber(Skill.Value) or 0
        end

        function Recipes:GetInventoryText()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Inventory = PlayerStats and PlayerStats:FindFirstChild("Inventory")
            return Inventory and Inventory.Value or ""
        end

        --// Item name -> count, from the "Name|Amount,Name|Amount" string.
        function Recipes:GetInventory()
            local Counts = {}

            for Item in string.gmatch(self:GetInventoryText(), "([^,]+)") do
                local Name, Amount = string.match(Item, "([^|]+)|(.+)")

                if Name then
                    Counts[Name] = tonumber(Amount) or 0
                end
            end

            return Counts
        end

        --// Material name -> how many Material Reserve keeps back.
        function Recipes:GetReserves()
            local Reserves = {}

            for _, Entry in ipairs(CONFIG.SMITH_RESERVES or {}) do
                Reserves[Entry.Name] = tonumber(Entry.Keep) or 0
            end

            return Reserves
        end

        --// Where one recipe of the list stands:
        --//   Known      the game has this recipe
        --//   Locked     SmithingSkill is below its requirement
        --//   Have / Target / Remaining  of the crafted item
        --//   Craftable  crafts the materials allow, after the reserves
        --//   Short      the first material holding it back { Name, Have, Need }
        function Recipes:Describe(Entry, Inventory, Reserves, Skill)
            local Recipe = self:Get(Entry.Name)
            local Have = Inventory[Entry.Name] or 0
            local Target = tonumber(Entry.Target) or 0
            local State = {
                Name = Entry.Name,
                Recipe = Recipe,
                Known = Recipe ~= nil,
                Have = Have,
                Target = Target,
                Remaining = math.max(0, Target - Have),
                Skill = Skill,
                Locked = false,
                Craftable = 0,
                Short = nil,
            }

            if not Recipe then
                return State
            end

            State.Locked = Recipe.Skill > Skill

            local Craftable = math.huge

            for _, Material in ipairs(Recipe.Materials) do
                local Usable = math.max(0, (Inventory[Material.Name] or 0) - (Reserves[Material.Name] or 0))
                local Count = math.floor(Usable / Material.Amount)

                if Count < Craftable then
                    Craftable = Count
                end

                if Count < 1 and not State.Short then
                    State.Short = { Name = Material.Name, Have = Usable, Need = Material.Amount }
                end
            end

            State.Craftable = Craftable == math.huge and State.Remaining or Craftable
            return State
        end

        --// Every recipe in the Recipe Priority list, in order.
        function Recipes:GetPlan()
            local Inventory = self:GetInventory()
            local Reserves = self:GetReserves()
            local Skill = self:GetSkill()
            local Plan = {}

            for _, Entry in ipairs(CONFIG.SMITH_RECIPES or {}) do
                table.insert(Plan, self:Describe(Entry, Inventory, Reserves, Skill))
            end

            return Plan
        end

        --// The first recipe in priority that can be crafted now and is not
        --// done, skipping any IsPaused(Name) reports. Also returns the plan.
        function Recipes:PickNext(IsPaused)
            local Plan = self:GetPlan()

            for _, State in ipairs(Plan) do
                if State.Known
                    and not State.Locked
                    and State.Remaining > 0
                    and State.Craftable > 0
                    and not IsPaused(State.Name)
                then
                    return State, Plan
                end
            end

            return nil, Plan
        end

        Context.Lifetime.OnEnd(function()
            Context.Lifetime.Disconnect(S.Connections)
        end)

        return Recipes
    end,
}
