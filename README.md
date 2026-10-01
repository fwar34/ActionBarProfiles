# ActionBarProfiles（动作条保存）

> World of Warcraft 1.12 / Turtle WoW（乌龟服 1.18）动作条保存/加载插件
> 版本：2.1 ｜ 接口版本：11200

## 功能特性

- **一键保存 / 加载 / 删除 / 列表**：将当前动作条上的**技能、宏、物品**整体保存为命名配置（Profile），随时一键恢复。
- **完全覆盖加载**：加载配置后动作条与保存时**完全一致**——保存时为空的动作槽位，加载后也会被清空，不会残留当前布局。
- **自动保存**：只有**真的改动了动作条**（拖放技能/物品/宏，或其它插件改写动作条）才会触发；改动后等待 **5 秒无再次变化**才保存到以 **"职业+角色名"** 命名的配置（如"战士雾满拦江"）。触发前先过一遍 O(1) 的廉价过滤：**拾取尸体 / 采药 / 开箱**这类客户端补发的事件、登录静默窗口内的事件、以及保存/加载自身产生的尾随事件都会被直接丢掉，不扫描、不写盘、不刷聊天框、也不会造成卡顿。登录/重载后的 **30 秒静默窗口期**内不自动保存（起点为进入世界的那一刻）。若怀疑存在"没操作也自动保存"，用 `/abprofile debug` 看触发来源。
- **手动保存/加载不会触发自动保存**：切换配置不会污染自动保存的数据。
- **总开关**：`/abprofile off` 关闭插件（不再监听动作条事件、不再自动保存），`/abprofile on` 恢复；状态记在 `ABP_Enabled` 里，重登后保持。**关闭时小地图按钮与菜单功能完全不变**，手动 `保存|加载|删除|列表` 也照常可用，随时可以从按钮或命令重新开启。
- **多角色隔离**：配置按"角色名 of 服务器名"隔离，互不干扰；同一角色可保存多套配置（如不同的专精/场景布局）。
- **小地图按钮**：左键弹出菜单操作；右键拖动按钮绕小地图圆周定位，位置自动记忆。
- **中文斜杠命令**：`/abprofile` 系列命令快速管理配置。

## 安装方法

1. 将 `ActionBarProfiles` 文件夹放入 `Interface\AddOns\` 目录。
2. 启动游戏，在插件列表确认已启用。
3. 小地图旁出现图标即安装成功。

## 使用方法

### 小地图按钮

- **左键点击** → 打开配置菜单：
  - 点击配置名 → 直接加载该配置
  - "保存当前动作条的布局" → 子菜单选择覆盖已有配置或新建
  - "删除一个布局" → 子菜单选择要删除的配置
- **右键拖动** → 按钮绕小地图旋转定位（位置自动保存）

### 斜杠命令

```
/abprofile 保存 <配置名>     # 将当前动作条保存为配置
/abprofile 加载 <配置名>     # 加载指定配置（完全覆盖当前动作条）
/abprofile 删除 <配置名>     # 删除指定配置
/abprofile 列表             # 列出当前角色的所有配置
/abprofile on                # 开启插件（恢复监听动作条与自动保存）
/abprofile off               # 关闭插件（不再监听动作条、不再自动保存；小地图按钮与菜单照旧）
/abprofile debug             # 打开/关闭诊断输出（按防抖窗口汇总，不会刷屏）
/abprofile debug all         # 诊断输出升级为逐条事件打印（排查用，可能刷屏）
```

`/abprofile`（不带参数，或命令名后多打了空格）会打印上面这份命令提示，并显示当前的开关状态与诊断级别；`/abprofile help`、`/abprofile ?`、`/abprofile 帮助` 也可以，看不懂的命令同样会打印提示，而不是静默无反应。

### 自动保存

- 改动动作条（拖技能、放物品、改宏）后，若 **5 秒内没有再次改动**，自动保存到 `"职业+角色名"` 配置。
- **触发源只有两个**：拖放动作（挂钩 `PlaceAction`）、以及某槽位宏名/图标真的变了的事件；其余事件（拾取/采药/开箱补发、换页换形态、保存自身产生）在 O(1) 的廉价指纹里就被丢掉，不会启动扫描，也就没有卡顿。
- 保存前再做逐槽比对，**内容一致就完全跳过**（不写盘、不刷聊天框）。
- 换形态/翻页不再单独触发保存（旧版会），因为那只是切换了当前的页面，并没有改动动作。
- 该配置与手动配置并列显示在列表和 `/abprofile 列表` 中，可随时主动加载。
- 手动保存/加载不会改写该自动配置。

## 目录结构

```
ActionBarProfiles/
├── ActionBarProfiles.toc     # 插件清单（元数据、加载顺序、保存变量声明）
├── ActionBarProfiles.xml     # 界面布局（小地图按钮、下拉菜单、Tooltip）
├── ActionBarProfiles.lua     # 全部逻辑代码
├── Images/
│   └── abp.tga               # 小地图按钮图标
└── README.md
```

## 文件说明

### ActionBarProfiles.toc

| 字段 | 值 | 说明 |
|------|-----|------|
| Interface | 11200 | 1.12 接口版本 |
| Title | [辅助]动作条保存 | 插件标题 |
| SavedVariables | ABP_Layout, ABP_ButtonPosition, ABP_Enabled | 持久化数据（含插件开关状态） |
| 加载顺序 | lua 在前，xml 在后 | 先定义逻辑，再构建界面 |

另含平台相关的 `X-PluginId` / `X-PublishTime` 等扩展元数据（非暴雪标准字段）。

### ActionBarProfiles.xml

定义了三部分 UI：

1. **ActionBarProfiles_IconFrame**（按钮，父级 Minimap）
   - 小地图上的 33×33 图标按钮，中央显示 `abp.tga` 纹理
   - 左键点击弹出下拉菜单；右键拖动绕小地图旋转定位
   - OnEnter 显示 GameTooltip 说明
2. **ABP_DropDownMenu**（继承 UIDropDownMenuTemplate）— 插件主交互菜单
3. **ABP_Tooltip**（独立 GameTooltip）— 用于在保存/加载过程中探测动作条与物品的**工具 Tooltip**（非展示用途）

### ActionBarProfiles.lua

单文件承载全部逻辑，分为三块：数据操作、UI 逻辑、常量定义。

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
ABP_Enabled = <true|false>      -- 插件开关（/abprofile on|off），关闭时持久生效
```

数据按 **角色 → 配置名 → 三种类型** 三层组织。键使用 `角色名 of 服务器名` 实现角色隔离。

## 核心工作流程

### 保存流程 `ABP_SaveProfile(profileName, silent, skipIfUnchanged)`

保存是**异步分帧**执行的（返回是否已开始，真正的扫描/写入由 `ABP_RunSaveJob` 在 `ABP_TimerFrame` 的 OnUpdate 里推进），因为一帧内对几十个槽位做 Tooltip + 拾取/放置会明显掉帧。

1. **扫描段**（`phase = "scan"`，每帧 `ABP_JobSlotsPerFrame` = 6 个槽位）：遍历 1~144 号动作槽
   - 有内容且 `GetActionText` 非空 → 是宏，存 `macros`
   - 否则用 `PickupAction`/`PlaceAction` + `CursorHasSpell` 探测是否为技能
     - 是技能 → 读取 Tooltip 第 1 行拆分为 技能名/等级，存 `spells`
     - 是物品 → 读取物品名存 `items`
   - 顺带记录该槽位的廉价指纹（`ABP_SlotTexture` / `ABP_SlotMacro`）
   - 光标上正拿着东西（`ABP_CursorBusy`）时暂停本帧，避免打断玩家拖拽
   - 任务开始时关闭 `autoSelfCast`、扫描结束时还原（只改两次 CVar）
2. **收尾段**（`phase = "done"`）：`skipIfUnchanged` 且内容与已存配置一致 → 不写盘、不提示；否则覆盖数据并提示

> 采用"按需探测 + 复用 Tooltip + 分帧"的方式：既不每帧扫描，也不让单帧承担整条动作条的开销。

### 加载流程 `ABP_LoadProfile(profileName)`

1. 校验配置存在性
2. 预处理三张映射表（减少重复 Tooltip 探测）：
   - `spellKeyToId`：技能名+等级 → 法术 ID（`GetSpellTabInfo` + `GetSpellName` 扫描法术书）
   - `equipItemToId`：物品名 → 装备槽位（遍历 1~19 装备位）
   - `bagItemToLoc`：物品名 → 背包/格位（遍历背包）
3. 按槽位顺序回填：
   - 技能：`PickupSpell` → `PlaceAction`
   - 宏：优先 `PickupMacro(0, name)`（超级宏），否则按名称查索引 `PickupMacro(idx)`
   - 物品：先查装备位，再查背包，`PickupInventoryItem` / `PickupContainerItem`
4. 回填期间同样临时关闭 `autoSelfCast`
5. **保存配置中为空的槽位会被清空**，实现完全覆盖

### 自动保存机制

- 注册 `ACTIONBAR_SLOT_CHANGED` / `UPDATE_BONUS_ACTIONBAR` / `UPDATE_MULTI_CAST_ACTIONBAR` 事件监听动作条变化。
- 变化后启动 **5 秒防抖计时**：期间无再次变化才保存一次，避免频繁保存。
- 通过独立的 Lua 计时帧（`ABP_TimerFrame`）驱动防抖判断，不依赖 XML 脚本参数机制。
- **噪音事件过滤（两道闸）**：
- **噪音事件过滤（触发源本身就很窄）**：
  - **挂钩 `PlaceAction`**：拖技能/物品/宏到按钮、以及别的插件改写动作条，最终都会调用它，所以它才是"真的改了动作条"的可靠信号；客户端因**拾取尸体 / 采药 / 开箱**等背包变动补发的事件完全不经过它。
  - **廉价指纹**：`ACTIONBAR_SLOT_CHANGED` 只在**该槽位的宏名 / 图标真的变了**（`ABP_SlotTexture` / `ABP_SlotMacro`）时才被接受，其余在 O(1) 里丢掉——不碰 Tooltip、不碰光标、不改 CVar，因此拾取类事件完全不产生任何开销。
  - **换页/换形态**（`UPDATE_BONUS_ACTIONBAR` / `UPDATE_MULTI_CAST_ACTIONBAR`）只作废并重建廉价指纹，不触发保存。
  - **逐槽比对**：只有上面两种触发才会进扫描（`ABP_ScanSlot` 用 `PickupAction`/`PlaceAction` 判定技能还是物品），扫描结果再与已存配置比一次（`ABP_IsSameProfile`），一致则不写入、不提示。
  - **分帧执行**：扫描由 `ABP_RunSaveJob` 每帧只处理 `ABP_JobSlotsPerFrame`（默认 6）个槽位，避免单帧集中开销造成卡顿。
- **自触发抑制**：`ABP_SavingInProgress` 标志覆盖扫描/回填全过程；`ABP_SelfChangeUntil`（**1 秒**）兜底拦截保存动作自身产生的、可能延后派发的尾随事件。
- **不打断拖拽**：光标上正拿着技能/物品/宏（`ABP_CursorBusy`）时推迟本次自动保存，避免扫描中的拾取/放置与玩家正在进行的拖拽打架。
- 登录/重载（`VARIABLES_LOADED`）后进入 **30 秒静默窗口期**（`ABP_StartupDelay`），起点为该事件；并在本次登录**首次** `PLAYER_ENTERING_WORLD`（加载画面结束）时重新计时，避免加载耗时长时客户端回填动作条触发误保存。
- **诊断开关**：`/abprofile debug` 打开后**不是逐条事件打印**，而是每个防抖窗口汇总成两行以内：
  1. `事件窗口：接受 N 个（首个 <来源> @时间），忽略噪音 X 个、自触发 X 个、登录窗口 Y 个`
  2. `比对结果（"配置名"）：…` 或 `写入 "配置名"：<槽位差异>`

  `ACTIONBAR_SLOT_CHANGED` 是按槽位逐个发的、保存一次扫描就能产生几十个，所以被忽略的事件只计数不打印；确实需要逐条看时用 `/abprofile debug all`（级别 2）。
- 注销（`PLAYER_LOGOUT`）阶段动作条已被客户端清空，因此**不执行自动保存**，避免覆盖有效数据。

## 函数清单

### 公共 API（暴露为全局）

| 函数 | 作用 |
|------|------|
| `ABP_OnLoad` | 注册事件与斜杠命令 |
| `ABP_OnEvent` | 初始化角色名、保存变量、菜单、按钮位置；应用插件开关状态 |
| `ABP_SetEnabled` | 开启/关闭插件（注册/注销事件、显示/隐藏按钮、中断保存任务） |
| `ABP_SaveProfile` | 保存配置（**异步**：只创建分帧任务；`silent` 静默、`skipIfUnchanged` 无变化时不写入） |
| `ABP_RunSaveJob` | 分帧推进保存任务（由 `ABP_TimerFrame` 的 OnUpdate 每帧调用） |
| `ABP_LoadProfile` | 加载配置 |
| `ABP_ListProfiles` | 列出配置 |
| `ABP_RemoveProfile` | 删除配置 |
| `ABP_SlashCommand` | 斜杠命令分发（无参数/无法识别时打印 `ABP_PrintHelp`） |
| `ABP_PrintHelp` | 打印可用命令提示与当前开关/诊断状态 |
| `ABP_DropDownMenu_OnLoad` | 构建下拉菜单 |
| `ABPButton_UpdatePosition` | 按角度更新按钮位置 |
| `ABPButton_BeingDragged` | 拖动中计算角度 |
| `ABPButton_SetPosition` | 设置并持久化角度 |
| `ABP_AutoSaveProfile` | 执行自动保存（内容无变化时跳过，返回配置名或 nil） |
| `ABP_OnActionBarChanged` | 动作条变化事件处理（防抖标记，带调试输出） |
| `ABP_OnUpdate` | 计时帧驱动，防抖到期执行保存 |
| `ABP_CreateTimerFrame` | 创建独立计时帧 |

### 局部辅助函数

| 函数 | 作用 |
|------|------|
| `hasElements` | 判断表是否为空 |
| `ABP_IsSameProfile` | 比较两份配置内容是否完全一致（自动保存跳过无变化写入） |
| `ABP_NoteChange` | 登记一次"真的改了动作条"的变化并进入防抖 |
| `ABP_RebuildCheapCache` | 重建全部槽位的廉价指纹（宏名 / 图标） |
| `PlaceAction`（包装） | 挂钩客户端 API，捕获真正放置动作的操作（`ABP_OrigPlaceAction` 保存原函数） |
| `ABP_ScanSlot` | 完整扫描单个槽位：宏 / 技能 / 物品，并刷新廉价指纹 |
| `ABP_JobAbort` | 中断进行中的保存任务并还原状态 |
| `ABP_CursorBusy` | 光标上是否正拿着技能/物品/宏，用于暂停扫描/推迟保存 |
| `ABP_DiffSummary` | 汇总两份配置的槽位差异（调试输出用） |
| `ABP_Dbg` | 诊断输出（级别 1 起生效） |
| `ABP_Dbg2` | 逐条事件输出（级别 2，`/abprofile debug all`） |
| `ABP_DbgFlushEventStats` | 把本防抖窗口内的事件计数汇总成一行 |
| `ABP_TimeText` | 调试用的时间戳文本 |
| `ABP_GetTooltipLine1` | 安全读取 Tooltip 第 1 行左右文本 |
| `ABP_ComposeSpellKey` | 组合"技能名 等级"作为唯一键 |
| `ABP_Msg` | 聊天框输出 |
| `ABP_TooltipAttach` | 将工具 Tooltip 绑定到 UIParent |
| `ABP_BuildNeededSpellMap` | 构建"技能键 → 法术 ID"映射 |
| `ABP_FindItemsInEquipment` | 构建"物品名 → 装备槽"映射 |
| `ABP_FindItemsInBags` | 构建"物品名 → 背包位置"映射 |

## 常量与配置项

| 常量 | 值 | 说明 |
|------|-----|------|
| `MAX_ACTIONS` | 144 | 最大动作槽数 |
| `ABP_ButtonRadius` | 78 | 按钮绕小地图旋转半径 |
| `CMD_SAVE/LOAD/REMOVE/LIST` | 保存/加载/删除/列表 | 中文斜杠命令关键字 |
| `ABP_ButtonPosition` | 默认 60 | 按钮角度持久化变量 |
| `ABP_DebounceInterval` | 5 | 自动保存防抖间隔（秒） |
| `ABP_JobSlotsPerFrame` | 6 | 保存任务每帧处理的槽位数（越小越不卡顿，总耗时越长） |
| `ABP_SelfChangeGrace` | 1 | 保存/加载结束后继续忽略变化事件的窗口（秒），用于拦截延迟派发的自触发事件 |
| `ABP_StartupDelay` | 30 | 登录/重载后的静默窗口期（秒） |

## 技术要点与注意事项

1. **依赖客户端的 Tooltip 作为"数据探测仪"**：保存与加载都通过向 `ABP_Tooltip` 注入动作/物品并读取文本行来获取名称，这是 1.12 无原生 API 环境下的通用技巧，但意味着探测结果受客户端本地化/语言环境影响。
2. **`CursorHasSpell` 探测法**：通过拾取再放回动作槽判断是否为法术，期间主动关闭 `autoSelfCast` 以规避干扰。
3. **宏兼容双路径**：`GetSuperMacroInfo`（超级宏）与 `GetMacroIndexByName`（普通宏）双路回退。
4. **性能优化**：加载前预构建技能/物品映射表，将多次重复的 Tooltip 探测压缩为一次性的线性扫描（法术书、19 装备位、背包），并带 `leftCount` 提前终止；**保存则分帧执行**（每帧 `ABP_JobSlotsPerFrame` 个槽位），避免单帧集中做几十次 Tooltip + 拾取/放置造成掉帧。
5. **自触发抑制**：`ABP_SavingInProgress` 覆盖任务执行期间（自己扫描时的 `PlaceAction` 因此不会被挂钩认作玩家操作），`ABP_SelfChangeUntil`（1 秒）覆盖客户端延迟派发的尾随事件，廉价指纹则让"内容没变"的事件连扫描都进不去。
6. **注销阶段不保存**：`PLAYER_LOGOUT` 时动作条已被客户端清空，直接保存会写入空数据，故自动保存仅在正常游戏帧中通过事件/计时触发。
