-- Descriptions is the one list of the short help line shown under each
-- control's name in the main window (UI/Utils draws it). Keyed by the
-- control's label, in any case; a label not listed shows no line.
-- It starts before any module adds controls, so every one finds its text.
return {
    Name = "Descriptions",
    Dependencies = {"Runtime"},

    Start = function(Context)
        local DESCRIPTIONS = {
            --// Features
            ["Auto Farm"] = "Walks the waypoint route, then fights the Enemy Priority targets",
            ["Auto Block"] = "Blocks anyone off the Block Whitelist, then leaves the server",
            ["Auto Confirm Block"] = "Presses Block in Roblox's block dialog for you (executor only)",
            ["Whitelist Skips Safety"] = "Block Whitelist players never make you leave a server",
            ["Safe Combat"] = "Fights from outside enemy weapon reach; off fights up close",
            ["Jump While Fighting"] = "Jumps over something in the way while chasing a target; off keeps it on the ground in a fight",
            ["Auto Find"] = "Skips the waypoint route and goes straight for targets",
            ["Ignore Farm Zone"] = "Fights and mines anywhere, not only inside farm zones",
            ["Auto Patrol"] = "Walks around the farm zone looking for targets when none are near",
            ["Return To Farm Zone"] = "Walks back into the farm zone after leaving it",
            ["Auto Skill"] = "Uses the weapon skill on the target when it is ready",
            ["Gather Mobs"] = "Pulls a pack of mobs together, then hits them all with the skill",
            ["Refill Booster"] = "Resets the character when a selected booster runs out to refill it",
            ["Safe Booster Reset"] = "Refill Booster waits until no mob is hitting you",
            ["Refresh Boosters"] = "Looks again for boosters in PlayerStats and lists any new ones",
            ["Auto Start Game"] = "Clicks through the title screen into the game",
            ["Dismiss Death Prompt"] = "Presses No on the confirm notice that appears when you die",
            ["FPS Boost"] = "Turns off shadows, effects, particles and lights for more FPS",
            ["Party System"] = "Follows the Leader to their server with the tp friend command",
            ["Waypoint Loop"] = "Farms only the zones paired with waypoints, walking between them",
            ["Boss Route"] = "Walks the saved boss stops, fights at each and resets on its own timers",
            ["Debug Visualizer"] = "Draws zones, waypoints and targets in the world",
            ["Auto Mining"] = "Mines the Ore Priority ores inside mine zones",
            ["Auto Smithing"] = "Crafts the Recipe Priority recipes at a smithing table",
            ["Leave On Danger Group"] = "Blocks, then leaves when a Danger Group member joins",
            ["Join Alerts"] = "Notifies you when someone off the Block Whitelist joins",
            ["Follower Guard"] = "Kicks you out of the game when one player keeps joining yours",

            --// Boss Route
            ["Always Wait Before Reset"] = "Takes the Reset (s) pause before every reset, even when no EXP would be lost",
            ["Add Boss Stop Here"] = "Saves a boss stop at the character's position",
            ["Clear Boss Route"] = "Removes every boss stop",
            ["Edit Boss Stop"] = "Picks which boss stop the boxes below edit",
            ["Boss Stop Name"] = "The name shown for this boss stop",
            ["Teleport Waypoint #"] = "Game waypoint to teleport to before walking here (0 walks the whole way)",
            ["Wait At Spot (s)"] = "Seconds stood still at the stop before the fight starts",
            ["Wait After Reset (s)"] = "Seconds after the reset respawns the character before the next stop starts",
            ["Reset After Kill"] = "Resets the character once the boss is down, so the next stop starts from spawn",
            ["Engage Radius"] = "How far from the stop a boss is picked up",
            ["Add Boss Name"] = "Adds a boss from the mobs around you to the selected stop",
            ["Boss Names"] = "The bosses this stop fights; empty fights anything at the spot",
            ["Refresh Nearby Bosses"] = "Rebuilds the Add Boss Name list from the mobs around you",
            ["Move Stop Here"] = "Moves the selected boss stop to the character's position",
            ["Remove Stop"] = "Removes the selected boss stop",
            ["Loop Route"] = "Starts again at the first boss stop after the last one",

            --// Debug Visualizer
            ["Debug Waypoints"] = "Shows waypoint markers and the route",
            ["Debug Farm Zones"] = "Shows the farm zone circles",
            ["Debug Deadzones"] = "Shows the deadzone circles",
            ["Debug Mine Zones"] = "Shows the mine zone circles",
            ["Debug Ore Status"] = "Labels each ore with what Auto Mining thinks of it",
            ["Debug Smithing Tables"] = "Labels each smithing table with its state",
            ["Radius Billboard Labels"] = "Shows each zone's number and radius over it",

            --// Combat and targets
            ["Retreat At HP%"] = "Backs off to heal below this much health (0 = never)",
            ["Auto Heal at HP%"] = "Drinks the last used potion at or below this much health",
            ["Execute Charge at HP%"] = "Finishes a target below this health instead of retreating",
            ["Safe Enemy Range"] = "Extra gap kept from enemy weapons (Safe Combat on)",
            ["Close Combat Range"] = "How far from the target it fights with Safe Combat off",
            ["Target Type"] = "Tie break between targets of equal priority",
            ["Refresh Detected Targets"] = "Reloads the player and mob lists below",
            ["Open Mob Dictionary"] = "Every mob and boss: health, speed, threat and more",
            ["Enemy Priority"] = "Targets fought first to last",
            ["Min Mobs"] = "Fewest mobs that make a pack worth gathering",
            ["Max Mobs"] = "Most mobs pulled into one pack",
            ["Gather Radius"] = "How close together mobs must be to count as a pack",

            --// Auto Block
            ["Leave Instead Of Block"] = "Never blocks the stranger; closes the game once Block Delay runs out",
            ["Block Delay (s)"] = "Seconds a stranger may stay before being blocked or left",
            ["Random Leave Delay"] = "Every leave waits a random 2-4 s first, so nothing leaves the instant someone joins",
            ["Block Whitelist"] = "Players Auto Block leaves alone",
            ["Add Player In Server"] = "Adds someone in this server to the list above",
            ["User ID"] = "A Roblox UserId to add to the list",
            ["Add User ID"] = "Adds the UserId typed above",
            ["Add Everyone Here"] = "Whitelists every player in this server",
            ["Refresh Player List"] = "Reloads the players in the dropdown",
            ["Clear Whitelist"] = "Removes everyone from the Block Whitelist",

            --// Webhook
            ["Discord Logging"] = "Sends the start and end reports; off sends nothing at all",
            ["Webhook URL"] = "Discord webhook the report is posted to",
            ["Ping User ID"] = "UserId to mention, everyone, or blank for none",
            ["Ping Duo User ID"] = "Duo's UserId to mention too, or blank for none",
            ["Duo Username"] = "Name reported next to yours; blank when solo",
            ["Report Format"] = "Which report to post: Event Currency or EXP Grind",
            ["EC Item Name"] = "Inventory item counted as EC; blank uses the tracked currency",
            ["Send Report"] = "Posts the report for this session now",
            ["Reset Session"] = "Starts a new report: new start time and starting numbers",

            --// Server
            ["Rejoin"] = "Joins this same server again",
            ["Server Hop"] = "Joins another public server with a free slot",
            ["Copy Job ID"] = "Copies this server's Job ID",
            ["Job ID"] = "A server's Job ID to join",
            ["Join Job ID"] = "Joins the server typed above",
            ["Open Server Browser"] = "Lists public servers to pick one from",
            ["Danger Groups"] = "Group IDs whose members make you leave",
            ["Group ID"] = "A Roblox group ID to add",
            ["Add Group ID"] = "Adds the group ID typed above",
            ["Danger Whitelist"] = "Players Leave On Danger Group stays for",
            ["Clear Danger Whitelist"] = "Removes everyone from the Danger Whitelist",

            --// Teleport
            ["Door"] = "A door's T1 or T2 point to teleport to",
            ["Teleport To Door"] = "Teleports to the door point picked above",
            ["Refresh Doors"] = "Reloads the doors from the Interactions folder",
            ["Waypoint"] = "One of the game's waypoints that has loaded in",
            ["Teleport To Waypoint"] = "Teleports to the waypoint picked above",
            ["Refresh Waypoints"] = "Reloads the waypoints from the Waypoints folder",
            ["Waypoint Number"] = "Any waypoint number, even one not loaded in yet",
            ["Teleport To Number"] = "Teleports straight to the waypoint number typed above",

            --// Quest
            ["Quest ID"] = "The ID of the quest to take, as the game names it",
            ["Assign Quest"] = "Asks the game to give you the quest typed above",
            ["Quest ESP"] = "Highlights the quest targets below and shows how far each one is",
            ["Quest Targets"] = "Names of items in QuestItems to find, comma separated (case, spaces and symbols ignored)",
            ["Show All Quest Items"] = "Tags every item in the QuestItems folder, not just the names typed below",
            ["Rescan Quest Targets"] = "Looks through the QuestItems folder for the quest targets again",
            ["Copy Quest Info"] = "Copies what the game shows of your quest, to set targets automatically later",
            ["Clear Log"] = "Empties the Player Log",

            --// Party
            ["Set Leader"] = "Picks the player to follow between servers",
            ["Clear Leader"] = "Stops following anyone",

            --// Mining
            ["Ore Priority"] = "Ores mined first to last, each until its Target",
            ["Add Ore"] = "Adds an ore loaded nearby to Ore Priority",
            ["Ore Name"] = "An ore's exact name, for ores not loaded yet",
            ["Add Ore By Name"] = "Adds the ore typed above",
            ["Refresh Ore List"] = "Reloads the ores in the dropdown",
            ["All Mine Zones"] = "Areas Auto Mining works in",
            ["Add Mine Zone Here"] = "Adds a mine zone where you stand",
            ["Edit Mine Zone"] = "Picks the mine zone the radius applies to",
            ["Mine Zone Radius"] = "Size of the picked mine zone",
            ["Clear Mine Zones"] = "Removes every mine zone",

            --// Crafting
            ["Set Smithing Table"] = "Uses the table you stand next to",
            ["Use Nearest Table"] = "Uses whichever table is nearest",
            ["Recipe Priority"] = "Recipes crafted first to last, each until its Target",
            ["Open Recipe Browser"] = "Find recipes, craft now and edit the priority",
            ["Open Asset Explorer"] = "Every item: stats, price, recipe, drops and uses",
            ["Refresh Recipes"] = "Reloads the recipes and materials",
            ["Keep In Inventory"] = "Materials Auto Smithing never uses below this count",
            ["Add Material"] = "Adds a material to keep a reserve of",

            --// Status
            ["Reset Stats"] = "Zeroes stats under 500 points; 500 won't reset (trips the anticheat)",

            --// Profile
            ["Profile"] = "Loads the picked profile",
            ["Profile Name"] = "Name for a new profile",
            ["Create New Profile"] = "Saves a new profile from the current settings",
            ["Save Profile"] = "Saves the current settings to this profile",
            ["Delete Profile"] = "Deletes the selected profile",
            ["Export Save"] = "Copies this profile as text to share",
            ["Import Data"] = "Profile text to import",
            ["Import Save"] = "Creates a profile from the text above",

            --// Waypoints and zones
            ["All Waypoints"] = "The route walked in order before farming; tick Jump to jump at that waypoint",
            ["Add Waypoint Here"] = "Adds a waypoint where you stand",
            ["Waypoint Reach Distance"] = "How close counts as reaching a waypoint",
            ["Hole Check Distance"] = "How far ahead the route looks for a gap to jump (studs)",
            ["Hole Check Step"] = "Gap between ground checks; smaller catches narrow gaps",
            ["Hole Min Depth"] = "A drop at least this deep counts as a hole to jump",
            ["Clear Waypoints"] = "Removes every waypoint",
            ["Pair Waypoint"] = "Picks a waypoint to pair with a farm zone",
            ["Paired Farm Zone"] = "The farm zone the picked waypoint leads to",
            ["All Farm Zones"] = "Areas Auto Farm fights in",
            ["Add Farm Zone Here"] = "Adds a farm zone where you stand",
            ["Edit Farm Zone"] = "Picks the farm zone to change",
            ["Farm Radius"] = "Size of the picked farm zone",
            ["Zone Targets"] = "Targets for the picked zone (empty: Enemy Priority)",
            ["Add Zone Target"] = "Adds a target to the picked zone",
            ["Clear Farm Zones"] = "Removes every farm zone",
            ["All Deadzones"] = "Areas never fought or walked in",
            ["Add Deadzone Here"] = "Adds a deadzone where you stand",
            ["Edit Deadzone"] = "Picks the deadzone to change",
            ["Deadzone Radius"] = "Size of the picked deadzone",
            ["Clear Deadzones"] = "Removes every deadzone",
        }

        Context.UI:SetDescriptions(DESCRIPTIONS)

        return { Name = "Descriptions" }
    end,
}
