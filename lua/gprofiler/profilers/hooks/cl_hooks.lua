GProfiler.Hooks = GProfiler.Hooks or {}
local Hooks = GProfiler.Hooks
Hooks.Realm = Hooks.Realm or "Client"

local HooksStore = GProfiler.Profilers.GetStore("Hooks")

function GProfiler.Hooks.DoTab(Base, Outer)
	local Header = GProfiler.Utils.SetupHeader(Outer, "Hooks", "gprofiler/hooks.png")
	local initialActive = Hooks.Realm == "Both" and (HooksStore:IsActive("Client") or HooksStore:IsActive("Server")) or HooksStore:IsActive(Hooks.Realm)
	local StartStop = Header:SetupStartStop(initialActive)
	local RealmSelector = Header:SetupRealmSelector(Hooks.Realm, true)
	local Timer = Header:SetupTimer(function()
		local realm = Hooks.Realm == "Both" and "Client" or Hooks.Realm
		return HooksStore:GetTimerData(realm)
	end)

	Base:SetPos(GProfiler.GetScaledSize(10), Header:GetTall() + GProfiler.GetScaledSize(12))
	Base:SetSize(Outer:GetWide() - GProfiler.GetScaledSize(20), Outer:GetTall() - Header:GetTall() - GProfiler.GetScaledSize(22))
	Base.OnHandleMoved = function()
		Header:SetWide(Outer:GetWide())
		Base:SetSize(Outer:GetWide() - GProfiler.GetScaledSize(20), Outer:GetTall() - Header:GetTall() - GProfiler.GetScaledSize(22))
		Header.OnHandleMoved()
	end

	function StartStop:OnStateChanged(Running)
		GProfiler.Profilers.Toggle("Hooks", Hooks.Realm, Running)

		if Hooks.RefreshUI then
			Hooks.RefreshUI()
		end
	end

	function RealmSelector:OnStateChanged(state)
		Hooks.Realm = state
		if state == "Both" then
			StartStop.State = HooksStore:IsActive("Client") or HooksStore:IsActive("Server")
		else
			StartStop.State = HooksStore:IsActive(state)
		end
		StartStop:SetText(StartStop.State and "Stop" or "Start")
		if Hooks.RefreshUI then
			Hooks.RefreshUI()
		end
	end

	local left, Source = GProfiler.Utils.VSplitPanel(Base, GProfiler.GetScaledSize(10), "hook_lr", 0.65)
	local Results, Receivers = GProfiler.Utils.HSplitPanel(left, GProfiler.GetScaledSize(10), "hook_l_bt", 0.65)
	local OwnersPanel, SpikesPanel = GProfiler.Utils.VSplitPanel(Receivers, GProfiler.GetScaledSize(10), "hook_lb_lr", 0.5)

	local SourceHeader = vgui.Create("DLabel", Source)
	SourceHeader:SetFont("GProfiler.Inter24")
	SourceHeader:SetTextColor(GProfiler.SyntaxColors.comment)
	SourceHeader:SetPos(GProfiler.GetScaledSize(10), GProfiler.GetScaledSize(5))
	SourceHeader:SetSize(Source:GetWide() - GProfiler.GetScaledSize(20), GProfiler.GetScaledSize(24))
	SourceHeader:SetText("Select a hook to view source.")

	Source.Paint = function(s, w, h)
		GProfiler.RNDX.DrawScaled(8, 0, 0, w, h, GProfiler.SyntaxColors.background, GProfiler.RNDX.NO_BR + GProfiler.RNDX.NO_BL)
	end

	local RichText = vgui.Create("RichText", Source)
	RichText:SetText("")
	RichText:SetSize(Source:GetWide() - GProfiler.GetScaledSize(20), Source:GetTall() - GProfiler.GetScaledSize(20) - GProfiler.GetScaledSize(30))
	RichText:SetPos(GProfiler.GetScaledSize(10), GProfiler.GetScaledSize(30))
	RichText:SetVerticalScrollbarEnabled(true)
	function RichText:PerformLayout()
		self:SetFontInternal("GProfiler.Code")
	end

	Source.OnHandleMoved = function()
		SourceHeader:SetSize(Source:GetWide() - GProfiler.GetScaledSize(20), GProfiler.GetScaledSize(24))
		RichText:SetSize(Source:GetWide() - GProfiler.GetScaledSize(20), Source:GetTall() - GProfiler.GetScaledSize(20) - GProfiler.GetScaledSize(30))
		RichText:SetPos(GProfiler.GetScaledSize(10), GProfiler.GetScaledSize(30))
		RichText:InvalidateLayout()
	end

	local Header = GProfiler.Utils.SetupHeader(Results, "Profiler Results", nil, true)
	local ResultsList = GProfiler.Utils.CreateList(Results, Header, {"Hook", "Count", "Time (Total)", "Time (Avg)", "Time (Longest)"})
	local OwnersHeader = GProfiler.Utils.SetupHeader(OwnersPanel, "By Module", nil, true)
	local OwnersList = GProfiler.Utils.CreateList(OwnersPanel, OwnersHeader, {"Owner", "Hooks", "Calls", "Time (Total)", "Time (Longest)"})
	GProfiler.Utils.WidenNameColumn(ResultsList)
	GProfiler.Utils.WidenNameColumn(OwnersList)

	OwnersPanel.OnHandleMoved = function()
		OwnersHeader:SetWide(OwnersPanel:GetWide())
		OwnersList:SetSize(OwnersPanel:GetWide(), OwnersPanel:GetTall() - OwnersHeader:GetTall())
		OwnersList:SetPos(0, OwnersHeader:GetTall())
	end

	local function GetDisplayRealm()
		return Hooks.Realm == "Both" and "Client" or Hooks.Realm
	end

	local function PopulateOwners(realmData)
		OwnersList:Clear()

		local owners = {}
		for _, v in pairs(realmData) do
			local key = v.o or "other"
			local owner = owners[key]
			if not owner then
				owner = { Hooks = 0, Calls = 0, Total = 0, Longest = 0 }
				owners[key] = owner
			end

			owner.Hooks = owner.Hooks + 1
			owner.Calls = owner.Calls + v.c
			owner.Total = owner.Total + v.t
			owner.Longest = math.max(owner.Longest, v.m or 0)
		end

		for name, owner in pairs(owners) do
			GProfiler.Utils.AddSortedLine(OwnersList, {
				name,
				owner.Hooks,
				owner.Calls,
				{ GProfiler.Utils.FormatTime(owner.Total), owner.Total },
				{ GProfiler.Utils.FormatTime(owner.Longest), owner.Longest }
			})
		end

		OwnersList:SortByColumn(4, true)
	end

	local function PopulateResults()
		if not IsValid(ResultsList) then return end

		local realmData = HooksStore:GetData(GetDisplayRealm()) or {}

		ResultsList:Clear()

		for k, v in pairs(realmData) do
			local average = v.c > 0 and v.t / v.c or 0
			local row = GProfiler.Utils.AddSortedLine(ResultsList, {
				v.d or string.format("%s (%s)", v.r, v.h),
				v.c,
				{ GProfiler.Utils.FormatTime(v.t), v.t },
				{ GProfiler.Utils.FormatTime(average), average },
				{ GProfiler.Utils.FormatTime(v.m), v.m or 0 }
			})
			row.HookData = v
		end

		ResultsList:SortByColumn(3, true)
		PopulateOwners(realmData)
	end
	GProfiler.Hooks.RefreshUI = PopulateResults
	PopulateResults()

	function ResultsList:OnRowSelected(rowIndex, row)
		local data = row.HookData
		if data then
			RichText:SetText("Loading source...")
			SourceHeader:SetText("")

			local file = data.Source or data[4]
			local lineDefined = data.Lines and data.Lines[1] or data[5] or 0
			local lastLineDefined = data.Lines and data.Lines[2] or data[6] or 0

			if file and file ~= "" then
				file = string.match(file, "@?(.+)")
				if not file then file = data.Source or data[4] end

				SourceHeader:SetText(string.format("%s (%d - %d)", file, lineDefined, lastLineDefined))

				GProfiler.RequestFunctionSource(file, lineDefined, lastLineDefined, function(src)
					if src then
						GProfiler.SyntaxHighlight(RichText, table.concat(src, ""), lineDefined)
					else
						RichText:SetText("Failed to load source")
					end
				end)
			else
				RichText:SetText("Failed to load source (2)")
			end
		end
	end

	GProfiler.Utils.CreateSpikeList(SpikesPanel, GetDisplayRealm, function(spike)
		SourceHeader:SetText("Spike frame")
		RichText:SetText(GProfiler.Utils.DescribeSpike(spike))
	end)

	Results.OnHandleMoved = function()
		ResultsList:SetSize(Results:GetWide(), Results:GetTall() - Header:GetTall())
		ResultsList:SetPos(0, Header:GetTall())
		Header:SetWide(Results:GetWide())
	end
end

GProfiler.Menu.RegisterTab("Hooks", "gprofiler/hooks.png", 1, Hooks.DoTab, function()
	local timer = HooksStore:GetTimerData(Hooks.Realm)
	if timer.StartTime == 0 then return end
	return GProfiler.TimeRunning(timer.StartTime, timer.EndTime, timer.ProfileActive), timer.ProfileActive
end)

GProfiler.Utils.OnLarge("Hooks", function(data)
	HooksStore:SetData("Server", data)
	if Hooks.RefreshUI then Hooks.RefreshUI() end
end)
