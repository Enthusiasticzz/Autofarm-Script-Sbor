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

        --// A feature that eats the frame is named in the console, at most once
        --// a second. A freeze that never said which loop caused it is the one
        --// thing that makes this kind of report cost a whole evening.
        local SLOW_FEATURE = 0.008

        --// The first Update of a feature is where its one-time setup happens
        --// (finding a target, opening a table, starting a loop). Running all
        --// of them in the frame the loop starts is the spike that froze the
        --// client the moment the loader reached "STARTING". They are spread
        --// over the first dozen frames instead; from then on every feature
        --// updates every frame as before. Counted in frames, not seconds, so
        --// the spread does not change with the frame rate.
        local FIRST_TICK_SLOTS = 12

        function Heartbeat:Start(Features)
            local RunService =
                Context.Services
                and Context.Services.RunService
                or game:GetService("RunService")

            if self.Connection then
                self.Connection:Disconnect()
            end

            local Watch = { Since = os.clock(), Total = 0, Frames = 0, Worst = 0 }
            local FirstFrame, Frame = {}, 0

            self.Connection = RunService.Heartbeat:Connect(function(DeltaTime)
                --// A run that ended while this connection was still bound stops
                --// itself instead of touching state a newer run may own.
                local Lifetime = Context.Lifetime

                if Lifetime and Lifetime.Alive == false then
                    self:Destroy()
                    return
                end

                Frame += 1

                for Index, Feature in ipairs(Features or {}) do
                    if type(Feature.Update) == "function" then
                        --// Keyed by the feature itself when it carries no Name.
                        local Name = Feature.Name
                        local Key = Name or Feature
                        local Now = os.clock()
                        local Ready = FirstFrame[Key]

                        if Ready == nil then
                            FirstFrame[Key] = 1 + (Index % FIRST_TICK_SLOTS)
                        elseif Frame >= Ready then
                            local State = self.Failing[Key]

                            if not State or Now >= State.Until then
                                local Started = os.clock()
                                local Ok, Error = xpcall(Feature.Update, debug.traceback, Feature, DeltaTime)
                                local Cost = os.clock() - Started

                                Watch.Total += Cost

                                if Cost > Watch.Worst then
                                    Watch.Worst, Watch.Name = Cost, Name
                                end

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
                end

                Watch.Frames += 1

                local Finished = os.clock()

                if Finished - Watch.Since >= 1 then
                    if Watch.Worst >= SLOW_FEATURE then
                        warn(string.format(
                            "[AIC] heartbeat: %s took %.1f ms in one frame (%d features, %.1f ms each on average)",
                            tostring(Watch.Name or "a feature"),
                            Watch.Worst * 1000,
                            #(Features or {}),
                            Watch.Total / math.max(1, Watch.Frames) * 1000
                        ))
                    end

                    Watch.Since, Watch.Total, Watch.Frames, Watch.Worst, Watch.Name = Finished, 0, 0, 0, nil
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
