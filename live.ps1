# Daily schedule (post once, then keep it in sync), pre-match reminders, per-game lineup cards and the
# Worlds champion card. Dot-sourced by bot.ps1.

function New-ScheduleEmbed([DateTime]$Day, $Todays, [hashtable]$Odds) {
    $fields = @()
    foreach ($g in ($Todays | Group-Object { $_.league.name })) {
        $lines = foreach ($ev in $g.Group) {
            $t = ConvertTo-Utc $ev.startTime
            $time = Format-TW $t
            if ($t.AddHours(8).Date -gt $Day) { $time += '（隔日）' }
            $a = $ev.match.teams[0].code; $b = $ev.match.teams[1].code
            $line = "``$time`` **$a** vs **$b** · BO$($ev.match.strategy.count) · $($ev.blockName)"
            $o = $Odds[$ev.match.id]
            if ($o) {
                # 10-square split bar: blue = first team's win rate, red = second team's
                $n = [int][Math]::Round($o[$a] / 10)
                $line += "`n$a **$($o[$a])%** " + ('🟦' * $n) + ('🟥' * (10 - $n)) + " **$($o[$b])%** $b"
            }
            $line
        }
        $fields += @{ name = $g.Name; value = ($lines -join "`n`n"); inline = $false }
    }
    $dow = '日一二三四五六'[[int]$Day.DayOfWeek]
    @{
        title  = "📅 $($Day.ToString('M/d'))（週$dow）賽程"
        description = '時間為台灣時間，涵蓋今天 10:00 到明天 10:00'
        color  = Get-LeagueColor $Todays[0]
        fields = $fields
        footer = @{ text = 'LoL Esports' }
    }
}

# Window is [today 10:00 TW, tomorrow 10:00 TW). After the first post the message is edited when matches
# move or TBD teams are filled in; a changed start time also gets its own short notice.
function Update-Schedule {
    # The schedule day runs 10:00 -> 10:00 TW, so before 10:00 we are still syncing yesterday's post
    $day = $nowTW.AddHours(-$cfg.scheduleHourTW).Date
    $key = 'sched-' + $day.ToString('yyyy-MM-dd')
    $winStart = $day.AddHours($cfg.scheduleHourTW - 8)   # back to UTC
    $winEnd = $winStart.AddDays(1)
    $todays = @($events | Where-Object { $t = ConvertTo-Utc $_.startTime; $t -ge $winStart -and $t -lt $winEnd } |
        Sort-Object { ConvertTo-Utc $_.startTime })
    if (-not $todays.Count) { return }
    $cid = $cfg.channels.schedule
    $existing = Find-BotMessage $cid $key
    if (-not $existing) {
        Send-Embed $cid (New-ScheduleEmbed $day $todays (Get-ScheduleOdds $todays)) $key -Silent:$silent
        return
    }

    # Times/teams changes are synced right away; win rates only in the first minutes of each hour,
    # and at most every 30 min, so the post is not re-edited (and the market re-queried) every pass
    $oldText = (@($existing.msg.embeds[0].fields) | ForEach-Object { "$($_.name)`n$($_.value)" }) -join "`n"
    $plain = New-ScheduleEmbed $day $todays @{}
    $plainText = ($plain.fields | ForEach-Object { "$($_.name)`n$($_.value)" }) -join "`n"
    # Drop the win-rate bar lines (and the older inline "20% vs 80%" form) to compare times/teams only
    $oldPlain = ($oldText -replace "`n[^`n]*🟦[^`n]*|`n[^`n]*🟥[^`n]*", '') -replace ' \d+% vs \d+% ', ' vs '
    $structural = $oldPlain -ne $plainText
    $last = if ($existing.msg.edited_timestamp) { $existing.msg.edited_timestamp } else { $existing.msg.timestamp }
    $oddsDue = $nowTW.Minute -lt 5 -and (ConvertTo-Utc $last) -lt $nowUtc.AddMinutes(-30)
    if (-not $structural -and -not $oddsDue) { return }
    $embed = New-ScheduleEmbed $day $todays (Get-ScheduleOdds $todays)
    $newText = ($embed.fields | ForEach-Object { "$($_.name)`n$($_.value)" }) -join "`n"
    if ($oldText -eq $newText) { return }

    foreach ($ev in $todays) {
        if (-not (Test-TeamsKnown $ev)) { continue }
        $a = $ev.match.teams[0].code; $b = $ev.match.teams[1].code
        $pattern = '`([^`]+)` \*\*' + [regex]::Escape($a) + '\*\*(?: \d+%)? vs (?:\d+% )?\*\*' + [regex]::Escape($b) + '\*\*'
        $old = [regex]::Match($oldText, $pattern); $new = [regex]::Match($newText, $pattern)
        if (-not $old.Success -or -not $new.Success -or $old.Groups[1].Value -eq $new.Groups[1].Value) { continue }
        $note = @{
            title = '⚠️ 賽程異動'
            description = "**$a** vs **$b** 改到 ``$($new.Groups[1].Value)``（原 ``$($old.Groups[1].Value)``）"
            color = Get-LeagueColor $ev
            footer = @{ text = "$($ev.league.name) · $($ev.blockName)" }
        }
        $chgKey = "chg-$($ev.match.id)-" + (ConvertTo-Utc $ev.startTime).ToString('MMddHHmm')
        if (-not ((Get-PostedKeys $cid) -contains $chgKey)) { Send-Embed $cid $note $chgKey -Silent:$silent }
    }
    Edit-Embed $cid $existing.id $embed $key
}

# matchId -> @{ code = % } for matches not yet started; a failed lookup just leaves that match without odds
function Get-ScheduleOdds($Todays) {
    $odds = @{}
    foreach ($ev in $Todays) {
        if ($ev.state -ne 'unstarted' -or -not (Test-TeamsKnown $ev)) { continue }
        try { $o = Get-MatchOdds $ev; if ($o) { $odds[$ev.match.id] = $o } } catch {}
    }
    $odds
}

function Get-StreamLinks($ev) {
    $links = @()
    try {
        $ed = Get-EventDetails $ev.match.id
        $yt = @($ed.streams) | Where-Object { $_.provider -eq 'youtube' -and $_.locale -eq 'zh-TW' } | Select-Object -First 1
        if ($yt) { $links += "[中文台 YouTube](https://www.youtube.com/watch?v=$($yt.parameter))" }
    } catch {}
    $links += "[LoL Esports](https://lolesports.com/live/$($ev.league.slug))"
    $links -join ' · '
}

# reminderMinutes before the scheduled start, once per match, while it is still unstarted
function Send-Reminders {
    $cid = $cfg.channels.results
    foreach ($ev in $events) {
        if ($ev.state -ne 'unstarted' -or -not (Test-TeamsKnown $ev)) { continue }
        $t = ConvertTo-Utc $ev.startTime
        if ($nowUtc -lt $t.AddMinutes(-$cfg.reminderMinutes) -or $nowUtc -gt $t.AddMinutes(20)) { continue }
        $key = "r-$($ev.match.id)"
        if ((Get-PostedKeys $cid) -contains $key) { continue }
        $a = $ev.match.teams[0].code; $b = $ev.match.teams[1].code
        $embed = @{
            title = "⏰ 即將開打：$a vs $b"
            description = "預定 ``$(Format-TW $t)`` 開始 · BO$($ev.match.strategy.count) · $($ev.blockName)`n📺 $(Get-StreamLinks $ev)"
            color = Get-LeagueColor $ev
            footer = @{ text = $ev.league.name }
        }
        Send-Embed $cid $embed $key -Silent:$silent
    }
}

# One card when each game loads into the livestats feed: the 5 lane matchups with champions
function Send-Lineups {
    $cid = $cfg.channels.results
    foreach ($ev in $events) {
        if ($ev.state -ne 'inProgress' -or (ConvertTo-Utc $ev.startTime).Ticks -lt $since) { continue }
        $m = $ev.match
        $n = [int]$m.teams[0].result.gameWins + [int]$m.teams[1].result.gameWins + 1   # game being played now
        $key = "l-$($m.id)-$n"
        if ((Get-PostedKeys $cid) -contains $key) { continue }
        $ed = Get-EventDetails $m.id
        $game = @($ed.match.games) | Where-Object { [int]$_.number -eq $n } | Select-Object -First 1
        if (-not $game) { continue }
        try { $w = Invoke-Api GET "$feed/window/$($game.id)" @{} $null } catch { continue }
        $meta = $w.gameMetadata
        if (-not $meta -or -not @($meta.blueTeamMetadata.participantMetadata).Count) { continue }

        $codeById = @{}
        foreach ($tm in @($ed.match.teams)) { $codeById["$($tm.id)"] = $tm.code }
        $blue = $codeById["$($meta.blueTeamMetadata.esportsTeamId)"]
        $red = $codeById["$($meta.redTeamMetadata.esportsTeamId)"]
        $lines = foreach ($role in $roles) {
            $p = @($meta.blueTeamMetadata.participantMetadata) | Where-Object role -eq $role | Select-Object -First 1
            $q = @($meta.redTeamMetadata.participantMetadata) | Where-Object role -eq $role | Select-Object -First 1
            $pn = "$($p.summonerName)" -replace '^\S+\s+', ''
            $qn = "$($q.summonerName)" -replace '^\S+\s+', ''
            "``$($roleNames[$role])`` **$pn**（$(Get-ChampionName $p.championId)） vs **$qn**（$(Get-ChampionName $q.championId)）"
        }
        $patch = ($meta.patchVersion -split '\.')[0..1] -join '.'
        $embed = @{
            title = "⚔️ 第 $n 局開打：$blue vs $red"
            description = "🔵 $blue（藍方） vs 🔴 $red（紅方） · 版本 $patch`n`n" + ($lines -join "`n")
            color = Get-LeagueColor $ev
            footer = @{ text = "$($ev.league.name) · $($ev.blockName)" }
        }
        Send-Embed $cid $embed $key -Silent:$silent
    }
}

# Posted in the odds channel once the Worlds final is over
function Send-ChampionCard {
    $cid = $cfg.channels.odds
    foreach ($ev in $events) {
        if ($ev.league.slug -ne $cfg.odds.league -or $ev.blockName -ne $cfg.pickem.finalBlock -or $ev.state -ne 'completed') { continue }
        if ((ConvertTo-Utc $ev.startTime).Ticks -lt $since) { continue }
        $key = "champ-$($ev.match.id)"
        if ((Get-PostedKeys $cid) -contains $key) { continue }
        $ta = $ev.match.teams[0]; $tb = $ev.match.teams[1]
        $w = if ($ta.result.outcome -eq 'win') { $ta } else { $tb }
        $embed = @{
            title = "🏆 $($ev.league.name) 冠軍：$($w.name)"
            description = "決賽 **$($ta.code)** $($ta.result.gameWins) – $($tb.result.gameWins) **$($tb.code)**`n恭喜 **$($w.name)** 奪冠！"
            color = Get-LeagueColor $ev
            footer = @{ text = "$($ev.league.name) · $($ev.blockName)" }
        }
        if ($w.image) { $embed.thumbnail = @{ url = $w.image } }
        Send-Embed $cid $embed $key -Silent:$silent
    }
}
