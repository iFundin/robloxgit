type AnimMap = {
	idle: AnimationTrack?,
	block: AnimationTrack?,
	equip: AnimationTrack?,
	unequip: AnimationTrack?,
	heavy: AnimationTrack?,
	aerial: AnimationTrack?,
	runningAttack: AnimationTrack?,
	m: {AnimationTrack?}
}
type WeaponControllerConfig = {inputPriority: number?}

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CAS = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Holster = require(RS:WaitForChild("Modules"):WaitForChild("Holster"))

local remotes = RS:WaitForChild("Remotes")
local hitMarker = remotes:WaitForChild("HitMarker")
local reaction = remotes:WaitForChild("Reaction")
local blockState = remotes:WaitForChild("BlockState")
local fx = remotes:WaitForChild("Fx")
local sfx = remotes:WaitForChild("Sfx")
local fxReq = remotes:WaitForChild("FxReq")
local sfxReq = remotes:FindFirstChild("SfxReq")

local VFX = require(RS:WaitForChild("Modules"):WaitForChild("VFX"))
local SFX = require(RS:WaitForChild("Modules"):WaitForChild("SFX"))

local WeaponController = {}
WeaponController.__index = WeaponController

local function attr(m: Instance, n: string): any
	return m and m:GetAttribute(n)
end

local function playSfxV2(char: Instance, toolName: string?, name: string)
	local w = toolName or "Default"
	SFX.play(char, w, name)
	if sfxReq then sfxReq:FireServer(w, name, char) end
end

function WeaponController.new(player: Player, config: WeaponControllerConfig?)
	local self = setmetatable({}, WeaponController)
	self.player = player
	self.char = player.Character or player.CharacterAdded:Wait()
	self.hum = self.char:WaitForChild("Humanoid") :: Humanoid
	self.animator = self.hum:WaitForChild("Animator") :: Animator
	self.states = self.char:FindFirstChild("States")
	self.attacking = (self.states:FindFirstChild("Attacking") :: BoolValue)
	self.blocking = (self.states:FindFirstChild("Blocking") :: BoolValue)
	self.stunned = (self.states:FindFirstChild("Stunned") :: BoolValue)
	self.parrying = (self.states:FindFirstChild("Parrying") :: BoolValue)
	self.guardBroken = (self.states:FindFirstChild("GuardBroken") :: BoolValue)
	self.dodging = (self.states:FindFirstChild("Dodging") :: BoolValue)
	self.values = self.char:FindFirstChild("Values")
	self.bound = false
	self.tool = nil
	self.anims = nil :: AnimMap?
	self.hitAnims = {}
	self.extraTracks = {}
	self.comboIndex = 1
	self.inputPriority = if config and config.inputPriority then config.inputPriority else 200
	self.conns = {}
	self.markerConns = {}
	self.lastAttackAt = 0
	self.comboResetDelay = 2
	self._comboResetToken = 0
	self.critCdUntil = 0
	self.postComboCooldown = 0.5
	self.comboLocked = false
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
	self.curTrack = nil
	self._rmbDownAt = 0
	self._rmbMoved = false
	self._runCarryLV = nil :: LinearVelocity?
	self._runCarryAtt = nil :: Attachment?

	local v = self.values
	if v then
		local o = v:FindFirstChild("OriginalWalkSpeed") :: NumberValue?
		if o and o:IsA("NumberValue") and typeof(o.Value) == "number" then self.origWalk = o.Value end
		local ss = v:FindFirstChild("SlowSpeed") :: NumberValue?
		if ss and ss:IsA("NumberValue") and typeof(ss.Value) == "number" then self.slowSpeed = ss.Value end
		local sm = v:FindFirstChild("SpeedMultiplier") :: NumberValue?
		if sm and sm:IsA("NumberValue") and typeof(sm.Value) == "number" then self.speedMultiplier = sm.Value end

		if o and o:IsA("NumberValue") then
			o:GetPropertyChangedSignal("Value"):Connect(function()
				if typeof(o.Value) == "number" then self.origWalk = o.Value end
				self:_applySpeed()
			end)
		end
		if sm and sm:IsA("NumberValue") then
			sm:GetPropertyChangedSignal("Value"):Connect(function()
				if typeof(sm.Value) == "number" then self.speedMultiplier = sm.Value end
				self:_applySpeed()
			end)
		end
	end

	self:_bindStateSpeed()
	self:_bindStunWatcher()
	self:_bindReactions()

	self.hum.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			self.lastJumpAt = os.clock()
		end
	end)

	local function hookAttr(n: string)
		self.char:GetAttributeChangedSignal(n):Connect(function()
			if self:_isDisabled() then
				self:cancelAttack()
				self.blocking.Value = false
				self.parrying.Value = false
				self:stopAll()
				if fxReq then fxReq:FireServer("ToolTrailsOff", self.char) end
			end
			self:_applySpeed()
			self:_tryConsumeBuffers()
		end)
	end

	hookAttr("IsCarried")
	hookAttr("IsCarrying")
	hookAttr("IsGripping")
	hookAttr("IsBeingGripped")

	local rt = self.char:FindFirstChild("RagdollTrigger")
	if rt and rt:IsA("BoolValue") then
		rt.Changed:Connect(function()
			if self:_isDisabled() then
				self:cancelAttack()
				self.blocking.Value = false
				self.parrying.Value = false
				self:stopAll()
				if fxReq then fxReq:FireServer("ToolTrailsOff", self.char) end
			end
			self:_applySpeed()
			self:_tryConsumeBuffers()
		end)
	end

	local wv = self.values and self.values:FindFirstChild("CurrentWeapon")
	local wn = (wv and wv:IsA("StringValue") and wv.Value) or ""
	if wn ~= "" then Holster.onSpawn(self.char, wn) end

	self.player.CharacterAppearanceLoaded:Connect(function(c)
		if c == self.char then Holster.rebind(self.char) end
	end)

	return self
end

function WeaponController:_speedMul(): number
	local m = self.speedMultiplier
	if typeof(m) ~= "number" or m <= 0 then return 1 end
	return m
end

function WeaponController:_canUnequip(): boolean
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

function WeaponController:_isDisabled(): boolean
	if not self.char or not self.char.Parent then return true end
	if attr(self.char,"IsCarried") == true then return true end
	if attr(self.char,"IsCarrying") == true then return true end
	if attr(self.char,"IsGripping") == true then return true end
	if attr(self.char,"IsBeingGripped") == true then return true end
	local rt = self.char:FindFirstChild("RagdollTrigger")
	if rt and rt:IsA("BoolValue") and rt.Value then return true end
	return false
end

function WeaponController:_canAttackNow(): boolean
	if not self.bound or not self.tool then return false end
	if self:_isDisabled() then return false end
	if os.clock() < self.feintAttackUnlockUntil then return false end
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
	if os.clock() < self._blockCooldownUntil then return false end
	if not self.anims or not self.anims.block or self.blocking.Value then return false end
	return true
end

function WeaponController:_bufferAttack()
	self._attackBufferedUntil = os.clock() + self.attackBufferTime
end

function WeaponController:_bufferBlock()
	self._blockBufferedUntil = os.clock() + self.blockBufferTime
end

function WeaponController:_tryConsumeBuffers()
	local now = os.clock()
	if self._attackBufferedUntil > now and self:_canAttackNow() then
		self._attackBufferedUntil = 0
		self:doAttack()
		return
	end
	if self._blockHeld and self._blockBufferedUntil > now and self:_canBlockNow() then
		self._blockBufferedUntil = 0
		self:startBlock()
	end
end

function WeaponController:_beginParryWindow()
	if not self.blocking.Value then return end
	local now = os.clock()
	if now < self._parryCooldownUntil then return end
	self.parryToken += 1
	local token = self.parryToken
	local pt = self:_parryTime()
	self._activeParryToken = token
	self._activeParryUntil = now + pt
	self.parrying.Value = true
	task.delay(pt, function()
		if token ~= self.parryToken then return end
		self.parrying.Value = false
		self._activeParryToken = -1
		self._activeParryUntil = 0
		if self._parryHitToken ~= token then
			self._parryCooldownUntil = os.clock() + self._parryMissCd
		end
	end)
end

function WeaponController:_playParriedRandom()
	if not self.tool or not self.bound then return end
	local folder = RS:WaitForChild("Animations"):WaitForChild("Weapons"):FindFirstChild(self.tool.Name)
	if not folder then return end
	local parried = folder:FindFirstChild("Parried")
	if not parried or not parried:IsA("Folder") then return end
	local list = {}
	for _, c in ipairs(parried:GetChildren()) do
		if c:IsA("Animation") then table.insert(list, c) end
	end
	if #list == 0 then return end
	local pick = list[math.random(1, #list)]
	local t = self.animator:LoadAnimation(pick)
	t.Priority = Enum.AnimationPriority.Action4
	t.Looped = false
	self.extraTracks["Parried"] = t
	t:Play(0.05,1,1)
end

function WeaponController:_bindReactions()
	reaction.OnClientEvent:Connect(function(kind: string, param: number?)
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
			local a = RS:WaitForChild("Animations"):FindFirstChild("GuardBreak")
			if a and a:IsA("Animation") then
				local t = self.animator:LoadAnimation(a)
				t.Priority = Enum.AnimationPriority.Action4
				t.Looped = false
				t:Play(0.05,1,1)
			end
		elseif kind == "BlockHit" then
			self:_playWeaponExtra("BlockHit")
			SFX.play(self.char, self.tool and self.tool.Name or "Default", "Blocked")
		elseif kind == "Hit" then
			self:_playHit(math.clamp(param or 1,1,4))
		end
	end)

	fx.OnClientEvent:Connect(function(name: string, target: Instance?, extra: any)
		VFX.play(name, target or self.char, extra)
	end)

	sfx.OnClientEvent:Connect(function(name: string, weapon: string?, target: Instance?)
		SFX.play(target or self.char, weapon or (self.tool and self.tool.Name or "Default"), name)
	end)
end

function WeaponController:_applySpeed()
	local mul = self:_speedMul()
	local ws
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
	self.attacking:GetPropertyChangedSignal("Value"):Connect(function() self:_applySpeed() end)
	self.blocking:GetPropertyChangedSignal("Value"):Connect(function() self:_applySpeed() end)
	self.stunned:GetPropertyChangedSignal("Value"):Connect(function() self:_applySpeed() end)
	self.guardBroken:GetPropertyChangedSignal("Value"):Connect(function() self:_applySpeed() end)
end

function WeaponController:_bindStunWatcher()
	self.stunned:GetPropertyChangedSignal("Value"):Connect(function()
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

function WeaponController:_loadAnimIn(folder: Instance, name: string): AnimationTrack?
	local a = folder:FindFirstChild(name)
	if not a or not a:IsA("Animation") then return nil end
	return self.animator:LoadAnimation(a)
end

function WeaponController:loadAnims(toolName: string): AnimMap?
	local root = RS:WaitForChild("Animations")
	local wroot = root:WaitForChild("Weapons")
	local folder = wroot:FindFirstChild(toolName)
	if not folder then return nil end
	local map: AnimMap = {m = {}}
	map.idle = self:_loadAnimIn(folder,"Idle")
	map.block = self:_loadAnimIn(folder,"Blocking")
	map.equip = self:_loadAnimIn(folder,"Equip")
	map.unequip = self:_loadAnimIn(folder,"Unequip")
	map.heavy = self:_loadAnimIn(folder,"Heavy")
	map.aerial = self:_loadAnimIn(folder,"Aerial")
	map.runningAttack = self:_loadAnimIn(folder,"RunningAttack")
	for i = 1,4 do map.m[i] = self:_loadAnimIn(folder,tostring(i)) end
	self.hitAnims = {}
	local hfolder = root:FindFirstChild("Hit")
	if hfolder then
		for i = 1,4 do self.hitAnims[i] = self:_loadAnimIn(hfolder,("Hit%d"):format(i)) end
	end
	self.extraTracks = {}
	return map
end

function WeaponController:_playWeaponExtra(name: string)
	if not self.tool or not self.anims or not self.bound then return end
	local folder = RS:WaitForChild("Animations"):WaitForChild("Weapons"):FindFirstChild(self.tool.Name)
	if not folder then return end
	local t = self:_loadAnimIn(folder,name)
	if t then
		self.extraTracks[name] = t
		t:Play(0.05,1,1)
	end
end

function WeaponController:_playHit(i: number)
	local t = self.hitAnims[i]
	if t then t:Play(0.05,1,1) end
end

function WeaponController:_unbindMarkers()
	for _, c in ipairs(self.markerConns) do if c then c:Disconnect() end end
	self.markerConns = {}
end

function WeaponController:_bindMarkers()
	self:_unbindMarkers()
	if not self.anims then return end

	for i = 1, 4 do
		local t = self.anims.m[i]
		if t then
			table.insert(self.markerConns, t:GetMarkerReachedSignal("Hit"):Connect(function()
				if not self.bound or not self.tool or self.stunned.Value or self.guardBroken.Value or self:_isDisabled() then return end
				self.hitArmed = false
				playSfxV2(self.char, self.tool and self.tool.Name or "Default", "Swing")
				hitMarker:FireServer(self.tool, {kind = "light", index = i})
			end))
		end
	end

	if self.anims.heavy then
		table.insert(self.markerConns, self.anims.heavy:GetMarkerReachedSignal("Hit"):Connect(function()
			if not self.bound or not self.tool or self.stunned.Value or self.guardBroken.Value or self:_isDisabled() then return end
			playSfxV2(self.char, self.tool and self.tool.Name or "Default", "Swing")
			hitMarker:FireServer(self.tool, {kind = "heavy"})
		end))
	end

	if self.anims.runningAttack then
		table.insert(self.markerConns, self.anims.runningAttack:GetMarkerReachedSignal("Hit"):Connect(function()
			if not self.bound or not self.tool or self.stunned.Value or self.guardBroken.Value or self:_isDisabled() then return end
			self:_stopRunCarry()
			self.hitArmed = false
			playSfxV2(self.char, self.tool and self.tool.Name or "Default", "Swing")
			hitMarker:FireServer(self.tool, {kind = "running"})
		end))
	end
end

function WeaponController:_setTrails(enabled: boolean)
	if not self.tool then return end
	for _, d in ipairs(self.tool:GetDescendants()) do
		if d:IsA("Trail") then d.Enabled = enabled end
	end
	if fxReq then
		if enabled then fxReq:FireServer("ToolTrailsOn", self.char) else fxReq:FireServer("ToolTrailsOff", self.char) end
	end
end

function WeaponController:_stopWeaponTracks()
	if self.anims then
		if self.anims.idle then self.anims.idle:Stop(0.05) end
		if self.anims.block then self.anims.block:Stop(0.05) end
		if self.anims.equip then self.anims.equip:Stop(0.05) end
		if self.anims.unequip then self.anims.unequip:Stop(0.05) end
		if self.anims.heavy then self.anims.heavy:Stop(0.05) end
		if self.anims.aerial then self.anims.aerial:Stop(0.05) end
		if self.anims.runningAttack then self.anims.runningAttack:Stop(0.05) end
		for i = 1,4 do local t = self.anims.m[i]; if t then t:Stop(0.05) end end
	end
	for i = 1,4 do local t = self.hitAnims[i]; if t then t:Stop(0.05) end end
	for _, t in pairs(self.extraTracks) do if t then t:Stop(0.05) end end
	self.extraTracks = {}
end

function WeaponController:stopAll()
	if not self.anims then return end
	if self.anims.idle then self.anims.idle:Stop(0.1) end
	if self.anims.block then self.anims.block:Stop(0.1) end
	if self.anims.heavy then self.anims.heavy:Stop(0.1) end
	if self.anims.aerial then self.anims.aerial:Stop(0.1) end
	if self.anims.runningAttack then self.anims.runningAttack:Stop(0.1) end
	for i = 1,4 do local t = self.anims.m[i]; if t then t:Stop(0.05) end end
end

function WeaponController:_stopRunCarry()
	if self._runCarryConn then self._runCarryConn:Disconnect() end
	if self._runCarryLV then self._runCarryLV:Destroy() end
	if self._runCarryAtt then self._runCarryAtt:Destroy() end
	self._runCarryConn = nil
	self._runCarryLV = nil
	self._runCarryAtt = nil
end

function WeaponController:_startRunCarry()
	self:_stopRunCarry()
	local hrp = self.char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local v = hrp.AssemblyLinearVelocity
	local planarVel = Vector3.new(v.X, 0, v.Z)
	local planarMag = planarVel.Magnitude

	local mag = planarMag
	local a = self.tool and self.tool:GetAttribute("RunningAttackSpeed")
	if typeof(a) == "number" and a > 0 then
		mag = a
	else
		local nv = self.values and (self.values:FindFirstChild("RunningAttackSpeed") :: NumberValue?)
		if nv and nv:IsA("NumberValue") then
			local nvv = nv.Value
			if typeof(nvv) == "number" and nvv > 0 then
				mag = nvv
			end
		end
	end

	if typeof(mag) ~= "number" or mag < 1 then
		mag = math.max(self.hum.WalkSpeed, planarMag)
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
		if not self._runCarryLV or not hrp.Parent then return end
		local lk = hrp.CFrame.LookVector
		local d2 = Vector3.new(lk.X, 0, lk.Z)
		if d2.Magnitude < 0.01 then return end
		self._runCarryLV.VectorVelocity = d2.Unit * mag
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
	if self.anims and self.anims.idle and not self.anims.idle.IsPlaying then
		self.anims.idle:Play(0.1,1,1)
		self:_setTrails(false)
	end
	self:_applySpeed()
	self:_tryConsumeBuffers()
end

function WeaponController:_parryTime(): number
	local pt = 0.2
	if self.values then
		local nv = self.values:FindFirstChild("ParryTime")
		if nv and nv:IsA("NumberValue") then pt = math.max(0,nv.Value) end
	end
	return pt
end

function WeaponController:startBlock()
	if not self:_canBlockNow() then return end
	self.blocking.Value = true
	self:stopAll()
	self.anims.block.Looped = true
	self.anims.block:Play(0.05,1,1)
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
		self._parryCooldownUntil = os.clock() + self._parryMissCd
	end
	self.blocking.Value = false
	self.parryToken += 1
	self.parrying.Value = false
	self._activeParryToken = -1
	self._activeParryUntil = 0
	self._blockCooldownUntil = os.clock() + 0.1
	if self.anims and self.anims.block then self.anims.block:Stop(0.05) end
	blockState:FireServer("End")
	self:playIdle()
	self:_tryConsumeBuffers()
end

function WeaponController:_attackTrack(i: number): AnimationTrack?
	if not self.anims then return nil end
	return self.anims.m[i]
end

function WeaponController:_postSwing(bookend: boolean)
	self.lastAttackAt = os.clock()
	self._comboResetToken += 1
	local token = self._comboResetToken
	task.delay(self.comboResetDelay, function()
		if token ~= self._comboResetToken then return end
		if os.clock() - self.lastAttackAt >= self.comboResetDelay then
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
	local hrp = self.char:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hrp then return end
	for _, d in ipairs(hrp:GetChildren()) do
		if d:IsA("LinearVelocity") then d:Destroy() end 
	end
	local cam = workspace.CurrentCamera
	local look = cam and cam.CFrame.LookVector or hrp.CFrame.LookVector
	local planar = Vector3.new(look.X, 0, look.Z)
	if planar.Magnitude < 0.01 then
		local f = hrp.CFrame.LookVector
		planar = Vector3.new(f.X,0,f.Z)
	end
	planar = planar.Unit
	local fMag = (self.tool and typeof(self.tool:GetAttribute("AerialPushForward"))=="number") and self.tool:GetAttribute("AerialPushForward") or 55
	local dMag = (self.tool and typeof(self.tool:GetAttribute("AerialPushDown"))=="number") and self.tool:GetAttribute("AerialPushDown") or 20
	local v = hrp.AssemblyLinearVelocity
	hrp.AssemblyLinearVelocity = Vector3.new(planar.X * fMag, v.Y - dMag, planar.Z * fMag)
end

function WeaponController:doAerial(): boolean
	if not self.bound or not self.tool then return false end
	if self:_isDisabled() then return false end
	if os.clock() < self.aerialCooldownUntil then return false end
	if not self.anims or not self.anims.aerial then return false end
	if self.attacking.Value or self.blocking.Value or self.stunned.Value or self.guardBroken.Value then return false end
	if self.dodging.Value then return false end
	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)
	self:_aerialPush()
	self.anims.aerial.Looped = false
	local hitCon = self.anims.aerial:GetMarkerReachedSignal("Hit"):Connect(function()
		if not self.bound or not self.tool or self.stunned.Value or self.guardBroken.Value or self:_isDisabled() then return end
		playSfxV2(self.char, self.tool and self.tool.Name or "Default", "Swing")
		hitMarker:FireServer(self.tool, {kind = "aerial"})
	end)
	self.anims.aerial:Play(0.05,1,1)
	local s
	s = self.anims.aerial.Stopped:Connect(function()
		if hitCon then hitCon:Disconnect() end
		if s then s:Disconnect() end
		self.attacking.Value = false
		self:_setTrails(false)
		self.aerialCooldownUntil = os.clock() + 2
		self:playIdle()
		self:_tryConsumeBuffers()
	end)
	return true
end

function WeaponController:tryFeint()
	if not self.bound or not self.tool then return end
	if self:_isDisabled() then return end
	if os.clock() < self.feintLockUntil then return end
	if not self.attacking.Value then return end
	if not self.hitArmed then return end
	self.attacking.Value = false
	self.hitArmed = false
	if self.curTrack and self.curTrack.IsPlaying then self.curTrack:Stop(0.05) end
	self.curTrack = nil
	self:_stopRunCarry()
	self:_setTrails(false)
	self.comboLocked = true
	local now = os.clock()
	self.feintLockUntil = now + 1
	self.feintAttackUnlockUntil = now + 0.3
	playSfxV2(self.char, self.tool and self.tool.Name or "Default", "Feint")
	task.delay(0.3, function()
		self.comboLocked = false
		self:_tryConsumeBuffers()
	end)
	self:playIdle()
end

function WeaponController:doRunningAttack()
	if not self.anims or not self.anims.runningAttack then return end
	if self.hum.FloorMaterial == Enum.Material.Air then return end
	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)
	self.curTrack = self.anims.runningAttack
	self.hitArmed = true
	self:_startRunCarry()
	local hitOnce = self.curTrack:GetMarkerReachedSignal("Hit"):Connect(function()
		self.hitArmed = false
	end)
	self.curTrack.Looped = false
	self.curTrack:Play(0.05,1,1)
	local c
	c = self.curTrack.Stopped:Connect(function()
		if c then c:Disconnect() end
		if hitOnce then hitOnce:Disconnect() end
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
	if not self.bound or not self.tool then return end
	if self:_isDisabled() then return end
	if os.clock() < self.feintAttackUnlockUntil then return end
	if self.attacking.Value or self.blocking.Value or self.stunned.Value or self.comboLocked or self.guardBroken.Value then return end
	if self.dodging.Value then return end

	local state = self.hum:GetState()
	local airborne = self.hum.FloorMaterial == Enum.Material.Air
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping

	if airborne and os.clock() - self.lastJumpAt <= 0.5 and self.anims and self.anims.aerial then
		if self:doAerial() then return end
	end

	local running = not airborne and self.hum:GetAttribute("IsRunning") == true and self.hum:GetAttribute("Sliding") ~= true
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
	local hitOnce = track:GetMarkerReachedSignal("Hit"):Connect(function() self.hitArmed = false end)
	track.Looped = false
	track:Play(0.05,1,1)
	local c
	c = track.Stopped:Connect(function()
		if c then c:Disconnect() end
		if hitOnce then hitOnce:Disconnect() end
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
	if os.clock() < (self.critCdUntil or 0) then return end
	self.attacking.Value = true
	self:stopAll()
	self:_setTrails(true)
	playSfxV2(self.char, self.tool and self.tool.Name or "Default", "Heavy")
	if fxReq then fxReq:FireServer("CriticalCue", self.char) end
	self.anims.heavy.Looped = false
	self.anims.heavy:Play(0.05,1,1)
	local c
	c = self.anims.heavy.Stopped:Connect(function()
		if c then c:Disconnect() end
		self.attacking.Value = false
		self:_setTrails(false)
		local cdAttr = self.tool and self.tool:GetAttribute("CriticalCooldown")
		local cd = typeof(cdAttr) == "number" and cdAttr or 1.5
		self.critCdUntil = os.clock() + math.max(0, cd)
		self:playIdle()
		self:_tryConsumeBuffers()
	end)
end

function WeaponController:bindTool(tool: Tool)
	if self.bound then self:unbind() end
	self.tool = tool
	self.anims = self:loadAnims(tool.Name)
	self.comboIndex = 1
	if self.anims and self.anims.equip then
		self:stopAll()
		self.anims.equip.Looped = false
		self.anims.equip:Play(0.05,1,1)
		playSfxV2(self.char, tool.Name, "Equip")
		Holster.hide(self.char)
	end
	self:_bindMarkers()
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
			if self:_canBlockNow() then
				self:startBlock()
			else
				self:_bufferBlock()
			end
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
			self._rmbDownAt = os.clock()
			self._rmbMoved = false
			return Enum.ContextActionResult.Pass
		elseif state == Enum.UserInputState.Change and input and input.UserInputType == Enum.UserInputType.MouseMovement then
			if input.Delta.Magnitude > 2 then self._rmbMoved = true end
			return Enum.ContextActionResult.Pass
		elseif state == Enum.UserInputState.End then
			if not self._rmbMoved and os.clock() - self._rmbDownAt <= 0.2 then
				self:tryFeint()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end
		return Enum.ContextActionResult.Pass
	end

	CAS:BindActionAtPriority("ParryBlockF", handleBlock, false, self.inputPriority, Enum.KeyCode.F)
	CAS:BindActionAtPriority("HeavyR", handleHeavy, false, self.inputPriority, Enum.KeyCode.R)
	CAS:BindActionAtPriority("FeintRC", handleFeint, false, math.max(0, (self.inputPriority or 200) - 100), Enum.UserInputType.MouseButton2)

	self.bound = true
end

function WeaponController:onUnequip()
	if not self.tool then return end
	if not self:_canUnequip() then return end
	local wv = self.values and self.values:FindFirstChild("CurrentWeapon")
	local wn = (wv and wv:IsA("StringValue") and wv.Value) or (self.tool and self.tool.Name) or nil
	playSfxV2(self.char, wn or "Default", "Unequip")
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
		if wn then Holster.showTemp(self.char, wn) end
		t.Looped = false
		t:Play(0.05,1,1)
		if self.anims.idle then self.anims.idle:Stop(0.05) end
		local c
		c = t.Stopped:Connect(function()
			if c then c:Disconnect() end
			self:_stopWeaponTracks()
			Holster.hideTemp(self.char)
			if wn then Holster.show(self.char, wn) end
			Holster.rebind(self.char)
			self:unbind()
		end)
	else
		self:_stopWeaponTracks()
		if wn then Holster.show(self.char, wn) end
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
	for _, c in ipairs(self.conns) do if c then c:Disconnect() end end
	self.conns = {}
	self:_stopWeaponTracks()
	self:_stopRunCarry()
	self.tool = nil
	self.anims = nil
	self.bound = false
	self:_applySpeed()
end

function WeaponController.autoWire(player: Player)
	local controller = WeaponController.new(player,{})
	local function tryBind(tool: Tool)
		if not CollectionService:HasTag(tool, "Weapon") then return end
		if tool.Parent == controller.char then controller:bindTool(tool) end
		tool.Equipped:Connect(function() controller:bindTool(tool) end)
	end
	for _, t in ipairs(controller.char:GetChildren()) do if t:IsA("Tool") then tryBind(t) end end
	controller.char.ChildAdded:Connect(function(i) if i:IsA("Tool") then tryBind(i) end end)
	return controller
end

return WeaponController
