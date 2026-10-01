-- ActionBarProfiles.lua (WoW 1.12)
-- 经过Sunelgy优化的轻量版本：按需扫描 / 降低Tooltip与拾取操作 / 避免不必要表分配
-- 作者：Sunelgy在原作者基础上优化，武藤纯子酱修复宏逻辑

-- 全局状态与常量定义
local ABP_PlayerName = nil -- 当前角色标识：角色名 of 服务器名
local MAX_ACTIONS = 144 -- 最大动作槽数量
local ABP_SavingInProgress = false -- 保存/加载动作条期间抑制变化事件，防止自触发自动保存
-- 客户端会把 ACTIONBAR_SLOT_CHANGED 延后派发：保存/加载结束后标志位已复位，
-- 但这些延迟事件才刚到达，仅靠标志位无法拦住，会形成“自己触发自己保存”的循环。
-- 因此再用一个时间窗口兜底，见 ABP_SelfChangeUntil。
local ABP_SelfChangeUntil = 0 -- 自身改动后继续忽略变化事件的截止时间（GetTime 基准）
local ABP_SelfChangeGrace = 1 -- 该窗口的时长（秒）
local ABP_DebugLevel = 0 -- 诊断输出级别：0=关，1=按防抖窗口汇总，2=事件逐条打印
-- 诊断统计（仅运行时）：事件按"接受 / 被忽略"计数，最后汇总成一行，避免逐条刷屏
local ABP_StatAccepted = 0
local ABP_StatIgnoredSelf = 0
local ABP_StatIgnoredStartup = 0
local ABP_StatIgnoredNoise = 0 -- 被廉价指纹判定为"内容没变"而丢掉的噪音事件
local ABP_StatFirstAccepted = nil
local ABP_FirstWorldEnter = true -- 本次登录/重载是否还没进过世界
-- 每个槽位的"廉价指纹"（动作文字 + 图标）：用来 O(1) 判断某个动作条事件是不是真的改了内容。
-- 拾取/采药等背包变动后客户端补发的 ACTIONBAR_SLOT_CHANGED 不会让它变化，于是被直接丢掉。
local ABP_SlotTexture = {}
local ABP_SlotMacro = {}
local ABP_CacheDirty = true -- 需要重建廉价指纹（登录、加载配置、换页/换形态之后）

-- 自动保存的防抖与登录静默窗口（保存任务 ABP_RunSaveJob 也会用到，故提前声明）
local ABP_PendingSave = false -- 是否有待保存的变化
local ABP_LastChangeTime = 0 -- 最近一次被接受的变化时间
local ABP_DebounceInterval = 5 -- 防抖间隔（秒）
local ABP_StartupDelay = 30 -- 登录/重载后的静默窗口期（秒）
local ABP_StartupTime = 0 -- 静默窗口计时起点

-- 斜杠命令关键字（中文）
local CMD_SAVE   = "保存"
local CMD_LOAD   = "加载"
local CMD_REMOVE = "删除"
local CMD_LIST   = "列表"
local CMD_DEBUG  = "debug"

-- 判断表中是否有元素（用于空配置检测）
local function hasElements(T)
    if type(T) ~= "table" then return 0 end
    for _ in pairs(T) do
        return 1
    end
    return 0
end

-- 安全读取工具 Tooltip 第一行文本，返回 (左文本, 右文本)
local function ABP_GetTooltipLine1()
    local left, right = nil, nil
    if ABP_TooltipTextLeft1 and ABP_TooltipTextLeft1:IsShown() then
        left = ABP_TooltipTextLeft1:GetText()
    end
    if ABP_TooltipTextRight1 and ABP_TooltipTextRight1:IsShown() then
        right = ABP_TooltipTextRight1:GetText()
    end
    return left, right
end

-- 组合"技能名 + 等级"作为唯一键（等级为空时仅用技能名）
local function ABP_ComposeSpellKey(name, rankText)
    if not name or name == "" then return nil end
    if rankText and rankText ~= "" then
        return name .. " " .. rankText
    end
    return name
end

-- 向默认聊天框输出消息
local function ABP_Msg(msg)
    if DEFAULT_CHAT_FRAME and msg then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

-- 诊断输出：级别 1 起生效（/abprofile debug 打开）
local function ABP_Dbg(msg)
    if ABP_DebugLevel >= 1 and DEFAULT_CHAT_FRAME and msg then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33aaff[ABP调试]|r " .. msg)
    end
end

-- 逐条事件输出：只有级别 2 才打（/abprofile debug all），平时用汇总行代替
local function ABP_Dbg2(msg)
    if ABP_DebugLevel >= 2 and DEFAULT_CHAT_FRAME and msg then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33aaff[ABP调试]|r " .. msg)
    end
end

-- 输出一个防抖窗口内的事件统计并清零：一条汇总行代替成百上千条逐事件日志
local function ABP_DbgFlushEventStats()
    if ABP_DebugLevel < 1 then return end
    if ABP_StatAccepted == 0 and ABP_StatIgnoredSelf == 0
       and ABP_StatIgnoredStartup == 0 and ABP_StatIgnoredNoise == 0 then
        return
    end

    local text = "事件窗口：接受 " .. ABP_StatAccepted .. " 个"
    if ABP_StatFirstAccepted then
        text = text .. "（首个 " .. ABP_StatFirstAccepted .. "）"
    end
    text = text .. "，忽略噪音 " .. ABP_StatIgnoredNoise
        .. " 个、自触发 " .. ABP_StatIgnoredSelf
        .. " 个、登录窗口 " .. ABP_StatIgnoredStartup .. " 个"
    ABP_Dbg(text)

    ABP_StatAccepted = 0
    ABP_StatIgnoredSelf = 0
    ABP_StatIgnoredStartup = 0
    ABP_StatIgnoredNoise = 0
    ABP_StatFirstAccepted = nil
end

-- 时间戳文本：避免依赖 string.format 的浮点格式（1.12 的 Lua 版本较老）
local function ABP_TimeText(t)
    return tostring(math.floor(t * 10) / 10) .. "s"
end

-- 登记一次"真的改了动作条"的变化：计入统计并进入 5 秒防抖
local function ABP_NoteChange(what)
    ABP_StatAccepted = ABP_StatAccepted + 1
    if not ABP_StatFirstAccepted then
        ABP_StatFirstAccepted = what .. " @" .. ABP_TimeText(GetTime())
    end
    ABP_Dbg2("接受 " .. what)
    ABP_PendingSave = true
    ABP_LastChangeTime = GetTime()
end

-- 重建全部槽位的廉价指纹（不做 Tooltip、不碰光标，开销极小）
local function ABP_RebuildCheapCache()
    for i = 1, MAX_ACTIONS do
        if HasAction(i) then
            ABP_SlotTexture[i] = GetActionTexture(i)
            ABP_SlotMacro[i] = GetActionText(i)
        else
            ABP_SlotTexture[i] = nil
            ABP_SlotMacro[i] = nil
        end
    end
    ABP_CacheDirty = false
end

-- ===== 触发源：只认"真的往动作槽里放了东西" =====
-- 1) 挂钩 PlaceAction：拖技能/物品/宏到按钮、以及别的插件改写动作条都会走这里；
--    客户端因拾取/采药/开箱等背包变动补发的动作条事件完全不经过它。
-- 2) ACTIONBAR_SLOT_CHANGED：只在该槽位的廉价指纹（宏名 / 图标）真的变了时才认。
-- 其余事件一律在 O(1) 里丢掉，不会触发任何扫描。
local ABP_OrigPlaceAction = PlaceAction
PlaceAction = function(slot)
    ABP_OrigPlaceAction(slot)

    if not ABP_Enabled or ABP_SavingInProgress or not ABP_PlayerName then return end
    if GetTime() < ABP_SelfChangeUntil then return end
    if GetTime() - ABP_StartupTime < ABP_StartupDelay then return end

    ABP_NoteChange("PlaceAction 槽位" .. tostring(slot) .. " @" .. ABP_TimeText(GetTime()))
end

-- 光标上是否正拿着东西（玩家在拖拽/放置技能、物品或宏）
local function ABP_CursorBusy()
    if CursorHasItem and CursorHasItem() then return true end
    if CursorHasSpell and CursorHasSpell() then return true end
    if CursorHasMacro and CursorHasMacro() then return true end
    return false
end

-- 将工具 Tooltip 绑定到 UIParent（供保存/加载时探测动作与物品名称）
local function ABP_TooltipAttach()
    if ABP_Tooltip and ABP_Tooltip.SetOwner then
        ABP_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
end

-- ===== 保存任务 =====
-- 一帧之内对几十个槽位做 SetAction（生成 Tooltip）+ PickupAction/PlaceAction 会造成明显卡顿，
-- 所以保存拆到多帧执行；而且只有真的发生变化的动作条才会走到这里（见上面的触发源）。
local ABP_Job = nil            -- 进行中的保存任务
local ABP_JobSlotsPerFrame = 6 -- 每帧处理的槽位数（越小越不卡，总耗时越长）

-- 中断进行中的保存任务（加载配置前、或新的保存请求到来时）
local function ABP_JobAbort()
    if not ABP_Job then return end
    SetCVar("autoSelfCast", ABP_Job.scStatus)
    ABP_Job = nil
    ABP_SavingInProgress = false
    ABP_SelfChangeUntil = GetTime() + ABP_SelfChangeGrace
end

-- 完整扫描单个槽位：宏 -> 技能 -> 物品（技能/物品靠 PickupAction + CursorHasSpell 判定）
-- 顺带刷新该槽位的廉价指纹，供事件过滤使用
local function ABP_ScanSlot(dest, i)
    if not HasAction(i) then
        ABP_SlotTexture[i] = nil
        ABP_SlotMacro[i] = nil
        return
    end

    ABP_SlotTexture[i] = GetActionTexture(i)
    ABP_SlotMacro[i] = GetActionText(i)

    local macroName = GetActionText(i)
    if macroName and macroName ~= "" then
        dest.macros[i] = macroName
        return
    end

    ABP_Tooltip:ClearLines()
    ABP_Tooltip:SetAction(i)

    local isSpell = false
    PickupAction(i)
    isSpell = CursorHasSpell()
    PlaceAction(i)

    if isSpell then
        local spellName, rankText = ABP_GetTooltipLine1()
        if spellName and spellName ~= "" then
            dest.spells[i] = {
                name = spellName,
                rank = rankText,
            }
        end
    else
        local itemName = (select(1, ABP_GetTooltipLine1()))
        if itemName and itemName ~= "" then
            dest.items[i] = itemName
        end
    end
end

-- 比较两份配置内容是否完全一致（自动保存时用来跳过无意义的重复写入）
local function ABP_IsSameProfile(a, b)
    if not a or not b then return false end
    for _, group in ipairs({ "spells", "macros", "items" }) do
        local ta, tb = a[group], b[group]
        if ta and tb then
            for k, v in pairs(ta) do
                local w = tb[k]
                if type(v) == "table" then
                    if type(w) ~= "table" or w.name ~= v.name or w.rank ~= v.rank then
                        return false
                    end
                elseif w ~= v then
                    return false
                end
            end
            for k in pairs(tb) do
                if ta[k] == nil then return false end
            end
        elseif ta ~= tb then
            return false
        end
    end
    return true
end

-- 汇总两份配置的槽位差异，仅用于调试输出（最多列 8 条）
local function ABP_DiffSummary(old, new)
    local parts = {}
    local function describe(v)
        if type(v) == "table" then
            local text = tostring(v.name or "?")
            if v.rank and v.rank ~= "" then text = text .. " " .. v.rank end
            return text
        end
        if v == nil then return "空" end
        return tostring(v)
    end

    for _, group in ipairs({ "spells", "macros", "items" }) do
        local ta = (old and old[group]) or {}
        local tb = (new and new[group]) or {}
        local slots = {}
        for k in pairs(ta) do slots[k] = true end
        for k in pairs(tb) do slots[k] = true end

        local keys = {}
        for k in pairs(slots) do table.insert(keys, k) end
        table.sort(keys)

        for _, k in ipairs(keys) do
            local a, b = ta[k], tb[k]
            local changed
            if type(a) == "table" or type(b) == "table" then
                changed = type(a) ~= type(b) or type(a) == "table" and (a.name ~= b.name or a.rank ~= b.rank)
            else
                changed = a ~= b
            end
            if changed then
                table.insert(parts, group .. " 槽" .. k .. " " .. describe(a) .. " → " .. describe(b))
                if table.getn(parts) >= 8 then
                    return table.concat(parts, "；") .. " …"
                end
            end
        end
    end

    if table.getn(parts) == 0 then return "无" end
    return table.concat(parts, "；")
end

-- 保存当前动作条到指定配置（异步：真正的扫描与写入由 ABP_RunSaveJob 分帧完成）
-- silent 为 true 时不输出提示；skipIfUnchanged 为 true 时内容没变就不写入、不提示
-- 返回是否已开始执行
function ABP_SaveProfile(profileName, silent, skipIfUnchanged)
    if not profileName or profileName == "" then return false end
    if not ABP_PlayerName then return false end
    if not ABP_Layout then ABP_Layout = {} end
    if not ABP_Layout[ABP_PlayerName] then ABP_Layout[ABP_PlayerName] = {} end

    if ABP_Job then ABP_JobAbort() end

    ABP_TooltipAttach()

    ABP_Job = {
        name = profileName,
        silent = silent,
        skipIfUnchanged = skipIfUnchanged,
        phase = "scan",  -- scan=分帧完整扫描 done=比对写入
        i = 0,           -- 已处理到的槽位
        dest = {
            spells = {},  -- [slot] = { name=, rank= }
            macros = {},  -- [slot] = macroName
            items  = {},  -- [slot] = itemName
        },
        previous = ABP_Layout[ABP_PlayerName][profileName],
        scStatus = GetCVar("autoSelfCast"),
    }

    -- autoSelfCast 只在任务期间关闭一次，避免每帧改 CVar 引起动作按钮整体刷新
    SetCVar("autoSelfCast", 0)

    ABP_SavingInProgress = true
    ABP_Dbg('开始扫描动作条（"' .. profileName .. '"）')
    return true
end

-- 分帧执行保存任务：每帧最多处理 ABP_JobSlotsPerFrame 个槽位
function ABP_RunSaveJob()
    local job = ABP_Job
    if not job then return end

    local last = job.i + ABP_JobSlotsPerFrame
    if last > MAX_ACTIONS then last = MAX_ACTIONS end

    -- 第一段：分帧完整扫描（宏/技能/物品）
    if job.phase == "scan" then
        -- 玩家正在拖拽：本帧不动光标，等下一帧再继续（并记下，收尾时补一次比对）
        if ABP_CursorBusy() then
            job.pausedForCursor = true
            ABP_Dbg("光标上有物品/技能，暂停扫描")
            return
        end

        for i = job.i + 1, last do
            ABP_ScanSlot(job.dest, i)
        end
        job.i = last

        if job.i >= MAX_ACTIONS then
            SetCVar("autoSelfCast", job.scStatus) -- 扫描结束，还原 CVar
            ABP_CacheDirty = false
            job.phase = "done"
        end
        return
    end

    -- 收尾：比对结果，决定是否写入
    ABP_SelfChangeUntil = GetTime() + ABP_SelfChangeGrace
    ABP_SavingInProgress = false
    ABP_Job = nil

    -- 扫描期间因为玩家拖拽暂停过：再排一次比对，避免漏掉拖拽带来的变化
    if job.pausedForCursor then
        ABP_PendingSave = true
        ABP_LastChangeTime = GetTime()
    end

    if job.skipIfUnchanged and ABP_IsSameProfile(job.previous, job.dest) then
        ABP_Dbg('比对结果（"' .. job.name .. '"）：内容与已存配置一致，本次不写入')
        return
    end

    ABP_Dbg('写入 "' .. job.name .. '"：' .. ABP_DiffSummary(job.previous, job.dest))

    ABP_Layout[ABP_PlayerName][job.name] = job.dest
    if not job.silent then
        ABP_Msg('配置文件 "' .. job.name .. '" 已保存.')
    end
end

-- 扫描法术书，构建"技能键(名+等级) -> 法术ID"映射（只找需要的技能，找到全部即停）
local function ABP_BuildNeededSpellMap(neededSpellKeys)
    local result = {}
    if not neededSpellKeys or not next(neededSpellKeys) then return result end

    local remaining = {}
    local remainingCount = 0
    for key in pairs(neededSpellKeys) do
        remaining[key] = true
        remainingCount = remainingCount + 1
    end

    for tab = 1, MAX_SKILLLINE_TABS do
        local name, _, offset, numSpells = GetSpellTabInfo(tab)
        if not name then break end
        for s = offset + 1, offset + numSpells do
            local n, r = GetSpellName(s, BOOKTYPE_SPELL)
            local key = ABP_ComposeSpellKey(n, (r ~= "" and r or nil))
            if key and remaining[key] then
                result[key] = s
                remaining[key] = nil
                remainingCount = remainingCount - 1
                if remainingCount == 0 then
                    return result
                end
            end
        end
    end
    return result
end

-- 遍历 19 个装备位，构建"物品名 -> 装备槽位"映射（找齐即停）
local function ABP_FindItemsInEquipment(neededItems)
    local equipMap = {}
    if not neededItems or not next(neededItems) then return equipMap end

    ABP_TooltipAttach()
    local remaining = {}
    local leftCount = 0
    for name in pairs(neededItems) do remaining[name] = true; leftCount = leftCount + 1 end

    for slot = 1, 19 do
        ABP_Tooltip:ClearLines()
        local hasItem = ABP_Tooltip:SetInventoryItem("player", slot)
        if hasItem then
            local itemName = (select(1, ABP_GetTooltipLine1()))
            if itemName and remaining[itemName] then
                equipMap[itemName] = slot
                remaining[itemName] = nil
                leftCount = leftCount - 1
                if leftCount == 0 then
                    break
                end
            end
        end
    end
    return equipMap
end

-- 遍历背包与随身包，构建"物品名 -> {bag, slot}"映射（找齐即停）
local function ABP_FindItemsInBags(neededItems)
    local bagMap = {}
    if not neededItems or not next(neededItems) then return bagMap end

    ABP_TooltipAttach()
    local remaining = {}
    local leftCount = 0
    for name in pairs(neededItems) do remaining[name] = true; leftCount = leftCount + 1 end

    for bag = 0, NUM_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local texture = (select(1, GetContainerItemInfo(bag, slot)))
                if texture then
                    ABP_Tooltip:ClearLines()
                    ABP_Tooltip:SetBagItem(bag, slot)
                    local itemName = (select(1, ABP_GetTooltipLine1()))
                    if itemName and remaining[itemName] then
                        bagMap[itemName] = { bag = bag, slot = slot }
                        remaining[itemName] = nil
                        leftCount = leftCount - 1
                        if leftCount == 0 then
                            return bagMap
                        end
                    end
                end
            end
        end
    end
    return bagMap
end

-- 加载配置到动作条（完全覆盖当前布局）
-- 先预构建技能/物品映射表，再按槽位回填；配置中为空的槽位会被清空
function ABP_LoadProfile(profileName)
    if not ABP_PlayerName or not ABP_Layout or not ABP_Layout[ABP_PlayerName]
       or not ABP_Layout[ABP_PlayerName][profileName] then
        ABP_Msg('配置文件 "' .. tostring(profileName) .. '" 以前没有保存，无法加载.')
        return
    end

    -- 有保存任务在跑就先中断，避免两个流程同时操作动作条
    ABP_JobAbort()

    local profile = ABP_Layout[ABP_PlayerName][profileName]
    local spells = profile.spells or {}
    local macros = profile.macros or {}
    local items  = profile.items  or {}

    local neededSpellKeys = {}
    local neededItemNames = {}

    for slot, info in pairs(spells) do
        local key = ABP_ComposeSpellKey(info.name, info.rank)
        if key then neededSpellKeys[key] = true end
    end
    for slot, itemName in pairs(items) do
        if itemName and itemName ~= "" then neededItemNames[itemName] = true end
    end

    local spellKeyToId   = ABP_BuildNeededSpellMap(neededSpellKeys)
    local equipItemToId  = ABP_FindItemsInEquipment(neededItemNames)

    do
        -- 只在装备位上找不到的物品，才继续去背包里找
        local remaining = {}
        for name in pairs(neededItemNames) do
            if not equipItemToId[name] then remaining[name] = true end
        end
        var_bagMap = ABP_FindItemsInBags(remaining) -- 遗留的全局变量，仅作返回值暂存
    end
    local bagItemToLoc = var_bagMap or {}

    ABP_TooltipAttach()
    local scStatus = GetCVar("autoSelfCast")
    SetCVar("autoSelfCast", 0)

    ABP_SavingInProgress = true
    for i = 1, MAX_ACTIONS do
        repeat
            local sp = spells[i]
            if sp then
                local key = ABP_ComposeSpellKey(sp.name, sp.rank)
                local sid = key and spellKeyToId[key] or nil
                if sid then
                    PickupSpell(sid, BOOKTYPE_SPELL)
                    PlaceAction(i)
                    ClearCursor() -- 清空光标，防止被覆盖槽位的旧内容残留并干扰后续槽位
                end
                break
            end

            local mname = macros[i]
            if mname and mname ~= "" then
                local picked = false
                if GetSuperMacroInfo and GetSuperMacroInfo(mname, "texture") then
                    PickupMacro(0, mname)
                    PlaceAction(i)
                    ClearCursor() -- 清空光标残留
                    picked = true
                else
                    local idx = GetMacroIndexByName(mname)
                    if idx and idx > 0 then
                        PickupMacro(idx)
                        PlaceAction(i)
                        ClearCursor() -- 清空光标残留
                        picked = true
                    end
                end
                break
            end

            local iname = items[i]
            if iname and iname ~= "" then
                local eslot = equipItemToId[iname]
                if eslot then
                    PickupInventoryItem(eslot)
                    PlaceAction(i)
                    ClearCursor() -- 清空光标残留
                    break
                end
                local loc = bagItemToLoc[iname]
                if loc then
                    PickupContainerItem(loc.bag, loc.slot)
                    PlaceAction(i)
                    ClearCursor() -- 清空光标残留
                    break
                end
                break
            end

            -- 保存的配置中该槽位为空：拾起当前动作并丢弃，实现完全覆盖
            PickupAction(i)
            ClearCursor()
        until true
    end
    ABP_SelfChangeUntil = GetTime() + ABP_SelfChangeGrace
    SetCVar("autoSelfCast", scStatus)
    ABP_SavingInProgress = false

    -- 动作条已被程序改写：廉价指纹作废，等下次重建后再用来过滤事件
    ABP_CacheDirty = true

    ABP_Msg('配置文件 "' .. profileName .. '" 已加载.')
end

-- 列出当前角色的所有配置名
function ABP_ListProfiles()
    if not ABP_PlayerName or not ABP_Layout or not ABP_Layout[ABP_PlayerName]
       or hasElements(ABP_Layout[ABP_PlayerName]) == 0 then
        ABP_Msg("你没有为这个人物保存的配置文件.")
        return
    end
    ABP_Msg("这个人物的配置文件有:")
    for profileName in pairs(ABP_Layout[ABP_PlayerName]) do
        ABP_Msg(profileName)
    end
end

-- 删除指定配置
function ABP_RemoveProfile(profileName)
    if not ABP_PlayerName or not ABP_Layout
       or not ABP_Layout[ABP_PlayerName]
       or not ABP_Layout[ABP_PlayerName][profileName] then
        ABP_Msg("你没有配置文件 '" .. tostring(profileName) .. "' 保存在这个人物上.")
        return
    end
    ABP_Layout[ABP_PlayerName][profileName] = nil
    ABP_Msg("配置文件 '" .. profileName .. "' 已经删除.")
end

-- 自动保存配置名：职业+角色名
function ABP_GetAutoProfileName()
    if not ABP_PlayerName then return nil end
    local className = UnitClass("player")
    local playerName = UnitName("player")
    if not className or className == "" or not playerName or playerName == "" then return nil end
    return className .. playerName
end

-- 执行自动保存（保存到 "职业+角色名" 配置）
-- 实际扫描分帧进行，内容一致时不会写入、也不会提示
function ABP_AutoSaveProfile()
    local profileName = ABP_GetAutoProfileName()
    if not profileName then return nil end
    ABP_DbgFlushEventStats()
    ABP_SaveProfile(profileName, false, true)
    return profileName
end

-- 事件驱动：动作条内容变化后，等待 5 秒无再次变化才自动保存（防抖，避免频繁保存）
function ABP_OnActionBarChanged(evtName, slot)
    local now = GetTime()
    local evtText = tostring(evtName or "?") .. " 槽位" .. tostring(slot or "-") .. " @" .. ABP_TimeText(now)

    -- 静默窗口期内忽略动作条变化，防止登录时客户端恢复动作条覆盖已有配置
    if now - ABP_StartupTime < ABP_StartupDelay then
        ABP_StatIgnoredStartup = ABP_StatIgnoredStartup + 1
        ABP_Dbg2("忽略 " .. evtText .. "（登录静默窗口内）")
        return
    end
    -- 自身改动（保存/加载）产生的延迟事件不算玩家操作
    if not ABP_PlayerName or ABP_SavingInProgress or now < ABP_SelfChangeUntil then
        ABP_StatIgnoredSelf = ABP_StatIgnoredSelf + 1
        ABP_Dbg2("忽略 " .. evtText .. "（自触发窗口内）")
        return
    end

    -- 廉价过滤（不碰 Tooltip、不碰光标、不改 CVar）：
    -- 只有该槽位的宏名 / 图标真的变了，才认为这条事件需要保存。
    -- 客户端在拾取、采药、开箱等背包变动后补发的 ACTIONBAR_SLOT_CHANGED 内容并没有变，
    -- 到这里就被丢掉，绝不会走到扫描与卡顿。
    local slotNum = tonumber(slot)
    if not slotNum or slotNum < 1 or slotNum > MAX_ACTIONS then
        ABP_StatIgnoredNoise = ABP_StatIgnoredNoise + 1
        ABP_Dbg2("忽略 " .. evtText .. "（无有效槽位，按噪音丢弃）")
        return
    end

    if ABP_CacheDirty then ABP_RebuildCheapCache() end

    local macroText = GetActionText(slotNum)
    local texture = GetActionTexture(slotNum)
    if (macroText or "") == (ABP_SlotMacro[slotNum] or "") and texture == ABP_SlotTexture[slotNum] then
        ABP_StatIgnoredNoise = ABP_StatIgnoredNoise + 1
        ABP_Dbg2("忽略 " .. evtText .. "（该槽位内容未变）")
        return
    end

    -- 内容确实变了：刷新指纹并登记变化
    ABP_SlotMacro[slotNum] = macroText
    ABP_SlotTexture[slotNum] = texture
    ABP_NoteChange(evtText)
end

-- 由独立计时帧每帧驱动：先推进进行中的保存任务，再处理防抖到期的自动保存
function ABP_OnUpdate(frame, elapsed)
    -- 保存任务分帧执行，未完成前不启动新的
    if ABP_Job then
        ABP_RunSaveJob()
        return
    end

    -- 关闭状态下不做自动保存（但上面手动触发的保存任务仍会继续推进）
    if not ABP_Enabled then return end

    if not ABP_PlayerName or not ABP_PendingSave then return end
    if GetTime() - ABP_LastChangeTime < ABP_DebounceInterval then return end
    -- 玩家手上还拿着东西（拖拽中）：推迟保存，避免扫描时的拾取/放置打断操作
    if ABP_CursorBusy() then
        ABP_Dbg("光标上有物品/技能，推迟本次自动保存")
        ABP_LastChangeTime = GetTime()
        return
    end
    ABP_PendingSave = false
    ABP_AutoSaveProfile()
end

-- 创建独立的自动保存计时帧
function ABP_CreateTimerFrame()
    if ABP_TimerFrame then return end
    ABP_TimerFrame = CreateFrame("Frame", "ABP_TimerFrame", UIParent)
    ABP_TimerFrame:SetScript("OnUpdate", ABP_OnUpdate)
    ABP_TimerFrame:Show()
end

-- ===== 插件开关 =====
-- off（默认）：不再监听动作条事件、不再自动保存；小地图按钮与菜单功能完全不变。
-- on：恢复监听与自动保存。状态保存在 SavedVariables 里（ABP_Enabled）。
function ABP_SetEnabled(enabled, silent)
    ABP_Enabled = enabled and true or false

    -- 关闭时先收尾：中断进行中的保存任务、清掉待保存标记
    if not ABP_Enabled then
        ABP_JobAbort()
        ABP_PendingSave = false
    end

    local frame = getglobal("ActionBarProfiles_IconFrame")
    if frame then
        if ABP_Enabled then
            frame:RegisterEvent("PLAYER_ENTERING_WORLD")
            frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
            frame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
            frame:RegisterEvent("UPDATE_MULTI_CAST_ACTIONBAR")
        else
            frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
            frame:UnregisterEvent("ACTIONBAR_SLOT_CHANGED")
            frame:UnregisterEvent("UPDATE_BONUS_ACTIONBAR")
            frame:UnregisterEvent("UPDATE_MULTI_CAST_ACTIONBAR")
        end
    end

    if not silent then
        if ABP_Enabled then
            ABP_Msg("ActionBarProfiles 已开启：动作条改动会在 5 秒后自动保存.")
        else
            ABP_Msg("ActionBarProfiles 已关闭：不再监听动作条、不再自动保存.")
            ABP_Msg("小地图按钮与手动 保存|加载|删除|列表 仍然可用；重新开启：/abprofile on")
        end
    end
end

-- 插件加载：注册事件与斜杠命令
function ABP_OnLoad()
    this:RegisterEvent("VARIABLES_LOADED")
    this:RegisterEvent("PLAYER_ENTERING_WORLD")
    this:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    this:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
    this:RegisterEvent("UPDATE_MULTI_CAST_ACTIONBAR")
    SLASH_ABP1 = "/abprofile"
    SlashCmdList["ABP"] = function(msg) ABP_SlashCommand(msg or "") end
end

-- 事件分发：VARIABLES_LOADED 时初始化，动作条变化事件转发给自动保存防抖逻辑
function ABP_OnEvent()
    if event == "VARIABLES_LOADED" then
        ABP_PlayerName = UnitName("player") .. " of " .. GetCVar("realmName")
        ABP_StartupTime = GetTime() -- 记录静默窗口期起点

        if not ABP_Layout then ABP_Layout = {} end
        if not ABP_Layout[ABP_PlayerName] then ABP_Layout[ABP_PlayerName] = {} end

        if ABP_ButtonPosition == nil then ABP_ButtonPosition = 60 end

        -- 开关状态：SavedVariables 里没有就默认关闭（首次使用需 /abprofile on 开启）
        if ABP_Enabled == nil then ABP_Enabled = false end

        UIDropDownMenu_Initialize(getglobal("ABP_DropDownMenu"), ABP_DropDownMenu_OnLoad, "MENU")
        ABPButton_UpdatePosition()
        ABP_CreateTimerFrame()
        ABP_SetEnabled(ABP_Enabled, true)
        if not ABP_Enabled then
            ABP_Msg("ActionBarProfiles 当前是关闭状态（不监听动作条、不自动保存）. 开启：/abprofile on")
            ABP_Msg("查看全部命令：/abprofile")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 加载画面结束后才是客户端恢复/回填动作条的高峰期，静默窗口从这里重新计时
        -- （只在登录/重载后的第一次进入世界重置，之后切换地图不会重置）
        if ABP_FirstWorldEnter then
            ABP_FirstWorldEnter = false
            ABP_StartupTime = GetTime()
            ABP_CacheDirty = true -- 客户端刚回填完动作条，廉价指纹要重建
            ABP_Dbg("进入世界，登录静默窗口重新计时（" .. ABP_StartupDelay .. " 秒）")
        end
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        ABP_OnActionBarChanged(event, arg1)
    elseif event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_MULTI_CAST_ACTIONBAR" then
        -- 换形态 / 翻页：槽位整体换了一套内容，只作废廉价指纹，不触发保存
        ABP_CacheDirty = true
        ABP_Dbg2("忽略 " .. tostring(event) .. "（换页/换形态，仅重建廉价指纹）")
    end
end

-- 命令提示：列出所有可用命令，并带上当前开关/诊断状态
function ABP_PrintHelp()
    ABP_Msg("ActionBarProfiles - 动作条配置保存/加载")
    ABP_Msg("  /abprofile 保存 <名字>    把当前动作条存成配置")
    ABP_Msg("  /abprofile 加载 <名字>    加载配置，完全覆盖当前动作条")
    ABP_Msg("  /abprofile 删除 <名字>    删除配置")
    ABP_Msg("  /abprofile 列表           列出本角色的所有配置")
    ABP_Msg("  /abprofile on | off       开启/关闭插件（当前：" .. (ABP_Enabled and "开启" or "关闭") .. "）")
    ABP_Msg("  /abprofile debug          诊断输出：关 / 按防抖窗口汇总（当前：" .. ABP_DebugLevel .. " 级）")
    ABP_Msg("  /abprofile debug all      诊断输出：每条动作条事件都打印")
    ABP_Msg("不带参数的 /abprofile 就是这份提示.")
    ABP_Msg("ActionBarProfiles, 由Kronos的<Vanguard>制作, 60addons汉化")
end

-- 斜杠命令分发：解析"保存/加载/删除/列表 + 配置名"并调用对应函数
function ABP_SlashCommand(msg)
    msg = msg or ""

    -- 去掉首尾空格：/abprofile 后面多打了空格也当成没带参数
    local cmd = string.gsub(msg, "^%s*(.-)%s*$", "%1")
    if cmd == "" then
        ABP_PrintHelp()
        return
    end

    local lowerCmd = string.lower(cmd)

    -- 帮助别名
    if lowerCmd == "?" or lowerCmd == "help" or cmd == "帮助" then
        ABP_PrintHelp()
        return
    end

    -- 诊断开关：/abprofile debug（摘要），/abprofile debug all（每条事件都打印）
    -- 要求出现在命令开头，避免配置文件名字里含 debug 时误判
    if string.find(lowerCmd, "^%s*" .. CMD_DEBUG) then
        if string.find(lowerCmd, "all", 1, true) then
            ABP_DebugLevel = 2
        else
            ABP_DebugLevel = (ABP_DebugLevel == 0) and 1 or 0
        end

        if ABP_DebugLevel == 0 then
            ABP_Msg("ActionBarProfiles 诊断输出已关闭.")
        elseif ABP_DebugLevel == 1 then
            ABP_Msg("ActionBarProfiles 诊断输出已打开（按防抖窗口汇总，不刷屏）.")
            ABP_Msg("会打印：事件汇总、指纹/内容比对结果、写入的槽位差异.")
            ABP_Msg("想连每个事件都看，用 /abprofile debug all")
        else
            ABP_Msg("ActionBarProfiles 诊断输出已打开：all，每条动作条事件都会打印（可能刷屏）.")
            ABP_Msg("回到汇总模式：/abprofile debug")
        end
        return
    end

    -- 插件开关：/abprofile on | /abprofile off
    if string.find(lowerCmd, "^%s*off") then
        ABP_SetEnabled(false)
        return
    end
    if string.find(lowerCmd, "^%s*on") then
        ABP_SetEnabled(true)
        return
    end

    for profileName in string.gfind(cmd, CMD_SAVE .. " (.*)") do
        ABP_SaveProfile(profileName)
        return
    end
    for profileName in string.gfind(cmd, CMD_LOAD .. " (.*)") do
        ABP_LoadProfile(profileName)
        return
    end
    for profileName in string.gfind(cmd, CMD_REMOVE .. " (.*)") do
        ABP_RemoveProfile(profileName)
        return
    end
    if string.find(cmd, CMD_LIST, 1, true) then
        ABP_ListProfiles()
        return
    end

    -- 看不懂的命令：给提示，而不是静默什么都不做
    ABP_Msg('无法识别的命令 "' .. cmd .. '"')
    ABP_PrintHelp()
end

-- 构建小地图按钮的下拉菜单
-- 含三级：主菜单（加载/保存/删除）、保存子菜单、删除子菜单
function ABP_DropDownMenu_OnLoad()
    if UIDROPDOWNMENU_MENU_VALUE == "Delete menu" then
        UIDropDownMenu_AddButton({
            text = "选择要删除的布局",
            isTitle = true,
            owner = this:GetParent(),
            justifyH = "CENTER",
        }, UIDROPDOWNMENU_MENU_LEVEL)

        local list = ABP_Layout and ABP_Layout[ABP_PlayerName] or nil
        if list then
            for profileName in pairs(list) do
                UIDropDownMenu_AddButton({
                    text = profileName,
                    value = profileName,
                    func = function() ABP_RemoveProfile(this:GetText()) end,
                    notCheckable = 1,
                    owner = this:GetParent(),
                }, UIDROPDOWNMENU_MENU_LEVEL)
            end
        end
        return
    end

    -- 新增：保存子菜单
    if UIDROPDOWNMENU_MENU_VALUE == "Save menu" then
        UIDropDownMenu_AddButton({
            text = "选择要覆盖的布局",
            isTitle = true,
            owner = this:GetParent(),
            justifyH = "CENTER",
        }, UIDROPDOWNMENU_MENU_LEVEL)

        local list = ABP_Layout and ABP_Layout[ABP_PlayerName] or nil
        if list then
            for profileName in pairs(list) do
                UIDropDownMenu_AddButton({
                    text = profileName,
                    value = profileName,
                    func = function() ABP_SaveProfile(this:GetText()) end,
                    notCheckable = 1,
                    owner = this:GetParent(),
                }, UIDROPDOWNMENU_MENU_LEVEL)
            end
        end

        UIDropDownMenu_AddButton({
            text = "新建...",
            func = function() StaticPopup_Show("ABP_NewProfile") end,
            notCheckable = 1,
            owner = this:GetParent(),
        }, UIDROPDOWNMENU_MENU_LEVEL)
        return
    end

    -- 原默认菜单
    UIDropDownMenu_AddButton({
        text = UnitName("player") .. "的动作条",
        isTitle = true,
        owner = this:GetParent(),
        justifyH = "CENTER",
    }, UIDROPDOWNMENU_MENU_LEVEL)

    local list = ABP_Layout and ABP_Layout[ABP_PlayerName] or nil
    if list then
        for profileName in pairs(list) do
            UIDropDownMenu_AddButton({
                text = profileName,
                func = function() ABP_LoadProfile(this:GetText()) end,
                notCheckable = 1,
                owner = this:GetParent(),
            }, UIDROPDOWNMENU_MENU_LEVEL)
        end
    end

    UIDropDownMenu_AddButton({
        text = "选项",
        isTitle = true,
        justifyH = "CENTER",
    }, UIDROPDOWNMENU_MENU_LEVEL)

    -- 原"保存当前动作条的布局"改为带有子菜单的按钮
    UIDropDownMenu_AddButton({
        text = "保存当前动作条的布局",
        value = "Save menu",
        notCheckable = 1,
        hasArrow = true,
        owner = this:GetParent(),
    }, UIDROPDOWNMENU_MENU_LEVEL)

    UIDropDownMenu_AddButton({
        text = "删除一个布局",
        value = "Delete menu",
        notCheckable = 1,
        hasArrow = true,
    }, UIDROPDOWNMENU_MENU_LEVEL)

    UIDropDownMenu_AddButton({
        text = ABP_Enabled and "关闭 ActionBarProfiles" or "开启 ActionBarProfiles",
        func = function() ABP_SetEnabled(not ABP_Enabled) end,
        notCheckable = 1,
        owner = this:GetParent(),
    }, UIDROPDOWNMENU_MENU_LEVEL)
end

-- 小地图按钮绕小地图旋转的半径
local ABP_ButtonRadius = 78

-- 按保存的角度定位小地图按钮
function ABPButton_UpdatePosition()
    ActionBarProfiles_IconFrame:SetPoint(
        "TOPLEFT", "Minimap", "TOPLEFT",
        54 - (ABP_ButtonRadius * cos(ABP_ButtonPosition)),
        (ABP_ButtonRadius * sin(ABP_ButtonPosition)) - 55
    )
end

-- 按钮被拖动时：根据鼠标相对小地图的位置实时计算角度
function ABPButton_BeingDragged()
    local xpos, ypos = GetCursorPosition()
    local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
    xpos = xmin - xpos / UIParent:GetScale() + 70
    ypos = ypos / UIParent:GetScale() - ymin - 70
    ABPButton_SetPosition(math.deg(math.atan2(ypos, xpos)))
end

-- 设置按钮角度（0~360）并持久化，随后更新按钮位置
function ABPButton_SetPosition(v)
    if v < 0 then v = v + 360 end
    ABP_ButtonPosition = v
    ABPButton_UpdatePosition()
end

-- 新建配置名的输入对话框（菜单"新建..."触发）
StaticPopupDialogs["ABP_NewProfile"] = {
    text = "为当前动作条保存输入一个名称",
    button1 = SAVE,
    button2 = CANCEL,
    OnAccept = function()
        local profileName = getglobal(this:GetParent():GetName() .. "EditBox"):GetText()
        ABP_SaveProfile(profileName)
        getglobal(this:GetParent():GetName() .. "EditBox"):SetText("")
    end,
    EditBoxOnEnterPressed = function()
        local profileName = this:GetText()
        ABP_SaveProfile(profileName)
        this:SetText("")
        this:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    hasEditBox = true,
    preferredIndex = 3,
}
