--!native
-- https://github.com/78n/SimpleSpy 有一半概率会出错，但毕竟是测试版，情有可原！
-- ============================================================================
-- 本文件在 SimpleSpy（反编译增强版）基础上合并了 ACBridge 层。
--   ACBridge 移植自 Cobalt：https://github.com/notpoiu/cobalt
--   原作者 deivid / upio，许可证 Apache-2.0（见文件末尾声明）
--   主要修改：新增执行器能力探测与降级、统一 hook 登记与还原、
--             Adonis 定点处置、调用来源多因素过滤、栈隐藏、静默启动。
--   说明：该层只降低出现可观察痕迹的概率，不构成对任何反作弊的免疫；
--         对 Byfron / Hyperion 及服务端侧校验没有任何可证明的效果。
-- ============================================================================

if getgenv().SimpleSpyExecuted and type(getgenv().SimpleSpyShutdown) == "function" then
    getgenv().SimpleSpyShutdown()
end

local realconfigs = {
    logcheckcaller = false,
    autoblock = false,
    funcEnabled = true,
    advancedinfo = false,
    --logreturnvalues = false,
    supersecretdevtoggle = false,
    -- ↓ ACBridge 新增（取值依据研究报告：默认开启的只有已验证且低风险项）
    acBypass = true,               -- 启动即静默启用的 AC 处置
    actorBridge = false,           -- Actor 侧捕获：已实现，但部分执行器 run_on_actor 会崩溃
    acVerbose = false,             -- true 才把诊断信息 warn 出来，默认静默
    overrideGlobalDecompile = false, -- false = 不覆盖全局 decompile，避免全局污染
    ignoreRobloxInternal = false,  -- 过滤 RobloxReplicatedStorage 下的内部流量
    ignorePlayerModule = false,    -- 过滤 PlayerModule 来源的调用
}

local configs = newproxy(true)
local configsmetatable = getmetatable(configs)

configsmetatable.__index = function(self,index)
    return realconfigs[index]
end

local oth = syn and syn.oth
local unhook = oth and oth.unhook
local hook = oth and oth.hook

local lower = string.lower
local byte = string.byte
local round = math.round
local running = coroutine.running
local resume = coroutine.resume
local status = coroutine.status
local yield = coroutine.yield
local create = coroutine.create
local close = coroutine.close
local OldDebugId = game.GetDebugId
local info = debug.info

local IsA = game.IsA
local tostring = tostring
local tonumber = tonumber
local delay = task.delay
local spawn = task.spawn
local clear = table.clear
local clone = table.clone

local function blankfunction(...)
    return ...
end

local get_thread_identity = (syn and syn.get_thread_identity) or getidentity or getthreadidentity
local set_thread_identity = (syn and syn.set_thread_identity) or setidentity
local islclosure = islclosure or is_l_closure
local threadfuncs = (get_thread_identity and set_thread_identity and true) or false

local getinfo = getinfo or blankfunction
local getupvalues = getupvalues or debug.getupvalues or blankfunction
local getconstants = getconstants or debug.getconstants or blankfunction

local getcustomasset = getsynasset or getcustomasset
local getcallingscript = getcallingscript or blankfunction
local newcclosure = newcclosure or blankfunction
local clonefunction = clonefunction or blankfunction
local cloneref = cloneref or blankfunction
local request = request or (syn and syn.request)
local makewritable = makewriteable or function(tbl)
    setreadonly(tbl,false)
end
local makereadonly = makereadonly or function(tbl)
    setreadonly(tbl,true)
end
local isreadonly = isreadonly or table.isfrozen

-- ============================================================================
-- [修复] 剪贴板统一封装：全接口扫描 + 自动降级 + 失败兜底
--   原实现缺失 writeclipboard / syn.setclipboard，且 candidates 里放入了
--   尚未定义的 setclipboard 自身（恒为 nil），小众执行器上直接无接口可用。
-- ============================================================================
local setclipboard
do
    -- 关键：本文件开头有 `local setclipboard`，会遮蔽全局同名函数，
    -- 直接写 `setclipboard` 恒为 nil。必须从全局环境表显式取。
    local g = (type(getgenv) == "function" and getgenv()) or _G or {}
    local candidates = {
        rawget(g, "setclipboard"),     -- 全局 setclipboard（被 local 遮蔽，须显式取）
        toclipboard,
        set_clipboard,
        writeclipboard,
        Clipboard and Clipboard.set,
        syn and syn.setclipboard,
        syn and syn.to_clipboard,
        rawget(g, "toclipboard"),
        rawget(g, "writeclipboard"),
    }
    local realSetClipboard = nil
    for _, fn in ipairs(candidates) do
        if type(fn) == "function" then
            realSetClipboard = fn
            break
        end
    end

    if realSetClipboard then
        setclipboard = function(text)
            text = tostring(text or "")
            local ok, err = pcall(realSetClipboard, text)
            return ok, err
        end
    else
        -- 兜底：写文件 + 控制台输出，保证内容不丢
        setclipboard = function(text)
            text = tostring(text or "")
            local saved = false
            if type(writefile) == "function" and type(isfolder) == "function" then
                local ok = pcall(function()
                    if not isfolder("SimpleSpy") then makefolder("SimpleSpy") end
                    writefile("SimpleSpy/copied_" .. os.time() .. ".txt", text)
                end)
                saved = ok == true
            end
            warn("SimpleSpy：当前环境没有剪贴板接口")
            warn("  尝试复制的内容：" .. text:sub(1, 120))
            if saved then
                warn("  已保存为文件（见 SimpleSpy 文件夹）")
            end
            return false, "no clipboard api"
        end
    end
end

--- 复制并给出真实的成功/失败反馈（原实现无论成败都写「复制成功！」）
--- 返回 boolean 表示是否写入成功
local function copyToClipboard(text, statusLabel, successText)
    if text == nil or text == "" then
        if statusLabel then statusLabel.Text = "没有可复制的内容" end
        return false
    end
    local ok, err = setclipboard(text)
    if statusLabel then
        if ok then
            statusLabel.Text = successText or "复制成功！"
        else
            statusLabel.Text = ("复制失败：%s"):format(tostring(err):sub(1, 40))
        end
        delay(2, function()
            if statusLabel and statusLabel.Text:match("^复制") then
                statusLabel.Text = "这是一段稍长一些的文本。"
            end
        end)
    end
    return ok
end

local hookmetamethod = hookmetamethod or (makewriteable and makereadonly and getrawmetatable) and function(obj: object, metamethod: string, func: Function)
    local old = getrawmetatable(obj)

    if hookfunction then
        return hookfunction(old[metamethod],func)
    else
        local oldmetamethod = old[metamethod]
        makewriteable(old)
        old[metamethod] = func
        makereadonly(old)
        return oldmetamethod
    end
end

local function Create(instance, properties, children)
    local obj = Instance.new(instance)

    for i, v in next, properties or {} do
        obj[i] = v
        for _, child in next, children or {} do
            child.Parent = obj;
        end
    end
    return obj;
end

local function SafeGetService(service)
    return cloneref(game:GetService(service))
end

-- ============================================================================
-- ACBridge —— 从 Cobalt 移植的「反作弊处置 + 痕迹收敛」层
--   来源：https://github.com/notpoiu/cobalt （Apache-2.0，作者 deivid / upio）
--   上游实现：Src/Utils/ExecutorSupport、Src/Utils/Hook/Luau、Src/Utils/Anticheats
-- ----------------------------------------------------------------------------
-- 本次移植只纳入研究报告判定为「可行」的部分：
--   · 执行器能力逐项探测，缺什么降级什么（ExecutorSupport 思路）
--   · 统一 hook 登记与还原（Hooks 表 + restorefunction 双路径）
--   · 原始元表 / C 闭包安全兜底（getrawmetatable、newcclosure、AWP 特化）
--   · 栈隐藏（setstackhidden，可用时对所有 detour 启用）
--   · Adonis 定点处置（Main 两级调度：PlaceId 专用优先，通用兜底）
--   · 调用来源多因素过滤（checkcaller + isexecutorclosure，不单信其一）
--   · Roblox 内部流量 / PlayerModule 过滤
--   · 受保护 UI 容器（gethui → HiddenUI → CoreGui）
--   · 静默启动：不弹窗、不 warn，诊断信息只进内部缓冲区
-- 明确不默认启用（报告判定为「不宜默认」）：
--   · RakNet 网络层 hook —— 只探测能力，不安装
--   · Actor 侧捕获 —— 已实现，但默认关闭（部分执行器 run_on_actor 会崩溃）
-- ----------------------------------------------------------------------------
-- 这一层只能降低出现可观察痕迹的概率，不构成对任何反作弊的免疫，
-- 对 Byfron / Hyperion 及服务端侧校验没有任何可证明的效果。
-- ============================================================================
local ACBridge = {}
local AC = {
    Enabled = true,
    Unloaded = false,
    Name = "N/A",
    Disabled = false,
    Initialized = false,
    Applied = {},       -- 已生效的处置记录
    Risks = {},         -- 缺失的「降低检测风险」能力
    Buffer = {},        -- 静默诊断缓冲
    ActorBridge = false,
}
ACBridge.State = AC

-- ---------- 执行器识别与已知缺陷名单 ----------
local ExecutorName = "Unknown"
do
    local ok, name = pcall(identifyexecutor)
    if ok and type(name) == "string" and #name > 0 then
        local first = name:match("^(%S+)")
        ExecutorName = first or name
    end
end
AC.Executor = ExecutorName

-- 上游 BrokenFeatures：这些能力在对应执行器上已知损坏或会导致崩溃
local BrokenFeatures = {
    Volcano = { oth = true, run_on_actor = true },
    Potassium = { oth = true },
}

-- ---------- 静默诊断缓冲 ----------
local function acLog(level, msg)
    if type(msg) ~= "string" then msg = tostring(msg) end
    table.insert(AC.Buffer, ("[%s] %s"):format(level, msg))
    if #AC.Buffer > 200 then
        table.remove(AC.Buffer, 1)
    end
    if configs.acVerbose then
        warn(("SimpleSpy/AC · %s · %s"):format(level, msg))
    end
end
ACBridge.Log = acLog

-- ---------- 能力探测 ----------
local Cap = setmetatable({}, { __index = function() return false end })
ACBridge.Cap = Cap

local function test(name, fn, isRiskMitigation)
    if BrokenFeatures[ExecutorName] and BrokenFeatures[ExecutorName][name] then
        Cap[name] = false
        acLog("skip", ("%s 在 %s 上已知损坏，已跳过"):format(name, ExecutorName))
        return false
    end
    local ok, res = pcall(fn)
    local working = ok and res ~= false and res ~= nil
    Cap[name] = working and (res == true and true or res) or false
    if not working then
        if isRiskMitigation then
            table.insert(AC.Risks, name)
            acLog("risk", ("缺少 %s，可观察痕迹会增加"):format(name))
        else
            acLog("cap", ("%s 不可用，相关功能降级"):format(name))
        end
    end
    return working
end
ACBridge.Test = test

-- 基础 hook 能力
test("hookfunction", function() return type(hookfunction) == "function" end)
test("hookmetamethod", function() return type(hookmetamethod) == "function" end)
test("getrawmetatable", function() return type(getrawmetatable or debug.getmetatable) == "function" end)
test("newcclosure", function() return type(newcclosure) == "function" end)
test("clonefunction", function() return type(clonefunction) == "function" end)
test("cloneref", function() return type(cloneref) == "function" end)
test("islclosure", function() return type(islclosure or is_l_closure) == "function" end)
test("iscclosure", function() return type(iscclosure) == "function" end)
test("isfunctionhooked", function() return type(isfunctionhooked) == "function" end)
test("restorefunction", function() return type(restorefunction) == "function" end)
test("getnamecallmethod", function() return type(getnamecallmethod) == "function" end)
-- 降风险能力（缺失 = 更容易被观察到，而不是功能不可用）
test("setstackhidden", function() return type(setstackhidden) == "function" end, true)
test("checkcaller", function() return type(checkcaller) == "function" end, true)
test("isexecutorclosure", function() return type(isexecutorclosure) == "function" end, true)
test("compareinstances", function() return type(compareinstances) == "function" end, true)
test("getcallingscript", function() return type(getcallingscript) == "function" end)
-- 闭包枚举（Adonis 依赖）
test("getreg", function() return type(getreg) == "function" end)
test("getgc", function() return type(getgc) == "function" end)
test("filtergc", function() return type(filtergc) == "function" end)
test("debuginfo", function() return type(debug.info) == "function" end)
test("coroutineclose", function() return type(coroutine.close) == "function" end)
-- 只探测，不启用
test("run_on_actor", function() return type(run_on_actor) == "function" end)
test("getactors", function() return type(getactors) == "function" end)
test("create_comm_channel", function() return type(create_comm_channel) == "function" end)
test("get_comm_channel", function() return type(get_comm_channel) == "function" end)
test("raknet", function()
    return type(raknet) == "table" and type(raknet.add_send_hook) == "function"
end)

-- ---------- 安全包装：C 闭包转换 ----------
local islclosureSafe = islclosure or is_l_closure
local function isLuaClosure(f)
    if type(islclosureSafe) ~= "function" then return false end
    local ok, res = pcall(islclosureSafe, f)
    return ok and res == true
end

-- 上游对 AWP 的 newcclosure 特化：非 AWP 不应照搬，否则引入多余的 setfenv 去优化
local function toCClosure(f)
    if type(f) ~= "function" then return f end
    if not Cap.newcclosure then return f end
    if ExecutorName == "AWP" and type(getfenv) == "function" and type(setfenv) == "function" then
        local ok, wrapped = pcall(function()
            local env = getfenv(f)
            local proxy = setmetatable({ __F = f }, { __index = env, __newindex = env })
            local nf = function(...) return proxy.__F(...) end
            setfenv(nf, proxy)
            return newcclosure(nf)
        end)
        if ok and type(wrapped) == "function" then return wrapped end
    end
    if not isLuaClosure(f) then return f end
    local ok, c = pcall(newcclosure, f)
    if ok and type(c) == "function" then return c end
    return f
end
ACBridge.ToCClosure = toCClosure

-- 栈隐藏：让 detour 不出现在 debug.info / traceback / getfenv 的层级里
local function hideStack(f)
    if type(f) ~= "function" or not Cap.setstackhidden then return f end
    pcall(setstackhidden, f, true)
    return f
end
ACBridge.HideStack = hideStack

-- ---------- 安全取原始元表 ----------
local rawGetMeta = getrawmetatable or debug.getmetatable
local function safeRawMeta(obj)
    if Cap.getrawmetatable and type(rawGetMeta) == "function" then
        local ok, mt = pcall(rawGetMeta, obj)
        if ok and type(mt) == "table" then return mt end
    end
    return nil
end
ACBridge.SafeRawMeta = safeRawMeta

-- ---------- 实例等价判断 ----------
local OldDebugIdSafe = OldDebugId
local function IsEqualToInstance(a, b)
    if a == b then return true end
    if typeof(a) ~= "Instance" or typeof(b) ~= "Instance" then return false end
    if Cap.compareinstances then
        local ok, res = pcall(compareinstances, a, b)
        if ok and res ~= nil then return res == true end
    end
    if type(OldDebugIdSafe) == "function" then
        local ok1, id1 = pcall(OldDebugIdSafe, a)
        local ok2, id2 = pcall(OldDebugIdSafe, b)
        if ok1 and ok2 and type(id1) == "string" and id1 == id2 then return true end
    end
    return false
end
ACBridge.IsEqualToInstance = IsEqualToInstance

-- ---------- 统一 hook 登记与还原 ----------
local HookRegistry = {}   -- [hookedOrOriginal] = { Original, Replacement, Tag }
ACBridge.Registry = HookRegistry

local function registerHook(original, hooked, replacement, tag)
    if type(original) ~= "function" then return end
    HookRegistry[original] = {
        Original = original,
        Hooked = hooked,
        Replacement = replacement,
        Tag = tag or "unknown",
        Restore = function(self)
            local entry = HookRegistry[original]
            if not entry then return false end
            local target = entry.Hooked or entry.Original
            local done = false
            if Cap.restorefunction and Cap.isfunctionhooked then
                local ok, isHooked = pcall(isfunctionhooked, target)
                if ok and isHooked == true then
                    done = select(1, pcall(restorefunction, target)) == true
                end
            end
            if not done then
                -- 退化路径：用保存的原函数再覆盖一次
                done = select(1, pcall(hookfunction, target, entry.Original)) == true
            end
            HookRegistry[original] = nil
            return done
        end,
    }
    return HookRegistry[original]
end

--- 统一函数 hook。返回值语义与执行器 hookfunction 保持一致（多为原函数），
--- 失败时返回 nil，调用方应保持原行为，绝不抛错。
function ACBridge.HookFunction(original, replacement, tag)
    if type(original) ~= "function" or type(replacement) ~= "function" then return nil end
    if AC.Unloaded or not AC.Enabled then return nil end
    if not Cap.hookfunction then
        acLog("hook", ("%s：执行器不支持 hookfunction，保持未 hook"):format(tostring(tag)))
        return nil
    end
    local repl = toCClosure(hideStack(replacement))
    local ok, hooked = pcall(hookfunction, original, repl)
    if not ok then
        acLog("hook", ("%s hook 失败：%s"):format(tostring(tag), tostring(hooked)))
        return nil
    end
    if type(hooked) ~= "function" then
        acLog("hook", ("%s hook 返回值异常（%s）"):format(tostring(tag), tostring(hooked)))
        return nil
    end
    registerHook(original, hooked, repl, tag)
    acLog("hook", ("%s 已登记"):format(tostring(tag)))
    return hooked
end

--- 统一元方法 hook，三条降级路径：oth → hookmetamethod → rawset
function ACBridge.HookMetaMethod(object, method, replacement, tag)
    if type(object) == "nil" or type(replacement) ~= "function" then return nil end
    if AC.Unloaded or not AC.Enabled then return nil end
    local mt = safeRawMeta(object)
    local original = mt and rawget(mt, method)
    if type(original) ~= "function" then
        acLog("hook", ("%s：%s 不是函数，无法 hook"):format(tostring(tag), tostring(method)))
        return nil
    end
    local repl = toCClosure(hideStack(replacement))
    local ok, hooked
    if Cap.hookmetamethod then
        ok, hooked = pcall(hookmetamethod, object, method, repl)
    elseif mt then
        -- 最后手段：直接改写元表
        local wasReadonly = false
        if type(isreadonly) == "function" then
            local r = pcall(isreadonly, mt)
            wasReadonly = r and true or false
        end
        if wasReadonly and type(makewritable) == "function" then pcall(makewritable, mt) end
        ok, hooked = pcall(function()
            rawset(mt, method, repl)
            return original
        end)
        if wasReadonly and type(makereadonly) == "function" then pcall(makereadonly, mt) end
    end
    if not ok then
        acLog("hook", ("%s hook 失败：%s"):format(tostring(tag), tostring(hooked)))
        return nil
    end
    registerHook(original, type(hooked) == "function" and hooked or original, repl, tag)
    acLog("hook", ("%s（%s）已登记"):format(tostring(tag), tostring(method)))
    return type(hooked) == "function" and hooked or original
end

--- 手动登记（用于 oth 等不走 hookfunction 的路径），内部全程 pcall
function ACBridge.RegisterManual(original, hooked, tag)
    if type(original) ~= "function" then return false end
    local ok = pcall(registerHook, original, type(hooked) == "function" and hooked or original, hooked, tag)
    if ok then acLog("hook", ("%s 已登记（手动）"):format(tostring(tag))) end
    return ok
end

--- 还原全部登记过的 hook（顺序与安装相反无法保证，但每条都尽力还原）
function ACBridge.RestoreAll()
    local restored, failed = 0, 0
    for original, entry in pairs(HookRegistry) do
        local ok = pcall(entry.Restore, entry)
        if ok then restored = restored + 1 else failed = failed + 1 end
        HookRegistry[original] = nil
    end
    table.clear(HookRegistry)
    acLog("unload", ("hook 还原：成功 %d，失败 %d"):format(restored, failed))
    return restored, failed
end

-- ---------- 调用来源过滤 ----------
local function IsExecutorClosure(f)
    if type(f) ~= "function" then return false end
    if Cap.isexecutorclosure then
        local ok, res = pcall(isexecutorclosure, f)
        if ok and res ~= nil then return res == true end
    end
    return false
end

--- 多因素判断「这次调用来自执行器还是游戏脚本」
--- 单信 checkcaller 不可靠：它可能缺失、返回值错误，游戏侧也可能伪装
function ACBridge.IsExecutorCall()
    if Cap.checkcaller then
        local ok, res = pcall(checkcaller)
        if ok and res == true then return true end
    end
    if Cap.debuginfo then
        local ok, f = pcall(debug.info, 3, "f")
        if ok and IsExecutorClosure(f) then return true end
    end
    return false
end

-- ---------- Roblox 内部流量 / PlayerModule 过滤 ----------
local ACPlayers = nil
local RobloxReplicatedStorage = nil
local PlayerScriptsRef = nil
pcall(function()
    ACPlayers = cloneref(SafeGetService("Players"))
    RobloxReplicatedStorage = cloneref(SafeGetService("RobloxReplicatedStorage"))
end)

-- PlayerScripts 可能尚未生成：先取现成的，取不到就在 LocalPlayer 上等一次
local PlayerScriptsConnection = nil
local function resolvePlayerScripts()
    if PlayerScriptsRef then return PlayerScriptsRef end
    local lp = ACPlayers and ACPlayers.LocalPlayer
    if not lp then return nil end
    if PlayerScriptsConnection then
        pcall(function() PlayerScriptsConnection:Disconnect() end)
        PlayerScriptsConnection = nil
    end
    local ok, found = pcall(function() return lp:FindFirstChildOfClass("PlayerScripts") end)
    if ok and found then
        PlayerScriptsRef = cloneref(found)
        return PlayerScriptsRef
    end
    if not PlayerScriptsConnection then
        pcall(function()
            PlayerScriptsConnection = lp.ChildAdded:Connect(function(child)
                if child and child:IsA("PlayerScripts") then
                    PlayerScriptsRef = cloneref(child)
                    pcall(function() PlayerScriptsConnection:Disconnect() end)
                    PlayerScriptsConnection = nil
                end
            end)
        end)
    end
    return nil
end
resolvePlayerScripts()

local function IsPlayerModuleOrigin(origin)
    if typeof(origin) ~= "Instance" then return false end
    if not IsA(origin, "LuaSourceContainer") then return false end
    local ok, pm = pcall(function() return origin:FindFirstAncestor("PlayerModule") end)
    if not ok or not pm then return false end
    if pm.Parent == nil then return true end
    local ps = resolvePlayerScripts()
    if ps and typeof(ps) == "Instance" then
        return IsEqualToInstance(pm.Parent, ps)
    end
    return false
end

--- 是否应跳过这次调用（默认只按黑名单/拦截表判断，两个过滤项默认关闭）
function ACBridge.ShouldIgnore(remote)
    if remote == nil then return false end
    if configs.ignoreRobloxInternal and RobloxReplicatedStorage then
        local ok, res = pcall(function() return remote:IsDescendantOf(RobloxReplicatedStorage) end)
        if ok and res == true then return true end
    end
    -- 只在开关打开时才去取调用脚本，避免给热路径增加开销
    if configs.ignorePlayerModule then
        local origin = nil
        if Cap.getcallingscript then
            local ok2, script_ = pcall(getcallingscript)
            if ok2 and typeof(script_) == "Instance" then origin = script_ end
        end
        if IsPlayerModuleOrigin(origin) then return true end
    end
    return false
end

-- ============================================================================
-- 反作弊处置：Main 调度器 + 模块注册表
-- 接口与上游一致：{ Name, Game, Requires, Detect, Bypass }
--   Game == "*" → 通用模块；否则按 game.PlaceId 匹配为专用模块
--   Requires 声明依赖能力，缺失即跳过，绝不硬撑
-- ============================================================================
local ACModules = {}
local DedicatedModule = nil
local PlaceIdString = tostring(game.PlaceId)

local function registerACModule(mod)
    if type(mod) ~= "table" or type(mod.Detect) ~= "function" or type(mod.Bypass) ~= "function" then
        return
    end
    local game_ = mod.Game
    if type(game_) == "table" then
        for _, id in ipairs(game_) do
            if tostring(id) == PlaceIdString then
                DedicatedModule = mod
                return
            end
        end
    elseif tostring(game_) == PlaceIdString then
        DedicatedModule = mod
        return
    end
    if game_ == "*" then
        table.insert(ACModules, mod)
    end
end
ACBridge.RegisterModule = registerACModule

local function requirementsMet(mod)
    if type(mod.Requires) ~= "table" then return true end
    for _, name in ipairs(mod.Requires) do
        if not Cap[name] then
            acLog("ac", ("%s：缺少依赖 %s，跳过"):format(tostring(mod.Name), tostring(name)))
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Adonis：唯一在本次素材中可验证的 AC 实现
--   Detect：getreg() 中的线程源名匹配 .Core.Anti / .Plugins.Anti_Cheat
--   Bypass：关闭线程 → GC 中定位含 Detected + RLocked 的表 → 替换检测函数
-- ---------------------------------------------------------------------------
local Adonis = {
    Name = "Adonis",
    Game = "*",
    Requires = { "getreg", "getgc", "hookfunction", "isfunctionhooked", "debuginfo" },
}
ACBridge.Adonis = Adonis

local ADONIS_SOURCE_PATTERNS = { "%.Core%.Anti", "%.Plugins%.Anti_Cheat" }
local ADONIS_MAX_THREADS = 64
local ADONIS_MAX_TABLES = 32

local adonisThreads = {}
function Adonis.Detect()
    if not Cap.getreg or not Cap.debuginfo then return false end
    local ok, reg = pcall(getreg)
    if not ok or type(reg) ~= "table" then return false end
    local scanned = 0
    for _, value in pairs(reg) do
        if type(value) == "thread" then
            scanned = scanned + 1
            if scanned > ADONIS_MAX_THREADS then break end
            local sok, src = pcall(debug.info, value, 1, "s")
            if sok and type(src) == "string" then
                for _, pattern in ipairs(ADONIS_SOURCE_PATTERNS) do
                    if src:match(pattern) then
                        table.insert(adonisThreads, value)
                        break
                    end
                end
            end
        end
    end
    return #adonisThreads > 0
end

function Adonis.Bypass()
    local closed = 0
    -- 第一步：关闭已识别的 AC 线程
    if Cap.coroutineclose then
        for _, thread in ipairs(adonisThreads) do
            if pcall(coroutine.close, thread) then closed = closed + 1 end
        end
    end
    table.clear(adonisThreads)

    -- 第二步：从 GC 中定位含 Detected + RLocked 的表
    local candidates = {}
    if Cap.filtergc then
        local ok, found = pcall(filtergc, "table", { Keys = { "Detected", "RLocked" } }, false)
        if ok and type(found) == "table" then
            for _, t in pairs(found) do
                if type(t) == "table" and type(rawget(t, "Detected")) == "function" then
                    table.insert(candidates, t)
                    if #candidates >= ADONIS_MAX_TABLES then break end
                end
            end
        end
    end
    if #candidates == 0 and Cap.getgc then
        local ok, gc = pcall(getgc, true)
        if ok and type(gc) == "table" then
            for _, t in pairs(gc) do
                if type(t) == "table"
                    and type(rawget(t, "Detected")) == "function"
                    and rawget(t, "RLocked") then
                    table.insert(candidates, t)
                    if #candidates >= ADONIS_MAX_TABLES then break end
                end
            end
        end
    end
    if #candidates == 0 then
        return closed > 0
    end

    -- 第三步：替换检测函数，让它永远让出，无法完成上报
    local hooked = 0
    for _, tbl in ipairs(candidates) do
        for _, fn in pairs(tbl) do
            if type(fn) == "function" then
                local skip = false
                if Cap.isfunctionhooked then
                    local ok, already = pcall(isfunctionhooked, fn)
                    if ok and already == true then skip = true end
                end
                if not skip then
                    local replacement = toCClosure(hideStack(function(action, info, nocrash)
                        pcall(coroutine.yield)
                        return task.wait(9e9)
                    end))
                    local ok2, hookedFn = pcall(hookfunction, fn, replacement)
                    if ok2 and type(hookedFn) == "function" then
                        registerHook(fn, hookedFn, replacement, "Adonis.Detected")
                        hooked = hooked + 1
                    end
                end
            end
        end
    end
    AC.AdonisHooked = hooked
    return hooked > 0 or closed > 0
end

registerACModule(Adonis)

local function runACDispatch()
    if not configs.acBypass then
        acLog("ac", "AC 处置已由配置关闭")
        return
    end
    -- 专用模块优先（按 PlaceId 命中）
    if DedicatedModule and requirementsMet(DedicatedModule) then
        local dok, detected = pcall(DedicatedModule.Detect)
        if dok and detected == true then
            local bok, bypassed = pcall(DedicatedModule.Bypass)
            if bok and bypassed ~= false then
                AC.Name = DedicatedModule.Name or "Dedicated"
                AC.Disabled = true
                table.insert(AC.Applied, AC.Name)
                acLog("ac", ("已处置专用 AC：%s"):format(AC.Name))
                return
            end
            acLog("ac", ("专用 AC %s 处置失败"):format(tostring(DedicatedModule.Name)))
        end
    end
    -- 通用模块兜底
    for _, mod in ipairs(ACModules) do
        if requirementsMet(mod) then
            local dok, detected = pcall(mod.Detect)
            if dok and detected == true then
                local bok, bypassed = pcall(mod.Bypass)
                if bok and bypassed ~= false then
                    AC.Name = mod.Name or "Unknown"
                    AC.Disabled = true
                    table.insert(AC.Applied, AC.Name)
                    acLog("ac", ("已处置 AC：%s"):format(AC.Name))
                    break
                end
                acLog("ac", ("%s 检测命中但处置失败"):format(tostring(mod.Name)))
            end
        end
    end
    if not AC.Disabled then
        acLog("ac", "未命中任何已登记的客户端 AC")
    end
end

-- ============================================================================
-- Actor 侧捕获（已实现，默认关闭）
--   主 VM 的 __namecall hook 看不到 Actor 内部的 Remote；
--   但部分执行器 run_on_actor 会崩溃，故默认关闭，需手动开启。
-- ============================================================================
local ActorState = { Channel = nil, ChannelId = nil, Relay = nil, Connection = nil, Sent = 0 }

local ACTOR_SOURCE = [[
local ChannelId = ...
local ok, Channel = pcall(get_comm_channel, ChannelId)
if not ok or not Channel then return end
local Hooked = false
local mt = getrawmetatable and getrawmetatable(game)
local original = mt and rawget(mt, "__namecall")
if type(original) ~= "function" then return end
local wrap = newcclosure or function(f) return f end
local replacement
replacement = wrap(function(...)
    local method = getnamecallmethod and getnamecallmethod() or nil
    if method == "FireServer" or method == "InvokeServer" then
        local remote = (...)
        if typeof(remote) == "Instance" then
            pcall(Channel.Fire, Channel, "ActorCall", remote, method, select("#", ...) - 1)
        end
    end
    return original(...)
end)
if setstackhidden then pcall(setstackhidden, replacement, true) end
if hookmetamethod then
    Hooked = pcall(hookmetamethod, game, "__namecall", replacement)
elseif hookfunction then
    Hooked = pcall(hookfunction, original, replacement)
end
local conn
conn = Channel.Event:Connect(function(kind)
    if kind == "Unload" then
        pcall(function() conn:Disconnect() end)
    end
end)
]]

local function startActorBridge()
    if AC.ActorBridge then return true end
    if not (Cap.run_on_actor and Cap.getactors and Cap.create_comm_channel and Cap.get_comm_channel) then
        acLog("actor", "Actor 捕获所需能力缺失，已跳过")
        return false
    end
    local okCreate, channel = pcall(create_comm_channel, "SimpleSpyActorRelay")
    if not okCreate or type(channel) ~= "table" then
        acLog("actor", ("创建 Actor 通道失败：%s"):format(tostring(channel)))
        return false
    end
    ActorState.Channel = channel
    ActorState.Relay = channel
    pcall(function()
        ActorState.Connection = channel.Event:Connect(function(kind, remote, method, argCount)
            if kind ~= "ActorCall" then return end
            -- 只登记「Actor 侧发生过调用」，参数无法跨 VM 完整还原
            ActorState.Sent = ActorState.Sent + 1
            if typeof(remote) == "Instance" and type(ACBridge.Dispatch) == "function" then
                pcall(ACBridge.Dispatch, {
                    method = type(method) == "string" and method or "FireServer",
                    remote = remote,
                    args = {},
                    infofunc = nil,
                    callingscript = nil,
                    metamethod = "__namecall",
                    blockcheck = false,
                    returnvalue = {},
                    actor = true,
                })
            end
        end)
    end)
    local okActors, actors = pcall(getactors)
    if not okActors or type(actors) ~= "table" then
        acLog("actor", "getactors 返回异常")
        return false
    end
    for _, actor in ipairs(actors) do
        pcall(run_on_actor, actor, ACTOR_SOURCE, "SimpleSpyActorRelay")
    end
    AC.ActorBridge = true
    acLog("actor", ("Actor 桥接已启动，覆盖 %d 个 Actor"):format(#actors))
    return true
end

local function stopActorBridge()
    if not AC.ActorBridge then return end
    pcall(function()
        if ActorState.Channel and ActorState.Channel.Fire then
            ActorState.Channel:Fire("Unload")
        end
    end)
    pcall(function()
        if ActorState.Connection then ActorState.Connection:Disconnect() end
    end)
    ActorState.Channel, ActorState.Connection = nil, nil
    AC.ActorBridge = false
    acLog("actor", "Actor 桥接已停止")
end

ACBridge.StartActorBridge = startActorBridge
ACBridge.StopActorBridge = stopActorBridge

-- 由主脚本在 remoteHandler / schedule / ThreadGetDebugId 就绪后注入，
-- 避免在基础设施层直接引用尚未声明的 local
ACBridge.Dispatch = nil

-- ---------- 诊断与开关 ----------
function ACBridge.GetStatusText()
    local lines = {
        ("执行器：%s"):format(ExecutorName),
        ("AC 处置：%s%s"):format(
            configs.acBypass and "启用" or "关闭",
            AC.Disabled and ("（已处置 %s）"):format(AC.Name) or "（未命中）"
        ),
        ("Actor 捕获：%s"):format(AC.ActorBridge and "启用" or "关闭"),
        ("已登记 hook：%d"):format((function()
            local n = 0
            for _ in pairs(HookRegistry) do n = n + 1 end
            return n
        end)()),
        ("缺失的降风险能力：%s"):format(#AC.Risks > 0 and table.concat(AC.Risks, ", ") or "无"),
    }
    return table.concat(lines, "\n")
end

function ACBridge.GetBufferText()
    return table.concat(AC.Buffer, "\n")
end

-- ---------- 生命周期 ----------
function ACBridge.Init()
    if AC.Initialized then return end
    AC.Initialized = true
    -- 早于 Remote hook 安装，避免自身 hook 被 AC 记录为异常
    local ok, err = pcall(runACDispatch)
    if not ok then
        acLog("ac", ("AC 调度异常：%s"):format(tostring(err)))
    end
    if configs.actorBridge then
        local aok, aerr = pcall(startActorBridge)
        if not aok then acLog("actor", ("Actor 桥接异常：%s"):format(tostring(aerr))) end
    end
end

function ACBridge.Unload()
    if AC.Unloaded then return end
    AC.Unloaded = true
    pcall(stopActorBridge)
    pcall(function()
        if PlayerScriptsConnection then PlayerScriptsConnection:Disconnect() end
    end)
    pcall(ACBridge.RestoreAll)
    pcall(function() table.clear(AC.Buffer) end)
end

local function Search(logtable,tbl)
    table.insert(logtable,tbl)

    for i,v in tbl do
        if type(v) == "table" then
            if table.find(logtable,v) ~= nil then
                return true
            end
            local found = Search(logtable, v)
            if found then
                return true
            end
        end
    end
    return false
end

local function IsCyclicTable(tbl)
    local checkedtables = {}

    local function SearchTable(tbl)
        table.insert(checkedtables,tbl)

        for i,v in next, tbl do -- 这里原先是我犯的低级错误，感谢 59it 指出
            if type(v) == "table" then
                if table.find(checkedtables,v) then
                    return true
                end
                local found = SearchTable(v)
                if found then
                    return true
                end
            end
        end
        return false
    end

    return SearchTable(tbl)
end

local function deepclone(args: table, copies: table): table
    local copy = nil
    copies = copies or {}

    if type(args) == 'table' then
        if copies[args] then
            copy = copies[args]
        else
            copy = {}
            copies[args] = copy
            for i, v in next, args do
                copy[deepclone(i, copies)] = deepclone(v, copies)
            end
        end
    elseif typeof(args) == "Instance" then
        copy = cloneref(args)
    else
        copy = args
    end
    return copy
end

local function rawtostring(userdata)
    if type(userdata) == "table" or typeof(userdata) == "userdata" then
        local rawmetatable = getrawmetatable(userdata)
        local cachedstring = rawmetatable and rawget(rawmetatable, "__tostring")

        if cachedstring then
            local wasreadonly = isreadonly(rawmetatable)
            if wasreadonly then
                makewritable(rawmetatable)
            end
            rawset(rawmetatable, "__tostring", nil)
            local safestring = tostring(userdata)
            rawset(rawmetatable, "__tostring", cachedstring)
            if wasreadonly then
                makereadonly(rawmetatable)
            end
            return safestring
        end
    end
    return tostring(userdata)
end

local CoreGui = SafeGetService("CoreGui")
local Players = SafeGetService("Players")
local RunService = SafeGetService("RunService")
local UserInputService = SafeGetService("UserInputService")
local TweenService = SafeGetService("TweenService")
local ContentProvider = SafeGetService("ContentProvider")
local TextService = SafeGetService("TextService")
local http = SafeGetService("HttpService")
local GuiInset = game:GetService("GuiService"):GetGuiInset() :: Vector2 -- 取自重写版

local function jsone(str) return http:JSONEncode(str) end
local function jsond(str)
    local suc,err = pcall(http.JSONDecode,http,str)
    return suc and err or suc
end

function ErrorPrompt(Message,state)
    if getrenv then
        local ErrorPrompt = getrenv().require(CoreGui:WaitForChild("RobloxGui"):WaitForChild("Modules"):WaitForChild("ErrorPrompt")) -- 该文件可在你的 Roblox 安装目录中找到 (C:\Users\%Username%\AppData\Local\Roblox\Versions\whateverversionitis\ExtraContent\scripts\CoreScripts\Modules)
        local prompt = ErrorPrompt.new("Default",{HideErrorCode = true})
        local ErrorStoarge = Create("ScreenGui",{Parent = CoreGui,ResetOnSpawn = false})
        local thread = state and running()
        prompt:setParent(ErrorStoarge)
        prompt:setErrorTitle("Simple Spy V3 错误")
        prompt:updateButtons({{
            Text = "继续",
            Callback = function()
                prompt:_close()
                ErrorStoarge:Destroy()
                if thread then
                    resume(thread)
                end
            end,
            Primary = true
        }}, 'Default')
        prompt:_open(Message)
        if thread then
            yield(thread)
        end
    else
        warn(Message)
    end
end

local function safeLoadRemote(url, label)
    local ok, src = pcall(function() return game:HttpGet(url) end)
    if not ok or type(src) ~= "string" then
        warn(("SimpleSpy：从 %s 加载 %s 失败（%s）"):format(label, url, tostring(src)))
        return nil
    end
    local fn, err = loadstring(src)
    if not fn then
        warn(("SimpleSpy：编译 %s 失败（%s）"):format(label, tostring(err)))
        return nil
    end
    local ok2, result = pcall(fn)
    if not ok2 then
        warn(("SimpleSpy：运行 %s 失败（%s）"):format(label, tostring(result)))
        return nil
    end
    return result
end

local function safeLoadFile(path)
    if not (isfile and loadfile and isfile(path)) then return nil end
    local ok, fn = pcall(loadfile, path)
    if not ok or type(fn) ~= "function" then return nil end
    local ok2, result = pcall(fn)
    if not ok2 then return nil end
    return result
end

local Highlight = safeLoadFile("Highlight.lua") or safeLoadRemote("https://raw.githubusercontent.com/infyiff/backup/refs/heads/main/SimpleSpyV3/highlight.lua", "Highlight")
local LazyFix = safeLoadRemote("https://raw.githubusercontent.com/infyiff/backup/refs/heads/main/SimpleSpyV3/DataToCode.lua", "DataToCode") -- 非常偷懒的修法，其实就是从重写版直接搬过来的

-- ============================================================
-- 增强反编译器（方案移植自 DEX++ / 原作者 Karisob & Ccat）
-- ------------------------------------------------------------
-- 原版 SimpleSpy 直接调用注入器的 decompile 全局，质量完全取决于
-- 执行器：部分执行器会返回残缺、混淆甚至空字符串（俗称"忍者反编译"）。
-- 这里改为：只用执行器的 getscriptbytecode() 读取原始字节码，
-- 反编译过程交给纯 Luau 实现的反编译器在本地完成，不依赖执行器质量。
-- ============================================================
local getscriptbytecode = getscriptbytecode or (syn and syn.getscriptbytecode) or (cache and cache.getscriptbytecode)

-- 关键：必须在覆盖全局之前保存执行器原生 decompile。
-- 否则下面 doDecompile 里的"回退原生"会再次拿到已被覆盖的增强版，形成自我调用。
local nativeDecompile = type(decompile) == "function" and decompile or nil

local KARI_URL = "https://raw.githubusercontent.com/lIllIIlII/OpenSource/refs/heads/main/Kari%26Ccat.lua"
local EnhancedDecompile = nil   -- 增强反编译函数，加载失败则为 nil
local EnhancedTried = 0         -- 已尝试加载的次数
local EnhancedMaxRetry = 3      -- 最多重试几次，避免网络抖动导致永久失效
local EnhancedError = nil       -- 最近一次失败原因

-- 增强通道返回的是"注释形式的错误文本"而非 nil，需要用特征串识别，
-- 否则会被当成成功结果：既不触发回退，还会被写进缓存。
local ENHANCED_FAIL_MARKERS = {
    "-- 读取字节码失败",
    "-- 反编译过程出错",
}

local function isEnhancedFailure(s)
    if type(s) ~= "string" or #s == 0 then return true end
    for _, m in ipairs(ENHANCED_FAIL_MARKERS) do
        if s:sub(1, #m) == m then return true end
    end
    return false
end

--- 判断某个脚本是否有可能被反编译（客户端才能拿到字节码）
local function isViableDecompileScript(obj)
    if typeof(obj) ~= "Instance" then return false end
    local okIs, isLSC = pcall(function() return obj:IsA("LuaSourceContainer") end)
    if not okIs or not isLSC then return false end

    -- RunContext 在部分环境/旧版本上可能读不到，读不到就放行，交给后续实际尝试
    local okRC, rc = pcall(function() return obj.RunContext end)
    if not okRC then return true end

    if obj:IsA("ModuleScript") then
        return true
    elseif obj:IsA("LocalScript") then
        return rc == Enum.RunContext.Client or rc == Enum.RunContext.Legacy
    elseif obj:IsA("Script") then
        return rc == Enum.RunContext.Client
    end
    return false
end

--- 加载纯 Luau 反编译器，成功返回 decompile 函数
local function loadEnhancedDecompiler()
    if EnhancedDecompile then return EnhancedDecompile end
    if EnhancedTried >= EnhancedMaxRetry then return nil end
    EnhancedTried = EnhancedTried + 1

    if not getscriptbytecode then
        EnhancedError = "执行器不支持 getscriptbytecode，无法启用增强反编译"
        warn("[SimpleSpy] " .. EnhancedError)
        return nil
    end

    local fetchOk, src = pcall(function() return game:HttpGet(KARI_URL, true) end)
    if not fetchOk or type(src) ~= "string" or src == "" then
        EnhancedError = ("下载反编译器失败：%s"):format(tostring(src))
        warn("[SimpleSpy] " .. EnhancedError)
        return nil
    end

    local loadOk, fn = pcall(loadstring, src, "KariCcat")
    if not loadOk or type(fn) ~= "function" then
        EnhancedError = ("反编译器源码编译失败：%s"):format(tostring(fn))
        warn("[SimpleSpy] " .. EnhancedError)
        return nil
    end

    local runOk, Module = pcall(fn)
    if not runOk or type(Module) ~= "table" or type(Module.decompile) ~= "function" then
        EnhancedError = ("反编译器未返回有效模块：%s"):format(tostring(Module))
        warn("[SimpleSpy] " .. EnhancedError)
        return nil
    end

    local Mod = Module
    EnhancedDecompile = function(scriptObj)
        -- 第一步：从 Roblox 脚本读取原始字节码
        local bcOk, bytecode = pcall(getscriptbytecode, scriptObj)
        if not bcOk or type(bytecode) ~= "string" or #bytecode == 0 then
            return ("-- 读取字节码失败。\n--[[\n%s\n--]]"):format(tostring(bytecode))
        end
        -- 第二步：交给本地纯 Luau 反编译器还原源码
        local ok, source = pcall(Mod.decompile, bytecode, { mode = "source" })
        if not ok or type(source) ~= "string" then
            return ("-- 反编译过程出错：\n--[[\n%s\n--]]"):format(tostring(source))
        end
        return source
    end

    -- 覆盖全局 decompile 仅在显式开启时进行：
    -- 默认关闭，避免污染全局，也避免被其他脚本/AC 通过比较函数身份发现异常。
    -- 需要给外部用时把 configs.overrideGlobalDecompile 置为 true 再加载。
    if configs.overrideGlobalDecompile then
        getgenv().decompile = EnhancedDecompile
    end
    return EnhancedDecompile
end

--- 统一入口：优先增强反编译，失败自动退回执行器原生 decompile
local function doDecompile(scriptObj)
    if not isViableDecompileScript(scriptObj) then
        return nil, "该脚本不在客户端运行，无法读取字节码"
    end

    local enhanced = loadEnhancedDecompiler()
    if enhanced then
        local ok, out = pcall(enhanced, scriptObj)
        if ok and not isEnhancedFailure(out) then
            return out, nil
        end
        local reason = ok and tostring(out) or tostring(out)
        if nativeDecompile then
            local ok2, out2 = pcall(nativeDecompile, scriptObj)
            if ok2 and type(out2) == "string" and #out2 > 0 then
                return out2, ("增强反编译未成功，已回退原生：%s"):format(reason)
            end
        end
        return nil, reason
    end

    if nativeDecompile then
        local ok3, out3 = pcall(nativeDecompile, scriptObj)
        if ok3 and type(out3) == "string" and #out3 > 0 then
            return out3, EnhancedError and ("已使用原生反编译：%s"):format(EnhancedError) or nil
        end
        return nil, tostring(out3)
    end
    return nil, EnhancedError or "当前环境没有任何可用的反编译器"
end

-- 后台预热，避免首次点击时卡顿
spawn(function()
    loadEnhancedDecompiler()
end)


local SimpleSpy3 = Create("ScreenGui",{ResetOnSpawn = false})
local Storage = Create("Folder",{})
local Background = Create("Frame",{Parent = SimpleSpy3,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 500, 0, 200),Size = UDim2.new(0, 450, 0, 268)})
local LeftPanel = Create("Frame",{Parent = Background,BackgroundColor3 = Color3.fromRGB(53, 52, 55),BorderSizePixel = 0,Position = UDim2.new(0, 0, 0, 19),Size = UDim2.new(0, 131, 0, 249)})
local LogList = Create("ScrollingFrame",{Parent = LeftPanel,Active = true,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,BorderSizePixel = 0,Position = UDim2.new(0, 0, 0, 9),Size = UDim2.new(0, 131, 0, 232),CanvasSize = UDim2.new(0, 0, 0, 0),ScrollBarThickness = 4})
local UIListLayout = Create("UIListLayout",{Parent = LogList,HorizontalAlignment = Enum.HorizontalAlignment.Center,SortOrder = Enum.SortOrder.LayoutOrder})
local RightPanel = Create("Frame",{Parent = Background,BackgroundColor3 = Color3.fromRGB(37, 36, 38),BorderSizePixel = 0,Position = UDim2.new(0, 131, 0, 19),Size = UDim2.new(0, 319, 0, 249)})
local CodeBox = Create("Frame",{Parent = RightPanel,BackgroundColor3 = Color3.new(0.0823529, 0.0745098, 0.0784314),BorderSizePixel = 0,Size = UDim2.new(0, 319, 0, 119)})
local ScrollingFrame = Create("ScrollingFrame",{Parent = RightPanel,Active = true,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 0, 0.5, 0),Size = UDim2.new(1, 0, 0.5, -9),CanvasSize = UDim2.new(0, 0, 0, 0),ScrollBarThickness = 4})
local UIGridLayout = Create("UIGridLayout",{Parent = ScrollingFrame,HorizontalAlignment = Enum.HorizontalAlignment.Center,SortOrder = Enum.SortOrder.LayoutOrder,CellPadding = UDim2.new(0, 0, 0, 0),CellSize = UDim2.new(0, 94, 0, 27)})
local TopBar = Create("Frame",{Parent = Background,BackgroundColor3 = Color3.fromRGB(37, 35, 38),BorderSizePixel = 0,Size = UDim2.new(0, 450, 0, 19)})
local Simple = Create("TextButton",{Parent = TopBar,BackgroundColor3 = Color3.new(1, 1, 1),AutoButtonColor = false,BackgroundTransparency = 1,Position = UDim2.new(0, 5, 0, 0),Size = UDim2.new(0, 57, 0, 18),Font = Enum.Font.SourceSansBold,Text =  "SimpleSpy",TextColor3 = Color3.new(1, 1, 1),TextSize = 14,TextXAlignment = Enum.TextXAlignment.Left})
local CloseButton = Create("TextButton",{Parent = TopBar,BackgroundColor3 = Color3.new(0.145098, 0.141176, 0.14902),BorderSizePixel = 0,Position = UDim2.new(1, -19, 0, 0),Size = UDim2.new(0, 19, 0, 19),Font = Enum.Font.SourceSans,Text = "",TextColor3 = Color3.new(0, 0, 0),TextSize = 14})
local ImageLabel = Create("ImageLabel",{Parent = CloseButton,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 5, 0, 5),Size = UDim2.new(0, 9, 0, 9),Image = "http://www.roblox.com/asset/?id=5597086202"})
local MaximizeButton = Create("TextButton",{Parent = TopBar,BackgroundColor3 = Color3.new(0.145098, 0.141176, 0.14902),BorderSizePixel = 0,Position = UDim2.new(1, -38, 0, 0),Size = UDim2.new(0, 19, 0, 19),Font = Enum.Font.SourceSans,Text = "",TextColor3 = Color3.new(0, 0, 0),TextSize = 14})
local ImageLabel_2 = Create("ImageLabel",{Parent = MaximizeButton,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 5, 0, 5),Size = UDim2.new(0, 9, 0, 9),Image = "http://www.roblox.com/asset/?id=5597108117"})
local MinimizeButton = Create("TextButton",{Parent = TopBar,BackgroundColor3 = Color3.new(0.145098, 0.141176, 0.14902),BorderSizePixel = 0,Position = UDim2.new(1, -57, 0, 0),Size = UDim2.new(0, 19, 0, 19),Font = Enum.Font.SourceSans,Text = "",TextColor3 = Color3.new(0, 0, 0),TextSize = 14})
local ImageLabel_3 = Create("ImageLabel",{Parent = MinimizeButton,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 5, 0, 5),Size = UDim2.new(0, 9, 0, 9),Image = "http://www.roblox.com/asset/?id=5597105827"})

local ToolTip = Create("Frame",{Parent = SimpleSpy3,BackgroundColor3 = Color3.fromRGB(26, 26, 26),BackgroundTransparency = 0.1,BorderColor3 = Color3.new(1, 1, 1),Size = UDim2.new(0, 200, 0, 50),ZIndex = 3,Visible = false})
local TextLabel = Create("TextLabel",{Parent = ToolTip,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 2, 0, 2),Size = UDim2.new(0, 196, 0, 46),ZIndex = 3,Font = Enum.Font.SourceSans,Text = "这是一段稍长一些的文本。",TextColor3 = Color3.new(1, 1, 1),TextSize = 14,TextWrapped = true,TextXAlignment = Enum.TextXAlignment.Left,TextYAlignment = Enum.TextYAlignment.Top})

-------------------------------------------------------------------------------

local selectedColor = Color3.new(0.321569, 0.333333, 1)
local deselectedColor = Color3.new(0.8, 0.8, 0.8)
--- 让条目按降序排列
local layoutOrderNum = 999999999
--- 主界面是否正在关闭
local mainClosing = false
--- 主界面是否已关闭（默认 false）
local closed = false
--- 侧栏是否正在收起
local sideClosing = false
--- 侧栏是否已收起（默认 true，但选中远程项时会自动展开）
local sideClosed = false
--- 代码框是否已最大化（默认 false）
local maximized = false
--- 供读取的事件日志
local logs = {}
--- 当前选中的事件日志项（默认 nil）
local selected = nil
--- 黑名单（可以是名称字符串或远程对象实例）
local blacklist = {}
--- 拦截列表（可以是名称字符串或远程对象实例）
local blocklist = {}
--- 是否添加 getNil 函数
local getNil = false
--- 已连接的远程对象（及其原始函数）数组
local connectedRemotes = {}
--- true = 使用 hookfunction，false = 使用 namecall
local toggle = false
--- 用于防止递归
local prevTables = {}
--- 保存日志条目（便于删除）
local remoteLogs = {}
--- 供 hookfunction 使用
getgenv().SIMPLESPYCONFIG_MaxRemotes = 300
local indent = 4
local scheduled = {}
local schedulerconnect
local SimpleSpy = {}
local topstr = ""
local bottomstr = ""
local remotesFadeIn
local rightFadeIn
local codebox
local p
local getnilrequired = false

--- 安全取代码框文本：Highlight 形态下未必有 getString，需多层回退
--- （必须定义在 local codebox 之后才能捕获到该 upvalue）
local function getCodeBoxText()
    if not codebox then return "" end
    if type(codebox.getString) == "function" then
        local ok, res = pcall(codebox.getString, codebox)
        if ok and type(res) == "string" then return res end
        ok, res = pcall(codebox.getString)
        if ok and type(res) == "string" then return res end
    end
    local box = rawget(codebox, "_box") or rawget(codebox, "box")
    if box and type(box.Text) == "string" then return box.Text end
    if typeof(codebox) == "Instance" and codebox:IsA("TextBox") then
        return codebox.Text
    end
    return ""
end

-- 自动拦截相关变量
local history = {}
local excluding = {}

-- 鼠标是否位于界面内
local mouseInGui = false

local connections = {}
local DecompiledScripts = {}
local generation = {}
local running_threads = {}
local originalnamecall
local namecallOriginal = nil -- captured once, never mutated, used for clean unhook

local remoteEvent = Instance.new("RemoteEvent",Storage)
local unreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
local remoteFunction = Instance.new("RemoteFunction",Storage)
local NamecallHandler = Instance.new("BindableEvent",Storage)
local IndexHandler = Instance.new("BindableEvent",Storage)
local GetDebugIdHandler = Instance.new("BindableFunction",Storage) --感谢 engo 提出使用 BindableFunctions 的思路

local originalEvent = remoteEvent.FireServer
local originalUnreliableEvent = unreliableRemoteEvent.FireServer
local originalFunction = remoteFunction.InvokeServer
local GetDebugIDInvoke = GetDebugIdHandler.Invoke

function GetDebugIdHandler.OnInvoke(obj: Instance) -- 这样就不必再去设置线程身份之类
    return OldDebugId(obj)
end

local function ThreadGetDebugId(obj: Instance): string 
    return GetDebugIDInvoke(GetDebugIdHandler,obj) -- 用索引方式，避免之后再调用 setnamecall
end

local synv3 = false

if syn and identifyexecutor then
    local _, version = identifyexecutor()
    if (version and version:sub(1, 2) == 'v3') then
        synv3 = true
    end
end

xpcall(function()
    if isfile and readfile and isfolder and makefolder then
        local cachedconfigs = isfile("SimpleSpy//Settings.json") and jsond(readfile("SimpleSpy//Settings.json"))

        if cachedconfigs then
            for i,v in next, realconfigs do
                if cachedconfigs[i] == nil then
                    cachedconfigs[i] = v
                end
            end
            realconfigs = cachedconfigs
        end

        if not isfolder("SimpleSpy") then
            makefolder("SimpleSpy")
        end
        if not isfolder("SimpleSpy//Assets") then
            makefolder("SimpleSpy//Assets")
        end
        if not isfile("SimpleSpy//Settings.json") then
            writefile("SimpleSpy//Settings.json",jsone(realconfigs))
        end

        configsmetatable.__newindex = function(self,index,newindex)
            realconfigs[index] = newindex
            writefile("SimpleSpy//Settings.json",jsone(realconfigs))
        end
    else
        configsmetatable.__newindex = function(self,index,newindex)
            realconfigs[index] = newindex
        end
    end
end,function(err)
    ErrorPrompt(("发生错误：(%s)"):format(err))
end)

local function logthread(thread: thread)
    table.insert(running_threads,thread)
end

--- 防止远程调用刷屏造成卡顿（超过 `getgenv().SIMPLESPYCONFIG_MaxRemotes` 或 500 条后清理日志）
function clean()
    local max = getgenv().SIMPLESPYCONFIG_MaxRemotes
    if typeof(max) ~= "number" or math.floor(max) ~= max then
        max = 500
    end
    if #remoteLogs > max then
        -- 保留最新的 `max` 条，丢弃最旧的
        local dropCount = #remoteLogs - max
        for i = 1, dropCount do
            local v = remoteLogs[i]
            if typeof(v[1]) == "RBXScriptConnection" then
                v[1]:Disconnect()
            end
            if typeof(v[2]) == "Instance" then
                v[2]:Destroy()
            end
            -- 同时移除对应的日志条目，避免持有已销毁的界面对象
            local frame = v[2]
            for li = #logs, 1, -1 do
                if logs[li].Log == frame then
                    table.remove(logs, li)
                    break
                end
            end
        end
        local newLogs = {}
        for i = dropCount + 1, #remoteLogs do
            table.insert(newLogs, remoteLogs[i])
        end
        remoteLogs = newLogs
    end
end

local function ThreadIsNotDead(thread: thread): boolean
    return not status(thread) == "dead"
end

--- 调整提示框尺寸以适配其中的文字
function scaleToolTip()
    local size = TextService:GetTextSize(TextLabel.Text, TextLabel.TextSize, TextLabel.Font, Vector2.new(196, math.huge))
    TextLabel.Size = UDim2.new(0, size.X, 0, size.Y)
    ToolTip.Size = UDim2.new(0, size.X + 4, 0, size.Y + 4)
end

--- 鼠标悬浮在开关按钮（SimpleSpy 标志）上时执行
function onToggleButtonHover()
    if not toggle then
        TweenService:Create(Simple, TweenInfo.new(0.5), {TextColor3 = Color3.fromRGB(252, 51, 51)}):Play()
    else
        TweenService:Create(Simple, TweenInfo.new(0.5), {TextColor3 = Color3.fromRGB(68, 206, 91)}):Play()
    end
end

--- 鼠标离开开关按钮时执行
function onToggleButtonUnhover()
    TweenService:Create(Simple, TweenInfo.new(0.5), {TextColor3 = Color3.fromRGB(255, 255, 255)}):Play()
end

--- 鼠标悬浮在关闭按钮上时执行
function onXButtonHover()
    TweenService:Create(CloseButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(255, 60, 60)}):Play()
end

--- 鼠标离开关闭按钮时执行
function onXButtonUnhover()
    TweenService:Create(CloseButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(37, 36, 38)}):Play()
end

--- 切换远程监听方式（点击按钮时）
function onToggleButtonClick()
    if toggle then
        TweenService:Create(Simple, TweenInfo.new(0.5), {TextColor3 = Color3.fromRGB(252, 51, 51)}):Play()
    else
        TweenService:Create(Simple, TweenInfo.new(0.5), {TextColor3 = Color3.fromRGB(68, 206, 91)}):Play()
    end
    toggleSpyMethod()
end

--- 视口变化时重连 bringBackOnResize，并在首次运行时建立连接
function connectResize()
    if not workspace.CurrentCamera then
        workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
    end
    local lastCam = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(bringBackOnResize)
    workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        lastCam:Disconnect()
        if typeof(lastCam) == 'Connection' then
            lastCam:Disconnect()
        end
        lastCam = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(bringBackOnResize)
    end)
end

--- 界面被移出屏幕时把它拉回来（绑定在相机视口变化上）
function bringBackOnResize()
    validateSize()
    if sideClosed then
        minimizeSize()
    else
        maximizeSize()
    end
    local currentX = Background.AbsolutePosition.X
    local currentY = Background.AbsolutePosition.Y
    local viewportSize = workspace.CurrentCamera.ViewportSize
    if (currentX < 0) or (currentX > (viewportSize.X - (sideClosed and 131 or Background.AbsoluteSize.X))) then
        if currentX < 0 then
            currentX = 0
        else
            currentX = viewportSize.X - (sideClosed and 131 or Background.AbsoluteSize.X)
        end
    end
    if (currentY < 0) or (currentY > (viewportSize.Y - (closed and 19 or Background.AbsoluteSize.Y) - GuiInset.Y)) then
        if currentY < 0 then
            currentY = 0
        else
            currentY = viewportSize.Y - (closed and 19 or Background.AbsoluteSize.Y) - GuiInset.Y
        end
    end
    TweenService.Create(TweenService, Background, TweenInfo.new(0.1), {Position = UDim2.new(0, currentX, 0, currentY)}):Play()
end

--- 拖动界面（鼠标按住期间）
--- @param input InputObject
function onBarInput(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        local lastPos = UserInputService:GetMouseLocation()
        local mainPos = Background.AbsolutePosition
        local offset = mainPos - lastPos
        local currentPos = offset + lastPos
        if not connections["drag"] then
            connections["drag"] = RunService.RenderStepped:Connect(function()
                local newPos = UserInputService:GetMouseLocation()
                if newPos ~= lastPos then
                    local currentX = (offset + newPos).X
                    local currentY = (offset + newPos).Y
                    local viewportSize = workspace.CurrentCamera.ViewportSize
                    if (currentX < 0 and currentX < currentPos.X) or (currentX > (viewportSize.X - (sideClosed and 131 or TopBar.AbsoluteSize.X)) and currentX > currentPos.X) then
                        if currentX < 0 then
                            currentX = 0
                        else
                            currentX = viewportSize.X - (sideClosed and 131 or TopBar.AbsoluteSize.X)
                        end
                    end
                    if (currentY < 0 and currentY < currentPos.Y) or (currentY > (viewportSize.Y - (closed and 19 or Background.AbsoluteSize.Y) - GuiInset.Y) and currentY > currentPos.Y) then
                        if currentY < 0 then
                            currentY = 0
                        else
                            currentY = viewportSize.Y - (closed and 19 or Background.AbsoluteSize.Y) - GuiInset.Y
                        end
                    end
                    currentPos = Vector2.new(currentX, currentY)
                    lastPos = newPos
                    TweenService.Create(TweenService, Background, TweenInfo.new(0.1), {Position = UDim2.new(0, currentPos.X, 0, currentPos.Y)}):Play()
                end
                    -- if input.UserInputState ~= Enum.UserInputState.Begin then
                    --     RunService.UnbindFromRenderStep(RunService, "drag")
                    -- end
            end)
        end
        table.insert(connections, UserInputService.InputEnded:Connect(function(inputE)
            if input == inputE then
                if connections["drag"] then
                    connections["drag"]:Disconnect()
                    connections["drag"] = nil
                end
            end
        end))
    end
end

--- 淡出一组元素并隐藏它们，返回一个用于重新显示的函数
function fadeOut(elements)
    local data = {}
    for _, v in next, elements do
        if typeof(v) == "Instance" and v:IsA("GuiObject") and v.Visible then
            spawn(function()
                data[v] = {
                    BackgroundTransparency = v.BackgroundTransparency
                }
                TweenService:Create(v, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
                if v:IsA("TextBox") or v:IsA("TextButton") or v:IsA("TextLabel") then
                    data[v].TextTransparency = v.TextTransparency
                    TweenService:Create(v, TweenInfo.new(0.5), {TextTransparency = 1}):Play()
                elseif v:IsA("ImageButton") or v:IsA("ImageLabel") then
                    data[v].ImageTransparency = v.ImageTransparency
                    TweenService:Create(v, TweenInfo.new(0.5), {ImageTransparency = 1}):Play()
                end
                delay(0.5,function()
                    v.Visible = false
                    for i, x in next, data[v] do
                        v[i] = x
                    end
                    data[v] = true
                end)
            end)
        end
    end
    return function()
        for i, _ in next, data do
            spawn(function()
                local properties = {
                    BackgroundTransparency = i.BackgroundTransparency
                }
                i.BackgroundTransparency = 1
                TweenService:Create(i, TweenInfo.new(0.5), {BackgroundTransparency = properties.BackgroundTransparency}):Play()
                if i:IsA("TextBox") or i:IsA("TextButton") or i:IsA("TextLabel") then
                    properties.TextTransparency = i.TextTransparency
                    i.TextTransparency = 1
                    TweenService:Create(i, TweenInfo.new(0.5), {TextTransparency = properties.TextTransparency}):Play()
                elseif i:IsA("ImageButton") or i:IsA("ImageLabel") then
                    properties.ImageTransparency = i.ImageTransparency
                    i.ImageTransparency = 1
                    TweenService:Create(i, TweenInfo.new(0.5), {ImageTransparency = properties.ImageTransparency}):Play()
                end
                i.Visible = true
            end)
        end
    end
end

--- 展开/收起主界面（closed 为开关状态）
function toggleMinimize(override)
    if mainClosing and not override or maximized then
        return
    end
    mainClosing = true
    closed = not closed
    if closed then
        if not sideClosed then
            toggleSideTray(true)
        end
        LeftPanel.Visible = true
        remotesFadeIn = fadeOut(LeftPanel:GetDescendants())
        TweenService:Create(LeftPanel, TweenInfo.new(0.5), {Size = UDim2.new(0, 131, 0, 0)}):Play()
        wait(0.5)
    else
        TweenService:Create(LeftPanel, TweenInfo.new(0.5), {Size = UDim2.new(0, 131, 0, 249)}):Play()
        wait(0.5)
        if remotesFadeIn then
            remotesFadeIn()
            remotesFadeIn = nil
        end
        bringBackOnResize()
    end
    mainClosing = false
end

--- 展开/收起侧栏（sideClosed 为开关状态）
function toggleSideTray(override)
    if sideClosing and not override or maximized then
        return
    end
    sideClosing = true
    sideClosed = not sideClosed
    if sideClosed then
        rightFadeIn = fadeOut(RightPanel:GetDescendants())
        wait(0.5)
        minimizeSize(0.5)
        wait(0.5)
        RightPanel.Visible = false
    else
        if closed then
            toggleMinimize(true)
        end
        RightPanel.Visible = true
        maximizeSize(0.5)
        wait(0.5)
        if rightFadeIn then
            rightFadeIn()
        end
        bringBackOnResize()
    end
    sideClosing = false
end

--- 放大代码框以铺满屏幕，便于查看
function toggleMaximize()
    if not sideClosed and not maximized then
        maximized = true
        local disable = Instance.new("TextButton")
        local prevSize = UDim2.new(0, CodeBox.AbsoluteSize.X, 0, CodeBox.AbsoluteSize.Y)
        local prevPos = UDim2.new(0,CodeBox.AbsolutePosition.X, 0, CodeBox.AbsolutePosition.Y)
        disable.Size = UDim2.new(1, 0, 1, 0)
        disable.BackgroundColor3 = Color3.new()
        disable.BorderSizePixel = 0
        disable.Text = 0
        disable.ZIndex = 3
        disable.BackgroundTransparency = 1
        disable.AutoButtonColor = false
        CodeBox.ZIndex = 4
        CodeBox.Position = prevPos
        CodeBox.Size = prevSize
        TweenService:Create(CodeBox, TweenInfo.new(0.5), {Size = UDim2.new(0.5, 0, 0.5, 0), Position = UDim2.new(0.25, 0, 0.25, 0)}):Play()
        TweenService:Create(disable, TweenInfo.new(0.5), {BackgroundTransparency = 0.5}):Play()
        disable.MouseButton1Click:Connect(function()
            if UserInputService:GetMouseLocation().Y + GuiInset.Y >= CodeBox.AbsolutePosition.Y and UserInputService:GetMouseLocation().Y + GuiInset.Y <= CodeBox.AbsolutePosition.Y + CodeBox.AbsoluteSize.Y and UserInputService:GetMouseLocation().X >= CodeBox.AbsolutePosition.X and UserInputService:GetMouseLocation().X <= CodeBox.AbsolutePosition.X + CodeBox.AbsoluteSize.X then
                return
            end
            TweenService:Create(CodeBox, TweenInfo.new(0.5), {Size = prevSize, Position = prevPos}):Play()
            TweenService:Create(disable, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
            wait(0.5)
            disable:Destroy()
            CodeBox.Size = UDim2.new(1, 0, 0.5, 0)
            CodeBox.Position = UDim2.new(0, 0, 0, 0)
            CodeBox.ZIndex = 0
            maximized = false
        end)
    end
end

--- 检查光标是否处于缩放区域内
--- @param p Vector2
function isInResizeRange(p)
    local relativeP = p - Background.AbsolutePosition
    local range = 5
    if relativeP.X >= TopBar.AbsoluteSize.X - range and relativeP.Y >= Background.AbsoluteSize.Y - range
        and relativeP.X <= TopBar.AbsoluteSize.X and relativeP.Y <= Background.AbsoluteSize.Y then
        return true, 'B'
    elseif relativeP.X >= TopBar.AbsoluteSize.X - range and relativeP.X <= Background.AbsoluteSize.X then
        return true, 'X'
    elseif relativeP.Y >= Background.AbsoluteSize.Y - range and relativeP.Y <= Background.AbsoluteSize.Y then
        return true, 'Y'
    end
    return false
end

--- 检查光标是否处于可拖动区域内
--- @param p Vector2
function isInDragRange(p)
    local relativeP = p - Background.AbsolutePosition
    local topbarAS = TopBar.AbsoluteSize
    return relativeP.X <= topbarAS.X - CloseButton.AbsoluteSize.X * 3 and relativeP.X >= 0 and relativeP.Y <= topbarAS.Y and relativeP.Y >= 0 or false
end

--- 鼠标进入 SimpleSpy 界面时调用
local customCursor = Create("ImageLabel",{Parent = SimpleSpy3,Visible = false,Size = UDim2.fromOffset(200, 200),ZIndex = 1e9,BackgroundTransparency = 1,Image = ""})
function mouseEntered()
    local con = connections["SIMPLESPY_CURSOR"]
    if con then
        con:Disconnect()
        connections["SIMPLESPY_CURSOR"] = nil
    end
    connections["SIMPLESPY_CURSOR"] = RunService.RenderStepped:Connect(function()
        UserInputService.MouseIconEnabled = not mouseInGui
        customCursor.Visible = mouseInGui
        if mouseInGui and getgenv().SimpleSpyExecuted then
            local mouseLocation = UserInputService:GetMouseLocation() - GuiInset
            customCursor.Position = UDim2.fromOffset(mouseLocation.X - customCursor.AbsoluteSize.X / 2, mouseLocation.Y - customCursor.AbsoluteSize.Y / 2)
            local inRange, type = isInResizeRange(mouseLocation)
            if inRange and not closed then
                if not sideClosed then
                    customCursor.Image = type == 'B' and "rbxassetid://6065821980" or type == 'X' and "rbxassetid://6065821086" or type == 'Y' and "rbxassetid://6065821596"
                elseif type == 'Y' or type == 'B' then
                    customCursor.Image = "rbxassetid://6065821596"
                end
            elseif customCursor.Image ~= "rbxassetid://6065775281" then
                customCursor.Image = "rbxassetid://6065775281"
            end
        else
            connections["SIMPLESPY_CURSOR"]:Disconnect()
        end
    end)
end

--- 鼠标移动时调用
function mouseMoved()
    local mousePos = UserInputService:GetMouseLocation() - GuiInset
    if not closed
    and mousePos.X >= TopBar.AbsolutePosition.X and mousePos.X <= TopBar.AbsolutePosition.X + TopBar.AbsoluteSize.X
    and mousePos.Y >= Background.AbsolutePosition.Y and mousePos.Y <= Background.AbsolutePosition.Y + Background.AbsoluteSize.Y then
        if not mouseInGui then
            mouseInGui = true
            mouseEntered()
        end
    else
        mouseInGui = false
    end
end

--- 将界面元素调整为“最大化”尺寸
function maximizeSize(speed)
    if not speed then
        speed = 0.05
    end
    TweenService:Create(LeftPanel, TweenInfo.new(speed), { Size = UDim2.fromOffset(LeftPanel.AbsoluteSize.X, Background.AbsoluteSize.Y - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(RightPanel, TweenInfo.new(speed), { Size = UDim2.fromOffset(Background.AbsoluteSize.X - LeftPanel.AbsoluteSize.X, Background.AbsoluteSize.Y - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(TopBar, TweenInfo.new(speed), { Size = UDim2.fromOffset(Background.AbsoluteSize.X, TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(ScrollingFrame, TweenInfo.new(speed), { Size = UDim2.fromOffset(Background.AbsoluteSize.X - LeftPanel.AbsoluteSize.X, 110), Position = UDim2.fromOffset(0, Background.AbsoluteSize.Y - 119 - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(CodeBox, TweenInfo.new(speed), { Size = UDim2.fromOffset(Background.AbsoluteSize.X - LeftPanel.AbsoluteSize.X, Background.AbsoluteSize.Y - 119 - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(LogList, TweenInfo.new(speed), { Size = UDim2.fromOffset(LogList.AbsoluteSize.X, Background.AbsoluteSize.Y - TopBar.AbsoluteSize.Y - 18) }):Play()
end

--- 将界面元素调整为侧栏收起状态
function minimizeSize(speed)
    if not speed then
        speed = 0.05
    end
    TweenService:Create(LeftPanel, TweenInfo.new(speed), { Size = UDim2.fromOffset(LeftPanel.AbsoluteSize.X, Background.AbsoluteSize.Y - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(RightPanel, TweenInfo.new(speed), { Size = UDim2.fromOffset(0, Background.AbsoluteSize.Y - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(TopBar, TweenInfo.new(speed), { Size = UDim2.fromOffset(LeftPanel.AbsoluteSize.X, TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(ScrollingFrame, TweenInfo.new(speed), { Size = UDim2.fromOffset(0, 119), Position = UDim2.fromOffset(0, Background.AbsoluteSize.Y - 119 - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(CodeBox, TweenInfo.new(speed), { Size = UDim2.fromOffset(0, Background.AbsoluteSize.Y - 119 - TopBar.AbsoluteSize.Y) }):Play()
    TweenService:Create(LogList, TweenInfo.new(speed), { Size = UDim2.fromOffset(LogList.AbsoluteSize.X, Background.AbsoluteSize.Y - TopBar.AbsoluteSize.Y - 18) }):Play()
end

--- 确保尺寸不超过屏幕范围
function validateSize()
    local x, y = Background.AbsoluteSize.X, Background.AbsoluteSize.Y
    local screenSize = workspace.CurrentCamera.ViewportSize
    if x + Background.AbsolutePosition.X > screenSize.X then
        if screenSize.X - Background.AbsolutePosition.X >= 450 then
            x = screenSize.X - Background.AbsolutePosition.X
        else
            x = 450
        end
    elseif y + Background.AbsolutePosition.Y > screenSize.Y then
        if screenSize.X - Background.AbsolutePosition.Y >= 268 then
            y = screenSize.Y - Background.AbsolutePosition.Y
        else
            y = 268
        end
    end
    Background.Size = UDim2.fromOffset(x, y)
end

--- 鼠标位于 Background 框内且有用户输入时调用
--- @param input InputObject
function backgroundUserInput(input)
    local mousePos = UserInputService:GetMouseLocation() - GuiInset
    local inResizeRange, type = isInResizeRange(mousePos)
    if input.UserInputType == Enum.UserInputType.MouseButton1 and inResizeRange then
        local lastPos = UserInputService:GetMouseLocation()
        local offset = Background.AbsoluteSize - lastPos
        local currentPos = lastPos + offset
        if not connections["SIMPLESPY_RESIZE"] then
            connections["SIMPLESPY_RESIZE"] = RunService.RenderStepped:Connect(function()
                local newPos = UserInputService:GetMouseLocation()
                if newPos ~= lastPos then
                    local currentX = (newPos + offset).X
                    local currentY = (newPos + offset).Y
                    if currentX < 450 then
                        currentX = 450
                    end
                    if currentY < 268 then
                        currentY = 268
                    end
                    currentPos = Vector2.new(currentX, currentY)
                    Background.Size = UDim2.fromOffset((not sideClosed and not closed and (type == "X" or type == "B")) and currentPos.X or Background.AbsoluteSize.X, (--[[(not sideClosed or currentPos.X <= LeftPanel.AbsolutePosition.X + LeftPanel.AbsoluteSize.X) and]] not closed and (type == "Y" or type == "B")) and currentPos.Y or Background.AbsoluteSize.Y)
                    validateSize()
                    if sideClosed then
                        minimizeSize()
                    else
                        maximizeSize()
                    end
                    lastPos = newPos
                end
            end)
        end
        table.insert(connections, UserInputService.InputEnded:Connect(function(inputE)
            if input == inputE then
                if connections["SIMPLESPY_RESIZE"] then
                    connections["SIMPLESPY_RESIZE"]:Disconnect()
                    connections["SIMPLESPY_RESIZE"] = nil
                end
            end
        end))
    elseif isInDragRange(mousePos) then
        onBarInput(input)
    end
end

--- 获取某个实例所隶属的玩家
function getPlayerFromInstance(instance)
    for _, v in next, Players:GetPlayers() do
        if v.Character and (instance:IsDescendantOf(v.Character) or instance == v.Character) then
            return v
        end
    end
end

--- 点击某个事件条目时执行
function eventSelect(frame)
    if selected and selected.Log  then
        if selected.Button then
            spawn(function()
                TweenService:Create(selected.Button, TweenInfo.new(0.5), {BackgroundColor3 = Color3.fromRGB(0, 0, 0)}):Play()
            end)
        end
        selected = nil
    end
    for _, v in next, logs do
        if frame == v.Log then
            selected = v
        end
    end
    if selected and selected.Log then
        spawn(function()
            TweenService:Create(frame.Button, TweenInfo.new(0.5), {BackgroundColor3 = Color3.fromRGB(92, 126, 229)}):Play()
        end)
        codebox:setRaw(selected.GenScript)
    end
    if sideClosed then
        toggleSideTray()
    end
end

--- 更新画布尺寸以适配当前的功能按钮数量
function updateFunctionCanvas()
    ScrollingFrame.CanvasSize = UDim2.fromOffset(UIGridLayout.AbsoluteContentSize.X, UIGridLayout.AbsoluteContentSize.Y)
end

--- 更新画布尺寸以适配当前的远程条目数量
function updateRemoteCanvas()
    LogList.CanvasSize = UDim2.fromOffset(UIListLayout.AbsoluteContentSize.X, UIListLayout.AbsoluteContentSize.Y)
end

--- 用于开关提示框并方便地设置其描述文字
--- @param enable boolean
--- @param text string
function makeToolTip(enable, text)
    if enable and text then
        if ToolTip.Visible then
            ToolTip.Visible = false
            local tooltip = connections["ToolTip"]
            if tooltip then
                tooltip:Disconnect()
            end
        end
        local first = true
        connections["ToolTip"] = RunService.RenderStepped:Connect(function()
            local MousePos = UserInputService:GetMouseLocation()
            local topLeft = MousePos + Vector2.new(20, -15)
            local bottomRight = topLeft + ToolTip.AbsoluteSize
            local ViewportSize = workspace.CurrentCamera.ViewportSize
            local ViewportSizeX = ViewportSize.X
            local ViewportSizeY = ViewportSize.Y

            if topLeft.X < 0 then
                topLeft = Vector2.new(0, topLeft.Y)
            elseif bottomRight.X > ViewportSizeX then
                topLeft = Vector2.new(ViewportSizeX - ToolTip.AbsoluteSize.X, topLeft.Y)
            end
            if topLeft.Y < 0 then
                topLeft = Vector2.new(topLeft.X, 0)
            elseif bottomRight.Y > ViewportSizeY - 35 then
                topLeft = Vector2.new(topLeft.X, ViewportSizeY - ToolTip.AbsoluteSize.Y - 35)
            end
            if topLeft.X <= MousePos.X and topLeft.Y <= MousePos.Y then
                topLeft = Vector2.new(MousePos.X - ToolTip.AbsoluteSize.X - 2, MousePos.Y - ToolTip.AbsoluteSize.Y - 2)
            end
            if first then
                ToolTip.Position = UDim2.fromOffset(topLeft.X, topLeft.Y)
                first = false
            else
                ToolTip:TweenPosition(UDim2.fromOffset(topLeft.X, topLeft.Y), "Out", "Linear", 0.1)
            end
        end)
        TextLabel.Text = text
        TextLabel.TextScaled = true
        ToolTip.Visible = true
        return
    else
        if ToolTip.Visible then
            ToolTip.Visible = false
            local tooltip = connections["ToolTip"]
            if tooltip then
                tooltip:Disconnect()
            end
        end
    end
end

--- 创建新的功能按钮（位于代码框下方）
--- @param name string
---@param description function
---@param onClick function
function newButton(name, description, onClick)
    local FunctionTemplate = Create("Frame",{Name = "FunctionTemplate",Parent = ScrollingFrame,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Size = UDim2.new(0, 117, 0, 23)})
    local ColorBar = Create("Frame",{Name = "ColorBar",Parent = FunctionTemplate,BackgroundColor3 = Color3.new(1, 1, 1),BorderSizePixel = 0,Position = UDim2.new(0, 7, 0, 10),Size = UDim2.new(0, 7, 0, 18),ZIndex = 3})
    local Text = Create("TextLabel",{Text = name,Name = "Text",Parent = FunctionTemplate,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 19, 0, 10),Size = UDim2.new(0, 69, 0, 18),ZIndex = 2,Font = Enum.Font.SourceSans,TextColor3 = Color3.new(1, 1, 1),TextSize = 14,TextStrokeColor3 = Color3.new(0.145098, 0.141176, 0.14902),TextXAlignment = Enum.TextXAlignment.Left})
    local Button = Create("TextButton",{Name = "Button",Parent = FunctionTemplate,BackgroundColor3 = Color3.new(0, 0, 0),BackgroundTransparency = 0.69999998807907,BorderColor3 = Color3.new(1, 1, 1),Position = UDim2.new(0, 7, 0, 10),Size = UDim2.new(0, 80, 0, 18),AutoButtonColor = false,Font = Enum.Font.SourceSans,Text = "",TextColor3 = Color3.new(0, 0, 0),TextSize = 14})

    Button.MouseEnter:Connect(function()
        makeToolTip(true, description())
    end)
    Button.MouseLeave:Connect(function()
        makeToolTip(false)
    end)
    FunctionTemplate.AncestryChanged:Connect(function()
        makeToolTip(false)
    end)
    Button.MouseButton1Click:Connect(function(...)
        logthread(running())
        onClick(FunctionTemplate, ...)
    end)
    updateFunctionCanvas()
end

--- 向日志中添加新的远程条目
--- @param name string The name of the remote being logged
--- @param type string The type of the remote being logged (either 'function' or 'event')
--- @param args any
--- @param remote any
--- @param function_info string
--- @param blocked any
function newRemote(type, data)
    if layoutOrderNum < 1 then layoutOrderNum = 999999999 end
    local remote = data.remote
    local callingscript = data.callingscript

    local RemoteTemplate = Create("Frame",{LayoutOrder = layoutOrderNum,Name = "RemoteTemplate",Parent = LogList,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Size = UDim2.new(0, 117, 0, 27)})
    local ColorBar = Create("Frame",{Name = "ColorBar",Parent = RemoteTemplate,BackgroundColor3 = (type == "event" and Color3.fromRGB(255, 242, 0)) or Color3.fromRGB(99, 86, 245),BorderSizePixel = 0,Position = UDim2.new(0, 0, 0, 1),Size = UDim2.new(0, 7, 0, 18),ZIndex = 2})
    local Text = Create("TextLabel",{TextTruncate = Enum.TextTruncate.AtEnd,Name = "Text",Parent = RemoteTemplate,BackgroundColor3 = Color3.new(1, 1, 1),BackgroundTransparency = 1,Position = UDim2.new(0, 12, 0, 1),Size = UDim2.new(0, 105, 0, 18),ZIndex = 2,Font = Enum.Font.SourceSans,Text = remote.Name,TextColor3 = Color3.new(1, 1, 1),TextSize = 14,TextXAlignment = Enum.TextXAlignment.Left})
    local Button = Create("TextButton",{Name = "Button",Parent = RemoteTemplate,BackgroundColor3 = Color3.new(0, 0, 0),BackgroundTransparency = 0.75,BorderColor3 = Color3.new(1, 1, 1),Position = UDim2.new(0, 0, 0, 1),Size = UDim2.new(0, 117, 0, 18),AutoButtonColor = false,Font = Enum.Font.SourceSans,Text = "",TextColor3 = Color3.new(0, 0, 0),TextSize = 14})

    local log = {
        Name = remote.name,
        Function = data.infofunc or "--函数信息已关闭",
        Remote = remote,
        DebugId = data.id,
        metamethod = data.metamethod,
        args = data.args,
        Log = RemoteTemplate,
        Button = Button,
        Blocked = data.blocked,
        Source = callingscript,
        returnvalue = data.returnvalue,
        GenScript = "-- 正在生成，请稍候...\n--（若此提示持续存在，说明远程参数可能极长）"
    }

    logs[#logs + 1] = log
    local connect = Button.MouseButton1Click:Connect(function()
        logthread(running())
        eventSelect(RemoteTemplate)
        log.GenScript = genScript(log.Remote, log.args)
        if log.Blocked then
            log.GenScript = "-- 此远程调用已被 SIMPLESPY 阻止发往服务器\n\n" .. log.GenScript
        end
        if selected == log and RemoteTemplate then
            eventSelect(RemoteTemplate)
        end
    end)
    layoutOrderNum -= 1
    table.insert(remoteLogs, 1, {connect, RemoteTemplate})
    clean()
    updateRemoteCanvas()
end

--- 根据给定参数生成脚本（首项必须是远程对象路径）
function genScript(remote, args)
    prevTables = {}
    local gen = ""
    local function remotePath()
        if LazyFix and type(LazyFix.ConvertKnown) == "function" then
            local ok, out = pcall(LazyFix.ConvertKnown, LazyFix, "Instance", remote)
            if ok and type(out) == "string" and out ~= "" then
                return out
            end
        end
        local ok, path = pcall(i2p, remote)
        return (ok and type(path) == "string" and path ~= "") and path or ("--[[无法解析远程对象路径]] game:GetService(\"ReplicatedStorage\")")
    end
    if #args > 0 then
        if LazyFix and type(LazyFix.Convert) == "function" then
            xpcall(function()
                gen = "local args = "..LazyFix.Convert(args, true) .. "\n"
            end,function(err)
            gen ..= "-- 发生错误：\n--"..err.."\n-- 表转字符串失败！回退到旧版处理方式（结果可能不准确）\nlocal args = {"
            xpcall(function()
                for i, v in next, args do
                    if type(i) ~= "Instance" and type(i) ~= "userdata" then
                        gen = gen .. "\n    [object] = "
                    elseif type(i) == "string" then
                        gen = gen .. '\n    ["' .. i .. '"] = '
                    elseif type(i) == "userdata" and typeof(i) ~= "Instance" then
                        gen = gen .. "\n    [" .. string.format("nil --[[%s]]", typeof(v)) .. ")] = "
                    elseif type(i) == "userdata" then
                         gen = gen .. "\n    [game." .. i:GetFullName() .. ")] = "
                    end
                    if type(v) ~= "Instance" and type(v) ~= "userdata" then
                        gen = gen .. "object"
                    elseif type(v) == "string" then
                        gen = gen .. '"' .. v .. '"'
                    elseif type(v) == "userdata" and typeof(v) ~= "Instance" then
                        gen = gen .. string.format("nil --[[%s]]", typeof(v))
                    elseif type(v) == "userdata" then
                        gen = gen .. "game." .. v:GetFullName()
                    end
                end
                gen ..= "\n}\n\n"
            end,function()
                gen ..= "}\n-- 旧版表转字符串也失败！无法反编译。"
            end)
        end)
        else
            gen = "-- LazyFix 模块不可用，改用旧版参数格式\nlocal args = {}\n"
        end
        if not remote:IsDescendantOf(game) and not getnilrequired then
            gen = "function getNil(name,class) for _,v in next, getnilinstances()do if v.ClassName==class and v.Name==name then return v;end end end\n\n" .. gen
        end
        if remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") then
            gen ..= remotePath() .. ":FireServer(unpack(args))"
        elseif remote:IsA("RemoteFunction") then
            gen = gen .. remotePath() .. ":InvokeServer(unpack(args))"
        end
    else
        if remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") then
            gen ..= remotePath() .. ":FireServer()"
        elseif remote:IsA("RemoteFunction") then
            gen ..= remotePath() .. ":InvokeServer()"
        end
    end
    prevTables = {}
    return gen
end

--- 值转字符串：值、输出字符串、层级（缩进）、父表、变量名、是否来自 tovar
local CustomGeneration = {
    Vector3 = (function()
        local temp = {}
        for i,v in Vector3 do
            if type(v) == "vector" then
                temp[v] = `Vector3.{i}`
            end
        end
        return temp
    end)(),
    Vector2 = (function()
        local temp = {}
        for i,v in Vector2 do
            if type(v) == "userdata" then
                temp[v] = `Vector2.{i}`
            end
        end
        return temp
    end)(),
    CFrame = {
        [CFrame.identity] = "CFrame.identity"
    }
}

local number_table = {
    ["inf"] = "math.huge",
    ["-inf"] = "-math.huge",
    ["nan"] = "0/0"
}

local ufunctions
ufunctions = {
    TweenInfo = function(u)
        return `TweenInfo.new({u.Time}, {u.EasingStyle}, {u.EasingDirection}, {u.RepeatCount}, {u.Reverses}, {u.DelayTime})`
    end,
    Ray = function(u)
        local Vector3tostring = ufunctions["Vector3"]

        return `Ray.new({Vector3tostring(u.Origin)}, {Vector3tostring(u.Direction)})`
    end,
    BrickColor = function(u)
        return `BrickColor.new({u.Number})`
    end,
    NumberRange = function(u)
        return `NumberRange.new({u.Min}, {u.Max})`
    end,
    Region3 = function(u)
        local center = u.CFrame.Position
        local centersize = u.Size/2
        local Vector3tostring = ufunctions["Vector3"]

        return `Region3.new({Vector3tostring(center-centersize)}, {Vector3tostring(center+centersize)})`
    end,
    Faces = function(u)
        local faces = {}
        if u.Top then
            table.insert(faces, "Top")
        end
        if u.Bottom then
            table.insert(faces, "Enum.NormalId.Bottom")
        end
        if u.Left then
            table.insert(faces, "Enum.NormalId.Left")
        end
        if u.Right then
            table.insert(faces, "Enum.NormalId.Right")
        end
        if u.Back then
            table.insert(faces, "Enum.NormalId.Back")
        end
        if u.Front then
            table.insert(faces, "Enum.NormalId.Front")
        end
        return `Faces.new({table.concat(faces, ", ")})`
    end,
    EnumItem = function(u)
        return tostring(u)
    end,
    Enums = function(u)
        return "Enum"
    end,
    Enum = function(u)
        return `Enum.{u}`
    end,
    Vector3 = function(u)
        return CustomGeneration.Vector3[u] or `Vector3.new({u})`
    end,
    Vector2 = function(u)
        return CustomGeneration.Vector2[u] or `Vector2.new({u})`
    end,
    CFrame = function(u)
        return CustomGeneration.CFrame[u] or `CFrame.new({table.concat({u:GetComponents()},", ")})`
    end,
    PathWaypoint = function(u)
        return `PathWaypoint.new({ufunctions["Vector3"](u.Position)}, {u.Action}, "{u.Label}")`
    end,
    UDim = function(u)
        return `UDim.new({u})`
    end,
    UDim2 = function(u)
        return `UDim2.new({u})`
    end,
    Rect = function(u)
        local Vector2tostring = ufunctions["Vector2"]
        return `Rect.new({Vector2tostring(u.Min)}, {Vector2tostring(u.Max)})`
    end,
    Color3 = function(u)
        return `Color3.new({u.R}, {u.G}, {u.B})`
    end,
    RBXScriptSignal = function(u) -- 服务器不会收到这个值
        return "RBXScriptSignal --[[不支持 RBXScriptSignal]]"
    end,
    RBXScriptConnection = function(u) -- 服务器不会收到这个值
        return "RBXScriptConnection --[[不支持 RBXScriptConnection]]"
    end,
}

local typeofv2sfunctions = {
    number = function(v)
        local number = tostring(v)
        return number_table[number] or number
    end,
    boolean = function(v)
        return tostring(v)
    end,
    string = function(v,l)
        return formatstr(v, l)
    end,
    ["function"] = function(v) -- 服务器不会收到这个值
        return f2s(v)
    end,
    table = function(v, l, p, n, vtv, i, pt, path, tables, tI)
        return t2s(v, l, p, n, vtv, i, pt, path, tables, tI)
    end,
    Instance = function(v)
        local DebugId = OldDebugId(v)
        return i2p(v,generation[DebugId])
    end,
    userdata = function(v) -- 服务器不会收到这个值
        if configs.advancedinfo then
            if getrawmetatable(v) then
                return "newproxy(true)"
            end
            return "newproxy(false)"
        end
        return "newproxy(true)"
    end
}

local typev2sfunctions = {
    userdata = function(v,vtypeof)
        if ufunctions[vtypeof] then
            return ufunctions[vtypeof](v)
        end
        return `{vtypeof}({rawtostring(v)}) --[[生成失败]]`
    end,
    vector = ufunctions["Vector3"]
}


function v2s(v, l, p, n, vtv, i, pt, path, tables, tI)
    local vtypeof = typeof(v)
    local vtypeoffunc = typeofv2sfunctions[vtypeof]
    local vtypefunc = typev2sfunctions[type(v)]
    local vtype = type(v)
    if not tI then
        tI = {0}
    else
        tI[1] += 1
    end

    if vtypeoffunc then
        return vtypeoffunc(v, l, p, n, vtv, i, pt, path, tables, tI)
    elseif vtypefunc then
        return vtypefunc(v,vtypeof)
    end
    return `{vtypeof}({rawtostring(v)}) --[[生成失败]]`
end

--- 值转变量
--- @param t any
function v2v(t)
    topstr = ""
    bottomstr = ""
    getnilrequired = false
    local ret = ""
    local count = 1
    for i, v in next, t do
        if type(i) == "string" and i:match("^[%a_]+[%w_]*$") then
            ret = ret .. "local " .. i .. " = " .. v2s(v, nil, nil, i, true) .. "\n"
        elseif rawtostring(i):match("^[%a_]+[%w_]*$") then
            ret = ret .. "local " .. lower(rawtostring(i)) .. "_" .. rawtostring(count) .. " = " .. v2s(v, nil, nil, lower(rawtostring(i)) .. "_" .. rawtostring(count), true) .. "\n"
        else
            ret = ret .. "local " .. type(v) .. "_" .. rawtostring(count) .. " = " .. v2s(v, nil, nil, type(v) .. "_" .. rawtostring(count), true) .. "\n"
        end
        count = count + 1
    end
    if getnilrequired then
        topstr = "function getNil(name,class) for _,v in next, getnilinstances() do if v.ClassName==class and v.Name==name then return v;end end end\n" .. topstr
    end
    if #topstr > 0 then
        ret = topstr .. "\n" .. ret
    end
    if #bottomstr > 0 then
        ret = ret .. bottomstr
    end
    return ret
end

function tabletostring(tbl: table,format: boolean)
    
end

--- 表转字符串
--- @param t table
--- @param l number
--- @param p table
--- @param n string
--- @param vtv boolean
--- @param i any
--- @param pt table
--- @param path string
--- @param tables table
--- @param tI table
function t2s(t, l, p, n, vtv, i, pt, path, tables, tI)
    local globalIndex = table.find(getgenv(), t) -- 检查该表是否为全局变量
    if type(globalIndex) == "string" then
        return globalIndex
    end
    if not tI then
        tI = {0}
    end
    if not path then -- 将 path 设为空字符串（这样每次就不必手动传入）
        path = ""
    end
    if not l then -- 将层级设为 0（用于缩进），并初始化 tables 以记录已序列化的表
        l = 0
        tables = {}
    end
    if not p then -- p 是上一级的表，若本身就是第一层则无所谓
        p = t
    end
    for _, v in next, tables do -- 检查当前表是否已被序列化过
        if n and rawequal(v, t) then
            bottomstr = bottomstr .. "\n" .. rawtostring(n) .. rawtostring(path) .. " = " .. rawtostring(n) .. rawtostring(({v2p(v, p)})[2])
            return "{} --[[重复引用]]"
        end
    end
    table.insert(tables, t) -- 把当前表记入已处理表的列表
    local s =  "{" -- 序列化的起始
    local size = 0
    l += indent -- 设置缩进层级
    for k, v in next, t do -- iterates over table
        size = size + 1 -- 累加计数以判断上限
        if size > (getgenv().SimpleSpyMaxTableSize or 1000) then
            s = s .. "\n" .. string.rep(" ", l) .. "-- 已达到表大小上限，修改 'getgenv().SimpleSpyMaxTableSize' 可调整上限 "
            break
        end
        if rawequal(k, t) then -- 检查正在遍历的表是否被用作自身的索引（Lua 的老问题了）
            bottomstr ..= `\n{n}{path}[{n}{path}] = {(rawequal(v,k) and `{n}{path}` or v2s(v, l, p, n, vtv, k, t, `{path}[{n}{path}]`, tables))}`
            --bottomstr = bottomstr .. "\n" .. rawtostring(n) .. rawtostring(path) .. "[" .. rawtostring(n) .. rawtostring(path) .. "]" .. " = " .. (rawequal(v, k) and rawtostring(n) .. rawtostring(path) or v2s(v, l, p, n, vtv, k, t, path .. "[" .. rawtostring(n) .. rawtostring(path) .. "]", tables))
            size -= 1
            continue
        end
        local currentPath = "" -- 初始化 v 在 t 中的路径
        if type(k) == "string" and k:match("^[%a_]+[%w_]*$") then -- 妥善处理表路径的生成（前半部分）
            currentPath = "." .. k
        else
            currentPath = "[" .. v2s(k, l, p, n, vtv, k, t, path .. currentPath, tables, tI) .. "]"
        end
        if size % 100 == 0 then
            scheduleWait()
        end
        -- 真正开始序列化表中的成员
        s = s .. "\n" .. string.rep(" ", l) .. "[" .. v2s(k, l, p, n, vtv, k, t, path .. currentPath, tables, tI) .. "] = " .. v2s(v, l, p, n, vtv, k, t, path .. currentPath, tables, tI) .. ","
    end
    if #s > 1 then -- 去掉最后一个逗号，看起来更整洁（只能到最后才知道是否结束，所以...）
        s = s:sub(1, #s - 1)
    end
    if size > 0 then -- 让最后一个花括号缩进对齐
        s = s .. "\n" .. string.rep(" ", l - indent)
    end
    return s .. "}"
end

--- 函数转字符串
function f2s(f)
    for k, x in next, getgenv() do
        local isgucci, gpath
        if rawequal(x, f) then
            isgucci, gpath = true, ""
        elseif type(x) == "table" then
            isgucci, gpath = v2p(f, x)
        end
        if isgucci and type(k) ~= "function" then
            if type(k) == "string" and k:match("^[%a_]+[%w_]*$") then
                return k .. gpath
            else
                return "getgenv()[" .. v2s(k) .. "]" .. gpath
            end
        end
    end
    
    if configs.funcEnabled then
        local funcname = info(f,"n")
        
        if funcname and funcname:match("^[%a_]+[%w_]*$") then
            return `function {funcname}() end -- 被调用的函数：{funcname}`
        end
    end
    return tostring(f)
end

--- 实例转路径
--- @param i userdata
function i2p(i,customgen)
    if customgen then
        return customgen
    end
    local player = getplayer(i)
    local parent = i
    local out = ""
    if parent == nil then
        return "nil"
    elseif player then
        while true do
            if parent and parent == player.Character then
                if player == Players.LocalPlayer then
                    return 'game:GetService("Players").LocalPlayer.Character' .. out
                else
                    return i2p(player) .. ".Character" .. out
                end
            else
                if parent.Name:match("[%a_]+[%w+]*") ~= parent.Name then
                    out = ':FindFirstChild(' .. formatstr(parent.Name) .. ')' .. out
                else
                    out = "." .. parent.Name .. out
                end
            end
            task.wait()
            parent = parent.Parent
        end
    elseif parent ~= game then
        while true do
            if parent and parent.Parent == game then
                if SafeGetService(parent.ClassName) then
                    if lower(parent.ClassName) == "workspace" then
                        return `workspace{out}`
                    else
                        return 'game:GetService("' .. parent.ClassName .. '")' .. out
                    end
                else
                    if parent.Name:match("[%a_]+[%w_]*") then
                        return "game." .. parent.Name .. out
                    else
                        return 'game:FindFirstChild(' .. formatstr(parent.Name) .. ')' .. out
                    end
                end
            elseif not parent.Parent then
                getnilrequired = true
                return 'getNil(' .. formatstr(parent.Name) .. ', "' .. parent.ClassName .. '")' .. out
            else
                if parent.Name:match("[%a_]+[%w_]*") ~= parent.Name then
                    out = ':WaitForChild(' .. formatstr(parent.Name) .. ')' .. out
                else
                    out = ':WaitForChild("' .. parent.Name .. '")'..out
                end
            end
            if i:IsDescendantOf(Players.LocalPlayer) then
                return 'game:GetService("Players").LocalPlayer'..out
            end
            parent = parent.Parent
            task.wait()
        end
    else
        return "game"
    end
end

--- 获取某个实例所隶属的玩家
function getplayer(instance)
    for _, v in next, Players:GetPlayers() do
        if v.Character and (instance:IsDescendantOf(v.Character) or instance == v.Character) then
            return v
        end
    end
end

--- 在表中查找值对应的路径
function v2p(x, t, path, prev)
    if not path then
        path = ""
    end
    if not prev then
        prev = {}
    end
    if rawequal(x, t) then
        return true, ""
    end
    for i, v in next, t do
        if rawequal(v, x) then
            if type(i) == "string" and i:match("^[%a_]+[%w_]*$") then
                return true, (path .. "." .. i)
            else
                return true, (path .. "[" .. v2s(i) .. "]")
            end
        end
        if type(v) == "table" then
            local duplicate = false
            for _, y in next, prev do
                if rawequal(y, v) then
                    duplicate = true
                end
            end
            if not duplicate then
                table.insert(prev, t)
                local found
                found, p = v2p(x, v, path, prev)
                if found then
                    if type(i) == "string" and i:match("^[%a_]+[%w_]*$") then
                        return true, "." .. i .. p
                    else
                        return true, "[" .. v2s(i) .. "]" .. p
                    end
                end
            end
        end
    end
    return false, ""
end

--- 格式化字符串：按字节转义（处理特殊符号）
function formatstr(s, indentation)
    if not indentation then
        indentation = 0
    end
    local handled, reachedMax = handlespecials(s, indentation)
    return '"' .. handled .. '"' .. (reachedMax and " --[[ 已达到字符串长度上限，修改 'getgenv().SimpleSpyMaxStringSize' 可调整上限 ]]" or "")
end

--- Adds \'s to the text as a replacement to whitespace chars and other things because string.format can't yayeet

local function isFinished(coroutines: table)
    for _, v in next, coroutines do
        if status(v) == "running" then
            return false
        end
    end
    return true
end

local specialstrings = {
    ["\n"] = function(thread,index)
        resume(thread,index,"\\n")
    end,
    ["\t"] = function(thread,index)
        resume(thread,index,"\\t")
    end,
    ["\\"] = function(thread,index)
        resume(thread,index,"\\\\")
    end,
    ['"'] = function(thread,index)
        resume(thread,index,"\\\"")
    end
}

function handlespecials(s, indentation)
    local i = 0
    local n = 1
    local coroutines = {}
    local coroutineFunc = function(i, r)
        s = s:sub(0, i - 1) .. r .. s:sub(i + 1, -1)
    end
    local timeout = 0
    repeat
        i += 1
        if timeout >= 10 then
            task.wait()
            timeout = 0
        end
        local char = s:sub(i, i)

        if byte(char) then
            timeout += 1
            local c = create(coroutineFunc)
            table.insert(coroutines, c)
            local specialfunc = specialstrings[char]

            if specialfunc then
                specialfunc(c,i)
                i += 1
            elseif byte(char) > 126 or byte(char) < 32 then
                resume(c, i, "\\" .. byte(char))
                -- s = s:sub(0, i - 1) .. "\\" .. byte(char) .. s:sub(i + 1, -1)
                i += #rawtostring(byte(char))
            end
            if i >= n * 100 then
                local extra = string.format('" ..\n%s"', string.rep(" ", indentation + indent))
                s = s:sub(0, i) .. extra .. s:sub(i + 1, -1)
                i += #extra
                n += 1
            end
        end
    until char == "" or i > (getgenv().SimpleSpyMaxStringSize or 10000)
    while not isFinished(coroutines) do
        RunService.Heartbeat:Wait()
    end
    clear(coroutines)
    if i > (getgenv().SimpleSpyMaxStringSize or 10000) then
        s = string.sub(s, 0, getgenv().SimpleSpyMaxStringSize or 10000)
        return s, true
    end
    return s, false
end

--- 根据 getinfo 的 src 查找脚本，找不到则返回 nil
--- @param src string
function getScriptFromSrc(src)
    local realPath
    local runningTest
    --- @type number
    local s, e
    local match = false
    if src:sub(1, 1) == "=" then
        realPath = game
        s = 2
    else
        runningTest = src:sub(2, e and e - 1 or -1)
        for _, v in next, getnilinstances() do
            if v.Name == runningTest then
                realPath = v
                break
            end
        end
        s = #runningTest + 1
    end
    if realPath then
        e = src:sub(s, -1):find("%.")
        local i = 0
        repeat
            i += 1
            if not e then
                runningTest = src:sub(s, -1)
                local test = realPath.FindFirstChild(realPath, runningTest)
                if test then
                    realPath = test
                end
                match = true
            else
                runningTest = src:sub(s, e)
                local test = realPath.FindFirstChild(realPath, runningTest)
                local yeOld = e
                if test then
                    realPath = test
                    s = e + 2
                    e = src:sub(e + 2, -1):find("%.")
                    e = e and e + yeOld or e
                else
                    e = src:sub(e + 2, -1):find("%.")
                    e = e and e + yeOld or e
                end
            end
        until match or i >= 50
    end
    return realPath
end

--- 把给定函数加入调度队列（并附带其后的参数一起调用）

function schedule(f, ...)
    table.insert(scheduled, {f, ...})
end

--- 挂起当前线程，直到调度器放行
function scheduleWait()
    local thread = running()
    schedule(function()
        resume(thread)
    end)
    yield()
end

--- 任务调度器本体（其实现在已经很小了），尽可能快地处理各种任务
local function taskscheduler()
    if not toggle then
        scheduled = {}
        return
    end
    local cap = getgenv().SIMPLESPYCONFIG_MaxRemotes or 300
    if #scheduled > cap + 100 then
        -- 丢弃最新的条目以跟上节奏；较早的调用优先保留
        local overflow = #scheduled - (cap + 100)
        for _ = 1, overflow do
            table.remove(scheduled)
        end
    end
    if #scheduled > 0 then
        local currentf = scheduled[1]
        table.remove(scheduled, 1)
        if type(currentf) == "table" and type(currentf[1]) == "function" then
            -- 包一层新函数，确保 pcall 收到的是可调用对象而不是元组
            pcall(function()
                currentf[1](select(2, unpack(currentf)))
            end)
        end
    end
end

local function tablecheck(tabletocheck,instance,id)
    return tabletocheck[id] or tabletocheck[instance.Name]
end

function remoteHandler(data)
    if configs.autoblock then
        local id = data.id

        if excluding[id] then
            return
        end
        if not history[id] then
            history[id] = {badOccurances = 0, lastCall = tick()}
        end
        if tick() - history[id].lastCall < 1 then
            history[id].badOccurances += 1
            return
        else
            history[id].badOccurances = 0
        end
        if history[id].badOccurances > 3 then
            excluding[id] = true
            return
        end
        history[id].lastCall = tick()
    end

    if (data.remote:IsA("RemoteEvent") or data.remote:IsA("UnreliableRemoteEvent")) and lower(data.method) == "fireserver" then
        newRemote("event", data)
    elseif data.remote:IsA("RemoteFunction") and lower(data.method) == "invokeserver" then
        newRemote("function", data)
    end
end

local newindex = function(method,originalfunction,...)
    if typeof(...) == 'Instance' then
        local remote = cloneref(...)

        if remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction") or remote:IsA("UnreliableRemoteEvent") then
            if ACBridge and ACBridge.ShouldIgnore(remote) then return originalfunction(...) end
            if not configs.logcheckcaller and ACBridge.IsExecutorCall() then return originalfunction(...) end
            local id = ThreadGetDebugId(remote)
            local blockcheck = tablecheck(blocklist,remote,id)
            local args = {select(2,...)}

            if not tablecheck(blacklist,remote,id) and not IsCyclicTable(args) then
                local data = {
                    method = method,
                    remote = remote,
                    args = deepclone(args),
                    infofunc = infofunc,
                    callingscript = callingscript,
                    metamethod = "__index",
                    blockcheck = blockcheck,
                    id = id,
                    returnvalue = {}
                }
                args = nil

                if configs.funcEnabled then
                    data.infofunc = info(2,"f")
                    local calling = getcallingscript()
                    data.callingscript = calling and cloneref(calling) or nil
                end

                schedule(remoteHandler,data)
            end

            if blockcheck then
                return
            end
        end
    end
    return originalfunction(...)
end

-- ACBridge 注入点：Actor 侧捕获的调用走与主 VM 相同的记录通道
-- （须在 ThreadGetDebugId / schedule / remoteHandler 就绪之后才能注入）
if ACBridge then
    ACBridge.Dispatch = function(data)
        if type(data) ~= "table" or typeof(data.remote) ~= "Instance" then return end
        data.id = data.id or ThreadGetDebugId(data.remote)
        data.args = type(data.args) == "table" and data.args or {}
        schedule(remoteHandler, data)
    end
end

local newnamecall = newcclosure(function(...)
    local method = getnamecallmethod()

    if method and (method == "FireServer" or method == "fireServer" or method == "InvokeServer" or method == "invokeServer") then
        if typeof(...) == 'Instance' then
            local remote = cloneref(...)

            if IsA(remote,"RemoteEvent") or IsA(remote,"RemoteFunction") or IsA(remote,"UnreliableRemoteEvent") then    
                if ACBridge and ACBridge.ShouldIgnore(remote) then return originalnamecall(...) end
                if not configs.logcheckcaller and ACBridge.IsExecutorCall() then return originalnamecall(...) end
                local id = ThreadGetDebugId(remote)
                local blockcheck = tablecheck(blocklist,remote,id)
                local args = {select(2,...)}

                if not tablecheck(blacklist,remote,id) and not IsCyclicTable(args) then
                    local data = {
                        method = method,
                        remote = remote,
                        args = deepclone(args),
                        infofunc = infofunc,
                        callingscript = callingscript,
                        metamethod = "__namecall",
                        blockcheck = blockcheck,
                        id = id,
                        returnvalue = {}
                    }
                    args = nil

                    if configs.funcEnabled then
                        data.infofunc = info(2,"f")
                        local calling = getcallingscript()
                        if type(calling) == "userdata" then
                            data.callingscript = calling and cloneref(calling) or nil
                        end
                    end

                    if blockcheck then
                        data.blocked = true
                    end
                    schedule(remoteHandler,data)

                    if blockcheck then
                        return
                    end
                end
            end
        end
    end
    return originalnamecall(...)
end)

local newFireServer = newcclosure(function(...)
    return newindex("FireServer",originalEvent,...)
end)

local newUnreliableFireServer = newcclosure(function(...)
    return newindex("FireServer",originalUnreliableEvent,...)
end)

-- 对所有 detour 尝试栈隐藏：能降低被 debug.info / traceback / getfenv 观察到的概率
if ACBridge then
    ACBridge.HideStack(newnamecall)
    ACBridge.HideStack(newindex)
    ACBridge.HideStack(newFireServer)
    ACBridge.HideStack(newUnreliableFireServer)
end

local newInvokeServer = newcclosure(function(...)
    return newindex("InvokeServer",originalFunction,...)
end)

if ACBridge then
    ACBridge.HideStack(newInvokeServer)
end

local function disablehooks()
    if synv3 then
        if unhook then
            local nc = namecallOriginal
            local e = originalEvent
            local f = originalFunction
            local u = originalUnreliableEvent
            if nc and typeof(nc) == "function" then
                local ok = pcall(unhook, getrawmetatable(game).__namecall, nc)
                if not ok and nc ~= originalnamecall then
                    pcall(unhook, getrawmetatable(game).__namecall, originalnamecall)
                end
            end
            if e then pcall(unhook, e) end
            if f then pcall(unhook, f) end
            if u then pcall(unhook, u) end
        end
        if restorefunction then
            pcall(restorefunction, originalnamecall)
            pcall(restorefunction, originalEvent)
            pcall(restorefunction, originalFunction)
        end
    else
        if hookmetamethod then
            local nc = namecallOriginal or originalnamecall
            if nc then
                pcall(hookmetamethod, game, "__namecall", nc)
            end
        else
            local nc = namecallOriginal or originalnamecall
            if nc then
                pcall(hookfunction, getrawmetatable(game).__namecall, nc)
            end
        end
        if originalEvent then pcall(hookfunction, originalEvent, namecallOriginal) end
        if originalFunction then pcall(hookfunction, originalFunction, namecallOriginal) end
        if originalUnreliableEvent then pcall(hookfunction, originalUnreliableEvent, namecallOriginal) end
    end
    -- 兜底：把登记表里残留的 hook 一并还原，避免留下悬空 hook
    if ACBridge then
        ACBridge.RestoreAll()
    end
end

--- 开启/关闭远程监听
function toggleSpy()
    if not toggle then
        local oldnamecall
        -- 统一登记：ACBridge 保存每一处原值，卸载时逐条还原
        local function reg(original, hooked, tag)
            if ACBridge and type(original) == "function" then
                ACBridge.RegisterManual(original, hooked, tag)
            end
        end
        if synv3 then
            local rawNamecall = getrawmetatable(game).__namecall
            oldnamecall = hook(rawNamecall, clonefunction(newnamecall))
            reg(rawNamecall, oldnamecall, "__namecall")
            local rawEvent, rawFunction, rawUnreliable = originalEvent, originalFunction, originalUnreliableEvent
            local e = hook(rawEvent, clonefunction(newFireServer))
            if e then originalEvent = e; reg(rawEvent, e, "FireServer") end
            local f = hook(rawFunction, clonefunction(newInvokeServer))
            if f then originalFunction = f; reg(rawFunction, f, "InvokeServer") end
            local u = hook(rawUnreliable, clonefunction(newUnreliableFireServer))
            if u then originalUnreliableEvent = u; reg(rawUnreliable, u, "UnreliableFireServer") end
        else
            if hookmetamethod then
                oldnamecall = hookmetamethod(game, "__namecall", clonefunction(newnamecall))
                -- 这里不直接调 getrawmetatable：部分执行器没有它，原逻辑也不依赖它
                local rawNamecall = nil
                if ACBridge and ACBridge.SafeRawMeta then
                    local mt = ACBridge.SafeRawMeta(game)
                    rawNamecall = mt and rawget(mt, "__namecall")
                end
                reg(rawNamecall, oldnamecall, "__namecall")
            else
                local rawNamecall = getrawmetatable(game).__namecall
                oldnamecall = hookfunction(rawNamecall, clonefunction(newnamecall))
                reg(rawNamecall, oldnamecall, "__namecall")
            end
            local rawEvent, rawFunction, rawUnreliable = originalEvent, originalFunction, originalUnreliableEvent
            local e = hookfunction(rawEvent, clonefunction(newFireServer))
            if e then originalEvent = e; reg(rawEvent, e, "FireServer") end
            local f = hookfunction(rawFunction, clonefunction(newInvokeServer))
            if f then originalFunction = f; reg(rawFunction, f, "InvokeServer") end
            local u = hookfunction(rawUnreliable, clonefunction(newUnreliableFireServer))
            if u then originalUnreliableEvent = u; reg(rawUnreliable, u, "UnreliableFireServer") end
        end
        -- 只捕获一次真正的原始函数
        if not namecallOriginal then
            namecallOriginal = oldnamecall
        end
        originalnamecall = oldnamecall
    else
        disablehooks()
    end
end

--- 在两种远程监听方式间切换（当前 hookfunction 方式已禁用）
function toggleSpyMethod()
    toggleSpy()
    toggle = not toggle
end

--- 关闭远程监听
local function shutdown()
    if schedulerconnect then
        schedulerconnect:Disconnect()
    end
    for _, connection in next, connections do
        connection:Disconnect()
    end
    for i,v in next, running_threads do
        if ThreadIsNotDead(v) then
            close(v)
        end
    end
    clear(running_threads)
    clear(connections)
    clear(logs)
    clear(remoteLogs)
    disablehooks()
    if ACBridge then
        ACBridge.Unload()
    end
    SimpleSpy3:Destroy()
    Storage:Destroy()
    UserInputService.MouseIconEnabled = true
    getgenv().SimpleSpyExecuted = false
end

-- 主流程
if not getgenv().SimpleSpyExecuted then
    local succeeded,err = pcall(function()
        if not RunService:IsClient() then
            error("SimpleSpy 无法在服务器端运行！")
        end
        getgenv().SimpleSpyShutdown = shutdown
        -- AC 处置必须先于 Remote hook 安装：否则自身 hook 会被算作异常调用
        if ACBridge then
            ACBridge.Init()
        end
        onToggleButtonClick()
        if not hookmetamethod then
            local msg = "由于你的执行器不支持 hookmetamethod，Simple Spy V3 无法发挥全部功能。"
            if configs.acVerbose then
                ErrorPrompt(msg, true)
            elseif ACBridge then
                ACBridge.Log("gui", msg)
            end
        end
        if Highlight and type(Highlight.new) == "function" then
            codebox = Highlight.new(CodeBox)
        else
            if ACBridge then ACBridge.Log("gui", "Highlight 模块不可用，已回退为普通文本框") end
            if configs.acVerbose then warn("SimpleSpy：Highlight 模块不可用，已回退为普通文本框") end
            local box = CodeBox:FindFirstChildOfClass("TextBox") or Instance.new("TextBox")
            box.Name = "CodeBoxFallback"
            box.Parent = CodeBox
            box.BackgroundTransparency = 1
            box.TextColor3 = Color3.new(1, 1, 1)
            box.TextXAlignment = Enum.TextXAlignment.Left
            box.TextYAlignment = Enum.TextYAlignment.Top
            box.ClearTextOnFocus = false
            box.TextEditable = true
            box.Size = UDim2.new(1, 0, 1, 0)
            codebox = {
                _box = box;
                setRaw = function(self, text) box.Text = tostring(text) end;
                getString = function(self) return box.Text end;
            }
        end
        codebox:setRaw("-- SimpleSpy V3 就绪")
        logthread(spawn(function()
            local suc,content = pcall(game.HttpGet,game,"https://raw.githubusercontent.com/infyiff/backup/refs/heads/main/SimpleSpyV3/update.txt")
            if suc and type(content) == "string" and content ~= "" then
                codebox:setRaw(content)
            end
        end))
        getgenv().SimpleSpy = SimpleSpy
        getgenv().getNil = function(name,class)
            for _,v in next, getnilinstances() do
                if v.ClassName == class and v.Name == name then
                    return v;
                end
            end
        end
        table.insert(connections, Background.MouseEnter:Connect(function(...)
            mouseInGui = true
            mouseEntered()
        end))
        table.insert(connections, Background.MouseLeave:Connect(function(...)
            mouseInGui = false
            mouseEntered()
        end))
        table.insert(connections, TextLabel:GetPropertyChangedSignal("Text"):Connect(scaleToolTip))
        MinimizeButton.MouseButton1Click:Connect(toggleMinimize)
        MaximizeButton.MouseButton1Click:Connect(toggleSideTray)
        Simple.MouseButton1Click:Connect(onToggleButtonClick)
        CloseButton.MouseEnter:Connect(onXButtonHover)
        CloseButton.MouseLeave:Connect(onXButtonUnhover)
        Simple.MouseEnter:Connect(onToggleButtonHover)
        Simple.MouseLeave:Connect(onToggleButtonUnhover)
        CloseButton.MouseButton1Click:Connect(shutdown)
        table.insert(connections, UserInputService.InputBegan:Connect(backgroundUserInput))
        connectResize()
        SimpleSpy3.Enabled = true
        logthread(spawn(function()
            delay(1,onToggleButtonUnhover)
        end))
        schedulerconnect = RunService.Heartbeat:Connect(taskscheduler)
        bringBackOnResize()
        -- GUI 挂载：优先受保护容器（gethui / protect_gui），最后才退回 CoreGui
        local guiParent = nil
        if type(gethui) == "function" then
            local ok, container = pcall(gethui)
            if ok and typeof(container) == "Instance" then guiParent = container end
        end
        if not guiParent and syn and type(syn.protect_gui) == "function" then
            local ok = pcall(syn.protect_gui, SimpleSpy3)
            if ok then guiParent = CoreGui end
        end
        SimpleSpy3.Parent = guiParent or CoreGui
        logthread(spawn(function()
            local lp = Players.LocalPlayer
            if not lp then
                Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
                lp = Players.LocalPlayer
            end
            if lp then
                generation = {
                    [OldDebugId(lp)] = 'game:GetService("Players").LocalPlayer',
                    [OldDebugId(lp:GetMouse())] = 'game:GetService("Players").LocalPlayer:GetMouse',
                    [OldDebugId(game)] = "game",
                    [OldDebugId(workspace)] = "workspace"
                }
            end
        end))
    end)
    if succeeded then
        getgenv().SimpleSpyExecuted = true
    else
        ErrorPrompt("发生错误：\n"..rawtostring(err))
        shutdown()
        return
    end
else
    SimpleSpy3:Destroy()
    return
end

function SimpleSpy:newButton(name, description, onClick)
    return newButton(name, description, onClick)
end

----- 扩展功能 ----- （可方便地为 RemoteSpy 增删附加功能！）
--[[
    Some helpful things:
        - add your function in here, and create buttons for them through the 'newButton' function
        - the first argument provided is the TextButton the player clicks to run the function
        - generated scripts are generated when the namecall is initially fired and saved in remoteFrame objects
        - blacklisted remotes will be ignored directly in namecall (less lag)
        - the properties of a 'remoteFrame' object:
            {
                Name: (string) The name of the Remote
                GenScript: (string) The generated script that appears in the codebox (generated when namecall fired)
                Source: (Instance (LocalScript)) The script that fired/invoked the remote
                Remote: (Instance (RemoteEvent) | Instance (RemoteFunction)) The remote that was fired/invoked
                Log: (Instance (TextButton)) The button being used for the remote (same as 'selected.Log')
            }
        - globals list: (contact @exx#9394 for more information or if you have suggestions for more to be added)
            - closed: (boolean) whether or not the GUI is currently minimized
            - logs: (table[remoteFrame]) full of remoteFrame objects (properties listed above)
            - selected: (remoteFrame) the currently selected remoteFrame (properties listed above)
            - blacklist: (string[] | Instance[] (RemoteEvent) | Instance[] (RemoteFunction)) an array of blacklisted names and remotes
            - codebox: (Instance (TextBox)) the textbox that holds all the code- cleared often
]]
-- 复制代码框中的内容
newButton(
    "复制代码",
    function() return "点击复制代码" end,
    function()
        copyToClipboard(getCodeBoxText(), TextLabel)
    end
)

--- 复制来源脚本（即触发该远程调用的脚本）
newButton(
    "复制远程",
    function() return "点击复制远程对象的路径" end,
    function()
        if selected and selected.Remote then
            local ok, path = pcall(v2s, selected.Remote)
            if ok and type(path) == "string" and path ~= "" then
                copyToClipboard(path, TextLabel, "已复制！")
            else
                TextLabel.Text = "序列化远程对象失败"
            end
        else
            TextLabel.Text = "未选中远程对象"
        end
    end
)

-- 通过 loadstring 执行代码框中的内容
newButton("执行代码",
    function() return "点击执行代码" end,
    function()
        local Remote = selected and selected.Remote
        if Remote then
            TextLabel.Text = "正在执行..."
            xpcall(function()
                local returnvalue
                if Remote:IsA("RemoteEvent") or Remote:IsA("UnreliableRemoteEvent") then
                    returnvalue = Remote:FireServer(unpack(selected.args))
                elseif Remote:IsA("RemoteFunction") then
                    returnvalue = Remote:InvokeServer(unpack(selected.args))
                end

                TextLabel.Text = ("执行成功！\n%s"):format(v2s(returnvalue))
            end,function(err)
                TextLabel.Text = ("执行出错！\n%s"):format(err)
            end)
            return
        end
        TextLabel.Text = "未找到来源"
    end
)

--- 获取调用脚本（可靠性一般，将就用）
newButton(
    "获取脚本",
    function() return "点击复制调用脚本到剪贴板\n警告：不太可靠，nil 表示未能找到" end,
    function()
        if selected then
            if not selected.Source then
                -- getfenv(nil) 会抛错，原实现无任何保护
                if type(selected.Function) == "function" and type(getfenv) == "function" then
                    local ok, env = pcall(getfenv, selected.Function)
                    if ok and type(env) == "table" then
                        selected.Source = rawget(env, "script")
                    end
                end
            end
            local ok, path = pcall(v2s, selected.Source)
            if ok and type(path) == "string" and path ~= "" then
                copyToClipboard(path, TextLabel, "完成！")
            else
                TextLabel.Text = "未能获取调用脚本"
            end
        else
            TextLabel.Text = "未选中记录"
        end
    end
)

--- 反编译触发该远程调用的脚本，并放入代码框
newButton("函数信息",function() return "点击查看调用函数的信息" end,
function()
    local func = selected and selected.Function
    if func then
        local typeoffunc = typeof(func)

        if typeoffunc ~= 'string' then
            codebox:setRaw("--[[正在生成函数信息，请稍候]]")
            spawn(function()
                local lclosure = islclosure(func)
            local SourceScript = rawget(getfenv(func),"script")
            local CallingScript = selected.Source or nil
            local info = {}
            
            info = {
                info = getinfo(func),
                constants = lclosure and deepclone(getconstants(func)) or "N/A --需要 Lua 闭包，实际得到 C 闭包",
                upvalues = deepclone(getupvalues(func)),
                script = {
                    SourceScript = SourceScript or 'nil',
                    CallingScript = CallingScript or 'nil'
                }
            }
                    
            if configs.advancedinfo then
                local Remote = selected.Remote

                info["advancedinfo"] = {
                    Metamethod = selected.metamethod,
                    DebugId = {
                        SourceScriptDebugId = SourceScript and typeof(SourceScript) == "Instance" and OldDebugId(SourceScript) or "N/A",
                        CallingScriptDebugId = CallingScript and typeof(SourceScript) == "Instance" and OldDebugId(CallingScript) or "N/A",
                        RemoteDebugId = OldDebugId(Remote)
                    },
                    Protos = lclosure and getprotos(func) or "N/A --需要 Lua 闭包，实际得到 C 闭包"
                }

                if Remote:IsA("RemoteFunction") then
                    info["advancedinfo"]["OnClientInvoke"] = getcallbackmember and (getcallbackmember(Remote,"OnClientInvoke") or "N/A") or "N/A --缺少 getcallbackmember 函数"
                elseif getconnections then
                    info["advancedinfo"]["OnClientEvents"] = {}

                    for i,v in next, getconnections(Remote.OnClientEvent) do
                        info["advancedinfo"]["OnClientEvents"][i] = {
                            Function = v.Function or "N/A",
                            State = v.State or "N/A"
                        }
                    end
                end
            end
            codebox:setRaw("--[[正在转换表为字符串，请稍候]]")
            selected.Function = v2v({functionInfo = info})
            codebox:setRaw("-- 调用函数信息\n-- 由 SimpleSpy V3 序列化器生成\n\n"..tostring(selected.Function))
            TextLabel.Text = "完成！函数信息由 SimpleSpy V3 序列化器生成。"
            end)
        end
    else
        TextLabel.Text = "错误！未找到所选函数。"
    end
end)

--- 清空远程调用日志
newButton(
    "清空日志",
    function() return "点击清空日志" end,
    function()
        TextLabel.Text = "正在清空..."
        clear(logs)
        for i,v in next, LogList:GetChildren() do
            if not v:IsA("UIListLayout") then
                v:Destroy()
            end
        end
        codebox:setRaw("")
        selected = nil
        TextLabel.Text = "日志已清空！"
    end
)

--- 将选中的远程对象从 RemoteSpy 中排除
newButton(
    "排除(单个)",
    function() return "点击排除此远程对象。\n排除后 SimpleSpy 将忽略它，但它仍可正常使用。" end,
    function()
        if selected then
            blacklist[OldDebugId(selected.Remote)] = true
            TextLabel.Text = "已排除！"
        end
    end
)

--- 将所有与选中项同名的远程对象从 RemoteSpy 中排除
newButton(
    "排除(同名)",
    function() return "点击排除所有同名的远程对象。\n排除后 SimpleSpy 将忽略它们，但它们仍可正常使用。" end,
    function()
        if selected then
            blacklist[selected.Name] = true
            TextLabel.Text = "已排除！"
        end
    end
)

--- 清空黑名单
newButton("清黑名单",
function() return "点击清空黑名单。\n排除后 SimpleSpy 将忽略它们，但它们仍可正常使用。" end,
function()
    blacklist = {}
    TextLabel.Text = "黑名单已清空！"
end)

--- 阻止选中的远程对象发往服务器（仍会记录日志）
newButton(
    "拦截(单个)",
    function() return "点击阻止此远程对象发送。\n拦截不会把它从 SimpleSpy 日志中移除，但它不会再发往服务器。" end,
    function()
        if selected then
            blocklist[OldDebugId(selected.Remote)] = true
            TextLabel.Text = "已排除！"
        end
    end
)

--- 阻止所有与选中项同名的远程对象发往服务器（仍会记录日志）
newButton("拦截(同名)",function()
    return "点击阻止所有同名远程对象发送。\n拦截不会把它们从 SimpleSpy 日志中移除，但它们不会再发往服务器。" end,
    function()
        if selected then
            blocklist[selected.Name] = true
            TextLabel.Text = "已排除！"
        end
    end
)

--- 清空黑名单
newButton(
    "清拦截表",
    function() return "点击取消拦截远程对象。\n拦截不会把它们从 SimpleSpy 日志中移除，但它们不会再发往服务器。" end,
    function()
        blocklist = {}
        TextLabel.Text = "拦截列表已清空！"
    end
)

--- 尝试反编译来源脚本
newButton("反编译",
    function()
        return "反编译来源脚本（优先使用增强反编译器）"
    end,function()
        if not (selected and selected.Source) then
            TextLabel.Text = "未找到来源！"
            return
        end
        local Source = selected.Source
        if DecompiledScripts[Source] then
            codebox:setRaw(DecompiledScripts[Source])
            TextLabel.Text = "完成！（已缓存）"
            return
        end
        codebox:setRaw("--[[正在反编译]]")
        local started = tick()
        spawn(function()
            local source, note = doDecompile(Source)
            if source then
                -- 路径生成可能抛错，单独兜一层
                local okPath, pathStr = pcall(v2s, Source)
                local pathText = (okPath and type(pathStr) == "string") and pathStr or tostring(Source)
                local head = ("-- 脚本路径：%s\n-- 耗时 %.2f 秒\n"):format(pathText, tick() - started)
                if note then
                    head = head .. "-- 提示：" .. note .. "\n"
                end
                head = head .. "\n"
                DecompiledScripts[Source] = head .. source
                codebox:setRaw(DecompiledScripts[Source])
                TextLabel.Text = note and "完成！（有提示）" or "完成！"
            else
                -- 失败结果不写缓存，方便网络/环境恢复后直接重试
                codebox:setRaw(("--[[反编译失败\n%s]]"):format(tostring(note)))
                TextLabel.Text = "反编译失败"
            end
        end)
    end
)

    --[[newButton(
        "返回值",
        function() return "获取远程调用的返回数据" end,
        function()
            if selected then
                local Remote = selected.Remote
                if Remote and Remote:IsA("RemoteFunction") then
                    if selected.returnvalue and selected.returnvalue.data then
                        return codebox:setRaw(v2s(selected.returnvalue.data))
                    end
                    return codebox:setRaw("没有返回数据")
                else
                    codebox:setRaw("需要 RemoteFunction，实际得到 "..(Remote and Remote.ClassName))
                end
            end
        end
    )]]

newButton(
    "信息开关",
    function() return string.format("[%s] 函数信息开关（部分游戏中可能造成卡顿）", configs.funcEnabled and "ENABLED" or "DISABLED") end,
    function()
        realconfigs.funcEnabled = not realconfigs.funcEnabled
        TextLabel.Text = string.format("[%s] 函数信息开关（部分游戏中可能造成卡顿）", configs.funcEnabled and "ENABLED" or "DISABLED")
    end
)

newButton(
    "自动拦截",
    function() return string.format("[%s] [测试版] 智能识别并排除刷屏式的远程调用", configs.autoblock and "ENABLED" or "DISABLED") end,
    function()
        realconfigs.autoblock = not realconfigs.autoblock
        TextLabel.Text = string.format("[%s] [测试版] 智能识别并排除刷屏式的远程调用", configs.autoblock and "ENABLED" or "DISABLED")
        history = {}
        excluding = {}
    end
)

newButton("记录自身",function()
    return ("[%s] 记录由本客户端发出的远程调用"):format(configs.logcheckcaller and "ENABLED" or "DISABLED")
end,
function()
    realconfigs.logcheckcaller = not realconfigs.logcheckcaller
    TextLabel.Text = ("[%s] 记录由本客户端发出的远程调用"):format(configs.logcheckcaller and "ENABLED" or "DISABLED")
end)

--[[newButton("记录返回值",function()
    return ("[测试版] [%s] 记录 RemoteFunction 的返回值"):format(configs.logcheckcaller and "ENABLED" or "DISABLED")
end,
function()
    configs.logreturnvalues = not configs.logreturnvalues
    TextLabel.Text = ("[测试版] [%s] 记录 RemoteFunction 的返回值"):format(configs.logreturnvalues and "ENABLED" or "DISABLED")
end)]]

newButton("高级信息",function()
    return ("[%s] 显示更多远程信息"):format(configs.advancedinfo and "ENABLED" or "DISABLED")
end,
function()
    realconfigs.advancedinfo = not realconfigs.advancedinfo
    TextLabel.Text = ("[%s] 显示更多远程信息"):format(configs.advancedinfo and "ENABLED" or "DISABLED")
end)

--- AC 处置状态：默认静默运行，只有在这里才看得到内部诊断
newButton("AC 状态", function()
    return "点击查看 AC 处置结果、能力探测与降级情况"
end, function()
    if not ACBridge then
        TextLabel.Text = "ACBridge 未加载"
        return
    end
    codebox:setRaw(
        "-- ACBridge 状态\n"
        .. ACBridge.GetStatusText()
        .. "\n\n-- 诊断缓冲（静默模式下仅在此可见）\n"
        .. ACBridge.GetBufferText()
    )
    TextLabel.Text = "已输出到代码框"
end)

--- Actor 侧捕获（默认关闭：部分执行器 run_on_actor 会导致游戏崩溃）
newButton("Actor捕获", function()
    local on = ACBridge and ACBridge.State and ACBridge.State.ActorBridge
    return ("[%s] 捕获 Actor 内部发出的远程调用\n注意：部分执行器上可能崩溃，崩溃后请勿再开"):format(on and "ENABLED" or "DISABLED")
end, function()
    if not ACBridge then return end
    if ACBridge.State.ActorBridge then
        ACBridge.StopActorBridge()
        TextLabel.Text = "Actor 捕获已关闭"
    else
        local ok = ACBridge.StartActorBridge()
        TextLabel.Text = ok and "Actor 捕获已启动" or "Actor 捕获启动失败（详见 AC 状态）"
    end
end)

--- 是否过滤 Roblox 内部流量
newButton("忽略内部", function()
    return ("[%s] 忽略 RobloxReplicatedStorage 下的内部流量"):format(realconfigs.ignoreRobloxInternal and "ENABLED" or "DISABLED")
end, function()
    realconfigs.ignoreRobloxInternal = not realconfigs.ignoreRobloxInternal
    TextLabel.Text = ("[%s] 忽略 Roblox 内部流量"):format(realconfigs.ignoreRobloxInternal and "ENABLED" or "DISABLED")
end)

--- 是否过滤 PlayerModule 来源的调用
newButton("忽略PM", function()
    return ("[%s] 忽略 PlayerModule 发出的调用（移动/输入等噪音）"):format(realconfigs.ignorePlayerModule and "ENABLED" or "DISABLED")
end, function()
    realconfigs.ignorePlayerModule = not realconfigs.ignorePlayerModule
    TextLabel.Text = ("[%s] 忽略 PlayerModule"):format(realconfigs.ignorePlayerModule and "ENABLED" or "DISABLED")
end)

--- 诊断输出开关（默认静默）
newButton("诊断输出", function()
    return ("[%s] 是否把 AC 诊断信息 warn 出来（默认关=静默）"):format(realconfigs.acVerbose and "ENABLED" or "DISABLED")
end, function()
    realconfigs.acVerbose = not realconfigs.acVerbose
    TextLabel.Text = ("[%s] 诊断输出"):format(realconfigs.acVerbose and "ENABLED" or "DISABLED")
end)

newButton("加入Discord",function()
    return "加入 Simple Spy 的 Discord"
end,
function()
    copyToClipboard("https://discord.com/invite/AWS6ez9", TextLabel, "邀请链接已复制到剪贴板")
    if request then
        request({Url = 'http://127.0.0.1:6463/rpc?v=1',Method = 'POST',Headers = {['Content-Type'] = 'application/json', Origin = 'https://discord.com'},Body = http:JSONEncode({cmd = 'INVITE_BROWSER',nonce = http:GenerateGUID(false),args = {code = 'AWS6ez9'}})})
    end
end)

if configs.supersecretdevtoggle then
    newButton("加载 SSV2.2",function()
        return "加载 Simple Spy V2.2"
    end,
    function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/exxtremestuffs/SimpleSpySource/master/SimpleSpy.lua"))()
    end)
    newButton("加载 SSV3",function()
        return "加载 Simple Spy V3"
    end,
    function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/78n/SimpleSpy/main/SimpleSpySource.lua"))()
    end)
    local SuperSecretFolder = Create("Folder",{Parent = SimpleSpy3})
    newButton("超级神秘按钮",function()
        return "不需要说明，你早就知道它是干什么的"
    end,
    function()
        SuperSecretFolder:ClearAllChildren()
        local random = listfiles("Music")
        local NotSound = Create("Sound",{Parent = SuperSecretFolder,Looped = false,Volume = math.random(1,5),SoundId = getsynasset(random[math.random(1,#random)])})
        NotSound:Play()
    end)
end

if table.find({
    Enum.Platform.IOS, Enum.Platform.Android
}, UserInputService:GetPlatform()) then
    Background.Draggable = true
    local QuickCapture = Instance.new("TextButton")
    local UICorner = Instance.new("UICorner")
    QuickCapture.Parent = SimpleSpy3
    QuickCapture.BackgroundColor3 = Color3.fromRGB(37, 36, 38)
    QuickCapture.BackgroundTransparency = 0.14
    QuickCapture.Position = UDim2.new(0.529, 0, 0, 0)
    QuickCapture.Size = UDim2.new(0, 32, 0, 33)
    QuickCapture.Font = Enum.Font.SourceSansBold
    QuickCapture.Text = "Spy"
    QuickCapture.TextColor3 = Background.Visible and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(252, 51, 51)
    QuickCapture.TextSize = 16
    QuickCapture.TextWrapped = true
    QuickCapture.ZIndex = 10
    QuickCapture.Draggable = true
    UICorner.CornerRadius = UDim.new(0.5, 0)
    UICorner.Parent = QuickCapture
    QuickCapture.MouseButton1Click:Connect(function()
        Background.Visible = not Background.Visible
        QuickCapture.TextColor3 = Background.Visible and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(252, 51, 51)
    end)
end

-- ============================================================================
-- 许可与来源声明
-- ----------------------------------------------------------------------------
-- 本文件基于 SimpleSpy（https://github.com/78n/SimpleSpy）修改，
-- 合并了来自 Cobalt（https://github.com/notpoiu/cobalt，作者 deivid / upio）
-- 的反作弊处置与痕迹收敛思路。Cobalt 采用 Apache-2.0 许可：
--
--   Licensed under the Apache License, Version 2.0 (the "License");
--   you may not use this file except in compliance with the License.
--   You may obtain a copy of the License at
--       http://www.apache.org/licenses/LICENSE-2.0
--
-- 实质修改：新增 ACBridge 层（执行器能力探测与降级、统一 hook 登记与还原、
-- Adonis 定点处置、调用来源多因素过滤、栈隐藏、静默启动、Actor 侧可选捕获）。
--
-- 使用提醒：本层只降低出现可观察痕迹的概率，不构成对任何反作弊的免疫；
-- 请勿用于破坏多人游戏公平性。若公开发布本合并产物，请保留以上声明。
-- ============================================================================
