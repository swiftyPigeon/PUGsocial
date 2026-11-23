local ADDON, ns = ...

-- The add-on's names, its saved data and the helpers every other file uses. The event and
-- timer helpers, and the way names are written, follow Guild Master Forever's Core.lua (MIT,
-- see LICENSE.txt).

ns.NAME = "PUG Social" -- the name players see (the add-on, its folder, saved data and channels stay Pugger)
ns.VERSION = "0.1.7"
ns.PREFIX = "PUGGER"                  -- add-on message prefix (16 characters at most)
ns.CHANNELS = { Alliance = "PuggerA", Horde = "PuggerH" } -- + 1, 2, 3...: the numbered channels
ns.CHANNEL_MAX = 6                   -- the last backup channel tried
ns.ICON = "Interface\\AddOns\\Pugger\\media\\logo64"  -- the logo: a p wrapped in a ring, white on blue (the add-on list, cards)
ns.ICON_SMALL = "Interface\\AddOns\\Pugger\\media\\logo32" -- ...drawn for 18-20 px: the header, the minimap and map buttons
ns.ICON_MENTION = "Interface\\AddOns\\Pugger\\media\\bubble64" -- the Mentions tab and its cards: a speech bubble
ns.ICON_GROUPS = "Interface\\AddOns\\Pugger\\media\\stone64" -- the Groups tab and dungeon groups: a meeting stone
ns.ICON_SQUIRCLE = "Interface\\AddOns\\Pugger\\media\\squircle64" -- the button by the chat: the logo in a rounded square
ns.COLOR = "ffe2b65c"                -- the gold of the window's trim
-- Test copies only (tools/install-test-mop.sh sets it; nil in a release): /pug testnet then
-- sends the feed over the guild or the party instead of the channel (Comm.lua).
ns.TEST_COPY = nil

-- What every character starts with (ns.db.settings), each switchable in the window's menu.
local DEFAULTS = {
	showFollows = false,    -- others may see who this player follows (on the profile)
	mentionPopups = true,   -- a card beside the minimap when someone mentions this player
	mentionsFollowedOnly = false, -- ...only from people this player follows
	rarePopups = true,      -- a card for a rare call in this zone
	groupPopups = true,     -- a card for a quest group call nearby
	dungeonPopups = true,   -- a card for a dungeon group at a stone close by
	dungeons = {},          -- ...only for these dungeons (Stones keys = true); empty: every dungeon
	groupLevelOnly = true,  -- group cards only at a fitting level
	cardsOff = false,       -- no cards at all (asks on the player's own calls still come)
	pauseUntil = 0,         -- ...or none until this time (the menu's "pause for an hour")
	cardSound = true,       -- a card plays the whisper sound
	showRares = true, showCamps = true, showGroups = true, -- on the world map and minimap
	groupsInRealm = true,   -- dungeon calls as a small line in the Realm timeline
	asks = "all",           -- who may ask to join this player's calls: all | friends | off
	minimapAngle = 200,
	launcher = "chat",      -- Pugger's button: "chat" (above the game's social button, while the window
	                        -- is closed), "minimap", or "both"
	cardsAt = "chat",       -- where cards show: "chat" (stacked up from above the chat), "minimap"
	                        -- (beside it) or "top" (the top of the screen)
	setupDone = false,      -- the first-launch setup (where the button and cards go) was seen
	alpha = 1,              -- the window's transparency
	hideInCombat = false,
	quietInGroups = true,   -- in a dungeon, raid, battleground or arena with others: no window, no cards
	debug = false,
	words = {},             -- the word filter: lower-case words or #tags that hide a post
}
ns.DEFAULTS = DEFAULTS

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Server time when the game gives it: every client stamps posts with the same clock.
function ns.Now()
	if GetServerTime then
		local t = GetServerTime()
		if t and t > 0 then return t end
	end
	return time()
end

-- Is any of these a secret value (newer clients, Forever's among them, hand some game data
-- over as one: an add-on may pass it on, but not compare it, index with it or read it)?
function ns.Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) == true then return true end
	end
	return false
end

function ns.Print(msg)
	print("|c" .. ns.COLOR .. ns.NAME .. ":|r " .. tostring(msg))
end

-- At most n bytes of s, never half a letter (an accented letter is two bytes or more).
function ns.Cut(s, n)
	s = tostring(s or "")
	if #s <= n then return s end
	local b = s:byte(n + 1)
	while n > 0 and b and b >= 128 and b < 192 do
		n = n - 1
		b = s:byte(n + 1)
	end
	return s:sub(1, n)
end

-- Letters, not bytes (the 200-character limit of a post counts what the player sees).
function ns.Letters(s)
	local _, n = tostring(s or ""):gsub("[^\128-\191]", "")
	return n
end

function ns.Ago(t)
	local d = math.max(0, ns.Now() - (tonumber(t) or 0))
	if d < 60 then return ns.L.AGO_NOW end
	if d < 3600 then return ns.L.AGO_MIN:format(math.floor(d / 60)) end
	if d < 86400 then return ns.L.AGO_HOUR:format(math.floor(d / 3600)) end
	return ns.L.AGO_DAY:format(math.floor(d / 86400))
end

function ns.Count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

---------------------------------------------------------------------------
-- Names. Identity is always "Name-Realm", as the server stamps add-on messages. WoW: Forever's
-- names are a first name and a surname ("Firstname Surname"): its unit functions hand the
-- surname back where the realm goes (UnitFullName gives "Firstname", "Surname"; GetUnitName
-- "Firstname-Surname"), while the server writes "Firstname Surname-Realm". ns.splitNames: this
-- client splits names so.
---------------------------------------------------------------------------

-- The realm the game reports, in the form the server uses in "Name-Realm" (no spaces or
-- dashes), or "" when it reports none.
function ns.GameRealm()
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not realm or realm == "" then realm = (((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "")) end
	return type(realm) == "string" and realm or ""
end

-- The realm this character had, for a client that reports none (WoW: Forever 1.60.1 can:
-- GetRealmName "", GetRealmID 0). db.realmOf[character, lowercased, no realm] = realm, saved at
-- each login the game said it (ns.RememberRealm); before that was ever saved, this character's
-- entry in db.chars ("Name-Realm", the realm as the server wrote it). nil when neither knows.
local function CharacterKeys()
	local keys = {}
	local name, second = nil, nil
	if UnitFullName then name, second = UnitFullName("player") end
	if type(name) ~= "string" or name == "" then name = UnitName and UnitName("player") end
	if type(name) ~= "string" or name == "" then return keys end
	if type(second) == "string" and second ~= "" then keys[#keys + 1] = (name .. " " .. second):lower() end
	keys[#keys + 1] = name:lower()
	return keys
end

function ns.RememberedRealm()
	local db = ns.db
	if type(db) ~= "table" then return nil end
	local keys = CharacterKeys()
	if type(db.realmOf) == "table" then
		for _, k in ipairs(keys) do
			local r = db.realmOf[k]
			if type(r) == "string" and r ~= "" then return r end
		end
	end
	if type(db.chars) == "table" then
		for _, k in ipairs(keys) do
			for entry in pairs(db.chars) do
				local n, r = tostring(entry):match("^(.-)%-([^%-]+)$")
				if n and n:lower() == k and r ~= "?" then return r end
			end
		end
	end
	return nil
end

-- At login: the realm the game reports, kept for this character (nothing when it reports none).
function ns.RememberRealm(me)
	local realm = ns.GameRealm()
	if realm == "" or type(ns.db) ~= "table" or type(me) ~= "string" then return end
	ns.db.realmOf = type(ns.db.realmOf) == "table" and ns.db.realmOf or {}
	ns.db.realmOf[(me:gsub("%-[^%-]*$", "")):lower()] = realm
end

-- This realm's key: the one the game reports, else the one this character had (ns.RememberedRealm),
-- so its identity ("Name-Realm"), its key and its feed stay the same. "?" only when nothing is known.
function ns.CurrentRealm()
	local realm = ns.GameRealm()
	if realm == "" and ns.RememberedRealm then realm = ns.RememberedRealm() or "" end
	return realm ~= "" and realm or "?"
end

ns.knownRealms = {} -- realms seen in the senders' names this session

function ns.IsRealmName(realm)
	if type(realm) ~= "string" or realm == "" then return false end
	return realm == ns.realm or realm == ns.CurrentRealm() or ns.knownRealms[realm] == true
end

function ns.ShortName(name)
	if not name then return nil end
	return (name:gsub("%-[^%-]*$", ""))
end

function ns.RealmOf(name)
	return name and name:match("%-([^%-]+)$")
end

function ns.FullName(name, realm)
	if not name or name == "" or name:find("-", 1, true) then return name end
	realm = realm or ns.realm
	if not realm or realm == "" or realm == "?" then return name end
	return name .. "-" .. realm
end

-- A name the game's functions give ("First-Surname" on Forever), as the server writes it.
function ns.Normal(name)
	if not ns.splitNames or type(name) ~= "string" then return name end
	local first, rest = name:match("^([^%-]+)%-(.+)$")
	if not first or first:find(" ", 1, true) then return name end
	local surname, realm = rest:match("^([^%-]+)%-(.+)$")
	if surname and ns.IsRealmName(realm) then return first .. " " .. surname .. "-" .. realm end
	if ns.IsRealmName(rest) then return name end
	return first .. " " .. rest
end

-- Any name from the wire or the game, as the add-on keeps it: "Name-Realm".
function ns.Key(name)
	if type(name) ~= "string" or name == "" then return nil end
	return ns.FullName(ns.Normal(name))
end

function ns.PlayerName()
	local name, realm = UnitFullName("player")
	if not name then name = UnitName("player") end
	if not name then return "?" end
	local home = ns.realm or ns.CurrentRealm()
	if realm and realm ~= "" and realm ~= home and not ns.IsRealmName(realm) then
		ns.splitNames = true
		name, realm = name .. " " .. realm, nil
	end
	if not realm or realm == "" then realm = home end
	if realm and realm ~= "" and realm ~= "?" then return name .. "-" .. realm end
	return name
end

-- Short name for people on our realm, Name-Realm for anyone else.
function ns.DisplayName(name)
	if not name then return "?" end
	local realm = ns.RealmOf(name)
	if not realm or realm == ns.realm then return ns.ShortName(name) end
	return name
end

-- The name a whisper or an invite takes: the short name on our realm.
function ns.TellName(name)
	if type(name) ~= "string" or name == "" then return name end
	local base, realm = name:match("^(.+)%-([^%-]+)$")
	if realm and (realm == ns.realm or realm == ns.CurrentRealm()) then return base end
	return name
end

function ns.IsMe(name) return name ~= nil and name == ns.me end

---------------------------------------------------------------------------
-- Log (a ring buffer in the SavedVariables, read by /pug bug)
---------------------------------------------------------------------------

function ns.Log(fmt, ...)
	local msg
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		msg = ok and res or tostring(fmt)
	else
		msg = tostring(fmt)
	end
	local db = ns.db
	if not db then return end
	local log = db.log
	log[#log + 1] = date("%m-%d %H:%M:%S ") .. msg
	while #log > 300 do table.remove(log, 1) end
	if db.settings.debug then ns.Print("|cff999999" .. msg .. "|r") end
end

---------------------------------------------------------------------------
-- Internal callbacks and WoW events. Every handler runs protected, so one bug never breaks
-- the rest of the add-on; errors go to ns.CaptureError (Diagnostics.lua).
---------------------------------------------------------------------------

function ns.SafeCall(where, fn, ...)
	ns.lastWhere = where
	local ok, err = pcall(fn, ...)
	if not ok and ns.CaptureError then ns.CaptureError(where, err) end
	return ok, err
end

local listeners = {}
function ns.On(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
	local l = listeners[name]
	if not l then return end
	for i = 1, #l do ns.SafeCall("callback " .. name, l[i], ...) end
end

local eventFrame = CreateFrame("Frame")
local handlers = {}
function ns.RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local h = handlers[event]
	if not h then return end
	for i = 1, #h do ns.SafeCall("event " .. event, h[i], ...) end
end)

-- Quiet: in a group instance (a dungeon, raid, battleground, arena or scenario with at least one
-- other player), when the player keeps the switch on. The window steps aside and cards wait.
function ns.Quiet()
	if not (ns.db and ns.db.settings.quietInGroups) then return false end
	local inside, kind = false, nil
	if IsInInstance then inside, kind = IsInInstance() end
	if not inside or kind == "none" then return false end
	return (IsInGroup and IsInGroup()) or (GetNumGroupMembers and GetNumGroupMembers() > 1) or false
end

function ns.After(seconds, where, fn)
	C_Timer.After(seconds, function() ns.SafeCall(where, fn) end)
end
-- A ticker that starts after a random part of its period (at most a minute), so the tickers
-- started at login don't all tick on one frame.
function ns.Every(seconds, where, fn)
	local ticker, cancelled = nil, false
	local handle = {}
	function handle.Cancel()
		cancelled = true
		if ticker and ticker.Cancel then ticker:Cancel() end
	end
	local function Tick() if not cancelled then ns.SafeCall(where, fn) end end
	C_Timer.After(math.min(seconds, 60) * math.random(), function()
		if not cancelled then ticker = C_Timer.NewTicker(seconds, Tick) end
	end)
	return handle
end

---------------------------------------------------------------------------
-- Saved data. PuggerDB = {
--   settings = {...} (DEFAULTS), log = {}, errors = {},
--   chars = { [Name-Realm] = { window = {...}, seed = <secret key, base64>, pk = ... } },
--   realmOf = { [character, lowercased, no realm] = realm } (ns.RememberedRealm),
--   feeds = { [Ruleset-Faction] = the feed this character's ruleset and faction share (Store.lua);
--             Realm-Faction where the realm's name gives no ruleset },
-- }
-- Each feed belongs to one ruleset and faction: Horde and Alliance never share one, nor PvE and PvP.
---------------------------------------------------------------------------

local function Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			if type(v) == "table" then
				local copy = {}
				for kk, vv in pairs(v) do copy[kk] = vv end
				t[k] = copy
			else
				t[k] = v
			end
		end
	end
end

function ns.Faction()
	local f = UnitFactionGroup and UnitFactionGroup("player")
	return (f == "Horde" or f == "Alliance") and f or nil
end

-- The ruleset a realm belongs to, from the end of its name (Forever: "CAMWOWUS1Realm7PvE"); nil
-- for a realm whose name says none (other clients, test realms). On Forever a ruleset is many
-- realms: guilds and groups span them, and players of one ruleset and faction play together
-- whatever realm they're on, never with another ruleset's.
local RULESETS = { -- longest first: "RPPvP" before "PvP" and "RP"
	{ "rppvp", "RPPvP" }, { "hardcore", "Hardcore" }, { "pvp", "PvP" }, { "pve", "PvE" }, { "rp", "RP" },
}
function ns.Ruleset(realm)
	if type(realm) ~= "string" then return nil end
	local low = realm:gsub("[%s%-]", ""):lower()
	-- (A ruleset at the end, after a digit: "Realm7PvE", never a realm merely ending in "rp".)
	for _, r in ipairs(RULESETS) do
		if #low > #r[1] and low:sub(-#r[1]) == r[1] and low:sub(-#r[1] - 1, -#r[1] - 1):match("%d") then return r[2] end
	end
	return nil
end

-- The feed of this ruleset and faction (of this realm, where no ruleset is known): made the
-- first time.
function ns.FeedKey()
	return (ns.ruleset or ns.realm) .. "-" .. (ns.faction or "?")
end

-- 0.1.4: feeds were per realm. The ones of this ruleset and faction become its feed: follows,
-- mutes, blocks, likes and profiles kept (merged when two realms had one), on channel 1 again
-- (the channels are new).
local function Merge(into, from)
	for k, v in pairs(from) do
		if type(v) == "table" and type(into[k]) == "table" then
			for kk, vv in pairs(v) do if into[k][kk] == nil then into[k][kk] = vv end end
		elseif into[k] == nil then
			into[k] = v
		end
	end
	if tonumber(from.counter) and tonumber(into.counter) then into.counter = math.max(into.counter, from.counter) end
end
local function MoveRealmFeeds(db, key)
	if not ns.ruleset or not ns.faction then return end
	local moved = false
	for old, feed in pairs(db.feeds) do
		local realm, faction = old:match("^(.+)%-(%a+)$")
		if old ~= key and type(feed) == "table" and faction == ns.faction and realm ~= ns.ruleset and ns.Ruleset(realm) == ns.ruleset then
			db.feeds[key] = db.feeds[key] or {}
			Merge(db.feeds[key], feed)
			db.feeds[old] = nil
			moved = true
		end
	end
	if moved then
		db.feeds[key].channel = 1
		ns.Log("realm feeds moved to %s", key)
	end
end
ns.MoveRealmFeeds = MoveRealmFeeds

local function OpenFeed()
	local db = ns.db
	local key = ns.FeedKey()
	MoveRealmFeeds(db, key)
	db.feeds[key] = db.feeds[key] or {}
	ns.rdb = db.feeds[key]
	Fill(ns.rdb, {
		posts = {}, tombs = {}, profiles = {}, follows = {}, mutes = {}, blocks = {},
		myLikes = {}, counter = 0, channel = 1, trusted = {}, slow = {},
	})
end
ns.OpenFeed = OpenFeed

ns.RegisterEvent("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	PuggerDB = PuggerDB or {}
	local db = PuggerDB
	ns.db = db
	db.settings = db.settings or {}
	-- (Until 0.1.2 one switch, groupPopups, was for dungeon groups too.)
	if db.settings.dungeonPopups == nil and db.settings.groupPopups ~= nil then db.settings.dungeonPopups = db.settings.groupPopups end
	Fill(db.settings, DEFAULTS)
	db.log = db.log or {}
	db.errors = db.errors or {}
	db.chars = db.chars or {}
	db.feeds = db.feeds or {}
	db.stones = db.stones or {}  -- meeting stones this player recorded (/pug stone here)
	db.measure = db.measure or {} -- Phase 0's results (Measure.lua)
	ns.Fire("LOADED")
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
	ns.realm = ns.CurrentRealm()
	ns.ruleset = ns.Ruleset(ns.realm)
	ns.faction = ns.Faction()
	ns.me = ns.PlayerName()
	-- The realm kept while the game says it, and said when it was not (ns.CurrentRealm).
	ns.RememberRealm(ns.me)
	if ns.GameRealm() == "" then ns.Log("the game reports no realm: using %s", tostring(ns.realm)) end
	ns.db.chars[ns.me] = ns.db.chars[ns.me] or {}
	ns.cdb = ns.db.chars[ns.me]
	OpenFeed()
	ns.Log("login %s (%s) %s", ns.me, tostring(ns.faction), ns.VERSION)
	ns.Fire("LOGIN")
end)

-- A slow load can leave the faction unknown at login: the feed opens once the game says it.
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
	if ns.faction or not ns.db or not ns.me then return end
	ns.faction = ns.Faction()
	if ns.faction then
		OpenFeed()
		ns.Fire("FACTION")
	end
end)
