-- Stand-in for the hub's `log` module.
local M = {}
for _, level in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  M[level] = function(msg)
    if level ~= "trace" and (level ~= "debug" or os.getenv("VERBOSE")) then
      print(string.format("  [%s] %s", level, tostring(msg)))
    end
  end
end
return M
