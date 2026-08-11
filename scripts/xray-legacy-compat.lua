local jsonc = require "luci.jsonc"
local uci = require("luci.model.uci").cursor()

local path = arg[1]
local node_id = arg[2]

if not path or not node_id then
	os.exit(1)
end

local input = assert(io.open(path, "r"))
local config = assert(jsonc.parse(input:read("*a")))
input:close()

local node = uci:get_all("passwall", node_id) or {}

local changed = false
for _, outbound in ipairs(config.outbounds or {}) do
	local stream = outbound.streamSettings
	if stream then
		if stream.network == "raw" then
			stream.network = "tcp"
			changed = true
		end
		if stream.method == "raw" then
			stream.method = nil
			stream.network = "tcp"
			changed = true
		end
	end

	if outbound.protocol == "vless" then
		local settings = outbound.settings or {}
		local vnext = settings.vnext
		if settings.address or type(vnext) ~= "table" or #vnext == 0 then
			outbound.settings = {
				vnext = {
					{
						address = settings.address or node.address,
						port = tonumber(settings.port or node.port),
						users = {
							{
								id = settings.id or node.uuid,
								encryption = settings.encryption or node.encryption or "none",
								flow = settings.flow or node.flow,
								level = settings.level or 0
							}
						}
					}
				}
			}
			changed = true
		end
	end

	if outbound.protocol == "shadowsocks" then
		local settings = outbound.settings or {}
		local servers = settings.servers
		if settings.address or type(servers) ~= "table" or #servers == 0 then
			outbound.settings = {
				servers = {
					{
						address = settings.address or node.address,
						port = tonumber(settings.port or node.port),
						method = settings.method or node.method,
						password = settings.password or node.password,
						level = settings.level or 0
					}
				}
			}
			changed = true
		end
	end
end

if changed then
	local output = assert(io.open(path, "w"))
	output:write(jsonc.stringify(config, 1))
	output:close()
end
