-- Logger - optional verbose logging system for debugging silent failures.
--
-- Usage:
--   local Logger = require(script.Parent.Logger)
--   Logger.warn('PlayerStats missing')
--   Logger.debug('Checking target at %s', targetPosition)
--   Logger.error('Combat failed: %s', errorMessage)
--
-- Log levels (set CONFIG.VERBOSE_LOGGING to enable DEBUG):
--   [AIC] INFO    - normal operation messages
--   [AIC] WARN    - things that might be problems
--   [AIC] DEBUG   - verbose diagnostic info (opt-in, requires VERBOSE_LOGGING)
--   [AIC] ERROR   - failures and exceptions
--
-- All logging goes through print() so it appears in the executor output.
-- The logger is lightweight and has minimal overhead at INFO+ levels.

local Logger = {}

Logger.Name = "Logger"
Logger.Dependencies = {"Runtime"}

--// Internal state
local VERBOSE = false
local LOG_PREFIX = '[AIC]'

--// Set by Runtime after CONFIG is available.
function Logger.SetVerbose(enabled)
    VERBOSE = enabled == true
end

--// Internal: fill each "%s" from the arguments, in order.
--//
--// This used to be one gsub call per argument, and gsub replaces every
--// match it finds: the first argument filled the whole line, so
--// "equip %s: %s (was %s)" read "equip Weapon: Weapon (was Weapon)" and the
--// other arguments were dropped. One pass with a counter gives each
--// placeholder its own argument, and a line with more placeholders than
--// arguments keeps the leftover ones instead of losing text.
local function Format(message, args)
    local Index = 0

    local Text = tostring(message):gsub('%%s', function()
        Index += 1

        local Value = args[Index]

        if Value == nil then
            return '%s'
        end

        return tostring(Value)
    end)

    return Text
end

--// Internal: format and print a log message.
local function Log(level, message, ...)
    print(LOG_PREFIX, level, Format(message, table.pack(...)))
end

--// Log at INFO level. Always shown.
function Logger.info(message, ...)
    Log('INFO', message, ...)
end

--// Log at WARN level. Always shown.
function Logger.warn(message, ...)
    Log('WARN', message, ...)
end

--// Log at DEBUG level. Only shown when VERBOSE_LOGGING is true.
function Logger.debug(message, ...)
    if VERBOSE then
        Log('DEBUG', message, ...)
    end
end

--// Log at ERROR level. Always shown with error formatting.
function Logger.error(message, ...)
    Log('ERROR', message, ...)
end

--// Log with a traceback. Useful for debugging unexpected states.
function Logger.errorWithTrace(message, ...)
    Log('ERROR', message .. '\n' .. debug.traceback(2), ...)
end

--// Check if debug logging is enabled.
function Logger.IsDebugEnabled()
    return VERBOSE
end

--// Start: expose the logger on Context and honour CONFIG.VERBOSE_LOGGING.
function Logger.Start(Context)
    local CONFIG = Context and Context.CONFIG

    Logger.SetVerbose(type(CONFIG) == "table" and CONFIG.VERBOSE_LOGGING == true)

    return Logger
end

return Logger
