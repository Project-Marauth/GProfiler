GProfiler.Version = "2.0.0-marauth"

-- Available languages: english
GProfiler.Config.Language = "english"

-- Enable/Disable Log Types
GProfiler.Config.LOG_DEBUG = true
GProfiler.Config.LOG_INFO = true
GProfiler.Config.LOG_WARNING = true
GProfiler.Config.LOG_ERROR = true
GProfiler.Config.LOG_LOAD = false

-- Access
GProfiler.Config.AllowedSteamIDs = { -- SteamIDs that can access GProfiler
	["76561197963057641"] = true
}

GProfiler.Config.AllowSuperAdmin = false -- Allow players with superadmin (Player:IsSuperAdmin()) to access GProfiler regardless of other checks.

-- todo, requires a lot of changes probably
-- GProfiler.Config.AlwaysAllowClient = false -- Allow clients to use GProfiler (limited to client realm/cannot view sources, etc)

--[[
	If express is available, we use it over gmod's net library
	This can handle larger data sizes, and we shouldn't need to worry about overflowing the buffer
	Learn more at https://github.com/CFC-Servers/gm_express

	If you are using express and are having issues, set this to false to rule out express as the issue
]]
GProfiler.Config.UseExpressNetworking = true
-- Minimum profiler results required to use express networking
-- Express is not worth using for small amounts, as it will be slower for small data
GProfiler.Config.ExpressMinimumResults = 25

-- Net strings that carry many logical messages. The first string written to one of these is treated as the real message name.
GProfiler.Config.NetMultiplexers = {
	["marauth.net.msg"] = true
}

-- Logical messages split into one row per value of an argument, as { [name] = argument index }.
GProfiler.Config.NetDetail = {
	["entity.syncvar"] = 2
}

-- A frame is logged as a spike when it takes at least this long, in seconds.
GProfiler.Config.SpikeFrameTime = {
	Server = 0.05,
	Client = 0.1
}

GProfiler.Config.SpikeLuaTime = 0.01 -- Or when tracked Lua in the frame adds up to this many seconds
GProfiler.Config.SpikeWireBytes = 65536 -- Or when this many bytes of net messages leave in the frame, counted per recipient
GProfiler.Config.SpikeEntryTime = 0.0005 -- Hook calls faster than this are left out of the spike log
GProfiler.Config.SpikeLogSize = 256 -- Spikes kept per run, oldest dropped first
GProfiler.Config.SpikeEntries = 12 -- Offenders kept per spike

if SERVER then return end

GProfiler.MenuColors = {
	-- Misc
	White = Color(255, 255, 255),
	Blue = Color(91, 118, 255),
	Black100 = Color(0, 0, 0, 100),

	-- Scrollbars
	ScrollBar = Color(38, 57, 78),
	ScrollBarGrip = Color(68, 87, 108),
	ScrollBarGripOutline = Color(88, 107, 138),
}

GProfiler.Config.MenuCommands = {
	Chat = '!gprofiler', -- False to disable
	Console = 'gprofiler', -- False to disable
	Closekey = KEY_F4 -- False to disable
}
