return {
    Name = "Heartbeat",
    Dependencies = {},

    Start = function(Context)
        local Heartbeat = {
            Name = "Heartbeat",
            Connection = nil,
        }

        function Heartbeat:Start(Features)
            local RunService =
                Context.Services
                and Context.Services.RunService
                or game:GetService("RunService")

            if self.Connection then
                self.Connection:Disconnect()
            end

            self.Connection = RunService.Heartbeat:Connect(function(DeltaTime)
                for _, Feature in ipairs(Features or {}) do
                    if type(Feature.Update) == "function" then
                        Feature:Update(DeltaTime)
                    end
                end
            end)
        end

        function Heartbeat:Destroy()
            if self.Connection then
                self.Connection:Disconnect()
                self.Connection = nil
            end
        end

        return Heartbeat
    end,
}
