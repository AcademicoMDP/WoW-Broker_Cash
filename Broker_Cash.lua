
local addon         = LibStub('AceAddon-3.0'):NewAddon('Broker_Cash', 'AceConsole-3.0', 'AceEvent-3.0')
local L             = LibStub('AceLocale-3.0'):GetLocale('Broker_Cash')
local libDataBroker = LibStub('LibDataBroker-1.1')
local libQTip       = LibStub('LibQTip-1.0')

local FIRST_DAY_OF_WEEK   = 2	-- Lundi par défaut

local tth = select(2, GameTooltipText:GetFontObject():GetFont())
local GOLD_ICON_STRING    = ('|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:2:0|t'):format(tth, tth)
local SILVER_ICON_STRING  = ('|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:2:0|t'):format(tth, tth)
local COPPER_ICON_STRING  = ('|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:2:0|t'):format(tth, tth)
local PLUS_BUTTON_STRING  = ('|TInterface\\Buttons\\UI-PlusButton-Up:%d:%d:2:0|t'):format(tth, tth)
local MINUS_BUTTON_STRING = ('|TInterface\\Buttons\\UI-MinusButton-Up:%d:%d:2:0|t'):format(tth, tth)

local SILVER_PER_GOLD     = _G.SILVER_PER_GOLD
local COPPER_PER_SILVER   = _G.COPPER_PER_SILVER
local COPPER_PER_GOLD     = _G.COPPER_PER_SILVER * _G.SILVER_PER_GOLD

local COLOR_RED           = CreateColor(1.0, 0.1, 0.1, 1)
local COLOR_RED_DIMMED    = CreateColor(0.8, 0.1, 0.1, 1)
local COLOR_GREEN         = CreateColor(0.1, 1.0, 0.1, 1)
local COLOR_GREEN_DIMMED  = CreateColor(0.1, 0.8, 0.1, 1)
local COLOR_YELLOW        = CreateColor(1.0, 1.0, 0.1, 1)
local COLOR_YELLOW_DIMMED = CreateColor(0.8, 0.8, 0.1, 1)

-------------------------------------------------------------------------------
local defaults = {
	global = {
		firstDoW    = FIRST_DAY_OF_WEEK,
		showSession = false,
		showDay     = true,
		showWeek    = true,
		showMonth   = true,
		showYear    = true,
		folds       = {}
	},
	char = {
		money       = -1,
		since       = 0,
		lastSaved   = 0,
		day         = 0,
		week        = 0,
		month       = 0,
		year        = 0
	}
}

-------------------------------------------------------------------------------
local function GetAbsoluteMoneyString(money)
	local gold   = math.floor(money / COPPER_PER_GOLD)
	local silver = math.floor((money - (gold * COPPER_PER_GOLD)) / COPPER_PER_SILVER)
	local copper = money % COPPER_PER_SILVER

	local str = string.format('%02d%s', copper, COPPER_ICON_STRING)
	if (silver + gold) > 0 then
		str = string.format('%02d%s ', silver, SILVER_ICON_STRING) .. str
	end
	if gold > 0 then
		str = string.format('%s%s ', BreakUpLargeNumbers(gold), GOLD_ICON_STRING) .. str
	end
	return str
end

local function GetRelativeMoneyString(money)
	if (money or 0) == 0 then
		return COLOR_YELLOW_DIMMED:WrapTextInColorCode('0')
	elseif money < 0 then
		return COLOR_RED_DIMMED:WrapTextInColorCode('-' .. GetAbsoluteMoneyString(-money))
	else
		return COLOR_GREEN_DIMMED:WrapTextInColorCode('+' .. GetAbsoluteMoneyString(money))
	end
end

-------------------------------------------------------------------------------
function addon:OnInitialize()

	-- Royaume et perso courants
	self.charRealm = GetRealmName()
	self.charName  = UnitName('player')
	self.charKey   = self.charName .. ' - ' .. self.charRealm
	self.session   = 0

	-- Charge ou crée les données sauvegardées
	self.db = LibStub('AceDB-3.0'):New('Broker_CashDB', defaults, true)
	self.db.char.since = self.db.char.since	-- S'assure que AceDB est initialisée pour les nouveaux persos

	-- Recense les royaumes et les personnages connus
	self.sortedRealms = {}
	self.sortedChars  = {}
	do
		local h = {}
		for charKey,_ in pairs(rawget(Broker_CashDB, 'char')) do
			local charName, _, charRealm = strsplit(' ', charKey, 3)

			-- Nom du royaume (unique)
			if not h[charRealm] then
				h[charRealm] = true
				table.insert(self.sortedRealms, charRealm)
			end

			-- Nom du personnage
			self.sortedChars[charRealm] = self.sortedChars[charRealm] or {}
			table.insert(self.sortedChars[charRealm], charName)
		end

		-- Trie les royaumes par ordre alphabétique, le royaume courant en premier
		table.sort(self.sortedRealms, function(r1, r2)
			if r1 == addon.charRealm then
				return true
			elseif r2 == addon.charRealm then
				return false
			else
				return r1 < r2
			end
		end)
	end

	-- Crée l'icône LDB
	self.dataObject = libDataBroker:NewDataObject('Broker_Cash', {
		type    = 'data source',
		icon    = 'Interface\\MINIMAP\\TRACKING\\Banker',
		text    = 'Cash',
		OnEnter = function(f) addon:ShowMainTooltip(f) end
	})

	-- Texture pour surligner l'icône LDB
	self.highlightFrame = CreateFrame('Frame')
	self.highlightFrame:Hide()
	self.highlightTexture = self.highlightFrame:CreateTexture(nil, 'OVERLAY')
	self.highlightTexture:SetTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight')
	self.highlightTexture:SetBlendMode('ADD')
end

-------------------------------------------------------------------------------
function addon:OnEnable()

	-- Première connexion avec ce perso ?
	if self.db.char.money == -1 then
		self.db.char.money     = GetMoney()
		self.db.char.since     = time()
		self.db.char.lastSaved = self.db.char.since
	end

	-- Sauve les données actuelles
	-- (fait ici car l'addon peut être activé/désactivé à tout moment)
	self:PLAYER_MONEY()

	-- Surveille les événements
	self:RegisterEvent('PLAYER_MONEY')
end

function addon:OnDisable()
	self:HideMainTooltip()
end

-------------------------------------------------------------------------------
function addon:PLAYER_MONEY()

	-- Vérifie s'il faut réinitialiser les statistiques
	self:CheckStatResets(self.db.char)

	-- Enregistre la dépense / recette
	local money = GetMoney()
	local diff  = money - self.db.char.money

	-- Met à jour la stat de session
	self.session = self.session + diff

	-- Et les stats quotidienne/habdomadaire/mensuelle/annuelle
	self.db.char.money     = money
	self.db.char.day       = (self.db.char.day   or 0) + diff
	self.db.char.week      = (self.db.char.week  or 0) + diff
	self.db.char.month     = (self.db.char.month or 0) + diff
	self.db.char.year      = (self.db.char.year  or 0) + diff
	self.db.char.lastSaved = time()

	-- Met à jour le texte du LDB
	local txt = GetAbsoluteMoneyString(money)
	if self.db.global.showSession and self.session ~= 0 then
		txt = txt .. ' (' .. GetRelativeMoneyString(self.session) .. ')'
	end
	self.dataObject.text = txt
end

-------------------------------------------------------------------------------
function addon:CheckStatResets(charData)

	-- Calcule les dates de réinitialisation des statistiques
	self:CalcResetDates()

	-- Réinitialise les stats qui ont dépassé leur date limite
	-- (à nil plutôt que 0 pour rester consistant avec AceDB)
	local charLastSaved = charData.lastSaved or 0
	if charLastSaved < self.startOfDay   then charData.day   = nil end	-- Quotidienne
	if charLastSaved < self.startOfWeek  then charData.week  = nil end 	-- Hebdomadaire
	if charLastSaved < self.startOfMonth then charData.month = nil end 	-- Mensuelle
	if charLastSaved < self.startOfYear  then charData.year  = nil end 	-- Annuelle
end

-------------------------------------------------------------------------------
function days_in_month(mnth, yr)
	return date('*t', time( { year = yr, month = mnth + 1, day = 0 } ))['day']
end

function addon:CalcResetDates()

	-- On recalcule seulement si on a changé de jour depuis le dernier calcul
	local today = date('*t')
	if (self.yday or 0) == today.yday then return end
	self.yday = today.yday

	-- Toutes les limites sont calculées à 00:00:00
	-- TODO: Gérer l'heure d'été/hiver ?
	local limit = {
		hour = 0,
		min  = 0,
		sec  = 0
	}

	-- Début du jour courant
	limit.day   = today.day
	limit.month = today.month
	limit.year  = today.year
	self.startOfDay = time(limit)

	-- Début de la semaine courante
	limit.day   = today.day - (today.wday >= self.db.global.firstDoW and (today.wday - self.db.global.firstDoW) or (7 - today.wday))
	limit.month = today.month
	limit.year  = today.year
	if (limit.day < 1) then
		limit.month = limit.month - 1
		if limit.month < 1 then
			limit.month = 12
			limit.year = limit.year - 1
		end
		limit.day = days_in_month(limit.month, limit.year) - limit.day
	end
	self.startOfWeek = time(limit)

	-- Début du mois courant
	limit.day   = 1
	limit.month = today.month
	limit.year  = today.year
	self.startOfMonth = time(limit)

	-- Début de l'année courante
	limit.day   = 1
	limit.month = 1
	limit.year  = today.year
	self.startOfYear = time(limit)
end

-------------------------------------------------------------------------------
local function MainTooltip_OnClickRealm(lineFrame, realm)
	-- Replie ou déplie le royaume et rafraîchit le tooltip
	addon.db.global.folds[realm] = not addon.db.global.folds[realm]
	addon:UpdateMainTooltip()
end

local function MainTooltip_OnEnterChar(lineFrame, charKey)
	-- Affiche le second tooltip
	addon:ShowSubTooltip(lineFrame, charKey)
end

local function MainTooltip_OnLeaveChar(lineFrame)
	-- Masque le second tooltip
	addon:HideSubTooltip()
end

function addon:ShowMainTooltip(LDBFrame)
	if not self.mainTooltip then
		self.mainTooltip = libQTip:Acquire('BrokerCash_MainTooltip', 2, 'LEFT', 'RIGHT')
		self.mainTooltip:SmartAnchorTo(LDBFrame)
		self.mainTooltip:SetAutoHideDelay(0.1, LDBFrame, function() addon:HideMainTooltip() end)

		-- Surligne l'icône LDB
		self.highlightTexture:SetParent(LDBFrame)
		self.highlightTexture:SetAllPoints(LDBFrame)
	end
	self:UpdateMainTooltip()
end

function addon:UpdateMainTooltip()
	local mtt = self.mainTooltip
	local ln, rln

	-- Prépare le tooltip
	mtt:Hide()
	mtt:Clear()
	mtt:SetCellMarginV(2)

	-- Header
	mtt:AddHeader(L['Name'], L['Cash'])
	mtt:AddSeparator()

	-- Personnage courant
	mtt:AddLine()
	mtt:AddLine(self.charKey, GetAbsoluteMoneyString(self.db.char.money))
	mtt:AddLine('')
	ln = mtt:AddLine(); mtt:SetCell(ln, 1, L['Session'], GameTooltipTextSmall, 1, 10); mtt:SetCell(ln, 2, GetRelativeMoneyString(self.session),       GameTooltipTextSmall)
	ln = mtt:AddLine(); mtt:SetCell(ln, 1, L['Day'],     GameTooltipTextSmall, 1, 10); mtt:SetCell(ln, 2, GetRelativeMoneyString(self.db.char.day),   GameTooltipTextSmall)
	ln = mtt:AddLine(); mtt:SetCell(ln, 1, L['Week'],    GameTooltipTextSmall, 1, 10); mtt:SetCell(ln, 2, GetRelativeMoneyString(self.db.char.week),  GameTooltipTextSmall)
	ln = mtt:AddLine(); mtt:SetCell(ln, 1, L['Month'],   GameTooltipTextSmall, 1, 10); mtt:SetCell(ln, 2, GetRelativeMoneyString(self.db.char.month), GameTooltipTextSmall)
	ln = mtt:AddLine(); mtt:SetCell(ln, 1, L['Year'],    GameTooltipTextSmall, 1, 10); mtt:SetCell(ln, 2, GetRelativeMoneyString(self.db.char.year),  GameTooltipTextSmall)
	mtt:AddLine('')
	mtt:AddSeparator()
	mtt:AddLine('')

	-- Liste tous les personnages, par ordre des royaumes triés au début
	local charsDB, realmMoney, totalMoney = rawget(Broker_CashDB, 'char'), 0, 0
	for _,realm in ipairs(self.sortedRealms) do

		-- Trie les personnages de ce royaume par ordre de richesse décroissante
		table.sort(self.sortedChars[realm], function(c1, c2)
			return charsDB[c1 .. ' - ' .. realm].money > charsDB[c2 .. ' - ' .. realm].money
		end)

		-- 1/ Nom du royaume + nombre de personnages (la richesse est ajoutée après la boucle)
		rln = mtt:AddLine()
		mtt:SetCell(rln, 1, ('%s %s (%d)'):format(self.db.global.folds[realm] and PLUS_BUTTON_STRING or MINUS_BUTTON_STRING, realm, #self.sortedChars[realm]))
		mtt:SetCellTextColor(rln, 1, COLOR_YELLOW_DIMMED:GetRGBA())

		-- Gestion du clic sur cette ligne
		mtt:SetLineScript(rln, 'OnMouseDown', MainTooltip_OnClickRealm, realm)

		-- 2/ Personnages de ce royaume
		realmMoney = 0
		for _,name in ipairs(self.sortedChars[realm]) do
			local charKey = name .. ' - ' .. realm

			-- Vérifie s'il faut réinitialiser les statistiques de ce personnage
			local charData = charsDB[charKey]
			self:CheckStatResets(charData)

			if not self.db.global.folds[realm] then
				-- Ajoute le personnage (avec une marge à gauche)
				ln = mtt:AddLine()
				mtt:SetCell(ln, 1, name, 1, 20)
				mtt:SetCell(ln, 2, GetAbsoluteMoneyString(charData.money))

				-- Gestion du second tooltip pour cette ligne
				mtt:SetLineScript(ln, 'OnEnter', MainTooltip_OnEnterChar, charKey)
				mtt:SetLineScript(ln, 'OnLeave', MainTooltip_OnLeaveChar)
			end

			-- Comptabilise la richesse par royaume / totale
			realmMoney = realmMoney + charData.money
			totalMoney = totalMoney + charData.money
		end

		-- 3/ Richesse de ce royaume
		mtt:SetCell(rln, 2, GetAbsoluteMoneyString(realmMoney))
		mtt:SetCellTextColor(rln, 2, COLOR_YELLOW_DIMMED:GetRGBA())
		mtt:AddLine()
	end

	-- Ajoute le grand total
	mtt:AddSeparator()
	mtt:AddLine(L['Total'], GetAbsoluteMoneyString(totalMoney))
	mtt:AddLine()

	-- Ouf !
	mtt:Show()
end

function addon:HideMainTooltip()
	self:HideSubTooltip()
	if self.mainTooltip then
		self.mainTooltip:Release()

		-- Cache le surlignage
		self.highlightTexture:SetParent(self.highlightFrame)
	end
	self.mainTooltip = nil
end

-------------------------------------------------------------------------------
function addon:ShowSubTooltip(mainTooltipLine, charKey)
	local charData = rawget(Broker_CashDB, 'char')[charKey]
	local ln

	-- Affiche (ou déplace) le sous-tooltip
	if not self.subTooltip then
		self.subTooltip = libQTip:Acquire('BrokerCash_SubTooltip', 2, 'LEFT', 'RIGHT')
		self.subTooltip:SetFrameLevel(self.mainTooltip:GetFrameLevel() + 1)
	end
	self.subTooltip:SetPoint('TOPLEFT', mainTooltipLine, 'TOPRIGHT', 0, 10)
	self.subTooltip:Clear()
	self.subTooltip:SetFont(GameTooltipTextSmall)
	self.subTooltip:SetCellMarginV(2)

	-- Affiche les données du personnage
	ln = self.subTooltip:AddLine(); self.subTooltip:SetCell(ln, 1, charKey, 2)
	ln = self.subTooltip:AddLine(); self.subTooltip:SetCell(ln, 1, (L['Since']):format(date(L['DateFormat'], charData.since)), 2)
	ln = self.subTooltip:AddLine(); self.subTooltip:SetCell(ln, 1, (L['LastSaved']):format(date(L['DateTimeFormat'], charData.lastSaved)), 2)

	self.subTooltip:AddLine()
	self.subTooltip:AddSeparator()
	self.subTooltip:AddLine()

	if charKey == self.charKey then
		self.subTooltip:AddLine(L['Session'], GetRelativeMoneyString(self.session))
	end
	self.subTooltip:AddLine(L['Day'],   GetRelativeMoneyString(charData.day))
	self.subTooltip:AddLine(L['Week'],  GetRelativeMoneyString(charData.week))
	self.subTooltip:AddLine(L['Month'], GetRelativeMoneyString(charData.month))
	self.subTooltip:AddLine(L['Year'],  GetRelativeMoneyString(charData.year))
	self.subTooltip:Show()
end

function addon:HideSubTooltip()
	if self.subTooltip then
		self.subTooltip:Release()
	end
	self.subTooltip = nil
end
