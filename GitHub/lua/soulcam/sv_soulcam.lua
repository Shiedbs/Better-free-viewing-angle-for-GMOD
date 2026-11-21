-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 dy是鹅的不是
-- SoulCam 服务端：只负责真正的实体变换、冻结和撤销
-- 单人/自己开房专用；不会改动任何原版或他人文件

local CFG = SoulCam.Config
local Sessions = {}

-- 必须先注册网络消息，否则客户端 net.Start 会报 "unpooled message name"
util.AddNetworkString("soulcam_freeze")
util.AddNetworkString("soulcam_begin")
util.AddNetworkString("soulcam_apply")
util.AddNetworkString("soulcam_end")
util.AddNetworkString("soulcam_collide")
util.AddNetworkString("soulcam_cam")

local function Allowed(ply)
    if not IsValid(ply) then return false end
    if game.SinglePlayer() then return true end
    return ply:IsListenServerHost()
end

local function PhysOf(ent)
    if not IsValid(ent) then return NULL end
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then return NULL end
    return phys
end

-- 冻结/解冻本体
net.Receive("soulcam_freeze", function(_, ply)
    if not Allowed(ply) then return end
    local b = net.ReadBool()
    if b then
        if ply.SoulCam_WasFrozen == nil then
            ply.SoulCam_WasFrozen = ply:IsFlagSet(FL_FROZEN)
        end
        ply:Freeze(true)
        ply:SetVelocity(Vector(0, 0, 0))
    else
        ply:Freeze(ply.SoulCam_WasFrozen == true)
        ply.SoulCam_WasFrozen = nil
    end
end)

-- 开始拖拽：记录旧状态并暂时锁住物理
net.Receive("soulcam_begin", function(_, ply)
    if not Allowed(ply) then return end
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:IsPlayer() or ent == ply then return end

    local phys = PhysOf(ent)
    local session = {
        owner = ply,
        pos = ent:GetPos(),
        ang = ent:GetAngles(),
        scale = ent:GetModelScale(),
        motion = nil,
        last = CurTime(),
    }
    if IsValid(phys) then
        if phys.IsMotionEnabled then
            session.motion = phys:IsMotionEnabled()
        end
        phys:EnableMotion(false)
        phys:Wake()
    end
    Sessions[ent] = session
end)

-- 拖拽中：只同步位置/角度/（缩放模式下的）缩放
net.Receive("soulcam_apply", function(_, ply)
    if not Allowed(ply) then return end
    local ent = net.ReadEntity()
    local pos = net.ReadVector()
    local ang = net.ReadAngle()
    local scaling = net.ReadBool()
    local scale = net.ReadFloat()
    if not IsValid(ent) then return end

    ent:SetPos(pos)
    ent:SetAngles(ang)
    if scaling then
        ent:SetModelScale(math.Clamp(scale, CFG.scale_min, CFG.scale_max), 0)
    end
    -- 物理体跟着走，避免模型动了但碰撞/阴影留在原地
    local phys = PhysOf(ent)
    if IsValid(phys) then
        if phys.SetPos then phys:SetPos(pos) end
        if phys.SetAngles then phys:SetAngles(ang) end
    end
    if Sessions[ent] then
        Sessions[ent].last = CurTime()
    end
end)

-- 结束拖拽：恢复物理、重建碰撞、写撤销点
net.Receive("soulcam_end", function(_, ply)
    if not Allowed(ply) then return end
    local ent = net.ReadEntity()
    local pos = net.ReadVector()
    local ang = net.ReadAngle()
    local scaling = net.ReadBool()
    local scale = net.ReadFloat()

    local session = Sessions[ent]
    Sessions[ent] = nil

    if not IsValid(ent) then return end

    ent:SetPos(pos)
    ent:SetAngles(ang)
    if scaling then
        scale = math.Clamp(scale, CFG.scale_min, CFG.scale_max)
        ent:SetModelScale(scale, 0)
        ent:Activate()   -- 让碰撞体积和 PhysObj 跟着缩放
    end

    local phys = PhysOf(ent)
    if IsValid(phys) then
        if phys.SetPos then phys:SetPos(pos) end
        if phys.SetAngles then phys:SetAngles(ang) end
    end
    -- 放到哪就固定在哪：退出灵魂出窍后也不会掉下来
    if IsValid(phys) then
        phys:EnableMotion(false)
        phys:Wake()
    end
    ent.SoulCamPinned = true

    if not session then return end
    local changed = pos:DistToSqr(session.pos) > 0.01
        or math.abs(ang.p - session.ang.p) + math.abs(ang.y - session.ang.y) + math.abs(ang.r - session.ang.r) > 0.1
        or (scaling and math.abs(scale - session.scale) > 0.001)

    if changed and undo then
        local e, p, a, s = ent, session.pos, session.ang, session.scale
        undo.Create("SoulCam")
        undo.SetPlayer(ply)
        undo.AddFunction(function()
            if not IsValid(e) then return end
            e:SetPos(p)
            e:SetAngles(a)
            e:SetModelScale(s, 0)
            e:Activate()
            local ph = PhysOf(e)
            if IsValid(ph) then
                ph:EnableMotion(true)
                ph:Wake()
            end
        end)
        undo.Finish("SoulCam")
    end
end)

-- 碰撞箱开关：关闭 = 固定在原地，只和玩家碰撞，不和环境/其他物体碰撞
net.Receive("soulcam_collide", function(_, ply)
    if not Allowed(ply) then return end
    local ent = net.ReadEntity()
    local on = net.ReadBool()
    if not IsValid(ent) then return end
    local phys = PhysOf(ent)

    if on then
        ent.SoulCamGhost = nil
        ent.SoulCamPinned = nil
        if IsValid(phys) then
            phys:EnableMotion(true)
            phys:EnableGravity(true)
            phys:Wake()
        end
    else
        ent.SoulCamGhost = true
        if IsValid(phys) then
            ent.SoulCamOldMotion = phys:IsMotionEnabled()
            phys:EnableMotion(false)
            phys:EnableGravity(false)
        end
    end
end)

-- 幽灵物体：只和玩家碰撞
hook.Add("ShouldCollide", "SoulCam_Ghost", function(a, b)
    if a.SoulCamGhost and not b:IsPlayer() then return false end
    if b.SoulCamGhost and not a:IsPlayer() then return false end
end)

-- 灵魂出窍时，Q 摆放的物体改到镜头中心
net.Receive("soulcam_cam", function(_, ply)
    if not Allowed(ply) then return end
    local active = net.ReadBool()
    local pos = net.ReadVector()
    local ang = net.ReadAngle()
    if active then
        ply.SoulCamCam = { pos = pos, ang = ang }
    else
        ply.SoulCamCam = nil
    end
end)

local function MoveSpawnToCamera(ply, ent)
    local cam = ply.SoulCamCam
    if not cam or not IsValid(ent) then return end

    local tr = util.TraceLine({
        start = cam.pos,
        endpos = cam.pos + cam.ang:Forward() * 8192,
        filter = { ply, ent },
        mask = MASK_SOLID,
    })

    local pos
    if tr.Hit then
        pos = tr.HitPos + tr.HitNormal * 12
    else
        pos = cam.pos + cam.ang:Forward() * 200
    end

    ent:SetPos(pos)
    ent:SetAngles(Angle(0, cam.ang.y, 0))

    local phys = PhysOf(ent)
    if IsValid(phys) then
        phys:Wake()
    end
end

hook.Add("PlayerSpawnedProp", "SoulCam_SpawnProp", function(ply, model, ent)
    MoveSpawnToCamera(ply, ent)
end)

hook.Add("PlayerSpawnedRagdoll", "SoulCam_SpawnRagdoll", function(ply, model, ent)
    MoveSpawnToCamera(ply, ent)
end)

hook.Add("PlayerSpawnedSENT", "SoulCam_SpawnSENT", function(ply, ent)
    MoveSpawnToCamera(ply, ent)
end)

-- 清理：目标被删除 / 玩家掉线时解冻物理
hook.Add("EntityRemoved", "SoulCam_Cleanup", function(ent)
    local session = Sessions[ent]
    Sessions[ent] = nil
    if session and IsValid(ent) then
        local phys = PhysOf(ent)
        if IsValid(phys) and session.motion ~= nil then
            phys:EnableMotion(session.motion)
        end
    end
end)

hook.Add("PlayerDisconnected", "SoulCam_Drop", function(ply)
    for ent, session in pairs(Sessions) do
        if session.owner == ply then
            Sessions[ent] = nil
            if IsValid(ent) then
                local phys = PhysOf(ent)
                if IsValid(phys) and session.motion ~= nil then
                    phys:EnableMotion(session.motion)
                end
            end
        end
    end
    if ply.SoulCam_WasFrozen ~= nil then
        ply.SoulCam_WasFrozen = nil
    end
    ply.SoulCamCam = nil
end)

-- 兜底：客户端异常退出、长时间没有更新时自动恢复物理，避免物体永久冻结
timer.Create("SoulCam_StaleSessions", 5, 0, function()
    local now = CurTime()
    for ent, session in pairs(Sessions) do
        if now - (session.last or now) > 15 then
            Sessions[ent] = nil
            if IsValid(ent) then
                local phys = PhysOf(ent)
                if IsValid(phys) and session.motion ~= nil then
                    phys:EnableMotion(session.motion)
                end
            end
        end
    end
end)
