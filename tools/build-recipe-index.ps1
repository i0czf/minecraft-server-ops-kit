param(
    [switch]$Quiet,
    [switch]$Force
)

# 扫描 mods jar + datapacks，建立本服物品中文名与配方索引（只读，不改服）。
# 输出：tmp/recipe-index/index.json 与 meta.json

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $Root 'tmp\recipe-index'
$IndexPath = Join-Path $OutDir 'index.json'
$MetaPath = Join-Path $OutDir 'meta.json'
$NamesPath = Join-Path $OutDir 'item-names.tsv'
$LogPath = Join-Path $Root 'logs\recipe-index.log'

function Write-IdxLog([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    try {
        $d = Split-Path -Parent $LogPath
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content $LogPath $line -Encoding UTF8
    } catch { }
    if (-not $Quiet) { try { Write-Host $line } catch { } }
}

function Read-ZipEntryText($entry) {
    $sr = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8, $true)
    try { return $sr.ReadToEnd() } finally { $sr.Close() }
}

function Add-LangMap([hashtable]$Map, $obj, [string]$NsHint) {
    if ($null -eq $obj) { return }
    foreach ($p in $obj.PSObject.Properties) {
        $k = [string]$p.Name
        $v = [string]$p.Value
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        # item.modid.name / block.modid.name / item.modid.path.with.dots
        if ($k -match '^(item|block|fluid)\.([^.]+)\.(.+)$') {
            $kind = $matches[1]
            $ns = $matches[2]
            $path = $matches[3] -replace '\.', '/'
            # MC id usually uses _ not nested path from lang dots: item.fd.cabbage_seeds -> farmersdelight:cabbage_seeds
            # lang uses dots for path segments sometimes; most are single segment with underscores
            $path2 = $matches[3] -replace '\.', '_'
            $id = "${ns}:${path2}"
            if (-not $Map.ContainsKey($id)) {
                $Map[$id] = [ordered]@{ id = $id; zh = ''; en = ''; kind = $kind }
            }
            # caller sets field
            return @{ id = $id; value = $v; kind = $kind }
        }
    }
    return $null
}

function Set-Lang([hashtable]$Map, [string]$Id, [string]$Field, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Value)) { return }
    if (-not $Map.ContainsKey($Id)) {
        $Map[$Id] = [ordered]@{ id = $Id; zh = ''; en = ''; kind = 'item' }
    }
    $Map[$Id][$Field] = $Value
}

function Parse-LangObject($obj, [hashtable]$Map, [string]$LangField) {
    if ($null -eq $obj) { return 0 }
    $n = 0
    foreach ($p in $obj.PSObject.Properties) {
        $k = [string]$p.Name
        $v = [string]$p.Value
        if ($k -match '^(item|block|fluid)\.([^.]+)\.(.+)$') {
            $ns = $matches[2]
            $path = $matches[3] -replace '\.', '_'
            $id = "${ns}:${path}"
            Set-Lang $Map $id $LangField $v
            $n++
        }
    }
    return $n
}

function Get-IngredientIds($node) {
    $list = New-Object System.Collections.Generic.List[string]
    if ($null -eq $node) { return @() }
    if ($node -is [string]) {
        if ($node -match '^[a-z0-9_.]+:[a-z0-9_./]+$') { $list.Add($node) | Out-Null }
        return $list
    }
    if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string]) -and $node.GetType().Name -ne 'PSCustomObject') {
        foreach ($x in $node) {
            foreach ($i in (Get-IngredientIds $x)) { $list.Add($i) | Out-Null }
        }
        return $list
    }
    # single object
    if ($node.item) { $list.Add([string]$node.item) | Out-Null }
    elseif ($node.id -and -not $node.type) { $list.Add([string]$node.id) | Out-Null }
    elseif ($node.tag) { $list.Add('#' + ([string]$node.tag)) | Out-Null }
    elseif ($node.PSObject.Properties['id'] -and $node.type -match 'item') {
        # skip recipe type id collisions
    }
    return $list
}

function Add-CountedIngredient([System.Collections.Generic.List[string]]$List, $node) {
    if ($null -eq $node) { return }
    $ids = @(Get-IngredientIds $node)
    $count = 1
    try {
        if ($node.count) { $count = [int]$node.count }
    } catch { $count = 1 }
    if ($count -lt 1) { $count = 1 }
    if ($ids.Count -eq 0) { return }
    # 重复 count 次以便九宫格/锅槽展示份数
    for ($i = 0; $i -lt $count; $i++) {
        $List.Add([string]$ids[0]) | Out-Null
    }
}

function Parse-RecipeJson([string]$Text, [string]$RecipeId) {
    try { $j = $Text | ConvertFrom-Json } catch { return $null }
    $type = [string]$j.type
    if ([string]::IsNullOrWhiteSpace($type)) { return $null }
    # skip advancements mis-hit
    if ($type -match 'advancement|predicate') { return $null }

    $resultId = $null
    $resultCount = 1
    if ($j.result) {
        if ($j.result -is [string]) { $resultId = [string]$j.result }
        else {
            if ($j.result.id) { $resultId = [string]$j.result.id }
            elseif ($j.result.item) { $resultId = [string]$j.result.item }
            if ($j.result.count) { $resultCount = [int]$j.result.count }
        }
    } elseif ($j.results -and $j.results.Count -gt 0) {
        $r0 = $j.results[0]
        if ($r0.id) { $resultId = [string]$r0.id }
        elseif ($r0.item) { $resultId = [string]$r0.item }
        if ($r0.count) { try { $resultCount = [int]$r0.count } catch { } }
    }

    $ings = New-Object System.Collections.Generic.List[string]
    $primary = $null
    $extras = New-Object System.Collections.Generic.List[string]
    $activation = $null
    $spirits = New-Object System.Collections.Generic.List[string]
    $meta = [ordered]@{}

    if ($j.ingredients) {
        foreach ($x in @($j.ingredients)) { Add-CountedIngredient $ings $x }
    }
    if ($j.ingredient) { Add-CountedIngredient $ings $j.ingredient }
    if ($j.key) {
        foreach ($kp in $j.key.PSObject.Properties) {
            foreach ($i in (Get-IngredientIds $kp.Value)) { if ($i) { $ings.Add($i) | Out-Null } }
        }
    }
    # cooking pot / nested body
    if ($j.recipe_body -and $j.recipe_body.ingredients) {
        foreach ($x in @($j.recipe_body.ingredients)) { Add-CountedIngredient $ings $x }
    }
    # malum spirit_infusion 等：input + extraInputs
    if ($j.input) {
        $ids = @(Get-IngredientIds $j.input)
        if ($ids.Count -gt 0) {
            $primary = [string]$ids[0]
            $c = 1
            try { if ($j.input.count) { $c = [int]$j.input.count } } catch { }
            for ($i = 0; $i -lt [Math]::Max(1, $c); $i++) { $ings.Add($primary) | Out-Null }
        }
    }
    if ($j.extraInputs) {
        foreach ($x in @($j.extraInputs)) {
            $ids = @(Get-IngredientIds $x)
            $c = 1
            try { if ($x.count) { $c = [int]$x.count } } catch { }
            if ($ids.Count -gt 0) {
                for ($i = 0; $i -lt [Math]::Max(1, $c); $i++) {
                    $extras.Add([string]$ids[0]) | Out-Null
                    $ings.Add([string]$ids[0]) | Out-Null
                }
            }
        }
    }
    # goety ritual
    if ($j.activation_item) {
        $ids = @(Get-IngredientIds $j.activation_item)
        if ($ids.Count -gt 0) {
            $activation = [string]$ids[0]
            if (-not $primary) { $primary = $activation }
        }
    }
    # malum spirits: { type: "malum:aerial", count: 8 }
    if ($j.spirits) {
        foreach ($sp in @($j.spirits)) {
            $st = $null
            try { $st = [string]$sp.type } catch { }
            if (-not $st) { try { $st = [string]$sp.id } catch { } }
            if (-not $st) { continue }
            $sc = 1
            try { if ($sp.count) { $sc = [int]$sp.count } } catch { }
            $spirits.Add(("{0}*{1}" -f $st, $sc)) | Out-Null
        }
    }
    # 杂项 meta（展示用）
    foreach ($k in @('soulCost', 'duration', 'experience', 'cookingtime', 'cookingtime', 'craftType', 'ritual_type')) {
        try {
            if ($j.PSObject.Properties[$k] -and $null -ne $j.$k) { $meta[$k] = [string]$j.$k }
        } catch { }
    }
    if ($j.PSObject.Properties['cookingtime'] -and $j.cookingtime) { $meta['cookingtime'] = [string]$j.cookingtime }

    $pattern = @()
    if ($j.pattern) { $pattern = @($j.pattern | ForEach-Object { [string]$_ }) }

    # 有序合成：保留 key 字符 -> 物品，便于画出工作台格子
    $keyMap = @{}
    if ($j.key) {
        foreach ($kp in $j.key.PSObject.Properties) {
            $ch = [string]$kp.Name
            $ids = @(Get-IngredientIds $kp.Value)
            if ($ids.Count -gt 0) { $keyMap[$ch] = [string]$ids[0] }
        }
    }

    # 烧炼类主料
    if (-not $primary -and $ings.Count -gt 0) {
        $primary = [string]$ings[0]
    }

    # 面板提示：供查询端选择 JEI 风格皮肤
    $panel = 'craft'
    if ($type -match 'smelting$') { $panel = 'furnace' }
    elseif ($type -match 'blasting') { $panel = 'blast' }
    elseif ($type -match 'smoking') { $panel = 'smoker' }
    elseif ($type -match 'campfire') { $panel = 'campfire' }
    elseif ($type -match 'spirit_infusion|soul_binding|spirit_focusing') { $panel = 'malum_infusion' }
    elseif ($type -match 'goety:ritual|cursed_infuser') { $panel = 'goety_ritual' }
    elseif ($type -match 'cooking|stockpot|:pot$|flex_pot') { $panel = 'cooking' }
    elseif ($type -match 'cutting|chopping|stonecutting') { $panel = 'cutting' }
    elseif ($type -match 'smithing') { $panel = 'smithing' }
    elseif ($type -match 'thaumcraft|infusion|arcane') { $panel = 'thaumcraft' }
    elseif ($RecipeId -like 'thaumcraft:*' -or ($resultId -and $resultId -like 'thaumcraft:*')) { $panel = 'thaumcraft' }
    elseif ($RecipeId -like 'malum:*' -or ($resultId -and $resultId -like 'malum:*')) {
        if ($type -match 'crafting') { $panel = 'malum' } else { $panel = 'malum' }
    }
    elseif ($RecipeId -like 'goety:*' -or ($resultId -and $resultId -like 'goety:*')) { $panel = 'goety' }
    elseif ($type -match 'crafting_shaped|crafting_shapeless') { $panel = 'craft' }
    else { $panel = 'machine' }

    return [ordered]@{
        id             = $RecipeId
        type           = $type
        result         = $resultId
        resultCount    = $resultCount
        ingredients    = @($ings)
        pattern        = $pattern
        key            = $keyMap
        panel          = $panel
        primaryInput   = $primary
        extraInputs    = @($extras)
        activationItem = $activation
        spirits        = @($spirits)
        meta           = $meta
    }
}

function RecipeId-FromEntry([string]$FullName) {
    # data/{ns}/recipe/{path}.json or recipes/
    if ($FullName -match 'data/([^/]+)/recipes?/(.+)\.json$') {
        $ns = $matches[1]
        $path = $matches[2] -replace '\\', '/'
        return "${ns}:${path}"
    }
    return $null
}

function Parse-ItemCountToken([string]$Tok) {
    # "thaumcraft:goggles_revealing*1" | "empty" | "[a*1|b*1]"
    if ([string]::IsNullOrWhiteSpace($Tok) -or $Tok -eq 'empty') {
        return @{ id = $null; count = 0 }
    }
    $t = $Tok.Trim()
    if ($t.StartsWith('[') -and $t.EndsWith(']')) {
        $inner = $t.Substring(1, $t.Length - 2)
        $first = ($inner -split '\|')[0]
        return Parse-ItemCountToken $first
    }
    $count = 1
    $id = $t
    if ($t -match '^(.+)\*(\d+)$') {
        $id = $matches[1]
        $count = [int]$matches[2]
    }
    if ($id -eq 'empty' -or $id -eq 'dynamic') {
        return @{ id = $null; count = 0 }
    }
    return @{ id = $id; count = $count }
}

function Parse-ParityRow($row, [string]$NsHint) {
    if ($null -eq $row) { return $null }
    $family = [string]$row.family
    if ([string]::IsNullOrWhiteSpace($family)) { return $null }
    if ($family -match 'dynamic' -and [string]$row.output -eq 'dynamic') { return $null }

    $outTok = Parse-ItemCountToken ([string]$row.output)
    if (-not $outTok.id) { return $null }

    $ings = New-Object System.Collections.Generic.List[string]
    $keyMap = @{}
    $pattern = @()
    $primary = $null
    $extras = New-Object System.Collections.Generic.List[string]
    $spirits = New-Object System.Collections.Generic.List[string]
    $meta = [ordered]@{}

    if ($row.research) { $meta['research'] = [string]$row.research }
    if ($row.costs) { $meta['costs'] = [string]$row.costs }
    if ($row.detail) { $meta['detail'] = [string]$row.detail }

    # costs "aer:5,aqua:5" → 要素列表
    if ($row.costs) {
        foreach ($part in (([string]$row.costs) -split ',')) {
            if ($part -match '^([a-zA-Z_]+):(\d+)') {
                $spirits.Add(("{0}:{1}*{2}" -f $NsHint, $matches[1].ToLowerInvariant(), $matches[2])) | Out-Null
            }
        }
    }

    $detail = [string]$row.detail
    if ($detail -match 'central=([^;]+)') {
        $cTok = Parse-ItemCountToken $matches[1]
        if ($cTok.id) {
            $primary = $cTok.id
            $ings.Add($cTok.id) | Out-Null
        }
    }
    if ($detail -match 'catalyst=([^;]+)') {
        $cTok = Parse-ItemCountToken $matches[1]
        if ($cTok.id) {
            if (-not $primary) { $primary = $cTok.id }
            $ings.Add($cTok.id) | Out-Null
        }
    }

    $ingArr = @($row.ingredients)
    $slots = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $ingArr) {
        $tok = Parse-ItemCountToken ([string]$raw)
        if ($tok.id) {
            for ($i = 0; $i -lt [Math]::Max(1, $tok.count); $i++) {
                $ings.Add($tok.id) | Out-Null
            }
            $slots.Add($tok.id) | Out-Null
            if (-not $primary) { $primary = $tok.id }
            else { $extras.Add($tok.id) | Out-Null }
        } else {
            $slots.Add('') | Out-Null
        }
    }

    # 3x3 有序
    if ($family -match 'arcane_shaped|shaped' -and $slots.Count -ge 9) {
        $chars = @('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I')
        $usedCh = @{}
        $patRows = @('', '', '')
        for ($i = 0; $i -lt 9; $i++) {
            $id = $slots[$i]
            $r = [int][Math]::Floor($i / 3)
            if ([string]::IsNullOrWhiteSpace($id)) {
                $patRows[$r] += ' '
            } else {
                if (-not $usedCh.ContainsKey($id)) {
                    $ch = $chars[$usedCh.Count]
                    if ($usedCh.Count -ge $chars.Count) { $ch = [char](65 + ($usedCh.Count % 26)) }
                    $usedCh[$id] = [string]$ch
                    $keyMap[[string]$ch] = $id
                }
                $patRows[$r] += $usedCh[$id]
            }
        }
        $pattern = @($patRows)
    }

    $type = "thaumcraft:$family"
    $panel = 'thaumcraft'
    if ($family -match 'infusion') { $panel = 'thaumcraft_infusion'; $type = "thaumcraft:$family" }
    elseif ($family -match 'crucible') { $panel = 'thaumcraft_crucible'; $type = "thaumcraft:crucible" }
    elseif ($family -match 'arcane') { $panel = 'thaumcraft'; $type = "thaumcraft:$family" }

    $rid = "thaumcraft:parity/$family/$($row.registryIndex)"
    if ($row.research) { $rid = "thaumcraft:parity/$([string]$row.research)" }

    return [ordered]@{
        id             = $rid
        type           = $type
        result         = $outTok.id
        resultCount    = [Math]::Max(1, [int]$outTok.count)
        ingredients    = @($ings)
        pattern        = $pattern
        key            = $keyMap
        panel          = $panel
        primaryInput   = $primary
        extraInputs    = @($extras)
        activationItem = $null
        spirits        = @($spirits)
        meta           = $meta
    }
}

function Import-ParityManifest([string]$Text, [string]$NsHint, $recipesList, [hashtable]$byResultMap) {
    $n = 0
    try { $arr = $Text | ConvertFrom-Json } catch { return 0 }
    if ($null -eq $arr) { return 0 }
    foreach ($row in @($arr)) {
        try {
            $parsed = Parse-ParityRow $row $NsHint
            if ($null -eq $parsed) { continue }
            # 同 research 可能重复，用 fingerprint 去重 id
            if ($row.fingerprint) {
                $parsed.id = "thaumcraft:parity/$($row.family)/$($row.fingerprint.Substring(0, [Math]::Min(12, $row.fingerprint.Length)))"
            }
            $recipesList.Add($parsed) | Out-Null
            $n++
            if ($parsed.result) {
                $rk = [string]$parsed.result
                if (-not $byResultMap.ContainsKey($rk)) {
                    $byResultMap[$rk] = New-Object System.Collections.Generic.List[string]
                }
                $byResultMap[$rk].Add([string]$parsed.id) | Out-Null
            }
        } catch { }
    }
    return $n
}

function Import-VanillaZhFromAssets([hashtable]$Map) {
    # 从客户端 assets 对象读 minecraft/lang/zh_cn.json
    $indexCandidates = @(
        (Join-Path $Root '客户端\.minecraft\assets\indexes'),
        (Join-Path $env:APPDATA '.minecraft\assets\indexes')
    )
    $hash = $null
    foreach ($idxDir in $indexCandidates) {
        if (-not (Test-Path $idxDir)) { continue }
        $idxFile = Get-ChildItem $idxDir -Filter '*.json' -File -EA SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 3
        foreach ($f in $idxFile) {
            try {
                $raw = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
                if ($raw -match '"minecraft/lang/zh_cn\.json"\s*:\s*\{[^}]*"hash"\s*:\s*"([a-f0-9]+)"') {
                    $hash = $matches[1]
                    break
                }
                # 宽松：逐属性
                $j = $raw | ConvertFrom-Json
                $prop = $j.objects.PSObject.Properties['minecraft/lang/zh_cn.json']
                if ($prop -and $prop.Value.hash) { $hash = [string]$prop.Value.hash; break }
            } catch { }
        }
        if ($hash) { break }
    }
    if (-not $hash) {
        Write-IdxLog 'vanilla zh_cn asset hash not found'
        return 0
    }
    $objPaths = @(
        (Join-Path $Root ("客户端\.minecraft\assets\objects\{0}\{1}" -f $hash.Substring(0, 2), $hash)),
        (Join-Path $env:APPDATA (".minecraft\assets\objects\{0}\{1}" -f $hash.Substring(0, 2), $hash))
    )
    $path = $objPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $path) {
        Write-IdxLog "vanilla zh_cn object missing hash=$hash"
        return 0
    }
    try {
        $obj = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $n = Parse-LangObject $obj $Map 'zh'
        Write-IdxLog ("vanilla zh_cn loaded entries=$n from $path")
        return $n
    } catch {
        Write-IdxLog ("vanilla zh_cn parse fail: " + $_.Exception.Message)
        return 0
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if ((Test-Path $IndexPath) -and -not $Force) {
    $ageH = ((Get-Date) - (Get-Item $IndexPath).LastWriteTime).TotalHours
    if ($ageH -lt 24) {
        Write-IdxLog "index exists age=${ageH}h; use -Force to rebuild"
        if (-not $Quiet) { Write-Host "索引已存在（$([math]::Round($ageH,1)) 小时前），跳过。需要重建请加 -Force" }
        exit 0
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$items = @{}  # id -> {id,zh,en,kind}
$recipes = New-Object System.Collections.Generic.List[object]
$byResult = @{}  # resultId -> list of recipe ids
$langZhCount = 0
$langEnCount = 0
$recipeCount = 0
$jarCount = 0

$modJars = @(Get-ChildItem (Join-Path $Root 'mods') -File -Filter '*.jar' -EA SilentlyContinue)
# 原版数据包在 server jar 内
$vanillaJars = @(Get-ChildItem (Join-Path $Root 'libraries\net\minecraft\server') -Recurse -File -Filter 'server-*.jar' -EA SilentlyContinue |
        Where-Object { $_.Name -match '^server-1\.' -and $_.Length -gt 1MB } |
        Sort-Object Length -Descending | Select-Object -First 2)
$allJars = @($modJars + $vanillaJars)
Write-IdxLog ("scanning jars mods=$($modJars.Count) vanilla=$($vanillaJars.Count)")

foreach ($jar in $allJars) {
    $jarCount++
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
    } catch {
        Write-IdxLog ("skip jar " + $jar.Name + " " + $_.Exception.Message)
        continue
    }
    try {
        foreach ($e in $z.Entries) {
            $name = $e.FullName.Replace('\', '/')
            if ($name -match 'assets/[^/]+/lang/zh_cn\.json$') {
                try {
                    $obj = (Read-ZipEntryText $e) | ConvertFrom-Json
                    $langZhCount += Parse-LangObject $obj $items 'zh'
                } catch { }
            } elseif ($name -match 'assets/[^/]+/lang/en_us\.json$') {
                try {
                    $obj = (Read-ZipEntryText $e) | ConvertFrom-Json
                    $langEnCount += Parse-LangObject $obj $items 'en'
                } catch { }
            } elseif ($name -match 'data/[^/]+/recipe_parity/runtime_manifest\.json$') {
                try {
                    $nsHint = 'thaumcraft'
                    if ($name -match 'data/([^/]+)/') { $nsHint = $matches[1] }
                    $added = Import-ParityManifest (Read-ZipEntryText $e) $nsHint $recipes $byResult
                    $recipeCount += $added
                    Write-IdxLog ("parity manifest $nsHint +$added")
                } catch {
                    Write-IdxLog ("parity fail: " + $_.Exception.Message)
                }
            } elseif ($name -match 'data/[^/]+/recipes?/.+\.json$' -and $name -notmatch '/advancement/') {
                $rid = RecipeId-FromEntry $name
                if (-not $rid) { continue }
                try {
                    $parsed = Parse-RecipeJson (Read-ZipEntryText $e) $rid
                    if ($null -eq $parsed) { continue }
                    if (-not $parsed.result -and $parsed.ingredients.Count -eq 0) { continue }
                    $recipes.Add($parsed) | Out-Null
                    $recipeCount++
                    if ($parsed.result) {
                        $rk = [string]$parsed.result
                        if (-not $byResult.ContainsKey($rk)) { $byResult[$rk] = New-Object System.Collections.Generic.List[string] }
                        $byResult[$rk].Add($rid) | Out-Null
                    }
                } catch { }
            }
        }
    } finally { $z.Dispose() }
    if (($jarCount % 10) -eq 0) { Write-IdxLog ("progress jars=$jarCount recipes=$recipeCount") }
}

# 汉化资源包（原版中文不在 server jar，多在客户端/玩家包 resourcepacks）
$langPacks = @()
$langPacks += @(Get-ChildItem (Join-Path $Root 'modpack-public\hmcl-serverpack\resourcepacks') -Filter '*.zip' -File -EA SilentlyContinue)
$clientRp = Join-Path $Root '客户端'
if (Test-Path $clientRp) {
    $langPacks += @(Get-ChildItem $clientRp -Recurse -Filter '*Language*.zip' -File -EA SilentlyContinue | Select-Object -First 3)
    $langPacks += @(Get-ChildItem $clientRp -Recurse -Filter '*lang*zh*' -File -EA SilentlyContinue | Select-Object -First 3)
}
$langPacks = @($langPacks | Where-Object { $_ } | Sort-Object FullName -Unique)
Write-IdxLog ("scanning lang packs=" + $langPacks.Count)
foreach ($pack in $langPacks) {
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($pack.FullName)
    } catch { continue }
    try {
        foreach ($e in $z.Entries) {
            $name = $e.FullName.Replace('\', '/')
            if ($name -notmatch 'lang/zh_cn\.json$') { continue }
            try {
                $obj = (Read-ZipEntryText $e) | ConvertFrom-Json
                $langZhCount += Parse-LangObject $obj $items 'zh'
            } catch { }
        }
    } finally { $z.Dispose() }
}

# datapacks folders
$dpRoots = @(
    (Join-Path $Root 'world\datapacks'),
    (Join-Path $Root 'moonlight-global-datapacks')
)
foreach ($dpRoot in $dpRoots) {
    if (-not (Test-Path $dpRoot)) { continue }
    Get-ChildItem $dpRoot -Recurse -File -Filter '*.json' -EA SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel -notmatch 'data/[^/]+/recipes?/.+\.json$') { return }
        if ($rel -match 'advancement') { return }
        $rid = RecipeId-FromEntry $rel
        if (-not $rid) { return }
        try {
            $parsed = Parse-RecipeJson ([IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)) $rid
            if ($null -eq $parsed -or -not $parsed.result) { return }
            $recipes.Add($parsed) | Out-Null
            $recipeCount++
            $rk = [string]$parsed.result
            if (-not $byResult.ContainsKey($rk)) { $byResult[$rk] = New-Object System.Collections.Generic.List[string] }
            $byResult[$rk].Add($rid) | Out-Null
        } catch { }
    }
}

# 原版中文（assets 对象，不在 server jar）
[void](Import-VanillaZhFromAssets $items)

# 配方涉及的物品必须保留；模组有中文名的物品全部保留（可搜「揭示护目镜」等研究产物）
$used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$modNs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($r in $recipes) {
    if ($r.result) {
        [void]$used.Add([string]$r.result)
        if ([string]$r.result -match '^([^:]+):') { [void]$modNs.Add($matches[1]) }
    }
    foreach ($ing in @($r.ingredients)) {
        $s = [string]$ing
        if ($s -and -not $s.StartsWith('#')) {
            [void]$used.Add($s)
            if ($s -match '^([^:]+):') { [void]$modNs.Add($matches[1]) }
        }
    }
    foreach ($ing in @($r.extraInputs)) {
        if ($ing) { [void]$used.Add([string]$ing) }
    }
    if ($r.primaryInput) { [void]$used.Add([string]$r.primaryInput) }
    if ($r.activationItem) { [void]$used.Add([string]$r.activationItem) }
}
[void]$modNs.Add('thaumcraft')
[void]$modNs.Add('minecraft')

$slimItems = @{}
foreach ($kv in $items.GetEnumerator()) {
    $id = [string]$kv.Key
    $zh = [string]$kv.Value.zh
    $ns = if ($id -match '^([^:]+):') { $matches[1] } else { '' }
    $keep = $false
    if ($used.Contains($id)) { $keep = $true }
    elseif ($ns -and $ns -ne 'minecraft' -and -not [string]::IsNullOrWhiteSpace($zh)) { $keep = $true }
    elseif ($ns -eq 'minecraft' -and $used.Contains($id)) { $keep = $true }
    if ($keep) { $slimItems[$id] = $kv.Value }
}
# 配方里有、但 lang 未收录的 id
foreach ($id in $used) {
    if (-not $slimItems.ContainsKey($id)) {
        $slimItems[$id] = [ordered]@{ id = $id; zh = ''; en = ''; kind = 'item' }
    }
}
$items = $slimItems
Write-IdxLog ("items kept=$($items.Count) usedInRecipes=$($used.Count) modNs=$($modNs.Count)")

# 给常驻 QQ 进程提供轻量名称表；查询要素物品时不应反复解析 100MB 级 index.json。
$nameLines = New-Object System.Collections.Generic.List[string]
$nameLines.Add('# format=qq-item-names-v1') | Out-Null
$nameLines.Add("id`tzh`ten") | Out-Null
foreach ($id in @($items.Keys | Sort-Object)) {
    if (([string]$id) -notmatch '^[a-z0-9_.-]+:[a-z0-9_./-]+$') { continue }
    $zh = ([string]$items[$id].zh) -replace "[`t`r`n]", ' '
    $en = ([string]$items[$id].en) -replace "[`t`r`n]", ' '
    $safeId = ([string]$id) -replace "[`t`r`n]", ' '
    $nameLines.Add("$safeId`t$zh`t$en") | Out-Null
}
[IO.File]::WriteAllLines($NamesPath, $nameLines, [Text.UTF8Encoding]::new($false))

# zh name index for search（含去「之/的」弱化别名）
$zhToIds = @{}
function Add-ZhAlias([hashtable]$Map, [string]$Zh, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Zh) -or [string]::IsNullOrWhiteSpace($Id)) { return }
    if (-not $Map.ContainsKey($Zh)) { $Map[$Zh] = New-Object System.Collections.Generic.List[string] }
    if (-not $Map[$Zh].Contains($Id)) { $Map[$Zh].Add($Id) | Out-Null }
}
foreach ($kv in $items.GetEnumerator()) {
    $zh = [string]$kv.Value.zh
    if ([string]::IsNullOrWhiteSpace($zh)) { continue }
    Add-ZhAlias $zhToIds $zh $kv.Key
    # 揭示之护目镜 → 揭示护目镜
    $compact = $zh -replace '[之的]', ''
    if ($compact -ne $zh -and $compact.Length -ge 2) {
        Add-ZhAlias $zhToIds $compact $kv.Key
    }
}

$sw.Stop()
$index = [ordered]@{
    version     = 1
    generatedAt = (Get-Date).ToString('o')
    jarCount    = $jarCount
    recipeCount = $recipes.Count
    itemCount   = $items.Count
    items       = $items
    recipes     = $recipes
    byResult    = $byResult
    zhToIds     = $zhToIds
}

$json = $index | ConvertTo-Json -Depth 8 -Compress
# Compress may be huge; use non-compress if needed
if ($json.Length -lt 10) {
    $json = $index | ConvertTo-Json -Depth 8
}
[IO.File]::WriteAllText($IndexPath, ($index | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

$meta = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    seconds     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    jarCount    = $jarCount
    recipeCount = $recipes.Count
    itemCount   = $items.Count
    langZhKeys  = $langZhCount
    langEnKeys  = $langEnCount
    indexPath   = $IndexPath
    namesPath   = $NamesPath
    sizeBytes   = (Get-Item $IndexPath).Length
}
[IO.File]::WriteAllText($MetaPath, ($meta | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-IdxLog ("done recipes=$($recipes.Count) items=$($items.Count) sec=$($meta.seconds)")
if (-not $Quiet) {
    Write-Host ("【配方索引】完成 jar={0} 配方={1} 物品名={2} 耗时 {3}s" -f $jarCount, $recipes.Count, $items.Count, $meta.seconds)
    Write-Host ("输出: " + $IndexPath)
}
exit 0
