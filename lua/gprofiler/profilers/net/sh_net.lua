GProfiler.Net = GProfiler.Net or {}
GProfiler.Net.IsDetoured = GProfiler.Net.IsDetoured or false
GProfiler.Net.ProfileData = GProfiler.Net.ProfileData or {}
GProfiler.Net.ProfileData.Inc = GProfiler.Net.ProfileData.Inc or {}
GProfiler.Net.ProfileData.Out = GProfiler.Net.ProfileData.Out or {}
GProfiler.Net.Breakdowns = GProfiler.Net.Breakdowns or {}

local Net = GProfiler.Net
local Spikes = GProfiler.Spikes

local netReadHeader = net.ReadHeader
local util = util
local max = math.max

local MARAUTH_NET_FILE = "services/net/sh_net.lua"
local MAX_SENDERS_SHOWN = 8
local MAX_ARGUMENT_PREVIEW = 40

local netWriteFunctions = {
	"WriteAngle", "WriteBit", "WriteBool", "WriteColor", "WriteData",
	"WriteDouble", "WriteEntity", "WriteFloat", "WriteInt", "WriteMatrix",
	"WriteNormal", "WriteString", "WriteTable", "WriteType", "WriteUInt",
	"WriteUInt64", "WriteVector"
}

GProfiler.Net.OriginalWrites = GProfiler.Net.OriginalWrites or {}

local netSendFunctions = { "Send" }
if SERVER then
	table.insert(netSendFunctions, "Broadcast")
	table.insert(netSendFunctions, "SendOmit")
	table.insert(netSendFunctions, "SendPVS")
	table.insert(netSendFunctions, "SendPAS")
else
	table.insert(netSendFunctions, "SendToServer")
end

local function CountTargets(target)
	if isentity(target) then return 1 end
	if istable(target) then return #target end
	if target and target.GetCount then return target:GetCount() end
	return 1
end

local function CountInRange(position, method)
	local filter = RecipientFilter()
	filter[method](filter, position)
	return filter:GetCount()
end

--- How many clients one `net.Send*` call reaches, so a broadcast is charged for what actually leaves the server rather than for a single copy of the payload.
local recipientCounters = {
	Send = CountTargets,
	SendToServer = function() return 1 end,
	Broadcast = function() return player.GetCount() end,
	SendOmit = function(target) return max(player.GetCount() - CountTargets(target), 0) end,
	SendPVS = function(position) return CountInRange(position, "AddPVS") end,
	SendPAS = function(position) return CountInRange(position, "AddPAS") end
}

local function GetFrame()
	return SERVER and engine.TickCount() or FrameNumber()
end

local function GetRow(dataMap, name)
	local row = dataMap[name]
	if row then return row end

	row = {0, 0, 0, nil, nil, nil, 0, 0, 0, Wire = 0, Peak = 0, PeakRun = 0}
	dataMap[name] = row
	return row
end

local function AddBurst(row, bits)
	local frame = GetFrame()
	if row.PeakFrame ~= frame then
		row.PeakFrame = frame
		row.PeakRun = 0
	end

	row.PeakRun = row.PeakRun + bits
	row.Peak = max(row.Peak, row.PeakRun)
end

local function SetRowSource(row, info)
	if row[4] or not info then return end
	row[4] = GProfiler.Utils.SourcePath(info)
	row[5] = info.linedefined
	row[6] = info.lastlinedefined
end

local function GetMarauthNet()
	return istable(marauth) and istable(marauth.net) and marauth.net or nil
end

local function IsMultiplexed(name)
	local multiplexers = GProfiler.Config.NetMultiplexers
	return multiplexers and multiplexers[name] or false
end

--- Walks up from the framework's send wrapper to the code that asked for the message, returning the sending function's debug info plus the two nearest call sites as text.
local function FindSender()
	local sender, sites = nil, {}

	for level = 3, 14 do
		local info = debug.getinfo(level, "Sl")
		if not info then break end

		local path = GProfiler.Utils.SourcePath(info)
		if info.what ~= "C" and path ~= "[C]" and not string.find(path, MARAUTH_NET_FILE, 1, true) then
			sender = sender or info
			sites[#sites + 1] = string.format("%s:%d", path, info.currentline or 0)
			if #sites == 2 then break end
		end
	end

	return sender, table.concat(sites, " < ")
end

--- Row name for a logical message. Channels listed in `GProfiler.Config.NetDetail` are split by one of their arguments, so traffic that all shares a single name (every SyncVar) still shows which variable is responsible.
local function GetRowName(name, arguments)
	local detail = GProfiler.Config.NetDetail
	local index = detail and detail[name]
	if not index then return name end

	local value = arguments[index]
	if value == nil then return name end

	return string.format("%s[%s]", name, tostring(value))
end

local function DescribeArgument(index, value)
	local valueType = type(value)
	if isstring(value) then
		return string.format("argument %d (string \"%s\")", index, string.sub(value, 1, MAX_ARGUMENT_PREVIEW))
	end

	if isnumber(value) or isbool(value) then
		return string.format("argument %d (%s %s)", index, valueType, tostring(value))
	end

	return string.format("argument %d (%s)", index, valueType)
end

--- Measures each argument of the largest payload seen so far, on its own. It only runs when a message beats its own record, so the extra encoding stays out of the common path.
local function RecordArguments(row, arguments, bits)
	if bits <= (row.ArgumentBits or 0) then return end
	row.ArgumentBits = bits

	local nodes = {}
	for index = 1, arguments.n or #arguments do
		local bOk, encoded = pcall(sfs.encode, arguments[index])
		nodes[index] = {
			Func = "Argument",
			Label = DescribeArgument(index, arguments[index]),
			Size = bOk and isstring(encoded) and #encoded * 8 or 0,
			Children = {}
		}
	end

	row.ArgumentNodes = nodes
end

local function DetourMarauthNet()
	local marauthNet = GetMarauthNet()
	if not marauthNet then return end

	local originalBuild = marauthNet.BuildPayload
	local originalQueue = marauthNet.QueueMessage
	if not originalBuild or not originalQueue then return end

	local build = function(self, arguments)
		local encoded = originalBuild(self, arguments)
		Net.LastPayloadBits = isstring(encoded) and #encoded * 8 or 0
		return encoded
	end

	local queue = function(self, name, arguments, ...)
		local sender, sites = FindSender()
		local rowName = GetRowName(name, arguments)

		Net.QueuedName = name
		Net.QueuedRowName = rowName
		Net.LastPayloadBits = 0

		local startTime = SysTime()
		originalQueue(self, name, arguments, ...)
		local deltaTime = SysTime() - startTime

		Net.QueuedName = nil
		Net.QueuedRowName = nil

		local row = GetRow(Net.ProfileData.Out, rowName)
		row.Logical = true
		row[7] = row[7] + deltaTime
		row[8] = max(row[8], deltaTime)
		row[9] = row[7] / max(row[1], 1)
		SetRowSource(row, sender)

		row.Senders = row.Senders or {}
		row.Senders[sites] = (row.Senders[sites] or 0) + 1

		RecordArguments(row, arguments, Net.LastPayloadBits)
		Spikes.Add("out", rowName, deltaTime, 0)
	end

	marauthNet.BuildPayload = build
	marauthNet.QueueMessage = queue

	Net.MarauthDetour = {
		BuildPayload = originalBuild,
		QueueMessage = originalQueue,
		Build = build,
		Queue = queue
	}
end

local function RestoreMarauthNet()
	local detour = Net.MarauthDetour
	local marauthNet = GetMarauthNet()
	Net.MarauthDetour = nil
	if not detour or not marauthNet then return end

	if marauthNet.BuildPayload == detour.Build then marauthNet.BuildPayload = detour.BuildPayload end
	if marauthNet.QueueMessage == detour.Queue then marauthNet.QueueMessage = detour.QueueMessage end
end

local function DetourOutgoing()
	GProfiler.Net.OriginalWrites = {}

	local function AddEntry(funcName, size, ...)
		if not GProfiler.Net.CurrentMsg then return end

		local entry = {
			Func = funcName,
			Children = {},
			Size = size or 0
		}

		local stack = GProfiler.Net.CurrentMsg.Stack
		local parent = stack[#stack]
		if parent then
			table.insert(parent.Children, entry)
		end
		return entry
	end

	GProfiler.Net.OriginalWrites["Start"] = net.Start
	function net.Start(name, ...)
		local nameLower = name:lower()

		GProfiler.Net.CurrentMsg = {
			Name = nameLower,
			Multiplexed = IsMultiplexed(nameLower),
			Stack = {},
			Root = { Children = {} },
			StartTime = SysTime()
		}
		GProfiler.Net.CurrentMsg.Stack[1] = GProfiler.Net.CurrentMsg.Root

		AddEntry("Start", 0)

		return GProfiler.Net.OriginalWrites["Start"](name, ...)
	end

	local function FinishMsg(recipients)
		if not GProfiler.Net.CurrentMsg then return end
		local msg = GProfiler.Net.CurrentMsg
		local name = msg.Name

		local d = GetRow(GProfiler.Net.ProfileData.Out, name)
		local bytes, bits = net.BytesWritten()
		local size = bits or (bytes * 8)
		local wire = size * recipients

		local dt = SysTime() - (msg.StartTime or SysTime())

		d[1] = d[1] + 1
		d[2] = max(d[2], size)
		d[3] = d[3] + size
		d.Wire = d.Wire + wire
		AddBurst(d, wire)

		if msg.Logical then
			Spikes.Add("out", name, 0, wire)
		else
			d[7] = d[7] + dt
			d[8] = max(d[8], dt)
			d[9] = d[7] / d[1]

			SetRowSource(d, debug.getinfo(3, "S"))

			GProfiler.Net.Breakdowns[name] = {
				Nodes = msg.Root.Children,
				Size = size
			}

			Spikes.Add("out", name, dt, wire)
		end

		GProfiler.Net.CurrentMsg = nil
	end

	for _, funcName in ipairs(netSendFunctions) do
		if not net[funcName] then continue end
		GProfiler.Net.OriginalWrites[funcName] = net[funcName]

		local countRecipients = recipientCounters[funcName]
		net[funcName] = function(...)
			if GProfiler.Net.CurrentMsg then
				AddEntry(funcName, 0)
				FinishMsg(countRecipients(...))
			end

			return GProfiler.Net.OriginalWrites[funcName](...)
		end
	end

	for _, funcName in ipairs(netWriteFunctions) do
		if not net[funcName] then continue end

		GProfiler.Net.OriginalWrites[funcName] = net[funcName]
		net[funcName] = function(...)
			local msg = GProfiler.Net.CurrentMsg
			if not msg then
				return GProfiler.Net.OriginalWrites[funcName](...)
			end

			if funcName == "WriteString" and msg.Multiplexed and not msg.Logical then
				local logicalName = ...
				msg.Logical = true
				msg.Name = Net.QueuedName == logicalName and Net.QueuedRowName or logicalName
			end

			local entry = AddEntry(funcName, nil, ...)

			table.insert(msg.Stack, entry)

			local startB, startBits = net.BytesWritten()
			local ret = {GProfiler.Net.OriginalWrites[funcName](...)}
			local endB, endBits = net.BytesWritten()

			startBits = startBits or (startB * 8)
			endBits = endBits or (endB * 8)
			entry.Size = endBits - startBits

			table.remove(msg.Stack)

			return unpack(ret)
		end
	end
end

local function RestoreOutgoing()
	if not GProfiler.Net.OriginalWrites["Start"] then return end

	net.Start = GProfiler.Net.OriginalWrites["Start"]

	for _, funcName in ipairs(netSendFunctions) do
		if GProfiler.Net.OriginalWrites[funcName] then
			net[funcName] = GProfiler.Net.OriginalWrites[funcName]
		end
	end

	for _, funcName in ipairs(netWriteFunctions) do
		if GProfiler.Net.OriginalWrites[funcName] then
			net[funcName] = GProfiler.Net.OriginalWrites[funcName]
		end
	end

	GProfiler.Net.OriginalWrites = {}
	GProfiler.Net.CurrentMsg = nil
end

local function CountIncoming(row, bits)
	row[1] = row[1] + 1
	row[2] = max(row[2], bits)
	row[3] = row[3] + bits
	row.Wire = row.Wire + bits
	AddBurst(row, bits)
end

local function FindIncomingHandler(name)
	local marauthNet = GetMarauthNet()
	local stored = marauthNet and marauthNet.stored and marauthNet.stored[name]
	if not istable(stored) or not isfunction(stored[1]) then return end

	return debug.getinfo(stored[1], "S")
end

local function CountLogicalIncoming(name, rowName, bits)
	local row = GetRow(GProfiler.Net.ProfileData.Inc, rowName)
	row.Logical = true
	CountIncoming(row, bits)
	SetRowSource(row, FindIncomingHandler(name))

	Net.IncomingRow = row
	Net.IncomingName = rowName
	Spikes.Add("in", rowName, 0, bits)
end

--- The arguments of a received message only exist once its payload is decoded, so channels in `GProfiler.Config.NetDetail` are counted here rather than when their name is read.
local function FinishDetailIncoming(decoded)
	local name = Net.DetailIncomingName
	if not name then return end
	Net.DetailIncomingName = nil

	local rowName = istable(decoded) and GetRowName(name, decoded) or name
	CountLogicalIncoming(name, rowName, Net.DetailIncomingBits)
end

local function DetourDecode()
	local original = sfs and sfs.decode
	if not original then return end

	local decode = function(raw)
		local decoded, reason = original(raw)
		FinishDetailIncoming(decoded)
		return decoded, reason
	end

	sfs.decode = decode
	Net.DecodeDetour = { Original = original, Decode = decode }
end

local function RestoreDecode()
	local detour = Net.DecodeDetour
	Net.DecodeDetour = nil
	if detour and sfs.decode == detour.Decode then sfs.decode = detour.Original end
end

local function DetourIncoming()
	GProfiler.Net.OriginalIncoming = GProfiler.Net.OriginalIncoming or net.Incoming
	GProfiler.Net.OriginalReadString = GProfiler.Net.OriginalReadString or net.ReadString

	DetourDecode()

	function net.ReadString()
		local value = GProfiler.Net.OriginalReadString()

		local bits = Net.PendingIncomingBits
		if bits then
			Net.PendingIncomingBits = nil

			local detail = GProfiler.Config.NetDetail
			if detail and detail[value] and Net.DecodeDetour then
				Net.DetailIncomingName = value
				Net.DetailIncomingBits = bits
			else
				CountLogicalIncoming(value, value, bits)
			end
		end

		return value
	end

	function net.Incoming(len, client)
		local i = netReadHeader()

		local strName = util.NetworkIDToString(i)
		if not strName then return end
		local nameLower = strName:lower()

		len = len - 16

		local func = net.Receivers[nameLower]
		local row, rowName

		Net.IncomingRow = nil
		Net.IncomingName = nil
		Net.PendingIncomingBits = nil
		Net.DetailIncomingName = nil

		if IsMultiplexed(nameLower) then
			Net.PendingIncomingBits = len
		else
			row = GetRow(GProfiler.Net.ProfileData.Inc, nameLower)
			rowName = nameLower
			CountIncoming(row, len)
			Spikes.Add("in", nameLower, 0, len)
		end

		if not func then return end

		if row then
			SetRowSource(row, debug.getinfo(func, "S"))
		end

		local start = SysTime()
		func(len, client)
		local deltaTime = SysTime() - start

		FinishDetailIncoming()

		row = row or Net.IncomingRow
		rowName = rowName or Net.IncomingName
		Net.PendingIncomingBits = nil

		if not row then return end

		row[7] = row[7] + deltaTime
		row[8] = max(row[8], deltaTime)
		row[9] = row[7] / max(row[1], 1)
		Spikes.Add("in", rowName, deltaTime, 0)
	end
end

local function RestoreIncoming()
	net.Incoming = GProfiler.Net.OriginalIncoming
	net.ReadString = GProfiler.Net.OriginalReadString
	RestoreDecode()
end

local function StartDetour()
	if GProfiler.Net.IsDetoured then return end

	GProfiler.Log((SERVER and "Server" or "Client") .. " net profiler started!", 2)
	GProfiler.Net.ProfileData = { Inc = {}, Out = {} }
	GProfiler.Net.Breakdowns = {}
	GProfiler.Net.IsDetoured = true

	Spikes.Start("Networking")
	DetourIncoming()
	DetourOutgoing()
	DetourMarauthNet()
end

local function StopDetour()
	if not GProfiler.Net.IsDetoured then return end

	GProfiler.Log((SERVER and "Server" or "Client") .. " net profile stopped!", 2)
	GProfiler.Net.IsDetoured = false

	RestoreMarauthNet()
	RestoreIncoming()
	RestoreOutgoing()
	Spikes.Stop("Networking")

	if GProfiler.Net.RefreshUI then
		GProfiler.Net.RefreshUI()
	end
end

--- Returns what the breakdown pane shows for a sent message. A multiplexed message has no useful write tree (every one is a name and a blob), so it reports its arguments and who sent it instead.
function GProfiler.Net.GetBreakdown(name)
	local row = GProfiler.Net.ProfileData.Out[name]
	if not row or not row.Logical then return GProfiler.Net.Breakdowns[name] end

	local nodes = {}
	for _, node in ipairs(row.ArgumentNodes or {}) do
		nodes[#nodes + 1] = node
	end

	local senders = {}
	for sites, count in pairs(row.Senders or {}) do
		senders[#senders + 1] = { Sites = sites, Count = count }
	end
	table.sort(senders, function(a, b) return a.Count > b.Count end)

	for index = 1, math.min(#senders, MAX_SENDERS_SHOWN) do
		nodes[#nodes + 1] = {
			Func = "Sender",
			Label = string.format("x%d from %s", senders[index].Count, senders[index].Sites),
			Size = 0,
			Children = {}
		}
	end

	return { Nodes = nodes, Size = row.ArgumentBits or row[2] }
end

local function SerializeRows(dataMap)
	local rows = {}
	for name, v in pairs(dataMap) do
		rows[#rows + 1] = {
			Name = tostring(name),
			Count = v[1], MaxSize = v[2], TotalSize = v[3],
			Source = v[4] or "", LineDefined = v[5] or 0, LastLineDefined = v[6] or 0,
			TotalTime = v[7], LongestTime = v[8], AverageTime = v[9],
			Wire = v.Wire, Peak = v.Peak
		}
	end
	return rows
end

local function SendNetData(ply)
	GProfiler.Utils.SendLarge("Networking", {
		Inc = SerializeRows(GProfiler.Net.ProfileData.Inc),
		Out = SerializeRows(GProfiler.Net.ProfileData.Out)
	}, ply)

	Spikes.Send(ply)
end

GProfiler.Profilers.Register("Networking", {
	Realms = { "Client", "Server" },
	OnStart = function(realm, ply)
		StartDetour()
	end,
	OnStop = function(realm, ply)
		StopDetour()
		if CLIENT then
			local NetStore = GProfiler.Profilers.GetStore("Networking")
			if NetStore then
				NetStore:SetData(realm, {
					Inc = GProfiler.Net.ProfileData.Inc,
					Out = GProfiler.Net.ProfileData.Out
				})
			end
		end
		if SERVER and ply then
			SendNetData(ply)
		end
	end,
	WriteData = function(realm, ply)
		SendNetData(ply)
	end
})

if GProfiler.Net.IsDetoured then
	StopDetour()
	GProfiler.Profilers.GetStore("Networking"):Stop(SERVER and "Server" or "Client")
end

if SERVER then
	util.AddNetworkString("GProfiler_Net_RequestBreakdown")
	util.AddNetworkString("GProfiler_Net_SendBreakdown")
	util.AddNetworkString("GProfiler_Net_ReceiverTbl")

	net.Receive("GProfiler_Net_ReceiverTbl", function(len, ply)
		if not GProfiler.Access.HasAccess(ply) then return end

		net.Start("GProfiler_Net_ReceiverTbl")
		net.WriteUInt(table.Count(net.Receivers), 32)
		for name, func in pairs(net.Receivers) do
			local Source = debug.getinfo(func, "S") or {}
			net.WriteString(name)
			net.WriteString(Source.short_src or "")
			net.WriteUInt(Source.linedefined or 0, 16)
			net.WriteUInt(Source.lastlinedefined or 0, 16)
		end
		net.Send(ply)
	end)

	net.Receive("GProfiler_Net_RequestBreakdown", function(len, ply)
		if not GProfiler.Access.HasAccess(ply) then return end

		local name = net.ReadString()
		local breakdownData = GProfiler.Net.GetBreakdown(name)

		net.Start("GProfiler_Net_SendBreakdown")
		net.WriteString(name)
		if breakdownData then
			net.WriteBool(true)
			net.WriteUInt(breakdownData.Size, 32)

			local function WriteNode(node)
				net.WriteString(node.Func)
				net.WriteString(node.Label or "")
				net.WriteUInt(node.Size, 32)
				net.WriteUInt(#node.Children, 16)
				for _, child in ipairs(node.Children) do
					WriteNode(child)
				end
			end

			local nodes = breakdownData.Nodes
			net.WriteUInt(#nodes, 16)
			for _, node in ipairs(nodes) do
				WriteNode(node)
			end
		else
			net.WriteBool(false)
		end
		net.Send(ply)
	end)
end
