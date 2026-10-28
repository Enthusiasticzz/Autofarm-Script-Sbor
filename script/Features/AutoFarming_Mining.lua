-- AutoFarming_Mining - reserved for the mining step split.
--
-- The actual MiningStep implementation lives in Features/AutoMining.lua and is
-- exposed on AICFeature.MiningStep. This module is the hook point for moving
-- that logic here; it is a no-op for now so the split stays structural.
return {
    Name = "AutoFarming_Mining",
    Dependencies = {"AutoFarming"},

    Start = function(Context)
        return { Name = "AutoFarming_Mining" }
    end,
}
