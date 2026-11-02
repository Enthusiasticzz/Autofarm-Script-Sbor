-- TimeZones - the clock the Discord reports are stamped with.
--
-- A report says when it was posted, in a zone the player picked from the
-- Webhook section, e.g. "03:41 PM EST". os.date is the machine's own clock, so
-- the UTC hour is shifted by the zone's offset instead of trusting it.
--
-- A zone that keeps daylight saving follows the calendar by itself: US Eastern
-- prints EDT all summer and goes back to EST on the first Sunday in November
-- without anyone changing a setting.
--
-- Offsets are hours BEHIND UTC (US Eastern is 5 on standard time), which is the
-- sign os.date("!...") needs when the stamp is taken from `Epoch - Offset`.
return {
    Name = "TimeZones",

    Start = function(Context)
        local TimeZones = {}

        --// Std is the standard offset, Dst the daylight one (nil when the zone
        --// keeps none), and Rule says which calendar the switches follow:
        --//   "US"   second Sunday in March -> first Sunday in November
        --//   "EU"   last Sunday in March -> last Sunday in October
        --//   "AU"   first Sunday in October -> first Sunday in April
        --//   "NONE" no daylight saving, ever
        TimeZones.Zones = {
            { Name = "US Eastern", Std = 5, Dst = 4, Rule = "US", StdAbbr = "EST", DstAbbr = "EDT" },
            { Name = "US Central", Std = 6, Dst = 5, Rule = "US", StdAbbr = "CST", DstAbbr = "CDT" },
            { Name = "US Mountain", Std = 7, Dst = 6, Rule = "US", StdAbbr = "MST", DstAbbr = "MDT" },
            { Name = "US Arizona", Std = 7, Rule = "NONE", StdAbbr = "MST" },
            { Name = "US Pacific", Std = 8, Dst = 7, Rule = "US", StdAbbr = "PST", DstAbbr = "PDT" },
            { Name = "Alaska", Std = 9, Dst = 8, Rule = "US", StdAbbr = "AKST", DstAbbr = "AKDT" },
            { Name = "Hawaii", Std = 10, Rule = "NONE", StdAbbr = "HST" },
            { Name = "UTC", Std = 0, Rule = "NONE", StdAbbr = "UTC" },
            { Name = "UK", Std = 0, Dst = -1, Rule = "EU", StdAbbr = "GMT", DstAbbr = "BST" },
            { Name = "Central Europe", Std = -1, Dst = -2, Rule = "EU", StdAbbr = "CET", DstAbbr = "CEST" },
            { Name = "Australia Eastern", Std = -10, Dst = -11, Rule = "AU", StdAbbr = "AEST", DstAbbr = "AEDT" },
        }

        TimeZones.Default = TimeZones.Zones[1].Name
        TimeZones.Names = {}

        local ZoneByName = {}

        for _, Zone in ipairs(TimeZones.Zones) do
            table.insert(TimeZones.Names, Zone.Name)
            ZoneByName[Zone.Name] = Zone
        end

        --// Zeller's congruence: 0 = Saturday, 1 = Sunday, ... 6 = Friday.
        local function Weekday(Year, Month, Day)
            if Month < 3 then
                Year -= 1
                Month += 12
            end

            local K = Year % 100
            local J = math.floor(Year / 100)

            return (Day + math.floor(13 * (Month + 1) / 5) + K
                + math.floor(K / 4) + math.floor(J / 4) + 5 * J) % 7
        end

        local function DaysInMonth(Year, Month)
            local Days = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[Month]
            local Leap = Year % 4 == 0 and (Year % 100 ~= 0 or Year % 400 == 0)

            if Month == 2 and Leap then
                return 29
            end

            return Days
        end

        --// The Nth Sunday of a month, as a day number. The first Sunday is
        --// today when the 1st is a Sunday, so the walk from the 1st is zero
        --// days there.
        local function NthSunday(Year, Month, N)
            local First = 1 + (8 - Weekday(Year, Month, 1)) % 7

            return First + (N - 1) * 7
        end

        local function LastSunday(Year, Month)
            local Last = DaysInMonth(Year, Month)

            return Last - (Weekday(Year, Month, Last) + 6) % 7
        end

        --// Whether the zone is on daylight time on this date. The switch is
        --// taken at the start of the day it falls on rather than at the exact
        --// hour, which only matters for the few hours either side of it.
        local function IsDST(Zone, Year, Month, Day)
            if Zone.Dst == nil then
                return false
            end

            if Zone.Rule == "US" then
                if Month < 3 or Month > 11 then
                    return false
                end

                if Month == 3 then
                    return Day >= NthSunday(Year, 3, 2)
                end

                if Month == 11 then
                    return Day < NthSunday(Year, 11, 1)
                end

                return true
            end

            if Zone.Rule == "EU" then
                if Month < 3 or Month > 10 then
                    return false
                end

                if Month == 3 then
                    return Day >= LastSunday(Year, 3)
                end

                if Month == 10 then
                    return Day <= LastSunday(Year, 10)
                end

                return true
            end

            if Zone.Rule == "AU" then
                if Month > 10 or Month < 4 then
                    return true
                end

                if Month == 10 then
                    return Day >= NthSunday(Year, 10, 1)
                end

                if Month == 4 then
                    return Day < NthSunday(Year, 4, 1)
                end

                return false
            end

            return false
        end

        --// The zone a name belongs to; an unknown or blank name is the
        --// default, so a save from before the picker existed still stamps.
        function TimeZones.Get(Name)
            return ZoneByName[Name] or ZoneByName[TimeZones.Default]
        end

        function TimeZones.IsDST(Name, Year, Month, Day)
            return IsDST(TimeZones.Get(Name), Year, Month, Day)
        end

        --// Hours behind UTC right now (4 or 5 for US Eastern).
        function TimeZones.Offset(Name, Epoch)
            local Zone = TimeZones.Get(Name)
            local Utc = os.date("!*t", Epoch or os.time())

            return IsDST(Zone, Utc.year, Utc.month, Utc.day) and Zone.Dst or Zone.Std
        end

        --// "03:41 PM EST" - the clock at Epoch (or now) in the zone named,
        --// with the abbreviation the calendar is on: EDT in summer, EST after
        --// the clocks go back.
        function TimeZones.Stamp(Name, Epoch)
            local Zone = TimeZones.Get(Name)
            local Now = Epoch or os.time()
            local Utc = os.date("!*t", Now)
            local Daylight = IsDST(Zone, Utc.year, Utc.month, Utc.day)
            local Offset = Daylight and Zone.Dst or Zone.Std
            local Clock = os.date("!%I:%M %p", Now - Offset * 3600)

            return Clock .. " " .. (Daylight and Zone.DstAbbr or Zone.StdAbbr)
        end

        Context.TimeZones = TimeZones

        return TimeZones
    end,
}
