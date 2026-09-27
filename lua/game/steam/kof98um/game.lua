local ffi = require("ffi")
local ffiutil = require("ffiutil")
local luautil = require("luautil")
local winerror = require("winerror")
local winutil = require("winutil")
local winprocess = require("winprocess")
local window = require("window")
local hotkey = require("hotkey")
local colors = require("render.colors")
local types = require("game.steam.kof98um.types")
local boxtypes = require("game.steam.kof98um.boxtypes")
local BoxSet = require("game.boxset")
local BoxList = require("game.boxlist")
local KOF_Common = require("game.kof_common")
local KOF98 = KOF_Common:new({ whoami = "KOF98" })

KOF98.configSection = "kof98umfe"
KOF98.basicWidth = 320
KOF98.basicHeight = 224
KOF98.aspectMode = "pillarbox"
KOF98.recommendResolution = "640x448"
KOF98.absoluteYOffset = 16
KOF98.pivotSize = 5
KOF98.boxPivotSize = 2
KOF98.drawStaleThrowBoxes = false
KOF98.drawThrowableBoxes = true
KOF98.useThickLines = true
KOF98.boxesPerLayer = 20
-- game-specific constants
KOF98.boxtypes = boxtypes
KOF98.revisions = {
	["Steam"] = {
		-- The current Steam x86 executable stores the live player blocks here.
		playerPtrs = { 0x016CDF40, 0x016CE140 },
		playerExtraPtrs = { 0x016D6540, 0x016D674C },
		cameraPtr = 0x0180C938,
		projectilesListInfo = { start = 0x01703000, count = 51, step = 0x200 },
	},
	["GOG.com"] = {
		playerPtrs = { 0x01759700, 0x01759900 },
		playerExtraPtrs = { 0x0175DD00, 0x0175DF0C },
		cameraPtr = 0x0176DC78,
		projectilesListInfo = { start = 0x0174F700, count = 29, step = 0x200 },
	},
}

KOF98.drawRangeMarkers = { false, false }
KOF98.rangeMarkerHotkeys = { hotkey.VK_F1, hotkey.VK_F2 }
KOF98.gauges = { {}, {} }
KOF98.drawGauges = true -- "false" here overrides the two values below
KOF98.drawStunGauge = true -- also applies to the stun recovery gauge
KOF98.drawGuardGauge = true
KOF98.stunGaugeColor = colors.rgb(0xFF, 0xB0, 0x90)
KOF98.stunRecoveryGaugeColor = colors.RED
KOF98.guardGaugeColor = colors.rgb(0xA0, 0xC0, 0xE0)

KOF98.toggleHotkeys = {
	{ hotkey.VK_F3, "drawBoxFills", "drawing hitbox fills" },
	{ hotkey.VK_F4, "drawBoxPivot", "drawing hitbox center axes" },
	{ hotkey.VK_F5, "drawThrowableBoxes", "drawing \"throwable\" boxes" },
	{ hotkey.VK_F6, "drawStaleThrowBoxes", "drawing \"stale\" throw boxes" },
	{ hotkey.VK_F7, "drawGauges", "drawing gauge overlays" },
	{ hotkey.VK_F8, "drawInputDisplay", "drawing keyboard input display" },
	{ hotkey.VK_F9, "logInputTransitions", "logging keyboard input changes" },
}

KOF98.drawInputDisplay = true
KOF98.logInputTransitions = false
KOF98.inputHistoryLength = 12

KOF98.startupMessage = [[
Hotkeys available for this game:
F1 - Toggle close normal range marker (player 1)
F2 - Toggle close normal range marker (player 2)
F3 - Toggle drawing hitbox fills
F4 - Toggle drawing hitbox center axes
F5 - Toggle drawing "throwable"-type boxes
F6 - Toggle drawing "stale" throw boxes
F7 - Toggle gauge overlays
F8 - Toggle keyboard input display
F9 - Toggle keyboard input diagnostics in this console]]

-- Each player keyboard block stores ten little-endian DirectInput scan codes:
-- up/down/left/right, start/select, then LP/SP/LK/SK. Display order is A/B/C/D,
-- which maps to LP/LK/SP/SK, so the two middle attack slots are swapped below.
local inputPresetOffsets = { 0x0C, 0x8C }
local inputBindingSlots = { 0, 1, 2, 3, 6, 7, 8, 9 }

local function readInputPreset(path)
	local file, err = io.open(path, "rb")
	if not file then return nil, err end
	local data = file:read("*a")
	file:close()
	local function scanCodeAt(offset)
		if offset + 4 > #data then return nil end
		local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
		local scanCode = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
		if scanCode == 0 or scanCode > 0xFF then return nil end
		local vk = hotkey.fromScanCode(scanCode)
		if vk == 0 then return nil end
		return vk
	end
	local bindings = {}
	for player = 1, 2 do
		local base = inputPresetOffsets[player]
		local keys = {}
		for _, slot in ipairs(inputBindingSlots) do
			keys[slot] = scanCodeAt(base + slot * 4)
		end
		bindings[player] = {
			up = keys[0], down = keys[1], left = keys[2], right = keys[3],
			buttons = { keys[6], keys[8], keys[7], keys[9] },
		}
	end
	local mappedKeys = 0
	for player = 1, 2 do
		local binding = bindings[player]
		for _, key in pairs({ binding.up, binding.down, binding.left,
			binding.right, binding.buttons[1], binding.buttons[2],
			binding.buttons[3], binding.buttons[4] }) do
			if key then mappedKeys = mappedKeys + 1 end
		end
	end
	if mappedKeys == 0 then return nil, "No direction or attack keys are assigned." end
	return bindings
end

function KOF98:loadKeyboardInputPreset()
	local exePath = window.getProcessImageName(self.gameHandle)
	local gameDirectory = exePath:match("^(.*)[\\/]")
	if not gameDirectory then
		io.write("Could not locate the KOF98 game folder; keyboard input display is unavailable.\n")
		return
	end
	local path = gameDirectory .. "\\Data\\~options.bin"
	local bindings, err = readInputPreset(path)
	if not bindings then
		io.write("Could not load keyboard preset from Data\\~options.bin: ",
			tostring(err), "\n")
		return
	end
	self.inputBindings = bindings
	io.write("Loaded keyboard preset from Data\\~options.bin for both players.\n")
end

function KOF98:extraInit(noExport)
	if not noExport then
		types:export(ffi)
		self:importRevisionSpecificOptions(true)
	end
	self.boxset = BoxSet:new(self.boxtypes.order, self.boxesPerLayer,
		self.boxSlotConstructor, self.boxtypes)
	self.camera = ffi.new("camera")
	self.players = ffiutil.ntypes("player", 2, 1)
	self.playerExtras = ffiutil.ntypes("playerExtra", 2, 1)
	self.pivots = BoxList:new( -- dual purposing BoxList to draw pivots
		"pivots", self.projectilesListInfo.count + 2,
		self.pivotSlotConstructor)
	self.projBuffer = ffi.new("projectile")
	self.inputHistory = { {}, {} }
	self.lastInputState = { nil, nil }
	self.lastInputTime = { nil, nil }
	self.inputCaptureActive = false
	self:loadKeyboardInputPreset()

	luautil.ifNotEmpty(self.startupMessage)
	for which = 1, 2 do
		self:printRangeMarkerState(which, true)
	end
	self:setupGauges()
end

function KOF98:setupGauges()
	local g, a = self.gauges, self.gaugeFillAlpha
	g[1].stun = self:Gauge({
		x = 10, y = 51, width = 130, height = 5, direction = "left",
		fillColor = self.stunGaugeColor,
		minValue = 0, maxValue = 0x77,
	})
	-- stun and stun recovery gauges overlap (since we never draw both)
	g[1].stunRecovery = self:Gauge(luautil.extend({}, g[1].stun, {
		fillColor = self.stunRecoveryGaugeColor,
		maxValue = 0xF0,
	}))
	-- guard gauge appears right below the stun/stun recovery gauge
	g[1].guard = self:Gauge(luautil.extend({}, g[1].stun, {
		fillColor = self.guardGaugeColor,
		maxValue = 0x77, y = (g[1].stun.y + g[1].stun.height),
	}))
	-- copy the "mirror image" of player 1's gauges to the player 2 side
	for key, gauge in pairs(g[1]) do
		g[2][key] = self:Gauge(luautil.extend({}, gauge, {
			x = gauge.x + 169, direction = "right",
		}))
	end
end

function KOF98:capturePlayerState(which)
	local player = self.players[which]
	self:read(self.playerPtrs[which], player)
	local extraAddress = player.kof98_extra
	if extraAddress == 0 then extraAddress = self.playerExtraPtrs[which] end
	self:read(extraAddress, self.playerExtras[which])
	self:captureEntity(player, false)
end

function KOF98:captureProjectiles()
	local info, current = self.projectilesListInfo, self.projBuffer
	local pointer, step = info.start, info.step
	local minAddress, maxAddress = pointer
	for i = 1, info.count do
		maxAddress = pointer
		self:read(pointer, current)
		if current.basicStatus > 0 then
			self:captureEntity(current, true)
		end
		pointer = pointer + step
	end
	--print(string.format("Read from range 0x%08X to 0x%08X", minAddress, maxAddress))
end

function KOF98:captureState()
	self.boxset:reset()
	self.pivots:reset()
	self:read(self.cameraPtr, self.camera)
	for i = 1, 2 do 
		if self.playersEnabled[i] then
			self:capturePlayerState(i)
		end
	end
	if self.projectilesEnabled then
		self:captureProjectiles()
	end
end

-- return -1 if player is facing left, or +1 if player is facing right
function KOF98:facingMultiplier(player)
	return ((player.facing == 0) and 1) or -1
end

function KOF98:rangeMarkerMultiplier(player)
	return self:facingMultiplier(player) * -1
end

function KOF98:getPlayerPosition(player)
	return player.screenX, player.screenY
end

-- translate a hitbox's position into coordinates suitable for drawing
function KOF98:deriveBoxPosition(player, hitbox, facing)
	local playerX, playerY = self:getPlayerPosition(player)
	local centerX, centerY = hitbox.x, hitbox.y
	centerX = playerX + (centerX * facing) -- positive offsets move forward
	centerY = playerY + centerY -- positive offsets move downward
	local w, h = hitbox.width, hitbox.height
	return centerX, centerY, w, h
end

function KOF98:throwableBoxIsActive(player, hitbox)
	if not self.drawThrowableBoxes then return false
	elseif bit.band(player.statusFlags2nd[3], 0x20) ~= 0 then return false
	elseif bit.band(player.statusFlags[2], 0x03) == 1 then return false
	elseif player.throwableStatus ~= 0 then return false
	else return bit.band(hitbox.boxID, 0x80) == 0 end
end

function KOF98:captureEntity(target, isProjectile, facing)
	pivotColor = (pivotColor or colors.WHITE)
	facing = (facing or self:facingMultiplier(target))
	local pivotX, pivotY = target.screenX, target.screenY
	local boxstate = target.statusFlags[0]
	local bt, boxtype, boxesDrawn, i = self.boxtypes, "dummy", 0, 0
	local boxset, boxAdder, hitbox = self.boxset, self.addBox, nil
	-- attack/vulnerable boxes
	while boxstate ~= 0 and i <= 3 do
		if bit.band(boxstate, 1) ~= 0 then
			hitbox = target.hitboxes[i]
			boxtype = bt:typeForID(hitbox.boxID)
			if i == 1 and boxtype == "attack" then
				goto continue -- don't draw "ghost boxes" in '02UM
			end
			if isProjectile then
				boxtype = bt:asProjectile(boxtype)
			end
			if boxtype == "dummy" then
				--print(string.format("Dummy box at 0x%02X", hitbox.boxID))
			end
			boxset:add(boxtype, boxAdder, self, self:deriveBoxPosition(
				target, hitbox, facing))
			boxesDrawn = boxesDrawn + 1
			::continue::
		end
		boxstate = bit.rshift(boxstate, 1)
		i = i + 1
	end
	if not isProjectile then
		-- collision box
		hitbox = target.collisionBox
		if hitbox.boxID ~= 0xFF then
			boxset:add("collision", boxAdder, self, self:deriveBoxPosition(
				target, hitbox, facing))
		end
		-- "throw" box
		hitbox = target.throwBox
		if self.drawStaleThrowBoxes or (hitbox.boxID ~= 0) then
			--print(string.format("Active throw box (ID=0x%02X)", hitbox.boxID))
			boxset:add("throw", boxAdder, self, self:deriveBoxPosition(
				target, hitbox, facing))
		end
		-- "throwable" box
		hitbox = target.throwableBox
		if self:throwableBoxIsActive(target, hitbox) then
			boxset:add("throwable", boxAdder, self, self:deriveBoxPosition(
				target, hitbox, facing))
		end
		self.pivots:add(self.addPivot, self.pivotColor, self:worldToScreen(
			target.screenX, target.screenY))
	-- don't draw pivot axis for projectile if it has no active hitboxes
	elseif boxesDrawn > 0 then
		self.pivots:add(self.addPivot, self.projectilePivotColor,
			self:worldToScreen(target.screenX, target.screenY))
	end
end

function KOF98:advanceRangeMarker(which)
	local r = self.drawRangeMarkers
	if r[which] == false then r[which] = 0
	elseif r[which] >= 3 then r[which] = false
	else r[which] = r[which] + 1 end
	self:printRangeMarkerState(which)
end

function KOF98:printRangeMarkerState(which, suppressIfDisabled)
	local showing = self.drawRangeMarkers[which]
	if showing then
		io.write(
			"Showing close standing ", self.buttonNames[showing + 1],
			" activation range for player ", which, ".\n")
	elseif not suppressIfDisabled then
		io.write(
			"Disabled close normal range marker for player ", which, ".\n")
	end
end

function KOF98:shouldShowStunRecoveryGauge(player)
	local stunMeterFrozen = bit.band(player.statusFlags2nd[0], 0x01) ~= 0
	local dizzyState = bit.band(player.statusFlags2nd[3], 0x10) ~= 0
	if not (dizzyState and stunMeterFrozen) then return false
	else return (player.hitstun > 0 and player.stunRecovery > 0) end
end

function KOF98:renderState()
	KOF_Common.renderState(self)
	local players = self.players
	local xDistance = math.abs(players[1].screenX - players[2].screenX)
	for which = 1, 2 do
		local p, px = players[which], self.playerExtras[which]
		local rangeIndex = self.drawRangeMarkers[which]
		if rangeIndex and (p.yPivot.value == 0) then
			-- subtract 1 since the marker line must actually be "behind"
			-- the opponent's pivot axis to register a close-range attack
			local range = px.closeRanges[rangeIndex] - 1
			self:drawRangeMarker(p, range, range >= xDistance)
		end

		if self.drawGauges then
			local gauges = self.gauges[which]
			if self.drawStunGauge then
				if self:shouldShowStunRecoveryGauge(p) then
					gauges.stunRecovery:render(p.stunRecovery)
				else
					gauges.stun:render(p.stunGauge)
				end
			end
			if self.drawGuardGauge then
				gauges.guard:render(p.guardGauge)
			end
		end
	end
	if self.inputBindings then
		self:updateInputState()
		if self.drawInputDisplay then self:renderInputDisplay() end
	end
end

local inputColors = {
	neutral = colors.rgb(0x60, 0x60, 0x60),
	direction = colors.rgb(0xE8, 0xE8, 0xE8),
	buttons = {
		colors.rgb(0x70, 0xD8, 0xFF), colors.rgb(0xFF, 0xD5, 0x60),
		colors.rgb(0xFF, 0x80, 0x80), colors.rgb(0xA0, 0xFF, 0x90),
	},
}

function KOF98:readKeyboardInput(which)
	local binding, pressed = self.inputBindings[which], hotkey.down
	local mask = 0
	if binding.up and pressed(binding.up) then mask = bit.bor(mask, 1) end
	if binding.down and pressed(binding.down) then mask = bit.bor(mask, 2) end
	if binding.left and pressed(binding.left) then mask = bit.bor(mask, 4) end
	if binding.right and pressed(binding.right) then mask = bit.bor(mask, 8) end
	for i = 1, 4 do
		local key = binding.buttons[i]
		if key and pressed(key) then
			mask = bit.bor(mask, bit.lshift(1, i + 3))
		end
	end
	return mask
end

function KOF98:renderInputGlyph(mask, x, y, size)
	local active = inputColors.direction
	local inactive = inputColors.neutral
	local function cell(cx, cy, bitMask, color)
		local c = bit.band(mask, bitMask) ~= 0 and color or inactive
		self:box(cx, cy, cx + size, cy + size, c, c)
	end
	-- A compact D-pad; positions themselves communicate direction.
	cell(x + size, y, 1, active)
	cell(x + size, y + size * 2, 2, active)
	cell(x, y + size, 4, active)
	cell(x + size * 2, y + size, 8, active)
	local bx = x + size * 4
	for i = 1, 4 do
		local c = bit.band(mask, bit.lshift(1, i + 3)) ~= 0
			and inputColors.buttons[i] or inactive
		self:box(bx + (i - 1) * (size + 2), y + size,
			bx + (i - 1) * (size + 2) + size, y + size * 2, c, c)
	end
end

function KOF98:describeInputState(mask, which)
	local names = {}
	local facingRight = self.players[which].facing == 0
	local inputStateNames = {
		{ 1, "up" }, { 2, "down" },
		{ 4, facingRight and "back" or "forward" },
		{ 8, facingRight and "forward" or "back" },
		{ 16, "A" }, { 32, "B" }, { 64, "C" }, { 128, "D" },
	}
	for _, entry in ipairs(inputStateNames) do
		if bit.band(mask, entry[1]) ~= 0 then
			table.insert(names, entry[2])
		end
	end
	return (#names > 0 and table.concat(names, "+")) or "released"
end

function KOF98:updateInputState()
	local history, length = self.inputHistory, self.inputHistoryLength
	local now = hotkey.ticks()
	-- GetAsyncKeyState is system-wide, so accept samples only while the game
	-- window is foreground. Require a neutral state after focus returns to avoid
	-- treating a key held in another application as a game input.
	if window.foreground() ~= self.gameHwnd then
		self.inputCaptureActive = false
		self.lastInputState[1], self.lastInputState[2] = nil, nil
		self.lastInputTime[1], self.lastInputTime[2] = nil, nil
		return
	end
	if not self.inputCaptureActive then
		local p1, p2 = self:readKeyboardInput(1), self:readKeyboardInput(2)
		if p1 ~= 0 or p2 ~= 0 then return end
		self.inputCaptureActive = true
		self.lastInputState[1], self.lastInputState[2] = 0, 0
		self.lastInputTime[1], self.lastInputTime[2] = now, now
		return
	end
	for which = 1, 2 do
		local mask = self:readKeyboardInput(which)
		local last = self.lastInputState[which]
		if last == nil or mask ~= last then
			local row = history[which]
			table.insert(row, 1, mask)
			if #row > length then table.remove(row) end
			if last ~= nil and self.logInputTransitions then
				local elapsed = now - self.lastInputTime[which]
				if elapsed < 0 then elapsed = elapsed + 0x100000000 end
				io.write(string.format("P%d input: %s (state changed after %d ms)\n",
					which, self:describeInputState(mask, which), elapsed))
			end
			self.lastInputState[which] = mask
			self.lastInputTime[which] = now
		end
	end
end

function KOF98:renderInputDisplay()
	local history = self.inputHistory
	for which = 1, 2 do
		local mask = self.lastInputState[which] or 0
		local x = (which == 1) and 8 or 264
		local y = 22
		self:renderInputGlyph(mask, x, y, 4)
		-- Each column is one recent input change; rows run up/down/left/right/A/B/C/D.
		for index, state in ipairs(history[which]) do
			local hx, hy = x + (index - 1) * 4, y + 15
			for row = 1, 8 do
				local keyMask = bit.lshift(1, row - 1)
				if bit.band(state, keyMask) ~= 0 then
					local color = (row <= 4) and inputColors.direction
						or inputColors.buttons[row - 4]
					self:box(hx, hy + row - 1, hx + 3, hy + row, color, color)
				end
			end
		end
	end
end

function KOF98:toggleState(target, consoleLine)
	local v = not self[target]
	io.write((v and "Enabled ") or "Disabled ", consoleLine, ".\n")
	self[target] = v
end

function KOF98:checkInputs()
	for i = 1, 2 do
		if hotkey.pressed(self.rangeMarkerHotkeys[i]) then
			self:advanceRangeMarker(i)
		end
	end
	for _, toggleKey in ipairs(self.toggleHotkeys) do
		if hotkey.pressed(toggleKey[1]) then
			self:toggleState(toggleKey[2], toggleKey[3])
		end
	end
end

return KOF98
