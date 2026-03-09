local M = {}

-- API ImGui
local imgui = ui_imgui or imgui

-- Configuration
local modName = "NeedleStorm"
local windowName = "NeedleStorm Survival Control###uts_unique_id"

-- État
local state = {
  initialized = false,
  visible = true,
  running = false,
  gameOver = false,
  startTime = 0,
  score = 0,
  updateCounter = 0,
  debugVehCount = 0,

  -- Paramètres gameplay
  targetCount = 10,
  aggression = 2.2,
  triggerSpeedCapKmh = 20.0,    -- 20 km/h
  triggerBoostKmh = 432.0,      -- Exact mod Autobahn: applyVelocity(direction * 120 m/s)
  triggerSpacingM = 66.0,       -- Densité proche de la map Autobahn (environ 60-70m)
  triggerForwardOffsetM = 0.0,  -- Décalage trigger devant le PNJ
  triggerCooldownS = 0.05,
  unlimitedBoostZone = true,
  boostZoneRadiusM = 5000.0,
  pursuitMode = 3,
  pursuitRefreshS = 0.8,
  criticalDamage = 0.7,
  stopTimeoutS = 10.0,
  stoppedSpeedThresholdKmh = 2.0,

  -- Runtime
  lastAiUpdate = 0,
  lastRuntimeCleanup = 0,
  lastBoostStatTime = 0,
  boostWindowCount = 0,
  boostPerSecond = 0,
  totalBoostCount = 0,
  playerStoppedSince = 0,
  playerStoppedTime = 0,
  stopTimeoutTriggered = false,
  forcePursuitSetup = false,
  lastPursuitRefresh = 0,
  vehicleRuntime = {}
}

-- Pointers ImGui
local ui = {}
local function initUiPointers()
  if not imgui then return end
  ui.visible = imgui.BoolPtr(state.visible)
  ui.targetCount = imgui.IntPtr(state.targetCount)
  ui.aggression = imgui.FloatPtr(state.aggression)
  ui.triggerSpeedCapKmh = imgui.FloatPtr(state.triggerSpeedCapKmh)
  ui.triggerBoostKmh = imgui.FloatPtr(state.triggerBoostKmh)
  ui.triggerSpacingM = imgui.FloatPtr(state.triggerSpacingM)
  ui.triggerForwardOffsetM = imgui.FloatPtr(state.triggerForwardOffsetM)
  ui.triggerCooldownS = imgui.FloatPtr(state.triggerCooldownS)
  ui.unlimitedBoostZone = imgui.BoolPtr(state.unlimitedBoostZone)
  ui.boostZoneRadiusM = imgui.FloatPtr(state.boostZoneRadiusM)
end

-- ---------------------------------------------------------
-- UTILITAIRES
-- ---------------------------------------------------------

local function logMsg(level, msg)
  log(level, modName, "[UTS v0.38] " .. msg)
end

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function getUTSPlayerVehicle()
  if be and be.getPlayerVehicle then
    local ok, res = pcall(function() return be:getPlayerVehicle(0) end)
    if ok and res then return res end
  end
  if core_vehicles and core_vehicles.getAt then
    local res = core_vehicles.getAt(0)
    if res then return res end
  end
  return nil
end

local function dumpVehicleMethods()
  local veh = getUTSPlayerVehicle()
  if not veh then
    logMsg('E', "ERREUR DIAGNOSTIC : Aucun véhicule joueur trouvé !")
    return
  end

  logMsg('I', "--- DIAGNOSTIC MÉTHODES VÉHICULE (v0.38) ---")
  local ok, err = pcall(function()
    local methods = {}
    local mt = getmetatable(veh)
    if mt and mt.__index then
      for k, v in pairs(mt.__index) do
        if type(v) == "function" then table.insert(methods, k) end
      end
    end
    table.sort(methods)
    for _, m in ipairs(methods) do
      local ml = m:lower()
      if string.find(ml, "vel") or string.find(ml, "force") or string.find(ml, "delete") then
        logMsg('I', "Methode trouvee : " .. m)
      end
    end
  end)

  if not ok then logMsg('E', "Erreur pendant le dump : " .. tostring(err)) end
  logMsg('I', "--- FIN DIAGNOSTIC ---")
end

local function getObjectCount()
  if be then
    if be.getObjectCount then return be:getObjectCount() end
    if be.getObjectsCount then return be:getObjectsCount() end
  end
  return 0
end

local function getSafePosition(obj)
  if not obj then return nil end
  local ok, pos = pcall(function() return obj:getPosition() end)
  if ok and pos then return pos end
  return nil
end

local function getSafeForwardVector(obj)
  local forward = obj:getDirectionVector()
  if forward and forward:length() > 0.01 then return forward end

  local vel = obj:getVelocity()
  if vel and vel:length() > 0.01 then return vel:normalized() end

  return vec3(1, 0, 0)
end

local function getDistanceBetween(a, b)
  if not a or not b then return math.huge end
  local dx = a.x - b.x
  local dy = a.y - b.y
  local dz = a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function cleanupAllTraffic()
  local playerVeh = getUTSPlayerVehicle()
  local playerID = playerVeh and playerVeh:getID() or -1
  local count = 0
  local objCount = getObjectCount()
  local toDelete = {}

  for i = 0, objCount - 1 do
    local obj = be:getObject(i)
    if obj and obj:getID() ~= playerID and obj:getClassName() == "BeamNGVehicle" then
      table.insert(toDelete, obj)
    end
  end

  for _, obj in ipairs(toDelete) do
    local deleted = false
    if be.deleteObject then
      be:deleteObject(obj)
      deleted = true
    elseif be.deleteObjectByID then
      be:deleteObjectByID(obj:getID())
      deleted = true
    elseif obj.delete then
      obj:delete()
      deleted = true
    end
    if deleted then count = count + 1 end
  end

  logMsg('I', "Nettoyage : " .. count .. " vehicules supprimes")
  return count
end

local function copyVec3(v)
  return vec3(v.x, v.y, v.z)
end

local function getVehicleRuntime(objID, now)
  local runtime = state.vehicleRuntime[objID]
  if not runtime then
    runtime = {
      lastConfig = 0,
      lastTriggerAt = 0,
      lastTriggerPoint = nil,
      lastSeen = now
    }
    state.vehicleRuntime[objID] = runtime
  end
  runtime.lastSeen = now
  return runtime
end

local function cleanupVehicleRuntime(activeIDs)
  for id, _ in pairs(state.vehicleRuntime) do
    if not activeIDs[id] then
      state.vehicleRuntime[id] = nil
    end
  end
end

local function registerBoostHit()
  state.totalBoostCount = state.totalBoostCount + 1
  state.boostWindowCount = state.boostWindowCount + 1
end

local function updateBoostStats(now)
  if now - state.lastBoostStatTime >= 1.0 then
    state.boostPerSecond = state.boostWindowCount
    state.boostWindowCount = 0
    state.lastBoostStatTime = now
  end
end

local function resetRunState(now)
  local t = now or os.clock()
  state.startTime = t
  state.score = 0
  state.gameOver = false
  state.boostWindowCount = 0
  state.boostPerSecond = 0
  state.totalBoostCount = 0
  state.playerStoppedSince = 0
  state.playerStoppedTime = 0
  state.stopTimeoutTriggered = false
  state.forcePursuitSetup = true
  state.lastPursuitRefresh = 0
  state.lastBoostStatTime = t
  state.vehicleRuntime = {}
end

local function collectPoliceTrafficIds(playerID)
  local policeIds = {}
  if not gameplay_traffic or not gameplay_traffic.getTrafficData then
    return policeIds
  end

  local trafficData = gameplay_traffic.getTrafficData()
  for id, vehData in pairs(trafficData) do
    if id ~= playerID and vehData then
      if vehData.roleName ~= 'police' then
        pcall(function() vehData:setRole('police') end)
      end
      table.insert(policeIds, id)
    end
  end

  return policeIds
end

local function ensurePolicePursuit(now, playerID)
  if not gameplay_police or not gameplay_police.setupPursuitGameplay or not gameplay_police.setPursuitMode then
    return
  end
  if not playerID or playerID <= 0 then
    return
  end

  if not state.forcePursuitSetup and (now - state.lastPursuitRefresh) < state.pursuitRefreshS then
    return
  end

  local policeIds = collectPoliceTrafficIds(playerID)
  if not policeIds[1] then return end

  pcall(function()
    gameplay_police.setupPursuitGameplay(playerID, policeIds, {
      playerId = playerID,
      pursuitMode = state.pursuitMode,
      preventAutoStart = true
    })
    gameplay_police.setPursuitMode(state.pursuitMode, playerID, policeIds)
  end)

  state.lastPursuitRefresh = now
  state.forcePursuitSetup = false
end

local function spawnPoliceTrafficGroup()
  if not gameplay_traffic or not gameplay_traffic.setupTraffic then
    return false
  end

  local options = {
    policeAmount = state.targetCount,
    activeAmount = state.targetCount
  }

  local ok, res = pcall(function()
    return gameplay_traffic.setupTraffic(state.targetCount, 1.0, options)
  end)
  if not ok or res == false then
    return false
  end

  state.forcePursuitSetup = true
  return true
end

-- ---------------------------------------------------------
-- LOGIQUE GAMEPLAY (TRIGGERS DYNAMIQUES AUTOBANH)
-- ---------------------------------------------------------

local function queueAutobahnBoost(obj, speedCapMs, boostMs)
  local cmd = string.format([[
    if obj and obj:getVelocity():length() < %f then
      local dir = obj:getDirectionVector()
      if dir:length() < 0.001 then dir = vec3(1,0,0) end
      thrusters.applyVelocity(dir * %f)
      if input then
        input.event('brake', 0, 1)
        input.event('throttle', 1, 1)
      end
    end
  ]], speedCapMs, boostMs)
  obj:queueLuaCommand(cmd)
end

local function applyVehicleEffects(obj, runtime, now, playerPos)
  if not obj then return end

  local speedVec = obj:getVelocity() or vec3(0, 0, 0)
  local currentSpeedMs = speedVec:length()
  local speedCapMs = state.triggerSpeedCapKmh / 3.6
  local boostMs = state.triggerBoostKmh / 3.6

  -- Configuration IA légère: on laisse l'IA piloter, on ajoute seulement les boosts type trigger.
  if now - runtime.lastConfig > 0.5 then
    local cmd = string.format([[
      if ai then
        ai.setMode('traffic')
        ai.driveInLane('off')
        ai.setAggression(%f)
        ai.limitSpeedForCurves = false
        ai.lookAheadVehicles = false
      end
    ]], clamp(state.aggression, 0.5, 10.0))
    obj:queueLuaCommand(cmd)
    runtime.lastConfig = now
  end

  if not state.running then return end

  -- Trigger dynamique: un point "trigger" se déplace avec le PNJ.
  local pos = getSafePosition(obj)
  if not pos then return end
  local forward = getSafeForwardVector(obj)
  local triggerPoint = vec3(
    pos.x + forward.x * state.triggerForwardOffsetM,
    pos.y + forward.y * state.triggerForwardOffsetM,
    pos.z + forward.z * state.triggerForwardOffsetM
  )

  if not state.unlimitedBoostZone then
    if not playerPos then return end
    local zoneDist = getDistanceBetween(playerPos, pos)
    if zoneDist > state.boostZoneRadiusM then
      runtime.lastTriggerPoint = copyVec3(triggerPoint)
      return
    end
  end

  if not runtime.lastTriggerPoint then
    runtime.lastTriggerPoint = copyVec3(triggerPoint)
    return
  end

  local moved = getDistanceBetween(triggerPoint, runtime.lastTriggerPoint)
  if moved < state.triggerSpacingM then return end

  -- Le véhicule "entre" dans le trigger dynamique suivant.
  runtime.lastTriggerPoint = copyVec3(triggerPoint)

  if now - runtime.lastTriggerAt < state.triggerCooldownS then return end
  runtime.lastTriggerAt = now

  if currentSpeedMs < speedCapMs then
    queueAutobahnBoost(obj, speedCapMs, boostMs)
    registerBoostHit()
  end
end

local function hijackAllTraffic()
  local playerVeh = getUTSPlayerVehicle()
  local playerID = playerVeh and playerVeh:getID() or -1
  local playerPos = getSafePosition(playerVeh)
  local objCount = getObjectCount()
  local now = os.clock()

  ensurePolicePursuit(now, playerID)

  local hijackedCount = 0
  local activeIDs = {}

  for i = 0, objCount - 1 do
    local obj = be:getObject(i)
    if obj and obj:getID() ~= playerID and obj:getClassName() == "BeamNGVehicle" then
      local objID = obj:getID()
      activeIDs[objID] = true
      local runtime = getVehicleRuntime(objID, now)
      applyVehicleEffects(obj, runtime, now, playerPos)
      hijackedCount = hijackedCount + 1
    end
  end

  state.debugVehCount = hijackedCount
  updateBoostStats(now)

  if now - state.lastRuntimeCleanup > 2.0 then
    cleanupVehicleRuntime(activeIDs)
    state.lastRuntimeCleanup = now
  end

  if now - state.lastAiUpdate > 1.0 then
    state.lastAiUpdate = now
  end
end

-- ---------------------------------------------------------
-- RENDU INTERFACE
-- ---------------------------------------------------------

local function renderHudOverlay()
  if not imgui then return end
  if not state.running and not state.stopTimeoutTriggered then return end

  if not ui.hudVisible then
    ui.hudVisible = imgui.BoolPtr(true)
  end
  ui.hudVisible[0] = true

  imgui.SetNextWindowPos(imgui.ImVec2(20, 20), imgui.Cond_Always)
  imgui.SetNextWindowSize(imgui.ImVec2(520, 140), imgui.Cond_Always)
  if imgui.Begin("NeedleStorm HUD###uts_hud_overlay", ui.hudVisible) then
    imgui.SetWindowFontScale(2.3)
    imgui.Text(string.format("SCORE %.1fs", state.score))

    local stopText = string.format("STOPPED %.1fs / %.0fs", state.playerStoppedTime, state.stopTimeoutS)
    if state.playerStoppedTime >= state.stopTimeoutS * 0.7 then
      imgui.TextColored(imgui.ImVec4(1, 0.3, 0.25, 1), stopText)
    else
      imgui.TextColored(imgui.ImVec4(1, 0.85, 0.2, 1), stopText)
    end

    if state.stopTimeoutTriggered then
      imgui.TextColored(imgui.ImVec4(1, 0.1, 0.1, 1), "GAME OVER - STOPPED > 10s")
    end
    imgui.SetWindowFontScale(1.0)
  end
  imgui.End()
end

local function renderGui()
  if not imgui then return end

  renderHudOverlay()
  if not state.visible then return end

  if ui.visible then ui.visible[0] = state.visible end

  imgui.SetNextWindowSize(imgui.ImVec2(430, 560), imgui.Cond_FirstUseEver)
  if imgui.Begin(windowName, ui.visible) then
    state.visible = ui.visible[0]

    imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), "=== NEEDLESTORM SURVIVAL ===")
    imgui.Text("Score: " .. string.format("%.1f", state.score) .. "s")
    imgui.Text("Boosted vehicles: " .. state.debugVehCount)
    imgui.Text("Boosts/s: " .. state.boostPerSecond .. " | Total: " .. state.totalBoostCount)
    imgui.Text(string.format("Player stop time: %.1fs / %.0fs", state.playerStoppedTime, state.stopTimeoutS))

    imgui.Separator()

    if imgui.Button(state.running and "STOP SURVIVAL" or "START SURVIVAL", imgui.ImVec2(-1, 35)) then
      state.running = not state.running
      if state.running then
        resetRunState(os.clock())
      end
    end

    if imgui.Button("CLEAR ALL TRAFFIC", imgui.ImVec2(-1, 25)) then cleanupAllTraffic() end
    if imgui.Button("DIAGNOSTICS (CONSOLE)", imgui.ImVec2(-1, 20)) then dumpVehicleMethods() end

    if not state.running then
      if imgui.Button("SPAWN POLICE CHASERS", imgui.ImVec2(-1, 25)) then
        spawnPoliceTrafficGroup()
      end
    end

    imgui.Separator()
    imgui.Text("Police Chase + Dynamic Trigger Boost:")
    if not ui.targetCount then initUiPointers() end
    if ui.targetCount then
      if imgui.Button("BASE PRESET (20 km/h trigger)", imgui.ImVec2(-1, 24)) then
        state.aggression = 2.2
        state.triggerSpeedCapKmh = 20.0
        state.triggerBoostKmh = 432.0
        state.triggerSpacingM = 66.0
        state.triggerForwardOffsetM = 0.0
        state.triggerCooldownS = 0.05
        state.unlimitedBoostZone = true
        state.boostZoneRadiusM = 5000.0
        ui.aggression[0] = state.aggression
        ui.triggerSpeedCapKmh[0] = state.triggerSpeedCapKmh
        ui.triggerBoostKmh[0] = state.triggerBoostKmh
        ui.triggerSpacingM[0] = state.triggerSpacingM
        ui.triggerForwardOffsetM[0] = state.triggerForwardOffsetM
        ui.triggerCooldownS[0] = state.triggerCooldownS
        ui.unlimitedBoostZone[0] = state.unlimitedBoostZone
        ui.boostZoneRadiusM[0] = state.boostZoneRadiusM
        state.forcePursuitSetup = true
      end

      if imgui.SliderInt("Vehicle Count", ui.targetCount, 1, 60) then state.targetCount = ui.targetCount[0] end
      if imgui.SliderFloat("AI Aggression", ui.aggression, 0.5, 10.0) then state.aggression = ui.aggression[0] end
      if imgui.SliderFloat("Boost Threshold (km/h)", ui.triggerSpeedCapKmh, 5.0, 400.0) then state.triggerSpeedCapKmh = ui.triggerSpeedCapKmh[0] end
      if imgui.SliderFloat("Boost Speed (km/h)", ui.triggerBoostKmh, 120.0, 1400.0) then state.triggerBoostKmh = ui.triggerBoostKmh[0] end
      if imgui.SliderFloat("Trigger Spacing (m)", ui.triggerSpacingM, 15.0, 180.0) then state.triggerSpacingM = ui.triggerSpacingM[0] end
      if imgui.SliderFloat("Trigger Forward Offset (m)", ui.triggerForwardOffsetM, -20.0, 120.0) then state.triggerForwardOffsetM = ui.triggerForwardOffsetM[0] end
      if imgui.SliderFloat("Trigger Cooldown (s)", ui.triggerCooldownS, 0.01, 0.8) then state.triggerCooldownS = ui.triggerCooldownS[0] end

      if imgui.Checkbox("Unlimited Boost Zone (recommended)", ui.unlimitedBoostZone) then
        state.unlimitedBoostZone = ui.unlimitedBoostZone[0]
      end
      if not state.unlimitedBoostZone then
        if imgui.SliderFloat("Boost Zone Radius (m)", ui.boostZoneRadiusM, 30.0, 10000.0) then
          state.boostZoneRadiusM = ui.boostZoneRadiusM[0]
        end
      else
        imgui.Text("Boost zone is disabled: boosts can trigger anywhere.")
      end
    end

    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0, 1, 1, 1), "TRAFFIC INFO:")

    local stopped = 0
    local moving = 0
    local playerVeh = getUTSPlayerVehicle()
    local playerID = playerVeh and playerVeh:getID() or -1
    local objCount = getObjectCount()
    local displayCount = 0

    for i = 0, objCount - 1 do
      local obj = be:getObject(i)
      if obj and obj:getID() ~= playerID and obj:getClassName() == "BeamNGVehicle" then
        local speed = obj:getVelocity():length() * 3.6
        if speed < 5 then stopped = stopped + 1 else moving = moving + 1 end

        if displayCount < 8 then
          imgui.Text(string.format("ID %d : %s (%.0f km/h)", obj:getID(), (obj.JBeam or "Auto"), speed))
          displayCount = displayCount + 1
        end
      end
    end

    imgui.Text("Detected vehicles: " .. (moving + stopped))
    imgui.Text("Stopped: " .. stopped .. " | Moving: " .. moving)

    if imgui.Button("CLOSE MENU", imgui.ImVec2(-1, 20)) then state.visible = false end
  end
  imgui.End()
end

-- ---------------------------------------------------------
-- HOOKS
-- ---------------------------------------------------------

local function onUpdate(dt)
  state.updateCounter = state.updateCounter + 1

  local now = os.clock()
  local pVeh = getUTSPlayerVehicle()
  local playerID = pVeh and pVeh:getID() or (be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or 0)

  if state.forcePursuitSetup then
    ensurePolicePursuit(now, playerID)
  end

  if not state.running then return end

  state.score = now - state.startTime

  local ok, err = pcall(hijackAllTraffic, dt)
  if not ok then
    logMsg('E', "Erreur dans hijackAllTraffic : " .. tostring(err))
  end

  if pVeh then
    local vel = pVeh:getVelocity() or vec3(0, 0, 0)
    local speedKmh = vel:length() * 3.6

    if speedKmh <= state.stoppedSpeedThresholdKmh then
      if state.playerStoppedSince <= 0 then
        state.playerStoppedSince = now
      end
      state.playerStoppedTime = now - state.playerStoppedSince
    else
      state.playerStoppedSince = 0
      state.playerStoppedTime = 0
    end

    if state.playerStoppedTime >= state.stopTimeoutS then
      state.stopTimeoutTriggered = true
      state.gameOver = true
      state.running = false
      logMsg('W', "STOP TIMEOUT - GAME OVER")
      return
    end

    local okDamage, damage = pcall(function() return pVeh:getDamageLevel() end)
    if okDamage and damage and damage >= state.criticalDamage then
      state.gameOver = true
      state.running = false
      logMsg('W', "CRASH - GAME OVER")
    end
  end
end

M.onUpdate = onUpdate
M.onDrawGui = renderGui
M.onPreRender = renderGui
M.onExtensionLoaded = function() initUiPointers() end
M.show = function() state.visible = true end
M.toggle = function() state.visible = not state.visible end

initUiPointers()
return M
