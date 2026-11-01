local PANEL = {}

function PANEL:SortByColumn(ColumnID, Desc)
	table.sort(self.Sorted, function(a, b)
		if Desc then a, b = b, a end
		local aval = a:GetSortValue( ColumnID ) || a:GetColumnText( ColumnID )
		local bval = b:GetSortValue( ColumnID ) || b:GetColumnText( ColumnID )
		if isnumber(aval) and isnumber(bval) then return aval < bval end
		return tostring(aval) < tostring(bval)
	end)

	self:SetDirty(true)
	self:InvalidateLayout()

	self.SortedBy = ColumnID
	self.SortedDescending = Desc
end

derma.DefineControl("GP.ListView", "", PANEL, "DListView")

function GProfiler.Utils.CreateList(Parent, Header, Columns)
	local ResultsList = vgui.Create("GP.ListView", Parent)
	ResultsList:SetSize(Parent:GetWide(), Parent:GetTall() - Header:GetTall())
	ResultsList:SetPos(0, Header:GetTall())
	ResultsList:SetMultiSelect(false)
	for _, col in ipairs(Columns) do
		ResultsList:AddColumn(col)
	end
	ResultsList:SetHeaderHeight(GProfiler.GetScaledSize(30))
	ResultsList:SetDataHeight(GProfiler.GetScaledSize(draw.GetFontHeight("GProfiler.Inter24") + GProfiler.GetScaledSize(10)))
	ResultsList.Paint = nil

	local sbar = ResultsList.VBar
	sbar:SetWide(GProfiler.GetScaledSize(12))
	sbar:SetHideButtons(true)
	sbar.Paint = function(s, w, h)
		GProfiler.RNDX.DrawScaled(4, 0, 0, w, h, Color(255, 255, 255, 10))
	end
	sbar.btnGrip.Paint = function(s, w, h)
		GProfiler.RNDX.DrawScaled(4, 0, 0, w, h, Color(255, 255, 255, 20))
	end

	for k, v in ipairs(ResultsList.Columns) do
		v.Header:SetFont("GProfiler.Inter28")
		v.Header:SetTextColor(color_white)
		local isLast = v == ResultsList.Columns[#ResultsList.Columns]
		v.Header.Paint = function(s, w, h)
			GProfiler.RNDX.DrawScaled(0, 0, 0, w, h, Color(64, 105, 146), GProfiler.RNDX.NO_BL + GProfiler.RNDX.NO_BR)
			if not isLast then
				surface.SetDrawColor(Color(255, 255, 255, 20))
				surface.DrawRect(w - 1, 0, 1, h)
			end

			if s:IsHovered() then
				GProfiler.RNDX.DrawScaled(0, 0, 0, w, h, Color(255, 255, 255, 20), GProfiler.RNDX.NO_BL + GProfiler.RNDX.NO_BR)
			end

			if ResultsList.SortedBy == k then
				draw.SimpleText(ResultsList.SortedDescending and "▼" or "▲", "GProfiler.Inter24", w - GProfiler.GetScaledSize(20), h / 2, Color(255, 255, 255, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end
	end

	local oldAddLine = ResultsList.AddLine
	ResultsList.AddLine = function(self, ...)
		local line = oldAddLine(self, ...)
		line.Paint = function(s, w, h)
			local isEven = false
			for i, v in ipairs(self.Sorted) do
				if v == line then
					isEven = i % 2 == 0
					break
				end
			end
			GProfiler.RNDX.DrawScaled(0, 0, 0, w, h, isEven and Color(255, 255, 255, 10) or Color(255, 255, 255, 2))

			if s:IsHovered() then
				GProfiler.RNDX.DrawScaled(0, 0, 0, w, h, Color(255, 255, 255, 20))
			end

			if s:IsLineSelected() then
				GProfiler.RNDX.DrawScaled(0, 0, 0, w, h, Color(255, 255, 255, 30))
			end
		end
		for _, col in pairs(line.Columns) do
			col:SetFont("GProfiler.Inter24")
			col:SetTextColor(Color(255, 255, 255, 200))
		end
		local oldSetSize = line.SetSize
		line.SetSize = function(s, w, h)
			oldSetSize(s, w, draw.GetFontHeight("GProfiler.Inter24") + GProfiler.GetScaledSize(12))
		end
		return line
	end

	local sbar = ResultsList.VBar
	sbar:SetWide(GProfiler.GetScaledSize(12))
	sbar:SetHideButtons(true)
	sbar.Paint = function(s, w, h) GProfiler.RNDX.DrawScaled(4, 0, 0, w, h, Color(255, 255, 255, 10)) end
	sbar.btnGrip.Paint = function(s, w, h) GProfiler.RNDX.DrawScaled(4, 0, 0, w, h, Color(255, 255, 255, 20)) end

	return ResultsList
end

--- Formats a bit count as the largest unit that keeps it readable.
function GProfiler.Utils.FormatBits(bits)
	if not bits or bits < 0.01 then return "0 Bytes" end
	if not isnumber(bits) then return "oh fiddlesticks, what now?" end

	if bits < 8 then return math.Round(bits, 2) .. (bits == 1 and " Bit" or " Bits") end

	local bytes = bits / 8
	if bytes < 1024 then return math.Round(bytes, 2) .. (bytes == 1 and " Byte" or " Bytes") end

	local kb = bytes / 1024
	if kb < 1024 then return math.Round(kb, 2) .. " KB" end
	local mb = kb / 1024
	return math.Round(mb, 2) .. " MB"
end

--- Formats seconds as milliseconds, which is the scale everything here lives at.
function GProfiler.Utils.FormatTime(seconds)
	return string.format("%.3f ms", (seconds or 0) * 1000)
end

--- Adds a row whose numeric columns display formatted text but sort by value. Each cell is either plain text or `{ text, number }`.
function GProfiler.Utils.AddSortedLine(List, cells)
	local texts = {}
	for index, cell in ipairs(cells) do
		texts[index] = istable(cell) and cell[1] or cell
	end

	local line = List:AddLine(unpack(texts))
	for index, cell in ipairs(cells) do
		if istable(cell) then line:SetSortValue(index, cell[2]) end
	end

	return line
end

--- Gives the first column the room long message and hook names need.
function GProfiler.Utils.WidenNameColumn(List)
	List.Columns[1]:SetWidth(List:GetWide() * 0.34)
end

local function DescribeSpikeEntry(entry)
	return string.format("%-5s %-46s x%-5d %12s %12s", entry.Kind, entry.Name, entry.Count, GProfiler.Utils.FormatTime(entry.Time), GProfiler.Utils.FormatBits(entry.Bits))
end

--- Plain text report of one spike for the source pane.
function GProfiler.Utils.DescribeSpike(spike)
	local lines = {
		string.format("Frame took %s, %.2fs into the run.", GProfiler.Utils.FormatTime(spike.Gap), spike.At),
		string.format("Tracked Lua: %s. Net traffic: %s.", GProfiler.Utils.FormatTime(spike.Lua), GProfiler.Utils.FormatBits(spike.Bits)),
		""
	}

	if not spike.Entries or #spike.Entries == 0 then
		lines[#lines + 1] = "Nothing tracked was slow this frame. Look at timers, physics, garbage collection or the engine."
	end

	for _, entry in ipairs(spike.Entries or {}) do
		lines[#lines + 1] = DescribeSpikeEntry(entry)
	end

	return table.concat(lines, "\n")
end

--- Builds the list of logged spikes for a tab. Selecting one hands it to `onSelect`.
function GProfiler.Utils.CreateSpikeList(Parent, getRealm, onSelect)
	local Header = GProfiler.Utils.SetupHeader(Parent, "Spike Frames", nil, true)
	local List = GProfiler.Utils.CreateList(Parent, Header, {"At", "Frame", "Tracked Lua", "Net", "Worst"})

	Parent.OnHandleMoved = function()
		Header:SetWide(Parent:GetWide())
		List:SetSize(Parent:GetWide(), Parent:GetTall() - Header:GetTall())
		List:SetPos(0, Header:GetTall())
	end

	function List:OnRowSelected(rowIndex, row)
		if row.Spike then onSelect(row.Spike) end
	end

	local function Populate()
		if not IsValid(List) then return end

		List:Clear()

		for _, spike in ipairs(GProfiler.Spikes.Data[getRealm()] or {}) do
			local worst = spike.Entries and spike.Entries[1]
			local line = GProfiler.Utils.AddSortedLine(List, {
				{ string.format("%.2fs", spike.At), spike.At },
				{ GProfiler.Utils.FormatTime(spike.Gap), spike.Gap },
				{ GProfiler.Utils.FormatTime(spike.Lua), spike.Lua },
				{ GProfiler.Utils.FormatBits(spike.Bits), spike.Bits },
				worst and worst.Name or "nothing tracked"
			})

			line.Spike = spike
		end

		List:SortByColumn(2, true)
	end

	GProfiler.Spikes.RefreshUI = Populate
	Populate()

	return List
end

GProfiler.Utils.OnLarge("Spikes", function(data)
	GProfiler.Spikes.Data.Server = data
	if GProfiler.Spikes.RefreshUI then GProfiler.Spikes.RefreshUI() end
end)
