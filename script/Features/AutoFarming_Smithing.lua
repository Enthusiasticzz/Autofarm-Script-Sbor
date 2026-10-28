-- AutoFarming_Smithing - reserved for the smithing step split.
--
-- The actual SmithingStep implementation lives in Features/AutoSmithing.lua and
-- is exposed on AICFeature.SmithingStep. This module is the hook point for
-- moving that logic here; it is a no-op for now so the split stays structural.
return {
    Name = "AutoFarming_Smithing",
    Dependencies = {"AutoFarming"},

    Start = function(Context)
        return { Name = "AutoFarming_Smithing" }
    end,
}
