GProfiler.Hooks = GProfiler.Hooks or {}

local HooksProfiler = GProfiler.Hooks
HooksProfiler.IsDetoured = HooksProfiler.IsDetoured or false
HooksProfiler.ProfileData = HooksProfiler.ProfileData or {}

local Spikes = GProfiler.Spikes

local SysTime = SysTime
local unpack = unpack
local debug = debug

local DEFAULT_SPIKE_ENTRY_TIME = 0.0005
local MAX_UPVALUES = 32

local function GetIdent(hookName, receiverName)
	return string.format("%s_%s", hookName, tostring(receiverName))
end

--- Finds a local of a function by its upvalue name.
local function GetUpvalue(func, wanted)
	for index = 1, MAX_UPVALUES do
		local name, value = debug.getupvalue(func, index)
		if not name then return end
		if name == wanted then return value end
	end
end

--- Priority a live hook was registered with. Srlion's hook library drops it from `hook.GetTable`, and re-adding a hook without it would turn a POST_HOOK into a normal hook that receives the wrong arguments, so it is read from the library's own event table. The stock library has no such table and nothing to preserve.
local function GetPriority(hookName, receiverName)
	local events = GetUpvalue(hook.GetTable, "events")
	local event = istable(events) and events[hookName]
	local hookInfo = istable(event) and event[receiverName]

	return istable(hookInfo) and hookInfo.priority or nil
end

--- Module and schema hooks all run through one trampoline in `marauth.util:AttachHooks`, which would otherwise report every one of them as the same function. This reads the trampoline's registry and returns who really owns the hook, plus the handler it dispatches to.
local function ResolveOwnerHook(hookName, receiverName, receiverFunc)
	if not isstring(receiverName) then return end

	local kind, uniqueID = string.match(receiverName, "^marauth_(%a+)_hook_(.+)_" .. string.PatternSafe(hookName) .. "$")
	if not kind then return end

	local registry = GetUpvalue(receiverFunc, "registry")
	local entry = istable(registry) and registry[uniqueID]
	local handler = istable(entry) and entry[hookName]

	return kind, uniqueID, isfunction(handler) and handler or nil
end

local function GetNamespace(receiverName)
	if not isstring(receiverName) then return "other" end

	return string.match(receiverName, "^([^%.]+%.[^%.]+)%.") or string.match(receiverName, "^([^%.]+)%.") or "other"
end

local function SetSource(entry, func)
	local Source = debug.getinfo(func, "S")
	if Source and Source.short_src and Source.linedefined and Source.lastlinedefined then
		entry.Source = GProfiler.Utils.SourcePath(Source)
		entry.Lines = { Source.linedefined, Source.lastlinedefined }
		entry.FullSource = string.format("%s (%d - %d)", entry.Source, Source.linedefined, Source.lastlinedefined)
	end
end

local function DescribeEntry(entry, hookName, receiverName, receiverFunc)
	local kind, uniqueID, handler = ResolveOwnerHook(hookName, receiverName, receiverFunc)
	if kind then
		entry.d = string.format("%s %s:%s", kind, uniqueID, hookName)
		entry.o = string.format("%s %s", kind, uniqueID)
	else
		entry.d = string.format("%s (%s)", tostring(receiverName), hookName)
		entry.o = GetNamespace(receiverName)
	end

	SetSource(entry, handler or receiverFunc)
end

local function GetEntry(ident, hookName, receiverName)
	local entry = HooksProfiler.ProfileData[ident]
	if entry then return entry end

	entry = {
		h = hookName,
		r = tostring(receiverName),
		c = 0,
		t = 0,
		m = 0
	}
	HooksProfiler.ProfileData[ident] = entry
	return entry
end

local function MakeWrapper(entry, func)
	local threshold = GProfiler.Config.SpikeEntryTime or DEFAULT_SPIKE_ENTRY_TIME

	return function(...)
		local startTime = SysTime()
		local a, b, c, d, e, f = func(...)
		local deltaTime = SysTime() - startTime

		entry.c = entry.c + 1
		entry.t = entry.t + deltaTime
		if deltaTime > entry.m then entry.m = deltaTime end
		if deltaTime >= threshold then Spikes.Add("hook", entry.d, deltaTime, 0) end

		return a, b, c, d, e, f
	end
end

local function WrapGamemode()
	HooksProfiler.Gamemode = {}

	local gm = gmod.GetGamemode()
	if not istable(gm) then return end

	for name, func in pairs(gm) do
		if not isfunction(func) then continue end

		local entry = GetEntry(GetIdent(name, "gamemode"), name, "gamemode")
		entry.f = func
		entry.d = string.format("gamemode:%s", name)
		entry.o = "gamemode"
		SetSource(entry, func)

		entry.w = MakeWrapper(entry, func)
		gm[name] = entry.w
		HooksProfiler.Gamemode[name] = entry
	end
end

local function RestoreGamemode()
	local gm = gmod.GetGamemode()
	if not istable(gm) then return end

	for name, entry in pairs(HooksProfiler.Gamemode or {}) do
		if gm[name] == entry.w then gm[name] = entry.f end
	end

	HooksProfiler.Gamemode = nil
end

local function StartDetour()
	if HooksProfiler.IsDetoured then return end

	GProfiler.Log((SERVER and "Server" or "Client") .. " hook profiler started!", 2)
	HooksProfiler.ProfileData = {}
	HooksProfiler.IsDetoured = true
	HooksProfiler.AddHook = HooksProfiler.AddHook or hook.Add

	Spikes.Start("Hooks")

	local function profileHook(hookName, receiverName, receiverFunc, ...)
		if not isfunction(receiverFunc) or receiverName == Spikes.HookName then
			return HooksProfiler.AddHook(hookName, receiverName, receiverFunc, ...)
		end

		local hookTbl = GetEntry(GetIdent(hookName, receiverName), hookName, receiverName)
		hookTbl.f = receiverFunc
		hookTbl.extra = {...}
		DescribeEntry(hookTbl, hookName, receiverName, receiverFunc)

		hookTbl.w = MakeWrapper(hookTbl, receiverFunc)
		HooksProfiler.AddHook(hookName, receiverName, hookTbl.w, ...)
	end

	for hookName, hookReceivers in pairs(hook.GetTable()) do
		for receiverName, receiverFunc in pairs(hookReceivers) do
			profileHook(hookName, receiverName, receiverFunc, GetPriority(hookName, receiverName))
		end
	end

	hook.Add = profileHook
	WrapGamemode()
end

local function StopDetour()
	if not HooksProfiler.IsDetoured then return end

	GProfiler.Log((SERVER and "Server" or "Client") .. " hook profile stopped!", 2)
	HooksProfiler.IsDetoured = false

	hook.Add = HooksProfiler.AddHook
	RestoreGamemode()

	for hookName, hookReceivers in pairs(hook.GetTable()) do
		for receiverName, receiverFunc in pairs(hookReceivers) do
			if not isfunction(receiverFunc) or receiverName == Spikes.HookName then continue end

			local data = HooksProfiler.ProfileData[GetIdent(hookName, receiverName)]
			if data and (data.w == nil or data.w == receiverFunc) then
				local extra = data.extra or {}
				local priority = GetPriority(hookName, receiverName)
				if priority ~= nil then extra = { priority } end

				hook.Add(hookName, receiverName, data.f, unpack(extra))
			end
		end
	end

	Spikes.Stop("Hooks")

	for k, v in pairs(HooksProfiler.ProfileData) do
		if v.c == 0 then
			HooksProfiler.ProfileData[k] = nil
		end
	end
end

local function SendData(ply)
	local rows = {}
	for _, v in pairs(HooksProfiler.ProfileData) do
		if v.c > 0 then
			rows[#rows + 1] = {
				r = v.r, h = v.h, d = v.d, o = v.o,
				c = v.c, t = v.t, m = v.m,
				Source = v.Source, Lines = v.Lines
			}
		end
	end

	GProfiler.Utils.SendLarge("Hooks", rows, ply)
	Spikes.Send(ply)
end

GProfiler.Profilers.Register("Hooks", {
	Realms = { "Client", "Server" },
	OnStart = function(realm, ply)
		StartDetour()
	end,
	OnStop = function(realm, ply)
		StopDetour()
		if CLIENT then
			local HookStore = GProfiler.Profilers.GetStore("Hooks")
			if HookStore then
				HookStore:SetData(realm, HooksProfiler.ProfileData)
			end
		end
		if SERVER and ply then
			SendData(ply)
		end
	end,
	WriteData = function(realm, ply)
		SendData(ply)
	end
})

if HooksProfiler.IsDetoured then
	StopDetour()
	GProfiler.Profilers.GetStore("Hooks"):Stop(SERVER and "Server" or "Client")
end

if SERVER then
	util.AddNetworkString("GProfiler_Hooks_RemoveHook")

	net.Receive("GProfiler_Hooks_RemoveHook", function(len, ply)
		if not GProfiler.Access.HasAccess(ply) then return end

		local hookName = net.ReadString()
		local receiverName = net.ReadString()

		if not hookName or not receiverName then return end

		hook.Remove(hookName, receiverName)
	end)
end
