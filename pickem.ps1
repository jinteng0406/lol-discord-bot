# Knockout score pick'em in the pick'em channel: one post per match with a reaction per possible score,
# locked at the scheduled start (votes copied into the post), scored when the series ends, plus a pinned
# leaderboard. All state lives in the posts themselves. Dot-sourced by bot.ps1.

$pickLetters = @('🇦', '🇧', '🇨', '🇩', '🇪', '🇫', '🇬', '🇭')
$lockField = '🔒 投票結果'
$resultField = '✅ 結果'

# Options in post order: A wins clean ... A wins close, B wins close ... B wins clean
function Get-PickemOptions($ev) {
    $need = [int][Math]::Ceiling([int]$ev.match.strategy.count / 2)
    $codes = @($ev.match.teams[0].code, $ev.match.teams[1].code)
    $opts = @()
    for ($l = 0; $l -lt $need; $l++) { $opts += @{ side = 0; lose = $l } }
    for ($l = $need - 1; $l -ge 0; $l--) { $opts += @{ side = 1; lose = $l } }
    for ($i = 0; $i -lt $opts.Count; $i++) {
        $opts[$i].emoji = $pickLetters[$i]
        $opts[$i].label = "**$($codes[$opts[$i].side])** ${need}:$($opts[$i].lose)"
    }
    $opts
}

function Get-Field($msg, [string]$Name) { @($msg.embeds[0].fields) | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }

# Rebuild an embed we read back from Discord so it can be sent again with extra fields
function Copy-PickemEmbed($msg, [string]$ExtraDescription, $ExtraField) {
    $e = $msg.embeds[0]
    $fields = @(@($e.fields) | Where-Object { $_ } | ForEach-Object { @{ name = $_.name; value = $_.value; inline = $false } })
    $fields += $ExtraField
    @{
        title = $e.title; description = "$($e.description)$ExtraDescription"; color = $e.color; fields = $fields
        footer = @{ text = ("$($e.footer.text)" -replace ' · #\S+$', '') }
    }
}

function Update-Pickem {
    $cid = $cfg.channels.pickem
    $pc = $cfg.pickem
    $scored = $false
    foreach ($ev in $events) {
        if ($ev.league.slug -ne $pc.league -or @($pc.blocks) -notcontains $ev.blockName) { continue }
        if (-not (Test-TeamsKnown $ev)) { continue }
        $t = ConvertTo-Utc $ev.startTime
        $key = "p-$($ev.match.id)"
        $opts = Get-PickemOptions $ev
        $existing = Find-BotMessage $cid $key

        # Open as soon as both teams are known, but not overnight (01:00-10:00 TW): wait for 10:00 so
        # people see it, unless the match itself starts before then
        if (-not $existing) {
            if ($ev.state -ne 'unstarted' -or $nowUtc -ge $t) { continue }
            $overnight = $nowTW.Hour -ge $cfg.silentFromHourTW -and $nowTW.Hour -lt $cfg.scheduleHourTW
            if ($overnight -and $t.AddHours(8) -gt $nowTW.Date.AddHours($cfg.scheduleHourTW)) { continue }
            $isFinal = $ev.blockName -eq $pc.finalBlock
            $rules = '按下方反應投票，一人限一個選項（多選視為無效），開賽即截止。猜中勝方 1 分，比分全中再 +1'
            if ($isFinal) { $rules += '，**決賽雙倍**' }
            $embed = @{
                title = "🎯 競猜：$($ev.match.teams[0].code) vs $($ev.match.teams[1].code)"
                description = "$($ev.blockName) · BO$($ev.match.strategy.count) · 預定 ``$($t.AddHours(8).ToString('M/d HH:mm'))`` 開打`n`n" +
                    (($opts | ForEach-Object { "$($_.emoji) $($_.label)" }) -join "`n") + "`n`n$rules"
                color = Get-LeagueColor $ev
                footer = @{ text = "$($ev.league.name) · $($ev.blockName)" }
            }
            Send-Embed $cid $embed $key -Silent:$silent
            if ($script:lastPosted) {
                foreach ($o in $opts) {
                    Invoke-Discord PUT "/channels/$cid/messages/$($script:lastPosted.id)/reactions/$([Uri]::EscapeDataString($o.emoji))/@me" $null | Out-Null
                }
            }
            continue
        }

        # Lock at the scheduled start: copy the votes into the post (reactions carry no timestamp)
        $lock = Get-Field $existing.msg $lockField
        if (-not $lock) {
            if ($nowUtc -lt $t) { continue }
            $votes = @{}
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $enc = [Uri]::EscapeDataString($opts[$i].emoji)
                foreach ($u in @(Invoke-Discord GET "/channels/$cid/messages/$($existing.id)/reactions/$enc`?limit=100")) {
                    if (-not $u.id -or $u.id -eq $script:botId) { continue }
                    if (-not $votes.ContainsKey($u.id)) { $votes[$u.id] = @() }
                    $votes[$u.id] += $i
                }
            }
            $lines = @()
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $who = @($votes.Keys | Where-Object { $votes[$_].Count -eq 1 -and $votes[$_][0] -eq $i } | ForEach-Object { "<@$_>" })
                if ($who.Count) { $lines += "$($opts[$i].emoji) $($opts[$i].label)：$($who -join ' ')" }
            }
            $bad = @($votes.Keys | Where-Object { $votes[$_].Count -gt 1 } | ForEach-Object { "<@$_>" })
            if ($bad.Count) { $lines += "無效票（多選）：$($bad -join ' ')" }
            if (-not $lines.Count) { $lines = @('沒有人投票') }
            $embed = Copy-PickemEmbed $existing.msg "`n`n🔒 已截止" @{ name = $lockField; value = ($lines -join "`n"); inline = $false }
            Edit-Embed $cid $existing.id $embed $key
            continue   # score on a later pass, from the locked copy
        }

        # Score once the series is over
        if ($ev.state -ne 'completed' -or (Get-Field $existing.msg $resultField)) { continue }
        $a = [int]$ev.match.teams[0].result.gameWins; $b = [int]$ev.match.teams[1].result.gameWins
        $winSide = if ($a -gt $b) { 0 } else { 1 }
        $lose = [Math]::Min($a, $b)
        $mult = if ($ev.blockName -eq $pc.finalBlock) { 2 } else { 1 }
        $points = @{}
        foreach ($line in ("$($lock.value)" -split "`n")) {
            for ($i = 0; $i -lt $opts.Count; $i++) {
                if (-not $line.StartsWith($opts[$i].emoji, [StringComparison]::Ordinal)) { continue }
                $o = $opts[$i]
                $pts = 0
                if ($o.side -eq $winSide) { $pts++; if ($o.lose -eq $lose) { $pts++ } }
                foreach ($mm in [regex]::Matches($line, '<@(\d+)>')) { $points[$mm.Groups[1].Value] = $pts * $mult }
            }
        }
        $value = "**$($ev.match.teams[0].code)** ${a}:${b} **$($ev.match.teams[1].code)**`n"
        if ($points.Count) {
            $value += '得分：' + (($points.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "<@$($_.Key)> +$($_.Value)" }) -join '、')
        } else {
            $value += '沒有人投票'
        }
        $embed = Copy-PickemEmbed $existing.msg '' @{ name = $resultField; value = $value; inline = $false }
        Edit-Embed $cid $existing.id $embed $key
        $existing.msg = [pscustomobject]@{ id = $existing.id; embeds = @([pscustomobject]$embed) }
        $scored = $true
    }
    Update-PickemBoard -Force:$scored
}

# Pinned leaderboard, rebuilt from every scored pick'em post
function Update-PickemBoard([switch]$Force) {
    $cid = $cfg.channels.pickem
    $board = Find-BotMessage $cid 'board'
    if ($board -and -not $Force) { return }
    $total = @{}; $hits = @{}; $played = @{}
    foreach ($x in (Get-BotMessages $cid)) {
        if ("$($x.key)" -notlike 'p-*') { continue }
        $res = Get-Field $x.msg $resultField
        if (-not $res) { continue }
        foreach ($mm in [regex]::Matches("$($res.value)", '<@(\d+)> \+(\d+)')) {
            $id = $mm.Groups[1].Value; $pts = [int]$mm.Groups[2].Value
            $total[$id] = [int]$total[$id] + $pts
            $played[$id] = [int]$played[$id] + 1
            if ($pts -gt 0) { $hits[$id] = [int]$hits[$id] + 1 }
        }
    }
    $rows = @($total.Keys | Sort-Object @{ e = { $total[$_] }; Descending = $true }, @{ e = { [int]$hits[$_] }; Descending = $true })
    $medals = @('🥇', '🥈', '🥉')
    $lines = for ($i = 0; $i -lt $rows.Count; $i++) {
        $id = $rows[$i]
        $rank = if ($i -lt 3) { $medals[$i] } else { "$($i + 1)." }
        "$rank <@$id> **$($total[$id])** 分（猜中勝方 $([int]$hits[$id])/$($played[$id])）"
    }
    $desc = '還沒有比賽結算，八強賽打完第一場後開始計分。'
    if ($lines) { $desc = $lines -join "`n" }
    $embed = @{
        title = '🏅 競猜排行榜'
        description = $desc
        color = [int]$cfg.leagues.($cfg.pickem.league).color
        footer = @{ text = "更新於 $($nowTW.ToString('M/d HH:mm'))" }
    }
    if ($board) {
        Edit-Embed $cid $board.id $embed 'board'
    } else {
        Send-Embed $cid $embed 'board' -Silent
        if ($script:lastPosted) {
            $mid = $script:lastPosted.id
            try { Invoke-Discord PUT "/channels/$cid/messages/pins/$mid" $null | Out-Null }
            catch { Invoke-Discord PUT "/channels/$cid/pins/$mid" $null | Out-Null }
        }
    }
}
