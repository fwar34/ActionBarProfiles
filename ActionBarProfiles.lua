-- ActionBarProfiles.lua (WoW 1.12)
-- 纯手动版：只做"保存当前动作条 / 加载配置"，不监听动作条、不自动保存、不写任何东西到存档。
-- 作者：Sunelgy在原作者基础上优化，武藤纯子酱修复宏逻辑

-- 全局状态与常量定义
local ABP_PlayerName = nil -- 当前角色标识：角色名 of 服务器名
local MAX_ACTIONS = 144 -- 最大动作槽数量
local ABP_DebugLevel = 0 -- 诊断输出级别：0=关，1=打印扫描/比对结果
-- 每个槽位"上次扫描"的分类结果：给加载时的"这个技能/物品其实已经在位"判断用
local ABP_SlotKind = {}
local ABP_SlotName = {}
local ABP_SlotRank = {}
local ABP_SlotTexture = {}

-- 加载结果自检：加载后等动作条稳定几秒，再扫一遍当前动作条与存档逐槽比对
local ABP_VerifyAt = nil
local ABP_VerifyProfile = nil

-- 斜杠命令关键字（中文）
local CMD_SAVE   = "保存"
local CMD_LOAD   = "加载"
local CMD_REMOVE = "删除"
local CMD_LIST   = "列表"
local CMD_CHECK  = "对比"
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
local ABP_ScanOnlySlotsPerFrame = 3 -- "只扫不写"的预热/自检任务用更小的步长，尽量不打扰游戏

-- 中断进行中的保存任务（加载配置前、或新的保存请求到来时）
local function ABP_JobAbort()
    if not ABP_Job then return end
    SetCVar("autoSelfCast", ABP_Job.scStatus)
    ABP_Job = nil
end

-- 清空某个槽位的分类缓存（动作被清掉、或读不出内容时）
local function ABP_ForgetSlot(i)
    ABP_SlotTexture[i] = nil
    ABP_SlotKind[i] = nil
    ABP_SlotName[i] = nil
    ABP_SlotRank[i] = nil
end

-- 完整扫描单个槽位：宏 -> 技能 -> 物品（技能/物品靠 PickupAction + CursorHasSpell 判定）
-- 顺带记下该槽位的分类，供加载时判断"这个技能/物品其实已经在位"
local function ABP_ScanSlot(dest, i)
    if not HasAction(i) then
        ABP_ForgetSlot(i)
        return
    end

    local texture = GetActionTexture(i)
    local macroText = GetActionText(i)
    ABP_SlotTexture[i] = texture

    if macroText and macroText ~= "" then
        ABP_SlotKind[i] = "macro"
        ABP_SlotName[i] = macroText
        ABP_SlotRank[i] = nil
        dest.macros[i] = macroText
        return
    end

    local isSpell = false
    PickupAction(i)
    isSpell = CursorHasSpell()
    PlaceAction(i)

    -- Tooltip 放在拾取/放回之后才读：PlaceAction 有可能顺手动到 Tooltip，先设后读才稳
    ABP_Tooltip:ClearLines()
    ABP_Tooltip:SetAction(i)

    if isSpell then
        local spellName, rankText = ABP_GetTooltipLine1()
        if spellName and spellName ~= "" then
            ABP_SlotKind[i] = "spell"
            ABP_SlotName[i] = spellName
            ABP_SlotRank[i] = rankText
            dest.spells[i] = {
                name = spellName,
                rank = rankText,
            }
        else
            ABP_SlotKind[i] = nil
            ABP_SlotName[i] = nil
            ABP_SlotRank[i] = nil
        end
    else
        local itemName = (select(1, ABP_GetTooltipLine1()))
        if itemName and itemName ~= "" then
            ABP_SlotKind[i] = "item"
            ABP_SlotName[i] = itemName
            ABP_SlotRank[i] = nil
            dest.items[i] = itemName
        else
            ABP_SlotKind[i] = nil
            ABP_SlotName[i] = nil
            ABP_SlotRank[i] = nil
        end
    end
end

-- 扫描时"有动作却什么也没解析出来"的槽位（Tooltip 读不出来时会出现）：
-- 沿用上次存档里的内容，宁可保留旧数据，也不要把槽位悄悄清掉。返回沿用了多少个。
local function ABP_CarryOverUnreadable(previous, dest)
    if not previous then return 0 end
    local carried = 0
    for i = 1, MAX_ACTIONS do
        if HasAction(i)
           and not dest.spells[i] and not dest.macros[i] and not dest.items[i] then
            local sp = previous.spells and previous.spells[i]
            local mc = previous.macros and previous.macros[i]
            local it = previous.items and previous.items[i]
            if sp then
                dest.spells[i] = sp
                carried = carried + 1
            elseif mc then
                dest.macros[i] = mc
                carried = carried + 1
            elseif it then
                dest.items[i] = it
                carried = carried + 1
            end
        end
    end
    return carried
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

-- 自检结果：把当前动作条（刚扫出来的 dest）与配置逐槽比对后报告。
-- 用来回答"加载后动作条为什么跟存档不一样"——差异会直接列出来（最多 8 条）。
local function ABP_ReportVerify(profileName, dest)
    local profile = ABP_PlayerName and ABP_Layout and ABP_Layout[ABP_PlayerName]
        and ABP_Layout[ABP_PlayerName][profileName]
    if not profile then
        ABP_Msg("|cffff5555[ABP]|r 自检失败：配置 " .. tostring(profileName) .. " 已经不在了.")
        return
    end

    local diff = ABP_DiffSummary(profile, dest)
    if diff == "无" then
        ABP_Msg("|cff33aaff[ABP]|r 加载自检（" .. profileName .. "）：当前动作条与存档完全一致.")
        return
    end

    ABP_Msg("|cffff5555[ABP]|r 加载自检（" .. profileName .. "）：与存档不一致（存档 → 现状）：")
    ABP_Msg("  " .. diff)
end

-- 保存当前动作条到指定配置（异步：真正的扫描与写入由 ABP_RunSaveJob 分帧完成）
-- silent 为 true 时不输出提示；返回是否已开始执行
function ABP_SaveProfile(profileName, silent)
    if not profileName or profileName == "" then return false end
    if not ABP_PlayerName then return false end
    if not ABP_Layout then ABP_Layout = {} end
    if not ABP_Layout[ABP_PlayerName] then ABP_Layout[ABP_PlayerName] = {} end

    if ABP_Job then ABP_JobAbort() end

    ABP_TooltipAttach()

    ABP_Job = {
        name = profileName,
        silent = silent,
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

    ABP_Dbg('开始扫描动作条（"' .. profileName .. '"）')
    return true
end

-- 分帧执行保存任务：每帧最多处理 ABP_JobSlotsPerFrame 个槽位
function ABP_RunSaveJob()
    local job = ABP_Job
    if not job then return end

    -- 每帧处理多少个槽位：自检任务用更小的步长
    local per = job.slotsPerFrame or ABP_JobSlotsPerFrame
    local last = job.i + per
    if last > MAX_ACTIONS then last = MAX_ACTIONS end

    -- 第一段：分帧完整扫描（宏/技能/物品）
    if job.phase == "scan" then
        -- 玩家正在拖拽：本帧不动光标，等下一帧再继续
        if ABP_CursorBusy() then
            ABP_Dbg("光标上有物品/技能，暂停扫描")
            return
        end

        for i = job.i + 1, last do
            ABP_ScanSlot(job.dest, i)
        end
        job.i = last

        if job.i >= MAX_ACTIONS then
            SetCVar("autoSelfCast", job.scStatus) -- 扫描结束，还原 CVar
            job.phase = "done"
        end
        return
    end

    -- 收尾：写入（自检任务只比对、不写）
    ABP_Job = nil

    -- "只扫不写 + 比对"的自检任务
    if job.verifyProfile then
        ABP_ReportVerify(job.verifyProfile, job.dest)
        ABP_Dbg("自检扫描完成")
        return
    end

    -- 有动作却什么都没读出来的槽位：沿用上次的内容，避免一次读失败就把槽位清掉
    local carriedCount = ABP_CarryOverUnreadable(job.previous, job.dest)
    if carriedCount > 0 then
        ABP_Dbg("保存：有 " .. carriedCount .. " 个槽位读不出来，沿用上次的内容")
    end

    ABP_Dbg('写入 "' .. job.name .. '"：' .. ABP_DiffSummary(job.previous, job.dest))

    ABP_Layout[ABP_PlayerName][job.name] = job.dest
    if not job.silent then
        ABP_Msg('配置文件 "' .. job.name .. '" 已保存.')
    end
end

-- "只扫不写 + 与指定配置比对"的自检任务：给加载后的自动校验和 /abprofile 对比 用
function ABP_StartVerifyJob(profileName)
    if ABP_Job or not ABP_PlayerName then return false end
    if not ABP_Layout or not ABP_Layout[ABP_PlayerName]
       or not ABP_Layout[ABP_PlayerName][profileName] then
        return false
    end

    ABP_TooltipAttach()

    ABP_Job = {
        verifyProfile = profileName,
        silent = true,
        slotsPerFrame = ABP_ScanOnlySlotsPerFrame,
        phase = "scan",
        i = 0,
        dest = { spells = {}, macros = {}, items = {} },
        scStatus = GetCVar("autoSelfCast"),
    }

    SetCVar("autoSelfCast", 0)
    ABP_Dbg("开始自检扫描（对比 " .. profileName .. "）")
    return true
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

    local placedCount, clearedCount = 0, 0
    local missed = {} -- 存档里有、这次没能放回去的槽位（原因一起记下来）

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
                    placedCount = placedCount + 1
                elseif ABP_SlotKind[i] == "spell" and ABP_SlotName[i] == sp.name
                       and GetActionTexture(i) == ABP_SlotTexture[i] then
                    -- 法术书里找不到，但这个槽位现在挂着的就是它（比如物品给的技能）：算它已经到位
                    placedCount = placedCount + 1
                else
                    table.insert(missed, "技能 槽" .. i .. " " .. tostring(sp.name)
                        .. (sp.rank and (" " .. sp.rank) or "") .. "（法术书里找不到）")
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
                if picked then
                    placedCount = placedCount + 1
                elseif ABP_SlotKind[i] == "macro" and ABP_SlotName[i] == mname
                       and GetActionTexture(i) == ABP_SlotTexture[i] then
                    -- 找不到这个宏，但槽位上挂的就是它：算它已经到位
                    placedCount = placedCount + 1
                else
                    table.insert(missed, "宏 槽" .. i .. " " .. mname .. "（找不到这个宏）")
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
                    placedCount = placedCount + 1
                    break
                end
                local loc = bagItemToLoc[iname]
                if loc then
                    PickupContainerItem(loc.bag, loc.slot)
                    PlaceAction(i)
                    ClearCursor() -- 清空光标残留
                    placedCount = placedCount + 1
                    break
                end
                -- 背包和装备上都没有：如果这个槽位现在挂着的就是同一个物品，那它其实已经在位了
                if ABP_SlotKind[i] == "item" and ABP_SlotName[i] == iname
                   and GetActionTexture(i) == ABP_SlotTexture[i] then
                    placedCount = placedCount + 1
                    break
                end
                table.insert(missed, "物品 槽" .. i .. " " .. iname .. "（背包和装备上都没有）")
                break
            end

            -- 保存的配置中该槽位为空：拾起当前动作并丢弃，实现完全覆盖
            if HasAction(i) then clearedCount = clearedCount + 1 end
            PickupAction(i)
            ClearCursor()
        until true
    end
    SetCVar("autoSelfCast", scStatus)

    ABP_Msg('配置文件 "' .. profileName .. '" 已加载：放回 ' .. placedCount .. " 个槽位，清空 "
        .. clearedCount .. " 个。")
    if table.getn(missed) > 0 then
        ABP_Msg("|cffff5555[ABP]|r 有 " .. table.getn(missed)
            .. " 个槽位没能恢复（会保持原样，所以看起来跟存档不一致）：")
        for k = 1, table.getn(missed) do
            if k > 8 then
                ABP_Msg("  …还有 " .. (table.getn(missed) - 8) .. " 个")
                break
            end
            ABP_Msg("  " .. missed[k])
        end
    end

    -- 3 秒后自检一次：把当前动作条跟这份存档逐槽比一遍，直接回答"完全覆盖到底有没有生效"
    ABP_VerifyAt = GetTime() + 3
    ABP_VerifyProfile = profileName
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
        ABP_Msg("    " .. profileName)
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



-- 由独立计时帧每帧驱动：推进进行中的任务（保存任务 / 加载后的自检）
function ABP_OnUpdate(frame, elapsed)
    -- 分帧任务未完成前不启动新的
    if ABP_Job then
        ABP_RunSaveJob()
        return
    end

    -- 加载后的自检：等动作条稳定几秒再扫，避免把还没落地的改动算成差异
    if ABP_VerifyAt and GetTime() >= ABP_VerifyAt then
        local verifyName = ABP_VerifyProfile
        ABP_VerifyAt, ABP_VerifyProfile = nil, nil
        if verifyName then ABP_StartVerifyJob(verifyName) end
    end
end

-- 创建独立的计时帧（推进分帧任务）
function ABP_CreateTimerFrame()
    if ABP_TimerFrame then return end
    ABP_TimerFrame = CreateFrame("Frame", "ABP_TimerFrame", UIParent)
    ABP_TimerFrame:SetScript("OnUpdate", ABP_OnUpdate)
    ABP_TimerFrame:Show()
end

-- 插件加载：注册事件与斜杠命令
function ABP_OnLoad()
    this:RegisterEvent("VARIABLES_LOADED")
    SLASH_ABP1 = "/abprofile"
    SlashCmdList["ABP"] = function(msg) ABP_SlashCommand(msg or "") end
end

-- 事件分发：只在 VARIABLES_LOADED 时做初始化（纯手动插件，不监听动作条事件）
function ABP_OnEvent()
    if event ~= "VARIABLES_LOADED" then return end

    ABP_PlayerName = UnitName("player") .. " of " .. GetCVar("realmName")

    if not ABP_Layout then ABP_Layout = {} end
    if not ABP_Layout[ABP_PlayerName] then ABP_Layout[ABP_PlayerName] = {} end

    if ABP_ButtonPosition == nil then ABP_ButtonPosition = 60 end

    UIDropDownMenu_Initialize(getglobal("ABP_DropDownMenu"), ABP_DropDownMenu_OnLoad, "MENU")
    ABPButton_UpdatePosition()
    ABP_CreateTimerFrame()
end

-- 命令提示：列出所有可用命令
function ABP_PrintHelp()
    ABP_Msg("ActionBarProfiles - 动作条配置保存/加载（纯手动：不自动保存、不监听动作条）")
    ABP_Msg("  /abprofile 保存 <名字>    把当前动作条存成配置")
    ABP_Msg("  /abprofile 加载 <名字>    加载配置，完全覆盖当前动作条")
    ABP_Msg("  /abprofile 删除 <名字>    删除配置")
    ABP_Msg("  /abprofile 列表           列出本角色的所有配置")
    ABP_Msg("  /abprofile 对比 <名字>    把当前动作条跟该配置逐槽比一遍，列出差异")
    ABP_Msg("  /abprofile debug          诊断输出开关（当前：" .. ABP_DebugLevel .. " 级）")
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

    -- 诊断开关：/abprofile debug
    -- 要求出现在命令开头，避免配置文件名字里含 debug 时误判
    if string.find(lowerCmd, "^%s*" .. CMD_DEBUG) then
        ABP_DebugLevel = (ABP_DebugLevel == 0) and 1 or 0
        if ABP_DebugLevel == 0 then
            ABP_Msg("ActionBarProfiles 诊断输出已关闭.")
        else
            ABP_Msg("ActionBarProfiles 诊断输出已打开：会打印扫描/写入/比对的槽位差异.")
        end
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
    for profileName in string.gfind(cmd, CMD_CHECK .. " (.*)") do
        if not ABP_Layout or not ABP_Layout[ABP_PlayerName]
           or not ABP_Layout[ABP_PlayerName][profileName] then
            ABP_Msg('配置 "' .. profileName .. '" 还没有保存过，无法对比.')
        else
            ABP_Msg('正在把当前动作条与 "' .. profileName .. '" 逐槽比对（几秒后给结果）…')
            ABP_StartVerifyJob(profileName)
        end
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
