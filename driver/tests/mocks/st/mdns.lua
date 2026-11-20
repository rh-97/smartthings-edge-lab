-- Stand-in for st.mdns. A test sets _G.MDNS_MOCK to decide what discover says:
--   nil                 -> no services answered (what a hub without Bonjour does)
--   { found = { ... } }  -> these service events
--   { error = "msg" }    -> discover returns nil, msg
--   { raises = "msg" }   -> discover raises
local M = {}

function M.discover(service, domain)
  assert(service == "_stlab._tcp", "unexpected mDNS service " .. tostring(service))
  assert(domain == "local", "unexpected mDNS domain " .. tostring(domain))
  local mock = _G.MDNS_MOCK
  if mock == nil then return { found = {} } end
  if mock.raises then error(mock.raises, 0) end
  if mock.error then return nil, mock.error end
  return { found = mock.found or {} }
end

return M
