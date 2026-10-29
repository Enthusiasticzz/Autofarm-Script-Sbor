return {
    Name = "Heartbeat",
    Dependencies = {},

    Start = function(Context)
        local Heartbeat = {
            Name = "Heartbeat",
            Connection = nil,
            --// Feature -> { Count, Until } while its Update is failing. A feature
            --// that throws is skipped until Until, so one broken loop cannot
            --// throw sixty errors a second and drag the whole game down. It is
            --// retried after a pause that grows with each failure, and the
            --// first few are reported, so a transient error is not fatal.
            Failing = {},
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
                --// A run that ended while this connection was still bound stops
                --// itself instead of touching state a newer run may own.
                local Lifetime = Context.Lifetime

                if Lifetime and Lifetime.Alive == false then
                    self:Destroy()
                    return
                end

                for _, Feature in ipairs(Features or {}) do
                    if type(Feature.Update) == "function" then
                        --// Keyed by the feature itself when it carries no Name.
                        local Name = Feature.Name
                        local Key = Name or Feature
                        local State = self.Failing[Key]
                        local Now = os.clock()

                        if not State or Now >= State.Until then
                            local Ok, Error = xpcall(Feature.Update, debug.traceback, Feature, DeltaTime)

                            if Ok then
                                self.Failing[Key] = nil
                            else
                                State = State or { Count = 0 }
                                State.Count += 1
                                --// 2 s, 4 s, 8 s ... capped at 30 s.
                                State.Until = Now + math.min(2 ^ State.Count, 30)
                                self.Failing[Key] = State

                                if State.Count <= 3 then
                                    warn(
                                        "[AIC] "
                                        .. tostring(Name or "A feature")
                                        .. " failed to update: "
                                        .. tostring(Error)
                                    )
                                end
                            end
                        end
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
