return {
	Name = "SafeBoosterReset",
	IsFeature = true,
	Dependencies = {"Runtime", "SaveConfig", "ProfileManager", "Components", "Async"},
	Start = function(Context)
		local Runtime = Context.Runtime
		local Services = Context.Services
		local Player = Context.Player
		local Replicated = Services.Replicated
		local FeatureState = Context.Feature
		local AICFeature = Context.AICFeature
		local AICUI = Context.AICUI
		local UIRef = Context.UIRef
		local NotifyAction = Context.NotifyAction
		local SetupWorker = Context.Async:Worker()
		local BoostConnection
		local function DisconnectBoost()
			if BoostConnection then BoostConnection:Disconnect(); BoostConnection = nil end
		end
		Context.Lifetime.OnEnd(DisconnectBoost)

		local Feature = {
			Name = "SafeBoosterReset",
			IsFeature = true,
		}

		--// The connection stays alive for the whole session, so the toggle
		--// has to be read at fire time, not here.
		local function SafeBoosterReset(Boost)
			if Context.Lifetime.Alive == false or not FeatureState.SafeBoosterReset.Enabled then
				return
			end

			if Boost.Value <= 0 then
				NotifyAction("SAFE BOOSTER RESET", "Boost expired, no action.")
				return
			end

			local DamageTags = Replicated:FindFirstChild("PlayerDamageTags")
			if DamageTags and DamageTags:FindFirstChild(Player.Name .. "MobDamaged") then
				return
			end

			local _, Humanoid = Runtime:GetCharacter()

			if Humanoid then
				Humanoid.Health = 0
			end
		end

		function Feature.SafeBoosterReset()
			SetupWorker:Cancel()
			DisconnectBoost()
			SetupWorker:Start(function()
				local PlayerStats = Player:WaitForChild("PlayerStats", 30)
				return PlayerStats and PlayerStats:FindFirstChild("Boost")
			end, 30, function(Ok, ExpBoost)
				if not Ok or not ExpBoost then return end
				BoostConnection = ExpBoost:GetPropertyChangedSignal("Value"):Connect(function()
					SafeBoosterReset(ExpBoost)
				end)
			end)
		end

		AICFeature.SafeBoosterReset = Feature.SafeBoosterReset

		function Feature:Update()
		end

		--// The value is saved through Feature.SafeBoosterReset.Enabled like
		--// every other toggle and restored on load by updateFeatureButtons.
		AICUI.BindFeatureToggle("SafeBoosterReset", "Safe Booster Reset", nil, UIRef.BoosterSection)
		Feature.SafeBoosterReset()

		return Feature
	end,
}
