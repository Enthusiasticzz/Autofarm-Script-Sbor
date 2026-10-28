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

--// Internal: format and print a log message.
local function Log(level, message, ...)
    local args = {...}
    local formatted = message
    if #args > 0 then
        for _, arg in ipairs(args) do
            formatted = formatted:gsub('%%s', function()
                return tostring(arg)
            end)
        end
    end
    print(LOG_PREFIX, level, formatted)
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
