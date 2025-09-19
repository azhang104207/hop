local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = game.PlaceId
local CURRENT_JOB_ID = game.JobId

-- Map each sea's PlaceId to its dedicated host base
local function resolveHostBaseForPlace(placeId)
	-- Point to your public domain where PHP endpoints are hosted
	return "https://accbloxfruit1.com"
end

local function seaParamForPlace(placeId)
	if placeId == 2753915549 then return "s1" end
	if placeId == 4442272183 then return "s2" end
	if placeId == 7449423635 then return "s3" end
	return "s1"
end

-- How often to fetch and try teleport (seconds)
local FETCH_INTERVAL_SECONDS = 10
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
	local sea = seaParamForPlace(PLACE_ID)
	-- Prefer per-sea ids_unclaimed.php (filters claimed within TTL)
	local ok1, body1 = pcall(game.HttpGet, game, base .. "/ids_unclaimed.php?sea=" .. sea)
	if ok1 and type(body1) == "string" and #body1 > 0 then
		local ids = {}
		for line in string.gmatch(body1, "([^\r\n]+)") do
			local id = trim(line)
			if #id > 0 then table.insert(ids, id) end
		end
		if #ids > 0 then return ids end
	end
	-- Fallback to per-sea ids.php
	local ok2, body2 = pcall(game.HttpGet, game, base .. "/ids.php?sea=" .. sea)
	if ok2 and type(body2) == "string" and #body2 > 0 then
		local ids = {}
		for line in string.gmatch(body2, "([^\r\n]+)") do
			local id = trim(line)
			if #id > 0 then table.insert(ids, id) end
		end
		if #ids > 0 then return ids end
	end
	-- Fallback to legacy aggregated ids.php (no sea param)
	local ok2, body2 = pcall(game.HttpGet, game, base .. "/ids.php")
	if ok2 and type(body2) == "string" and #body2 > 0 then
		local ids = {}
		for line in string.gmatch(body2, "([^\r\n]+)") do
			local id = trim(line)
			if #id > 0 then table.insert(ids, id) end
		end
		if #ids > 0 then return ids end
	end
	return {}
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
	local sea = seaParamForPlace(PLACE_ID)
	local url = base .. "/claim.php?id=" .. HttpService:UrlEncode(id) .. "&sea=" .. sea
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

-- Check current server player count
local function getCurrentServerPlayerCount()
	local playerCount = #Players:GetPlayers()
	return playerCount
end

-- Check if current server has too many players (>5)
local function shouldLeaveCurrentServer()
	local playerCount = getCurrentServerPlayerCount()
	return playerCount > 5
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

-- Check current server player count first
local function checkAndTeleportIfNeeded()
	local playerCount = getCurrentServerPlayerCount()
	print("Current server has " .. playerCount .. " players")
	
	if shouldLeaveCurrentServer() then
		print("Server has more than 5 players, attempting to teleport immediately...")
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
				local rf = game:GetService("ReplicatedStorage"):FindFirstChild("__ServerBrowser")
				if rf and rf:IsA("RemoteFunction") then
					pcall(function()
						rf:InvokeServer("teleport", targetId)
					end)
					return true -- Successfully teleported
				else
					warn("__ServerBrowser RemoteFunction not found; skipping TeleportService per request")
				end
			end
		end
		return false -- Failed to teleport
	else
		print("Server has 5 or fewer players, staying and waiting 30 minutes...")
		return false -- Stay in current server
	end
end

-- First check: try to teleport if current server has too many players
local teleported = checkAndTeleportIfNeeded()

-- If we didn't teleport (either because server is fine or teleport failed), wait 30 minutes
if not teleported then
	print("Waiting 30 minutes before starting the normal teleport loop...")
	safeWait(INITIAL_DELAY_SECONDS)
end

-- Check server player count every 10 seconds
task.spawn(function()
	while true do
		safeWait(10) -- Wait 10 seconds
		checkAndTeleportIfNeeded()
	end
end)

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
