# Per-game player stats from the lolesports livestats feed: a 5-lane radar image (blue vs red per role),
# a per-team stat table and a data-based MVP. Dot-sourced by bot.ps1.

$feed = 'https://feed.lolesports.com/livestats/v1'
$roles = @('top', 'jungle', 'mid', 'bottom', 'support')
$roleNames = @{ top = '上路'; jungle = '打野'; mid = '中路'; bottom = '下路'; support = '輔助' }
$axes = @('damage', 'gold', 'cs', 'kp', 'kda', 'vision')
$axisNames = @('傷害佔比', '經濟', '補刀', '參團率', 'KDA', '視野')

function Get-EventDetails([string]$MatchId) {
    if (-not $script:eventDetails) { $script:eventDetails = @{} }
    if (-not $script:eventDetails.ContainsKey($MatchId)) {
        $r = Invoke-Api GET "https://esports-api.lolesports.com/persisted/gw/getEventDetails?hl=zh-TW&id=$MatchId" @{ 'x-api-key' = $apiKey } $null
        $script:eventDetails[$MatchId] = $r.data.event
    }
    $script:eventDetails[$MatchId]
}

# Data Dragon key ("LeeSin") -> Traditional Chinese name ("李星")
function Get-ChampionName([string]$Key) {
    if ($null -eq $script:champions) {
        $script:champions = @{}
        try {
            $ver = @(Invoke-Api GET 'https://ddragon.leagueoflegends.com/api/versions.json' @{} $null)[0]
            $c = Invoke-Api GET "https://ddragon.leagueoflegends.com/cdn/$ver/data/zh_TW/champion.json" @{} $null
            foreach ($p in $c.data.PSObject.Properties) { $script:champions[$p.Name] = $p.Value.name }
        } catch {}
    }
    if ($script:champions.ContainsKey($Key)) { $script:champions[$Key] } else { $Key }
}

# status: ok = final stats ready, wait = game feed still live (retry next pass), none = no stats for this game
function Get-GameStats([string]$MatchId, [int]$Number) {
    $ed = Get-EventDetails $MatchId
    $game = @($ed.match.games) | Where-Object { [int]$_.number -eq $Number } | Select-Object -First 1
    if (-not $game) { return @{ status = 'none' } }

    # startingTime must be a multiple of 10 s; a time after the game ends returns its final frames
    $t = [DateTime]::UtcNow.AddSeconds(-60)
    $t = $t.AddTicks(-($t.Ticks % 100000000))
    $q = '?startingTime=' + $t.ToString('yyyy-MM-ddTHH:mm:ss.000Z')
    try { $w = Invoke-Api GET "$feed/window/$($game.id)$q" @{} $null } catch { return @{ status = 'none' } }
    $frames = @($w.frames)
    if (-not $w -or -not $frames.Count) { return @{ status = 'none' } }
    $last = $frames[-1]
    if ($last.gameState -ne 'finished') {
        $age = [DateTime]::UtcNow - (ConvertTo-Utc $last.rfc460Timestamp)
        if ($age.TotalMinutes -lt $cfg.stats.waitMinutes) { return @{ status = 'wait' } }
        return @{ status = 'none' }
    }
    $detail = @{}
    try {
        $d = Invoke-Api GET "$feed/details/$($game.id)$q" @{} $null
        foreach ($p in @(@($d.frames)[-1].participants)) { $detail[[int]$p.participantId] = $p }
    } catch {}

    $codeById = @{}
    foreach ($tm in @($ed.match.teams)) { $codeById["$($tm.id)"] = $tm.code }
    $players = @()
    foreach ($side in 'blue', 'red') {
        $meta = $w.gameMetadata."${side}TeamMetadata"
        $frameTeam = $last."${side}Team"
        foreach ($pm in @($meta.participantMetadata)) {
            $pf = @($frameTeam.participants) | Where-Object { $_.participantId -eq $pm.participantId } | Select-Object -First 1
            $pd = $detail[[int]$pm.participantId]
            $name = "$($pm.summonerName)"
            if ($name -match '^\S+\s+(.+)$') { $name = $Matches[1] }   # "T1 Doran" -> "Doran"
            $k = [int]$pf.kills; $de = [int]$pf.deaths; $as = [int]$pf.assists
            $players += [pscustomobject]@{
                side = $side; team = $codeById["$($meta.esportsTeamId)"]; role = $pm.role
                name = $name; champ = Get-ChampionName $pm.championId
                k = $k; d = $de; a = $as; cs = [int]$pf.creepScore; goldRaw = [int]$pf.totalGold
                v = @{
                    damage = [double]$pd.championDamageShare; gold = [double]$pf.totalGold; cs = [double]$pf.creepScore
                    kp = [double]$pd.killParticipation; kda = ($k + $as) / [Math]::Max(1, $de)
                    vision = [double]$pd.wardsPlaced + [double]$pd.wardsDestroyed
                }
                n = @{}; score = 0.0
            }
        }
    }
    # Each axis relative to the best of the 10 players (= 100)
    foreach ($ax in $axes) {
        $max = ($players | ForEach-Object { $_.v[$ax] } | Measure-Object -Maximum).Maximum
        foreach ($p in $players) { $p.n[$ax] = if ($max -gt 0) { 100 * $p.v[$ax] / $max } else { 0.0 } }
    }
    foreach ($p in $players) {
        $wts = $cfg.stats.mvpWeights.($p.role)
        if (-not $wts) { continue }
        $sum = 0.0; $tot = 0.0
        foreach ($prop in $wts.PSObject.Properties) { $sum += $prop.Value * $p.n[$prop.Name]; $tot += $prop.Value }
        if ($tot) { $p.score = $sum / $tot }
    }
    # Supports' vision/KP are naturally near the top, so also reward beating the lane opponent
    foreach ($p in $players) {
        $opp = $players | Where-Object { $_.role -eq $p.role -and $_.side -ne $p.side } | Select-Object -First 1
        $lead = if ($opp) { $p.score - $opp.score } else { 0 }
        $p | Add-Member -NotePropertyName mvp -NotePropertyValue ($p.score + $cfg.stats.laneWeight * $lead)
    }
    @{ status = 'ok'; players = $players }
}

function New-RadarPanel($blue, $red, [string]$role) {
    function ds($p, [string]$color, [string]$fill) {
        @{ label = "$($p.name)（$($p.champ)）"; data = @(foreach ($ax in $axes) { [Math]::Round($p.n[$ax]) })
            borderColor = $color; backgroundColor = $fill; pointBackgroundColor = $color; pointRadius = 2; borderWidth = 2 }
    }
    $sets = @()
    if ($blue) { $sets += ds $blue '#4a9eff' 'rgba(74,158,255,0.25)' }
    if ($red) { $sets += ds $red '#ff5c5c' 'rgba(255,92,92,0.25)' }
    $body = @{
        version = '2'; width = 400; height = 430; format = 'png'; backgroundColor = '#2b2d31'
        chart = @{
            type = 'radar'
            data = @{ labels = $axisNames; datasets = $sets }
            options = @{
                title = @{ display = $true; text = $roleNames[$role]; fontColor = '#f2f3f5'; fontSize = 20 }
                legend = @{ position = 'bottom'; labels = @{ fontColor = '#dbdee1'; fontSize = 13; boxWidth = 14 } }
                scale = @{
                    ticks = @{ min = 0; max = 100; stepSize = 25; display = $false }
                    gridLines = @{ color = '#4e5058' }; angleLines = @{ color = '#4e5058' }
                    pointLabels = @{ fontColor = '#b5bac1'; fontSize = 13 }
                }
            }
        }
    }
    $json = ConvertTo-Json -InputObject $body -Depth 12 -Compress
    $r = Invoke-WebRequest -UseBasicParsing -Method POST 'https://quickchart.io/chart' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'
    $r.RawContentStream.ToArray()
}

# Five lane radars on one 1200x860 canvas: 3 on top, 2 centred below
function New-StatsImage($st) {
    Add-Type -AssemblyName System.Drawing
    $canvas = New-Object Drawing.Bitmap 1200, 860
    $g = [Drawing.Graphics]::FromImage($canvas)
    $g.Clear([Drawing.ColorTranslator]::FromHtml('#2b2d31'))
    $slots = @(@(0, 0), @(400, 0), @(800, 0), @(200, 430), @(600, 430))
    for ($i = 0; $i -lt $roles.Count; $i++) {
        $role = $roles[$i]
        $blue = $st.players | Where-Object { $_.side -eq 'blue' -and $_.role -eq $role } | Select-Object -First 1
        $red = $st.players | Where-Object { $_.side -eq 'red' -and $_.role -eq $role } | Select-Object -First 1
        $png = New-RadarPanel $blue $red $role
        $img = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $png)))
        $g.DrawImage($img, $slots[$i][0], $slots[$i][1], 400, 430)
        $img.Dispose()
    }
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $canvas.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $canvas.Dispose()
    , $ms.ToArray()
}

# Adds the per-team table + MVP to a game card and returns the radar PNG
function Add-GameStats($Embed, $st, [string]$WinnerCode) {
    $mvp = $st.players | Where-Object { $_.team -eq $WinnerCode } | Sort-Object mvp -Descending | Select-Object -First 1
    $fields = @()
    foreach ($side in 'blue', 'red') {
        $team = @($st.players | Where-Object side -eq $side)
        $dot = if ($side -eq 'blue') { '🔵' } else { '🔴' }
        $lines = foreach ($role in $roles) {
            $p = $team | Where-Object role -eq $role | Select-Object -First 1
            if (-not $p) { continue }
            $star = if ($p -eq $mvp) { '⭐ ' } else { '' }
            "$star**$($p.name)**（$($p.champ)）$($p.k)/$($p.d)/$($p.a) · $($p.cs) 刀 · $('{0:0.0}k' -f ($p.goldRaw / 1000))"
        }
        $fields += @{ name = "$dot $($team[0].team)"; value = ($lines -join "`n"); inline = $false }
    }
    $png = New-StatsImage $st
    $Embed.fields = $fields
    $Embed.image = @{ url = 'attachment://stats.png' }
    if ($mvp) { $Embed.description += "`n⭐ 本局 MVP：**$($mvp.name)**（依數據計算，非官方）" }
    , $png
}

# Stats for a finished game, attached to $Embed. Returns the PNG, $null without stats, or 'wait'.
function Add-GameStatsIfReady($Embed, [string]$MatchId, [int]$Number, [string]$WinnerCode) {
    try { $st = Get-GameStats $MatchId $Number } catch { return $null }
    if ($st.status -eq 'wait') { return 'wait' }
    if ($st.status -ne 'ok') { return $null }
    try { return , (Add-GameStats $Embed $st $WinnerCode) } catch { "stats failed: $_" | Write-Host; return $null }
}
