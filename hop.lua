local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = game.PlaceId
local CURRENT_JOB_ID = game.JobId

-- Map each sea's PlaceId to its dedicated host base
local function resolveHostBaseForPlace(placeId)
	if placeId == 2753915549 then -- Sea 1
		return "http://127.0.0.1:5001"
	elseif placeId == 4442272183 then -- Sea 2
		return "http://127.0.0.1:5002"
	elseif placeId == 7449423635 then -- Sea 3
		return "http://127.0.0.1:5003"
	end
	-- Fallback (single host setup)
	return "http://127.0.0.1:5000"
end

-- How often to fetch and try teleport (seconds)
local FETCH_INTERVAL_SECONDS = 60
-- Brief delay before teleport for stability (seconds)
local PRE_TELEPORT_WAIT_SECONDS = 1
-- 30-minute initial delay before the script starts running
local INITIAL_DELAY_SECONDS = 1800
-- Optional cooldown after each successful teleport (set 1800 to enable)
local AFTER_TELEPORT_COOLDOWN_SECONDS = 0
-- Remember recently visited server ids to reduce duplicate teleports
local RECENT_MAX = 2000
local MAX_SAMPLE = 300

local recentSet = {}
local recentQueue = {}

local function safeWait(seconds)
	local t0 = os.clock()
	repeat
		wait(0.25)
	until os.clock() - t0 >= seconds
end

local function rememberServer(id)
	if not id then return end
	if not recentSet[id] then
		recentSet[id] = true
		table.insert(recentQueue, id)
		if #recentQueue > RECENT_MAX then
			local old = table.remove(recentQueue, 1)
			recentSet[old] = nil
		end
	end
end

local function isRecentlyUsed(id)
	return id and recentSet[id] == true
end

local function trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Prefer /ids_unclaimed → /ids → /latest JSON
local function fetchIds()
	local base = resolveHostBaseForPlace(PLACE_ID)
	-- Try /ids_unclaimed first
	local ok0, body0 = pcall(game.HttpGet, game, base .. "/ids_unclaimed")
	if ok0 and type(body0) == "string" and #body0 > 0 then
		local ids = {}
		for line in string.gmatch(body0, "([^\r\n]+)") do
			local id = trim(line)
			if #id > 0 then table.insert(ids, id) end
		end
		if #ids > 0 then return ids end
	end
	-- Fallback /ids
	local ok, body = pcall(game.HttpGet, game, base .. "/ids")
	if ok and type(body) == "string" and #body > 0 then
		local ids = {}
		for line in string.gmatch(body, "([^\r\n]+)") do
			local id = trim(line)
			if #id > 0 then table.insert(ids, id) end
		end
		if #ids > 0 then return ids end
	end
	-- Fallback to JSON
	local ok2, jsonRaw = pcall(game.HttpGet, game, base .. "/latest")
	if not ok2 then return {} end
	local decoded = nil
	pcall(function()
		decoded = HttpService:JSONDecode(jsonRaw)
	end)
	local ids = {}
	if decoded and decoded.data and type(decoded.data) == "table" then
		for _, srv in ipairs(decoded.data) do
			local sid = srv and srv.id
			if type(sid) == "string" and #sid > 0 then table.insert(ids, sid) end
		end
	end
	return ids
end

local function shuffle(list)
	for i = #list, 2, -1 do
		local j = math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local function pickFromIds(allIds)
	local filtered = {}
	for _, sid in ipairs(allIds) do
		if type(sid) == "string" and sid ~= CURRENT_JOB_ID and not isRecentlyUsed(sid) then
			table.insert(filtered, sid)
		end
	end
	local n = #filtered
	if n == 0 then return nil end
	shuffle(filtered)
	local offset = math.random(0, n - 1)
	local stride = math.random(1, math.max(1, math.floor(n / 7)))
	local limit = math.min(MAX_SAMPLE, n)
	local checked = 0
	local idx = offset + 1
	while checked < limit do
		local sid = filtered[idx]
		if sid and not isRecentlyUsed(sid) then
			return sid
		end
		checked = checked + 1
		idx = (((idx - 1 + stride) % n) + 1)
	end
	return filtered[math.random(1, n)]
end

-- Return values:
--   true  → claim accepted (safe to use)
--   false → claim endpoint rejected (someone else claimed)
--   nil   → claim endpoint unavailable (proceed without claim)
local function tryClaim(id)
	local base = resolveHostBaseForPlace(PLACE_ID)
	local url = base .. "/claim?id=" .. HttpService:UrlEncode(id)
	local ok, resp = pcall(game.HttpGet, game, url)
	if not ok or type(resp) ~= "string" or #resp == 0 then
		return nil
	end
	local parsed = nil
	local okj = pcall(function()
		parsed = HttpService:JSONDecode(resp)
	end)
	if not okj or type(parsed) ~= "table" then
		return nil
	end
	if parsed.ok and parsed.claimed == true then
		return true
	end
	if parsed.ok and parsed.claimed == false then
		return false
	end
	return nil
end

local function preTeleport()
	local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp then
		pcall(function()
			hrp.Anchored = true
		end)
		wait(PRE_TELEPORT_WAIT_SECONDS)
	end
end

math.randomseed(os.clock() * 1000000)

-- Initial 30-minute delay before starting the loop
safeWait(INITIAL_DELAY_SECONDS)

while true do
	local ok, ids = pcall(fetchIds)
	if ok and type(ids) == "table" and #ids > 0 then
		local attempts = 0
		local targetId = nil
		while attempts < 20 do
			local candidate = pickFromIds(ids)
			if not candidate then break end
			local claimResult = tryClaim(candidate)
			if claimResult == true or claimResult == nil then
				targetId = candidate
				break
			elseif claimResult == false then
				rememberServer(candidate)
			end
			attempts = attempts + 1
		end
		if targetId then
			rememberServer(targetId)
			preTeleport()
			-- Only use game-provided RemoteFunction teleport as requested
			local rf = game:GetService("ReplicatedStorage"):FindFirstChild("__ServerBrowser")
			if rf and rf:IsA("RemoteFunction") then
				pcall(function()
					rf:InvokeServer("teleport", targetId)
				end)
			else
				warn("__ServerBrowser RemoteFunction not found; skipping TeleportService per request")
			end
			if AFTER_TELEPORT_COOLDOWN_SECONDS and AFTER_TELEPORT_COOLDOWN_SECONDS > 0 then
				safeWait(AFTER_TELEPORT_COOLDOWN_SECONDS)
			end
		end
	end
	safeWait(FETCH_INTERVAL_SECONDS)
end
