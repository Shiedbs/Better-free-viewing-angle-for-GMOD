-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 dy是鹅的不是
-- SoulCam 加载器：只 include 自己的文件，不覆盖任何原版内容
if SERVER then
    AddCSLuaFile("soulcam/sh_config.lua")
    AddCSLuaFile("soulcam/cl_soulcam.lua")
    include("soulcam/sh_config.lua")
    include("soulcam/sv_soulcam.lua")
else
    include("soulcam/sh_config.lua")
    include("soulcam/cl_soulcam.lua")
end
