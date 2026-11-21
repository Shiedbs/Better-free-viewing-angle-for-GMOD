-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 dy是鹅的不是
-- SoulCam 共享配置（客户端/服务端都会加载）
SoulCam = SoulCam or {}

SoulCam.Config = {
    -- 相机
    sensitivity = 0.035,     -- 每 1 点鼠标计数转多少度；不再乘引擎 sensitivity
    speed = 420,
    speed_fast = 1600,
    speed_slow = 110,
    pan_speed = 0.06,
    pitch_limit = 89,
    -- 操作轴
    grab_pixels = 12,
    gizmo_pixels = 110,
    -- 缩放范围
    scale_min = 0.1,
    scale_max = 5,
}

SoulCam.Colors = {
    x = Color(235, 80, 80),
    y = Color(90, 220, 110),
    z = Color(90, 150, 255),
    hot = Color(255, 225, 90),
    center = Color(255, 255, 255, 220),
}
