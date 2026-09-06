# ActionBarProfiles（动作条保存）

> World of Warcraft 1.12 / Turtle WoW（乌龟服 1.18）动作条保存/加载插件
> 版本：2.1 ｜ 接口版本：11200

## 功能特性

- **一键保存 / 加载 / 删除 / 列表**：将当前动作条上的**技能、宏、物品**整体保存为命名配置（Profile），随时一键恢复。
- **完全覆盖加载**：加载配置后动作条与保存时**完全一致**——保存时为空的动作槽位，加载后也会被清空，不会残留当前布局。
- **自动保存**：动作条内容变化后，等待 **5 秒无再次变化**才自动保存到以 **"职业+角色名"** 命名的配置（如"战士雾满拦江"）；连续操作不会频繁保存。该自动配置会出现在配置列表中，可随时主动加载。登录/重载后的 **30 秒静默窗口期**内不自动保存，避免客户端初始化动作条时误覆盖已有配置。
- **手动保存/加载不会触发自动保存**：切换配置不会污染自动保存的数据。
- **多角色隔离**：配置按"角色名 of 服务器名"隔离，互不干扰；同一角色可保存多套配置（如不同的专精/场景布局）。
- **小地图按钮**：左键弹出菜单操作；右键拖动按钮绕小地图圆周定位，位置自动记忆。
- **中文斜杠命令**：`/abp` 系列命令快速管理配置。

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
/abp 保存 <配置名>     # 将当前动作条保存为配置
/abp 加载 <配置名>     # 加载指定配置（完全覆盖当前动作条）
/abp 删除 <配置名>     # 删除指定配置
/abp 列表             # 列出当前角色的所有配置
```

### 自动保存

- 改动动作条（拖技能、放物品、改宏、换姿态）后，若 **5 秒内没有再次改动**，自动保存到 `"职业+角色名"` 配置。
- 该配置与手动配置并列显示在列表和 `/abp 列表` 中，可随时主动加载。
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
| SavedVariables | ABP_Layout, ABP_ButtonPosition | 持久化数据 |
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
```

数据按 **角色 → 配置名 → 三种类型** 三层组织。键使用 `角色名 of 服务器名` 实现角色隔离。

## 核心工作流程

### 保存流程 `ABP_SaveProfile(profileName)`

1. 遍历 1~144 号动作槽
2. 对每个有内容的槽位通过 `GetActionText` 判断是否为宏（是 → 存 `macros`）
3. 否则用 `PickupAction`/`PlaceAction` + `CursorHasSpell` 探测是否为技能
   - 是技能 → 读取 Tooltip 第 1 行拆分为 技能名/等级，存 `spells`
   - 是物品 → 读取物品名存 `items`
4. 保存期间临时关闭 `autoSelfCast`，避免探测干扰
5. 完成后向聊天框输出提示

> 采用"按需探测 + 复用 Tooltip"的方式，避免每帧扫描，属于轻量优化。

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
- 使用 `ABP_SavingInProgress` 抑制标志：保存/加载过程中的动作条操作不会自触发自动保存。
- 登录/重载（`VARIABLES_LOADED`）后进入 **30 秒静默窗口期**（`ABP_StartupDelay`），期间忽略一切动作条变化事件，避免客户端恢复动作条时误保存覆盖已有配置。
- 注销（`PLAYER_LOGOUT`）阶段动作条已被客户端清空，因此**不执行自动保存**，避免覆盖有效数据。

## 函数清单

### 公共 API（暴露为全局）

| 函数 | 作用 |
|------|------|
| `ABP_OnLoad` | 注册事件与斜杠命令 |
| `ABP_OnEvent` | 初始化角色名、保存变量、菜单、按钮位置 |
| `ABP_SaveProfile` | 保存配置 |
| `ABP_LoadProfile` | 加载配置 |
| `ABP_ListProfiles` | 列出配置 |
| `ABP_RemoveProfile` | 删除配置 |
| `ABP_SlashCommand` | 斜杠命令分发 |
| `ABP_DropDownMenu_OnLoad` | 构建下拉菜单 |
| `ABPButton_UpdatePosition` | 按角度更新按钮位置 |
| `ABPButton_BeingDragged` | 拖动中计算角度 |
| `ABPButton_SetPosition` | 设置并持久化角度 |
| `ABP_AutoSaveProfile` | 执行自动保存 |
| `ABP_OnActionBarChanged` | 动作条变化事件处理（防抖标记） |
| `ABP_OnUpdate` | 计时帧驱动，防抖到期执行保存 |
| `ABP_CreateTimerFrame` | 创建独立计时帧 |

### 局部辅助函数

| 函数 | 作用 |
|------|------|
| `hasElements` | 判断表是否为空 |
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
| `ABP_StartupDelay` | 30 | 登录/重载后的静默窗口期（秒） |

## 技术要点与注意事项

1. **依赖客户端的 Tooltip 作为"数据探测仪"**：保存与加载都通过向 `ABP_Tooltip` 注入动作/物品并读取文本行来获取名称，这是 1.12 无原生 API 环境下的通用技巧，但意味着探测结果受客户端本地化/语言环境影响。
2. **`CursorHasSpell` 探测法**：通过拾取再放回动作槽判断是否为法术，期间主动关闭 `autoSelfCast` 以规避干扰。
3. **宏兼容双路径**：`GetSuperMacroInfo`（超级宏）与 `GetMacroIndexByName`（普通宏）双路回退。
4. **性能优化**：加载前预构建技能/物品映射表，将多次重复的 Tooltip 探测压缩为一次性的线性扫描（法术书、19 装备位、背包），并带 `leftCount` 提前终止。
5. **自触发抑制**：`ABP_SavingInProgress` 标志使保存/加载过程中的动作条操作不会触发自动保存，避免循环覆盖。
6. **注销阶段不保存**：`PLAYER_LOGOUT` 时动作条已被客户端清空，直接保存会写入空数据，故自动保存仅在正常游戏帧中通过事件/计时触发。
