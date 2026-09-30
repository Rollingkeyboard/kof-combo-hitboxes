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
local roster = require("game.steam.kof98um.roster")
local kof98CommandPatterns = require("game.steam.kof98um.commands")
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
	{ hotkey.VK_F9, "logInputTransitions", "rhythm graph and input timing log" },
	{ hotkey.VK_F10, "commandCoachEnabled", "character command validation mode" },
}

KOF98.drawInputDisplay = true
KOF98.logInputTransitions = false
KOF98.commandCoachEnabled = false
KOF98.inputHistoryLength = 12
KOF98.inputTimelineLength = 72
KOF98.inputTimelinePeriodMs = 16
KOF98.shermieFeedbackDurationMs = 2000
KOF98.shermieMotionWindowMs = 1200
KOF98.shermieMotionStepWindowMs = 450
KOF98.rhythmGuideBeatMs = 70
KOF98.rhythmGuideToleranceMs = 45

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
F9 - Toggle rhythm graph and input timing log
F10 - Toggle character command validation mode]]

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
	self.inputFrames = { {}, {} }
	self.motionHistory = { {}, {} }
	self.commandFollowups = { nil, nil }
	self.commandLatch = { nil, nil }
	self.lastInputState = { nil, nil }
	self.lastInputTime = { nil, nil }
	self.lastInputFrameTime = nil
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
	if self.commandCoachEnabled then
		for i = 1, 2 do
			if self.playersEnabled[i] then self:loadCommandSet(i) end
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
		if self.commandCoachEnabled then self:renderCommandFeedback() end
	end
end

local inputColors = {
	neutral = colors.rgb(0x60, 0x60, 0x60),
	timeline = colors.rgb(0x38, 0x38, 0x38),
	positive = colors.rgb(0x50, 0xFF, 0x80),
	rhythmCue = colors.rgb(0xFF, 0xD5, 0x60),
	rhythmMiss = colors.rgb(0xFF, 0x80, 0x50),
	rhythmCursor = colors.rgb(0xFF, 0xFF, 0xFF),
	direction = colors.rgb(0xE8, 0xE8, 0xE8),
	buttons = {
		colors.rgb(0x70, 0xD8, 0xFF), colors.rgb(0xFF, 0xD5, 0x60),
		colors.rgb(0xFF, 0x80, 0x80), colors.rgb(0xA0, 0xFF, 0x90),
	},
}

local shermieMoveList = {
	"SHERMIE - KOF '98 UM command practice (normal Shermie)",
	"A=LP, B=LK, C=SP, D=SK; forward/back are relative to Shermie's facing.",
	"Coach checks P1 keyboard commands; it cannot verify move animation or range.",
	"Timing window: up to 450 ms between direction changes, 1200 ms total.",
	"P1 rhythm lane: back, down-back, down, down-forward, forward + B/D.",
	"Gold notes are targets; green input notes are on beat, orange notes are off beat.",
	"Throws (close; range cannot be checked from keyboard input):",
	"  Shermie Flash Original: back or forward + C (SP)",
	"  Front Flash: back or forward + D (SK)",
	"Command attack:",
	"  Shermie Stand: forward + B (LK)",
	"Special moves:",
	"  Shermie Spiral: HCF + A/C (LP/SP), close",
	"  Shermie Shoot: HCF + B/D (LK/SK)",
	"  Shermie Whip: QCB + A/C (LP/SP), close",
	"  Axle Spinning Kick: QCB + B/D (LK/SK)",
	"  Shermie Clutch: DP + B/D (LK/SK), anti-air target",
	"  Shermie Cute: QCF + B/D after Spiral, Whip, or Clutch",
	"Desperation moves (close):",
	"  Shermie Carnival: HCF, HCF + A/C (LP/SP)",
	"  Shermie Flash: HCB, HCB + A/C (LP/SP)",
}

local feedbackGlyphs = {
	[" "] = { "000", "000", "000", "000", "000" },
	A = { "010", "101", "111", "101", "101" }, B = { "110", "101", "110", "101", "110" },
	C = { "011", "100", "100", "100", "011" }, D = { "110", "101", "101", "101", "110" },
	E = { "111", "100", "110", "100", "111" }, F = { "111", "100", "110", "100", "100" },
	G = { "011", "100", "101", "101", "011" }, H = { "101", "101", "111", "101", "101" },
	I = { "111", "010", "010", "010", "111" }, J = { "001", "001", "001", "101", "010" },
	K = { "101", "101", "110", "101", "101" }, L = { "100", "100", "100", "100", "111" },
	M = { "101", "111", "111", "101", "101" }, N = { "101", "111", "111", "111", "101" },
	O = { "010", "101", "101", "101", "010" }, P = { "110", "101", "110", "100", "100" },
	Q = { "010", "101", "101", "111", "011" }, R = { "110", "101", "110", "101", "101" },
	S = { "011", "100", "010", "001", "110" }, T = { "111", "010", "010", "010", "010" },
	U = { "101", "101", "101", "101", "111" }, V = { "101", "101", "101", "101", "010" },
	W = { "101", "101", "111", "111", "101" }, X = { "101", "101", "010", "101", "101" },
	Y = { "101", "101", "010", "010", "010" }, Z = { "111", "001", "010", "100", "111" },
	["0"] = { "111", "101", "101", "101", "111" }, ["1"] = { "010", "110", "010", "010", "111" },
	["2"] = { "110", "001", "010", "100", "111" }, ["3"] = { "110", "001", "010", "001", "110" },
	["4"] = { "101", "101", "111", "001", "001" }, ["5"] = { "111", "100", "110", "001", "110" },
	["6"] = { "011", "100", "110", "101", "010" }, ["7"] = { "111", "001", "010", "010", "010" },
	["8"] = { "010", "101", "010", "101", "010" }, ["9"] = { "010", "101", "011", "001", "110" },
	[":"] = { "000", "010", "000", "010", "000" }, ["-"] = { "000", "000", "111", "000", "000" },
	["/"] = { "001", "001", "010", "100", "100" }, ["."] = { "000", "000", "000", "000", "010" },
	[","] = { "000", "000", "000", "010", "100" }, ["+"] = { "000", "010", "111", "010", "000" },
	["("] = { "001", "010", "010", "010", "001" }, [")"] = { "100", "010", "010", "010", "100" },
}

local ticksElapsed

local function feedbackName(name)
	name = (name or ""):gsub("%s*%([^)]*%)", "")
	name = name:upper():gsub("[^A-Z0-9: /%-%.]", ""):gsub("%s+", " ")
	return name
end

local function fitFeedbackLine(text, maxCharacters)
	if #text <= maxCharacters then return text end
	return text:sub(1, maxCharacters - 3) .. "..."
end

function KOF98:renderCommandFeedback()
	if not self.shermieFeedbackStart then return end
	local elapsed = ticksElapsed(hotkey.ticks(), self.shermieFeedbackStart)
	local remaining = self.shermieFeedbackDurationMs - elapsed
	if remaining <= 0 then return end

	local scale = 2
	local current = fitFeedbackLine(feedbackName(self.commandFeedbackName), 34)
	local lines = {
		"OK: " .. current,
		"INPUT: " .. (self.commandFeedbackInput or "BUTTON INPUT"),
	}
	if self.commandFeedbackNext and #self.commandFeedbackNext > 0 then
		local nextName = table.concat(self.commandFeedbackNext, " / ")
		local nextInput = table.concat(self.commandFeedbackNextInput or {}, " / ")
		table.insert(lines, "NEXT: " .. feedbackName(nextName))
		table.insert(lines, "NEXT INPUT: " .. (nextInput ~= "" and nextInput or "FOLLOW-UP"))
	else
		table.insert(lines, "NEXT: NO FOLLOW-UP DATA")
	end
	for index, text in ipairs(lines) do lines[index] = fitFeedbackLine(text, 72) end
	local longest = math.max(#lines[1], #lines[2])
	for index = 3, #lines do longest = math.max(longest, #lines[index]) end
	local textWidth = (longest * 4 - 1) * scale
	local x, y = math.floor((self.basicWidth - textWidth - 24) / 2), 78
	local width, height = textWidth + 24, 10 + #lines * 11
	local background = colors.rgba(5, 34, 18, 232)
	self:box(x, y, x + width, y + height, inputColors.positive, background)
	self:box(x + 2, y + 2, x + width - 2, y + 3,
		inputColors.positive, inputColors.positive)

	for lineIndex, text in ipairs(lines) do
		local textX = math.floor((self.basicWidth - (#text * 4 - 1) * scale) / 2)
		local textY = y + 5 + (lineIndex - 1) * 11
		for index = 1, #text do
			local glyph = feedbackGlyphs[text:sub(index, index)]
			if glyph then
				for row = 1, #glyph do
					for col = 1, #glyph[row] do
						if glyph[row]:sub(col, col) == "1" then
							local gx = textX + ((index - 1) * 4 + col - 1) * scale
							local gy = textY + (row - 1) * scale
							self:box(gx, gy, gx + scale, gy + scale,
								inputColors.positive, inputColors.positive)
						end
					end
				end
			end
		end
	end
end

local function printShermieMoveList()
	for _, line in ipairs(shermieMoveList) do io.write(line, "\n") end
end

local function directionName(mask)
	local direction = bit.band(mask, 0x0F)
	if direction == 0 then return nil end
	local names = {
		[1] = "up", [2] = "down", [4] = "back", [8] = "forward",
		[5] = "upback", [9] = "upforward", [6] = "downback",
		[10] = "downforward",
	}
	return names[direction]
end

local function recordMotionDirection(self, which, direction, now)
	if not direction then return end
	local history = self.motionHistory[which]
	local last = history[#history]
	local elapsed = last and (now - last.time) or 0
	if elapsed < 0 then elapsed = elapsed + 0x100000000 end
	if last and elapsed > self.shermieMotionStepWindowMs then
		for i = #history, 1, -1 do history[i] = nil end
	end
	table.insert(history, { name = direction, time = now })
	while #history > 20 do table.remove(history, 1) end
end

local function motionMatches(self, which, pattern, now)
	local history = self.motionHistory[which]
	if #history < #pattern then return false end
	local first = #history - #pattern + 1
	for i, direction in ipairs(pattern) do
		if history[first + i - 1].name ~= direction then return false end
	end
	local elapsed = now - history[#history].time
	if elapsed < 0 then elapsed = elapsed + 0x100000000 end
	local span = now - history[first].time
	if span < 0 then span = span + 0x100000000 end
	return elapsed <= self.shermieMotionStepWindowMs
		and span <= self.shermieMotionWindowMs
end

local hcf = { "back", "downback", "down", "downforward", "forward" }
local hcb = { "forward", "downforward", "down", "downback", "back" }
local qcb = { "down", "downback", "back" }
local qcf = { "down", "downforward", "forward" }
local dp = { "forward", "down", "downforward" }
local function doubled(pattern)
	local result = {}
	for _, direction in ipairs(pattern) do table.insert(result, direction) end
	for _, direction in ipairs(pattern) do table.insert(result, direction) end
	return result
end
local function joined(firstPattern, secondPattern)
	local result = {}
	for _, direction in ipairs(firstPattern) do table.insert(result, direction) end
	for _, direction in ipairs(secondPattern) do table.insert(result, direction) end
	return result
end

local shermieCommandPatterns = {
	{ name = "Shermie Carnival", motion = doubled(hcf), buttons = { 16, 64 }, close = true },
	{ name = "Shermie Flash (DM)", motion = doubled(hcb), buttons = { 16, 64 }, close = true },
	{ name = "Shermie Spiral", motion = hcf, buttons = { 16, 64 }, close = true,
		next = { "Shermie Cute" } },
	{ name = "Shermie Shoot", motion = hcf, buttons = { 32, 128 } },
	{ name = "Shermie Whip", motion = qcb, buttons = { 16, 64 }, close = true,
		next = { "Shermie Cute" } },
	{ name = "Axle Spinning Kick", motion = qcb, buttons = { 32, 128 } },
	{ name = "Shermie Clutch", motion = dp, buttons = { 32, 128 },
		next = { "Shermie Cute" } },
	{ name = "Shermie Cute", motion = qcf, buttons = { 32, 128 }, followupOnly = true },
}

-- Motion entries are relative to the player's facing. Follow-up links describe
-- the command tree, not a frame-perfect cancel window; the game guide does not
-- publish those timings. Character IDs come from roster.lua and the live player
-- block, so identical motions on different characters are not misidentified.
local kyoCommandPatterns = {
		{ name = "Hatsugane", motion = { "back" }, buttons = { 64 }, close = true },
		{ name = "Hatsugane", motion = { "forward" }, buttons = { 64 }, close = true },
		{ name = "Issetsu Seoi Nage", motion = { "back" }, buttons = { 128 }, close = true },
		{ name = "Issetsu Seoi Nage", motion = { "forward" }, buttons = { 128 }, close = true },
		{ name = "Geshiki: Goufu You", motion = { "forward" }, buttons = { 32 } },
		{ name = "88 Shiki", motion = { "downforward" }, buttons = { 128 } },
		{ name = "114 Shiki: Aragami (荒咬)", motion = qcf, buttons = { 16 },
			next = { "128 Shiki: Konokizu (九伤)" } },
		{ name = "128 Shiki: Konokizu (九伤)", motion = qcf, buttons = { 16, 64 },
			next = { "127 Shiki: Yanosabi (八锖)" }, followupOnly = true },
		{ name = "127 Shiki: Yanosabi (八锖)", motion = hcb, buttons = { 16, 64 },
			next = { "Geshiki: Migiri Ugachi (砌穿)" }, followupOnly = true },
		{ name = "127 Shiki: Yanosabi (八锖)", buttons = { 16, 64 },
			next = { "Geshiki: Migiri Ugachi (砌穿)" }, followupOnly = true },
		{ name = "Geshiki: Migiri Ugachi (砌穿)", buttons = { 16, 64 }, followupOnly = true },
		{ name = "125 Shiki: Nanase (七濑)", buttons = { 32, 128 }, followupOnly = true },
		{ name = "115 Shiki: Dokugami", motion = qcf, buttons = { 64 },
			next = { "401 Shiki: Tsumi Yomi", "402 Shiki: Batsu Yomi" } },
		{ name = "401 Shiki: Tsumi Yomi", motion = hcb, buttons = { 16, 64 },
			next = { "402 Shiki: Batsu Yomi" }, followupOnly = true },
		{ name = "402 Shiki: Batsu Yomi", motion = { "forward" }, buttons = { 16, 64 }, followupOnly = true },
		{ name = "100 Shiki: Oniyaki", motion = dp, buttons = { 16, 64 } },
		{ name = "212 Shiki: Kototsuki You", motion = hcb, buttons = { 32, 128 } },
		{ name = "Nue Tsumi", motion = qcb, buttons = { 16, 64 } },
		{ name = "Ura 108 Shiki: Orochi Nagi", motion = joined(qcb, hcf), buttons = { 16, 64 } },
		{ name = "Saishu Kessen Ougi: Mu Shiki", motion = doubled(qcf), buttons = { 16, 64 } },
}
kof98CommandPatterns.Kyo = kyoCommandPatterns
kof98CommandPatterns.Shermie = shermieCommandPatterns

function KOF98:loadCommandSet(which)
	local playerId = tonumber(self.players[which].currentCharID)
	local characterName = roster[playerId]
	local patterns = kof98CommandPatterns[characterName]
	self.loadedCommandSetByPlayer = self.loadedCommandSetByPlayer or {}
	if characterName and self.loadedCommandSetByPlayer[which] ~= characterName then
		if self.loadedCommandSetByPlayer[which] then
			self.motionHistory[which] = {}
			if self.commandFollowups then self.commandFollowups[which] = nil end
			if self.commandLatch then self.commandLatch[which] = nil end
		end
		self.loadedCommandSetByPlayer[which] = characterName
		if patterns then
			io.write(string.format("Loaded command set for P%d: %s (%d recognized inputs).\n",
				which, characterName, #patterns))
		else
			io.write("No command set is available yet for P", which, ": ", characterName, ".\n")
		end
	end
	return patterns, characterName
end

local function hasOneOfButtons(mask, buttons)
	for _, button in ipairs(buttons) do
		if bit.band(mask, button) ~= 0 then return true end
	end
	return false
end

ticksElapsed = function(now, thenTime)
	local elapsed = now - thenTime
	if elapsed < 0 then elapsed = elapsed + 0x100000000 end
	return elapsed
end

local shermieRhythmDirections = {
	"back", "downback", "down", "downforward", "forward",
}

local function timingColor(self, start, step, actualTime)
	local actualOffset = ticksElapsed(actualTime, start)
	local targetOffset = (step - 1) * self.rhythmGuideBeatMs
	if math.abs(actualOffset - targetOffset) <= self.rhythmGuideToleranceMs then
		return inputColors.positive
	end
	return inputColors.rhythmMiss
end

function KOF98:updateShermieRhythmGuide(which, mask, previousMask, now)
	if which ~= 1 then return end
	local characterName = roster[tonumber(self.players[which].currentCharID)]
	if characterName ~= "Shermie" then
		self.shermieRhythmGuide = nil
		return
	end
	local direction = directionName(mask)
	local previousDirection = directionName(previousMask or 0)
	local directionChanged = direction ~= nil and direction ~= previousDirection
	local buttons = bit.band(mask, 0xF0)
	local attackPressed = bit.band(buttons, 0xA0) ~= 0
		and bit.band(previousMask or 0, 0xA0) == 0
	local guide = self.shermieRhythmGuide

	if directionChanged and direction == "back" then
		local restart = not guide or guide.completed or guide.failed
			or guide.step == #shermieRhythmDirections
			or ticksElapsed(now, guide.lastHit) > self.shermieMotionStepWindowMs
		if restart then
			guide = { start = now, lastHit = now, lastDirection = direction,
				step = 1, notes = { {
					time = now, color = inputColors.positive,
				} } }
			self.shermieRhythmGuide = guide
		end
	end
	if not guide then return end

	if not guide.completed and not guide.failed
		and ticksElapsed(now, guide.lastHit) > self.shermieMotionStepWindowMs
		and not directionChanged then
		guide.failed = true
	end

	if directionChanged and direction ~= "back" and not guide.completed
		and not guide.failed then
		local nextStep = guide.step + 1
		if shermieRhythmDirections[nextStep] == direction then
			guide.step = nextStep
			guide.lastHit = now
			guide.lastDirection = direction
			guide.notes[nextStep] = {
				time = now,
				color = timingColor(self, guide.start, nextStep, now),
			}
			if nextStep == #shermieRhythmDirections then
				guide.forwardAt = now
			end
		else
			guide.failed = true
		end
	end

	if attackPressed and guide.step >= 4 then guide.attackPressedAt = now end
	if guide.step == #shermieRhythmDirections and direction == "forward"
		and bit.band(buttons, 0xA0) ~= 0 and not guide.completed then
		local attackTime = guide.attackPressedAt or now
		guide.notes[#shermieRhythmDirections] = {
			time = attackTime,
			color = timingColor(self, guide.start,
				#shermieRhythmDirections, attackTime),
		}
		guide.completed = true
	end
end

local function containsName(names, target)
	for _, name in ipairs(names or {}) do
		if name == target then return true end
	end
	return false
end

local function commandMotionMatches(self, which, pattern, direction, now)
	if #pattern == 1 then
		local history = self.motionHistory[which]
		local last = history[#history]
		return direction == pattern[1] and last and last.name == pattern[1]
	end
	return direction == pattern[#pattern]
		and motionMatches(self, which, pattern, now)
end

local feedbackDirections = {
	up = "UP", down = "DOWN", back = "BACK", forward = "FWD",
	downback = "DOWN-BACK", downforward = "DOWN-FWD",
	upback = "UP-BACK", upforward = "UP-FWD",
}

local feedbackButtons = {
	[16] = "A (LP)", [32] = "B (LK)",
	[64] = "C (SP)", [128] = "D (SK)",
}

local function commandInputNotation(move)
	local parts = {}
	for _, direction in ipairs(move.motion or {}) do
		table.insert(parts, feedbackDirections[direction] or direction:upper())
	end
	local buttons = {}
	for _, button in ipairs(move.buttons or {}) do
		table.insert(buttons, feedbackButtons[button] or "BUTTON")
	end
	local buttonText = table.concat(buttons, "/")
	if #parts == 0 then return buttonText end
	return table.concat(parts, ", ") .. " + " .. buttonText
end

function KOF98:checkCommandMove(which, mask, now)
	local direction = directionName(mask)
	local buttons = bit.band(mask, 0xF0)
	local patterns, characterName = self:loadCommandSet(which)
	if not direction or buttons == 0 then return end
	if not patterns then return end
	local byName = {}
	for _, move in ipairs(patterns) do
		byName[move.name] = byName[move.name] or {}
		table.insert(byName[move.name], move)
	end

	-- Check the active move's allowed branches first, so a follow-up that shares
	-- the same quarter-circle as a normal move is credited to the combo route.
	local chain = self.commandFollowups and self.commandFollowups[which]
	local selected
	local matchedFollowup = false
	if chain then
		if ticksElapsed(now, chain.time) <= 2000 then
			for _, name in ipairs(chain.names) do
				for _, move in ipairs(byName[name] or {}) do
					if move.followupOnly and hasOneOfButtons(buttons, move.buttons)
						and ((move.motion and commandMotionMatches(self, which,
							move.motion, direction, now))
							or (not move.motion and directionName(mask) ~= nil)) then
						selected = move
						matchedFollowup = true
						break
					end
				end
				if selected then break end
			end
		end
		if ticksElapsed(now, chain.time) > 2000 then
			self.commandFollowups[which] = nil
			chain = nil
		end
	end

	if not selected then
		-- Longest motion wins, preventing a super's final motion segment from
		-- also being reported as an ordinary special.
		local bestMotionLength = 0
		for _, move in ipairs(patterns) do
			if hasOneOfButtons(buttons, move.buttons)
				and move.motion
				and (not move.followupOnly or (chain
					and containsName(chain.names, move.name)))
				and #move.motion > bestMotionLength
				and commandMotionMatches(self, which, move.motion, direction, now) then
				selected = move
				bestMotionLength = #move.motion
			end
		end
	end
	if selected then
		self.commandLatch = self.commandLatch or {}
		if self.commandLatch[which] == selected.name then return end
		self.commandLatch[which] = selected.name
		self.commandFollowups = self.commandFollowups or {}
		if #(selected.next or {}) > 0 then
			self.commandFollowups[which] = { names = selected.next, time = now }
		else
			self.commandFollowups[which] = nil
		end
		self.shermieFeedbackStart = now
		self.shermieFeedbackName = selected.name
		self.commandFeedbackName = selected.name
		self.commandFeedbackNext = selected.next
		self.commandFeedbackInput = commandInputNotation(selected)
		self.commandFeedbackNextInput = {}
		for _, nextName in ipairs(selected.next or {}) do
			for _, nextMove in ipairs(byName[nextName] or {}) do
				local notation = commandInputNotation(nextMove)
				if not containsName(self.commandFeedbackNextInput, notation) then
					table.insert(self.commandFeedbackNextInput, notation)
				end
			end
		end
		io.write("\nP", which, " (", characterName, ") correct input: ", selected.name,
			selected.close and " (close range required)" or "", "\n")
		if matchedFollowup and chain then
			io.write(string.format("Follow-up spacing: %d ms after the previous recognized move (measurement only).\n",
				ticksElapsed(now, chain.time)))
		end
		if selected.next and #selected.next > 0 then
			io.write("Next combo input: ", table.concat(selected.next, "  OR  "),
				". Follow the game's cancel timing; the guide does not specify a fixed beat.\n")
		end
		return
	end

	if characterName == "Shermie" and direction == "forward" and bit.band(buttons, 32) ~= 0 then
		self.shermieFollowupUntil = nil
		if self.commandFollowups then self.commandFollowups[which] = nil end
		self.shermieFeedbackStart = now
		self.shermieFeedbackName = "Shermie Stand"
		self.commandFeedbackName = "Shermie Stand"
		self.commandFeedbackNext = nil
		self.commandFeedbackInput = "FWD + B (LK)"
		io.write("\nP", which, " correct input: Shermie Stand\n")
	elseif (direction == "back" or direction == "forward")
		and characterName == "Shermie" and bit.band(buttons, 64) ~= 0 then
		self.shermieFollowupUntil = nil
		self.shermieFeedbackStart = now
		self.shermieFeedbackName = "Shermie Flash Original (close throw)"
		self.commandFeedbackName = "Shermie Flash Original"
		self.commandFeedbackNext = nil
		self.commandFeedbackInput = direction:upper() .. " + C (SP)"
		io.write("\nP", which, " input matches Shermie Flash Original; close range is required.\n")
	elseif (direction == "back" or direction == "forward")
		and characterName == "Shermie" and bit.band(buttons, 128) ~= 0 then
		self.shermieFollowupUntil = nil
		self.shermieFeedbackStart = now
		self.shermieFeedbackName = "Front Flash (close throw)"
		self.commandFeedbackName = "Front Flash"
		self.commandFeedbackNext = nil
		self.commandFeedbackInput = direction:upper() .. " + D (SK)"
		io.write("\nP", which, " input matches Front Flash; close range is required.\n")
	end
end

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

function KOF98:describeInputState(mask)
	local names = {}
	local inputStateNames = {
		{ 1, "up" }, { 2, "down" },
		{ 4, "back" }, { 8, "forward" },
		{ 16, "A" }, { 32, "B" }, { 64, "C" }, { 128, "D" },
	}
	for _, entry in ipairs(inputStateNames) do
		if bit.band(mask, entry[1]) ~= 0 then
			table.insert(names, entry[2])
		end
	end
	return (#names > 0 and table.concat(names, "+")) or "released"
end

function KOF98:relativeInputMask(which, mask)
	if self.players[which].facing ~= 0 then return mask end
	local result = bit.band(mask, bit.bnot(0x0C))
	if bit.band(mask, 0x04) ~= 0 then result = bit.bor(result, 0x08) end
	if bit.band(mask, 0x08) ~= 0 then result = bit.bor(result, 0x04) end
	return result
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
		self.lastInputFrameTime = nil
		self.inputFrames = { {}, {} }
		self.motionHistory = { {}, {} }
		self.shermieFollowupUntil = nil
		self.commandFollowups = { nil, nil }
		self.commandLatch = { nil, nil }
		return
	end
	if not self.inputCaptureActive then
		local p1, p2 = self:readKeyboardInput(1), self:readKeyboardInput(2)
		if p1 ~= 0 or p2 ~= 0 then return end
		self.inputCaptureActive = true
		self.lastInputState[1], self.lastInputState[2] = 0, 0
		self.lastInputTime[1], self.lastInputTime[2] = now, now
		self.lastInputFrameTime = now
		return
	end
	local masks = {}
	for which = 1, 2 do
		local mask = self:readKeyboardInput(which)
		masks[which] = self:relativeInputMask(which, mask)
		if bit.band(masks[which], 0xF0) == 0 and self.commandLatch then
			self.commandLatch[which] = nil
		end
		local last = self.lastInputState[which]
		if last == nil or masks[which] ~= last then
			local row = history[which]
			table.insert(row, 1, masks[which])
			if #row > length then table.remove(row) end
			if last ~= nil and self.logInputTransitions then
				local elapsed = now - self.lastInputTime[which]
				if elapsed < 0 then elapsed = elapsed + 0x100000000 end
				io.write(string.format("P%d: %s held %d ms -> %s\n",
					which, self:describeInputState(last), elapsed,
					self:describeInputState(masks[which])))
			end
			if last == nil or bit.band(last, 0x0F) ~= bit.band(masks[which], 0x0F) then
				recordMotionDirection(self, which, directionName(masks[which]), now)
			end
			if self.logInputTransitions then
				self:updateShermieRhythmGuide(which, masks[which], last, now)
			end
			if self.commandCoachEnabled then
				self:checkCommandMove(which, masks[which], now)
			end
			self.lastInputState[which] = masks[which]
			self.lastInputTime[which] = now
		end
	end
	if self.logInputTransitions and
		now - self.lastInputFrameTime >= self.inputTimelinePeriodMs then
		for which = 1, 2 do
			local frames = self.inputFrames[which]
			table.insert(frames, masks[which])
			if #frames > self.inputTimelineLength then table.remove(frames, 1) end
		end
		self.lastInputFrameTime = now
	end
end

local inputTimelineBits = { 1, 4, 2, 8, 16, 32, 64, 128 }

function KOF98:renderInputTimeline()
	local xPositions, y, width = { 8, 168 }, 59, self.inputTimelineLength * 2
	local rowPitch, cellHeight = 1.5, 1
	for which = 1, 2 do
		local x, frames = xPositions[which], self.inputFrames[which]
		for row, keyMask in ipairs(inputTimelineBits) do
			local ry = y + (row - 1) * rowPitch
			self:horzLine(x, x + width, ry + cellHeight, inputColors.timeline)
		end
		-- Quarter-second ticks; each sampled column represents about 16 ms.
		for tick = 1, 4 do
			local tx = x + (tick * 15 * 2)
			self:vertLine(y, y + 8 * rowPitch, tx, inputColors.timeline)
		end
		local emptyColumns = self.inputTimelineLength - #frames
		for index, mask in ipairs(frames) do
			local fx = x + (emptyColumns + index - 1) * 2
			for row, keyMask in ipairs(inputTimelineBits) do
				if bit.band(mask, keyMask) ~= 0 then
					local color = (row <= 4) and inputColors.direction
						or inputColors.buttons[row - 4]
					local ry = y + (row - 1) * rowPitch
					self:box(fx, ry, fx + 1.5, ry + cellHeight, color, color)
				end
			end
		end
	end
	if self.shermieFeedbackStart then
		local elapsed = ticksElapsed(hotkey.ticks(), self.shermieFeedbackStart)
		local remaining = self.shermieFeedbackDurationMs - elapsed
		if remaining > 0 then
			local feedbackWidth = width * remaining / self.shermieFeedbackDurationMs
			self:horzLine(xPositions[1], xPositions[1] + feedbackWidth,
				y - 2, inputColors.positive)
		end
	end
	local guide = self.shermieRhythmGuide
	if guide then
		-- Use a single note lane attached to P1's existing input timeline.
		local laneY = y + 8 * rowPitch + 3
		local hitLineX = xPositions[1] + width * 0.7
		local scrollPixelsPerMs = 0.035
		local now = hotkey.ticks()
		local elapsed = ticksElapsed(now, guide.start)
		self:horzLine(xPositions[1], xPositions[1] + width,
			laneY, inputColors.timeline)
		self:vertLine(laneY - 3, laneY + 3, hitLineX,
			inputColors.rhythmCursor)
		for step = 1, #shermieRhythmDirections do
			local targetDelta = (step - 1) * self.rhythmGuideBeatMs
			local targetX = hitLineX
				+ (elapsed - targetDelta) * scrollPixelsPerMs
			if targetX >= xPositions[1] and targetX <= xPositions[1] + width then
				local targetColor = inputColors.rhythmCue
				if not guide.notes[step]
					and elapsed > targetDelta + self.rhythmGuideToleranceMs then
					targetColor = inputColors.rhythmMiss
				end
				self:box(targetX - 2, laneY - 2, targetX + 2, laneY + 2,
					targetColor, inputColors.timeline)
			end
			local note = guide.notes[step]
			if note then
				local actualElapsed = ticksElapsed(now, note.time)
				local actualX = hitLineX + actualElapsed * scrollPixelsPerMs
				if actualX >= xPositions[1] and actualX <= hitLineX + 10 then
					self:box(actualX - 2, laneY - 2, actualX + 2, laneY + 2,
						note.color, note.color)
				end
			end
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
	if self.logInputTransitions then self:renderInputTimeline() end
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
			if toggleKey[2] == "logInputTransitions" then
				self.inputFrames = { {}, {} }
				self.motionHistory = { {}, {} }
				self.shermieRhythmGuide = nil
				self.inputCaptureActive = false
				self.lastInputState[1], self.lastInputState[2] = nil, nil
				self.lastInputTime[1], self.lastInputTime[2] = nil, nil
				self.shermieFollowupUntil = nil
				self.commandFollowups = { nil, nil }
				self.commandLatch = { nil, nil }
				if self.logInputTransitions then
					io.write("Rhythm graph: rows up/back/down/forward/A/B/C/D; each column ~16 ms, ticks ~240 ms apart, newest at right.\n")
				end
			elseif toggleKey[2] == "commandCoachEnabled" then
				self.inputCaptureActive = false
				self.lastInputState[1], self.lastInputState[2] = nil, nil
				self.lastInputTime[1], self.lastInputTime[2] = nil, nil
				self.commandFollowups = { nil, nil }
				self.commandLatch = { nil, nil }
				self.loadedCommandSetByPlayer = {}
				if self.commandCoachEnabled then
					io.write("Command validation mode enabled. Current P1/P2 characters will load their own command sets.\n")
					io.write("Recognized commands and valid follow-ups will be shown in this console.\n")
					io.write("Timing is measured between recognized follow-ups; exact cancel windows are move-specific.\n")
				end
			end
		end
	end
end

return KOF98
