# Adds the Traditional Chinese YouTube VOD link to game cards (and BO1 summaries) once Riot publishes it.
# Only the message content is edited, so the embed and its stats image stay untouched. Dot-sourced by bot.ps1.

function Add-VodLinks {
    $cid = $cfg.channels.results
    foreach ($x in (Get-BotMessages $cid)) {
        # g-<match>-<game>-<a>-<b> game cards, s-<match> summaries (only BO1 ones get a link)
        if ($x.key -match '^g-(\d+)-(\d+)-') { $matchId = $Matches[1]; $n = [int]$Matches[2] }
        elseif ($x.key -match '^s-(\d+)$') { $matchId = $Matches[1]; $n = 1 }
        else { continue }
        if ("$($x.msg.content)".Contains('📼')) { continue }
        if ((ConvertTo-Utc $x.msg.timestamp) -lt $nowUtc.AddHours(-24)) { continue }

        $ed = Get-EventDetails $matchId
        if ($x.key -like 's-*' -and [int]$ed.match.strategy.count -ne 1) { continue }
        $game = @($ed.match.games) | Where-Object { [int]$_.number -eq $n } | Select-Object -First 1
        $vod = @($game.vods) | Where-Object { $_.provider -eq 'youtube' -and $_.locale -eq 'zh-TW' } | Select-Object -First 1
        if (-not $vod) { continue }

        # One video covers the whole broadcast; startMillis jumps to this game. <...> suppresses the preview.
        $at = [int]([double]$vod.startMillis / 1000)
        $content = "📼 [第 $n 局中文台重播](<https://www.youtube.com/watch?v=$($vod.parameter)&t=${at}s>)"
        if ($DryRun) { "[dry-run] vod $($x.key): $content"; continue }
        Invoke-Discord PATCH "/channels/$cid/messages/$($x.id)" @{ content = $content } | Out-Null
        $x.msg | Add-Member -NotePropertyName content -NotePropertyValue $content -Force
        "VOD $($x.key)"
    }
}
