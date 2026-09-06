-- ActionBarProfiles.lua (WoW 1.12)
-- 经过Sunelgy优化的轻量版本：按需扫描 / 降低Tooltip与拾取操作 / 避免不必要表分配
-- 作者：Sunelgy在原作者基础上优化，武藤纯子酱修复宏逻辑

-- 全局状态与常量定义
local ABP_PlayerName = nil -- 当前角色标识：角色名 of 服务器名
local MAX_ACTIONS = 144 -- 最大动作槽数量
local ABP_SavingInProgress = false -- 保存/加载动作条期间抑制变化事件，防止自触发自动保存

-- 斜杠命令关键字（中文）
local CMD_SAVE   = "保存"
local CMD_LOAD   = "加载"
local CMD_REMOVE = "删除"
local CMD_LIST   = "列表"

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

-- 将工具 Tooltip 绑定到 UIParent（供保存/加载时探测动作与物品名称）
local function ABP_TooltipAttach()
    if ABP_Tooltip and ABP_Tooltip.SetOwner then
        ABP_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
end

-- 保存当前动作条到指定配置
-- 逐个扫描动作槽：宏 -> 技能 -> 物品，分别存入对应子表；silent 为 true 时不输出提示
function ABP_SaveProfile(profileName, silent)
    if not profileName or profileName == "" then return end
    if not ABP_PlayerName then return end
    if not ABP_Layout then ABP_Layout = {} end
    if not ABP_Layout[ABP_PlayerName] then ABP_Layout[ABP_PlayerName] = {} end

    ABP_Layout[ABP_PlayerName][profileName] = {
        spells = {},  -- [slot] = { name=, rank= }
        macros = {},  -- [slot] = macroName
        items  = {},  -- [slot] = itemName
    }

    ABP_TooltipAttach()

    local scStatus = GetCVar("autoSelfCast")
    SetCVar("autoSelfCast", 0)

    ABP_SavingInProgress = true
    for i = 1, MAX_ACTIONS do
        if HasAction(i) then
            local macroName = GetActionText(i)
            if macroName and macroName ~= "" then
                ABP_Layout[ABP_PlayerName][profileName].macros[i] = macroName
            else
                ABP_Tooltip:ClearLines()
                ABP_Tooltip:SetAction(i)

                local isSpell = false
                do
                    PickupAction(i)
                    isSpell = CursorHasSpell()
                    PlaceAction(i)
                end

                if isSpell then
                    local spellName, rankText = ABP_GetTooltipLine1()
                    if spellName and spellName ~= "" then
                        ABP_Layout[ABP_PlayerName][profileName].spells[i] = {
                            name = spellName,
                            rank = rankText,
                        }
                    end
                else
                    local itemName = (select(1, ABP_GetTooltipLine1()))
                    if itemName and itemName ~= "" then
                        ABP_Layout[ABP_PlayerName][profileName].items[i] = itemName
                    end
                end
            end
        end
    end
    ABP_SavingInProgress = false

    SetCVar("autoSelfCast", scStatus)
    if not silent then
        ABP_Msg('配置文件 "' .. profileName .. '" 已保存.')
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
    ABP_SavingInProgress = false

    SetCVar("autoSelfCast", scStatus)
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
function ABP_AutoSaveProfile()
    local profileName = ABP_GetAutoProfileName()
    if not profileName then return nil end
    ABP_SaveProfile(profileName)
    return profileName
end

-- 事件驱动：动作条内容变化后，等待 5 秒无再次变化才自动保存（防抖，避免频繁保存）
local ABP_PendingSave = false
local ABP_LastChangeTime = 0
local ABP_DebounceInterval = 5 -- 防抖间隔（秒）
local ABP_StartupDelay = 30 -- 登录/重载后的静默窗口期（秒），避免客户端初始化动作条时误触发保存
local ABP_StartupTime = 0

function ABP_OnActionBarChanged()
    -- 静默窗口期内忽略动作条变化，防止登录时客户端恢复动作条覆盖已有配置
    if GetTime() - ABP_StartupTime < ABP_StartupDelay then return end
    if not ABP_PlayerName or ABP_SavingInProgress then return end
    ABP_PendingSave = true
    ABP_LastChangeTime = GetTime()
end

-- 由独立计时帧每帧驱动：变化后安静满 5 秒才保存一次
function ABP_OnUpdate(frame, elapsed)
    if not ABP_PlayerName or not ABP_PendingSave then return end
    if GetTime() - ABP_LastChangeTime >= ABP_DebounceInterval then
        ABP_PendingSave = false
        ABP_AutoSaveProfile()
    end
end

-- 创建独立的自动保存计时帧
function ABP_CreateTimerFrame()
    if ABP_TimerFrame then return end
    ABP_TimerFrame = CreateFrame("Frame", "ABP_TimerFrame", UIParent)
    ABP_TimerFrame:SetScript("OnUpdate", ABP_OnUpdate)
    ABP_TimerFrame:Show()
end

-- 插件加载：注册事件与斜杠命令
function ABP_OnLoad()
    this:RegisterEvent("VARIABLES_LOADED")
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

        UIDropDownMenu_Initialize(getglobal("ABP_DropDownMenu"), ABP_DropDownMenu_OnLoad, "MENU")
        ABPButton_UpdatePosition()
        ABP_CreateTimerFrame()
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_MULTI_CAST_ACTIONBAR" then
        ABP_OnActionBarChanged()
    end
end

-- 斜杠命令分发：解析"保存/加载/删除/列表 + 配置名"并调用对应函数
function ABP_SlashCommand(msg)
    msg = msg or ""
    if msg == "" then
        ABP_Msg("ActionBarProfiles, 由Kronos的<Vanguard>制作, 60addons汉化")
        ABP_Msg("/abprofile 保存 [配置文件名字]")
        ABP_Msg("/abprofile 加载 [配置文件名字]")
        ABP_Msg("/abprofile 删除 [配置文件名字]")
        ABP_Msg("/abprofile 列表")
        return
    end

    for profileName in string.gfind(msg, CMD_SAVE .. " (.*)") do
        ABP_SaveProfile(profileName)
        return
    end
    for profileName in string.gfind(msg, CMD_LOAD .. " (.*)") do
        ABP_LoadProfile(profileName)
        return
    end
    for profileName in string.gfind(msg, CMD_REMOVE .. " (.*)") do
        ABP_RemoveProfile(profileName)
        return
    end
    if string.find(msg, CMD_LIST, 1, true) then
        ABP_ListProfiles()
        return
    end
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
