# ActionBarProfiles（动作条保存）

> World of Warcraft 1.12 / Turtle WoW（乌龟服 1.18）动作条保存/加载插件
> 纯手动版：**只有你主动点"保存"才会记录动作条**，插件不监听动作条、不自动保存、不挂钩任何游戏函数。

## 功能特性

- **一键保存 / 加载 / 删除 / 列表**：把当前动作条上的**技能、宏、物品**整体存成命名配置（Profile），随时一键恢复。
- **完全覆盖加载**：加载后动作条与保存时**完全一致**——保存时为空的动作槽位，加载后也会被清空，不会残留当前布局。
- **加载结果报告**：放回 / 清空了多少槽位；存档里有、这次没能放回去的槽位会逐条列出并给原因（技能不在法术书里、宏不存在、物品不在背包或装备上）。如果该槽位现在挂着的本来就是这个技能 / 宏 / 物品，算"已经在位"，不会误报。
- **加载后 3 秒自检**：等动作条稳定后自动扫一遍，与刚加载的存档逐槽比对，直接报"与存档完全一致"或列出差异（最多 8 条）。也可以随时用 `/abprofile 对比 <名字>` 手动比对。
- **多角色隔离**：配置按"角色名 of 服务器名"隔离，互不干扰；同一角色可保存多套配置。
- **小地图按钮**：左键弹出菜单操作；右键拖动按钮绕小地图圆周定位，位置自动记忆。
- **中文斜杠命令**：`/abprofile` 系列命令。

**没有自动保存。** 插件的改动（保存/加载/删除）全部由你手动触发；动作条上拖来拖去不会被记录，也不会写进存档。如果哪天想要"改动后自动保存 / 退出时自动补存"，旧版本备份在 `ActionBarProfiles.lua.bak-autosave`（见文末）。

## 安装方法

1. 将 `ActionBarProfiles` 文件夹放入 `Interface\AddOns\` 目录。
2. 启动游戏，在插件列表确认已启用。
3. 小地图旁出现图标即安装成功，不需要任何额外设置。

## 使用方法

### 小地图按钮

- **左键点击** → 打开配置菜单：
  - 点击配置名 → 直接加载该配置
  - "保存当前动作条的布局" → 子菜单选择覆盖已有配置或新建
  - "删除一个布局" → 子菜单选择要删除的配置
- **右键拖动** → 按钮绕小地图旋转定位（位置自动保存）

### 斜杠命令

```
/abprofile 保存 <配置名>     # 把当前动作条存成配置
/abprofile 加载 <配置名>     # 加载配置（完全覆盖当前动作条）
/abprofile 删除 <配置名>     # 删除配置
/abprofile 列表             # 列出当前角色的所有配置
/abprofile 对比 <配置名>     # 把当前动作条跟该配置逐槽比一遍，列出差异
/abprofile debug            # 诊断输出开关（打印扫描/写入/比对的槽位差异）
```

`/abprofile`（不带参数，或命令名后多打了空格）会打印命令提示；`/abprofile help`、`/abprofile ?`、`/abprofile 帮助` 也可以，看不懂的命令同样会打印提示，而不是静默无反应。

## 目录结构

```
ActionBarProfiles/
├── ActionBarProfiles.toc     # 插件清单（元数据、加载顺序、保存变量声明）
├── ActionBarProfiles.xml     # 界面布局（小地图按钮、下拉菜单、Tooltip）
├── ActionBarProfiles.lua     # 全部逻辑代码
├── Images/
│   └── abp.tga               # 小地图按钮图标
├── ActionBarProfiles.lua.bak-autosave  # 旧的"自动保存版"备份，可删
└── README.md
```

## 文件说明

### ActionBarProfiles.toc

| 字段 | 值 | 说明 |
|------|-----|------|
| Interface | 11200 | 1.12 接口版本 |
| Title | [辅助]动作条保存 | 插件标题 |
| SavedVariables | `ABP_Layout`, `ABP_ButtonPosition` | 配置数据 + 小地图按钮角度 |
| 加载顺序 | lua 在前，xml 在后 | 先定义逻辑，再构建界面 |

### ActionBarProfiles.xml

1. **ActionBarProfiles_IconFrame**（按钮，父级 Minimap）：小地图图标；左键弹菜单，右键拖动定位。
2. **ABP_DropDownMenu**（继承 UIDropDownMenuTemplate）— 主交互菜单。
3. **ABP_Tooltip**（独立 GameTooltip）— 保存/加载时用来**探测**动作与物品名称（非展示用途）。

## 核心数据模型

```lua
ABP_Layout = {
    ["<角色名> of <服务器>"] = {
        ["<配置名>"] = {
            spells = {},   -- [动作槽位] = { name = "技能名", rank = "等级" }
            macros = {},   -- [动作槽位] = 宏名称
            items  = {},   -- [动作槽位] = 物品名称
        },
    },
}

ABP_ButtonPosition = <number>   -- 小地图按钮角度（0~360）
```

数据按 **角色 → 配置名 → 三种类型** 三层组织。键使用 `角色名 of 服务器名` 实现角色隔离。

## 核心工作流程

### 保存 `ABP_SaveProfile(profileName, silent)`

保存是**异步分帧**执行的（真正的扫描/写入由 `ABP_RunSaveJob` 在计时帧里推进），因为一帧内对几十个槽位做 Tooltip + 拾取/放置会明显掉帧。

1. **扫描段**（每帧 6 个槽位）：遍历 1~144 号动作槽
   - 有内容且 `GetActionText` 非空 → 是宏，存 `macros`
   - 否则用 `PickupAction`/`PlaceAction` + `CursorHasSpell` 探测是否为技能
     - 是技能 → 读 Tooltip 第 1 行拆成 技能名 / 等级，存 `spells`
     - 是物品 → 读物品名存 `items`
   - 光标上正拿着东西（`ABP_CursorBusy`）时暂停本帧，避免打断你正在进行的拖拽
   - 任务开始时关闭 `autoSelfCast`、扫描结束时还原（只改两次 CVar）
2. **收尾**：**有动作却什么都没读出来的槽位**（Tooltip 读不出来时会这样）→ 沿用上次存档里的内容，宁可保留旧数据也不要把槽位悄悄清空；然后写入并提示。

### 加载 `ABP_LoadProfile(profileName)`

1. 校验配置存在性
2. 预处理三张映射表（减少重复 Tooltip 探测）：
   - `spellKeyToId`：技能名+等级 → 法术书序号（`GetSpellTabInfo` + `GetSpellName`）
   - `equipItemToId`：物品名 → 装备槽位（遍历 1~19 装备位）
   - `bagItemToLoc`：物品名 → 背包/格位
3. 按槽位顺序回填：技能 `PickupSpell` → `PlaceAction`；宏优先 `PickupMacro(0, name)`（超级宏）否则 `GetMacroIndexByName` + `PickupMacro(idx)`；物品先查装备位再查背包。**存档中为空的槽位会被清空**，实现完全覆盖。
4. 回填期间同样临时关闭 `autoSelfCast`
5. 报告放回 / 清空数量与"没能恢复"清单（含原因），并安排 **3 秒后的自检**（`ABP_StartVerifyJob` → `ABP_ReportVerify`）

## 函数清单

### 公共 API（暴露为全局）

| 函数 | 作用 |
|------|------|
| `ABP_OnLoad` | 注册 `VARIABLES_LOADED` 与斜杠命令 |
| `ABP_OnEvent` | 初始化角色标识、配置表、菜单、按钮位置、计时帧 |
| `ABP_SaveProfile` | 保存配置（**异步**：只创建分帧任务；`silent` 静默） |
| `ABP_RunSaveJob` | 分帧推进任务（计时帧每帧调用） |
| `ABP_StartVerifyJob` | 启动"只扫不写 + 与配置比对"的自检 |
| `ABP_ReportVerify` | 自检结果：一致 / 差异清单 |
| `ABP_LoadProfile` | 加载配置（完全覆盖 + 加载报告 + 安排自检） |
| `ABP_ListProfiles` / `ABP_RemoveProfile` | 列表 / 删除配置 |
| `ABP_SlashCommand` / `ABP_PrintHelp` | 斜杠命令分发 / 命令提示 |
| `ABP_OnUpdate` | 计时帧驱动（推进分帧任务与自检） |
| `ABP_CreateTimerFrame` | 创建计时帧 |
| `ABP_DropDownMenu_OnLoad` | 构建下拉菜单 |
| `ABPButton_UpdatePosition` / `ABPButton_BeingDragged` / `ABPButton_SetPosition` | 小地图按钮定位 |

### 局部辅助函数

| 函数 | 作用 |
|------|------|
| `hasElements` | 判断表是否为空 |
| `ABP_Msg` / `ABP_Dbg` | 聊天框输出 / 诊断输出 |
| `ABP_GetTooltipLine1` / `ABP_ComposeSpellKey` | 读 Tooltip 第 1 行 / 组合"技能名 等级"键 |
| `ABP_ForgetSlot` / `ABP_ScanSlot` | 清空某个槽位的分类缓存 / 完整扫描单个槽位 |
| `ABP_CarryOverUnreadable` | 读不出来的槽位沿用上次存档内容 |
| `ABP_DiffSummary` | 汇总两份配置的差异（调试/自检用） |
| `ABP_JobAbort` / `ABP_CursorBusy` / `ABP_TooltipAttach` | 中断任务 / 光标是否忙 / 绑定探测 Tooltip |
| `ABP_BuildNeededSpellMap` / `ABP_FindItemsInEquipment` / `ABP_FindItemsInBags` | 三张加载用映射表 |

## 常量与配置项

| 常量 | 值 | 说明 |
|------|-----|------|
| `MAX_ACTIONS` | 144 | 遍历的最大动作槽数 |
| `ABP_JobSlotsPerFrame` | 6 | 保存任务每帧处理的槽位数（越小越不卡） |
| `ABP_ScanOnlySlotsPerFrame` | 3 | 自检任务每帧处理的槽位数 |
| `ABP_ButtonRadius` | 78 | 按钮绕小地图旋转半径 |
| `ABP_ButtonPosition` | 默认 60 | 按钮角度持久化变量 |
| `CMD_SAVE/LOAD/REMOVE/LIST/CHECK/DEBUG` | 保存/加载/删除/列表/对比/debug | 中文斜杠命令关键字 |

## 技术要点与注意事项

1. **依赖客户端的 Tooltip 作为"数据探测仪"**：保存与加载都通过向 `ABP_Tooltip` 注入动作/物品并读取文本行来获取名称，这是 1.12 无原生 API 环境下的通用技巧。
2. **`CursorHasSpell` 探测法**：通过拾取再放回动作槽判断是否为法术，期间主动关闭 `autoSelfCast` 以避免干扰（只改两次 CVar，不逐帧改）。
3. **宏兼容双路径**：`GetSuperMacroInfo`（超级宏）与 `GetMacroIndexByName`（普通宏）双路回退。
4. **加载的限制**：
   - 技能必须是**法术书里能找到的同一个 技能名 + 等级**；洗点、没学过、物品给的技能放不回去（会在"没能恢复"清单里说明）。
   - 物品必须还在**背包或装备位**上；放银行、卖掉、用完了就恢复不回去。
   - **姿态 / 奖励动作条（61–72 槽）**：保存的是当时那个姿态页面的内容，换个姿态再加载会写进当前姿态那一页。
5. **性能**：保存/自检都是分帧任务（每帧 3~6 个槽位）；插件不注册任何动作条/退出事件，不挂钩 `PlaceAction`/`Logout`/`Quit`，平时完全不做事（计时帧每帧只做一次极轻量的判断）。

## 关于"自动保存版"

`ActionBarProfiles.lua.bak-autosave` 是**移除自动保存逻辑之前**的完整备份（含改动后自动保存、退出/登出补存、缓存预热、退出补存记录等）。游戏不会加载它（不在 `.toc` 里）。

- 想彻底干净：直接删掉这个文件。
- 想回退：把它改名回 `ActionBarProfiles.lua`（覆盖当前文件），并把 `.toc` 的 `## SavedVariables:` 改回 `ABP_Layout, ABP_ButtonPosition, ABP_Enabled, ABP_Active, ABP_ExitLog, ABP_ExitState`。
