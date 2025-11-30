--[[
WEAPON CONTROLLER
Will handle all the basic weapon functions for all weapons that are tagged "Weapon". All weapon attributes are inside the weapon as a tool
later, i will change the animation handling to make it server-sided
]]
--TYPES--
type AnimMap = {
	idle: AnimationTrack?,
	block: AnimationTrack?,
	equip: AnimationTrack?,
	unequip: AnimationTrack?,
	heavy: AnimationTrack?,
	aerial: AnimationTrack?,
	runningAttack: AnimationTrack?,
	m: {AnimationTrack?},
}

type WeaponControllerConfig = { inputPriority: number? }
------------------------------------------------
--VARIABLES
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CAS = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Holster = require(RS:WaitForChild("Modules"):WaitForChild("Holster"))
local VFX = require(RS:WaitForChild("Modules"):WaitForChild("VFX"))
local SFX = require(RS:WaitForChild("Modules"):WaitForChild("SFX"))

local remotes = RS:WaitForChild("Remotes")
local hitMarker = remotes:WaitForChild("HitMarker")
local reaction = remotes:WaitForChild("Reaction")
local blockState = remotes:WaitForChild("BlockState")
local fx = remotes:WaitForChild("Fx")
local sfx = remotes:WaitForChild("Sfx")
local fxReq = remotes:WaitForChild("FxReq")
local sfxReq = remotes:FindFirstChild("SfxReq")

local animationsRoot = RS:WaitForChild("Animations")
local weaponsAnimRoot = animationsRoot:WaitForChild("Weapons")
local hitAnimRoot = animationsRoot:FindFirstChild("Hit")
local guardBreakAnim = animationsRoot:FindFirstChild("GuardBreak")
-----------------------------------------------------Module 
local WeaponController = {}
WeaponController.__index = WeaponController

--Local Functions--
local function attr(inst: Instance?, name: string): any
	return inst and inst:GetAttribute(name)
end

local function now(): number
	return os.clock()
end

local function getNumberValue(parent: Instance?, name: string): number?
	if not parent then return nil end
	local v = parent:FindFirstChild(name)
	if v and v:IsA("NumberValue") then
		local n = v.Value
		if typeof(n) == "number" then return n end
	end
	return nil
end

local function playSfx(char: Instance, toolName: string?, name: string)
	local w = toolName or "Default"
	SFX.play(char, w, name)
	if sfxReq then sfxReq:FireServer(w, name, char) end
end
--------------------
function WeaponController.new(player: Player, config: WeaponControllerConfig?)
	local self = setmetatable({}, WeaponController)

	self.player = player
	self.char = player.Character or player.CharacterAdded:Wait()
	self.hum = self.char:WaitForChild("Humanoid") :: Humanoid
	self.animator = self.hum:WaitForChild("Animator") :: Animator

	self.states = self.char:WaitForChild("States")
	self.attacking = self.states:WaitForChild("Attacking") :: BoolValue
	self.blocking = self.states:WaitForChild("Blocking") :: BoolValue
	self.stunned = self.states:WaitForChild("Stunned") :: BoolValue
	self.parrying = self.states:WaitForChild("Parrying") :: BoolValue
	self.guardBroken = self.states:WaitForChild("GuardBroken") :: BoolValue
	self.dodging = self.states:WaitForChild("Dodging") :: BoolValue

	self.values = self.char:FindFirstChild("Values")

	self.bound = false
	self.tool = nil :: Tool?
	self.anims = nil :: AnimMap?
	self.hitAnims = {} :: { [number]: AnimationTrack? }
	self.extraTracks = {} :: { [string]: AnimationTrack }
	self.markerConns = {} :: { RBXScriptConnection }
	self.conns = {} :: { RBXScriptConnection }

	self.comboIndex = 1
	self.inputPriority = (config and config.inputPriority) or 200

	self.lastAttackAt = 0
	self.comboResetDelay = 2
	self._comboResetToken = 0
	self.postComboCooldown = 0.5
	self.comboLocked = false

	self.critCdUntil = 0

	self.parryToken = 0
	self._activeParryToken = -1
	self._activeParryUntil = 0
	self._parryHitToken = -1
	self._parryCooldownUntil = 0
	self._parryMissCd = 2

	self._blockCooldownUntil = 0
	self._blockHeld = false

	self.attackBufferTime = 0.25
	self.blockBufferTime = 0.25
	self._attackBufferedUntil = 0
	self._blockBufferedUntil = 0

	self.lastJumpAt = 0
	self.aerialCooldownUntil = 0

	self.slowSpeed = 8
	self.origWalk = self.hum.WalkSpeed
	self.speedMultiplier = 1

	self.feintLockUntil = 0
	self.feintAttackUnlockUntil = 0

	self.hitArmed = false
	self.curTrack = nil :: AnimationTrack?

	self._rmbDownAt = 0
	self._rmbMoved = false

	self._runCarryConn = nil :: RBXScriptConnection?
	self._runCarryLV = nil :: LinearVelocity?
	self._runCarryAtt = nil :: Attachment?

	self._trailList = nil :: { Trail }?
	self._parriedAnims = nil :: { Animation }?

	local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
		local c = signal:Connect(fn)
		table.insert(self.conns, c)
		return c
	end
	self._connect = connect

	-- INITIAL VALUES------------
	do
		local o = getNumberValue(self.values, "OriginalWalkSpeed")
		if o then self.origWalk = o end

		local ss = getNumberValue(self.values, "SlowSpeed")
		if ss then self.slowSpeed = ss end

		local sm = getNumberValue(self.values, "SpeedMultiplier")
		if sm then self.speedMultiplier = sm end

		if self.values then
			local own = self.values:FindFirstChild("OriginalWalkSpeed")
			if own and own:IsA("NumberValue") then
				connect(own:GetPropertyChangedSignal("Value"), function()
					if typeof(own.Value) == "number" then self.origWalk = own.Value end
					self:_applySpeed()
				end)
			end
			local smv = self.values:FindFirstChild("SpeedMultiplier")
			if smv and smv:IsA("NumberValue") then
				connect(smv:GetPropertyChangedSignal("Value"), function()
					if typeof(smv.Value) == "number" then self.speedMultiplier = smv.Value end
					self:_applySpeed()
				end)
			end
		end
	end

	self:_bindStateSpeed()
	self:_bindStunWatcher()
	self:_bindReactions()

	connect(self.hum.StateChanged, function(_, newState)
		if newState == Enum.HumanoidStateType.Jumping then
			self.lastJumpAt = now()
		end
	end)

	-- Disbled checking: ragdoll and grip/carry states will cancel combat functions
	local function onDisableRelevantChanged()
		if self:_isDisabled() then
			self:cancelAttack()
			self.blocking.Value = false
			self.parrying.Value = false
			self:stopAll()
			if fxReq then fxReq:FireServer("ToolTrailsOff", self.char) end
		end
		self:_applySpeed()
		self:_tryConsumeBuffers()
	end

	local function hookAttr(name: string)
		connect(self.char:GetAttributeChangedSignal(name), onDisableRelevantChanged)
	end
	hookAttr("IsCarried")
	hookAttr("IsCarrying")
	hookAttr("IsGripping")
	hookAttr("IsBeingGripped")

	local rt = self.char:FindFirstChild("RagdollTrigger")
	if rt and rt:IsA("BoolValue") then
		connect(rt.Changed, onDisableRelevantChanged)
	end

	local wv = self.values and self.values:FindFirstChild("CurrentWeapon")
	local wn = (wv and wv:IsA("StringValue") and wv.Value) or ""
	if wn ~= "" then Holster.onSpawn(self.char, wn) end

	connect(self.player.CharacterAppearanceLoaded, function(c)
		if c == self.char then Holster.rebind(self.char) end
	end)

	return self
end

function WeaponController:_speedMul(): number
	local m = self.speedMultiplier
	if typeof(m) ~= "number" or m <= 0 then return 1 end
	return m
end

function WeaponController:_isDisabled(): boolean
	if not self.char or not self.char.Parent then return true end
	if attr(self.char, "IsCarried") == true then return true end
	if attr(self.char, "IsCarrying") == true then return true end
	if attr(self.char, "IsGripping") == true then return true end
	if attr(self.char, "IsBeingGripped") == true then return true end
	local rt = self.char:FindFirstChild("RagdollTrigger")
	if rt and rt:IsA("BoolValue") and rt.Value then return true end
	return false
end

function WeaponController:_canUnequip(): boolean --replace later with inventory checking instead of putting it in th e weapon module
	if self.blocking.Value then return false end
	if self.parrying.Value then return false end
	if self.attacking.Value then return false end
	if self.dodging.Value then return false end
	if self.stunned.Value then return false end
	if self.guardBroken.Value then return false end
	if self.comboLocked then return false end
	if self.hitArmed then return false end
	if self.curTrack then return false end
	return true
end

function WeaponController:_canAttackNow(): boolean
	if not self.bound or not self.tool then return false end
	if self:_isDisabled() then return false end
	if now() < self.feintAttackUnlockUntil then return false end
	if self.attacking.Value or self.blocking.Value or self.stunned.Value or self.comboLocked or self.guardBroken.Value then return false end
	if self.dodging.Value then return false end
	return true
end

function WeaponController:_canBlockNow(): boolean
	if not self.bound or not self.tool then return false end
	if self:_isDisabled() then return false end
	if self.guardBroken.Value then return false end
	if self.attacking.Value then return false end
	if self.dodging.Value then return false end
	if now() < self._blockCooldownUntil then return false end
	if not self.anims or not self.anims.block or self.blocking.Value then return false end
	return true
end
--buffering and parrying

function WeaponController:_bufferAttack()
	self._attackBufferedUntil = now() + self.attackBufferTime
end

function WeaponController:_bufferBlock()
	self._blockBufferedUntil = now() + self.blockBufferTime
end

function WeaponController:_tryConsumeBuffers()
	local t = now()
	if self._attackBufferedUntil > t and self:_canAttackNow() then
		self._attackBufferedUntil = 0
		self:doAttack()
		return
	end
	if self._blockHeld and self._blockBufferedUntil > t and self:_canBlockNow() then
		self._blockBufferedUntil = 0
		self:startBlock()
	end
end

function WeaponController:_parryTime(): number
	local pt = getNumberValue(self.values, "ParryTime")
	return math.max(0, pt or 0.2)
end

-- parry checking
function WeaponController:_beginParryWindow()
	if not self.blocking.Value then return end
	local t = now()
	if t < self._parryCooldownUntil then return end

	self.parryToken += 1
	local token = self.parryToken
	local pt = self:_parryTime()

	self._activeParryToken = token
	self._activeParryUntil = t + pt
	self.parrying.Value = true

	task.delay(pt, function()
		if token ~= self.parryToken then return end
		self.parrying.Value = false
		self._activeParryToken = -1
		self._activeParryUntil = 0
		if self._parryHitToken ~= token then
			self._parryCooldownUntil = now() + self._parryMissCd
		end
	end)
end

function WeaponController:_loadAnimIn(folder: Instance, name: string): AnimationTrack? 
	local a = folder:FindFirstChild(name)
	if not a or not a:IsA("Animation") then return nil end
	return self.animator:LoadAnimation(a)
end

function WeaponController:_buildParriedCache(toolName: string)
	self._parriedAnims = nil
	local folder = weaponsAnimRoot:FindFirstChild(toolName)
	if not folder then return end
	local parried = folder:FindFirstChild("Parried")
	if not parried or not parried:IsA("Folder") then return end

	local list = table.create(#parried:GetChildren())
	local n = 0
	for _, c in ipairs(parried:GetChildren()) do
		if c:IsA("Animation") then
			n += 1
			list[n] = c
		end
	end
	if n == 0 then return end
	self._parriedAnims = list
end

function WeaponController:_playParriedRandom() --random parried animation out of 1-2 animations in the folder, i plan on changing this to a cycling parry animation because one animation seems to play more often (for some reason)
	local list = self._parriedAnims
	if not list or not self.tool or not self.bound then return end
	local pick = list[math.random(1, #list)]
	if not pick then return end
	local t = self.animator:LoadAnimation(pick)
	t.Priority = Enum.AnimationPriority.Action4
	t.Looped = false
	self.extraTracks.Parried = t
	t:Play(0.05, 1, 1)
end

function WeaponController:loadAnims(toolName: string): AnimMap?
	local folder = weaponsAnimRoot:FindFirstChild(toolName)
	if not folder then return nil end

	local map: AnimMap = { m = {} }
	map.idle = self:_loadAnimIn(folder, "Idle")
	map.block = self:_loadAnimIn(folder, "Blocking")
	map.equip = self:_loadAnimIn(folder, "Equip")
	map.unequip = self:_loadAnimIn(folder, "Unequip")
	map.heavy = self:_loadAnimIn(folder, "Heavy")
	map.aerial = self:_loadAnimIn(folder, "Aerial")
	map.runningAttack = self:_loadAnimIn(folder, "RunningAttack")
	for i = 1, 4 do
		map.m[i] = self:_loadAnimIn(folder, tostring(i))
	end

	table.clear(self.hitAnims)
	if hitAnimRoot then
		for i = 1, 4 do
			self.hitAnims[i] = self:_loadAnimIn(hitAnimRoot, ("Hit%d"):format(i))
		end
	end

	table.clear(self.extraTracks)
	return map
end

function WeaponController:_playWeaponExtra(name: string)
	if not self.tool or not self.bound then return end
	local folder = weaponsAnimRoot:FindFirstChild(self.tool.Name)
	if not folder then return end
	local t = self:_loadAnimIn(folder, name)
	if not t then return end
	self.extraTracks[name] = t
	t:Play(0.05, 1, 1)
end

function WeaponController:_playHit(i: number)
	local t = self.hitAnims[i]
	if t then t:Play(0.05, 1, 1) end
end

function WeaponController:_unbindMarkers()
	for _, c in ipairs(self.markerConns) do
		c:Disconnect()
	end
	table.clear(self.markerConns)
end


--basically checking for the animation event "Hit" and then firing the hitbox so the server can make a hitbox with the parameters given
function WeaponController:_bindMarkers()
	self:_unbindMarkers()
	local anims = self.anims
	if not anims then return end

	local function canEmitHit(): boolean
		return self.bound
			and self.tool ~= nil
			and not self.stunned.Value
			and not self.guardBroken.Value
			and not self:_isDisabled()
	end

	for i = 1, 4 do
		local t = anims.m[i]
		if t then
			table.insert(self.markerConns, t:GetMarkerReachedSignal("Hit"):Connect(function()
				if not canEmitHit() then return end
				self.hitArmed = false
				playSfx(self.char, self.tool and self.tool.Name or "Default", "Swing")
				hitMarker:FireServer(self.tool, { kind = "light", index = i })
			end))
		end
	end

	if anims.heavy then
		table.insert(self.markerConns, anims.heavy:GetMarkerReachedSignal("Hit"):Connect(function()
			if not canEmitHit() then return end
			playSfx(self.char, self.tool and self.tool.Name or "Default", "Swing")
			hitMarker:FireServer(self.tool, { kind = "heavy" })
		end))
	end

	if anims.runningAttack then
		table.insert(self.markerConns, anims.runningAttack:GetMarkerReachedSignal("Hit"):Connect(function()
			if not canEmitHit() then return end
			self:_stopRunCarry()
			self.hitArmed = false
			playSfx(self.char, self.tool and self.tool.Name or "Default", "Swing")
			hitMarker:FireServer(self.tool, { kind = "running" })
		end))
	end
end

function WeaponController:_cacheTrailsForTool(tool: Tool?)
	self._trailList = nil
	if not tool then return end
	local trails = table.create(8)
	local n = 0
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("Trail") then
			n += 1
			trails[n] = d
		end
	end
	self._trailList = trails
end

function WeaponController:_setTrails(enabled: boolean)
	local trails = self._trailList
	if trails then
		for i = 1, #trails do
			local tr = trails[i]
			if tr then tr.Enabled = enabled end
		end
	end
	if fxReq then
		fxReq:FireServer(enabled and "ToolTrailsOn" or "ToolTrailsOff", self.char)
	end
end

function WeaponController:_stopWeaponTracks()
	local anims = self.anims
	if anims then
		if anims.idle then anims.idle:Stop(0.05) end
		if anims.block then anims.block:Stop(0.05) end
		if anims.equip then anims.equip:Stop(0.05) end
		if anims.unequip then anims.unequip:Stop(0.05) end
		if anims.heavy then anims.heavy:Stop(0.05) end
		if anims.aerial then anims.aerial:Stop(0.05) end
		if anims.runningAttack then anims.runningAttack:Stop(0.05) end
		for i = 1, 4 do
			local t = anims.m[i]
			if t then t:Stop(0.05) end
		end
	end
	for i = 1, 4 do
		local t = self.hitAnims[i]
		if t then t:Stop(0.05) end
	end
	for _, t in pairs(self.extraTracks) do
		t:Stop(0.05)
	end
	table.clear(self.extraTracks)
end

function WeaponController:stopAll()
	local anims = self.anims
	if not anims then return end
	if anims.idle then anims.idle:Stop(0.1) end
	if anims.block then anims.block:Stop(0.1) end
	if anims.heavy then anims.heavy:Stop(0.1) end
	if anims.aerial then anims.aerial:Stop(0.1) end
	if anims.runningAttack then anims.runningAttack:Stop(0.1) end
	for i = 1, 4 do
		local t = anims.m[i]
		if t then t:Stop(0.05) end
	end
end

function WeaponController:_stopRunCarry()
	if self._runCarryConn then self._runCarryConn:Disconnect() end
	if self._runCarryLV then self._runCarryLV:Destroy() end
	if self._runCarryAtt then self._runCarryAtt:Destroy() end
	self._runCarryConn = nil
	self._runCarryLV = nil
	self._runCarryAtt = nil
end
--running attacks, you run + attack
function WeaponController:_startRunCarry()
	self:_stopRunCarry()
	local hrp = self.char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local mag = 0
	local a = self.tool and self.tool:GetAttribute("RunningAttackSpeed")
	if typeof(a) == "number" and a > 0 then
		mag = a
	else
		local nv = getNumberValue(self.values, "RunningAttackSpeed")
		if nv and nv > 0 then mag = nv end
	end
	if mag < 1 then
		local v = hrp.AssemblyLinearVelocity
		local planar = Vector3.new(v.X, 0, v.Z)
		mag = math.max(self.hum.WalkSpeed, planar.Magnitude)
	end

	local look = hrp.CFrame.LookVector
	local dir = Vector3.new(look.X, 0, look.Z)
	if dir.Magnitude < 0.01 then return end
	dir = dir.Unit

	local att = Instance.new("Attachment")
	att.Name = "RunCarryAtt"
	att.Parent = hrp

	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 1e5
	lv.VectorVelocity = dir * mag
	lv.Parent = hrp

	self._runCarryAtt = att
	self._runCarryLV = lv

	self._runCarryConn = RunService.Heartbeat:Connect(function()
		local cur = self._runCarryLV
		if not cur or not hrp.Parent then return end
		local lk = hrp.CFrame.LookVector
		local d2 = Vector3.new(lk.X, 0, lk.Z)
		if d2.Magnitude < 0.01 then return end
		cur.VectorVelocity = d2.Unit * mag
	end)
end

function WeaponController:_applySpeed()
	local mul = self:_speedMul()
	local ws: number

	if self:_isDisabled() or self.stunned.Value then
		ws = 2
	elseif self.attacking.Value then
		ws = 6
	elseif self.blocking.Value then
		ws = 4
	elseif self.guardBroken.Value then
		ws = 0
	else
		if self.hum:GetAttribute("IsRunning") then return end
		ws = self.origWalk
	end

	self.hum.WalkSpeed = ws * mul
end

function WeaponController:_bindStateSpeed()
	self._connect(self.attacking:GetPropertyChangedSignal("Value"), function() self:_applySpeed() end)
	self._connect(self.blocking:GetPropertyChangedSignal("Value"), function() self:_applySpeed() end)
	self._connect(self.stunned:GetPropertyChangedSignal("Value"), function() self:_applySpeed() end)
	self._connect(self.guardBroken:GetPropertyChangedSignal("Value"), function() self:_applySpeed() end)
end

function WeaponController:_bindStunWatcher()
	self._connect(self.stunned:GetPropertyChangedSignal("Value"), function()
		if self.stunned.Value then
			self:cancelAttack()
			self:_setTrails(false)
			if fxReq then fxReq:FireServer("ToolTrailsOff", self.char) end
			self:stopAll()
		else
			self:playIdle()
			self:_tryConsumeBuffers()
		end
	end)
end

function WeaponController:_bindReactions()
	self._connect(reaction.OnClientEvent, function(kind: string, param: number?)
		if kind == "Parry" then
			self._parryHitToken = self.parryToken
			self:_playWeaponExtra("Parry")
			SFX.play(self.char, self.tool and self.tool.Name or "Default", "Parry")
			if self.blocking.Value then
				blockState:FireServer("Begin")
				self:_beginParryWindow()
			end
		elseif kind == "Parried" then
			self:_playParriedRandom()
		elseif kind == "GuardBreak" then
			if self.blocking.Value then self:stopBlock() end
			self:cancelAttack()
			self:stopAll()
			if guardBreakAnim and guardBreakAnim:IsA("Animation") then
				local t = self.animator:LoadAnimation(guardBreakAnim)
				t.Priority = Enum.AnimationPriority.Action4
				t.Looped = false
				t:Play(0.05, 1, 1)
			end
		elseif kind == "BlockHit" then
			self:_playWeaponExtra("BlockHit")
			SFX.play(self.char, self.tool and self.tool.Name or "Default", "Blocked")
		elseif kind == "Hit" then
			self:_playHit(math.clamp(param or 1, 1, 4))
		end
	end)

	self._connect(fx.OnClientEvent, function(name: string, target: Instance?, extra: any)
		VFX.play(name, target or self.char, extra)
	end)

	self._connect(sfx.OnClientEvent, function(name: string, weapon: string?, target: Instance?)
		SFX.play(target or self.char, weapon or (self.tool and self.tool.Name or "Default"), name)
	end)
end

function WeaponController:cancelAttack()
	self.attacking.Value = false
	self.hitArmed = false
	self.curTrack = nil
	self:stopAll()
	self:_stopRunCarry()
	self:_setTrails(false)
	self:_applySpeed()
	self:_tryConsumeBuffers()
end

function WeaponController:playIdle()
	if self.blocking.Value or self.attacking.Value or self.stunned.Value or self.guardBroken.Value or self:_isDisabled() then return end
	local anims = self.anims
	if anims and anims.idle and not anims.idle.IsPlaying then
		anims.idle:Play(0.1, 1, 1)
		self:_setTrails(false)
	end
	self:_applySpeed()
	self:_tryConsumeBuffers()
end

function WeaponController:startBlock()
	if not self:_canBlockNow() then return end
	self.blocking.Value = true
	self:stopAll()
	local b = self.anims and self.anims.block
	if not b then return end
	b.Looped = true
	b:Play(0.05, 1, 1)
	blockState:FireServer("Begin")
	self:_applySpeed()
	self:_beginParryWindow()
end

function WeaponController:stopBlock()
	if not self.blocking.Value then
		self._blockBufferedUntil = 0
		self:_tryConsumeBuffers()
		return
	end

	local active = self._activeParryToken
	if active ~= -1 and self._parryHitToken ~= active then
		self._parryCooldownUntil = now() + self._parryMissCd
	end

	self.blocking.Value = false
	self.parryToken += 1
	self.parrying.Value = false
	self._activeParryToken = -1
	self._activeParryUntil = 0
	self._blockCooldownUntil = now() + 0.1

	local b = self.anims and self.anims.block
	if b then b:Stop(0.05) end
	blockState:FireServer("End")

	self:playIdle()
	self:_tryConsumeBuffers()
end

function WeaponController:_attackTrack(i: number): AnimationTrack?
	local anims = self.anims
	return anims and anims.m[i] or nil
end

function WeaponController:_postSwing(bookend: boolean)
	self.lastAttackAt = now()
	self._comboResetToken += 1
	local token = self._comboResetToken

	task.delay(self.comboResetDelay, function()
		if token ~= self._comboResetToken then return end
		if now() - self.lastAttackAt >= self.comboResetDelay then
			self.comboIndex = 1
		end
	end)

	if bookend then
		self.comboLocked = true
		task.delay(self.postComboCooldown, function()
			self.comboLocked = false
			self:_tryConsumeBuffers()
		end)
	end
end

function WeaponController:_aerialPush()
	local hrp = self.char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local cam = workspace.CurrentCamera
	local look = (cam and cam.CFrame.LookVector) or hrp.CFrame.LookVector
	local planar = Vector3.new(look.X, 0, look.Z)
	if planar.Magnitude < 0.01 then
		local f = hrp.CFrame.LookVector
		planar = Vector3.new(f.X, 0, f.Z)
	end
	planar = planar.Unit

	local fMagAny = self.tool and self.tool:GetAttribute("AerialPushForward")
	local dMagAny = self.tool and self.tool:GetAttribute("AerialPushDown")
	local fMag = (typeof(fMagAny) == "number" and fMagAny) or 55
	local dMag = (typeof(dMagAny) == "number" and dMagAny) or 20

	local v = hrp.AssemblyLinearVelocity
	hrp.AssemblyLinearVelocity = Vector3.new(planar.X * fMag, v.Y - dMag, planar.Z * fMag)
end

function WeaponController:doAerial(): boolean
	if not self.bound or not self.tool then return false end
	if self:_isDisabled() then return false end
	if now() < self.aerialCooldownUntil then return false end
	if not self.anims or not self.anims.aerial then return false end
	if self.attacking.Value or self.blocking.Value or self.stunned.Value or self.guardBroken.Value then return false end
	if self.dodging.Value then return false end

	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)
	self:_aerialPush()

	local track = self.anims.aerial
	track.Looped = false

	local hitCon = track:GetMarkerReachedSignal("Hit"):Connect(function()
		if not self.bound or not self.tool or self.stunned.Value or self.guardBroken.Value or self:_isDisabled() then return end
		playSfx(self.char, self.tool and self.tool.Name or "Default", "Swing")
		hitMarker:FireServer(self.tool, { kind = "aerial" })
	end)

	track:Play(0.05, 1, 1)

	local stopCon: RBXScriptConnection?
	stopCon = track.Stopped:Connect(function()
		hitCon:Disconnect()
		if stopCon then stopCon:Disconnect() end
		self.attacking.Value = false
		self:_setTrails(false)
		self.aerialCooldownUntil = now() + 2
		self:playIdle()
		self:_tryConsumeBuffers()
	end)

	return true
end

function WeaponController:tryFeint()
	if not self.bound or not self.tool then return end
	if self:_isDisabled() then return end
	if now() < self.feintLockUntil then return end
	if not self.attacking.Value then return end
	if not self.hitArmed then return end

	self.attacking.Value = false
	self.hitArmed = false
	if self.curTrack and self.curTrack.IsPlaying then self.curTrack:Stop(0.05) end
	self.curTrack = nil
	self:_stopRunCarry()
	self:_setTrails(false)

	self.comboLocked = true
	local t = now()
	self.feintLockUntil = t + 1
	self.feintAttackUnlockUntil = t + 0.3

	playSfx(self.char, self.tool and self.tool.Name or "Default", "Feint")

	task.delay(0.3, function()
		self.comboLocked = false
		self:_tryConsumeBuffers()
	end)

	self:playIdle()
end

function WeaponController:doRunningAttack()
	local anims = self.anims
	if not anims or not anims.runningAttack then return end
	if self.hum.FloorMaterial == Enum.Material.Air then return end

	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)

	self.curTrack = anims.runningAttack
	self.hitArmed = true
	self:_startRunCarry()

	local hitOnce = self.curTrack:GetMarkerReachedSignal("Hit"):Connect(function()
		self.hitArmed = false
	end)

	self.curTrack.Looped = false
	self.curTrack:Play(0.05, 1, 1)

	local stopCon: RBXScriptConnection?
	stopCon = self.curTrack.Stopped:Connect(function()
		if stopCon then stopCon:Disconnect() end
		hitOnce:Disconnect()
		self:_stopRunCarry()
		self.curTrack = nil
		self.hitArmed = false
		self.attacking.Value = false
		self:_setTrails(false)
		self.comboIndex = 1
		self:_postSwing(false)
		self:playIdle()
		self:_tryConsumeBuffers()
	end)
end

function WeaponController:doAttack()
	if not self:_canAttackNow() then
		self:_bufferAttack()
		return
	end

	local state = self.hum:GetState()
	local airborne = self.hum.FloorMaterial == Enum.Material.Air
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping

	if airborne and now() - self.lastJumpAt <= 0.5 and self.anims and self.anims.aerial then
		if self:doAerial() then return end
	end

	local running = (not airborne)
		and self.hum:GetAttribute("IsRunning") == true
		and self.hum:GetAttribute("Sliding") ~= true

	if running and self.anims and self.anims.runningAttack then
		self:doRunningAttack()
		return
	end

	local track = self:_attackTrack(self.comboIndex)
	if not track then return end

	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)

	self.curTrack = track
	self.hitArmed = true

	local hitOnce = track:GetMarkerReachedSignal("Hit"):Connect(function()
		self.hitArmed = false
	end)

	track.Looped = false
	track:Play(0.05, 1, 1)

	local stopCon: RBXScriptConnection?
	stopCon = track.Stopped:Connect(function()
		if stopCon then stopCon:Disconnect() end
		hitOnce:Disconnect()

		self.curTrack = nil
		self.hitArmed = false
		self.attacking.Value = false
		self:_setTrails(false)

		self.comboIndex += 1
		if self.comboIndex > 4 then self.comboIndex = 1 end
		self:_postSwing(self.comboIndex == 1)

		self:playIdle()
		self:_tryConsumeBuffers()
	end)
end

function WeaponController:doHeavy()
	if not self.bound or not self.tool then return end
	if self:_isDisabled() then return end
	if self.attacking.Value or self.blocking.Value or self.stunned.Value or self.guardBroken.Value then return end
	if self.dodging.Value then return end
	if not self.anims or not self.anims.heavy then return end
	if now() < (self.critCdUntil or 0) then return end

	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)

	playSfx(self.char, self.tool.Name, "Heavy")
	if fxReq then fxReq:FireServer("CriticalCue", self.char) end

	local track = self.anims.heavy
	track.Looped = false
	track:Play(0.05, 1, 1)

	local stopCon: RBXScriptConnection?
	stopCon = track.Stopped:Connect(function()
		if stopCon then stopCon:Disconnect() end
		self.attacking.Value = false
		self:_setTrails(false)

		local cdAttr = self.tool and self.tool:GetAttribute("CriticalCooldown")
		local cd = (typeof(cdAttr) == "number" and cdAttr) or 1.5
		self.critCdUntil = now() + math.max(0, cd)

		self:playIdle()
		self:_tryConsumeBuffers()
	end)
end

function WeaponController:bindTool(tool: Tool)
	if self.bound then self:unbind() end

	self.tool = tool
	self.anims = self:loadAnims(tool.Name)
	self.comboIndex = 1
	self.bound = true

	self:_cacheTrailsForTool(tool)
	self:_buildParriedCache(tool.Name)
	self:_bindMarkers()

	if self.anims and self.anims.equip then
		self:stopAll()
		self.anims.equip.Looped = false
		self.anims.equip:Play(0.05, 1, 1)
		playSfx(self.char, tool.Name, "Equip")
		Holster.hide(self.char)
	end

	self:playIdle()

	table.insert(self.conns, tool.Unequipped:Connect(function()
		if not self:_canUnequip() then
			if tool.Parent ~= self.char then tool.Parent = self.char end
			return
		end
		self:onUnequip()
	end))

	table.insert(self.conns, tool.Activated:Connect(function()
		if self:_canAttackNow() then
			self:doAttack()
		else
			self:_bufferAttack()
		end
	end))

	local function handleBlock(_: string, s: Enum.UserInputState, _: InputObject?)
		if not self.bound or not self.tool then return Enum.ContextActionResult.Pass end
		if s == Enum.UserInputState.Begin then
			self._blockHeld = true
			if self:_canBlockNow() then self:startBlock() else self:_bufferBlock() end
			return Enum.ContextActionResult.Sink
		end
		if s == Enum.UserInputState.End then
			self._blockHeld = false
			self._blockBufferedUntil = 0
			self:stopBlock()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	local function handleHeavy(_: string, s: Enum.UserInputState, _: InputObject?)
		if s ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
		self:doHeavy()
		return Enum.ContextActionResult.Sink
	end

	local function handleFeint(_: string, state: Enum.UserInputState, input: InputObject?)
		if state == Enum.UserInputState.Begin then
			self._rmbDownAt = now()
			self._rmbMoved = false
			return Enum.ContextActionResult.Pass
		elseif state == Enum.UserInputState.Change and input and input.UserInputType == Enum.UserInputType.MouseMovement then
			if input.Delta.Magnitude > 2 then self._rmbMoved = true end
			return Enum.ContextActionResult.Pass
		elseif state == Enum.UserInputState.End then
			if not self._rmbMoved and now() - self._rmbDownAt <= 0.2 then
				self:tryFeint()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end
		return Enum.ContextActionResult.Pass
	end

	CAS:BindActionAtPriority("ParryBlockF", handleBlock, false, self.inputPriority, Enum.KeyCode.F)
	CAS:BindActionAtPriority("HeavyR", handleHeavy, false, self.inputPriority, Enum.KeyCode.R)
	CAS:BindActionAtPriority("FeintRC", handleFeint, false, math.max(0, self.inputPriority - 100), Enum.UserInputType.MouseButton2)
end

function WeaponController:onUnequip()
	if not self.tool then return end
	if not self:_canUnequip() then return end

	local wv = self.values and self.values:FindFirstChild("CurrentWeapon")
	local wn = (wv and wv:IsA("StringValue") and wv.Value) or self.tool.Name

	playSfx(self.char, wn, "Unequip")

	self.blocking.Value = false
	self.attacking.Value = false
	self.parrying.Value = false
	self._activeParryToken = -1
	self._activeParryUntil = 0
	self.hitArmed = false
	self.curTrack = nil

	self:_stopRunCarry()
	self:_setTrails(false)

	local t = self.anims and self.anims.unequip
	if t then
		Holster.showTemp(self.char, wn)
		t.Looped = false
		t:Play(0.05, 1, 1)
		local idle = self.anims and self.anims.idle
		if idle then idle:Stop(0.05) end

		local stopCon: RBXScriptConnection?
		stopCon = t.Stopped:Connect(function()
			if stopCon then stopCon:Disconnect() end
			self:_stopWeaponTracks()
			Holster.hideTemp(self.char)
			Holster.show(self.char, wn)
			Holster.rebind(self.char)
			self:unbind()
		end)
	else
		self:_stopWeaponTracks()
		Holster.show(self.char, wn)
		Holster.rebind(self.char)
		self:unbind()
	end
end

function WeaponController:unbind()
	if not self.bound then return end

	self:_unbindMarkers()
	CAS:UnbindAction("ParryBlockF")
	CAS:UnbindAction("HeavyR")
	CAS:UnbindAction("FeintRC")

	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	table.clear(self.conns)

	self:_stopWeaponTracks()
	self:_stopRunCarry()

	self.tool = nil
	self.anims = nil
	self.bound = false

	self._trailList = nil
	self._parriedAnims = nil

	self:_applySpeed()
end

function WeaponController.autoWire(player: Player)
	local controller = WeaponController.new(player, {})
	local function tryBind(tool: Tool)
		if not CollectionService:HasTag(tool, "Weapon") then return end
		if tool.Parent == controller.char then controller:bindTool(tool) end
		tool.Equipped:Connect(function()
			controller:bindTool(tool)
		end)
	end
	for _, t in ipairs(controller.char:GetChildren()) do
		if t:IsA("Tool") then tryBind(t) end
	end
	controller.char.ChildAdded:Connect(function(i)
		if i:IsA("Tool") then tryBind(i) end
	end)
	return controller
end

return WeaponController
