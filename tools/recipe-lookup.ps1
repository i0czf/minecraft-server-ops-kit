param(
    [Parameter(Mandatory = $true)][string]$Query,
    [int]$Max = 5,
    [switch]$Rebuild,
    [switch]$NoImage,
    [switch]$QqSummary,
    [switch]$Quiet
)

# 本服配方查询：中文友好 + JEI 风格物品贴图九宫格 PNG

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$IndexPath = Join-Path $Root 'tmp\recipe-index\index.json'
$BuildScript = Join-Path $PSScriptRoot 'build-recipe-index.ps1'
$ImgDir = Join-Path $Root 'tmp\recipe-index\images'
$IconCacheDir = Join-Path $Root 'tmp\recipe-index\icons'
$CatalogPath = Join-Path $Root 'tmp\recipe-index\texture-catalog.json'
$LogPath = Join-Path $Root 'logs\recipe-index.log'

if ($Rebuild -or -not (Test-Path $IndexPath)) {
    if (-not (Test-Path $BuildScript)) { throw '缺少 build-recipe-index.ps1' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BuildScript -Force -Quiet
    if ($LASTEXITCODE -ne 0) { throw '构建配方索引失败' }
}
if (-not (Test-Path $IndexPath)) { throw '配方索引不存在，请先运行 tools\build-recipe-index.ps1 -Force' }

$raw = [IO.File]::ReadAllText($IndexPath, [Text.Encoding]::UTF8)
try { $idx = $raw | ConvertFrom-Json } catch {
    throw "索引解析失败：$($_.Exception.Message)"
}

# 贴图目录内存缓存（本次进程）
$script:TextureCatalog = $null
$script:IconPathCache = @{}
$script:OpenZips = @{}

function Write-RecipeLog([string]$m) {
    try {
        $d = Split-Path -Parent $LogPath
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content $LogPath ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
    } catch { }
}

# 英文残留 -> 中文（原版常见）
$enZh = @{
    'Iron Ingot' = '铁锭'; 'Gold Ingot' = '金锭'; 'Copper Ingot' = '铜锭'; 'Netherite Ingot' = '下界合金锭'
    'Raw Iron' = '粗铁'; 'Raw Gold' = '粗金'; 'Raw Copper' = '粗铜'
    'Iron Nugget' = '铁粒'; 'Gold Nugget' = '金粒'
    'Iron Ore' = '铁矿石'; 'Deepslate Iron Ore' = '深层铁矿石'
    'Cobblestone' = '圆石'; 'Stone' = '石头'; 'Oak Planks' = '橡木木板'
    'Stick' = '木棍'; 'Coal' = '煤炭'; 'Charcoal' = '木炭'
    'Redstone Dust' = '红石粉'; 'Redstone' = '红石粉'; 'Diamond' = '钻石'
    'Emerald' = '绿宝石'; 'Glass' = '玻璃'; 'Chest' = '箱子'
    'Furnace' = '熔炉'; 'Crafting Table' = '工作台'; 'Ender Pearl' = '末影珍珠'
    'Iron Block' = '铁块'; 'Gold Block' = '金块'; 'Copper Block' = '铜块'
    'Netherite Scrap' = '下界合金碎片'; 'Ancient Debris' = '远古残骸'
    'Bread' = '面包'; 'Wheat' = '小麦'; 'Bucket' = '桶'; 'Water Bucket' = '水桶'
    'Cooked Porkchop' = '熟猪排'; 'Raw Porkchop' = '生猪排'; 'Cooked Beef' = '牛排'; 'Raw Beef' = '生牛肉'
    'Cooked Chicken' = '熟鸡肉'; 'Raw Chicken' = '生鸡肉'; 'Cooked Mutton' = '熟羊肉'; 'Raw Mutton' = '生羊肉'
    'Cooked Cod' = '熟鳕鱼'; 'Cooked Salmon' = '熟鲑鱼'; 'Baked Potato' = '烤马铃薯'
    'Block of Iron' = '铁块'
    'Lava Bucket' = '熔岩桶'; 'Bowl' = '碗'; 'Paper' = '纸'; 'Book' = '书'
    'String' = '线'; 'Leather' = '皮革'; 'Bone' = '骨头'; 'Gunpowder' = '火药'
    'Blaze Powder' = '烈焰粉'; 'Blaze Rod' = '烈焰棒'; 'Slimeball' = '粘液球'
    'Nether Quartz' = '下界石英'; 'Obsidian' = '黑曜石'; 'Crying Obsidian' = '哭泣的黑曜石'
}

$builtinAlias = @{
    '铁锭' = 'minecraft:iron_ingot'; '金锭' = 'minecraft:gold_ingot'; '铜锭' = 'minecraft:copper_ingot'
    '下界合金锭' = 'minecraft:netherite_ingot'; '钻石' = 'minecraft:diamond'; '绿宝石' = 'minecraft:emerald'
    '红石' = 'minecraft:redstone'; '煤炭' = 'minecraft:coal'; '木棍' = 'minecraft:stick'
    '圆石' = 'minecraft:cobblestone'; '石头' = 'minecraft:stone'; '橡木木板' = 'minecraft:oak_planks'
    '玻璃' = 'minecraft:glass'; '箱子' = 'minecraft:chest'; '熔炉' = 'minecraft:furnace'
    '工作台' = 'minecraft:crafting_table'; '末影珍珠' = 'minecraft:ender_pearl'
    '粗铁' = 'minecraft:raw_iron'; '粗金' = 'minecraft:raw_gold'; '粗铜' = 'minecraft:raw_copper'
}

function Short-Name([string]$Name, [int]$MaxLen = 4) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '·' }
    $n = $Name.Trim()
    # 去掉括号后缀
    if ($n -match '^(.+?)\s*\(') { $n = $matches[1].Trim() }
    if ($n.Length -le $MaxLen) { return $n }
    return $n.Substring(0, $MaxLen)
}

function Item-NameOnly($idx, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return '空' }
    if ($Id.StartsWith('#')) {
        $tag = $Id.Substring(1)
        # 常见标签中文
        if ($tag -match 'stone_crafting') { return '任意石头类' }
        if ($tag -match 'planks') { return '任意木板' }
        if ($tag -match 'logs') { return '任意原木' }
        if ($tag -match 'ingots/iron') { return '任意铁锭' }
        if ($tag -match 'ingots/gold') { return '任意金锭' }
        if ($tag -match 'ingots/copper') { return '任意铜锭' }
        if ($tag -match 'coals') { return '任意煤炭' }
        if ($tag -match 'wool') { return '任意羊毛' }
        if ($tag -match 'leather') { return '任意皮革' }
        if ($tag -match 'glass') { return '任意玻璃' }
        if ($tag -match 'prismarine') { return '任意海晶' }
        if ($tag -match 'ender_pearl') { return '任意末影珍珠' }
        $short = ($tag -split '[/:]' | Select-Object -Last 1)
        return '标签:' + $short
    }
    $it = $null
    try { $it = $idx.items.$Id } catch { }
    if ($it -and $it.zh -and [string]$it.zh.Trim() -ne '') { return [string]$it.zh }
    if ($it -and $it.en) {
        $en = [string]$it.en
        if ($enZh.ContainsKey($en)) { return [string]$enZh[$en] }
        # 英文名尽量不直接甩给玩家：转成可读词
        $pretty = $en -replace '([a-z])([A-Z])', '$1 $2'
        if ($enZh.ContainsKey($pretty)) { return [string]$enZh[$pretty] }
    }
    # id 末段 → 下划线分词（仍非理想中文，但好过 raw English dump）
    if ($Id -match '^[^:]+:(.+)$') {
        $tail = $matches[1] -replace '_', ' '
        if ($enZh.ContainsKey($tail)) { return [string]$enZh[$tail] }
        # 常见词替换
        $tail2 = $tail
        $tail2 = $tail2 -replace '\biron\b', '铁' -replace '\bgold\b', '金' -replace '\bcopper\b', '铜'
        $tail2 = $tail2 -replace '\braw\b', '粗' -replace '\bcooked\b', '熟' -replace '\bblock\b', '块'
        if ($tail2 -ne $tail -and $tail2 -match '[\u4e00-\u9fff]') { return $tail2 }
        return $tail
    }
    return $Id
}

function Item-Label($idx, [string]$Id) {
    # 展示用：中文优先，不附带英文/ID（未知时才露 ID）
    $n = Item-NameOnly $idx $Id
    if ($n -eq $Id -or $n -match '^[a-z0-9_.:/-]+$') {
        # 仍是 id 形态
        if ($Id -match '^minecraft:(.+)$') {
            $t = $matches[1] -replace '_', ' '
            return $t
        }
        return $Id
    }
    return $n
}

function Type-Cn([string]$t) {
    switch -Regex ($t) {
        'crafting_shaped' { return '工作台·有序' }
        'crafting_shapeless' { return '工作台·无序' }
        'smelting' { return '熔炉烧炼' }
        'blasting' { return '高炉烧炼' }
        'smoking' { return '烟熏炉' }
        'campfire' { return '营火烹饪' }
        'stonecutting' { return '切石机' }
        'smithing' { return '锻造台' }
        'cooking' { return '烹饪锅' }
        'stockpot|flex_stockpot' { return '汤锅' }
        'flex_pot|:pot$' { return '炒锅' }
        'cutting|chopping' { return '砧板切割' }
        'cloche' { return '园艺罩' }
        'spirit_infusion' { return '灵魂注魔' }
        'soul_binding' { return '灵魂绑定' }
        'spirit_focusing' { return '精神聚焦' }
        'runeworking' { return '符文加工' }
        'goety:ritual' { return '诡厄仪式' }
        'cursed_infuser' { return '诅咒灌注' }
        'brewing' { return '酿造' }
        'crushing' { return '粉碎' }
        'milling' { return '碾磨' }
        'inscriber' { return '压印机' }
        'melting' { return '熔化' }
        'altar_recipe' { return '祭坛' }
        'gun_smith' { return '枪械工作台' }
        'arcane_shaped' { return '奥术合成·有序' }
        'arcane_shapeless' { return '奥术合成·无序' }
        'infusion_fixed|infusion_transform' { return '注魔' }
        'infusion_enchantment' { return '注魔附魔' }
        'crucible' { return '坩埚炼金' }
        default {
            if ($t -match 'thaumcraft') { return '神秘时代' }
            if ($t -match ':([a-z0-9_]+)$') { return '特殊:' + $matches[1] }
            return '特殊配方'
        }
    }
}

function Get-PanelKind($recipe) {
    # 优先索引内 panel 字段；否则按 type/id/result 推断
    try {
        $p = [string]$recipe.panel
        if ($p -and $p -ne '' -and $p -ne 'craft') {
            # craft 也可能被 thaum 覆盖
            if ($p -ne 'machine') { return $p }
        }
        if ($p -eq 'craft' -or $p -eq 'machine') {
            # fall through for namespace theme
        } elseif ($p) { return $p }
    } catch { }
    $t = [string]$recipe.type
    $id = [string]$recipe.id
    $res = [string]$recipe.result
    if ($t -match 'smelting$') { return 'furnace' }
    if ($t -match 'blasting') { return 'blast' }
    if ($t -match 'smoking') { return 'smoker' }
    if ($t -match 'campfire') { return 'campfire' }
    if ($t -match 'spirit_infusion|soul_binding|spirit_focusing') { return 'malum_infusion' }
    if ($t -match 'goety:ritual|cursed_infuser') { return 'goety_ritual' }
    if ($t -match 'cooking|stockpot|:pot$|flex_pot') { return 'cooking' }
    if ($t -match 'cutting|chopping') { return 'cutting' }
    if ($t -match 'smithing') { return 'smithing' }
    if ($t -match 'infusion') { return 'thaumcraft_infusion' }
    if ($t -match 'crucible') { return 'thaumcraft_crucible' }
    if ($t -match 'thaumcraft|arcane') { return 'thaumcraft' }
    if ($id -like 'thaumcraft:*' -or $res -like 'thaumcraft:*') { return 'thaumcraft' }
    if ($id -like 'malum:*' -or $res -like 'malum:*') { return 'malum' }
    if ($id -like 'goety:*' -or $res -like 'goety:*') { return 'goety' }
    if ($id -like 'taintedmagic:*' -or $res -like 'taintedmagic:*') { return 'thaumcraft' }
    if ($t -match 'crafting') { return 'craft' }
    return 'machine'
}

function Get-PanelTheme([string]$kind) {
    # bg / slot / slotEmpty / title / text / accent / border / fire
    switch ($kind) {
        'furnace' {
            return @{
                bg = @(110, 95, 85); slot = @(48, 42, 38); slotEmpty = @(38, 34, 30)
                title = @(255, 235, 210); text = @(240, 230, 220); accent = @(255, 180, 60)
                border = @(80, 60, 40); fire1 = @(255, 120, 20); fire2 = @(255, 200, 40)
            }
        }
        'blast' {
            return @{
                bg = @(70, 75, 85); slot = @(40, 44, 52); slotEmpty = @(32, 36, 42)
                title = @(220, 230, 255); text = @(210, 220, 240); accent = @(120, 160, 255)
                border = @(50, 55, 70); fire1 = @(100, 140, 255); fire2 = @(180, 210, 255)
            }
        }
        'smoker' {
            return @{
                bg = @(95, 90, 80); slot = @(45, 42, 38); slotEmpty = @(36, 34, 30)
                title = @(255, 240, 220); text = @(240, 230, 210); accent = @(200, 140, 80)
                border = @(70, 60, 45); fire1 = @(255, 100, 30); fire2 = @(255, 180, 50)
            }
        }
        'campfire' {
            return @{
                bg = @(85, 70, 55); slot = @(50, 40, 30); slotEmpty = @(40, 32, 24)
                title = @(255, 230, 180); text = @(245, 230, 200); accent = @(255, 140, 40)
                border = @(60, 45, 30); fire1 = @(255, 90, 10); fire2 = @(255, 210, 50)
            }
        }
        'thaumcraft' {
            # 深紫底 + 古铜金边，贴近奥术工作台
            return @{
                bg = @(36, 24, 52); slot = @(52, 40, 68); slotEmpty = @(30, 20, 44)
                title = @(255, 228, 150); text = @(236, 224, 255); accent = @(200, 160, 255)
                border = @(198, 158, 72); fire1 = @(170, 100, 255); fire2 = @(255, 210, 100)
            }
        }
        'thaumcraft_infusion' {
            # 更深虚空紫，注魔矩阵感；槽位略亮便于图标可读
            return @{
                bg = @(26, 16, 40); slot = @(58, 44, 78); slotEmpty = @(34, 24, 50)
                title = @(255, 214, 130); text = @(242, 230, 255); accent = @(186, 130, 255)
                border = @(212, 168, 78); fire1 = @(150, 80, 230); fire2 = @(255, 190, 120)
            }
        }
        'thaumcraft_crucible' {
            # 青蓝炼金锅
            return @{
                bg = @(28, 36, 52); slot = @(48, 56, 72); slotEmpty = @(32, 40, 54)
                title = @(190, 230, 255); text = @(220, 236, 255); accent = @(110, 190, 255)
                border = @(90, 150, 200); fire1 = @(90, 160, 255); fire2 = @(190, 230, 255)
            }
        }
        'malum' {
            return @{
                bg = @(48, 32, 42); slot = @(36, 24, 32); slotEmpty = @(28, 18, 26)
                title = @(255, 200, 220); text = @(240, 210, 230); accent = @(220, 120, 180)
                border = @(120, 60, 90); fire1 = @(200, 80, 140); fire2 = @(255, 180, 220)
            }
        }
        'malum_infusion' {
            return @{
                bg = @(36, 22, 40); slot = @(48, 28, 44); slotEmpty = @(30, 18, 32)
                title = @(255, 190, 230); text = @(245, 220, 240); accent = @(200, 100, 200)
                border = @(140, 70, 130); fire1 = @(180, 60, 200); fire2 = @(255, 160, 255)
            }
        }
        'goety' {
            return @{
                bg = @(32, 24, 40); slot = @(40, 28, 50); slotEmpty = @(26, 18, 34)
                title = @(210, 180, 255); text = @(220, 200, 240); accent = @(140, 80, 220)
                border = @(90, 50, 140); fire1 = @(120, 40, 200); fire2 = @(200, 120, 255)
            }
        }
        'goety_ritual' {
            return @{
                bg = @(28, 18, 36); slot = @(44, 28, 56); slotEmpty = @(24, 14, 32)
                title = @(230, 190, 255); text = @(230, 210, 250); accent = @(160, 60, 255)
                border = @(110, 40, 160); fire1 = @(100, 20, 180); fire2 = @(220, 140, 255)
            }
        }
        'cooking' {
            return @{
                bg = @(100, 85, 65); slot = @(55, 45, 35); slotEmpty = @(45, 36, 28)
                title = @(255, 245, 220); text = @(245, 235, 210); accent = @(255, 180, 80)
                border = @(80, 60, 40); fire1 = @(255, 120, 40); fire2 = @(255, 200, 80)
            }
        }
        'cutting' {
            return @{
                bg = @(120, 120, 110); slot = @(55, 55, 50); slotEmpty = @(45, 45, 40)
                title = @(40, 40, 35); text = @(50, 50, 45); accent = @(100, 100, 80)
                border = @(70, 70, 60); fire1 = @(180, 180, 100); fire2 = @(220, 220, 160)
            }
        }
        default {
            return @{
                bg = @(139, 139, 139); slot = @(55, 55, 55); slotEmpty = @(45, 45, 45)
                title = @(40, 40, 40); text = @(230, 230, 230); accent = @(255, 255, 80)
                border = @(30, 30, 30); fire1 = @(255, 120, 20); fire2 = @(255, 200, 40)
            }
        }
    }
}

function New-BrushFromRgb($rgb) {
    return New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, [int]$rgb[0], [int]$rgb[1], [int]$rgb[2]))
}
function New-PenFromRgb($rgb, [float]$w = 1) {
    return New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, [int]$rgb[0], [int]$rgb[1], [int]$rgb[2]), $w)
}

function Draw-FlameIcon($g, [int]$cx, [int]$cy, [int]$size, $th) {
    # 简易火焰（不依赖贴图）
    $b1 = New-BrushFromRgb $th.fire1
    $b2 = New-BrushFromRgb $th.fire2
    $pts = @(
        (New-Object System.Drawing.Point ($cx), ($cy + $size)),
        (New-Object System.Drawing.Point ($cx - [int]($size * 0.55)), ($cy + [int]($size * 0.35))),
        (New-Object System.Drawing.Point ($cx - [int]($size * 0.2)), ($cy + [int]($size * 0.15))),
        (New-Object System.Drawing.Point ($cx), ($cy - [int]($size * 0.15))),
        (New-Object System.Drawing.Point ($cx + [int]($size * 0.2)), ($cy + [int]($size * 0.15))),
        (New-Object System.Drawing.Point ($cx + [int]($size * 0.55)), ($cy + [int]($size * 0.35)))
    )
    $g.FillPolygon($b1, $pts)
    $inner = @(
        (New-Object System.Drawing.Point ($cx), ($cy + [int]($size * 0.85))),
        (New-Object System.Drawing.Point ($cx - [int]($size * 0.25)), ($cy + [int]($size * 0.45))),
        (New-Object System.Drawing.Point ($cx), ($cy + [int]($size * 0.15))),
        (New-Object System.Drawing.Point ($cx + [int]($size * 0.25)), ($cy + [int]($size * 0.45)))
    )
    $g.FillPolygon($b2, $inner)
    $b1.Dispose(); $b2.Dispose()
}

function Draw-RuneBorder($g, $rect, $th) {
    # 神秘符文风外框：双线 + 角饰
    $penGold = New-PenFromRgb $th.border 2
    $penGlow = New-PenFromRgb $th.accent 1
    $g.DrawRectangle($penGold, $rect)
    $inset = New-Object System.Drawing.Rectangle ($rect.X + 2), ($rect.Y + 2), ($rect.Width - 4), ($rect.Height - 4)
    $g.DrawRectangle($penGlow, $inset)
    $c = 6
    # 四角短划
    foreach ($corner in @(
            @($rect.X, $rect.Y, 1, 1),
            @(($rect.X + $rect.Width), $rect.Y, -1, 1),
            @($rect.X, ($rect.Y + $rect.Height), 1, -1),
            @(($rect.X + $rect.Width), ($rect.Y + $rect.Height), -1, -1)
        )) {
        $x = [int]$corner[0]; $y = [int]$corner[1]; $dx = [int]$corner[2]; $dy = [int]$corner[3]
        $g.DrawLine($penGold, $x, $y, ($x + $dx * $c), $y)
        $g.DrawLine($penGold, $x, $y, $x, ($y + $dy * $c))
    }
    $penGold.Dispose(); $penGlow.Dispose()
}

function Resolve-SpiritItemId([string]$SpiritType) {
    # malum:aerial / thaumcraft:aer → 图标候选
    $ns = 'malum'
    $tail = $SpiritType
    if ($SpiritType -match '^([^:]+):([^:]+)$') {
        $ns = $matches[1]; $tail = $matches[2]
    }
    $cands = New-Object System.Collections.Generic.List[string]
    if ($ns -eq 'thaumcraft' -or $tail -match '^(aer|aqua|ignis|ordo|perditio|terra|sensus|auram|praecantatio)') {
        $cands.Add("thaumcraft:aspect_$tail") | Out-Null
        $cands.Add("thaumcraft:$tail") | Out-Null
        $cands.Add("thaumcraft:${tail}_shard") | Out-Null
    }
    $cands.Add("malum:${tail}_spirited_glass") | Out-Null
    $cands.Add("malum:${tail}_spirit") | Out-Null
    $cands.Add("malum:${tail}_spirit_shard") | Out-Null
    $cands.Add("malum:spirit_shard") | Out-Null
    $cands.Add("malum:umbral_spirit_shard") | Out-Null
    return @($cands)
}

function Aspect-NameCn([string]$AspectId) {
    $t = $AspectId
    if ($t -match ':([^:*]+)') { $t = $matches[1] }
    $t = $t -replace '\*\d+$', ''
    $map = @{
        aer = '风'; aqua = '水'; ignis = '火'; ordo = '序'; perditio = '蚀'; terra = '地'
        sensus = '感'; auram = '灵气'; praecantatio = '咒'; potentia = '能'
        tutamen = '御'; fabrico = '造'; metallum = '金'; vitreus = '晶'
        spiritus = '魂'; mortuus = '亡'; lux = '光'; tenebrae = '暗'
        humanus = '人'; bestia = '兽'; herba = '草'; instrumentum = '器'
        permutatio = '变'; vacuos = '空'; motus = '动'; gelum = '寒'
    }
    if ($map.ContainsKey($t)) { return $map[$t] }
    return $t
}

function Get-KeyMap($recipe) {
    $map = @{}
    if ($null -eq $recipe.key) { return $map }
    # JSON object after ConvertFrom-Json
    if ($recipe.key.PSObject) {
        foreach ($p in $recipe.key.PSObject.Properties) {
            $map[[string]$p.Name] = [string]$p.Value
        }
    }
    return $map
}

# ---- 物品贴图：目录构建 / 缓存 / 解析 ----

# 常见标签 → 代表物品（用于九宫格显示）
$script:TagIconMap = @{
    '#minecraft:stone_crafting_materials' = 'minecraft:cobblestone'
    '#minecraft:stone_tool_materials'     = 'minecraft:cobblestone'
    '#minecraft:cobblestone'              = 'minecraft:cobblestone'
    '#minecraft:planks'                   = 'minecraft:oak_planks'
    '#minecraft:logs'                     = 'minecraft:oak_log'
    '#minecraft:logs_that_burn'           = 'minecraft:oak_log'
    '#minecraft:wooden_slabs'             = 'minecraft:oak_slab'
    '#minecraft:coals'                    = 'minecraft:coal'
    '#minecraft:wool'                     = 'minecraft:white_wool'
    '#c:ingots/iron'                      = 'minecraft:iron_ingot'
    '#c:ingots/gold'                      = 'minecraft:gold_ingot'
    '#c:ingots/copper'                    = 'minecraft:copper_ingot'
    '#c:ingots/netherite'                 = 'minecraft:netherite_ingot'
    '#c:gems/diamond'                     = 'minecraft:diamond'
    '#c:gems/emerald'                     = 'minecraft:emerald'
    '#c:dusts/redstone'                   = 'minecraft:redstone'
    '#c:crops/wheat'                      = 'minecraft:wheat'
    '#forge:ingots/iron'                  = 'minecraft:iron_ingot'
    '#forge:cobblestone'                  = 'minecraft:cobblestone'
}

function Resolve-TagToItemId([string]$TagOrId) {
    if ([string]::IsNullOrWhiteSpace($TagOrId)) { return $null }
    if (-not $TagOrId.StartsWith('#')) { return $TagOrId }
    if ($script:TagIconMap.ContainsKey($TagOrId)) { return [string]$script:TagIconMap[$TagOrId] }
    $t = $TagOrId.ToLowerInvariant()
    if ($t -match 'planks') { return 'minecraft:oak_planks' }
    if ($t -match 'logs') { return 'minecraft:oak_log' }
    if ($t -match 'cobble|stone_crafting|stone_tool') { return 'minecraft:cobblestone' }
    if ($t -match 'ingots?/iron|iron_ingot') { return 'minecraft:iron_ingot' }
    if ($t -match 'ingots?/gold|gold_ingot') { return 'minecraft:gold_ingot' }
    if ($t -match 'ingots?/copper') { return 'minecraft:copper_ingot' }
    if ($t -match 'coals?$|/coal') { return 'minecraft:coal' }
    if ($t -match 'wool') { return 'minecraft:white_wool' }
    if ($t -match 'glass') { return 'minecraft:glass' }
    if ($t -match 'diamond') { return 'minecraft:diamond' }
    if ($t -match 'redstone') { return 'minecraft:redstone' }
    # 猜 tag 末段是否为物品 id
    if ($TagOrId -match '#(?:c:|forge:|minecraft:)?(?:[a-z0-9_]+/)?([a-z0-9_]+)$') {
        $tail = $matches[1]
        return "minecraft:$tail"
    }
    return $null
}

function Get-TextureJarCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    # 1) BlueMap 缓存的原版 client jar（含 item/block 贴图）
    $bm = Join-Path $Root 'bluemap\minecraft-client-1.21.1.jar'
    if (Test-Path -LiteralPath $bm) { $list.Add($bm) | Out-Null }
    # 2) 服务端 mods（主来源；客户端 mods 大多重复，不扫全量以免首次 20s+）
    $modsDir = Join-Path $Root 'mods'
    if (Test-Path $modsDir) {
        Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.disable' -and $_.Name -notlike '*.disabled' } |
            ForEach-Object { $list.Add($_.FullName) | Out-Null }
    }
    # 3) 若无 BlueMap client jar，再补便携客户端 version jar
    if (-not (Test-Path -LiteralPath $bm)) {
        $verRoot = Join-Path $Root '客户端\.minecraft\versions'
        if (Test-Path $verRoot) {
            Get-ChildItem -LiteralPath $verRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $vjar = Get-ChildItem -LiteralPath $_.FullName -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike 'HMCL*' -and $_.Length -gt 5MB } |
                    Sort-Object Length -Descending | Select-Object -First 1
                if ($vjar) { $list.Add($vjar.FullName) | Out-Null }
            }
        }
    }
    return @($list | Select-Object -Unique)
}

function Get-TexturePriority([string]$Kind, [string]$FileBase) {
    # 数字越小越优先
    $isVariant = $FileBase -match '_(front|side|top|bottom|inner|outer|on|off|lit|still|flow|stage\d+)$'
    if ($Kind -eq 'item' -and -not $isVariant) { return 10 }
    if ($Kind -eq 'item') { return 20 }
    if ($Kind -eq 'block' -and -not $isVariant) { return 30 }
    if ($FileBase -match '_front(_on)?$') { return 40 }
    if ($FileBase -match '_side$') { return 50 }
    if ($FileBase -match '_top$') { return 60 }
    return 80
}

function Get-CatalogKeys([string]$Ns, [string]$FileBase) {
    $keys = New-Object System.Collections.Generic.List[string]
    $keys.Add("${Ns}:${FileBase}") | Out-Null
    # furnace_front -> furnace
    if ($FileBase -match '^(.+)_(front|side|top|bottom|inner|outer)(_on|_off|_lit)?$') {
        $keys.Add("${Ns}:$($matches[1])") | Out-Null
    }
    if ($FileBase -match '^(.+)_stage\d+$') {
        $keys.Add("${Ns}:$($matches[1])") | Out-Null
    }
    # camelCase 无下划线贴图：amberbrick → amber_brick / amber_bricks
    if ($FileBase -notmatch '_' -and $FileBase -match '^[a-z]+') {
        if ($FileBase -match '^(.*)(block|brick|ore|stone|wood|log|planks?|slab|stairs?)$') {
            $stem = $matches[1]; $suf = $matches[2]
            if ($stem) {
                $keys.Add("${Ns}:${stem}_${suf}") | Out-Null
                if ($suf -eq 'brick') { $keys.Add("${Ns}:${stem}_bricks") | Out-Null }
                if ($suf -eq 'block') { $keys.Add("${Ns}:${stem}_block") | Out-Null }
            }
        }
    }
    # shard_balanced → balanced_shard
    if ($FileBase -eq 'shard_balanced') { $keys.Add("${Ns}:balanced_shard") | Out-Null }
    if ($FileBase -match '^shard_(.+)$') { $keys.Add("${Ns}:$($matches[1])_shard") | Out-Null }
    if ($FileBase -eq 'shard') {
        foreach ($el in @('air', 'fire', 'water', 'earth', 'order', 'entropy')) {
            $keys.Add("${Ns}:${el}_shard") | Out-Null
        }
    }
    if ($FileBase -eq 'cloth') {
        $keys.Add("${Ns}:enchanted_fabric") | Out-Null
        $keys.Add("${Ns}:fabric") | Out-Null
        $keys.Add("${Ns}:magic_cloth") | Out-Null
    }
    if ($FileBase -eq 'bootstraveler') {
        $keys.Add("${Ns}:boots_traveller") | Out-Null
        $keys.Add("${Ns}:traveller_boots") | Out-Null
    }
    return $keys
}

function Build-TextureCatalog {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $best = @{} # id -> @{ prio; jar; entry }
    $jars = Get-TextureJarCandidates
    $scanned = 0
    foreach ($jarPath in $jars) {
        try {
            $z = [IO.Compression.ZipFile]::OpenRead($jarPath)
            try {
                foreach ($e in $z.Entries) {
                    $fn = $e.FullName.Replace('\', '/')
                    # item/block（含一层子目录，如 spirited_glass/aerial_xxx.png）
                    if ($fn -match '^assets/([^/]+)/textures/(item|block)/(?:([^/]+)/)?([^/]+\.png)$') {
                        $ns = $matches[1]
                        $kind = $matches[2]
                        $sub = $matches[3]
                        $file = $matches[4]
                        $base = $file -replace '\.png$', ''
                        if ($base -match '(_overlay|_particle|_inventory|_gui)') { continue }
                        $prio = Get-TexturePriority $kind $base
                        $keys = @(Get-CatalogKeys $ns $base)
                        # 子目录名也可作 id 提示
                        if ($sub -and $base -notlike "$sub*") {
                            $keys += "${ns}:${sub}_${base}"
                        }
                        foreach ($id in $keys) {
                            if (-not $best.ContainsKey($id) -or $prio -lt $best[$id].prio) {
                                $best[$id] = @{ prio = $prio; jar = $jarPath; entry = $fn }
                            }
                        }
                        $scanned++
                        continue
                    }
                    # 神秘要素图标
                    if ($fn -match '^assets/([^/]+)/textures/aspects/([^/]+\.png)$') {
                        $ns = $matches[1]
                        $base = $matches[2] -replace '\.png$', ''
                        if ($base.StartsWith('_')) { continue }
                        $id = "${ns}:aspect_$base"
                        $prio = 15
                        if (-not $best.ContainsKey($id) -or $prio -lt $best[$id].prio) {
                            $best[$id] = @{ prio = $prio; jar = $jarPath; entry = $fn }
                        }
                        # 也登记简写 thaumcraft:aer 等
                        $id2 = "${ns}:$base"
                        if (-not $best.ContainsKey($id2)) {
                            $best[$id2] = @{ prio = 70; jar = $jarPath; entry = $fn }
                        }
                        $scanned++
                    }
                }
            } finally { $z.Dispose() }
        } catch {
            Write-RecipeLog ("catalog jar skip: {0} {1}" -f $jarPath, $_.Exception.Message)
        }
    }
    # 序列化为 JSON 对象
    $obj = [ordered]@{}
    foreach ($k in ($best.Keys | Sort-Object)) {
        $obj[$k] = [ordered]@{
            jar   = [string]$best[$k].jar
            entry = [string]$best[$k].entry
            prio  = [int]$best[$k].prio
        }
    }
    $dir = Split-Path -Parent $CatalogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($obj | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $CatalogPath -Encoding UTF8
    Write-RecipeLog ("texture catalog: {0} ids from {1} jars ({2} png entries)" -f $obj.Count, $jars.Count, $scanned)
    return $obj
}

function Ensure-TextureCatalog {
    if ($null -ne $script:TextureCatalog) { return $script:TextureCatalog }
    $needRebuild = $true
    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $CatalogPath).LastWriteTime
            # 目录 24h 内有效；mods 变更后可删文件强制重建
            if ($age.TotalHours -lt 24) { $needRebuild = $false }
        } catch { $needRebuild = $true }
    }
    if ($needRebuild) {
        $script:TextureCatalog = Build-TextureCatalog
    } else {
        try {
            $rawCat = [IO.File]::ReadAllText($CatalogPath, [Text.Encoding]::UTF8)
            $script:TextureCatalog = $rawCat | ConvertFrom-Json
        } catch {
            $script:TextureCatalog = Build-TextureCatalog
        }
    }
    return $script:TextureCatalog
}

function Get-OpenZip([string]$JarPath) {
    if ($script:OpenZips.ContainsKey($JarPath)) { return $script:OpenZips[$JarPath] }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $z = [IO.Compression.ZipFile]::OpenRead($JarPath)
    $script:OpenZips[$JarPath] = $z
    return $z
}

function Close-OpenZips {
    foreach ($k in @($script:OpenZips.Keys)) {
        try { $script:OpenZips[$k].Dispose() } catch { }
    }
    $script:OpenZips = @{}
}

function Get-CatalogEntry([string]$ItemId) {
    $cat = Ensure-TextureCatalog
    if (-not $cat) { return $null }
    if ($cat -is [System.Collections.IDictionary]) {
        if ($cat.Contains($ItemId)) { return $cat[$ItemId] }
        return $null
    }
    try {
        $prop = $cat.PSObject.Properties[$ItemId]
        if ($prop) { return $prop.Value }
    } catch { }
    return $null
}

function Extract-IconFromCatalog([string]$ItemId) {
    $info = Get-CatalogEntry $ItemId
    # 目录键可能是无下划线贴图名：goggles_revealing → gogglesrevealing
    if (-not $info -and $ItemId -match '^([^:]+):(.+)$') {
        $ns0 = $matches[1]; $p0 = $matches[2]
        $compact = $p0 -replace '_', ''
        if ($compact -ne $p0) { $info = Get-CatalogEntry "${ns0}:$compact" }
        if (-not $info -and $compact.EndsWith('s') -and $compact.Length -gt 2) {
            $info = Get-CatalogEntry ("{0}:{1}" -f $ns0, $compact.Substring(0, $compact.Length - 1))
        }
    }
    if (-not $info) { return $null }
    $jar = [string]$info.jar
    $entry = [string]$info.entry
    if ([string]::IsNullOrWhiteSpace($jar) -or -not (Test-Path -LiteralPath $jar)) { return $null }

    if ($ItemId -match '^([^:]+):(.+)$') {
        $ns = $matches[1]; $path = $matches[2] -replace '/', '_'
    } else {
        $ns = '_'; $path = ($ItemId -replace '[^\w\-]', '_')
    }
    $outDir = Join-Path $IconCacheDir $ns
    $outFile = Join-Path $outDir ($path + '.png')
    if (Test-Path -LiteralPath $outFile) { return $outFile }

    try {
        if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $z = Get-OpenZip $jar
        $ent = $z.GetEntry($entry)
        if (-not $ent) {
            # 部分 jar 路径大小写不一致
            $ent = $z.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $entry } | Select-Object -First 1
        }
        if (-not $ent) { return $null }
        $src = $ent.Open()
        try {
            $fs = [IO.File]::Create($outFile)
            try { $src.CopyTo($fs) } finally { $fs.Close() }
        } finally { $src.Close() }
        return $outFile
    } catch {
        Write-RecipeLog ("extract icon fail {0}: {1}" -f $ItemId, $_.Exception.Message)
        return $null
    }
}

function Get-ItemIdVariants([string]$ItemId) {
    $list = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($ItemId)) { return @() }
    $list.Add($ItemId) | Out-Null
    if ($ItemId -notmatch '^([^:]+):(.+)$') { return @($list) }
    $ns = $matches[1]; $path = $matches[2]
    # 去下划线：amber_bricks → amberbricks；再去尾 s → amberbrick（TC 贴图命名）
    $compact = $path -replace '_', ''
    if ($compact -ne $path) { $list.Add("${ns}:$compact") | Out-Null }
    if ($compact.Length -gt 2 -and $compact.EndsWith('s')) {
        $list.Add("${ns}:$($compact.Substring(0, $compact.Length - 1))") | Out-Null
    }
    if ($path.EndsWith('s') -and $path.Length -gt 2) {
        $list.Add("${ns}:$($path.Substring(0, $path.Length - 1))") | Out-Null
    }
    # block ↔ bricks 常见别名
    if ($path -match '_bricks?$') {
        $stem = $path -replace '_bricks?$', ''
        $list.Add("${ns}:${stem}_block") | Out-Null
        $list.Add("${ns}:${stem}block") | Out-Null
        $list.Add("${ns}:${stem}brick") | Out-Null
    }
    if ($path -match '_block$') {
        $stem = $path -replace '_block$', ''
        $list.Add("${ns}:${stem}block") | Out-Null
    }
    # amber_bearing_stone → amber_ore / amberore
    if ($path -match '^(.+)_bearing_stone$') {
        $stem = $matches[1]
        $list.Add("${ns}:${stem}_ore") | Out-Null
        $list.Add("${ns}:${stem}ore") | Out-Null
    }
    # balanced_shard → shard_balanced；air_shard → shard 等
    if ($path -eq 'balanced_shard') {
        $list.Add("${ns}:shard_balanced") | Out-Null
    }
    if ($path -match '^(air|fire|water|earth|order|entropy|nether|taint)_shard$') {
        $list.Add("${ns}:shard") | Out-Null
        $list.Add("${ns}:$($matches[1])shard") | Out-Null
    }
    if ($path -match '^(.+)_shard$' -and $path -ne 'balanced_shard') {
        $list.Add("${ns}:shard") | Out-Null
    }
    if ($path -match '^shard_(.+)$') {
        $list.Add("${ns}:$($matches[1])_shard") | Out-Null
    }
    # 神秘时代常见 id ↔ 贴图名不一致
    if ($path -eq 'enchanted_fabric' -or $path -eq 'magic_cloth' -or $path -eq 'fabric') {
        $list.Add("${ns}:cloth") | Out-Null
        $list.Add("${ns}:enchanted_fabric") | Out-Null
    }
    if ($path -eq 'cloth') {
        $list.Add("${ns}:enchanted_fabric") | Out-Null
    }
    if ($path -eq 'boots_traveller' -or $path -eq 'traveller_boots' -or $path -eq 'boots_of_the_traveller') {
        $list.Add("${ns}:bootstraveler") | Out-Null
        $list.Add("${ns}:boots_traveller") | Out-Null
    }
    if ($path -eq 'bootstraveler') {
        $list.Add("${ns}:boots_traveller") | Out-Null
    }
    # 同 path 原版回退
    if ($ns -ne 'minecraft') { $list.Add("minecraft:$path") | Out-Null }
    return @($list | Select-Object -Unique)
}

function Resolve-ItemIconPath([string]$IdOrTag) {
    if ([string]::IsNullOrWhiteSpace($IdOrTag)) { return $null }
    if ($script:IconPathCache.ContainsKey($IdOrTag)) {
        $c = $script:IconPathCache[$IdOrTag]
        if ($c -eq '') { return $null }
        return $c
    }
    $itemId = Resolve-TagToItemId $IdOrTag
    if (-not $itemId) {
        $script:IconPathCache[$IdOrTag] = ''
        return $null
    }
    $tryIds = @(Get-ItemIdVariants $itemId)
    foreach ($tid in $tryIds) {
        if ($tid -match '^([^:]+):(.+)$') {
            $cached = Join-Path $IconCacheDir (Join-Path $matches[1] (($matches[2] -replace '/', '_') + '.png'))
            if (Test-Path -LiteralPath $cached) {
                $script:IconPathCache[$IdOrTag] = $cached
                return $cached
            }
        }
    }
    foreach ($tid in $tryIds) {
        $path = Extract-IconFromCatalog $tid
        if ($path) {
            $script:IconPathCache[$IdOrTag] = $path
            $script:IconPathCache[$itemId] = $path
            return $path
        }
    }
    $script:IconPathCache[$IdOrTag] = ''
    return $null
}

function Get-ContentScoreBmp([System.Drawing.Bitmap]$Bmp, [int]$X0, [int]$Y0, [int]$Sz) {
    $score = 0
    $step = [Math]::Max(1, [int]($Sz / 32))
    for ($x = $X0; $x -lt ($X0 + $Sz); $x += $step) {
        for ($y = $Y0; $y -lt ($Y0 + $Sz); $y += $step) {
            if ($x -lt 0 -or $y -lt 0 -or $x -ge $Bmp.Width -or $y -ge $Bmp.Height) { continue }
            $c = $Bmp.GetPixel($x, $y)
            if ($c.A -lt 16) { continue }
            # 彩色/高亮像素加权（宝石、符文）
            $chroma = [Math]::Abs([int]$c.R - [int]$c.G) + [Math]::Abs([int]$c.G - [int]$c.B) + [Math]::Abs([int]$c.B - [int]$c.R)
            if ($chroma -gt 40) { $score += 3 }
            elseif ($c.R -gt 30 -or $c.G -gt 30 -or $c.B -gt 30) { $score += 1 }
        }
    }
    return $score
}

function Get-OpaqueBounds([System.Drawing.Bitmap]$Bmp, [int]$X0, [int]$Y0, [int]$Sz) {
    $minX = $X0 + $Sz; $minY = $Y0 + $Sz; $maxX = $X0; $maxY = $Y0
    $found = $false
    $step = [Math]::Max(1, [int]($Sz / 64))
    for ($x = $X0; $x -lt ($X0 + $Sz); $x += $step) {
        for ($y = $Y0; $y -lt ($Y0 + $Sz); $y += $step) {
            if ($x -ge $Bmp.Width -or $y -ge $Bmp.Height) { continue }
            $c = $Bmp.GetPixel($x, $y)
            if ($c.A -lt 24) { continue }
            if ($c.R -lt 8 -and $c.G -lt 8 -and $c.B -lt 8) { continue }
            $found = $true
            if ($x -lt $minX) { $minX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
    if (-not $found) {
        return (New-Object System.Drawing.Rectangle $X0, $Y0, $Sz, $Sz)
    }
    # 正方形包围，略留边
    $pad = [Math]::Max(2, [int]($Sz * 0.04))
    $minX = [Math]::Max($X0, $minX - $pad)
    $minY = [Math]::Max($Y0, $minY - $pad)
    $maxX = [Math]::Min(($X0 + $Sz - 1), $maxX + $pad)
    $maxY = [Math]::Min(($Y0 + $Sz - 1), $maxY + $pad)
    $bw = $maxX - $minX + 1
    $bh = $maxY - $minY + 1
    $side = [Math]::Max($bw, $bh)
    if ($minX + $side -gt $X0 + $Sz) { $minX = $X0 + $Sz - $side }
    if ($minY + $side -gt $Y0 + $Sz) { $minY = $Y0 + $Sz - $side }
    if ($minX -lt $X0) { $minX = $X0 }
    if ($minY -lt $Y0) { $minY = $Y0 }
    return (New-Object System.Drawing.Rectangle $minX, $minY, $side, $side)
}

function Get-InventoryIconPath([string]$RawPath, [string]$ItemId) {
    # 大图集/模型贴图 → 裁出物品栏用图标（如魔导透镜 256 图集 → 华丽六边形）
    if ([string]::IsNullOrWhiteSpace($RawPath) -or -not (Test-Path -LiteralPath $RawPath)) { return $null }
    $invPath = if ($RawPath -match '\.inv\.png$') { $RawPath } else { $RawPath -replace '\.png$', '.inv.png' }
    # 版本标记：逻辑变更后强制重裁
    $invVer = $invPath -replace '\.inv\.png$', '.inv2.png'
    try {
        if ((Test-Path -LiteralPath $invVer) -and
            (Get-Item -LiteralPath $invVer).LastWriteTime -ge (Get-Item -LiteralPath $RawPath).LastWriteTime -and
            (Get-Item -LiteralPath $invVer).Length -gt 32) {
            return $invVer
        }
    } catch { }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $img = [System.Drawing.Bitmap]::FromFile($RawPath)
        try {
            $w = [int]$img.Width
            $h = [int]$img.Height
            # 已是物品栏尺寸
            if ($w -le 32 -and $h -le 32) { return $RawPath }

            $srcRect = $null
            if ($w -eq $h -and $w -ge 64) {
                $tile = [int]($w / 2)
                # 四象限打分，取「内容最丰富」一块（魔导透镜左下宝石环得分最高）
                $cands = @(
                    @{ x = 0; y = 0 },
                    @{ x = $tile; y = 0 },
                    @{ x = 0; y = $tile },
                    @{ x = $tile; y = $tile }
                )
                $best = $null; $bestScore = -1
                foreach ($q in $cands) {
                    $sc = Get-ContentScoreBmp $img ([int]$q.x) ([int]$q.y) $tile
                    if ($sc -gt $bestScore) { $bestScore = $sc; $best = $q }
                }
                # 已知魔导透镜/扫描仪：强制偏好左下
                if ($ItemId -match 'thaumometer|scanner' -or $RawPath -match 'thaumometer|scanner') {
                    $best = @{ x = 0; y = $tile }
                }
                $srcRect = Get-OpaqueBounds $img ([int]$best.x) ([int]$best.y) $tile
            } elseif ($h -gt $w -and $w -gt 0 -and ($h % $w) -eq 0 -and $w -le 64) {
                $srcRect = New-Object System.Drawing.Rectangle 0, 0, $w, $w
            } elseif ($w -gt $h -and $h -gt 0 -and ($w % $h) -eq 0 -and $h -le 64) {
                $srcRect = New-Object System.Drawing.Rectangle 0, 0, $h, $h
            } else {
                $s = [Math]::Min($w, $h)
                if ($s -gt 128) { $s = [int]($s / 2) }
                $srcRect = Get-OpaqueBounds $img 0 0 $s
            }

            $outSize = 64
            $bmp = New-Object System.Drawing.Bitmap $outSize, $outSize
            $gg = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $gg.Clear([System.Drawing.Color]::Transparent)
                $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $gg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                if ($srcRect.Width -le 32) {
                    $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                    $gg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
                }
                $dest = New-Object System.Drawing.Rectangle 0, 0, $outSize, $outSize
                $gg.DrawImage($img, $dest, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
            } finally { $gg.Dispose() }
            $dir = Split-Path -Parent $invVer
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $bmp.Save($invVer, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            return $invVer
        } finally { $img.Dispose() }
    } catch {
        Write-RecipeLog ("inv icon crop fail {0}: {1}" -f $ItemId, $_.Exception.Message)
        return $RawPath
    }
}

function HexTo-Rgb([int]$Hex) {
    return @(
        [int](($Hex -shr 16) -band 0xFF),
        [int](($Hex -shr 8) -band 0xFF),
        [int]($Hex -band 0xFF)
    )
}

function Get-AspectColorRgb([string]$AspectName) {
    # 神秘时代原版色（Thaumcraft 6 Aspect.java 色值，白底贴图乘色）
    $n = $AspectName.ToLowerInvariant()
    if ($n -match ':([^:]+)$') { $n = $matches[1] }
    $n = $n -replace '\*\d+$', '' -replace '^aspect_', ''
    # 0xRRGGBB
    $hexMap = @{
        # 六元
        aer = 0xffff7e; terra = 0x56c000; ignis = 0xff5a01
        aqua = 0x3cd4fc; ordo = 0xd5d4ec; perditio = 0x404040
        # 复合（与游戏内 essentia/JEI 一致）
        vacuos = 0x888888; lux = 0xffffc0; motus = 0xcdccf4
        gelum = 0xe1ffff; vitreus = 0x80ffff; metallum = 0xb5b5cd
        victus = 0xde0005; mortuus = 0x887788; potentia = 0xc0ffff
        permutatio = 0x578357; praecantatio = 0xcf00ff; auram = 0xffc0ff
        vitium = 0x800080; tenebrae = 0x222222; alienis = 0x805080
        herba = 0x01ac00; instrumentum = 0x4040ee; fabrico = 0x809d80
        machina = 0x8080a0; vinculum = 0x9a8080; spiritus = 0xebebfb
        cognitio = 0xffc2b3; sensus = 0x0fd9ff; aversio = 0xc05050
        praemunio = 0x00c0c0; desiderium = 0xe5be53; exanimis = 0x3a4000
        bestia = 0x9f6409; humanus = 0xffd7c0
        # 用户点名：旅行=红，飞行=白
        volatus = 0xe7e7d7; iter = 0xe0585b
        fames = 0x9a0305; limus = 0x01ff70; lucrum = 0xe5be53
        messis = 0xe1b529; pannus = 0xeaeac2; tutamen = 0x00c0c0
        telum = 0xc05050
    }
    if ($hexMap.ContainsKey($n)) { return (HexTo-Rgb ([int]$hexMap[$n]) ) }
    return (HexTo-Rgb 0xc8a0ff)
}

function Get-ShardTintRgb([string]$ItemId) {
    # 风之碎片等共用 shard.png，按元素染色
    if ($ItemId -match 'air_shard|aer') { return (Get-AspectColorRgb 'aer') }
    if ($ItemId -match 'fire_shard|ignis') { return (Get-AspectColorRgb 'ignis') }
    if ($ItemId -match 'water_shard|aqua') { return (Get-AspectColorRgb 'aqua') }
    if ($ItemId -match 'earth_shard|terra') { return (Get-AspectColorRgb 'terra') }
    if ($ItemId -match 'order_shard|ordo') { return (Get-AspectColorRgb 'ordo') }
    if ($ItemId -match 'entropy_shard|perditio') { return (Get-AspectColorRgb 'perditio') }
    if ($ItemId -match 'balanced_shard') { return @(220, 200, 255) }
    return $null
}

function New-ColorizedBitmap([System.Drawing.Bitmap]$Src, [int[]]$Rgb) {
    # 白/灰贴图 × 目标色（保留 alpha）
    $w = $Src.Width; $h = $Src.Height
    $out = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $tr = [int]$Rgb[0]; $tg = [int]$Rgb[1]; $tb = [int]$Rgb[2]
    for ($x = 0; $x -lt $w; $x++) {
        for ($y = 0; $y -lt $h; $y++) {
            $c = $Src.GetPixel($x, $y)
            if ($c.A -lt 2) {
                $out.SetPixel($x, $y, [System.Drawing.Color]::Transparent)
                continue
            }
            # 亮度：偏白像素保留高饱和目标色
            $lum = ([int]$c.R * 0.35 + [int]$c.G * 0.45 + [int]$c.B * 0.20) / 255.0
            if ($lum -lt 0.02) { $lum = 0.02 }
            # 阴影区略压暗，亮区贴近目标色
            $f = [Math]::Pow($lum, 0.85)
            $nr = [Math]::Min(255, [int]($tr * $f + 8))
            $ng = [Math]::Min(255, [int]($tg * $f + 8))
            $nb = [Math]::Min(255, [int]($tb * $f + 8))
            $out.SetPixel($x, $y, [System.Drawing.Color]::FromArgb([int]$c.A, $nr, $ng, $nb))
        }
    }
    return $out
}

function Get-ColorizedIconPath([string]$SrcPath, [int[]]$Rgb, [string]$CacheKey) {
    if (-not $SrcPath -or -not (Test-Path -LiteralPath $SrcPath)) { return $null }
    $safe = ($CacheKey -replace '[^\w\-]+', '_')
    # v3：原版 TC 色表，强制重染
    $dir = Join-Path $IconCacheDir '_tinted_v3'
    $out = Join-Path $dir ($safe + '.png')
    try {
        if ((Test-Path -LiteralPath $out) -and
            (Get-Item -LiteralPath $out).LastWriteTime -ge (Get-Item -LiteralPath $SrcPath).LastWriteTime) {
            return $out
        }
    } catch { }
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $src = [System.Drawing.Bitmap]::FromFile($SrcPath)
        try {
            $bmp = New-ColorizedBitmap $src $Rgb
            try { $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
        } finally { $src.Dispose() }
        return $out
    } catch {
        Write-RecipeLog ("tint fail {0}: {1}" -f $CacheKey, $_.Exception.Message)
        return $SrcPath
    }
}

function Resolve-AspectIconPath([string]$SpiritType) {
    # thaumcraft:aer*5 或 malum:aerial*8 → 着色后的图标路径
    $raw = $SpiritType
    if ($raw -match '^(.+)\*(\d+)$') { $raw = $matches[1] }
    $ns = 'thaumcraft'
    $tail = $raw
    if ($raw -match '^([^:]+):([^:]+)$') { $ns = $matches[1]; $tail = $matches[2] }
    $cands = @(
        "${ns}:aspect_$tail",
        "thaumcraft:aspect_$tail",
        "${ns}:$tail",
        "thaumcraft:$tail"
    )
    $basePath = $null
    foreach ($c in $cands) {
        $p = Resolve-ItemIconPath $c
        if ($p) { $basePath = $p; break }
    }
    if (-not $basePath) {
        foreach ($c in @("thaumcraft:aspect_$tail", "thaumcraft:$tail")) {
            $p = Extract-IconFromCatalog $c
            if ($p) { $basePath = $p; break }
        }
    }
    if (-not $basePath) { return $null }
    # 不走 inv 裁切（32×32 要素图），直接染色
    $rgb = Get-AspectColorRgb $tail
    return (Get-ColorizedIconPath $basePath $rgb ("aspect_$tail"))
}

function Extract-KnownTextureEntry([string]$JarRelativeEntry) {
    # 直接按 jar 内路径抽贴图（用于 leather_*_overlay 等非物品 id）
    $entry = $JarRelativeEntry.Replace('\', '/')
    $safe = ($entry -replace '[^\w\.\-]+', '_')
    $out = Join-Path $IconCacheDir ('_raw\' + $safe)
    if (Test-Path -LiteralPath $out) { return $out }
    $jars = Get-TextureJarCandidates
    foreach ($jarPath in $jars) {
        try {
            $z = Get-OpenZip $jarPath
            $ent = $z.GetEntry($entry)
            if (-not $ent) { continue }
            $dir = Split-Path -Parent $out
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $src = $ent.Open()
            try {
                $fs = [IO.File]::Create($out)
                try { $src.CopyTo($fs) } finally { $fs.Close() }
            } finally { $src.Close() }
            return $out
        } catch { }
    }
    return $null
}

function Get-LeatherArmorIconPath([string]$ItemId) {
    # 皮革装备：底图可染色（默认棕）+ overlay 层；未染色时灰白很像铁装
    if ($ItemId -notmatch '^minecraft:(leather_(boots|helmet|chestplate|leggings|horse_armor))$') {
        return $null
    }
    $baseName = $matches[1]
    $cache = Join-Path $IconCacheDir ("minecraft\" + $baseName + ".leather.png")
    try {
        if ((Test-Path -LiteralPath $cache) -and (Get-Item -LiteralPath $cache).Length -gt 32) {
            return $cache
        }
    } catch { }

    $basePath = $null
    # 避免递归：直接走目录/解压
    $basePath = Extract-IconFromCatalog ("minecraft:" + $baseName)
    if (-not $basePath) {
        $basePath = Extract-KnownTextureEntry ("assets/minecraft/textures/item/" + $baseName + ".png")
    }
    if (-not $basePath) { return $null }

    $overlayPath = Extract-KnownTextureEntry ("assets/minecraft/textures/item/" + $baseName + "_overlay.png")
    # 原版默认皮革色 #A06540
    $tr = 0xA0; $tg = 0x65; $tb = 0x40
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $base = [System.Drawing.Bitmap]::FromFile($basePath)
        try {
            $w = $base.Width; $h = $base.Height
            $out = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            for ($x = 0; $x -lt $w; $x++) {
                for ($y = 0; $y -lt $h; $y++) {
                    $c = $base.GetPixel($x, $y)
                    if ($c.A -lt 2) {
                        $out.SetPixel($x, $y, [System.Drawing.Color]::Transparent)
                        continue
                    }
                    # 底图灰度 × 皮革棕
                    $f = ([int]$c.R * 0.4 + [int]$c.G * 0.4 + [int]$c.B * 0.2) / 255.0
                    if ($f -lt 0.05) { $f = 0.05 }
                    $nr = [Math]::Min(255, [int]($tr * $f + 6))
                    $ng = [Math]::Min(255, [int]($tg * $f + 4))
                    $nb = [Math]::Min(255, [int]($tb * $f + 2))
                    $out.SetPixel($x, $y, [System.Drawing.Color]::FromArgb([int]$c.A, $nr, $ng, $nb))
                }
            }
            if ($overlayPath -and (Test-Path -LiteralPath $overlayPath)) {
                $over = [System.Drawing.Bitmap]::FromFile($overlayPath)
                try {
                    $ow = [Math]::Min($w, $over.Width); $oh = [Math]::Min($h, $over.Height)
                    for ($x = 0; $x -lt $ow; $x++) {
                        for ($y = 0; $y -lt $oh; $y++) {
                            $o = $over.GetPixel($x, $y)
                            if ($o.A -lt 2) { continue }
                            $bg = $out.GetPixel($x, $y)
                            $a = $o.A / 255.0
                            $r = [int]($o.R * $a + $bg.R * (1 - $a))
                            $g2 = [int]($o.G * $a + $bg.G * (1 - $a))
                            $b = [int]($o.B * $a + $bg.B * (1 - $a))
                            $aa = [Math]::Max([int]$bg.A, [int]$o.A)
                            $out.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($aa, $r, $g2, $b))
                        }
                    }
                } finally { $over.Dispose() }
            }
            $dir = Split-Path -Parent $cache
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $out.Save($cache, [System.Drawing.Imaging.ImageFormat]::Png)
            $out.Dispose()
            return $cache
        } finally { $base.Dispose() }
    } catch {
        Write-RecipeLog ("leather composite fail {0}: {1}" -f $ItemId, $_.Exception.Message)
        return $basePath
    }
}

function Draw-ItemIcon($g, [string]$IdOrTag, $rect, $brushFallback, $font, $brushText, $sf, $idx) {
    # 皮革装备优先合成「染色底 + overlay」，否则像铁装
    $leatherPath = Get-LeatherArmorIconPath $IdOrTag
    $iconPath = if ($leatherPath) { $leatherPath } else { Resolve-ItemIconPath $IdOrTag }
    if ($iconPath -and -not $leatherPath) { $iconPath = Get-InventoryIconPath $iconPath $IdOrTag }
    # 风之碎片等：白晶贴图 × 元素色
    $tint = Get-ShardTintRgb $IdOrTag
    if ($tint -and $iconPath -and -not $leatherPath) {
        $iconPath = Get-ColorizedIconPath $iconPath $tint ("shard_" + ($IdOrTag -replace '[^\w]+', '_'))
    }
    if ($iconPath -and (Test-Path -LiteralPath $iconPath)) {
        try {
            $img = [System.Drawing.Image]::FromFile($iconPath)
            try {
                $oldInterp = $g.InterpolationMode
                $oldPix = $g.PixelOffsetMode
                if ($img.Width -le 32 -and $img.Height -le 32) {
                    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
                } else {
                    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                }
                $pad = if ($img.Width -ge 48) { 3 } else { 5 }
                $dw = $rect.Width - $pad * 2
                $dh = $rect.Height - $pad * 2
                $dx = $rect.X + $pad
                $dy = $rect.Y + $pad
                $g.DrawImage($img, $dx, $dy, $dw, $dh)
                $g.InterpolationMode = $oldInterp
                $g.PixelOffsetMode = $oldPix
                return $true
            } finally { $img.Dispose() }
        } catch {
            Write-RecipeLog ("draw icon fail {0}: {1}" -f $IdOrTag, $_.Exception.Message)
        }
    }
    $label = ''
    if ($IdOrTag) {
        $label = Short-Name (Item-Label $idx $IdOrTag) 4
    }
    if ($label) {
        $rf = New-Object System.Drawing.RectangleF ([float]$rect.X), ([float]$rect.Y), ([float]$rect.Width), ([float]$rect.Height)
        $g.DrawString($label, $font, $brushText, $rf, $sf)
    }
    return $false
}

function Draw-AspectIconRow($g, $spirits, [int]$ox, [int]$oy, $th, $fontSmall, $brushTitle, $brushAccent, $fontCount) {
    # 要素：直接画原版着色图标 + 数量，不加圆圈套壳
    if (-not $spirits -or @($spirits).Count -eq 0) { return 0 }
    $iconSz = 28
    $gap = 8
    $sx = $ox
    $drawn = 0
    $brushShadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 0, 0, 0))
    $brushNum = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 245, 200))
    $brushLabel = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 200, 185, 230))
    try {
        $g.DrawString('要素', $fontSmall, $brushLabel, [float]$sx, [float]($oy + 6))
        $sx += 32
        foreach ($sp in @($spirits)) {
            if ($drawn -ge 12) { break }
            $spType = $sp; $spCnt = 1
            if ($sp -match '^(.+)\*(\d+)$') { $spType = $matches[1]; $spCnt = [int]$matches[2] }
            $ip = Resolve-AspectIconPath $spType
            if ($ip -and (Test-Path -LiteralPath $ip)) {
                try {
                    $img = [System.Drawing.Image]::FromFile($ip)
                    try {
                        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $g.DrawImage($img, $sx, $oy, $iconSz, $iconSz)
                    } finally { $img.Dispose() }
                } catch {
                    $g.DrawString((Aspect-NameCn $spType), $fontSmall, $brushTitle, [float]$sx, [float]($oy + 8))
                }
            } else {
                $g.DrawString((Aspect-NameCn $spType), $fontSmall, $brushTitle, [float]$sx, [float]($oy + 8))
            }
            if ($spCnt -gt 0) {
                $num = [string]$spCnt
                $nx = $sx + $iconSz - 8
                $ny = $oy + $iconSz - 12
                $g.DrawString($num, $fontCount, $brushShadow, [float]($nx + 1), [float]($ny + 1))
                $g.DrawString($num, $fontCount, $brushNum, [float]$nx, [float]$ny)
            }
            $sx += $iconSz + $gap
            $drawn++
        }
    } finally {
        $brushShadow.Dispose(); $brushNum.Dispose(); $brushLabel.Dispose()
    }
    return ($iconSz + 4)
}

function Format-ShapedGrid($idx, $recipe) {
    $lines = New-Object System.Collections.Generic.List[string]
    $keyMap = Get-KeyMap $recipe
    $pattern = @($recipe.pattern)
    if ($pattern.Count -eq 0 -or $keyMap.Count -eq 0) {
        # 退化：材料列表
        $ings = @($recipe.ingredients)
        if ($ings.Count -gt 0) {
            $labels = $ings | ForEach-Object { Item-Label $idx $_ } | Select-Object -First 12
            $lines.Add('  材料：' + ($labels -join '、')) | Out-Null
        }
        return $lines
    }
    # 规范化 3 行
    $rows = @()
    foreach ($row in $pattern) {
        $s = [string]$row
        while ($s.Length -lt 3) { $s += ' ' }
        if ($s.Length -gt 3) { $s = $s.Substring(0, 3) }
        $rows += $s
    }
    while ($rows.Count -lt 3) { $rows += '   ' }

    $cellNames = @()
    for ($r = 0; $r -lt 3; $r++) {
        $rowNames = @()
        for ($c = 0; $c -lt 3; $c++) {
            $ch = $rows[$r][$c]
            if ($ch -eq ' ' -or $ch -eq [char]0) {
                $rowNames += '（空）'
            } else {
                $cs = [string]$ch
                $id = $null
                if ($keyMap.ContainsKey($cs)) { $id = $keyMap[$cs] }
                $rowNames += (Short-Name (Item-Label $idx $id) 5)
            }
        }
        $cellNames += , $rowNames
    }

    # 计算列宽
    $w0 = 4; $w1 = 4; $w2 = 4
    for ($r = 0; $r -lt 3; $r++) {
        $w0 = [Math]::Max($w0, $cellNames[$r][0].Length)
        $w1 = [Math]::Max($w1, $cellNames[$r][1].Length)
        $w2 = [Math]::Max($w2, $cellNames[$r][2].Length)
    }
    function Pad-Cell([string]$s, [int]$w) {
        $pad = $w - $s.Length
        if ($pad -le 0) { return $s }
        return $s + ('　' * 0) + (' ' * $pad)
    }

    $sep = '  ┌' + ('─' * ($w0 + 2)) + '┬' + ('─' * ($w1 + 2)) + '┬' + ('─' * ($w2 + 2)) + '┐'
    $mid = '  ├' + ('─' * ($w0 + 2)) + '┼' + ('─' * ($w1 + 2)) + '┼' + ('─' * ($w2 + 2)) + '┤'
    $bot = '  └' + ('─' * ($w0 + 2)) + '┴' + ('─' * ($w1 + 2)) + '┴' + ('─' * ($w2 + 2)) + '┘'
    $lines.Add('  【工作台】') | Out-Null
    $lines.Add($sep) | Out-Null
    for ($r = 0; $r -lt 3; $r++) {
        $a = Pad-Cell $cellNames[$r][0] $w0
        $b = Pad-Cell $cellNames[$r][1] $w1
        $c = Pad-Cell $cellNames[$r][2] $w2
        $lines.Add(('  │ {0} │ {1} │ {2} │' -f $a, $b, $c)) | Out-Null
        if ($r -lt 2) { $lines.Add($mid) | Out-Null }
    }
    $lines.Add($bot) | Out-Null
    return $lines
}

function Format-MachineRecipe($idx, $recipe) {
    $lines = New-Object System.Collections.Generic.List[string]
    $ings = @($recipe.ingredients)
    $inLabels = @($ings | ForEach-Object { Item-Label $idx $_ })
    $outName = Item-Label $idx ([string]$recipe.result)
    $cnt = 1
    try { $cnt = [int]$recipe.resultCount } catch { }
    $typeCn = Type-Cn ([string]$recipe.type)
    if ($inLabels.Count -eq 0) {
        $lines.Add(('  [{0}] → {1} ×{2}' -f $typeCn, $outName, $cnt)) | Out-Null
    } elseif ($inLabels.Count -eq 1) {
        $lines.Add(('  [{0}]' -f $typeCn)) | Out-Null
        $lines.Add(('    {0}' -f $inLabels[0])) | Out-Null
        $lines.Add(('      ↓')) | Out-Null
        $lines.Add(('    {0} ×{1}' -f $outName, $cnt)) | Out-Null
    } else {
        $lines.Add(('  [{0}]' -f $typeCn)) | Out-Null
        $lines.Add(('    投入：{0}' -f ($inLabels -join ' + '))) | Out-Null
        $lines.Add(('      ↓')) | Out-Null
        $lines.Add(('    产出：{0} ×{1}' -f $outName, $cnt)) | Out-Null
    }
    return $lines
}

function New-RecipePng($idx, $recipe, [string]$OutPath) {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [void](Ensure-TextureCatalog)

        $kind = Get-PanelKind $recipe
        $th = Get-PanelTheme $kind
        $keyMap = Get-KeyMap $recipe
        $pattern = @($recipe.pattern)
        $isShaped = ($pattern.Count -gt 0 -and $keyMap.Count -gt 0)
        $ings = @($recipe.ingredients)
        if ($null -eq $ings) { $ings = @() }

        $primary = $null
        try { if ($recipe.primaryInput) { $primary = [string]$recipe.primaryInput } } catch { }
        $extras = @()
        try { $extras = @($recipe.extraInputs) } catch { }
        $activation = $null
        try { if ($recipe.activationItem) { $activation = [string]$recipe.activationItem } } catch { }
        $spirits = @()
        try { $spirits = @($recipe.spirits) } catch { }
        if (-not $primary -and $ings.Count -gt 0) { $primary = [string]$ings[0] }

        $isCookFire = ($kind -in @('furnace', 'blast', 'smoker', 'campfire'))
        $isTcInfusion = ($kind -eq 'thaumcraft_infusion')
        $isMalumInfusion = ($kind -eq 'malum_infusion')
        $isInfusion = ($isTcInfusion -or $isMalumInfusion)
        $isRitual = ($kind -eq 'goety_ritual')
        $isCooking = ($kind -eq 'cooking')
        $isCrucible = ($kind -eq 'thaumcraft_crucible')
        $isRuneCraft = ($kind -in @('thaumcraft', 'thaumcraft_infusion', 'thaumcraft_crucible', 'malum', 'goety'))
        $isShapelessGrid = (-not $isShaped) -and (-not $isCookFire) -and (-not $isInfusion) -and (-not $isRitual) -and (-not $isCrucible) -and (
            $ings.Count -gt 0
        ) -and (
            ([string]$recipe.type -match 'crafting_shapeless|arcane_shapeless') -or ($ings.Count -le 9 -and [string]$recipe.type -match 'crafting|arcane') -or $isCooking
        )

        $cell = 52
        $gap = 4
        $pad = 16
        $titleH = 36
        $footerH = 28
        $arrowW = 40
        $hasAspects = ($spirits.Count -gt 0) -and ($kind -match 'thaumcraft')
        $aspectRowH = if ($hasAspects) { 38 } else { 0 }

        # 注魔环材料（仅跳过一次核心）
        $infExtra = New-Object System.Collections.Generic.List[string]
        if ($isInfusion) {
            $skippedCore = $false
            foreach ($ing in $ings) {
                $s = [string]$ing
                if (-not $skippedCore -and $primary -and $s -eq $primary) { $skippedCore = $true; continue }
                if ($s) { $infExtra.Add($s) | Out-Null }
            }
            if ($infExtra.Count -eq 0 -and $extras.Count -gt 0) {
                foreach ($e in $extras) { $infExtra.Add([string]$e) | Out-Null }
            }
        }
        $infN = $infExtra.Count
        # 注魔：环半径随材料数变化（非九宫格）
        $ringR = if ($infN -le 4) { 70 } elseif ($infN -le 6) { 82 } else { 94 }

        # 按面板类型定画布
        if ($isCookFire) {
            $w = [int]($pad * 2 + $cell * 2 + $arrowW + 80)
            $h = [int]($titleH + $pad + $cell * 3 + $footerH + 10)
        } elseif ($isTcInfusion) {
            $ringBox = [int](2 * $ringR + $cell + 16)
            $w = [int]($pad + $ringBox + $arrowW + $cell + $pad + 24)
            $h = [int]($titleH + 8 + $ringBox + $aspectRowH + $footerH + 20)
        } elseif ($isMalumInfusion) {
            $w = [int]($pad * 2 + $cell * 5 + $gap * 4 + $arrowW + $cell)
            $h = [int]($titleH + $pad + $cell * 3 + $gap * 2 + $footerH + 36 + $aspectRowH)
        } elseif ($isRitual) {
            $w = [int]($pad * 2 + $cell * 5 + $gap * 4 + 20)
            $h = [int]($titleH + $pad + $cell * 3 + $gap * 2 + $footerH + 24)
        } elseif ($isCrucible) {
            $w = [int]($pad * 2 + $cell * 3 + $arrowW + 40)
            $h = [int]($titleH + $pad + $cell * 2 + $footerH + $aspectRowH + 20)
        } else {
            $gridW = $cell * 3 + $gap * 2
            $w = [int]($pad + $gridW + $arrowW + $cell + $pad)
            if ($hasAspects) {
                $w = [Math]::Max($w, [int]($pad * 2 + 36 + 36 * [Math]::Min(8, $spirits.Count)))
            }
            $h = [int]($titleH + $pad + $cell * 3 + $gap * 2 + $footerH + $aspectRowH)
        }

        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        $panelBrush = New-BrushFromRgb $th.bg
        $g.FillRectangle($panelBrush, 0, 0, $w, $h)
        # 神秘面板外框
        if ($isRuneCraft -or $isInfusion -or $isRitual) {
            Draw-RuneBorder $g (New-Object System.Drawing.Rectangle 4, 4, ($w - 8), ($h - 8)) $th
        }

        $fontTitle = $null; $fontCell = $null; $fontCount = $null; $fontSmall = $null
        foreach ($fn in @('Microsoft YaHei UI', 'Microsoft YaHei', 'SimHei', 'SimSun', 'Segoe UI')) {
            try {
                $fontTitle = New-Object System.Drawing.Font($fn, 11.0, [System.Drawing.FontStyle]::Bold)
                $fontCell = New-Object System.Drawing.Font($fn, 8.0)
                $fontCount = New-Object System.Drawing.Font($fn, 10.0, [System.Drawing.FontStyle]::Bold)
                $fontSmall = New-Object System.Drawing.Font($fn, 7.5)
                if ($fontTitle) { break }
            } catch { $fontTitle = $null }
        }
        if (-not $fontTitle) {
            $fontTitle = New-Object System.Drawing.Font('Arial', 11.0, [System.Drawing.FontStyle]::Bold)
            $fontCell = New-Object System.Drawing.Font('Arial', 8.0)
            $fontCount = New-Object System.Drawing.Font('Arial', 10.0, [System.Drawing.FontStyle]::Bold)
            $fontSmall = New-Object System.Drawing.Font('Arial', 7.5)
        }

        $brushSlot = New-BrushFromRgb $th.slot
        $brushSlotEmpty = New-BrushFromRgb $th.slotEmpty
        $brushTitle = New-BrushFromRgb $th.title
        $brushText = New-BrushFromRgb $th.text
        $brushAccent = New-BrushFromRgb $th.accent
        $brushCount = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 80))
        $penHi = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(180, 255, 255, 255), 1)
        $penLo = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 0, 0, 0), 1)
        $penSlot = New-PenFromRgb $th.border 1
        if ($isRuneCraft -or $isInfusion -or $isRitual) {
            $penSlot = New-PenFromRgb $th.accent 1.5
        }

        $outId = [string]$recipe.result
        $outName = Item-Label $idx $outId
        $cnt = 1
        try { $cnt = [int]$recipe.resultCount } catch { }
        $typeCn = Type-Cn ([string]$recipe.type)
        # 面板中文名覆盖
        $panelTitle = switch ($kind) {
            'furnace' { '熔炉' }
            'blast' { '高炉' }
            'smoker' { '烟熏炉' }
            'campfire' { '营火' }
            'thaumcraft' { '奥术工作台' }
            'thaumcraft_infusion' { '注魔矩阵' }
            'thaumcraft_crucible' { '坩埚' }
            'malum' { '玛鲁姆' }
            'malum_infusion' { '灵魂注魔' }
            'goety' { '诡厄' }
            'goety_ritual' { '诡厄仪式' }
            'cooking' { '烹饪锅' }
            'cutting' { '切割' }
            default { $typeCn }
        }
        $titleStr = "$panelTitle  ·  $outName" + $(if ($cnt -gt 1) { " ×$cnt" } else { '' })
        $g.DrawString($titleStr, $fontTitle, $brushTitle, [float]$pad, 8.0)

        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center

        $script:__drawCell = $cell
        function Draw-ThemedSlot($gx, $gy, [string]$itemId, [bool]$rune) {
            $c = $script:__drawCell
            $rect = New-Object System.Drawing.Rectangle $gx, $gy, $c, $c
            $br = if ($itemId) { $brushSlot } else { $brushSlotEmpty }
            $g.FillRectangle($br, $rect)
            if ($rune) {
                Draw-RuneBorder $g $rect $th
            } else {
                $g.DrawLine($penLo, $gx, $gy, ($gx + $c - 1), $gy)
                $g.DrawLine($penLo, $gx, $gy, $gx, ($gy + $c - 1))
                $g.DrawLine($penHi, $gx, ($gy + $c - 1), ($gx + $c - 1), ($gy + $c - 1))
                $g.DrawLine($penHi, ($gx + $c - 1), $gy, ($gx + $c - 1), ($gy + $c - 1))
                $g.DrawRectangle($penSlot, $rect)
            }
            if ($itemId) {
                $drawn = $false
                # 精神类型特殊解析
                if ($itemId -match '^malum:(aerial|arcane|eldritch|earthen|wicked|sacred|infernal|aqueous|umbral)') {
                    foreach ($cand in (Resolve-SpiritItemId $itemId)) {
                        $p = Resolve-ItemIconPath $cand
                        if ($p) {
                            [void](Draw-ItemIcon $g $cand $rect $brushSlot $fontCell $brushText $sf $idx)
                            $drawn = $true
                            break
                        }
                    }
                }
                if (-not $drawn) {
                    [void](Draw-ItemIcon $g $itemId $rect $brushSlot $fontCell $brushText $sf $idx)
                }
            }
            return $rect
        }

        function Draw-CountBadge([int]$rx, [int]$ry, [int]$n) {
            if ($n -le 1) { return }
            $num = [string]$n
            $nx = $rx + $script:__drawCell - 18
            $ny = $ry + $script:__drawCell - 18
            $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(180, 0, 0, 0))
            $g.DrawString($num, $fontCount, $shadow, [float]($nx + 1), [float]($ny + 1))
            $g.DrawString($num, $fontCount, $brushCount, [float]$nx, [float]$ny)
            $shadow.Dispose()
        }

        $ox = $pad
        $oy = $titleH + 4
        $useRune = ($isRuneCraft -or $isInfusion -or $isRitual)

        if ($isCookFire) {
            # ===== 熔炉 / 烟熏 / 高炉 / 营火：输入 → 火焰 → 产出 =====
            $ix = $ox + 20
            $iy = $oy + 8
            [void](Draw-ThemedSlot $ix $iy $primary $false)
            $g.DrawString('原料', $fontSmall, $brushText, [float]$ix, [float]($iy + $cell + 2))

            # 火焰
            $fx = $ix + [int]($cell / 2)
            $fy = $iy + $cell + 28
            Draw-FlameIcon $g $fx $fy 22 $th
            $fuelLabel = switch ($kind) {
                'campfire' { '营火' }
                'blast' { '高温' }
                'smoker' { '烟熏' }
                default { '燃料' }
            }
            $g.DrawString($fuelLabel, $fontSmall, $brushAccent, [float]($ix + 8), [float]($fy + 18))

            # 箭头 + 产出
            $ax = $ix + $cell + 16
            $ay = $iy + [int]($cell / 2) - 8
            $g.DrawString('→', $fontTitle, $brushAccent, [float]$ax, [float]$ay)
            $rx = $ax + 36
            $ry = $iy
            [void](Draw-ThemedSlot $rx $ry $outId $false)
            Draw-CountBadge $rx $ry $cnt
            $g.DrawString('产物', $fontSmall, $brushText, [float]$rx, [float]($ry + $cell + 2))

            # 机型图标小贴（可选文字）
            $machineHint = switch ($kind) {
                'furnace' { 'JEI · 熔炉' }
                'blast' { 'JEI · 高炉' }
                'smoker' { 'JEI · 烟熏炉' }
                'campfire' { 'JEI · 营火' }
                default { '' }
            }
            $g.DrawString($machineHint, $fontSmall, $brushAccent, [float]$pad, [float]($h - 22))

        } elseif ($isCrucible) {
            # ===== 坩埚：催化剂 + 要素 =====
            $cx = $ox + $cell
            $cy = $oy + $cell
            [void](Draw-ThemedSlot $cx $cy $primary $true)
            $g.DrawString('催化剂', $fontSmall, $brushAccent, [float]$cx, [float]($cy + $cell + 2))
            $rx = $cx + $cell + $arrowW
            $ry = $cy
            $g.DrawString('→', $fontTitle, $brushAccent, [float]($cx + $cell + 8), [float]($cy + 12))
            [void](Draw-ThemedSlot $rx $ry $outId $true)
            Draw-CountBadge $rx $ry $cnt
            if ($spirits.Count -gt 0) {
                [void](Draw-AspectIconRow $g $spirits $ox ($cy + $cell + 18) $th $fontSmall $brushTitle $brushAccent $fontCount)
            }
            try {
                if ($recipe.meta.research) {
                    $g.DrawString(('研究：' + [string]$recipe.meta.research), $fontSmall, $brushAccent, [float]$ox, [float]($h - 40))
                }
            } catch { }

        } elseif ($isTcInfusion) {
            # ===== 神秘注魔：中心核心 + 基座环绕（非九宫格）+ 稳定性 + 要素 =====
            $ringBox = [int](2 * $ringR + $cell)
            $centerPx = $pad + [int]($ringBox / 2)
            $centerPy = $titleH + 10 + [int]($ringBox / 2)
            # 淡环引导线（注魔矩阵感）
            $penRing = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 180, 140, 255), 1.5)
            $g.DrawEllipse($penRing, ($centerPx - $ringR), ($centerPy - $ringR), (2 * $ringR), (2 * $ringR))
            $penRing.Dispose()

            # 外围基座：等角环绕，从正上方开始（贴合注魔祭坛摆法）
            $nPed = [Math]::Max(1, $infN)
            for ($i = 0; $i -lt $infN; $i++) {
                $ang = (-[double][Math]::PI / 2.0) + (2.0 * [Math]::PI * $i / [double]$nPed)
                $sx = [int]($centerPx + $ringR * [Math]::Cos($ang) - $cell / 2.0)
                $sy = [int]($centerPy + $ringR * [Math]::Sin($ang) - $cell / 2.0)
                [void](Draw-ThemedSlot $sx $sy ([string]$infExtra[$i]) $true)
            }
            # 中心：被注魔物
            $csx = [int]($centerPx - $cell / 2)
            $csy = [int]($centerPy - $cell / 2)
            [void](Draw-ThemedSlot $csx $csy $primary $true)
            $g.DrawString('核心', $fontSmall, $brushAccent, [float]$csx, [float]($csy + $cell + 1))

            # 稳定性
            $instab = $null
            try {
                $det = [string]$recipe.meta.detail
                if ($det -match 'instability\s*=\s*([0-9.]+)') { $instab = $matches[1] }
            } catch { }
            if ($instab) {
                $g.DrawString(('不稳定性  ' + $instab), $fontSmall, $brushTitle, [float]$pad, [float]($titleH + 2))
            }

            # 产出
            $rx = $pad + $ringBox + $arrowW
            $ry = [int]($centerPy - $cell / 2)
            $g.DrawString('→', $fontTitle, $brushAccent, [float]($rx - 30), [float]($ry + 14))
            [void](Draw-ThemedSlot $rx $ry $outId $true)
            Draw-CountBadge $rx $ry $cnt
            $g.DrawString('产物', $fontSmall, $brushAccent, [float]$rx, [float]($ry + $cell + 1))

            # 要素（无圆圈）
            if ($spirits.Count -gt 0) {
                $sy0 = $titleH + 10 + $ringBox + 6
                [void](Draw-AspectIconRow $g $spirits $pad $sy0 $th $fontSmall $brushTitle $brushAccent $fontCount)
            }

        } elseif ($isMalumInfusion) {
            # ===== 玛鲁姆注魔：中心主料 + 八向环绕 =====
            $cx = $ox + $cell * 2 + $gap
            $cy = $oy + $cell + $gap
            [void](Draw-ThemedSlot $cx $cy $primary $true)
            $g.DrawString('主料', $fontSmall, $brushAccent, [float]$cx, [float]($cy + $cell + 2))
            $offsets = @(
                @(0, -1), @(1, -1), @(1, 0), @(1, 1),
                @(0, 1), @(-1, 1), @(-1, 0), @(-1, -1)
            )
            for ($i = 0; $i -lt [Math]::Min(8, $infExtra.Count); $i++) {
                $dx = [int]$offsets[$i][0]; $dy = [int]$offsets[$i][1]
                $sx = $cx + $dx * ($cell + $gap)
                $sy = $cy + $dy * ($cell + $gap)
                [void](Draw-ThemedSlot $sx $sy ([string]$infExtra[$i]) $true)
            }
            $sy0 = $oy + $cell * 3 + $gap * 2 + 4
            $g.DrawString('精神:', $fontSmall, $brushAccent, [float]$ox, [float]$sy0)
            $sx = $ox + 36
            $si = 0
            foreach ($sp in $spirits) {
                if ($si -ge 8) { break }
                $spType = $sp; $spCnt = 1
                if ($sp -match '^(.+)\*(\d+)$') { $spType = $matches[1]; $spCnt = [int]$matches[2] }
                $iconId = $null
                foreach ($cand in (Resolve-SpiritItemId $spType)) {
                    if (Resolve-ItemIconPath $cand) { $iconId = $cand; break }
                }
                if ($iconId) {
                    $mini = 28
                    $oldCell = $script:__drawCell
                    $script:__drawCell = $mini
                    [void](Draw-ThemedSlot $sx $sy0 $iconId $true)
                    $script:__drawCell = $oldCell
                    $g.DrawString(("×$spCnt"), $fontSmall, $brushTitle, [float]($sx + 2), [float]($sy0 + $mini + 1))
                    $sx += $mini + 14
                }
                $si++
            }
            $rx = $w - $pad - $cell
            $ry = $cy
            $g.DrawString('→', $fontTitle, $brushAccent, [float]($rx - 28), [float]($ry + 12))
            [void](Draw-ThemedSlot $rx $ry $outId $true)
            Draw-CountBadge $rx $ry $cnt

        } elseif ($isRitual) {
            # ===== 诡厄仪式：中心激活物 + 周围祭品 + 产出 =====
            $cx = $ox + $cell * 2
            $cy = $oy + $cell
            $centerId = $activation
            if (-not $centerId) { $centerId = $primary }
            [void](Draw-ThemedSlot $cx $cy $centerId $true)
            $g.DrawString('祭品核', $fontSmall, $brushAccent, [float]($cx - 4), [float]($cy + $cell + 2))

            $ring = @($ings | Where-Object { $_ -ne $centerId } | Select-Object -First 8)
            $offsets = @(
                @(0, -1), @(1, -1), @(1, 0), @(1, 1),
                @(0, 1), @(-1, 1), @(-1, 0), @(-1, -1)
            )
            for ($i = 0; $i -lt [Math]::Min(8, $ring.Count); $i++) {
                $dx = [int]$offsets[$i][0]; $dy = [int]$offsets[$i][1]
                $sx = $cx + $dx * ($cell + $gap)
                $sy = $cy + $dy * ($cell + $gap)
                [void](Draw-ThemedSlot $sx $sy ([string]$ring[$i]) $true)
            }

            # meta
            $metaBits = @()
            try {
                if ($recipe.meta) {
                    if ($recipe.meta.soulCost) { $metaBits += ("灵魂×{0}" -f $recipe.meta.soulCost) }
                    if ($recipe.meta.duration) { $metaBits += ("{0}s" -f $recipe.meta.duration) }
                    if ($recipe.meta.craftType) { $metaBits += [string]$recipe.meta.craftType }
                }
            } catch { }
            if ($metaBits.Count -gt 0) {
                $g.DrawString(($metaBits -join ' · '), $fontSmall, $brushAccent, [float]$pad, [float]($h - 40))
            }

            if ($outId -and $outId -notmatch 'jei_dummy') {
                $rx = $w - $pad - $cell
                $ry = $cy
                $g.DrawString('→', $fontTitle, $brushAccent, [float]($rx - 28), [float]($ry + 12))
                [void](Draw-ThemedSlot $rx $ry $outId $true)
                Draw-CountBadge $rx $ry $cnt
            }

        } else {
            # ===== 工作台 3×3（含神秘/玛鲁姆/诡厄主题边框）=====
            $gridW = $cell * 3 + $gap * 2
            if ($isShaped) {
                $rows = @()
                foreach ($row in $pattern) {
                    $s = [string]$row
                    while ($s.Length -lt 3) { $s += ' ' }
                    if ($s.Length -gt 3) { $s = $s.Substring(0, 3) }
                    $rows += $s
                }
                while ($rows.Count -lt 3) { $rows += '   ' }
                for ($r = 0; $r -lt 3; $r++) {
                    for ($c = 0; $c -lt 3; $c++) {
                        $x = $ox + $c * ($cell + $gap)
                        $y = $oy + $r * ($cell + $gap)
                        $ch = $rows[$r].Substring($c, 1)
                        $id = $null
                        if ($ch -ne ' ' -and $keyMap.ContainsKey($ch)) { $id = [string]$keyMap[$ch] }
                        [void](Draw-ThemedSlot $x $y $id $useRune)
                    }
                }
            } elseif ($isShapelessGrid -or $isCooking) {
                $slots = @($ings | Select-Object -First 9)
                while ($slots.Count -lt 9) { $slots += $null }
                for ($i = 0; $i -lt 9; $i++) {
                    $r = [int][Math]::Floor($i / 3)
                    $c = $i % 3
                    $x = $ox + $c * ($cell + $gap)
                    $y = $oy + $r * ($cell + $gap)
                    $id = $null
                    if ($slots[$i]) { $id = [string]$slots[$i] }
                    [void](Draw-ThemedSlot $x $y $id $useRune)
                }
            } else {
                $inList = @($ings | Select-Object -First 6)
                $n = [Math]::Max(1, $inList.Count)
                $rowY = $oy + $cell
                for ($i = 0; $i -lt $n; $i++) {
                    $x = $ox + $i * ($cell + $gap)
                    if ($x + $cell -gt ($ox + $gridW)) { break }
                    [void](Draw-ThemedSlot $x $rowY ([string]$inList[$i]) $useRune)
                }
                $g.DrawString($typeCn, $fontCell, $brushTitle, [float]$ox, [float]($oy + 4))
            }

            $ax = $ox + $gridW + 8
            $ay = $oy + $cell + $gap + 12
            $g.DrawString('→', $fontTitle, $brushTitle, [float]$ax, [float]$ay)
            $rx = $ox + $gridW + $arrowW
            $ry = $oy + $cell + $gap
            [void](Draw-ThemedSlot $rx $ry $outId $useRune)
            Draw-CountBadge $rx $ry $cnt
        }

        $foot = '本服真实配方'
        if ($kind -eq 'thaumcraft') { $foot = '本服真实配方 · 奥术工作台' }
        elseif ($kind -eq 'thaumcraft_infusion') { $foot = '本服真实配方 · 注魔' }
        elseif ($kind -eq 'thaumcraft_crucible') { $foot = '本服真实配方 · 坩埚' }
        elseif ($kind -eq 'malum_infusion') { $foot = '本服真实配方 · 玛鲁姆注魔' }
        elseif ($kind -eq 'goety_ritual') { $foot = '本服真实配方 · 诡厄仪式' }
        elseif ($isCookFire) { $foot = "本服真实配方 · $panelTitle" }
        # 奥术要素：图标行（非文字）
        if ($kind -eq 'thaumcraft' -and $spirits.Count -gt 0) {
            $aspY = $h - 20 - $aspectRowH
            [void](Draw-AspectIconRow $g $spirits $pad $aspY $th $fontSmall $brushTitle $brushAccent $fontCount)
        }
        $g.DrawString($foot, $fontSmall, $brushTitle, [float]$pad, [float]($h - 18))

        $dir = Split-Path -Parent $OutPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        $fontTitle.Dispose(); $fontCell.Dispose(); $fontCount.Dispose(); $fontSmall.Dispose()
        $brushSlot.Dispose(); $brushSlotEmpty.Dispose(); $brushTitle.Dispose()
        $brushText.Dispose(); $brushAccent.Dispose(); $brushCount.Dispose(); $panelBrush.Dispose()
        $penHi.Dispose(); $penLo.Dispose(); $penSlot.Dispose(); $sf.Dispose()
        return $OutPath
    } catch {
        Write-RecipeLog ("png fail: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        return $null
    }
}

# ---- resolve query ----
$q = $Query.Trim()
if ([string]::IsNullOrWhiteSpace($q)) { throw '请提供关键词' }
$qCompact = ($q -replace '[之的的\s·・]', '')

$exactIds = New-Object System.Collections.Generic.List[string]
$fuzzyIds = New-Object System.Collections.Generic.List[string]

if ($builtinAlias.ContainsKey($q)) { $exactIds.Add([string]$builtinAlias[$q]) | Out-Null }
if ($builtinAlias.ContainsKey($qCompact)) { $exactIds.Add([string]$builtinAlias[$qCompact]) | Out-Null }
if ($q -match '^[a-z0-9_.]+:[a-z0-9_./]+$') { $exactIds.Add($q) | Out-Null }

function Add-FromZhMap([string]$Key) {
    if (-not $idx.zhToIds -or [string]::IsNullOrWhiteSpace($Key)) { return }
    $prop = $idx.zhToIds.PSObject.Properties[$Key]
    if (-not $prop) { return }
    foreach ($id in @($prop.Value)) {
        $exactIds.Add([string]$id) | Out-Null
    }
}
Add-FromZhMap $q
Add-FromZhMap $qCompact
# 子串命中 zhToIds 键（揭示 → 揭示之护目镜）
if ($exactIds.Count -eq 0 -and $idx.zhToIds -and $q.Length -ge 2) {
    foreach ($p in $idx.zhToIds.PSObject.Properties) {
        $k = [string]$p.Name
        if ($k.Contains($q) -or $k.Contains($qCompact) -or ($qCompact.Length -ge 2 -and ($k -replace '[之的]', '').Contains($qCompact))) {
            foreach ($id in @($p.Value)) { $exactIds.Add([string]$id) | Out-Null }
            if ($exactIds.Count -ge 20) { break }
        }
    }
}

if ($idx.items) {
    foreach ($p in $idx.items.PSObject.Properties) {
        $id = $p.Name
        $it = $p.Value
        $zh = [string]$it.zh
        $en = [string]$it.en
        if ($zh -eq $q -or $zh -eq $qCompact) { $exactIds.Add($id) | Out-Null; continue }
        $zhC = if ($zh) { $zh -replace '[之的\s]', '' } else { '' }
        if (($zh -and ($zh.Contains($q) -or $zhC.Contains($qCompact))) -or
            ($en -and $en.ToLowerInvariant().Contains($q.ToLowerInvariant())) -or
            ($id -and $id.Contains($q))) {
            $fuzzyIds.Add($id) | Out-Null
            if ($fuzzyIds.Count -ge 60) { break }
        }
    }
}

if ($exactIds.Count -gt 0) {
    $candidateIds = @($exactIds | Select-Object -Unique)
} else {
    $scored = foreach ($id in ($fuzzyIds | Select-Object -Unique)) {
        $zh = ''
        try { $zh = [string]$idx.items.$id.zh } catch { }
        $score = 0
        if ($zh -and $zh.Contains($q)) {
            $score = 1000 - $zh.Length
            if ($zh.StartsWith($q) -or $zh.EndsWith($q)) { $score += 50 }
        }
        if ($id -like 'minecraft:*') { $score += 80 }
        [pscustomobject]@{ id = $id; score = $score }
    }
    $candidateIds = @($scored | Sort-Object score -Descending | Select-Object -First 12 | ForEach-Object { $_.id })
}

if ($candidateIds.Count -eq 0) {
    $msg = "【配方】没找到「$q」`n试试中文名或 ID。索引约 $($idx.recipeCount) 条配方。"
    if ($QqSummary) { Write-Output $msg } else { Write-Host $msg }
    exit 1
}

$found = New-Object System.Collections.Generic.List[object]
foreach ($id in $candidateIds) {
    $list = $null
    if ($idx.byResult) {
        $prop = $idx.byResult.PSObject.Properties[$id]
        if ($prop) { $list = @($prop.Value) }
    }
    if (-not $list) { continue }
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($rid in $list) {
        $rec = $null
        foreach ($r in @($idx.recipes)) {
            if ([string]$r.id -eq [string]$rid) { $rec = $r; break }
        }
        if ($null -eq $rec) { continue }
        $ridStr = [string]$rec.id
        $score = 0
        if ($ridStr -like 'minecraft:*') { $score += 100 }
        $pk = ''
        try { $pk = [string]$rec.panel } catch { }
        if (-not $pk) { $pk = Get-PanelKind $rec }
        # 多样化：烧炼/注魔/仪式等专用面板优先露出
        switch -Regex ($pk) {
            'furnace|blast|smoker|campfire' { $score += 55 }
            'malum_infusion|goety_ritual' { $score += 50 }
            'thaumcraft|cooking' { $score += 40 }
            'malum|goety' { $score += 30 }
            default { $score += 15 }
        }
        if ([string]$rec.type -match 'crafting_shaped') { $score += 12 }
        elseif ([string]$rec.type -match 'crafting_shapeless') { $score += 8 }
        $recs.Add([pscustomobject]@{ score = $score; recipe = $rec; panel = $pk }) | Out-Null
    }
    # 同结果下尽量交错不同面板类型
    $usedPanel = @{}
    $ordered = @($recs | Sort-Object score -Descending)
    $picked = New-Object System.Collections.Generic.List[object]
    foreach ($row in $ordered) {
        $pk = [string]$row.panel
        $bonus = 0
        if ($pk -and -not $usedPanel.ContainsKey($pk)) { $bonus = 100 }
        $picked.Add([pscustomobject]@{ score = ($row.score + $bonus); recipe = $row.recipe; panel = $pk }) | Out-Null
    }
    foreach ($row in ($picked | Sort-Object score -Descending)) {
        $pk = [string]$row.panel
        if ($pk) { $usedPanel[$pk] = $true }
        $found.Add([pscustomobject]@{ resultId = $id; recipe = $row.recipe }) | Out-Null
        if ($found.Count -ge ($Max * 3)) { break }
    }
    if ($found.Count -ge ($Max * 3)) { break }
}

$imagePaths = New-Object System.Collections.Generic.List[string]
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('【本服配方】' + $q)

if ($found.Count -eq 0) {
    [void]$sb.AppendLine('找到物品，但没有「以它为产物」的配方（可能是掉落/交易/世界生成）：')
    foreach ($id in ($candidateIds | Select-Object -First 6)) {
        [void]$sb.AppendLine(' · ' + (Item-Label $idx $id))
    }
    $text = $sb.ToString().TrimEnd()
    if ($QqSummary) { Write-Output $text } else { Write-Host $text }
    exit 0
}

$shown = 0
$imgIdx = 0
$byRes = $found | Group-Object resultId
foreach ($g in $byRes) {
    $resultId = $g.Name
    $outLabel = Item-Label $idx $resultId
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('▸ 做出：' + $outLabel)
    foreach ($row in @($g.Group | Select-Object -First 2)) {
        $r = $row.recipe
        $shown++
        if ($shown -gt $Max) { break }
        $typeCn = Type-Cn ([string]$r.type)
        $cnt = 1
        try { $cnt = [int]$r.resultCount } catch { }
        $isShaped = ($r.pattern -and @($r.pattern).Count -gt 0 -and $r.key)
        if ($isShaped) {
            [void]$sb.AppendLine(('  {0} · 得到 {1}×{2}' -f $typeCn, $outLabel, $cnt))
            foreach ($line in (Format-ShapedGrid $idx $r)) { [void]$sb.AppendLine($line) }
        } else {
            foreach ($line in (Format-MachineRecipe $idx $r)) { [void]$sb.AppendLine($line) }
        }

        if (-not $NoImage) {
            try {
                New-Item -ItemType Directory -Path $ImgDir -Force | Out-Null
                $imgIdx++
                $safe = ($q -replace '[^\w\u4e00-\u9fff\-]+', '_')
                if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'q' }
                if ($safe.Length -gt 16) { $safe = $safe.Substring(0, 16) }
                $imgPath = Join-Path $ImgDir ("recipe-{0}-{1}.png" -f $safe, $imgIdx)
                $p = New-RecipePng $idx $r $imgPath
                if ($p -and (Test-Path -LiteralPath $p)) {
                    $imagePaths.Add(([IO.Path]::GetFullPath($p))) | Out-Null
                }
            } catch {
                try { Add-Content (Join-Path $Root 'logs\recipe-index.log') ("png outer: " + $_.Exception.Message) -Encoding UTF8 } catch { }
            }
        }
    }
    if ($shown -gt $Max) { break }
}

if ($found.Count -gt $Max) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(("（显示前 {0} 种，共约 {1} 条）" -f $Max, $found.Count))
}
[void]$sb.AppendLine('—— 本服真实配方 · 换模组后需重建索引')

$text = $sb.ToString().TrimEnd()
Close-OpenZips
if ($QqSummary) {
    Write-Output $text
    foreach ($ip in $imagePaths) {
        Write-Output ('IMAGE:' + $ip)
    }
} elseif (-not $Quiet) {
    Write-Host $text
    if ($imagePaths.Count -gt 0) {
        Write-Host ''
        Write-Host '图片：' -ForegroundColor Cyan
        $imagePaths | ForEach-Object { Write-Host $_ }
    }
}
exit 0
