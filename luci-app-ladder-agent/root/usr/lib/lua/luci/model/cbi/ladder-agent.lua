-- CBI form for OpenWrt 19.07. Current LuCI uses the JavaScript view instead.

local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"

local m = Map("ladder-agent", translate("LadderAirport Agent"),
	translate("Configure the local LadderAirport node agent. Save restarts the service. On 21.02 and later, use the JavaScript pages."))

local s = m:section(NamedSection, "main", "ladder-agent", translate("Main"))
s.addremove = false

local function flag(option, title, description, default)
	local o = s:option(Flag, option, title, description)
	o.default = default or "0"
	o.rmempty = false
	return o
end

local function value(option, title, description)
	local o = s:option(Value, option, title, description)
	o.rmempty = true
	return o
end

flag("enabled", translate("Enable"),
	translate("Start ladder-agent on boot when the init script is enabled."))

local url = value("panel_url", translate("Panel URL"),
	translate("HTTPS base URL of the Panel, e.g. https://panel.example.com"))
url.rmempty = false

local node = value("node_id", translate("Node ID"),
	translate("Node ID from the Panel nodes page."))
node.rmempty = false

local token = value("token", translate("Control token"),
	translate("Long-lived LADDER_TOKEN. Leave empty and set enroll token once to exchange automatically."))
token.password = true

local enroll = value("enroll_token", translate("Enroll token"),
	translate("One-time enrollment token. Cleared after a successful enroll."))
enroll.password = true

flag("uplink", translate("Uplink mode"),
	translate("Agent dials Panel over HTTP/WebSocket (recommended on routers behind NAT)."), "1")
flag("uplink_ws", translate("Uplink WebSocket"),
	translate("Realtime channel; disable to use HTTP report/config polling only."), "1")
flag("uplink_serve_grpc", translate("Also serve gRPC"),
	translate("Keep mTLS gRPC listen in uplink mode (requires management TLS materials)."))

local listen = value("listen", translate("gRPC listen"),
	translate("Used when push mode or uplink_serve_grpc is enabled."))
listen.default = "0.0.0.0:50051"
listen.placeholder = "0.0.0.0:50051"
listen.rmempty = false

local data = value("data_dir", translate("Data directory"))
data.default = "/var/lib/ladder-agent"
data.rmempty = false

value("report_address", translate("Report address"),
	translate("Optional address reported to Panel; leave empty for auto."))

local egress = s:option(ListValue, "egress_interface", translate("Egress interface"),
	translate("Logical network used as the proxy egress on this router. The agent binds sing-box to that network's current L3 device. Empty follows the Panel."))
egress.rmempty = true
egress:value("", translate("Follow Panel"))
uci:foreach("network", "interface", function(sec)
	local name = sec[".name"]
	if name and name ~= "loopback" then
		local proto = sec.proto
		if proto and proto ~= "" then
			egress:value(name, name .. " (" .. proto .. ")")
		else
			egress:value(name, name)
		end
	end
end)

value("tls_sans", translate("TLS extra SANs"),
	translate("Comma-separated DNS:/IP: SANs for certificate renewals."))

flag("log_stderr", translate("Log to stderr (procd)"), nil, "1")

function m.on_after_commit(self)
	sys.call("/etc/init.d/ladder-agent restart >/dev/null 2>&1")
end

return m
