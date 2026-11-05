--[[
    VENOM FARM v6  -  "[🎃] +1 Évolution du venin"
    - Auto farm : TP devant chaque ennemi (4.5 studs) + attaque par la remote du jeu (aucun clic écran)
    - Progression automatique étape par étape depuis l'étape 1 (1 win gratuite par étape)
    - "Max time per stage" : si l'étape est trop longue -> entraînement, puis étape -1
    - Auto claim : uniquement les wins GRATUITES = pad JAUNE (jamais le pad payant R$)
    - Auto Evolve / Auto Claim Quests / Auto Claim Gifts (100% gratuits)
    - Évolution : objectifs wins + niveau ; si les wins sont atteints mais pas le
      niveau, le bot va s'entraîner dans la meilleure chambre puis évolue
    - Anti-AFK sans saut (aucune touche Espace)
    - UI : NextUI (https://diser.me/nextui/)
    - Touche pour ouvrir/fermer le menu + bouton flottant mobile
    - Optimisé mobile / petit écran / tous executors
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local VIM = game:GetService("VirtualInputManager")
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")

local LP = Players.LocalPlayer
local Remotes = RS:WaitForChild("Remotes")
local GetData = Remotes:WaitForChild("GetData")
local EvolveRemote = Remotes:WaitForChild("Evolve")
local QuestClaim = Remotes:WaitForChild("QuestClaim")

local QuestsCfg
pcall(function() QuestsCfg = require(RS.Shared.Config.Quests) end)

local ProgressCfg
pcall(function() ProgressCfg = require(RS.Shared.Config.Progress) end)

-- ============================================================ génération (anti-conflit d'instances)
-- Chaque exécution incrémente la génération : seule la plus récente tourne.
-- IMPORTANT : on ne touche JAMAIS aux tables trouvées par getgc (ce sont des
-- templates Luau partagés, les modifier corrompt les futurs littéraux de table).
_G.__MadiumGen = (_G.__MadiumGen or 0) + 1
local GEN = _G.__MadiumGen

do
	local prev = _G.MadiumFarm and _G.MadiumFarm.State
	if type(prev) == "table" and prev.Gen ~= GEN then
		prev.Farm, prev.Train, prev.WinPad, prev.NextStage = false, false, false, false
		prev.Godmode, prev.AntiAfk = false, false
	end
end

-- ============================================================ state
local RAW = {
	Gen = GEN,
	StartStage = 1,
	TargetStage = nil,
	MaxStageTime = 120,
	TrainTime = 45,
	Farm = true,
	NextStage = true,
	WinPad = true,
	AutoClaim = true,
	AutoEvolve = true,
	TrainEvolve = true,
	AutoQuests = true,
	AutoGifts = true,
	Recover = true,
	Train = false,
	Godmode = true,
	AntiAfk = true,
	AttackRate = 0.15,
	MenuKey = "RightShift",
	LowEnd = false,
	StageWins = 0,
	StageFails = 0,
	RobuxBlocked = 0,
	Evolutions = 0,
	QuestClaims = 0,
	GiftClaims = 0,
	Status = "Ready",
	Wins = 0,
	Venom = 0,
	BestStage = 0,
}

local function alive()
	return _G.__MadiumGen == GEN
end

-- tue immédiatement une instance dépassée, même suspendue dans un appel serveur
local function guard()
	if _G.__MadiumGen ~= GEN then
		error("venomfarm: instance superseded", 0)
	end
end

_G.__MadiumLog = {}
local function jlog(ev, detail)
	if not alive() then return end
	local L = _G.__MadiumLog
	L[#L + 1] = string.format("%.1f %s %s", os.clock(), tostring(ev), tostring(detail or ""))
	while #L > 200 do table.remove(L, 1) end
end

local S = setmetatable({}, {
	__index = RAW,
	__newindex = function(_, k, v)
		if RAW[k] ~= v then
			RAW[k] = v
		end
	end,
})

local function setStatus(txt)
	if not alive() then return end
	S.Status = tostring(txt)
end

-- ============================================================ helpers
local function getRoot()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
	local c = LP.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function teleport(pos, lookAt)
	local r = getRoot()
	if not r or typeof(pos) ~= "Vector3" then return end
	r.CFrame = lookAt and CFrame.new(pos, lookAt) or CFrame.new(pos)
	r.AssemblyLinearVelocity = Vector3.zero
end

local deaths = 0

local dataCache, dataAt = nil, 0
local function getData(force)
	if dataCache and not force and (os.clock() - dataAt) < 5 then return dataCache end
	local ok, res = pcall(function() return GetData:InvokeServer() end)
	guard()
	if ok and type(res) == "table" then
		dataCache = res
		dataAt = os.clock()
		if res.Wins then S.Wins = tonumber(res.Wins) or S.Wins end
		if res.Venom then S.Venom = tonumber(res.Venom) or S.Venom end
		if res.BestStage then S.BestStage = tonumber(res.BestStage) or S.BestStage end
		if res.Evolutions then S.Evolutions = tonumber(res.Evolutions) or S.Evolutions end
	end
	return dataCache or {}
end

local function currentStage()
	return tonumber(getData().BestStage) or 1
end

-- ============================================================ ennemis
local function getEnemies()
	local out = {}
	for _, m in ipairs(CS:GetTagged("VenomEnemy")) do
		local h = m:FindFirstChildOfClass("Humanoid")
		local root = m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("UpperTorso")
		if h and h.Health > 0 and root and not m:GetAttribute("Dead") and m:GetAttribute("NPCCharacterId") then
			out[#out + 1] = {
				model = m, hum = h, root = root,
				boss = (m:GetAttribute("IsBoss") == true) or (m:GetAttribute("EnemyKind") == "boss"),
			}
		end
	end
	return out
end

-- zone de l'étape en cours : on n'attaque QUE les ennemis de cette zone,
-- sinon le farm retéléporte le joueur à l'étape voisine et l'étape cible ne se charge jamais.
local activeZone = nil
local ZONE_RADIUS = 200

local function nearestEnemy()
	local r = getRoot()
	if not r then return nil end
	local best, bestD
	for _, e in ipairs(getEnemies()) do
		if not activeZone or (e.root.Position - activeZone).Magnitude < ZONE_RADIUS then
			local d = (e.root.Position - r.Position).Magnitude
			if not bestD or d < bestD then best, bestD = e, d end
		end
	end
	return best, bestD
end

-- ============================================================ attaque via la remote du jeu
-- Aucun clic d'attaque n'est envoyé à l'écran : on appelle directement
-- CombatController:Attack(), qui utilise Remotes.Attack (comme un vrai clic).
-- -> impossible de cliquer sur un gamepass ou sur l'interface par erreur.
local VIEWPORT = Vector2.new(1280, 720)

local attackRemote = Remotes:FindFirstChild("Attack")

local CombatCtrl
local function getCombat()
	if CombatCtrl then return CombatCtrl end
	local ps = LP:FindFirstChild("PlayerScripts")
	local client = ps and ps:FindFirstChild("Client")
	local ctrls = client and client:FindFirstChild("Controllers")
	local mod = ctrls and ctrls:FindFirstChild("CombatController")
	if mod then
		local ok, m = pcall(require, mod)
		if ok and type(m) == "table" then CombatCtrl = m end
	end
	return CombatCtrl
end

local function aimAt(pos)
	local cam = workspace.CurrentCamera
	local r = getRoot()
	if not cam or not r then return end
	pcall(function()
		cam.CFrame = CFrame.lookAt(r.Position + Vector3.new(0, 2, 0), pos)
	end)
	if cam.ViewportSize.X > 0 then VIEWPORT = cam.ViewportSize end
end

local lastAimAt = 0
local attackLogAt = 0

-- Niveau à partir duquel on utilise les griffes (Claw) au lieu de Bite.
local clawLevel = 4
pcall(function()
	local cfg = require(RS.Shared.Config.Combat)
	if cfg and cfg.Moves and cfg.Moves.ClawR and tonumber(cfg.Moves.ClawR.level) then
		clawLevel = tonumber(cfg.Moves.ClawR.level)
	end
end)

-- Attaque 100 % par la remote du jeu (CombatController:Attack() -> Remotes.Attack).
-- Aucun clic souris : rien ne peut toucher un gamepass ou l'interface.
local function attackAt(pos)
	local r = getRoot()
	if not r then return false end
	if not S.LowEnd or (os.clock() - lastAimAt) > 0.6 then
		aimAt(pos)
		lastAimAt = os.clock()
	end

	local cc = getCombat()
	if cc then
		local ok, res = pcall(cc.Attack, cc)
		if ok then
			if res and (os.clock() - attackLogAt) > 8 then
				attackLogAt = os.clock()
				jlog("ATTACK", "remote ok")
			end
			return res and true or false
		end
		jlog("ERR", "attack " .. tostring(res))
	end

	-- secours : envoi direct de la remote (le serveur vise l'ennemi le plus proche)
	if attackRemote then
		local lvl = 1
		pcall(function()
			local goo = require(LP.PlayerScripts.Client.Controllers.GooController)
			lvl = goo:Level()
		end)
		local move = (lvl >= clawLevel) and "ClawR" or "Bite"
		local ok = pcall(function() attackRemote:FireServer(move, nil, pos) end)
		if ok and (os.clock() - attackLogAt) > 8 then
			attackLogAt = os.clock()
			jlog("ATTACK", "remote " .. move)
		end
		return ok
	end
	return false
end

-- ============================================================ étapes
local function findStage(n)
	local prefix = string.format("Stage%02d_", n)
	for _, map in ipairs(workspace:GetChildren()) do
		if map:IsA("Folder") or map:IsA("Model") then
			for _, st in ipairs(map:GetChildren()) do
				if st.Name:sub(1, #prefix) == prefix then return st end
			end
		end
	end
end

local function cfFromString(s)
	if typeof(s) == "CFrame" then return s end
	if type(s) ~= "string" then return nil end
	local t = {}
	for v in s:gmatch("-?[%d%.]+") do t[#t + 1] = tonumber(v) end
	if #t < 3 then return nil end
	if #t >= 12 then
		return CFrame.new(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11], t[12])
	end
	return CFrame.new(t[1], t[2], t[3])
end

-- Position RÉELLE de l'arène de l'étape : l'EnemyZone n'existe pas tant que la
-- zone n'est pas chargée, donc on lit d'abord l'attribut ZoneCFrame (fourni par le jeu).
local function stageZonePos(st)
	if not st then return nil end
	local ez = st:FindFirstChild("EnemyZone", true)
	if ez and ez:IsA("BasePart") then return ez.Position end
	local zc = cfFromString(st:GetAttribute("ZoneCFrame"))
	if zc then return zc.Position end
	return nil
end

-- On se téléporte au MILIEU de l'arène (ZoneCFrame), pas au StageStart qui est
-- le point d'entrée du couloir : sinon on reste bloqué hors de la zone de combat.
local function ensureStageLoaded(n)
	local st = findStage(n)
	if not st then return nil end
	if st:FindFirstChild("EnemyZone", true) then return st end
	local zone = stageZonePos(st)
	local start = cfFromString(st:GetAttribute("StageStart"))
	local target = zone or (start and start.Position)
	if target then
		teleport(target + Vector3.new(0, 8, 0))
		for _ = 1, 24 do
			task.wait(0.25)
			guard()
			if st:FindFirstChild("EnemyZone", true) then return st end
		end
	end
	return st
end

-- Il y a DEUX pads par étape : un GRATUIT (texte jaune "N Wins") et un PAYANT
-- (affiche "R$ 80" + le nombre de wins en bleu). On ne prend QUE le pad gratuit.
local function padFreeScore(p)
	local hasPaid, yellow, wins = false, false, false
	for _, c in ipairs(p:GetDescendants()) do
		if c:IsA("TextLabel") then
			local t = tostring(c.Text)
			if t:find("R%$") or t:lower():find("robux") then hasPaid = true end
			if t:match("^%s*%d+%s*Wins?%s*$") then
				wins = true
				local col = c.TextColor3
				if col.R > 0.75 and col.G > 0.55 and col.B < 0.45 then yellow = true end
			end
		end
	end
	if hasPaid then return -1 end
	if wins and yellow then return 2 end
	if wins then return 1 end
	return 0
end

local function findPad(n)
	local best, bestScore
	for _, p in ipairs(CS:GetTagged("VenomWinPad")) do
		if p:IsA("BasePart") and tonumber(p:GetAttribute("Stage")) == n then
			local sc = padFreeScore(p)
			if not bestScore or sc > bestScore then best, bestScore = p, sc end
		end
	end
	if bestScore and bestScore > 0 then return best end
	return nil
end

-- clique UNIQUEMENT un bouton gratuit d'un écran de victoire.
-- Allowlist stricte : si le texte ne contient pas un mot "gratuit", on ne clique pas.
-- Aucun appel à PromptGamePassPurchase / PromptProductPurchase n'existe dans ce script.
local FREE_WORDS = { "claim", "free", "gratuit", "continue", "collect", "recuperer", "récupérer" }
local PAID_WORDS = {
	"robux", "r$", "x2", "2x", "double", "purchase", "buy", "pass", "product",
	"premium", "vip", "membership", "subscribe", "abonnement", "gamepass", "offre",
	"deal", "shop", "store", "pay", "price", "currency",
}

local function pressButton(b)
	-- 1) firesignal (executors modernes)
	if typeof(firesignal) == "function" then
		if pcall(firesignal, b.MouseButton1Click) then return true end
	end
	-- 2) connections du signal (executors sans firesignal)
	if typeof(getconnections) == "function" then
		local ok, conns = pcall(getconnections, b.MouseButton1Click)
		if ok and type(conns) == "table" then
			local fired = false
			for _, c in ipairs(conns) do
				if typeof(c) == "table" and c.Fire then
					pcall(c.Fire, c)
					fired = true
				end
			end
			if fired then return true end
		end
	end
	-- 3) dernier recours : vrai clic souris sur le bouton
	local p = b.AbsolutePosition + b.AbsoluteSize * Vector2.new(0.5, 0.5)
	pcall(function()
		VIM:SendMouseButtonEvent(math.floor(p.X), math.floor(p.Y), 0, true, game, 0)
		VIM:SendMouseButtonEvent(math.floor(p.X), math.floor(p.Y), 0, false, game, 0)
	end)
	return true
end

local function isYellow(col)
	return col ~= nil and col.R > 0.6 and col.G > 0.45 and col.B < 0.45 and (col.R - col.B) > 0.2
end

local function chainVisible(o, root)
	local p = o
	while p and p ~= root and p.Parent do
		if p:IsA("GuiObject") and not p.Visible then return false end
		p = p.Parent
	end
	if root and root:IsA("ScreenGui") and not root.Enabled then return false end
	return true
end

-- UNIQUEMENT le bouton GRATUIT JAUNE situé à DROITE de l'écran de victoire.
-- Aucun appel à PromptGamePassPurchase / PromptProductPurchase dans ce script.
local function clickFreeWinButton()
	local pg = LP:FindFirstChild("PlayerGui")
	if not pg then return false end
	local rightMin = VIEWPORT.X * 0.45
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") and g.Enabled then
			for _, b in ipairs(g:GetDescendants()) do
				if b:IsA("GuiButton") and b.Visible and b.AbsoluteSize.X > 4 then
					local inWin = false
					local p = b
					while p and p ~= g do
						local pn = p.Name:lower()
						if pn:find("win") or pn:find("victory") or pn:find("clear")
							or pn:find("celebrate") or pn:find("stage") then
							inWin = true
							break
						end
						p = p.Parent
					end
					if inWin and chainVisible(b, g) then
						local txt = ((b.Name or "") .. " " .. (b:IsA("TextButton") and b.Text or "")):lower()
						local paid = false
						for _, w in ipairs(PAID_WORDS) do if txt:find(w, 1, true) then paid = true break end end
						if paid then
							S.RobuxBlocked = (S.RobuxBlocked or 0) + 1
							jlog("BLOCK", "paid button ignored: " .. txt:sub(1, 40))
						else
							local yellow = isYellow(b.BackgroundColor3)
							if b:IsA("TextButton") then yellow = yellow or isYellow(b.TextColor3) end
							local center = b.AbsolutePosition + b.AbsoluteSize * 0.5
							if yellow and center.X >= rightMin then
								jlog("FREE", "yellow right click " .. txt:sub(1, 40))
								return pressButton(b)
							end
						end
					end
				end
			end
		end
	end
	return false
end

local pauseUntil = 0
-- true pendant qu'on s'entraîne pour atteindre le niveau requis par l'évolution
local evolveTraining = false
local function isPaused() return os.clock() < pauseUntil end

-- claim gratuit : TP sur le pad JAUNE gratuit + clic du bouton jaune de droite.
-- On vérifie que la win est bien consommée, sinon on retente (sans jamais toucher au pad payant).
local function claimStageFree(n)
	if not n then return false end
	local pad = findPad(n)
	if not pad then
		jlog("CLAIM", "no free pad for stage " .. tostring(n))
		return false
	end
	local function stillReady()
		return (LP:GetAttribute("WinReady") or ""):find("," .. n .. ",", 1, true) ~= nil
	end
	pauseUntil = os.clock() + 2.6
	local onPad = pad.Position + Vector3.new(0, 2.5, 0)
	teleport(onPad)
	task.wait(0.7)
	guard()
	for attempt = 1, 3 do
		if not stillReady() then break end
		clickFreeWinButton()
		task.wait(0.5)
		guard()
		if stillReady() and attempt < 3 then
			-- on remonte puis on retombe sur le pad pour refaire un vrai "touch"
			teleport(onPad + Vector3.new(0, 7, 0))
			task.wait(0.35)
			teleport(onPad)
			task.wait(0.45)
			guard()
		end
	end
	local ok = not stillReady()
	local gained = 0
	if ok then
		dataCache = nil
		local g = getData(true)
		if type(g) == "table" then S.Wins = tonumber(g.Wins) or S.Wins end
	end
	jlog("CLAIM", ("stage %s free=%s wins=%s target=%s"):format(
		tostring(n), tostring(ok), tostring(S.Wins), tostring(S.TargetStage)))
	return ok
end

local function nextReadyStage()
	local ready = LP:GetAttribute("WinReady") or ""
	for n in ready:gmatch(",(%d+),") do return tonumber(n) end
	return nil
end

-- ============================================================ entraînement
local TrainingCfg
pcall(function() TrainingCfg = require(RS.Shared.Config.Training) end)

local function ownedChambers()
	local owned = {}
	local s = LP:GetAttribute("Chambers")
	if type(s) == "string" then
		for n in s:gmatch("%d+") do owned[tonumber(n)] = true end
	elseif type(s) == "number" then
		owned[s] = true
	end
	if TrainingCfg and TrainingCfg.Chambers then
		for i, c in pairs(TrainingCfg.Chambers) do
			if c.unlock and c.unlock.kind == "free" then owned[i] = true end
		end
	end
	return owned
end

local function bestChamberModel()
	local owned = ownedChambers()
	local best, bestGain
	for i in pairs(owned) do
		local g = 1
		if TrainingCfg and TrainingCfg.Gain then
			local ok, r = pcall(TrainingCfg.Gain, i)
			if ok and type(r) == "number" then g = r end
		end
		if not bestGain or g > bestGain then best, bestGain = i, g end
	end
	if not best then return nil end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Name == "SoundChambers" then
			for _, c in ipairs(d:GetChildren()) do
				if c:GetAttribute("Chamber") == best then return c, best end
			end
		end
	end
end

local function trainingBreak(seconds)
	seconds = tonumber(seconds) or S.TrainTime or 45
	local chamber, idx = bestChamberModel()
	local pad = chamber and chamber:FindFirstChild("Pad", true)
	if not pad then return false end
	setStatus("Recovery: training " .. tostring(idx))
	pauseUntil = os.clock() + seconds + 2
	local p = pad.Position + Vector3.new(0, pad.Size.Y * 0.5 + 3, 0)
	teleport(p, pad.Position)
	local t0 = os.clock()
	while alive() and S.Farm and (os.clock() - t0) < seconds do
		teleport(p, pad.Position)
		task.wait(0.5)
	end
	pauseUntil = os.clock() + 0.4
	return true
end

-- ============================================================ boucles
local running = { farm = false, train = false, win = false, stage = false }

local function startAt(stage)
	stage = math.max(1, math.floor(tonumber(stage) or 1))
	S.TargetStage = stage
	S.StageWins = 0
	S.StageFails = 0
	deaths = 0
	pauseUntil = 0
end

local function farmLoop()
	if running.farm then return end
	running.farm = true
	task.spawn(function()
		local deadHandled = false
		while alive() and S.Farm do
			local ok, err = pcall(function()
				if evolveTraining then
					task.wait(0.3)
					return
				end
				if isPaused() then
					task.wait(0.2)
					return
				end
				local h = getHum()
				local r = getRoot()
				if not h or not r or h.Health <= 0 then
					if not deadHandled then
						deadHandled = true
						deaths += 1
						setStatus("Dead — recovering…")
						local t0 = os.clock()
						while alive() and S.Farm and (os.clock() - t0) < 15 and (not getHum() or getHum().Health <= 0) do
							task.wait(0.4)
						end
						if S.Farm and S.Recover then
							local target = tonumber(S.TargetStage) or 1
							if deaths >= 2 and target > 1 then
								S.TargetStage = target - 1
								deaths = 0
								S.StageWins = 0
								setStatus("Too many deaths — stage " .. tostring(S.TargetStage))
								pauseUntil = 0
								local st = ensureStageLoaded(S.TargetStage)
								local zone = stageZonePos(st)
								if zone then activeZone = zone; teleport(zone + Vector3.new(0, 8, 0)) end
							else
								if not trainingBreak(S.TrainTime) then
									-- pas de chambre : on descend d'une étape si possible
									if target > 1 then
										S.TargetStage = target - 1
										S.StageWins = 0
									end
								end
								deaths = 0
								if S.Farm and S.TargetStage then
									pauseUntil = 0
									local st2 = ensureStageLoaded(S.TargetStage)
									local zone2 = stageZonePos(st2)
									if zone2 then activeZone = zone2; teleport(zone2 + Vector3.new(0, 8, 0)) end
									task.wait(0.8)
								end
							end
						end
					else
						task.wait(0.6)
					end
				else
					deadHandled = false
					local e, dist = nearestEnemy()
					if e and dist then
						if dist > 5.5 then
							local away = r.Position - e.root.Position
							away = Vector3.new(away.X, 0, away.Z)
							if away.Magnitude < 0.5 then away = Vector3.new(0, 0, 1) end
							teleport(e.root.Position + away.Unit * 4.5 + Vector3.new(0, 2, 0), e.root.Position)
						end
						setStatus(("%s  [%d studs]%s"):format(e.model.Name, math.floor(dist), e.boss and "  BOSS" or ""))
						attackAt(e.root.Position)
						task.wait(S.AttackRate)
					else
						-- aucun ennemi : on revient au MILIEU de l'arène pour déclencher les spawns
						local rr = getRoot()
						if activeZone and rr and (rr.Position - activeZone).Magnitude > 140 then
							teleport(activeZone + Vector3.new(0, 8, 0))
							task.wait(0.5)
						else
							task.wait(0.3)
						end
					end
				end
			end)
			if not ok then
				jlog("ERR", "farm " .. tostring(err))
				task.wait(1)
			end
		end
		running.farm = false
	end)
end

local function trainLoop()
	if running.train then return end
	running.train = true
	task.spawn(function()
		while alive() and S.Train do
			local ok, err = pcall(function()
				local chamber, idx = bestChamberModel()
				if chamber then
					local pad = chamber:FindFirstChild("Pad", true)
					if pad then
						setStatus("Training chamber " .. tostring(idx))
						teleport(pad.Position + Vector3.new(0, pad.Size.Y * 0.5 + 3, 0), pad.Position)
					end
				else
					setStatus("No chamber unlocked")
				end
				task.wait(1.6)
			end)
			if not ok then jlog("ERR", "train " .. tostring(err)); task.wait(1) end
		end
		running.train = false
	end)
end

local function winLoop()
	if running.win then return end
	running.win = true
	task.spawn(function()
		while alive() and S.WinPad do
			local ok, err = pcall(function()
				if S.AutoClaim and not S.NextStage and not isPaused() and not evolveTraining then
					local n = nextReadyStage()
					if n then claimStageFree(n) else task.wait(1.5) end
				else
					task.wait(0.4)
				end
			end)
			if not ok then jlog("ERR", "win " .. tostring(err)); task.wait(1) end
		end
		running.win = false
	end)
end

-- ============================================================ auto evolve
local evolveFails = 0
local function tryEvolve()
	if not S.AutoEvolve or isPaused() then return false end
	local ok, res = pcall(function() return EvolveRemote:InvokeServer() end)
	guard()
	if ok and res then
		evolveFails = 0
		jlog("EVOLVE", "success")
		setStatus("Evolved!")
		dataCache = nil
		pcall(function() getData(true) end)
		return true
	end
	evolveFails += 1
	return false
end

-- Objectifs d'évolution : nombre de wins ET niveau (calculé depuis le Venom).
local function evolveStats()
	local g = getData(true)
	local evo = tonumber(g.Evolutions) or 0
	local wins = tonumber(g.Wins) or 0
	local venom = tonumber(g.Venom) or 0
	local lvl, needLvl, needWins = 0, 0, 0
	if ProgressCfg then
		lvl = ProgressCfg.LevelFor(venom, evo)
		needLvl = ProgressCfg.LevelToEvolve(evo)
		needWins = ProgressCfg.WinsToEvolve(evo)
	end
	S.EvolveLevel, S.EvolveNeedLevel, S.EvolveNeedWins = lvl, needLvl, needWins
	return evo, wins, venom, lvl, needLvl, needWins
end

-- Tant que les wins sont atteints mais pas le niveau : on va s'entraîner dans
-- la meilleure chambre jusqu'au niveau requis, puis on évolue.
local function trainForEvolve(evo, needLvl)
	local chamber, idx = bestChamberModel()
	local pad = chamber and chamber:FindFirstChild("Pad", true)
	if not pad then
		setStatus("Evolve: no training chamber")
		jlog("EVOLVE", "no chamber for level " .. tostring(needLvl))
		task.wait(15)
		return false
	end
	local target = pad.Position + Vector3.new(0, pad.Size.Y * 0.5 + 3, 0)
	setStatus(("Evolve: training level/%d"):format(needLvl))
	jlog("EVOLVE", "wins ok -> training to level " .. tostring(needLvl))
	local t0 = os.clock()
	while alive() and S.AutoEvolve and (os.clock() - t0) < 1800 do
		teleport(target, pad.Position)
		task.wait(1.0)
		local g = getData(true)
		local lvl = ProgressCfg and ProgressCfg.LevelFor(tonumber(g.Venom) or 0, tonumber(g.Evolutions) or evo) or 0
		S.EvolveLevel = lvl
		setStatus(("Evolve: training level %d/%d"):format(lvl, needLvl))
		if lvl >= needLvl then
			jlog("EVOLVE", "level reached " .. tostring(lvl))
			return true
		end
	end
	return false
end

task.spawn(function()
	task.wait(6)
	while alive() do
		if S.AutoEvolve and not isPaused() and not evolveTraining then
			local ok, err = pcall(function()
				local evo, wins, _, lvl, needLvl, needWins = evolveStats()
				if needWins > 0 and wins >= needWins and lvl >= needLvl then
					tryEvolve()
				elseif needWins > 0 and wins >= needWins and lvl < needLvl and S.TrainEvolve then
					evolveTraining = true
					local done = false
					local ok2, err2 = pcall(function() done = trainForEvolve(evo, needLvl) end)
					evolveTraining = false
					if not ok2 then jlog("ERR", "evolve train " .. tostring(err2)) end
					if done then tryEvolve() end
				end
			end)
			if not ok then jlog("ERR", "evolve " .. tostring(err)) end
		end
		task.wait(10)
	end
end)

-- ============================================================ auto quests
local function claimedSet(str)
	local t = {}
	if type(str) == "string" then
		for v in str:gmatch("[^,]+") do
			v = v:gsub("^%s+", ""):gsub("%s+$", "")
			if v ~= "" then t[v] = true end
		end
	end
	return t
end

local function tryQuests()
	if not S.AutoQuests or isPaused() or not QuestsCfg then return false end
	local g = getData(true)
	if type(g) ~= "table" then return false end
	local did = false
	for _, period in ipairs(QuestsCfg.Periods or { "Daily", "Weekly" }) do
		local key = (period == "Daily") and "QuestDay" or "QuestWeek"
		local d = g[key]
		if type(d) == "table" then
			local claimed = claimedSet(d.Claimed)
			local slots = QuestsCfg.Slots[period] or {}
			local prefix = (period == "Daily") and "daily" or "weekly"
			-- On ne réclame QUE les quêtes terminées (sinon le serveur refuse).
			local counts = g[key .. "Count"] or {}
			local ready = {}
			for _, row in ipairs(QuestsCfg.Rows(period, d.Set) or {}) do
				local have = tonumber(counts[row.kind]) or 0
				if have >= (tonumber(row.target) or 1) then ready[row.slot] = true end
			end
			for _, cat in ipairs(slots) do
				if not claimed[cat] and ready[cat] then
					-- Le jeu attend l'identifiant du slot : "daily_stages", "weekly_evolves", ...
					local id = prefix .. "_" .. tostring(cat)
					pcall(function() QuestClaim:InvokeServer("Claim", id) end)
					guard()
					did = true
					claimed[cat] = true
					jlog("QUEST", "claim " .. id)
					task.wait(0.3)
				end
			end
			local all = #slots > 0
			for _, cat in ipairs(slots) do
				if not claimed[cat] then all = false break end
			end
			if all and not d.Bonus then
				-- Le bonus s'appelle avec la période : "Daily" ou "Weekly".
				local ok = pcall(function() QuestClaim:InvokeServer("Bonus", period) end)
				guard()
				if ok then
					did = true
					jlog("QUEST", "bonus " .. period)
				end
				task.wait(0.3)
			end
		end
	end
	if did then
		dataCache = nil
		local g2 = getData(true)
		local nDay, nWeek = 0, 0
		if type(g2) == "table" then
			local cd = claimedSet(type(g2.QuestDay) == "table" and g2.QuestDay.Claimed or "")
			local cw = claimedSet(type(g2.QuestWeek) == "table" and g2.QuestWeek.Claimed or "")
			for _, cat in ipairs(QuestsCfg.Slots.Daily or {}) do if cd[cat] then nDay += 1 end end
			for _, cat in ipairs(QuestsCfg.Slots.Weekly or {}) do if cw[cat] then nWeek += 1 end end
		end
		S.QuestClaims = (S.QuestClaims or 0) + 1
		jlog("QUEST", ("claimed now daily=%d/4 weekly=%d/4"):format(nDay, nWeek))
	end
	return did
end

task.spawn(function()
	task.wait(10)
	while alive() do
		if S.AutoQuests and not isPaused() then
			local ok, err = pcall(tryQuests)
			if not ok then jlog("ERR", "quests " .. tostring(err)) end
		end
		task.wait(25)
	end
end)

-- ============================================================ auto gifts (100% gratuits)
-- On déclenche les vrais boutons du jeu (FreeReward / DailyRewards / TimeRewards).
-- JAMAIS : le cadre "Gift" (cadeau payant), ni le bouton "Claim All" Robux.
local function fireClaimButtons()
	local pg = LP:FindFirstChild("PlayerGui")
	local gui = pg and pg:FindFirstChild("GUI")
	local frames = gui and gui:FindFirstChild("Frames")
	if not frames then return 0 end
	local fired = 0
	local function fire(b, needActive)
		if not (b and b:IsA("GuiButton")) then return end
		if needActive and (b.Active == false or b.Selectable == false) then return end
		pcall(pressButton, b)
		fired += 1
	end
	local free = frames:FindFirstChild("FreeReward")
	if free then fire(free:FindFirstChild("ClaimButton", true), false) end
	local daily = frames:FindFirstChild("DailyRewards")
	if daily then
		-- IMPORTANT : le "Claim All" du header est un PRODUIT ROBUX -> jamais cliqué.
		for _, day in ipairs(daily:GetDescendants()) do
			if day.Name == "ClaimButton" then fire(day, true) end
		end
	end
	local tr = frames:FindFirstChild("TimeRewards")
	if tr then
		for _, b in ipairs(tr:GetDescendants()) do
			if b:IsA("GuiButton") and tonumber(b.Name) then fire(b, true) end
		end
	end
	return fired
end

local function tryGifts()
	if not S.AutoGifts or isPaused() then return false end
	local n = fireClaimButtons()
	if n > 0 then
		S.GiftClaims = (S.GiftClaims or 0) + 1
		jlog("GIFT", "free claim buttons fired: " .. tostring(n))
		return true
	end
	return false
end

task.spawn(function()
	task.wait(14)
	while alive() do
		if S.AutoGifts and not isPaused() then
			local ok, err = pcall(tryGifts)
			if not ok then jlog("ERR", "gifts " .. tostring(err)) end
		end
		task.wait(30)
	end
end)

local function stageLoop()
	if running.stage then return end
	running.stage = true
	S.Farm = true
	farmLoop()
	task.spawn(function()
		while alive() and S.NextStage and not evolveTraining do
			local ok, err = pcall(function()
				local n = math.max(1, math.floor(tonumber(S.TargetStage) or tonumber(S.StartStage) or 1))
				if S.TargetStage ~= n then S.TargetStage = n end
				setStatus(("Stage %d — clearing"):format(n))

				local st = ensureStageLoaded(n)
				local zone = stageZonePos(st)
				if not zone then
					task.wait(1.5)
					return
				end

				pauseUntil = 0
				activeZone = zone
				teleport(zone + Vector3.new(0, 8, 0))
				local t0 = os.clock()
				local maxTime = math.max(20, tonumber(S.MaxStageTime) or 120)

				while alive() and S.NextStage and tonumber(S.TargetStage) == n and not evolveTraining do
					-- on garde le joueur dans la zone de l'étape (sinon le farm repart ailleurs)
					local rr = getRoot()
					if rr and (rr.Position - zone).Magnitude > 80 then
						teleport(zone + Vector3.new(0, 8, 0))
					end
					local ready = LP:GetAttribute("WinReady") or ""
					if ready:find("," .. n .. ",", 1, true) then
						if claimStageFree(n) then
							S.StageFails = 0
							S.StageWins = 0
							S.TargetStage = n + 1
							deaths = 0
							setStatus(("Stage %d done → stage %d"):format(n, n + 1))
							break
						end
					elseif (os.clock() - t0) > maxTime then
						S.StageFails = (S.StageFails or 0) + 1
						if S.StageFails >= 2 and n > 1 then
							S.TargetStage = n - 1
							S.StageWins = 0
							S.StageFails = 0
							setStatus(("Stage %d too slow → stage %d"):format(n, n - 1))
						else
							setStatus(("Stage %d too slow — training"):format(n))
							if not trainingBreak(S.TrainTime) then
								if n > 1 then
									S.TargetStage = n - 1
									S.StageWins = 0
								end
							end
						end
						break
					end
					task.wait(0.4)
				end
			end)
			if not ok then jlog("ERR", "stage " .. tostring(err)); task.wait(1.5) end
			task.wait(0.3)
		end
		running.stage = false
	end)
end

-- superviseur : relance toute boucle qui aurait planté
task.spawn(function()
	while alive() do
		task.wait(3)
		if S.Farm and not running.farm then farmLoop() end
		if S.Train and not running.train then trainLoop() end
		if S.WinPad and not running.win then winLoop() end
		if S.NextStage and S.Farm and not running.stage and not evolveTraining then stageLoop() end
	end
end)

-- ============================================================ passifs
task.spawn(function()
	while alive() do
		if S.Godmode then
			local h = getHum()
			if h then
				if h.MaxHealth < 1e6 then h.MaxHealth = 1e9 end
				if h.Health < h.MaxHealth then h.Health = h.MaxHealth end
			end
		end
		task.wait(0.15)
	end
end)

-- Anti-AFK SANS saut : on ne simule aucune touche
LP.Idled:Connect(function()
	if not alive() or not S.AntiAfk then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new(4, 4))
	end)
	jlog("AFK", "idle counter reset")
end)

-- stats serveur (wins / venom / best stage) rafraîchies doucement
task.spawn(function()
	while alive() do
		pcall(function() getData(true) end)
		task.wait(15)
	end
end)

-- ============================================================ UI (NextUI)
local ui = {
	window = nil,
	labels = {},
	notify = nil,
	watermark = nil,
	statusItem = nil,
}

local function notify(title, content, ok)
	if ui.notify then
		pcall(function()
			if ok == false then ui.notify:Error(title, content) else ui.notify:Success(title, content) end
		end)
	end
end

local NEXTUI_URL = "https://diser.me/nextui/source.lua"

local function httpGet(url)
	local attempts = {
		function() return game:HttpGet(url) end,
		function() return game:HttpGetAsync(url) end,
		function() return httpget(url) end,
		function() return request({ Url = url, Method = "GET" }).Body end,
		function() return syn.request({ Url = url, Method = "GET" }).Body end,
		function() return http_request({ Url = url, Method = "GET" }).Body end,
	}
	for _, fn in ipairs(attempts) do
		local ok, res = pcall(fn)
		if ok and type(res) == "string" and #res > 100 then return res end
	end
	return nil
end

local function loadNextUI()
	local src = httpGet(NEXTUI_URL)
	if not src then return nil end
	local loader = loadstring or load
	if typeof(loader) ~= "function" then return nil end
	local fn = loader(src)
	if not fn then return nil end
	local ok, res = pcall(fn)
	if ok and type(res) == "table" then return res end
	return nil
end

local function buildFallback()
	local parent = (gethui and gethui()) or game:GetService("CoreGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "VenomFarm"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9999
	gui.Parent = parent

	local cam = workspace.CurrentCamera
	local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
	local w = math.clamp(math.floor(vp.X * 0.30), 260, 340)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(w, 150)
	frame.Position = UDim2.new(0, 14, 0, 70)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -20, 0, 56)
	label.Position = UDim2.fromOffset(10, 8)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.TextWrapped = true
	label.TextColor3 = Color3.fromRGB(230, 230, 235)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = "Venom Farm — simple menu (NextUI failed to load)\nFree wins only. No Robux."
	label.Parent = frame

	local function mkButton(text, x, color, cb)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset((w - 30) / 2, 34)
		b.Position = UDim2.fromOffset(x, 96)
		b.BackgroundColor3 = color
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 12
		b.Text = text
		b.Parent = frame
		b.MouseButton1Click:Connect(cb)
		return b
	end

	mkButton("STOP", 10, Color3.fromRGB(190, 60, 60), function()
		S.Farm, S.NextStage, S.Train, S.WinPad = false, false, false, false
		S.AutoEvolve, S.AutoQuests, S.AutoGifts = false, false, false
		label.Text = "Stopped."
	end)
	mkButton("HIDE", 20 + (w - 30) / 2, Color3.fromRGB(60, 60, 70), function()
		gui.Enabled = false
		task.delay(1, function() gui.Enabled = true end)
	end)
	return gui
end

local function buildUI()
	local NextUI
	local ok, res = pcall(loadNextUI)
	if ok then NextUI = res end
	if not NextUI then
		jlog("UI", "NextUI unavailable — fallback")
		buildFallback()
		return
	end

	ui.notify = NextUI
	local cam = workspace.CurrentCamera
	local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
	local winW = math.clamp(math.floor(vp.X * 0.55), 420, 780)
	local winH = math.clamp(math.floor(vp.Y * 0.72), 320, 540)

	local Window = NextUI:CreateWindow({
		Title = "Venom Farm",
		SubTitle = "v5 · free wins only",
		Theme = "Amethyst",
		Size = Vector2.new(winW, winH),
		ToggleKey = Enum.KeyCode.RightShift,
		MobileButton = "Auto",
	})
	ui.window = Window

	-- place la fenêtre à gauche pour laisser la zone de clic libre à droite
	pcall(function()
		local main = NextUI.Windows and NextUI.Windows[1] and NextUI.Windows[1]._main
		if main then main.Position = UDim2.fromOffset(12, 56) end
	end)

	-- ================= Farm tab
	local FarmTab = Window:AddTab({ Title = "Farm", Icon = "crosshair" })

	local Auto = FarmTab:AddSection({ Title = "Automation", Icon = "bot" })

	local farmToggle
	farmToggle = Auto:AddToggle({
		Title = "Auto Farm",
		Description = "Teleport in front of enemies and attack",
		Style = "Switch",
		Default = true,
		Flag = "farm",
		Callback = function(on)
			S.Farm = on
			if on then
				startAt(S.StartStage)
				farmLoop()
				if S.NextStage then stageLoop() end
				notify("Auto Farm", "Started at stage " .. tostring(S.TargetStage))
			else
				S.NextStage = false
				if ui.opts and ui.opts.next then pcall(function() ui.opts.next:Set(false) end) end
			end
		end,
	})

	local nextToggle
	nextToggle = Auto:AddToggle({
		Title = "Auto Next Stage",
		Description = "Clear a stage, claim the free win, move on",
		Style = "Switch",
		Default = true,
		Flag = "nextstage",
		Callback = function(on)
			S.NextStage = on
			if on then
				if not S.Farm then S.Farm = true; if ui.opts and ui.opts.farm then pcall(function() ui.opts.farm:Set(true) end) end end
				if not tonumber(S.TargetStage) then startAt(S.StartStage) end
				stageLoop()
			end
		end,
	})
	ui.opts = ui.opts or {}
	ui.opts.farm = farmToggle
	ui.opts.next = nextToggle

	Auto:AddToggle({
		Title = "Auto Claim Wins",
		Description = "Free claim only — never Robux",
		Style = "Switch",
		Default = true,
		Flag = "autoclaim",
		Callback = function(on) S.AutoClaim = on end,
	})

	Auto:AddToggle({
		Title = "Win Pad Claim",
		Description = "Teleport on the yellow free pad only",
		Style = "Switch",
		Default = true,
		Flag = "winpad",
		Callback = function(on) S.WinPad = on; if on then winLoop() end end,
	})

	-- ================= Rewards (all free)
	local Rew = FarmTab:AddSection({ Title = "Rewards", Icon = "gift" })

	Rew:AddToggle({
		Title = "Auto Evolve",
		Description = "Evolves as soon as the requirements are met",
		Style = "Switch",
		Default = true,
		Flag = "auto_evolve",
		Callback = function(on) S.AutoEvolve = on end,
	})

	Rew:AddToggle({
		Title = "Train for Evolve",
		Description = "Wins reached → train until the required level",
		Style = "Switch",
		Default = true,
		Flag = "train_evolve",
		Callback = function(on) S.TrainEvolve = on end,
	})

	Rew:AddToggle({
		Title = "Auto Claim Quests",
		Description = "Daily + weekly quests and completion bonus",
		Style = "Switch",
		Default = true,
		Flag = "auto_quests",
		Callback = function(on) S.AutoQuests = on end,
	})

	Rew:AddToggle({
		Title = "Auto Claim Gifts",
		Description = "Free gift, daily rewards and playtime rewards",
		Style = "Switch",
		Default = true,
		Flag = "auto_gifts",
		Callback = function(on) S.AutoGifts = on end,
	})

	Rew:AddButton({
		Title = "Claim quests & gifts now",
		Description = "Free rewards only",
		Callback = function()
			task.spawn(function()
				pcall(tryQuests)
				pcall(tryGifts)
				notify("Rewards", "Free quests & gifts checked")
			end)
		end,
	})

	-- ================= Progression
	local Prog = FarmTab:AddSection({ Title = "Progression", Icon = "map" })

	Prog:AddNumberInput({
		Title = "Start stage",
		Description = "Auto Farm always begins here",
		Min = 1, Max = 60, Default = 1, Increment = 1,
		Flag = "start_stage",
		Callback = function(v) S.StartStage = v end,
	})

	Prog:AddNumberInput({
		Title = "Max time per stage",
		Description = "Slower than this = too hard → train / go down",
		Min = 20, Max = 600, Default = 120, Increment = 10, Suffix = " s",
		Flag = "max_stage_time",
		Callback = function(v) S.MaxStageTime = v end,
	})

	Prog:AddNumberInput({
		Title = "Train duration",
		Description = "Recovery training length",
		Min = 10, Max = 600, Default = 45, Increment = 5, Suffix = " s",
		Flag = "train_time",
		Callback = function(v) S.TrainTime = v end,
	})

	local tStage = Prog:AddNumberInput({
		Title = "Teleport stage",
		Min = 1, Max = 60, Default = 1, Increment = 1,
		Flag = "_tp_stage",
	})

	Prog:AddButton({
		Title = "Teleport",
		Description = "Go to the selected stage",
		Callback = function()
			local n = math.max(1, math.floor(tonumber(tStage:Get()) or 1))
			S.TargetStage = n
			S.StageWins = 0
			local st = ensureStageLoaded(n)
			local zone = stageZonePos(st)
			if zone then activeZone = zone; teleport(zone + Vector3.new(0, 8, 0)) end
			setStatus("Teleported to stage " .. tostring(n))
		end,
	})

	Prog:AddButton({
		Title = "Restart from start stage",
		Description = "Reset progress counters",
		Callback = function()
			startAt(S.StartStage)
			stageLoop()
			notify("Farm", "Restarted at stage " .. tostring(S.TargetStage))
		end,
	})

	-- ================= Recovery
	local Rec = FarmTab:AddSection({ Title = "Recovery", Icon = "heart" })

	Rec:AddToggle({
		Title = "Auto Recover",
		Description = "Death → train, 2nd death → stage below",
		Style = "Switch",
		Default = true,
		Flag = "recover",
		Callback = function(on) S.Recover = on end,
	})

	Rec:AddToggle({
		Title = "Godmode",
		Description = "Keeps your health topped up",
		Style = "Switch",
		Default = true,
		Flag = "godmode",
		Callback = function(on) S.Godmode = on end,
	})

	-- ================= Character tab
	local CharTab = Window:AddTab({ Title = "Character", Icon = "user" })
	local Char = CharTab:AddSection({ Title = "Player", Icon = "user" })

	Char:AddToggle({
		Title = "Anti-AFK (no jump)",
		Description = "Resets the idle timer without pressing Space",
		Style = "Switch",
		Default = true,
		Flag = "antiafk",
		Callback = function(on) S.AntiAfk = on end,
	})

	Char:AddToggle({
		Title = "Auto Train",
		Description = "Stays on the best unlocked chamber pad",
		Style = "Switch",
		Default = false,
		Flag = "train",
		Callback = function(on) S.Train = on; if on then trainLoop() end end,
	})

	Char:AddButton({
		Title = "Go to Lobby",
		Callback = function()
			local map = workspace:FindFirstChild("MapQuarantine")
			local lobby = map and map:FindFirstChild("Lobby")
			local sp = lobby and lobby:FindFirstChild("SpawnLocation", true)
			teleport(sp and (sp.Position + Vector3.new(0, 4, 0)) or Vector3.new(-2, 6, -190))
			setStatus("Lobby")
		end,
	})

	-- ================= Settings tab
	local SetTab = Window:AddTab({ Title = "Settings", Icon = "settings" })
	local Cfg = SetTab:AddSection({ Title = "Attack", Icon = "crosshair" })

	Cfg:AddSlider({
		Title = "Attack rate",
		Description = "Seconds between attacks (remote, no clicks)",
		Min = 0.05, Max = 0.4, Default = 0.15, Increment = 0.01, Suffix = " s",
		Flag = "attack_rate",
		Callback = function(v) S.AttackRate = v end,
	})

	Cfg:AddToggle({
		Title = "Low-end mode",
		Description = "Fewer camera updates — better FPS on phones",
		Style = "Switch",
		Default = false,
		Flag = "lowend",
		Callback = function(on) S.LowEnd = on end,
	})

	local MenuSec = SetTab:AddSection({ Title = "Menu", Icon = "layout" })

	MenuSec:AddKeybind({
		Title = "Menu key",
		Description = "Press it to open / close this window",
		Default = Enum.KeyCode.RightShift,
		MenuKey = true,
		Flag = "menu_key",
	})

	MenuSec:AddButton({
		Title = "Open / Hide menu",
		Description = "Same as the mobile button",
		Callback = function() pcall(function() ui.window:Toggle() end) end,
	})

	Cfg:AddButton({
		Title = "STOP EVERYTHING",
		Description = "Hold to confirm",
		Hold = 1.2,
		Callback = function()
			S.Farm, S.NextStage, S.Train, S.WinPad = false, false, false, false
			S.AutoEvolve, S.AutoQuests, S.AutoGifts = false, false, false
			if ui.opts then
				pcall(function() ui.opts.farm:Set(false) end)
				pcall(function() ui.opts.next:Set(false) end)
			end
			setStatus("Stopped")
			notify("Stopped", "All automation is off", false)
		end,
	})

	-- ================= Stats tab
	local StatsTab = Window:AddTab({ Title = "Stats", Icon = "activity" })
	local Stats = StatsTab:AddSection({ Title = "Live", Icon = "activity" })
	ui.labels.status = Stats:AddLabel("Status: ready")
	ui.labels.stage = Stats:AddLabel("Stage: 1")
	ui.labels.wins = Stats:AddLabel("Wins: 0 (best 0)")
	ui.labels.venom = Stats:AddLabel("Venom: 0")
	ui.labels.rate = Stats:AddLabel("Click: Auto")
	ui.labels.paid = Stats:AddLabel("Robux buttons blocked: 0")
	ui.labels.evolve = Stats:AddLabel("Evolutions: 0")
	ui.labels.evoNeed = Stats:AddLabel("Evolve: wins 0/0 · level 0/0")
	ui.labels.quests = Stats:AddLabel("Quest claims: 0")
	ui.labels.gifts = Stats:AddLabel("Gift claims: 0")

	Stats:AddButton({
		Title = "Refresh stats",
		Callback = function() pcall(function() getData(true) end) end,
	})

	-- ================= watermark
	pcall(function()
		local WM = NextUI:CreateWatermark({ Title = "Venom Farm", Position = "TopRight" })
		ui.watermark = WM
		ui.statusItem = WM:Add("Status", "ready")
		WM:Add("Stage", function() return tostring(S.TargetStage or S.StartStage or 1) end)
		WM:Add("Wins", function() return tostring(S.Wins) end)
	end)
end

-- rafraîchit les labels / watermark
task.spawn(function()
	while alive() do
		local st = S.TargetStage or S.StartStage or 1
		if ui.statusItem then pcall(function() ui.statusItem:Set(S.Status) end) end
		local L = ui.labels
		if L.status then
			pcall(function() L.status:Set("Status: " .. tostring(S.Status)) end)
			pcall(function() L.stage:Set(("Stage: %s"):format(tostring(st))) end)
			pcall(function() L.wins:Set(("Wins: %s  (best %s)"):format(tostring(S.Wins), tostring(S.BestStage))) end)
			pcall(function() L.venom:Set("Venom: " .. tostring(S.Venom)) end)
			pcall(function() L.rate:Set("Attack: remote  ·  " .. tostring(S.AttackRate) .. " s") end)
			if L.paid then pcall(function() L.paid:Set("Robux buttons blocked: " .. tostring(S.RobuxBlocked or 0)) end) end
			if L.evolve then pcall(function() L.evolve:Set("Evolutions: " .. tostring(S.Evolutions or 0)) end) end
			if L.evoNeed then
				pcall(function()
					L.evoNeed:Set(("Evolve: wins %s/%s · level %s/%s"):format(
						tostring(S.Wins or 0), tostring(S.EvolveNeedWins or 0),
						tostring(S.EvolveLevel or 0), tostring(S.EvolveNeedLevel or 0)))
				end)
			end
			if L.quests then pcall(function() L.quests:Set("Quest claims: " .. tostring(S.QuestClaims or 0)) end) end
			if L.gifts then pcall(function() L.gifts:Set("Gift claims: " .. tostring(S.GiftClaims or 0)) end) end
		end
		task.wait(0.5)
	end
end)

pcall(buildUI)

-- ============================================================ API
_G.MadiumFarm = {
	Gen = GEN,
	State = S,
	StartFarm = function()
		S.Farm = true
		startAt(S.StartStage)
		farmLoop()
		if S.NextStage then stageLoop() end
	end,
	StopAll = function() S.Farm, S.NextStage, S.Train, S.WinPad = false, false, false, false end,
	StopFarm = function() S.Farm = false end,
	StartTrain = function() S.Train = true; trainLoop() end,
	StopTrain = function() S.Train = false end,
	StartStage = function() S.NextStage = true; startAt(S.StartStage); stageLoop() end,
	StopStage = function() S.NextStage = false end,
	StartWin = function() S.WinPad = true; winLoop() end,
	StopWin = function() S.WinPad = false end,
	ClaimNow = function() local n = nextReadyStage(); return n and claimStageFree(n) or false end,
	ClearPause = function() pauseUntil = 0 end,
	ClickFreeButton = clickFreeWinButton,
	EvolveNow = tryEvolve,
	ClaimQuests = tryQuests,
	ClaimGifts = tryGifts,
	FindFreePad = findPad,
	TeleportStage = function(n)
		n = math.max(1, math.floor(tonumber(n) or 1))
		S.TargetStage = n
		S.StageWins = 0
		local st = ensureStageLoaded(n)
		local zone = stageZonePos(st)
		if zone then activeZone = zone; teleport(zone + Vector3.new(0, 8, 0)) end
	end,
	GetEnemies = getEnemies,
	Log = _G.__MadiumLog,
}

-- ============================================================ démarrage
jlog("START", "gen=" .. GEN .. " player=" .. LP.Name)
if S.Farm then
	startAt(S.StartStage)
	farmLoop()
	if S.NextStage then stageLoop() end
end
if S.WinPad then winLoop() end

print("[VenomFarm v4] loaded — stage " .. tostring(S.TargetStage))
