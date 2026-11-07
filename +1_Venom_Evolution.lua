--[[
    VENOM FARM v6  -  "+1 Venom Evolution"
    - Auto farm: TP in front of every enemy (4.5 studs) + attack through the game remote (no screen clicks)
    - Automatic stage-by-stage progression from stage 1 (1 free win per stage)
    - "Max time per stage": if a stage takes too long -> training, then stage -1
    - Auto claim: FREE wins only = YELLOW pad (never the paid R$ pad)
    - Auto Evolve / Auto Claim Quests / Auto Claim Gifts (100% free)
    - Evolution: win + level goals; if wins are reached but not the level,
      the bot trains in the best chamber then evolves
    - Anti-AFK without jumping (no Space key)
    - UI: NextUI (https://diser.me/nextui/)
    - Menu open/close key + floating mobile button
    - Optimized for mobile / small screens / all executors
    - Everything is OFF on launch; Crimson theme + Glass enabled by default
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")

-- ============================================================ compat (executors / appareils)
-- VirtualInputManager n'est pas accessible partout : on le charge sans jamais
-- faire planter le script (fallback = VirtualUser puis firesignal).
local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local function execName()
	local ok, n = pcall(function()
		if typeof(identifyexecutor) == "function" then return identifyexecutor() end
		return nil
	end)
	return (ok and type(n) == "string" and n ~= "") and n or "unknown"
end
local EXEC = execName()

-- Mobile = tactile SANS clavier. Une tablette avec clavier reste en mode "pc".
local IS_TOUCH = UIS.TouchEnabled == true
local IS_MOBILE = IS_TOUCH and UIS.KeyboardEnabled ~= true
local IS_PC = not IS_MOBILE

-- Parent d'interface compatible avec tous les executors connus.
local function getGuiParent()
	local tries = {
		function() return gethui and gethui() end,
		function() return get_hidden_gui and get_hidden_gui() end,
		function() return game:GetService("CoreGui") end,
		function() return Players.LocalPlayer:FindFirstChild("PlayerGui") end,
	}
	for _, f in ipairs(tries) do
		local ok, p = pcall(f)
		if ok and typeof(p) == "Instance" then return p end
	end
	return nil
end

-- Rattache un ScreenGui en essayant CoreGui puis PlayerGui (executors varies).
local function safeParent(gui)
	local parent = getGuiParent()
	if parent then
		local ok = pcall(function() gui.Parent = parent end)
		if ok and gui.Parent then return true end
	end
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if pg then
		local ok = pcall(function() gui.Parent = pg end)
		if ok and gui.Parent then return true end
	end
	return false
end

local function waitChild(parent, name, timeout)
	if not parent then return nil end
	local c = parent:FindFirstChild(name)
	if c then return c end
	local ok, r = pcall(function() return parent:WaitForChild(name, timeout or 20) end)
	if ok and r then return r end
	return parent:FindFirstChild(name)
end

local LP = Players.LocalPlayer
local Remotes = waitChild(RS, "Remotes", 25)
if not Remotes then
	warn("[VenomFarm] Remotes not found - wrong game?")
	return
end
local GetData = waitChild(Remotes, "GetData", 10)
local EvolveRemote = waitChild(Remotes, "Evolve", 10)
local QuestClaim = waitChild(Remotes, "QuestClaim", 10)

local QuestsCfg
pcall(function() QuestsCfg = require(RS.Shared.Config.Quests) end)

local ProgressCfg
pcall(function() ProgressCfg = require(RS.Shared.Config.Progress) end)

local MapsCfg
pcall(function() MapsCfg = require(RS.Shared.Maps) end)

-- ============================================================ generation (anti-conflit d'instances)
-- Chaque execution incremente la generation : seule la plus recente tourne.
-- IMPORTANT : on ne touche JAMAIS aux tables trouvees par getgc (ce sont des
-- templates Luau partages, les modifier corrompt les futurs litteraux de table).
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
	-- Tout est DESACTIVE au lancement : l'utilisateur active ce qu'il veut.
	Farm = false,
	NextStage = false,
	WinPad = false,
	AutoClaim = false,
	AutoEvolve = false,
	TrainEvolve = false,
	AutoQuests = false,
	AutoGifts = false,
	AutoDaily = false,
	AutoPlaytime = false,
	-- Monde ou s'entrainer : 0 = meilleure chambre de tous les mondes,
	-- 1/2/3 = seulement les chambres de ce monde.
	TrainWorld = 0,
	-- Auto Recover a ete retire : plus de "mort -> train -> etape -1".
	Recover = false,
	Train = false,
	Godmode = false,
	AntiAfk = false,
	-- Admin features
	NoClip = false,
	SpeedHack = false,
	WalkSpeed = 16,
	JumpHack = false,
	JumpPower = 50,
	InfJump = false,
	AttackAura = false,
	-- TP direct cote client (contourne les mondes verrouilles par le serveur)
	-- Desactive au lancement comme le reste ; le voyage serveur reste utilise et
	-- bascule en direct automatiquement si le monde est verrouille.
	DirectTp = false,
	AttackRate = 0.15,
	MenuKey = "RightShift",
	-- Sur mobile on active d'office le mode allege (moins d'updates camera).
	LowEnd = IS_MOBILE,
	StageWins = 0,
	StageFails = 0,
	-- 0 = ca avance normalement. >0 = on est bloque (mort / stage trop long) :
	-- c'est la seule condition qui autorise l'entrainement pour l'evolution.
	Stuck = 0,
	StuckStage = nil,
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

-- tue immediatement une instance depassee, meme suspendue dans un appel serveur
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

-- Le serveur REFUSE les gros sauts (au-dela de ~500 studs il renvoie le joueur
-- au dernier checkpoint - c'est ce qui cassait les etapes 13/14/15, tres loin
-- du lobby). On decoupe donc les longs trajets en bonds courts.
--
-- Les etapes 13/14/15 sont sous la lave et separees par des murs : marcher ou
-- voler en ligne droite au niveau du sol traverse la lave et tue le joueur.
-- On fait donc un TRAJET AERIEN : montee au-dessus de tout, croisiere
-- horizontale par bonds de 400 studs, puis descente verticale sur la cible.
-- Verifie en jeu : lobby -> etape 13 sans perdre 1 PV.
local HOP_DIST = 120
local HOP_WAIT = 0.09
local DIRECT_MAX = 220

local AIR_DIST = 400   -- longueur d'un bond en croisiere
local AIR_WAIT = 0.06  -- delai entre deux bonds aeriens
local CRUISE_UP = 180  -- altitude de croisiere au-dessus du point le plus haut

-- > 0 pendant un trajet : les autres boucles ne doivent pas bouger le joueur
local teleporting = 0

local function teleport(pos, lookAt)
	local r = getRoot()
	if not r or typeof(pos) ~= "Vector3" then return end
	local start = r.Position
	local dist = (start - pos).Magnitude

	if dist <= DIRECT_MAX then
		r.CFrame = lookAt and CFrame.new(pos, lookAt) or CFrame.new(pos)
		r.AssemblyLinearVelocity = Vector3.zero
		return
	end

	teleporting += 1
	local ok, err = pcall(function()
		-- point de croisiere : au-dessus du joueur ET de la destination
		local cruiseY = math.max(start.Y, pos.Y) + CRUISE_UP
		local a = Vector3.new(start.X, cruiseY, start.Z)
		local b = Vector3.new(pos.X, cruiseY, pos.Z)

		local function step(from, to, maxLeg, wait)
			local n = math.max(1, math.ceil((to - from).Magnitude / maxLeg))
			for i = 1, n do
				guard()
				local rr = getRoot()
				local hh = getHum()
				if not rr or (hh and hh.Health <= 0) then return false end
				rr.CFrame = CFrame.new(from:Lerp(to, i / n))
				rr.AssemblyLinearVelocity = Vector3.zero
				task.wait(wait)
			end
			return true
		end

		-- 1) montee verticale au-dessus du decor
		if not step(start, a, HOP_DIST, AIR_WAIT) then return end
		-- 2) croisiere horizontale (au-dessus de la lave et des murs)
		if not step(a, b, AIR_DIST, AIR_WAIT) then return end
		-- 3) descente verticale sur le point d'atterrissage
		if not step(b, pos, HOP_DIST, AIR_WAIT) then return end

		local rr = getRoot()
		if rr then
			rr.CFrame = lookAt and CFrame.new(pos, lookAt) or CFrame.new(pos)
			rr.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	teleporting -= 1
	if not ok then jlog("ERR", "teleport " .. tostring(err)) end
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

-- ============================================================ tours de soin (stage 15)
-- Pendant le combat de TheChoir, le boss passe en phase "Fungal Bloom" a
-- certains paliers de PV (70 %, 50 %...) : il devient SHIELDE (degats = 0) et
-- 3 tours de soin apparaissent autour de l'arene. Chaque tour a
-- HP = 6 % des PV max du boss (864 000 ici). Tant qu'une tour est vivante le
-- boss ne peut pas mourir : on casse donc TOUJOURS les tours en priorite.
-- Les tours ne sont pas taguees "VenomEnemy" : on les repere via leur attribut
-- HP et leur attribut Simple == "Tower" (modeles dans Workspace.VenomEnemies).
local function getTowers()
	local out = {}
	local folder = workspace:FindFirstChild("VenomEnemies")
	if not folder then return out end
	for _, m in ipairs(folder:GetChildren()) do
		local hp = tonumber(m:GetAttribute("HP"))
		if hp and hp > 0 and (m.Name == "Tower" or m:GetAttribute("Simple") == "Tower") then
			local core = m:FindFirstChild("Core")
			local root = m:FindFirstChild("HumanoidRootPart") or core
			if core and root then
				out[#out + 1] = { model = m, root = root, aim = core.Position, tower = true, boss = false }
			end
		end
	end
	return out
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

-- zone de l'etape en cours : on n'attaque QUE les ennemis de cette zone,
-- sinon le farm reteleporte le joueur a l'etape voisine et l'etape cible ne se charge jamais.
local activeZone = nil
local ZONE_RADIUS = 200

local function nearestEnemy()
	local r = getRoot()
	if not r then return nil end
	local best, bestD
	-- priorite absolue : les tours de soin (le boss est invulnerable sinon)
	for _, e in ipairs(getTowers()) do
		if not activeZone or (e.root.Position - activeZone).Magnitude < ZONE_RADIUS * 2 then
			local d = (e.root.Position - r.Position).Magnitude
			if not bestD or d < bestD then best, bestD = e, d end
		end
	end
	if best then return best, bestD end
	for _, e in ipairs(getEnemies()) do
		if not activeZone or (e.root.Position - activeZone).Magnitude < ZONE_RADIUS then
			local d = (e.root.Position - r.Position).Magnitude
			if not bestD or d < bestD then best, bestD = e, d end
		end
	end
	return best, bestD
end

-- ============================================================ attaque via la remote du jeu
-- Aucun clic d'attaque n'est envoye a l'ecran : on appelle directement
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

-- Niveau a partir duquel on utilise les griffes (Claw) au lieu de Bite.
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
	if not S.LowEnd or (os.clock() - lastAimAt) > (IS_MOBILE and 1.0 or 0.6) then
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

-- ============================================================ etapes
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

-- Derniere etape reellement construite dans la map (15 pour cette version du
-- jeu). Au-dela il n'y a aucune geometrie : le farm doit rester sur la
-- derniere etape et enchainer les wins gratuites.
local function maxStage()
	local top = 0
	local mq = workspace:FindFirstChild("MapQuarantine")
	if mq then
		for _, m in ipairs(mq:GetChildren()) do
			local k = tonumber(string.match(m.Name, "^Stage(%d+)_"))
			if k and k > top then top = k end
		end
	end
	return top > 0 and top or 15
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

-- Position REELLE de l'arene de l'etape : l'EnemyZone n'existe pas tant que la
-- zone n'est pas chargee, donc on lit d'abord l'attribut ZoneCFrame (fourni par le jeu).
local function stageZonePos(st)
	if not st then return nil end
	local ez = st:FindFirstChild("EnemyZone", true)
	if ez and ez:IsA("BasePart") then return ez.Position end
	local zc = cfFromString(st:GetAttribute("ZoneCFrame"))
	if zc then return zc.Position end
	return nil
end

-- On se teleporte au MILIEU de l'arene (ZoneCFrame), pas au StageStart qui est
-- le point d'entree du couloir : sinon on reste bloque hors de la zone de combat.
--
-- ETAPES 13/14/15 : elles sont tres loin et NE SONT PAS streamees tant qu'on n'a
-- pas demande la zone. Sans RequestStreamAroundAsync le joueur atterrit dans le
-- vide (au-dessus de la lave) et meurt -> retour au checkpoint : c'est ce qui
-- faisait croire que le TP etait casse. On charge donc la zone AVANT de bouger.
--
-- ATTENTION : RequestStreamAroundAsync peut mettre tres longtemps (voire rester
-- bloque). On le lance donc dans un thread separe : la boucle de farm ne doit
-- JAMAIS attendre cette remote.
local function requestStream(pos)
	task.spawn(function()
		pcall(function() LP:RequestStreamAroundAsync(pos, 5) end)
	end)
end

-- Charge la geometrie de l'etape (sans deplacer le joueur : c'est goToStage qui
-- gere le trajet, palier par palier).
local function ensureStageLoaded(n)
	local st = findStage(n)
	if not st then return nil end
	if st:FindFirstChild("EnemyZone", true) then return st end
	local zone = stageZonePos(st)
	local start = cfFromString(st:GetAttribute("StageStart"))
	local target = zone or (start and start.Position)
	if not target then return st end

	requestStream(target)
	for _ = 1, 60 do
		if st:FindFirstChild("EnemyZone", true) then break end
		task.wait(0.2)
		guard()
	end
	return st
end

-- Points d'atterrissage mesures en jeu (position debout sur le sol de l'arene).
-- Les etapes 13/14/15 sont sous la lave : le ZoneCFrame seul tombe parfois dans
-- le vide quand la geometrie vient juste d'etre streamee.
local LANDING = {
	[13] = Vector3.new(-85.15, -77.00, 6891.23),
	[14] = Vector3.new(54.09, -147.00, 8137.31),
	[15] = Vector3.new(-9.30, -224.00, 9099.56),
}

local function landingPos(n, st)
	local o = LANDING[n]
	if o then return o end
	local z = stageZonePos(st)
	return z and (z + Vector3.new(0, 8, 0)) or nil
end

-- Se rend a l'etape n. Etapes 13/14/15 : on descend PALIER PAR PALIER
-- (12 -> 13 -> 14 -> 15). Un saut direct depuis le lobby vers le fond traverse
-- la lave et tue le joueur : c'est ce qui cassait les TP.
local function goToStage(n)
	local st = ensureStageLoaded(n)
	local target = landingPos(n, st)
	if not target then return nil end

	local r = getRoot()
	local near = r and (r.Position - target).Magnitude < 90

	-- 13/14/15 sont sous la lave : on descend palier par palier. Les etapes
	-- des autres mondes (16+) ne sont pas concernees.
	if not near and n >= 13 and n <= 15 then
		local prev = findStage(n - 1)
		local pz = prev and landingPos(n - 1, prev)
		if pz and (not r or (r.Position - pz).Magnitude > 90) then
			requestStream(pz)
			teleport(pz)
			task.wait(0.5)
			guard()
		end
	end

	requestStream(target)
	teleport(target)
	for _ = 1, 20 do
		if st and st:FindFirstChild("EnemyZone", true) then break end
		task.wait(0.2)
		guard()
	end
	return stageZonePos(st) or target
end

-- Il y a DEUX pads par etape : un GRATUIT (texte jaune "N Wins") et un PAYANT
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

-- clique UNIQUEMENT un bouton gratuit d'un ecran de victoire.
-- Allowlist stricte : si le texte ne contient pas un mot "gratuit", on ne clique pas.
-- Aucun appel a PromptGamePassPurchase / PromptProductPurchase n'existe dans ce script.
local FREE_WORDS = { "claim", "free", "gratuit", "continue", "collect", "recuperer", "recuperer" }
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
	-- 3) clic virtuel (fonctionne aussi sur mobile)
	local p = b.AbsolutePosition + b.AbsoluteSize * Vector2.new(0.5, 0.5)
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton1(p)
	end)
	-- 4) dernier recours : VIM (PC, si l'executor l'autorise)
	if VIM then
		pcall(function()
			VIM:SendMouseButtonEvent(math.floor(p.X), math.floor(p.Y), 0, true, game, 0)
			VIM:SendMouseButtonEvent(math.floor(p.X), math.floor(p.Y), 0, false, game, 0)
		end)
	end
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

-- UNIQUEMENT le bouton GRATUIT JAUNE situe a DROITE de l'ecran de victoire.
-- Aucun appel a PromptGamePassPurchase / PromptProductPurchase dans ce script.
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
-- true pendant qu'on s'entraine pour atteindre le niveau requis par l'evolution
local evolveTraining = false
local function isPaused() return os.clock() < pauseUntil end

-- claim gratuit : TP sur le pad JAUNE gratuit + clic du bouton jaune de droite.
-- On verifie que la win est bien consommee, sinon on retente (sans jamais toucher au pad payant).
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

-- ============================================================ entrainement
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

-- Monde d'une chambre (1 par defaut : les chambres 10 et 11 sont dans les
-- mondes 2 et 3).
local function chamberWorld(i)
	local c = TrainingCfg and TrainingCfg.Chambers and TrainingCfg.Chambers[i]
	return (c and tonumber(c.world)) or 1
end

local function chamberGain(i)
	if TrainingCfg and TrainingCfg.Gain then
		local ok, r = pcall(TrainingCfg.Gain, i)
		if ok and type(r) == "number" then return r end
	end
	return 1
end

-- Meilleure chambre possedee. Si S.TrainWorld > 0 on ne regarde QUE les
-- chambres de ce monde (ex : monde 2 = Thunder Stack des 12 evolutions).
local function bestChamberModel()
	local owned = ownedChambers()
	local want = tonumber(S.TrainWorld) or 0

	local function pick(filterWorld)
		local best, bestGain
		for i in pairs(owned) do
			if filterWorld == 0 or chamberWorld(i) == filterWorld then
				local g = chamberGain(i)
				if not bestGain or g > bestGain then best, bestGain = i, g end
			end
		end
		return best, bestGain
	end

	local best = pick(want)
	if not best and want ~= 0 then best = pick(0) end
	if not best then return nil end

	local map = workspace:FindFirstChild(chamberWorld(best) == 1 and "MapQuarantine" or ("MapWorld" .. tostring(chamberWorld(best))))
	local lob = map and map:FindFirstChild("Lobby")
	local sc = lob and lob:FindFirstChild("SoundChambers")
	local folders = {}
	if sc then
		folders[1] = sc
	else
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == "SoundChambers" then folders[#folders + 1] = d end
		end
	end
	for _, d in ipairs(folders) do
		for _, c in ipairs(d:GetChildren()) do
			if c:GetAttribute("Chamber") == best then return c, best end
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
				-- trajet en bonds en cours : on ne deplace pas le joueur ailleurs
				if teleporting > 0 then
					task.wait(0.05)
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
						S.Stuck = (tonumber(S.Stuck) or 0) + 1
						S.StuckStage = tonumber(S.TargetStage) or 1
						setStatus("Dead - recovering...")
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
								setStatus("Too many deaths - stage " .. tostring(S.TargetStage))
								pauseUntil = 0
								local zone = goToStage(S.TargetStage)
								if zone then activeZone = zone end
							else
								if not trainingBreak(S.TrainTime) then
									-- pas de chambre : on descend d'une etape si possible
									if target > 1 then
										S.TargetStage = target - 1
										S.StageWins = 0
									end
								end
								deaths = 0
								if S.Farm and S.TargetStage then
									pauseUntil = 0
									local zone2 = goToStage(S.TargetStage)
									if zone2 then activeZone = zone2 end
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
						local aim = e.aim or e.root.Position
						if dist > 5.5 then
							local away = r.Position - e.root.Position
							away = Vector3.new(away.X, 0, away.Z)
							if away.Magnitude < 0.5 then away = Vector3.new(0, 0, 1) end
							teleport(e.root.Position + away.Unit * 4.5 + Vector3.new(0, 2, 0), aim)
						end
						setStatus(("%s  [%d studs]%s"):format(e.model.Name, math.floor(dist), e.tower and "  TOWER" or (e.boss and "  BOSS" or "")))
						attackAt(aim)
						task.wait(S.AttackRate)
					else
						-- aucun ennemi : on revient au MILIEU de l'arene pour declencher les spawns
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

-- Objectifs d'evolution : nombre de wins ET niveau (calcule depuis le Venom).
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

-- Tant que les wins sont atteints mais pas le niveau : on va s'entrainer dans
-- la meilleure chambre jusqu'au niveau requis, puis on evolue.
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
				local stuck = tonumber(S.Stuck) or 0
				if needWins > 0 and wins >= needWins and lvl >= needLvl then
					tryEvolve()
				elseif needWins > 0 and wins >= needWins and lvl < needLvl and S.TrainEvolve and stuck > 0 then
					-- On ne s'entraine QUE si on est reellement bloque : sinon on
					-- continue a farmer les wins (les wins d'abord, le niveau ensuite).
					local retry = tonumber(S.StuckStage) or tonumber(S.TargetStage) or 1
					evolveTraining = true
					local done = false
					local ok2, err2 = pcall(function() done = trainForEvolve(evo, needLvl) end)
					evolveTraining = false
					if not ok2 then jlog("ERR", "evolve train " .. tostring(err2)) end
					if done and tryEvolve() then
						-- evolution reussie : on retente le stage qui nous bloquait
						S.Stuck = 0
						S.StuckStage = nil
						S.StageFails = 0
						deaths = 0
						S.TargetStage = math.max(1, math.floor(retry))
						pauseUntil = 0
						jlog("EVOLVE", "retry stage " .. tostring(S.TargetStage))
					end
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
			-- On ne reclame QUE les quetes terminees (sinon le serveur refuse).
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
				-- Le bonus s'appelle avec la periode : "Daily" ou "Weekly".
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
-- On declenche les vrais boutons du jeu (FreeReward / DailyRewards / TimeRewards).
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
		-- IMPORTANT : le "Claim All" du header est un PRODUIT ROBUX -> jamais clique.
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

-- ============================================================ quotidien + temps de jeu
-- Le jeu passe par la RemoteFunction "Rewards" :
--   InvokeServer("Daily")           -> reclame le jour suivant disponible
--   InvokeServer("Playtime", index) -> reclame la recompense de temps de jeu
-- "index" est la position dans Rewards.Playtime (deja triee par minutes).
-- Reponse : true = reclame, "claimed" = deja pris, "early"/"slot" = pas pret.
local RewardsRF = Remotes:FindFirstChild("Rewards")

local function claimDaily(force)
	if (not force and not S.AutoDaily) or isPaused() or not RewardsRF then return false end
	local ok, res = pcall(function() return RewardsRF:InvokeServer("Daily") end)
	if ok and res == true then
		S.DailyClaims = (S.DailyClaims or 0) + 1
		jlog("DAILY", "claimed")
		return true
	end
	return false
end

local function playtimeCount()
	local cfg
	pcall(function() cfg = require(RS.Shared.Config.Rewards) end)
	local n = (cfg and type(cfg.Playtime) == "table") and #cfg.Playtime or 0
	return n > 0 and n or 10
end

local function claimPlaytime(force)
	if (not force and not S.AutoPlaytime) or isPaused() or not RewardsRF then return false end
	local done = tostring(LP:GetAttribute("PlaytimeClaimed") or ",")
	local did = false
	for i = 1, playtimeCount() do
		if not done:find("," .. i .. ",", 1, true) then
			local ok, res = pcall(function() return RewardsRF:InvokeServer("Playtime", i) end)
			if ok and res == true then
				did = true
				S.PlaytimeClaims = (S.PlaytimeClaims or 0) + 1
				jlog("PLAYTIME", "claimed " .. i)
			end
			guard()
			task.wait(0.25)
		end
	end
	return did
end

task.spawn(function()
	task.wait(16)
	while alive() do
		if S.AutoDaily and not isPaused() then
			local ok, err = pcall(claimDaily)
			if not ok then jlog("ERR", "daily " .. tostring(err)) end
		end
		task.wait(60)
	end
end)

task.spawn(function()
	task.wait(20)
	while alive() do
		if S.AutoPlaytime and not isPaused() then
			local ok, err = pcall(claimPlaytime)
			if not ok then jlog("ERR", "playtime " .. tostring(err)) end
		end
		task.wait(45)
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
				-- ne jamais tenter un stage verrouille : BestStage + 1 maximum
				local best = tonumber(S.BestStage) or 0
				if best > 0 and n > best + 1 then n = best + 1 end
				-- ne jamais depasser la derniere etape construite (15) : au-dela
				-- le jeu n'a pas de geometrie et le farm tournerait dans le vide.
				local top = maxStage()
				if n > top then n = top end
				if S.TargetStage ~= n then S.TargetStage = n end
				setStatus(("Stage %d - clearing"):format(n))

				local zone = goToStage(n)
				if not zone then
					task.wait(1.5)
					return
				end

				pauseUntil = 0
				activeZone = zone
				local t0 = os.clock()
				local maxTime = math.max(20, tonumber(S.MaxStageTime) or 120)

				while alive() and S.NextStage and tonumber(S.TargetStage) == n and not evolveTraining do
					-- on garde le joueur dans la zone de l'etape (sinon le farm repart ailleurs)
					local rr = getRoot()
					if rr and (rr.Position - zone).Magnitude > 80 then
						teleport(zone + Vector3.new(0, 8, 0))
					end
					local ready = LP:GetAttribute("WinReady") or ""
					if ready:find("," .. n .. ",", 1, true) then
						if claimStageFree(n) then
							S.StageFails = 0
							S.StageWins = 0
							S.Stuck = 0
							S.StuckStage = nil
							local nxt = math.min(n + 1, maxStage())
							S.TargetStage = nxt
							deaths = 0
							if nxt == n then
								setStatus(("Stage %d done -> farming stage %d (max)"):format(n, n))
							else
								setStatus(("Stage %d done -> stage %d"):format(n, nxt))
							end
							break
						end
					elseif (os.clock() - t0) > maxTime then
						S.StageFails = (S.StageFails or 0) + 1
						S.Stuck = (tonumber(S.Stuck) or 0) + 1
						S.StuckStage = n
						if S.StageFails >= 2 and n > 1 then
							S.TargetStage = n - 1
							S.StageWins = 0
							S.StageFails = 0
							setStatus(("Stage %d too slow -> stage %d"):format(n, n - 1))
						else
							setStatus(("Stage %d too slow - training"):format(n))
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

-- superviseur : relance toute boucle qui aurait plante
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

-- ============================================================ admin features
local noclipChanged = {}

local function applyNoClip(on)
	local c = LP.Character
	if not c then return end
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") then
			if on then
				if p.CanCollide then
					p.CanCollide = false
					noclipChanged[p] = true
				end
			elseif noclipChanged[p] then
				p.CanCollide = true
				noclipChanged[p] = nil
			end
		end
	end
end

local function nearestEnemyAnywhere()
	local r = getRoot()
	if not r then return nil end
	local best, bestD
	for _, e in ipairs(getTowers()) do
		local d = (e.root.Position - r.Position).Magnitude
		if not bestD or d < bestD then best, bestD = e, d end
	end
	for _, e in ipairs(getEnemies()) do
		local d = (e.root.Position - r.Position).Magnitude
		if not bestD or d < bestD then best, bestD = e, d end
	end
	return best, bestD
end

local function killAllEnemies()
	task.spawn(function()
		local n = 0
		for _, e in ipairs(getTowers()) do
			if not alive() then break end
			local aim = e.aim or e.root.Position
			teleport(e.root.Position + Vector3.new(0, 2, 4), aim)
			for _ = 1, 3 do
				if not alive() then break end
				attackAt(aim)
				task.wait(S.AttackRate)
			end
			n += 1
		end
		for _, e in ipairs(getEnemies()) do
			if not alive() then break end
			local aim = e.aim or e.root.Position
			teleport(e.root.Position + Vector3.new(0, 2, 4), aim)
			for _ = 1, 3 do
				if not alive() then break end
				attackAt(aim)
				task.wait(S.AttackRate)
			end
			n += 1
		end
		setStatus("Admin: " .. tostring(n) .. " enemies attacked")
	end)
end

-- vitesse / saut / noclip / aura
task.spawn(function()
	while alive() do
		local h = getHum()
		if S.NoClip then applyNoClip(true) end
		if h then
			if S.SpeedHack then h.WalkSpeed = S.WalkSpeed end
			if S.JumpHack then
				h.UseJumpPower = true
				h.JumpPower = S.JumpPower
			end
		end
		task.wait(0.2)
	end
end)

-- attaque automatique sur l'ennemi le plus proche, sans filtre de zone
task.spawn(function()
	while alive() do
		if S.AttackAura then
			local e = nearestEnemyAnywhere()
			if e then attackAt(e.aim or e.root.Position) end
			task.wait(S.AttackRate)
		else
			task.wait(0.3)
		end
	end
end)

UIS.JumpRequest:Connect(function()
	if not S.InfJump then return end
	local h = getHum()
	if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

-- ============================================================ monde / spawn
-- Les 3 mondes sont des maps separees dans Workspace :
--   monde 1 = MapQuarantine (autour de X = 0)
--   monde 2 = MapWorld2     (autour de X = 20000)
--   monde 3 = MapWorld3     (autour de X = 40000)
-- Positions de secours (mesurees en jeu) si le lobby n'est pas encore streame.
local WORLD_LOBBY = {
	[1] = Vector3.new(0, 6, -155),
	[2] = Vector3.new(20000, 405, 5),
	[3] = Vector3.new(40000, 405, -95),
}

local function worldMap(n)
	return workspace:FindFirstChild(n == 1 and "MapQuarantine" or ("MapWorld" .. tostring(n)))
end

-- Position ou se poser dans le lobby du monde n (sol reel du lobby).
local function worldLobbyPos(n)
	n = math.clamp(math.floor(tonumber(n) or 1), 1, 3)
	local map = worldMap(n)
	local lob = map and map:FindFirstChild("Lobby")
	if lob then
		local floor = lob:FindFirstChild("LobbyFloor", true)
		if floor and floor:IsA("BasePart") then
			return floor.Position + Vector3.new(0, 5, 0)
		end
		local paint = lob:FindFirstChild("LobbyPaint")
		if paint then
			local ok, piv = pcall(function() return paint:GetPivot().Position end)
			if ok and piv then
				local rp = RaycastParams.new()
				rp.FilterType = Enum.RaycastFilterType.Exclude
				rp.FilterDescendantsInstances = { LP.Character }
				local hit = workspace:Raycast(piv + Vector3.new(0, 40, 0), Vector3.new(0, -200, 0), rp)
				if hit then return hit.Position + Vector3.new(0, 5, 0) end
				return piv + Vector3.new(0, 5, 0)
			end
		end
	end
	return WORLD_LOBBY[n]
end

local function teleportToCursor()
	local cam = workspace.CurrentCamera
	if not cam then return false end
	local mp = UIS:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mp.X, mp.Y)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { LP.Character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, rp)
	local pos = hit and hit.Position or (ray.Origin + ray.Direction * 200)
	teleport(pos + Vector3.new(0, 3, 0))
	setStatus("TP cursor")
	return true
end

-- Anti-AFK SANS saut : on ne simule aucune touche
LP.Idled:Connect(function()
	if not alive() or not S.AntiAfk then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new(4, 4))
	end)
	jlog("AFK", "idle counter reset")
end)

-- stats serveur (wins / venom / best stage) rafraichies doucement
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

-- TP direct cote client : on demande le streaming autour du spawn puis on
-- deplace le personnage. Ca marche meme quand le monde est verrouille cote
-- serveur (le serveur repondrait "Locked" au voyage officiel).
local function tpWorldSpawn(n)
	n = math.clamp(math.floor(tonumber(n) or 1), 1, 3)
	local pos = worldLobbyPos(n)
	if not pos then
		notify("Teleportation", "World " .. tostring(n) .. " spawn not found", false)
		return false
	end
	requestStream(pos)
	task.wait(0.6)
	teleport(pos)
	setStatus("Direct TP world " .. tostring(n))
	notify("Teleportation", "Direct TP: world " .. tostring(n))
	return true
end

-- ============================================================ teleportation
-- Voyage vers un monde.
--  * S.DirectTp = true  -> TP direct cote client au spawn du monde (marche
--    meme si le monde est verrouille : le serveur ne peut pas l'empecher).
--  * S.DirectTp = false -> voyage officiel via Remotes.World "Travel" <id>.
--    Le serveur repond "Locked" si le monde n'est pas debloque (monde 2 =
--    etape 15, monde 3 = etape 30) ; dans ce cas on bascule en direct.
local function travelWorld(n)
	n = math.clamp(math.floor(tonumber(n) or 1), 1, 3)
	if S.DirectTp then return tpWorldSpawn(n) end

	local w = Remotes:FindFirstChild("World")
	if not w then return tpWorldSpawn(n) end
	if not pcall(function() w:FireServer("Travel", n) end) then return tpWorldSpawn(n) end

	setStatus("Traveling to world " .. tostring(n))
	notify("Teleportation", "Traveling to world " .. tostring(n))

	-- Si le serveur refuse (monde verrouille) le joueur ne bouge pas : apres
	-- 2.5 s on y va quand meme en direct.
	task.spawn(function()
		local before = getRoot() and getRoot().Position
		local t0 = os.clock()
		while alive() and (os.clock() - t0) < 2.5 do
			task.wait(0.25)
			local r = getRoot()
			if r and before and (r.Position - before).Magnitude > 200 then return end
		end
		-- le serveur a refuse : on y va quand meme, en direct
		tpWorldSpawn(n)
	end)
	return true
end

local function worldOf(pos)
	if MapsCfg and MapsCfg.WorldAt then
		return MapsCfg.WorldAt(pos)
	end
	return (pos.X > 30000 and 3) or (pos.X > 17000 and 2) or 1
end

-- TP vers une etape, meme si elle est dans un autre monde.
-- goToStage lit l'attribut ZoneCFrame de l'etape (present meme sans streaming)
-- et fait un TP client : aucun voyage serveur n'est necessaire.
local function teleportStageSmart(n)
	n = math.max(1, math.floor(tonumber(n) or 1))
	S.TargetStage = n
	S.StageWins = 0
	local zone = goToStage(n)
	if zone then activeZone = zone end
	setStatus("TP stage " .. tostring(n))
	return true
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
		function() return http.request({ Url = url, Method = "GET" }).Body end,
		function() return fluxus.request({ Url = url, Method = "GET" }).Body end,
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
	local gui = Instance.new("ScreenGui")
	gui.Name = "VenomFarm"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9999
	if not safeParent(gui) then return nil end

	local cam = workspace.CurrentCamera
	local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
	local w = math.clamp(math.floor(vp.X * (IS_MOBILE and 0.72 or 0.30)), 250, IS_MOBILE and 430 or 340)
	local btnH = IS_MOBILE and 44 or 34
	local gap = 10
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(w, 56 + btnH + 12)
	frame.Position = IS_MOBILE and UDim2.new(0.5, -w / 2, 0, 64) or UDim2.fromOffset(14, 70)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -20, 0, 48)
	label.Position = UDim2.fromOffset(10, 8)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = IS_MOBILE and 13 or 12
	label.TextWrapped = true
	label.TextColor3 = Color3.fromRGB(230, 230, 235)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = "Venom Farm - simple menu (NextUI failed to load)\nFree wins only. No Robux."
	label.Parent = frame

	local btnW = (w - gap * 3) / 2
	local function mkButton(text, slot, color, cb)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(btnW, btnH)
		b.Position = UDim2.fromOffset(gap + slot * (btnW + gap), 56)
		b.BackgroundColor3 = color
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = IS_MOBILE and 13 or 12
		b.Text = text
		b.Parent = frame
		b.Activated:Connect(cb)
		return b
	end

	mkButton("STOP", 0, Color3.fromRGB(190, 60, 60), function()
		S.Farm, S.NextStage, S.Train, S.WinPad = false, false, false, false
		S.AutoEvolve, S.AutoQuests, S.AutoGifts = false, false, false
		S.AutoDaily, S.AutoPlaytime = false, false
		label.Text = "Stopped."
	end)
	mkButton("HIDE", 1, Color3.fromRGB(60, 60, 70), function()
		gui.Enabled = false
		task.delay(1, function() gui.Enabled = true end)
	end)
	return gui
end

-- Bouton flottant de secours : si NextUI n'a pas cree son bouton mobile, on en
-- fabrique un pour toujours pouvoir rouvrir le menu (mobile uniquement).
local function ensureMobileButton(NextUI)
	if not IS_MOBILE then return end
	task.delay(1.5, function()
		if not alive() then return end
		local gui = NextUI and NextUI.Gui
		if gui and gui:FindFirstChild("MobileButton", true) then return end
		local parent = getGuiParent()
		if parent then
			local old = parent:FindFirstChild("VenomFarmButton")
			if old then old:Destroy() end
		end
		local sg = Instance.new("ScreenGui")
		sg.Name = "VenomFarmButton"
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 9998
		if not safeParent(sg) then return end
		local b = Instance.new("TextButton")
		b.Name = "Open"
		b.Size = UDim2.fromOffset(56, 56)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.new(1, -44, 0.28, 0)
		b.BackgroundColor3 = Color3.fromRGB(140, 60, 220)
		b.BackgroundTransparency = 0.05
		b.Text = "VF"
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 16
		b.Parent = sg
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = b

		b.Activated:Connect(function()
			pcall(function() ui.window:Toggle() end)
		end)

		local dragging, start, base = false, nil, nil
		b.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging, start, base = true, i.Position, b.Position
			end
		end)
		UIS.InputChanged:Connect(function(i)
			if not dragging then return end
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement then
				local d = i.Position - start
				b.Position = UDim2.new(base.X.Scale, base.X.Offset + d.X, base.Y.Scale, base.Y.Offset + d.Y)
			end
		end)
		UIS.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging = false
			end
		end)
	end)
end

local function buildUI()
	local NextUI
	local ok, res = pcall(loadNextUI)
	if ok then NextUI = res end
	if not NextUI then
		jlog("UI", "NextUI unavailable - fallback")
		buildFallback()
		return
	end

	ui.notify = NextUI
	local cam = workspace.CurrentCamera
	local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
	local winW, winH, tabW
	if IS_MOBILE then
		winW = math.clamp(math.floor(vp.X * 0.94), 320, 720)
		winH = math.clamp(math.floor(vp.Y * 0.86), 260, 520)
		tabW = math.clamp(math.floor(winW * 0.36), 130, 168)
	else
		winW = math.clamp(math.floor(vp.X * 0.55), 420, 780)
		winH = math.clamp(math.floor(vp.Y * 0.72), 320, 540)
		tabW = 200
	end

	local Window = NextUI:CreateWindow({
		Title = "Venom Farm",
		SubTitle = "v6 - free wins - admin - TP",
		Theme = "Crimson",
		Glass = true,
		Size = Vector2.new(winW, winH),
		TabWidth = tabW,
		ToggleKey = Enum.KeyCode.RightShift,
		MobileButton = IS_MOBILE and {
			Size = 52,
			Position = UDim2.new(1, -42, 0.28, 0),
			Draggable = true,
		} or "Auto",
	})
	ui.window = Window
	ui.nextui = NextUI
	_G.__NextUI = NextUI

	-- Force le theme Crimson + Glass des le premier affichage (meme si la
	-- version de NextUI ignore les options ci-dessus).
	pcall(function() NextUI:SetTheme("Crimson", true) end)
	pcall(function() NextUI:SetGlass(true) end)
	ensureMobileButton(NextUI)

	-- PC : fenetre a gauche pour laisser la zone de clic libre a droite.
	-- Mobile : on garde le centrage par defaut (plus pratique au pouce).
	if not IS_MOBILE then
		pcall(function()
			local main = NextUI.Windows and NextUI.Windows[1] and NextUI.Windows[1]._main
			if main then main.Position = UDim2.fromOffset(12, 56) end
		end)
	end

	-- ================= Farm tab
	local FarmTab = Window:AddTab({ Title = "Farm", Icon = "crosshair" })

	local Auto = FarmTab:AddSection({ Title = "Automation", Icon = "bot" })

	local farmToggle
	local nextToggle
	farmToggle = Auto:AddToggle({
		Title = "Auto Farm",
		Description = "Teleport in front of enemies and attack",
		Style = "Switch",
		Default = S.Farm,
		Flag = "farm",
		Callback = function(on)
			S.Farm = on
			if on then
				-- Auto Farm active TOUJOURS Auto Next Stage (demande utilisateur).
				S.NextStage = true
				if nextToggle then pcall(function() nextToggle:Set(true) end) end
				startAt(S.StartStage)
				farmLoop()
				stageLoop()
				notify("Auto Farm", "Started at stage " .. tostring(S.TargetStage))
			else
				S.NextStage = false
				if ui.opts and ui.opts.next then pcall(function() ui.opts.next:Set(false) end) end
			end
		end,
	})

	nextToggle = Auto:AddToggle({
		Title = "Auto Next Stage",
		Description = "Clear a stage, claim the free win, move on",
		Style = "Switch",
		Default = S.NextStage,
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
		Description = "Free claim only - never Robux",
		Style = "Switch",
		Default = S.AutoClaim,
		Flag = "autoclaim",
		Callback = function(on) S.AutoClaim = on end,
	})

	Auto:AddToggle({
		Title = "Win Pad Claim",
		Description = "Teleport on the yellow free pad only",
		Style = "Switch",
		Default = S.WinPad,
		Flag = "winpad",
		Callback = function(on) S.WinPad = on; if on then winLoop() end end,
	})

	-- ================= Evolution (reste dans Farm)
	local Evo = FarmTab:AddSection({ Title = "Evolution", Icon = "flask-conical" })

	Evo:AddToggle({
		Title = "Auto Evolve",
		Description = "Evolves as soon as the requirements are met",
		Style = "Switch",
		Default = S.AutoEvolve,
		Flag = "auto_evolve",
		Callback = function(on) S.AutoEvolve = on end,
	})

	Evo:AddToggle({
		Title = "Train for Evolve",
		Description = "Wins reached -> train until the required level",
		Style = "Switch",
		Default = S.TrainEvolve,
		Flag = "train_evolve",
		Callback = function(on) S.TrainEvolve = on end,
	})

	Evo:AddToggle({
		Title = "Auto Train",
		Description = "Stays on the best unlocked chamber pad",
		Style = "Switch",
		Default = S.Train,
		Flag = "train",
		Callback = function(on) S.Train = on; if on then trainLoop() end end,
	})

	-- Monde d'entrainement : on prend la meilleure chambre POSSEDEE de ce
	-- monde (ex : monde 2 = Thunder Stack a partir de 12 evolutions).
	local trainWorldDrop = Evo:AddDropdown({
		Title = "Train world",
		Description = "World used for training - best unlocked chamber there",
		Values = { "Auto (best)", "World 1", "World 2", "World 3" },
		Flag = "train_world",
		Callback = function(v)
			local map = { ["Auto (best)"] = 0, ["World 1"] = 1, ["World 2"] = 2, ["World 3"] = 3 }
			S.TrainWorld = map[v] or 0
			jlog("TRAIN", "world " .. tostring(S.TrainWorld))
		end,
	})
	_G.__trainWorldDrop = trainWorldDrop
	pcall(function() trainWorldDrop:Set("Auto (best)", true) end)

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
		Description = "Slower than this = too hard -> train / go down",
		Min = 20, Max = 600, Default = 120, Increment = 10, Suffix = " s",
		Flag = "max_stage_time",
		Callback = function(v) S.MaxStageTime = v end,
	})

	Prog:AddNumberInput({
		Title = "Train duration",
		Description = "Training length before retrying a hard stage",
		Min = 10, Max = 600, Default = 45, Increment = 5, Suffix = " s",
		Flag = "train_time",
		Callback = function(v) S.TrainTime = v end,
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

	-- ================= Combat (deplace depuis Admin features)
	local FarmCombat = FarmTab:AddSection({ Title = "Combat", Icon = "swords" })

	FarmCombat:AddToggle({
		Title = "Auto Attack (aura)",
		Description = "Attacks the closest enemy anywhere",
		Style = "Switch",
		Default = S.AttackAura,
		Flag = "attack_aura",
		Callback = function(on) S.AttackAura = on end,
	})

	FarmCombat:AddButton({
		Title = "Kill all enemies",
		Description = "TP + attack every enemy",
		Callback = function() killAllEnemies() end,
	})

	FarmCombat:AddButton({
		Title = "Teleport to next enemy",
		Callback = function()
			local e = nearestEnemyAnywhere()
			if e then
				teleport(e.root.Position + Vector3.new(0, 2, 4), e.aim or e.root.Position)
				setStatus("TP enemy")
			end
		end,
	})

	-- ================= Character tab
	local CharTab = Window:AddTab({ Title = "Character", Icon = "user" })
	local Char = CharTab:AddSection({ Title = "Player", Icon = "user" })

	Char:AddToggle({
		Title = "Anti-AFK (no jump)",
		Description = "Resets the idle timer without pressing Space",
		Style = "Switch",
		Default = S.AntiAfk,
		Flag = "antiafk",
		Callback = function(on) S.AntiAfk = on end,
	})

	-- ================= Rewards tab (hors Farm)
	local RewardsTab = Window:AddTab({ Title = "Rewards", Icon = "trophy" })
	local Rew = RewardsTab:AddSection({ Title = "Free Rewards", Icon = "star" })

	Rew:AddToggle({
		Title = "Auto Claim Quests",
		Description = "Daily + weekly quests and completion bonus",
		Style = "Switch",
		Default = S.AutoQuests,
		Flag = "auto_quests",
		Callback = function(on) S.AutoQuests = on end,
	})

	Rew:AddToggle({
		Title = "Auto Claim Gifts",
		Description = "Free gift box only",
		Style = "Switch",
		Default = S.AutoGifts,
		Flag = "auto_gifts",
		Callback = function(on) S.AutoGifts = on end,
	})

	local RewDaily = RewardsTab:AddSection({ Title = "Daily", Icon = "calendar" })

	RewDaily:AddToggle({
		Title = "Auto Claim Daily Rewards",
		Description = "Claims the next available day automatically",
		Style = "Switch",
		Default = S.AutoDaily,
		Flag = "auto_daily",
		Callback = function(on) S.AutoDaily = on end,
	})

	RewDaily:AddButton({
		Title = "Claim daily now",
		Description = "Free - never the Robux Claim All",
		Callback = function()
			task.spawn(function()
				local got = 0
				for _ = 1, 7 do
					if claimDaily(true) then got += 1 else break end
					task.wait(0.4)
				end
				notify("Daily", got > 0 and ("Claimed " .. got .. " day(s)") or "Nothing ready", got > 0)
			end)
		end,
	})

	local RewTime = RewardsTab:AddSection({ Title = "Playtime", Icon = "clock" })

	RewTime:AddToggle({
		Title = "Auto Claim Playtime Rewards",
		Description = "Claims every playtime milestone as soon as it is ready",
		Style = "Switch",
		Default = S.AutoPlaytime,
		Flag = "auto_playtime",
		Callback = function(on) S.AutoPlaytime = on end,
	})

	RewTime:AddButton({
		Title = "Claim playtime now",
		Description = "Uses the game remote directly",
		Callback = function()
			task.spawn(function()
				local did = claimPlaytime(true)
				notify("Playtime", did and "Claimed!" or "Nothing ready", did)
			end)
		end,
	})

	-- ================= Teleportation tab
	local TpTab = Window:AddTab({ Title = "Teleportation", Icon = "globe" })

	local TpWorld = TpTab:AddSection({ Title = "Worlds (spawn)", Icon = "globe" })

	TpWorld:AddToggle({
		Title = "TP direct (client)",
		Description = "TP to spawn client-side: works even if the world is locked",
		Style = "Switch",
		Default = S.DirectTp,
		Flag = "direct_tp",
		Callback = function(on) S.DirectTp = on end,
	})

	TpWorld:AddButton({
		Title = "Quarantine",
		Description = "World 1",
		Callback = function() travelWorld(1) end,
	})

	TpWorld:AddButton({
		Title = "Symbiote Homeworld",
		Description = "World 2",
		Callback = function() travelWorld(2) end,
	})

	TpWorld:AddButton({
		Title = "Grave Isles",
		Description = "World 3",
		Callback = function() travelWorld(3) end,
	})

	local TpStage = TpTab:AddSection({ Title = "Stages", Icon = "map" })

	local tStage = TpStage:AddNumberInput({
		Title = "Stage",
		Description = "Pick the stage number (1 to 60)",
		Min = 1, Max = 60, Default = 1, Increment = 1,
		Flag = "_tp_stage",
	})

	TpStage:AddButton({
		Title = "TP to stage",
		Description = "Teleports straight into the arena (works in all 3 worlds)",
		Callback = function()
			teleportStageSmart(math.floor(tonumber(tStage:Get()) or 1))
		end,
	})

	-- ================= Admin features
	local AdminTab = Window:AddTab({ Title = "Admin features", Icon = "shield" })

	local AdminLife = AdminTab:AddSection({ Title = "Survival", Icon = "shield" })

	AdminLife:AddToggle({
		Title = "Godmode",
		Description = "Keeps your health topped up",
		Style = "Switch",
		Default = S.Godmode,
		Flag = "godmode",
		Callback = function(on) S.Godmode = on end,
	})

	AdminLife:AddToggle({
		Title = "No Clip",
		Description = "Walk through walls and props",
		Style = "Switch",
		Default = S.NoClip,
		Flag = "noclip",
		Callback = function(on)
			S.NoClip = on
			applyNoClip(on)
		end,
	})

	AdminLife:AddToggle({
		Title = "Infinite Jump",
		Description = "Infinite jump (press Space)",
		Style = "Switch",
		Default = S.InfJump,
		Flag = "infjump",
		Callback = function(on) S.InfJump = on end,
	})

	local AdminMove = AdminTab:AddSection({ Title = "Movement", Icon = "move" })

	AdminMove:AddSlider({
		Title = "WalkSpeed",
		Description = "Movement speed (16 = default)",
		Min = 16, Max = 250, Default = 16, Increment = 1,
		Flag = "walkspeed",
		Callback = function(v)
			S.WalkSpeed = v
			S.SpeedHack = v > 16
			if not S.SpeedHack then
				local h = getHum()
				if h then h.WalkSpeed = 16 end
			end
		end,
	})

	AdminMove:AddSlider({
		Title = "JumpPower",
		Description = "Jump power (50 = default)",
		Min = 50, Max = 400, Default = 50, Increment = 5,
		Flag = "jumppower",
		Callback = function(v)
			S.JumpPower = v
			S.JumpHack = v > 50
			if not S.JumpHack then
				local h = getHum()
				if h then h.JumpPower = 50 end
			end
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
		Description = "Fewer camera updates - better FPS on phones (auto on mobile)",
		Style = "Switch",
		Default = S.LowEnd,
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
			S.AutoDaily, S.AutoPlaytime = false, false
			S.AttackAura, S.InfJump = false, false
			S.SpeedHack, S.JumpHack = false, false
			S.NoClip = false
			applyNoClip(false)
			local h = getHum()
			if h then
				h.WalkSpeed = 16
				h.JumpPower = 50
			end
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
	ui.labels.evoNeed = Stats:AddLabel("Evolve: wins 0/0 - level 0/0")
	ui.labels.quests = Stats:AddLabel("Quest claims: 0")
	ui.labels.gifts = Stats:AddLabel("Gift claims: 0")
	ui.labels.daily = Stats:AddLabel("Daily claims: 0")
	ui.labels.playtime = Stats:AddLabel("Playtime claims: 0")
	ui.labels.device = Stats:AddLabel(
		("Device: %s  -  executor: %s"):format(IS_MOBILE and "mobile" or "pc", EXEC)
	)

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

-- rafraichit les labels / watermark
task.spawn(function()
	while alive() do
		local st = S.TargetStage or S.StartStage or 1
		if ui.statusItem then pcall(function() ui.statusItem:Set(S.Status) end) end
		local L = ui.labels
		if L.status then
			pcall(function() L.status:Set("Status: " .. tostring(S.Status)) end)
			pcall(function() L.stage:Set(("Stage: %s%s"):format(tostring(st), ((tonumber(S.Stuck) or 0) > 0) and (" - stuck x" .. tostring(S.Stuck)) or "")) end)
			pcall(function() L.wins:Set(("Wins: %s  (best %s)"):format(tostring(S.Wins), tostring(S.BestStage))) end)
			pcall(function() L.venom:Set("Venom: " .. tostring(S.Venom)) end)
			pcall(function() L.rate:Set("Attack: remote  -  " .. tostring(S.AttackRate) .. " s") end)
			if L.paid then pcall(function() L.paid:Set("Robux buttons blocked: " .. tostring(S.RobuxBlocked or 0)) end) end
			if L.evolve then pcall(function() L.evolve:Set("Evolutions: " .. tostring(S.Evolutions or 0)) end) end
			if L.evoNeed then
				pcall(function()
					L.evoNeed:Set(("Evolve: wins %s/%s - level %s/%s"):format(
						tostring(S.Wins or 0), tostring(S.EvolveNeedWins or 0),
						tostring(S.EvolveLevel or 0), tostring(S.EvolveNeedLevel or 0)))
				end)
			end
			if L.quests then pcall(function() L.quests:Set("Quest claims: " .. tostring(S.QuestClaims or 0)) end) end
			if L.gifts then pcall(function() L.gifts:Set("Gift claims: " .. tostring(S.GiftClaims or 0)) end) end
			if L.daily then pcall(function() L.daily:Set("Daily claims: " .. tostring(S.DailyClaims or 0)) end) end
			if L.playtime then pcall(function() L.playtime:Set("Playtime claims: " .. tostring(S.PlaytimeClaims or 0)) end) end
		end
		-- mobile : on rafraichit moins souvent pour garder des FPS
		task.wait(IS_MOBILE and 1 or 0.5)
	end
end)

pcall(buildUI)

-- ============================================================ API
_G.MadiumFarm = {
	Gen = GEN,
	State = S,
	Device = IS_MOBILE and "mobile" or "pc",
	Executor = EXEC,
	ToggleMenu = function() pcall(function() if ui.window then ui.window:Toggle() end end) end,
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
	ClaimDaily = claimDaily,
	ClaimPlaytime = claimPlaytime,
	BestChamber = bestChamberModel,
	FindFreePad = findPad,
	TeleportStage = function(n)
		return teleportStageSmart(n)
	end,
	TravelWorld = travelWorld,
	TeleportTo = function(pos)
		if typeof(pos) ~= "Vector3" then return false end
		teleport(pos)
		return true
	end,
	TeleportCursor = teleportToCursor,
	KillAll = killAllEnemies,
	GetEnemies = getEnemies,
	Log = _G.__MadiumLog,
	Debug = function()
		return {
			evolveTraining = evolveTraining,
			running = { farm = running.farm, stage = running.stage, train = running.train, win = running.win },
			teleporting = teleporting,
			paused = isPaused(),
			pauseIn = pauseUntil - os.clock(),
			target = S.TargetStage,
			next = S.NextStage,
			farm = S.Farm,
		}
	end,
}

-- ============================================================ demarrage
jlog("START", "gen=" .. GEN .. " player=" .. LP.Name)
if S.Farm then
	startAt(S.StartStage)
	farmLoop()
	if S.NextStage then stageLoop() end
end
if S.WinPad then winLoop() end

print("[VenomFarm v4] loaded - stage " .. tostring(S.TargetStage))
