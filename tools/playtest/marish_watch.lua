function widget:GetInfo()
	return { name = "Marish watch", desc = "test: speed, per-minute census, first-finish times", author = "test", layer = 10, enabled = true }
end
local FPS, END_MIN = 30, 16
-- owner: 5x for runs of 5 minutes or longer, 10x for 20 minutes or longer
local SPEED = (END_MIN >= 20) and 10 or 5
local KIND = {
	armlab="T1lab", corlab="T1lab", leglab="T1lab",
	armalab="T2lab", coralab="T2lab", legalab="T2lab",
	armshltx="gantry", corgant="gantry", leggant="gantry",
	armvp="VEHPLANT", corvp="VEHPLANT", legvp="VEHPLANT", armavp="VEHPLANT", coravp="VEHPLANT", legavp="VEHPLANT",
	armhp="HOVER", corhp="HOVER", leghp="HOVER", armap="AIRPLANT", corap="AIRPLANT", legap="AIRPLANT",
}
local seen = {}
local function echo(s) Spring.Echo("[Marish] " .. s) end
local function mmss(f) local s = math.floor(f / FPS); return string.format("%d:%02d", math.floor(s / 60), s % 60) end
function widget:Initialize()
	Spring.SendCommands("specfullview 3")
	Spring.SendCommands("luaui disablewidget Autoquit")
	if widgetHandler and widgetHandler.DisableWidget then widgetHandler:DisableWidget("Autoquit") end
end
function widget:UnitFinished(unitID, unitDefID, team)
	local ud = UnitDefs[unitDefID]; if not ud then return end
	local key = team .. ":" .. ud.name
	if seen[key] then return end
	seen[key] = true
	local _, _, _, mi = Spring.GetTeamResources(team, "metal")
	local isMobile = ud.speed and ud.speed > 0
	if KIND[ud.name] or (isMobile and not ud.isBuilder) or ud.isFactory then
		echo(string.format("first %s %s team %d at %s (metal income %.0f)", KIND[ud.name] or (ud.isFactory and "factory" or "unit"), ud.name, team, mmss(Spring.GetGameFrame()), mi or -1))
	end
end
function widget:GameFrame(f)
	if f == 1 then Spring.SendCommands({ "setmaxspeed " .. SPEED, "setminspeed " .. SPEED }); echo("speed " .. SPEED) end
	if f > 0 and f % (60 * FPS) == 0 then
		for _, team in ipairs(Spring.GetTeamList() or {}) do
			local _, _, _, mi = Spring.GetTeamResources(team, "metal")
			local _, _, _, ei = Spring.GetTeamResources(team, "energy")
			local c = {}
			for _, u in ipairs(Spring.GetTeamUnits(team) or {}) do
				local ud = UnitDefs[Spring.GetUnitDefID(u) or -1]
				local _, _, _, _, bp = Spring.GetUnitHealth(u)
				if ud and (bp or 1) >= 1 and (ud.isFactory or (ud.speed > 0 and not ud.isBuilder)) then c[ud.name] = (c[ud.name] or 0) + 1 end
			end
			local parts = {}
			for n, k in pairs(c) do parts[#parts + 1] = n .. "=" .. k end
			table.sort(parts)
			if #parts > 0 then echo(string.format("min %d team %d m=%.0f e=%.0f | %s", math.floor(f / (60 * FPS)), team, mi or 0, ei or 0, table.concat(parts, " "))) end
		end
	end
	if f >= END_MIN * 60 * FPS then echo("end"); Spring.SendCommands("quitforce") end
end
