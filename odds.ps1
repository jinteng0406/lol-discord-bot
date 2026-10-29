# Worlds title odds from the prediction-market winner event: one pinned, continuously edited message in the
# odds channel (table + trend chart), plus the before/after line on series summary cards. Dot-sourced by bot.ps1.
# Never links to the market itself.

$oc = $cfg.odds
$pmGamma = 'https://gamma-api.polymarket.com'
$pmClob = 'https://clob.polymarket.com'
$palette = @('#e6b422', '#e74c3c', '#3498db', '#2ecc71', '#9b59b6', '#1abc9c', '#e67e22', '#ecf0f1', '#ff79c6', '#95a5a6')

function ConvertTo-Unix([DateTime]$utc) { [DateTimeOffset]::new($utc).ToUnixTimeSeconds() }

# Teams knocked out per lolesports: 3 Swiss losses, or a lost BO5
function Get-EliminatedCodes {
    $out = @{}
    $from = ConvertTo-Utc $oc.chartFrom   # earlier editions of the event can be in the feed too
    foreach ($ev in $events) {
        if ($ev.league.slug -ne $oc.league -or $ev.state -ne 'completed') { continue }
        if ((ConvertTo-Utc $ev.startTime) -lt $from) { continue }
        foreach ($t in $ev.match.teams) {
            if ($t.record -and [int]$t.record.losses -ge 3) { $out[$t.code] = $true }
            if ([int]$ev.match.strategy.count -eq 5 -and $t.result.outcome -eq 'loss') { $out[$t.code] = $true }
        }
    }
    $out
}

# Last price at or before $ts (first price if $ts precedes the history)
function Get-PriceAt($hist, [long]$ts) {
    $n = $hist.t.Count
    if ($n -eq 0) { return 0.0 }
    if ($ts -lt $hist.t[0]) { return $hist.p[0] }
    $lo = 0; $hi = $n - 1
    while ($lo -lt $hi) {
        $mid = [int][Math]::Ceiling(($lo + $hi) / 2)
        if ($hist.t[$mid] -le $ts) { $lo = $mid } else { $hi = $mid - 1 }
    }
    $hist.p[$lo]
}

# Prices normalised to 100% across all teams at a past moment
function Get-NormAt($d, [long]$ts) {
    $raw = @{}; $sum = 0.0
    foreach ($t in $d.teams) { $v = Get-PriceAt $d.hist[$t.code] $ts; $raw[$t.code] = $v; $sum += $v }
    $out = @{}
    foreach ($k in $raw.Keys) { $out[$k] = if ($sum -gt 0) { 100 * $raw[$k] / $sum } else { 0.0 } }
    $out
}

function Get-OddsData {
    if ($script:oddsData) { return $script:oddsData }
    $evt = @(Invoke-Api GET "$pmGamma/events?slug=$($oc.eventSlug)" @{} $null)[0]
    $elim = Get-EliminatedCodes
    $teams = @()
    foreach ($m in @($evt.markets)) {
        $code = $oc.teams.($m.groupItemTitle)
        if (-not $code) { continue }   # placeholder markets such as "Team I" / "Other"
        $price = [double](ConvertFrom-Json $m.outcomePrices)[0]
        if ($m.bestBid -and $m.bestAsk) { $price = ([double]$m.bestBid + [double]$m.bestAsk) / 2 }
        $teams += [pscustomobject]@{
            code = $code; token = (ConvertFrom-Json $m.clobTokenIds)[0]; price = $price
            out = [bool]$m.closed -or $elim.ContainsKey($code)
        }
    }

    $fromTs = ConvertTo-Unix (ConvertTo-Utc $oc.chartFrom)
    $hist = @{}
    foreach ($t in $teams) {
        $h = Invoke-Api GET "$pmClob/prices-history?market=$($t.token)&startTs=$fromTs&fidelity=60" @{} $null
        $pts = @($h.history | Sort-Object t)
        $hist[$t.code] = @{ t = [long[]]@($pts | ForEach-Object { $_.t }); p = [double[]]@($pts | ForEach-Object { $_.p }) }
    }

    $aliveSum = 0.0
    foreach ($t in $teams) { if (-not $t.out) { $aliveSum += $t.price } }
    $now = @{}
    foreach ($t in $teams) { $now[$t.code] = if ($t.out -or $aliveSum -le 0) { 0.0 } else { 100 * $t.price / $aliveSum } }

    $script:oddsData = @{ closed = [bool]$evt.closed; teams = $teams; hist = $hist; now = $now }
    $script:oddsData
}

# Series-winner market for one scheduled match: @{ <code> = <whole %> } or $null when no market exists.
# Found by search, then matched on market start time and both team names (search also returns other games).
function Get-MatchOdds($ev) {
    if (-not $script:matchOdds) { $script:matchOdds = @{} }
    $id = $ev.match.id
    if ($script:matchOdds.ContainsKey($id)) { return $script:matchOdds[$id] }
    $script:matchOdds[$id] = $null
    $ta = $ev.match.teams[0]; $tb = $ev.match.teams[1]
    $marketName = @{}
    foreach ($p in $oc.teams.PSObject.Properties) { $marketName[$p.Value] = $p.Name }
    $na = if ($marketName[$ta.code]) { $marketName[$ta.code] } else { $ta.name }
    $nb = if ($marketName[$tb.code]) { $marketName[$tb.code] } else { $tb.name }
    $t = ConvertTo-Utc $ev.startTime
    $r = Invoke-Api GET "$pmGamma/public-search?q=$([Uri]::EscapeDataString("$na $nb"))" @{} $null
    foreach ($e in @($r.events)) {
        if ("$($e.slug)" -notlike 'lol-*' -or $e.closed) { continue }
        foreach ($m in @($e.markets)) {
            if ($m.sportsMarketType -ne 'moneyline' -or $m.closed -or -not $m.gameStartTime) { continue }
            if ([Math]::Abs(([DateTimeOffset]::Parse("$($m.gameStartTime)").UtcDateTime - $t).TotalHours) -gt 6) { continue }
            # Assign first, then enumerate: @(ConvertFrom-Json '[..]') in PS 5.1 is one element holding the array
            $outs = ConvertFrom-Json $m.outcomes
            $outs = @($outs | ForEach-Object { $_ })
            $ia = -1; $ib = -1
            for ($k = 0; $k -lt $outs.Count; $k++) {
                if ([string]::Equals("$($outs[$k])", $na, [StringComparison]::OrdinalIgnoreCase)) { $ia = $k }
                if ([string]::Equals("$($outs[$k])", $nb, [StringComparison]::OrdinalIgnoreCase)) { $ib = $k }
            }
            if ($outs.Count -ne 2 -or $ia -lt 0 -or $ib -lt 0 -or $ia -eq $ib) { continue }
            $p0 = [double](ConvertFrom-Json $m.outcomePrices)[0]
            if ($m.bestBid -and $m.bestAsk) { $p0 = ([double]$m.bestBid + [double]$m.bestAsk) / 2 }
            $pa = [int][Math]::Round(100 * $(if ($ia -eq 0) { $p0 } else { 1 - $p0 }))
            $script:matchOdds[$id] = @{ $ta.code = $pa; $tb.code = 100 - $pa }
            return $script:matchOdds[$id]
        }
    }
    $null
}

function Format-Pct([double]$v) { if ($v -gt 0 -and $v -lt 0.05) { '<0.1%' } else { '{0:0.0}%' -f $v } }

# "BLG 31.0% → 38.2% ▲　TES 2.1% → 淘汰" for a Worlds series that started at $startUtc
function Get-OddsChangeLine([string[]]$Codes, [DateTime]$StartUtc) {
    $d = Get-OddsData
    $before = Get-NormAt $d (ConvertTo-Unix $StartUtc)
    $parts = foreach ($c in $Codes) {
        if (-not $d.now.ContainsKey($c)) { continue }
        $b = $before[$c]; $a = $d.now[$c]
        $arrow = if ($a - $b -ge 0.1) { ' ▲' } elseif ($b - $a -ge 0.1) { ' ▼' } else { '' }
        $after = if (($d.teams | Where-Object code -eq $c).out) { '淘汰' } else { (Format-Pct $a) + $arrow }
        "$c $(Format-Pct $b) → $after"
    }
    if ($parts) { '奪冠機率：' + ($parts -join '　') }
}

function New-OddsChart($d) {
    $from = ConvertTo-Utc $oc.chartFrom
    $grid = @()
    for ($t = $from; $t -lt $nowUtc; $t = $t.AddHours($oc.chartStepHours)) { $grid += $t }
    $labels = @(foreach ($t in $grid) { $tw = $t.AddHours(8); if ($tw.Hour -lt $oc.chartStepHours) { $tw.ToString('M/d') } else { '' } })
    $labels += '現在'
    $snap = @(foreach ($t in $grid) { Get-NormAt $d (ConvertTo-Unix $t) })

    $alive = @($d.teams | Where-Object { -not $_.out } | Sort-Object { $d.now[$_.code] } -Descending)
    $codes = @($alive | Select-Object -First $oc.chartTop | ForEach-Object code)
    foreach ($h in $oc.highlight) { if ($codes -notcontains $h -and $d.now.ContainsKey($h)) { $codes += $h } }

    $datasets = @()
    $i = 0
    foreach ($c in $codes) {
        $vals = New-Object System.Collections.Generic.List[object]
        foreach ($s in $snap) { $vals.Add([Math]::Round($s[$c], 1)) }
        $vals.Add([Math]::Round($d.now[$c], 1))
        if (($d.teams | Where-Object code -eq $c).out) {
            # Line stops once the team drops to zero
            $last = -1
            for ($k = 0; $k -lt $vals.Count; $k++) { if ($vals[$k] -ge 0.05) { $last = $k } }
            for ($k = $last + 2; $k -lt $vals.Count; $k++) { $vals[$k] = $null }
            if ($last + 1 -lt $vals.Count) { $vals[$last + 1] = 0 }
        }
        $color = $palette[$i % $palette.Count]; $i++
        $ds = @{ label = $c; data = $vals.ToArray(); borderColor = $color; backgroundColor = $color
            fill = $false; pointRadius = 0; borderWidth = 2; lineTension = 0.2; spanGaps = $false }
        if ($oc.highlight -contains $c) { $ds.borderDash = @(6, 4) }
        $datasets += $ds
    }

    $axis = @{ fontColor = '#b5bac1'; autoSkip = $false; maxRotation = 0 }
    $gridLines = @{ color = '#3f4147' }
    $body = @{
        version = '2'; width = 1000; height = 520; format = 'png'; backgroundColor = '#2b2d31'
        chart = @{
            type = 'line'
            data = @{ labels = $labels; datasets = $datasets }
            options = @{
                legend = @{ position = 'right'; labels = @{ fontColor = '#dbdee1' } }
                scales = @{
                    xAxes = @(@{ ticks = $axis; gridLines = @{ display = $false } })
                    yAxes = @(@{ ticks = @{ fontColor = '#b5bac1'; min = 0 }; gridLines = $gridLines
                            scaleLabel = @{ display = $true; labelString = '奪冠機率 (%)'; fontColor = '#b5bac1' } })
                }
            }
        }
    }
    $json = ConvertTo-Json -InputObject $body -Depth 12 -Compress
    $r = Invoke-WebRequest -UseBasicParsing -Method POST 'https://quickchart.io/chart' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'
    $r.RawContentStream.ToArray()
}

function New-OddsEmbed($d) {
    $alive = @($d.teams | Where-Object { -not $_.out } | Sort-Object { $d.now[$_.code] } -Descending)
    $max = [Math]::Max(1.0, $d.now[$alive[0].code])
    $day = Get-NormAt $d (ConvertTo-Unix $nowUtc.AddHours(-24))
    $lines = foreach ($t in $alive) {
        $v = $d.now[$t.code]
        $bar = '█' * [int][Math]::Round($v / $max * 12)
        $delta = $v - $day[$t.code]
        $ds = if ($delta -ge 0.1) { '▲{0:0.0}' -f $delta } elseif ($delta -le -0.1) { '▼{0:0.0}' -f (-$delta) } else { '' }
        '{0,-5}{1,-13}{2,6}  {3}' -f $t.code, $bar, (Format-Pct $v), $ds
    }
    $out = @($d.teams | Where-Object { $_.out -and ($d.hist[$_.code].t.Count) } | ForEach-Object code)
    $desc = "``````" + "`n" + ($lines -join "`n") + "`n``````" + "`n▲▼ 為 24 小時變化"
    if ($out.Count) { $desc += "`n已淘汰：" + ($out -join '、') }
    @{
        title = '🏆 Worlds 2026 奪冠機率'
        description = $desc
        color = [int]$cfg.leagues.($oc.league).color
        image = @{ url = 'attachment://chart.png' }
        footer = @{ text = "依預測市場價格換算，非官方預測，僅供參考 · 更新於 $($nowUtc.AddHours(8).ToString('M/d HH:mm'))" }
    }
}

# Refresh the pinned odds message: forced after new results, otherwise every refreshMinutes
function Update-OddsMessage([switch]$Force) {
    $cid = $cfg.channels.odds
    $mine = $null
    if ($token) {
        if (-not $script:botId) { $script:botId = (Invoke-Discord GET '/users/@me').id }
        $mine = @(Invoke-Discord GET "/channels/$cid/messages?limit=50") |
            Where-Object { $_.author.id -eq $script:botId -and @($_.embeds).Count } | Select-Object -Last 1
    }
    if ($mine -and -not $Force) {
        $last = if ($mine.edited_timestamp) { $mine.edited_timestamp } else { $mine.timestamp }
        if ((ConvertTo-Utc $last) -gt $nowUtc.AddMinutes(-$oc.refreshMinutes)) { return }
    }
    $d = Get-OddsData
    if ($d.closed -and $mine) { return }   # tournament over: keep the final message as is
    if (-not @($d.teams | Where-Object { -not $_.out }).Count) { return }
    $png = New-OddsChart $d
    $payload = @{ embeds = @(New-OddsEmbed $d); attachments = @(@{ id = 0; filename = 'chart.png' }) }
    if ($DryRun) {
        [IO.File]::WriteAllBytes("$root\chart-preview.png", $png)
        "[dry-run] odds message -> $cid (chart saved to chart-preview.png)"
        $payload.embeds[0].description
        return
    }
    if ($mine) {
        Invoke-DiscordFiles PATCH "/channels/$cid/messages/$($mine.id)" $payload @{ 'chart.png' = $png } | Out-Null
        'Updated odds message'
    } else {
        $m = Invoke-DiscordFiles POST "/channels/$cid/messages" $payload @{ 'chart.png' = $png }
        try { Invoke-Discord PUT "/channels/$cid/messages/pins/$($m.id)" $null | Out-Null }
        catch { Invoke-Discord PUT "/channels/$cid/pins/$($m.id)" $null | Out-Null }
        'Posted and pinned odds message'
    }
}
