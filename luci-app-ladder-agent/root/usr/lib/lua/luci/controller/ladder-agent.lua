-- OpenWrt 19.07 LuCI is a Lua dispatcher. 21.02 and later register this
-- app from menu.d JSON, so skip the Lua menu when that luci-base file exists
-- (including when luci-compat is installed on a current release).

module("luci.controller.ladder-agent", package.seeall)

function index()
	local fs = require "nixio.fs"
	if fs.access("/usr/share/luci/menu.d/luci-base.json") then
		return
	end
	if not fs.access("/etc/config/ladder-agent") then
		return
	end

	entry({"admin", "services", "ladder-agent"}, alias("admin", "services", "ladder-agent", "status"), _("LadderAirport"), 80).dependent = true
	entry({"admin", "services", "ladder-agent", "status"}, template("ladder-agent/status"), _("Status"), 1)
	entry({"admin", "services", "ladder-agent", "config"}, cbi("ladder-agent"), _("Configuration"), 2)

	local act = entry({"admin", "services", "ladder-agent", "action"}, call("action_service"))
	act.leaf = true
	act.hidden = true
end

function action_service()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local disp = require "luci.dispatcher"
	local allowed = {
		start = true,
		stop = true,
		restart = true,
		enable = true,
		disable = true,
	}
	local act = http.formvalue("action")
	if allowed[act] then
		sys.call("/etc/init.d/ladder-agent " .. act .. " >/dev/null 2>&1")
	end
	http.redirect(disp.build_url("admin", "services", "ladder-agent", "status"))
end
