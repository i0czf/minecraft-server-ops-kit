# 通用配方助手（模组知识库）

> 首包：2026-08-06  
> JEI 图标 / 多面板：2026-08-07  
> **现状（同日迭代后）**：中文检索、神秘 `recipe_parity`（奥术/注魔/坩埚）、注魔环绕布局、TC 原版要素色、皮革染色合成等

---

## 产品目标

接近 **JEI / REI**：格子里是**物品贴图**；不同机器/模组用**对应风格面板**；中文优先。

| 要素 | 状态 |
|------|------|
| 3×3 工作台 + 产出图标 | ✅ |
| 熔炉 / 高炉 / 烟熏 / 营火火焰面板 | ✅ |
| 奥术工作台（3×3 + 要素图标，无圆圈套壳） | ✅ |
| 注魔：中心核心 + **基座环绕**（非九宫格）+ 不稳定性 + 要素 | ✅ |
| 坩埚（催化剂 + 要素） | ✅ |
| 玛鲁姆灵魂注魔 / 诡厄仪式 / 烹饪锅 | ✅ |
| 中文名检索与展示 | ✅ 原版 zh_cn + 模组 lang |
| 当前服务器数据（JSON + TC parity） | ✅ |
| 完整 1:1 复刻每个模组 JEI 插件 | ⬜ 主题近似 |

---

## QQ 用法

```text
!配方 熔炉
!配方 铁锭
!配方 熟猪排
!配方 揭示护目镜          → 奥术 3×3 + 六元要素色
!配方 旅行者之靴          → 注魔环绕 + 旅行(红)/飞行(白) + 皮革靴棕
!配方 箱装卷心菜
!配方 苹果酒
!配方 malum:accelerating_inlay
!配方 goety:abyss_crown
```

- 全员可用：`!配方` / `!合成` / `!recipe`  
- 改 `recipe-lookup.ps1` 后**无需冷重启 MC**；下次查询即生效  
- 换模组后需重建索引（见下）

### 命令行

```powershell
# 换模组 / 修索引后强制重建（约 1～2 分钟）
powershell -File tools\build-recipe-index.ps1 -Force

# 查询（文字 + IMAGE:绝对路径）
powershell -File tools\recipe-lookup.ps1 -Query 旅行者之靴 -QqSummary
powershell -File tools\recipe-lookup.ps1 -Query 揭示护目镜 -Max 2 -QqSummary

# 贴图目录过期或贴图源变更时
Remove-Item tmp\recipe-index\texture-catalog.json -ErrorAction SilentlyContinue
Remove-Item tmp\recipe-index\icons\_tinted_v3 -Recurse -ErrorAction SilentlyContinue
```

### 一键

`一键脚本\一键便携-重建配方索引.bat`（重建 JSON 索引；贴图目录在查询时懒构建）

---

## 数据规模

| 项 | 说明 |
|----|------|
| 配方 | 由当前服务器的原版与模组数据动态生成，数量随整合包变化 |
| 可检索物品名 | 模组有中文名的条目 + 配方涉及物品；原版中文来自 assets `zh_cn` |
| 贴图源 | `mods/*.jar` + `bluemap/minecraft-client-*.jar` |

---

## 面板主题（自动选择）

| panel | 触发 | 布局要点 |
|-------|------|----------|
| `furnace` / `blast` / `smoker` / `campfire` | 烧炼类 | 原料 → 火焰 → 产物 |
| `thaumcraft` | 奥术合成 / thaumcraft 工作台配方 | 3×3 符文槽 + **原版色要素图标**（无圆圈） |
| `thaumcraft_infusion` | 注魔 | **中心核心 + 等角基座环**、不稳定性、要素、右侧产物 |
| `thaumcraft_crucible` | 坩埚 | 催化剂 → 产物 + 要素 |
| `malum_infusion` | 玛鲁姆 spirit_infusion 等 | 中心主料 + 环绕 + 精神 |
| `goety_ritual` | 诡厄仪式 | 祭品核 + 环 + 灵魂消耗 |
| `cooking` | 农夫乐事锅 / 汤锅等 | 材料格 + 暖色 |
| `craft` | 默认有序/无序 | JEI 灰底 3×3 |

索引字段（`build-recipe-index.ps1`）：

`panel` · `primaryInput` · `extraInputs` · `spirits` · `activationItem` · `meta`（research / costs / detail / 不稳定性等）

神秘时代研究配方来自 jar 内：

`data/thaumcraft/recipe_parity/runtime_manifest.json`

---

## 贴图与显示细节

| 能力 | 说明 |
|------|------|
| 物品栏图标 | 优先 `textures/item`；大方图集（如魔导透镜 256）裁切「内容最丰富」象限 |
| 命名别名 | `amber_bricks`↔`amberbrick`、`air_shard`→`shard`、`enchanted_fabric`→`cloth`、`boots_traveller`→`bootstraveler` 等 |
| 碎片染色 | 风/火/水/地/序/蚀碎片共用 `shard.png`，按元素色着色 |
| **要素色** | 对齐 TC6 `Aspect.java` 色值（如 **iter 旅行 `#e0585b` 红**、**volatus 飞行 `#e7e7d7` 近白**） |
| **皮革装备** | 底图 × 默认棕 `#A06540` + `*_overlay` 合成（避免灰底看起来像铁装） |
| 标签格 | 代表物图标（任意石头→圆石等） |
| 中文 | 模组 lang + 客户端 assets 原版 `zh_cn`；`揭示护目镜`≈`揭示之护目镜` 模糊匹配 |

---

## 产物路径

| 路径 | 内容 |
|------|------|
| `tmp/recipe-index/index.json` | 配方 + 物品名 + panel 扩展 |
| `tmp/recipe-index/meta.json` | 构建元数据 |
| `tmp/recipe-index/texture-catalog.json` | 贴图索引（约 24h） |
| `tmp/recipe-index/icons/` | 解压缓存；`_tinted_v3/` 要素/碎片染色图；`*.leather.png` 皮革合成 |
| `tmp/recipe-index/images/` | 每次查询生成的 PNG |
| `logs/recipe-index.log` | 构建 / 出图日志 |

---

## 说明与边界

1. **神秘时代**：普通 JSON 配方 + `recipe_parity`（奥术/注魔/坩埚）。纯代码动态配方、无数据的研究仍可能缺表。  
2. **注魔**按「核心 + 外围基座环 + 稳定性 + 要素」展示，**不是**工作台九宫格。  
3. **奥术要素**只画着色后的原版图标 + 数量，不再加圆圈套壳。  
4. 个别模组缺 `zh_cn` 或贴图命名极端时，仍可能露英文/短字降级。  
5. 不做：无头客户端实时截 JEI、完整研究树交互。

---

## 验收样例

| 查询 | 期望 |
|------|------|
| `!配方 熔炉` | 3×3 圆石 + 熔炉贴图 |
| `!配方 铁锭` | 优先高炉/熔炉火焰面板，中文矿名 |
| `!配方 揭示护目镜` | 奥术 3×3（皮革/金/魔导透镜）+ 六元本色要素 |
| `!配方 旅行者之靴` | 注魔环：中心**棕色皮革靴**，外围碎片/布/羽/鱼；要素旅行红、飞行白；不稳定性 |

---

## 变更记录

| 日期 | 说明 |
|------|------|
| 2026-08-06 | 首包索引 + 文字格 / 文字 PNG |
| 2026-08-06 | JEI 物品贴图 3×3 |
| 2026-08-07 | 多面板：熔炉火焰、神秘/玛鲁姆/诡厄/烹饪锅 |
| 2026-08-07 | 中文：原版 zh_cn + 模组可搜；TC recipe_parity；模糊中文 |
| 2026-08-07 | 注魔改为环绕基座布局；要素 TC6 原版色；去掉要素圆圈 |
| 2026-08-07 | 魔导透镜图集裁切；碎片/布匹/靴贴图别名；皮革靴棕染+overlay |
