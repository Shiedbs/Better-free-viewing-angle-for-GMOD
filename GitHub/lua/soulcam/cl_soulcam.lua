-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 dy是鹅的不是
-- SoulCam 客户端：自由视角 + 操作轴（参考 PAC3 的相机与轴操作思路，自行实现）
-- 只做加法：仅添加 hook / concommand / net，不改任何原版文件

local CFG = SoulCam.Config
local COL = SoulCam.Colors

local SC = SoulCam.State or {}
SoulCam.State = SC

SC.active = false
SC.objmode = false
SC.target = NULL
SC.gizmo = "move"
SC.pos = Vector(0, 0, 0)
SC.ang = Angle(0, 0, 0)
SC.bodyAng = Angle(0, 0, 0)
SC.fov = 90
SC.hover = nil
SC.drag = nil
SC.clicker = false
SC.f6 = false
SC.rc = false
SC.lc = false
SC.esc = false
SC.mm = false
SC.f9 = false
SC.hideUI = false
SC.z = false
SC.controlPlayer = false
SC.lit = {}
SC.unlit = {}
SC.lastnet = 0

SC.menu = false
SC.menuFrame = nil
SC.menuTarget = NULL
SC.fx = {}
SC.ghosts = {}

surface.CreateFont("SoulCamFont", {
    font = "Microsoft YaHei",
    size = 18,
    weight = 600,
    antialias = true,
})
surface.CreateFont("SoulCamFontSmall", {
    font = "Microsoft YaHei",
    size = 14,
    weight = 500,
    antialias = true,
})

-- 鼠标灵敏度倍率：不再跟随引擎 sensitivity，避免高灵敏度玩家在自由视角里"甩头"
local sens_mul = CreateClientConVar("soulcam_sensitivity", "1", true, false,
    "SoulCam 视角灵敏度倍率，默认 1，觉得快就调 0.5")
local speed_mul = CreateClientConVar("soulcam_speed", "1", true, false,
    "SoulCam 移动速度倍率，默认 1")

-- ---------------------------------------------------------------------------
-- 数学工具（世界坐标 <-> 屏幕，参考 PAC3 mctrl 的投影思路）
-- ---------------------------------------------------------------------------
local function project(p)
    local d = p - SC.pos
    local z = d:Dot(SC.ang:Forward())
    if z < 2 then return nil end
    local f = (ScrH() * 0.5) / math.tan(math.rad(SC.fov) * 0.5)
    return ScrW() * 0.5 + d:Dot(SC.ang:Right()) / z * f,
        ScrH() * 0.5 - d:Dot(SC.ang:Up()) / z * f,
        z
end

local function screenToVec(x, y)
    local d = (ScrH() * 0.5) / math.tan(math.rad(SC.fov) * 0.5)
    local v = SC.ang:Forward() * d
        + SC.ang:Right() * (x - ScrW() * 0.5)
        + SC.ang:Up() * (ScrH() * 0.5 - y)
    return v:GetNormalized()
end

local function rayPlane(ro, rd, planePos, planeNormal)
    local denom = rd:Dot(planeNormal)
    if math.abs(denom) < 0.0001 then return nil end
    local t = (planePos - ro):Dot(planeNormal) / denom
    if t < 0 then return nil end
    return ro + rd * t
end

local function angleAround(v, axis)
    local u = axis:Cross(Vector(0, 0, 1))
    if u:LengthSqr() < 0.001 then u = axis:Cross(Vector(1, 0, 0)) end
    u:Normalize()
    local w = axis:Cross(u):GetNormalized()
    return math.atan2(v:Dot(w), v:Dot(u))
end

local function distToSeg(px, py, ax, ay, bx, by, minT)
    local vx, vy = bx - ax, by - ay
    local wx, wy = px - ax, py - ay
    local len2 = vx * vx + vy * vy
    local t = 0
    if len2 > 0.0001 then
        t = math.Clamp((wx * vx + wy * vy) / len2, minT or 0, 1)
    end
    local dx, dy = px - (ax + vx * t), py - (ay + vy * t)
    return math.sqrt(dx * dx + dy * dy)
end

local function gizmoRadius(origin)
    local d = math.max(origin:Distance(SC.pos), 1)
    return d * math.tan(math.rad(SC.fov) * 0.5) * (CFG.gizmo_pixels / (ScrH() * 0.5))
end

local function axesOf(ent)
    local a = ent:GetAngles()
    return { a:Right(), a:Forward(), a:Up() }
end

-- ---------------------------------------------------------------------------
-- 进入 / 退出
-- ---------------------------------------------------------------------------
function SC:SendCam()
    net.Start("soulcam_cam")
    net.WriteBool(self.active)
    net.WriteVector(self.pos)
    net.WriteAngle(self.ang)
    net.SendToServer()
end

function SC:Enter()
    if self.active then return end
    if not game.SinglePlayer() then
        chat.AddText(Color(255, 120, 120), "[SoulCam] ", Color(255, 255, 255), "single player only")
        return
    end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    self.active = true
    self.objmode = false
    self.target = NULL
    self.hover = nil
    self.drag = nil
    self.pos = EyePos()
    self.ang = EyeAngles()
    self.bodyAng = EyeAngles()
    self.bodyAng.r = 0
    self.fov = ply:GetFOV()
    self.pendingInit = true
    self.hideUI = false
    self.controlPlayer = false

    net.Start("soulcam_freeze")
    net.WriteBool(true)
    net.SendToServer()
    self:SendCam()

    chat.AddText(Color(120, 200, 255), "[SoulCam] ", Color(255, 255, 255),
        "ON  -  right click object, right click again to cycle axis, F6 to exit")
end

function SC:Exit()
    if not self.active then return end
    if self.drag then self:EndDrag() end
    self:ExitObj()
    self.active = false
    self.hover = nil
    self.hideUI = false
    self.controlPlayer = false

    if self.menu then self:CloseMenu() end
    self.clicker = false
    gui.EnableScreenClicker(false)

    -- 注意：不还原透明度/亮度/碰撞，退出后改动继续保留

    net.Start("soulcam_freeze")
    net.WriteBool(false)
    net.SendToServer()
    self:SendCam()

    chat.AddText(Color(120, 200, 255), "[SoulCam] ", Color(255, 255, 255), "OFF")
end

function SC:ExitObj()
    if self.drag then self:EndDrag() end
    self.objmode = false
    self.target = NULL
    self.hover = nil
end

function SC:Toggle()
    if self.active then
        self:Exit()
    else
        self:Enter()
    end
end

-- Z：在"控制视角"和"控制人物"之间切换
function SC:SetPlayerControl(b)
    if self.controlPlayer == b then return end
    self.controlPlayer = b

    if b then
        self:ExitObj()
        if self.menu then self:CloseMenu() end
    end

    net.Start("soulcam_freeze")
    net.WriteBool(not b)
    net.SendToServer()

    chat.AddText(Color(120, 200, 255), "[SoulCam] ", Color(255, 255, 255),
        b and "control player" or "control camera")
end

-- ---------------------------------------------------------------------------
-- 选物体 / 操作轴
-- ---------------------------------------------------------------------------
function SC:Pick()
    local tr = util.TraceLine({
        start = self.pos,
        endpos = self.pos + self.ang:Forward() * 8192,
        filter = LocalPlayer(),
        mask = MASK_SOLID,
    })
    local e = tr.Entity
    if not IsValid(e) then return nil end
    if e:IsPlayer() or e:IsWorld() then return nil end
    local phys = e:GetPhysicsObject()
    if not IsValid(phys) and not e:GetModel() then return nil end
    return e
end

function SC:OnRightClick()
    if self.menu then return end
    if not self.objmode then
        local e = self:Pick()
        if IsValid(e) then
            self:OpenMenu(e)
        end
    else
        if self.gizmo == "move" then
            self.gizmo = "scale"
        elseif self.gizmo == "scale" then
            self.gizmo = "rotate"
        else
            self.gizmo = "move"
        end
    end
end

-- ---------------------------------------------------------------------------
-- 物体菜单：操作轴 / 灵敏度 / 移动速度 / 碰撞箱 / 不透明度 / 亮度
-- ---------------------------------------------------------------------------
function SC:GetFx(ent)
    local st = self.fx[ent]
    if not st then
        st = {
            color = ent:GetColor(),
            mode = ent:GetRenderMode(),
            alpha = 1,
            bright = 1,
        }
        self.fx[ent] = st
    end
    return st
end

function SC:ApplyFx(ent)
    local st = self.fx[ent]
    if not st or not IsValid(ent) then return end
    local a = math.Clamp(st.alpha, 0, 1)
    local b = math.Clamp(st.bright, 0, 2)

    -- 压暗用颜色调制（<1），提亮用叠加光晕（见 DrawGlow）
    local v = b < 1 and math.floor(255 * b) or 255
    ent:SetRenderMode(a < 1 and RENDERMODE_TRANSALPHA or st.mode)
    ent:SetColor(Color(v, v, v, math.floor(a * 255)))
end

function SC:RestoreFx(ent)
    local st = self.fx[ent]
    if not st then return end
    self.fx[ent] = nil
    if not IsValid(ent) then return end
    self:SetUnlit(ent, false)
    ent:SetColor(st.color)
    ent:SetRenderMode(st.mode)
end

-- 无光照：把物体从引擎绘制里摘出来，用全亮模式手动画一遍
function SC:SetUnlit(ent, b)
    if not IsValid(ent) then return end
    ent.SoulCamUnlit = b or nil
    if b then
        ent:SetNoDraw(true)
        self.unlit[ent] = true
    else
        ent:SetNoDraw(false)
        self.unlit[ent] = nil
    end
end

hook.Add("PostDrawOpaqueRenderables", "SoulCam_Unlit", function(bDrawingDepth)
    if bDrawingDepth or not next(SC.unlit) then return end
    for ent in pairs(SC.unlit) do
        if IsValid(ent) then
            render.SetLightingMode(1)
            pcall(ent.DrawModel, ent)
            render.SetLightingMode(0)
        else
            SC.unlit[ent] = nil
        end
    end
end)

-- 被移动过的物体补一层动态光，避免塞进实体后整块全黑
hook.Add("PreDrawOpaqueRenderables", "SoulCam_Light", function(bDrawingDepth)
    if bDrawingDepth or not next(SC.lit) then return end
    local count = 0
    for ent in pairs(SC.lit) do
        if not IsValid(ent) then
            SC.lit[ent] = nil
        else
            count = count + 1
            if count > 6 then break end
            local dl = DynamicLight(ent:EntIndex() + 60000)
            if dl then
                dl.pos = ent:WorldSpaceCenter()
                dl.r, dl.g, dl.b = 255, 255, 255
                dl.brightness = 2
                dl.Decay = 400
                dl.Size = math.max(ent:OBBMaxs():Distance(ent:OBBMins()), 64) * 2.5
                dl.Dietime = 0.1
            end
        end
    end
end)

-- 亮度 > 1：用加法混合把模型本体再画一遍（提亮模型本身，不画额外 sprite）
hook.Add("PostDrawTranslucentRenderables", "SoulCam_Bright", function(bDrawingDepth, bDrawingSkybox)
    if bDrawingDepth or not next(SC.fx) then return end

    for ent, st in pairs(SC.fx) do
        if IsValid(ent) and st.bright and st.bright > 1.01 then
            local k = math.Clamp(st.bright - 1, 0, 1)
            render.SetColorModulation(k, k, k)
            render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD,
                BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
            ent:DrawModel()
            render.OverrideBlend(false)
            render.SetColorModulation(1, 1, 1)
        end
    end
end)

function SC:CloseMenu()
    if not self.menu and not IsValid(self.menuFrame) then return end
    self.menu = false
    self.menuTarget = NULL
    local f = self.menuFrame
    self.menuFrame = nil
    if IsValid(f) then f:Close() end
    gui.EnableScreenClicker(false)
end

function SC:OpenMenu(ent)
    if self.menu or not IsValid(ent) then return end
    self.menu = true
    self.menuTarget = ent
    gui.EnableScreenClicker(true)

    local f = vgui.Create("DFrame")
    f:SetSize(380, 380)
    f:Center()
    f:SetTitle("灵魂出窍 · 物体选项")
    f:MakePopup()
    f:SetKeyboardInputEnabled(false)
    f.OnRemove = function()
        SC.menu = false
        SC.menuTarget = NULL
        gui.EnableScreenClicker(false)
    end
    self.menuFrame = f

    local y = 38

    local function button(text, click)
        local b = vgui.Create("DButton", f)
        b:SetPos(16, y)
        b:SetSize(328, 30)
        b:SetText(text)
        b.DoClick = click
        y = y + 36
        return b
    end

    local function number(label, getv, setv, minv, maxv, step)
        local l = vgui.Create("DLabel", f)
        l:SetPos(16, y)
        l:SetSize(190, 26)
        l:SetText(label)

        local e = vgui.Create("DTextEntry", f)
        e:SetPos(210, y)
        e:SetSize(80, 26)
        e:SetNumeric(true)
        e:SetText(string.format("%.2f", getv()))

        local function commit()
            local v = tonumber(e:GetText()) or getv()
            v = math.Clamp(v, minv, maxv)
            setv(v)
            e:SetText(string.format("%.2f", v))
        end
        e.OnEnter = commit
        e.OnLoseFocus = commit

        local function bump(d)
            local v = math.Clamp(getv() + d, minv, maxv)
            setv(v)
            e:SetText(string.format("%.2f", v))
        end

        local minus = vgui.Create("DButton", f)
        minus:SetPos(296, y)
        minus:SetSize(22, 26)
        minus:SetText("-")
        minus.DoClick = function() bump(-(step or 0.1)) end

        local plus = vgui.Create("DButton", f)
        plus:SetPos(322, y)
        plus:SetSize(22, 26)
        plus:SetText("+")
        plus.DoClick = function() bump(step or 0.1) end

        y = y + 34
    end

    button("1. 操作轴  （右键切换 移动/旋转/缩放）", function()
        self:CloseMenu()
        self.target = ent
        self.objmode = true
        self.gizmo = "move"
    end)

    number("2. 镜头灵敏度", function() return sens_mul:GetFloat() end,
        function(v) sens_mul:SetFloat(v) end, 0, 2, 0.1)

    number("3. 镜头移动速度", function() return speed_mul:GetFloat() end,
        function(v) speed_mul:SetFloat(v) end, 0, 2, 0.1)

    local colOn = not ent.SoulCamCollisionOff
    local colBtn
    colBtn = button("4. 碰撞箱：" .. (colOn and "开" or "关"), function()
        colOn = not colOn
        ent.SoulCamCollisionOff = not colOn
        net.Start("soulcam_collide")
        net.WriteEntity(ent)
        net.WriteBool(colOn)
        net.SendToServer()
        if colOn then
            self.ghosts[ent] = nil
        else
            self.ghosts[ent] = true
        end
        colBtn:SetText("4. 碰撞箱：" .. (colOn and "开" or "关"))
    end)

    local st = self:GetFx(ent)

    number("5. 不透明度", function() return st.alpha end, function(v)
        st.alpha = v
        self:ApplyFx(ent)
    end, 0, 1, 0.1)

    number("6. 亮度（自发光）", function() return st.bright end, function(v)
        st.bright = v
        self:ApplyFx(ent)
    end, 0, 2, 0.1)

    local unlitOn = ent.SoulCamUnlit == true
    local unlitBtn
    unlitBtn = button("7. 无光照：" .. (unlitOn and "开" or "关"), function()
        unlitOn = not unlitOn
        self:SetUnlit(ent, unlitOn)
        unlitBtn:SetText("7. 无光照：" .. (unlitOn and "开" or "关"))
    end)

    button("8. 还原外观（透明度/亮度）", function()
        self:RestoreFx(ent)
        self:CloseMenu()
    end)

    button("关闭", function() self:CloseMenu() end)
end

function SC:UpdateHover()
    local e = self.target
    if not IsValid(e) then
        self.hover = nil
        return
    end
    local o = e:GetPos()
    local dirs = axesOf(e)
    local r = gizmoRadius(o)
    local ox, oy = project(o)
    if not ox then
        self.hover = nil
        return
    end
    local cx, cy = ScrW() * 0.5, ScrH() * 0.5
    if self.clicker then cx, cy = input.GetCursorPos() end

    local best, bestDist = nil, CFG.grab_pixels
    for i = 1, 3 do
        local tx, ty = project(o + dirs[i] * r)
        if tx then
            -- 不把轴根部当命中区，否则准星在物体中心时永远选中第一根轴
            local d = distToSeg(cx, cy, ox, oy, tx, ty, 0.22)
            if d < bestDist then
                bestDist = d
                best = i
            end
        end
    end
    self.hover = best
end

-- ---------------------------------------------------------------------------
-- 拖拽
-- ---------------------------------------------------------------------------
function SC:StartDrag()
    local e = self.target
    if not IsValid(e) or not self.hover then return end

    local axis = axesOf(e)[self.hover]
    local center = e:GetPos()
    local radius = gizmoRadius(center)

    gui.EnableScreenClicker(true)
    self.clicker = true

    -- 把鼠标放到被点中的轴端，避免"从屏幕中心开始"导致的起点误差
    local tipx, tipy = project(center + axis * radius)
    if tipx then
        input.SetCursorPos(math.Clamp(math.floor(tipx), 4, ScrW() - 5),
            math.Clamp(math.floor(tipy), 4, ScrH() - 5))
    else
        input.SetCursorPos(math.floor(ScrW() * 0.5), math.floor(ScrH() * 0.5))
    end

    local startCx, startCy = input.GetCursorPos()
    local ray = screenToVec(startCx, startCy)
    local normal
    if self.gizmo == "move" then
        normal = self.pos - center
        normal = normal - axis * normal:Dot(axis)
        if normal:LengthSqr() < 0.001 then normal = self.ang:Up() end
        normal:Normalize()
    elseif self.gizmo == "rotate" then
        normal = axis
    else
        normal = self.ang:Forward()
    end

    local hit = rayPlane(self.pos, ray, center, normal)
    if not hit then
        gui.EnableScreenClicker(false)
        self.clicker = false
        return
    end

    local drag = {
        ent = e,
        axis = axis,
        center = center,
        normal = normal,
        radius = radius,
        startPos = e:GetPos(),
        startAng = e:GetAngles(),
        startScale = e:GetModelScale(),
        curScale = e:GetModelScale(),
        startCx = startCx,
        startCy = startCy,
        acc = 0,
        prevAngle = nil,
    }
    if self.gizmo == "move" then
        drag.base = (hit - center):Dot(axis)
    elseif self.gizmo == "rotate" then
        drag.base = angleAround(hit - center, axis)
        drag.prevAngle = drag.base
    else
        drag.base = 0
    end
    self.drag = drag
    self.lastnet = 0
    self.lit[e] = true

    net.Start("soulcam_begin")
    net.WriteEntity(e)
    net.SendToServer()
end

function SC:UpdateDrag()
    local d = self.drag
    if not d then return end
    local e = d.ent
    if not IsValid(e) then
        self:EndDrag()
        return
    end

    local cx, cy = input.GetCursorPos()
    local ray = screenToVec(cx, cy)
    local hit = rayPlane(self.pos, ray, d.center, d.normal)
    if not hit then return end

    local mode = self.gizmo
    if mode == "move" then
        local delta = (hit - d.center):Dot(d.axis) - d.base
        e:SetPos(d.startPos + d.axis * delta)
    elseif mode == "rotate" then
        local now = angleAround(hit - d.center, d.axis)
        local diff = now - d.prevAngle
        while diff > math.pi do diff = diff - math.pi * 2 end
        while diff < -math.pi do diff = diff + math.pi * 2 end
        d.acc = d.acc + diff
        d.prevAngle = now
        local a = Angle(d.startAng.p, d.startAng.y, d.startAng.r)
        a:RotateAroundAxis(d.axis, math.deg(d.acc))
        e:SetAngles(a)
    else
        -- 缩放：沿轴的屏幕位移换算比例，避免"起点在中心"导致数值爆炸
        local p0x, p0y = project(d.center)
        local p1x, p1y = project(d.center + d.axis * d.radius)
        if p0x and p1x then
            local ax, ay = p1x - p0x, p1y - p0y
            local len = math.sqrt(ax * ax + ay * ay)
            if len > 1 then
                ax, ay = ax / len, ay / len
                local dpx = (cx - d.startCx) * ax + (cy - d.startCy) * ay
                d.curScale = math.Clamp(d.startScale * (1 + dpx / 250), CFG.scale_min, CFG.scale_max)
            end
        end
    end

    if CurTime() - (self.lastnet or 0) > 0.03 then
        self.lastnet = CurTime()
        net.Start("soulcam_apply")
        net.WriteEntity(e)
        net.WriteVector(e:GetPos())
        net.WriteAngle(e:GetAngles())
        net.WriteBool(mode == "scale")
        net.WriteFloat(d.curScale)
        net.SendToServer()
    end
end

function SC:EndDrag()
    local d = self.drag
    self.drag = nil
    if self.clicker then
        gui.EnableScreenClicker(false)
        self.clicker = false
    end
    if d and IsValid(d.ent) then
        self.lit[d.ent] = true
        net.Start("soulcam_end")
        net.WriteEntity(d.ent)
        net.WriteVector(d.ent:GetPos())
        net.WriteAngle(d.ent:GetAngles())
        net.WriteBool(self.gizmo == "scale")
        net.WriteFloat(d.curScale or d.ent:GetModelScale())
        net.SendToServer()
    end
end

-- ---------------------------------------------------------------------------
-- 相机
-- ---------------------------------------------------------------------------
hook.Add("CalcView", "SoulCam_CalcView", function(ply, pos, ang, fov)
    if not SC.active then return end

    -- 第一帧以引擎给的真实视角为起点（比 EyePos 可靠，避免起始位置跑到高空）
    if SC.pendingInit then
        SC.pendingInit = false
        SC.pos = Vector(pos.x, pos.y, pos.z)
        SC.ang = Angle(ang.p, ang.y, 0)
        SC.fov = fov
        -- 兜底：如果拿到的起点离本体太远（例如被其他相机插件接管过），回到本体眼睛
        local body = ply:GetPos()
        if SC.pos:DistToSqr(body) > 500 * 500 then
            SC.pos = ply:EyePos()
            print("[SoulCam] view origin too far, reset to body eye")
        end
        print("[SoulCam] init view at " .. tostring(SC.pos))
    end

    return {
        origin = SC.pos,
        angles = SC.ang,
        fov = SC.fov,
        drawviewer = true,
    }
end)

hook.Add("CreateMove", "SoulCam_CreateMove", function(cmd)
    if not SC.active then return end

    -- 控制人物：镜头锁死，人物视角/移动/射击全部交还给玩家
    if SC.controlPlayer then
        return
    end

    -- 拖动操作轴 / 菜单打开时：相机完全锁定，鼠标只用来操作界面
    if SC.clicker or SC.menu then
        cmd:SetViewAngles(SC.bodyAng)
        if cmd.SetMouseX then
            cmd:SetMouseX(0)
            cmd:SetMouseY(0)
        end
        if cmd.SetForwardMove then cmd:SetForwardMove(0) end
        if cmd.SetSideMove then cmd:SetSideMove(0) end
        if cmd.SetUpMove then cmd:SetUpMove(0) end
        if cmd.SetButtons then cmd:SetButtons(0) end
        return
    end

    local mx, my = cmd:GetMouseX(), cmd:GetMouseY()
    -- 防止单帧异常大的鼠标增量导致"瞬间甩头"
    mx = math.Clamp(mx, -300, 300)
    my = math.Clamp(my, -300, 300)

    local sens = CFG.sensitivity * sens_mul:GetFloat()
    -- GMod 的 pitch 正值朝下，所以这里用 +
    SC.ang.p = math.Clamp(SC.ang.p + my * sens, -CFG.pitch_limit, CFG.pitch_limit)
    SC.ang.y = SC.ang.y - mx * sens

    local ft = FrameTime()
    local speed = CFG.speed * speed_mul:GetFloat()
    if input.IsKeyDown(KEY_LSHIFT) then
        speed = CFG.speed_fast
    elseif input.IsKeyDown(KEY_LALT) then
        speed = CFG.speed_slow
    end

    local moveDir = Vector(0, 0, 0)
    local fwd, right, up = SC.ang:Forward(), SC.ang:Right(), SC.ang:Up()
    if input.IsKeyDown(KEY_W) then moveDir:Add(fwd) end
    if input.IsKeyDown(KEY_S) then moveDir:Sub(fwd) end
    if input.IsKeyDown(KEY_D) then moveDir:Add(right) end
    if input.IsKeyDown(KEY_A) then moveDir:Sub(right) end
    if input.IsKeyDown(KEY_SPACE) then moveDir:Add(Vector(0, 0, 1)) end
    if input.IsKeyDown(KEY_LCONTROL) then moveDir:Sub(Vector(0, 0, 1)) end
    if moveDir:LengthSqr() > 0 then
        SC.pos = SC.pos + moveDir:GetNormalized() * speed * ft
    end

    cmd:SetViewAngles(SC.bodyAng)
    if cmd.SetMouseX then
        cmd:SetMouseX(0)
        cmd:SetMouseY(0)
    end
    if cmd.SetForwardMove then cmd:SetForwardMove(0) end
    if cmd.SetSideMove then cmd:SetSideMove(0) end
    if cmd.SetUpMove then cmd:SetUpMove(0) end
    if cmd.SetButtons then cmd:SetButtons(0) end
end)

hook.Add("PreDrawViewModel", "SoulCam_NoViewModel", function()
    if SC.active then return true end
end)

-- ---------------------------------------------------------------------------
-- 输入
-- ---------------------------------------------------------------------------
hook.Add("PlayerBindPress", "SoulCam_Binds", function(ply, bind, pressed)
    if not SC.active then return end
    if SC.controlPlayer then return end
    if bind == "+attack" or bind == "+attack2" or bind == "+reload" then
        return true
    end
    if bind == "cancelselect" then
        return true
    end
end)

hook.Add("Think", "SoulCam_Think", function()
    local f6 = input.IsKeyDown(KEY_F6)
    local uiBlocked = gui.IsGameUIVisible() or (vgui.CursorVisible() and not SC.menu)
    if f6 and not SC.f6 and not uiBlocked then
        if SC.menu then SC:CloseMenu() end
        SC:Toggle()
    end
    SC.f6 = f6

    if not SC.active then
        SC.mm = false
        SC.f9 = false
        return
    end

    -- F9：隐藏 / 显示 UI（F7 被 save quick 占用，改用空闲的 F9）
    local f9 = input.IsKeyDown(KEY_F9)
    if f9 and not SC.f9 then
        SC.hideUI = not SC.hideUI
    end
    SC.f9 = f9

    -- 定期把镜头位置同步给服务端（Q 摆放物体时用镜头中心）
    if CurTime() - (SC.lastcam or 0) > 0.3 then
        SC.lastcam = CurTime()
        SC:SendCam()
    end

    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then
        SC:Exit()
        return
    end

    if SC.menu then
        if not IsValid(SC.menuFrame) then
            SC.menu = false
            SC.menuTarget = NULL
            gui.EnableScreenClicker(false)
            return
        end
        if input.IsKeyDown(KEY_ESCAPE) then SC:CloseMenu() end
        return
    end

    -- Z：锁定镜头，改为控制人物；再按恢复镜头控制
    local z = input.IsKeyDown(KEY_Z)
    if z and not SC.z then
        SC:SetPlayerControl(not SC.controlPlayer)
    end
    SC.z = z

    if SC.controlPlayer then
        if input.IsKeyDown(KEY_ESCAPE) then SC:Exit() end
        return
    end

    if SC.objmode and not IsValid(SC.target) then
        SC:ExitObj()
    end

    -- ESC：先结束拖拽，再退出物体操控
    local esc = input.IsKeyDown(KEY_ESCAPE)
    if esc and not SC.esc then
        if SC.drag then
            SC:EndDrag()
        elseif SC.objmode then
            SC:ExitObj()
        else
            SC:Exit()
        end
    end
    SC.esc = esc

    -- 右键：选物体 / 循环 移动-缩放-旋转
    local r = input.IsMouseDown(MOUSE_RIGHT)
    if r and not SC.rc and not SC.drag then
        SC:OnRightClick()
    end
    SC.rc = r

    -- 左键：按在轴上开始拖拽
    local l = input.IsMouseDown(MOUSE_LEFT)
    if l and not SC.lc then
        if SC.objmode and not SC.drag and SC.hover then
            SC:StartDrag()
        end
    elseif not l and SC.lc and SC.drag then
        SC:EndDrag()
    end
    SC.lc = l

    -- 轴模式下按中键：退出轴模式，回到物体菜单
    local mid = input.IsMouseDown(MOUSE_MIDDLE)
    if mid and not SC.mm and SC.objmode and not SC.drag then
        local t = SC.target
        SC:ExitObj()
        if IsValid(t) then
            SC:OpenMenu(t)
        end
    end
    SC.mm = mid

    -- 兜底：左键已松开但拖拽状态还在（例如在窗口外松手），强制结束
    if SC.drag and not input.IsMouseDown(MOUSE_LEFT) then
        SC:EndDrag()
    end

    if SC.drag then
        SC:UpdateDrag()
    elseif SC.objmode then
        SC:UpdateHover()
    end
end)

-- ---------------------------------------------------------------------------
-- 绘制
-- ---------------------------------------------------------------------------
local lineTex

local function drawLine2D(x1, y1, x2, y2, w)
    lineTex = lineTex or surface.GetTextureID("gui/center_gradient.vtf")
    local dx, dy = x1 - x2, y1 - y2
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    surface.SetTexture(lineTex)
    surface.DrawTexturedRectRotated(x1 - dx * 0.5, y1 - dy * 0.5, w or 3, len,
        math.deg(math.atan2(dx, dy)))
end

local function drawCircle2D(x, y, rad, seg)
    for i = 0, seg - 1 do
        local a1 = (i / seg) * math.pi * 2
        local a2 = ((i + 1) / seg) * math.pi * 2
        drawLine2D(x + math.cos(a1) * rad, y + math.sin(a1) * rad,
            x + math.cos(a2) * rad, y + math.sin(a2) * rad, 2)
    end
end

function SC:DrawRing(center, axis, radius, col)
    local u = axis:Cross(Vector(0, 0, 1))
    if u:LengthSqr() < 0.001 then u = axis:Cross(Vector(1, 0, 0)) end
    u:Normalize()
    local w = axis:Cross(u):GetNormalized()

    surface.SetDrawColor(col)
    local prev = nil
    for i = 0, 32 do
        local a = (i / 32) * math.pi * 2
        local p = center + (u * math.cos(a) + w * math.sin(a)) * radius
        local x, y = project(p)
        if x and prev then
            drawLine2D(prev[1], prev[2], x, y, 2)
        end
        prev = x and { x, y } or nil
    end
end

function SC:DrawGizmo()
    local e = self.target
    if not IsValid(e) then return end

    local o = e:GetPos()
    local dirs = axesOf(e)
    local r = gizmoRadius(o)
    local ox, oy = project(o)
    if not ox then return end

    local cols = { COL.x, COL.y, COL.z }
    for i = 1, 3 do
        local tx, ty = project(o + dirs[i] * r)
        if tx then
            local hot = (self.hover == i)
            local c = hot and COL.hot or cols[i]
            surface.SetDrawColor(c)
            drawLine2D(ox, oy, tx, ty, hot and 5 or 3)

            if self.gizmo == "rotate" then
                self:DrawRing(o, dirs[i], r, c)
            elseif self.gizmo == "scale" then
                surface.DrawRect(tx - 5, ty - 5, 10, 10)
            else
                drawCircle2D(tx, ty, 6, 12)
            end

            draw.SimpleText(("XYZ"):sub(i, i), "SoulCamFontSmall", tx + 8, ty - 20, c)
        end
    end

    surface.SetDrawColor(COL.center)
    drawCircle2D(ox, oy, 5, 16)
end

hook.Add("HUDShouldDraw", "SoulCam_HideHUD", function(name)
    if SC.active and SC.hideUI then
        return false
    end
end)

hook.Add("HUDPaint", "SoulCam_HUD", function()
    if not SC.active then return end
    if SC.hideUI then return end

    if SC.objmode and IsValid(SC.target) then
        SC:DrawGizmo()
    end

    if not SC.clicker and not SC.drag then
        surface.SetDrawColor(255, 255, 255, 220)
        surface.DrawRect(ScrW() * 0.5 - 1, ScrH() * 0.5 - 1, 2, 2)
    end

    local modeName = "自由视角"
    if SC.controlPlayer then
        modeName = "控制人物"
    elseif SC.objmode then
        modeName = ({ move = "移动", scale = "缩放", rotate = "旋转" })[SC.gizmo] or "移动"
    end

    draw.SimpleText("灵魂出窍 · " .. modeName, "SoulCamFont",
        ScrW() * 0.5, ScrH() - 96, Color(255, 255, 255, 235), 1, 1)

    local hint
    if SC.controlPlayer then
        hint = "Z：返回视角控制  ·  WASD 移动人物  ·  鼠标射击"
    elseif SC.drag then
        hint = "松开左键结束拖动 · ESC 取消"
    elseif SC.objmode then
        hint = "右键：切换 移动/缩放/旋转  ·  左键拖轴  ·  中键返回菜单  ·  ESC：退出操控"
    else
        hint = "右键选中物体  ·  WASD 移动  ·  Z 控制人物  ·  F6 退出"
    end
    draw.SimpleText(hint, "SoulCamFontSmall",
        ScrW() * 0.5, ScrH() - 72, Color(200, 200, 200, 200), 1, 1)
end)

-- ---------------------------------------------------------------------------
-- 杂项
-- ---------------------------------------------------------------------------
hook.Add("EntityRemoved", "SoulCam_TargetRemoved", function(ent)
    if SC.menuTarget == ent then
        SC:CloseMenu()
    end
    if SC.target == ent then
        SC:ExitObj()
    end
    SC.fx[ent] = nil
    SC.ghosts[ent] = nil
end)

concommand.Add("soulcam_toggle", function()
    SC:Toggle()
end)

concommand.Add("soulcam_debug", function()
    local ply = LocalPlayer()
    local frozen = IsValid(ply) and ply:IsFlagSet(FL_FROZEN) or false
    print(string.format("[SoulCam] active=%s pendingInit=%s frozen=%s",
        tostring(SC.active), tostring(SC.pendingInit), tostring(frozen)))
    if IsValid(ply) then
        print("[SoulCam] cam=" .. tostring(SC.pos)
            .. " eye=" .. tostring(EyePos())
            .. " body=" .. tostring(ply:GetPos()))
    end
end)

concommand.Add("soulcam_ui", function()
    if SC.active then
        SC.hideUI = not SC.hideUI
    end
end)

-- 列出当前没有被绑定的常用键位
concommand.Add("soulcam_keys", function()
    local keys = {
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
        "`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=",
        "q", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\",
        "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'",
        "z", "x", "c", "v", "b", "n", "m", ",", ".", "/",
        "tab", "capslock", "space", "insert", "home", "delete", "end", "pgup", "pgdn",
        "up", "down", "left", "right",
    }
    local free = {}
    for _, k in ipairs(keys) do
        local ok, bind = pcall(input.LookupKeyBinding, k)
        if not ok or not bind or bind == "" then
            free[#free + 1] = k
        end
    end
    local msg = table.concat(free, " ")
    print("[SoulCam] unbound keys: " .. msg)
    chat.AddText(Color(120, 200, 255), "[SoulCam] ", Color(255, 255, 255), "unbound: " .. msg)
end)

concommand.Add("soulcam_reset", function()
    -- 还原外观
    local fxEnts = {}
    for ent in pairs(SC.fx) do fxEnts[#fxEnts + 1] = ent end
    for _, ent in ipairs(fxEnts) do
        SC:RestoreFx(ent)
    end

    -- 还原碰撞与物理
    local ghosts = SC.ghosts
    SC.ghosts = {}
    for ent in pairs(ghosts) do
        if IsValid(ent) then
            net.Start("soulcam_collide")
            net.WriteEntity(ent)
            net.WriteBool(true)
            net.SendToServer()
            ent.SoulCamCollisionOff = nil
        end
    end

    SC.drag = nil
    SC.clicker = false
    SC.menu = false
    if IsValid(SC.menuFrame) then
        SC.menuFrame:Close()
    end
    SC.menuFrame = nil
    SC.menuTarget = NULL
    gui.EnableScreenClicker(false)
    if SC.active then
        SC:Exit()
    end
    print("[SoulCam] reset")
end)

timer.Simple(2, function()
    if game.SinglePlayer() then
        chat.AddText(Color(120, 200, 255), "[SoulCam] ", Color(255, 255, 255),
            "loaded - press F6 to toggle (bind soulcam_toggle for a custom key)")
    end
end)
