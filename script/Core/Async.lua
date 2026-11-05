-- One cancellable coroutine per worker. Tokens reject stale completions;
-- cancellation also releases the suspended client thread (not server work).
return {
    Name = "Async",
    Dependencies = {},
    Start = function(Context)
        local Async = {}
        local Lifetime = Context.Lifetime
        local function Alive() return not Lifetime or Lifetime.Alive ~= false end
        local function CancelThread(Thread)
            if Thread then pcall(task.cancel, Thread) end
        end
        function Async:Worker()
            local Worker = { Job = nil }
            function Worker:IsRunning() return self.Job ~= nil end
            function Worker:Cancel()
                local Job = self.Job
                self.Job = nil
                if Job then
                    CancelThread(Job.Timer)
                    CancelThread(Job.Thread)
                end
            end
            function Worker:Start(Run, Timeout, Complete, Expired)
                if self.Job or not Alive() then return false end
                local Job = {}
                self.Job = Job
                Job.Thread = coroutine.create(function()
                    local Result = table.pack(pcall(Run))
                    if self.Job ~= Job or not Alive() then return end
                    self.Job = nil
                    Job.Thread = nil
                    CancelThread(Job.Timer)
                    Job.Timer = nil
                    if Complete then Complete(table.unpack(Result, 1, Result.n)) end
                end)
                if Timeout then
                    Job.Timer = task.delay(Timeout, function()
                        if self.Job ~= Job then return end
                        Job.Timer = nil -- Do not cancel the timeout callback itself.
                        self:Cancel()
                        if Alive() and Expired then Expired() end
                    end)
                end
                task.spawn(Job.Thread)
                return true
            end
            if Lifetime then Lifetime.OnEnd(function() Worker:Cancel() end) end
            return Worker
        end
        return Async
    end,
}
