# One pass of the LoL esports poster: daily schedule (once a day) + per-game / per-series results.
# Dedup state lives in Discord itself: every bot embed carries a key in its footer ("#<key>"),
# so the GitHub Actions runner and the home-PC runner never post the same thing twice.
#   .\bot.ps1                          live pass
#   .\bot.ps1 -DryRun                  print embeds instead of posting
#   .\bot.ps1 -Fixture f.json -Now 2026-10-29T03:00:00Z -DryRun   offline test
param([switch]$DryRun, [string]$Fixture, [string]$Now)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$discordApi = 'https://discord.com/api/v10'
$cfg = Get-Content "$root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$token = $env:DISCORD_TOKEN
if (-not $token -and (Test-Path "$root\.env")) {
    $token = (Get-Content "$root\.env" -Encoding UTF8 | Where-Object { $_ -match '^DISCORD_TOKEN=' }) -replace '^DISCORD_TOKEN=', ''
}
$token = "$token".Trim()
if (-not $token -and -not $DryRun) { throw 'No DISCORD_TOKEN' }
$apiKey = $env:LOLESPORTS_API_KEY
if (-not $apiKey) { $apiKey = $cfg.lolesportsApiKey }

$nowUtc = if ($Now) { [DateTimeOffset]::Parse($Now, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } else { [DateTime]::UtcNow }
$nowTW = $nowUtc.AddHours(8)

function ConvertTo-Utc($t) {
    # PS 7 ConvertFrom-Json already turns ISO strings into DateTime; PS 5.1 leaves them as strings
    if ($t -is [DateTime]) { return $t.ToUniversalTime() }
    return [DateTimeOffset]::Parse($t, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Invoke-Api([string]$Method, [string]$Uri, [hashtable]$Headers, $Body, [string]$ContentType) {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true }
        if ($Body -is [byte[]]) {
            $p.Body = $Body
            $p.ContentType = $ContentType
        } elseif ($null -ne $Body) {
            $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10 -Compress))
            $p.ContentType = 'application/json; charset=utf-8'
        }
        try {
            # Decode as UTF-8 ourselves: PS 5.1 falls back to Latin-1 when the response has no charset
            $resp = Invoke-WebRequest @p
            $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
            if (-not $text) { return }
            $r = ConvertFrom-Json $text
            # PS 5.1 emits JSON arrays as one object; assigning then returning unrolls it
            return $r
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 429) {
                $wait = 2
                try { $wait = [double](ConvertFrom-Json $_.ErrorDetails.Message).retry_after } catch {}
                Start-Sleep -Milliseconds ([int]($wait * 1000) + 250)
                continue
            }
            throw "$Method $Uri failed ($code): $($_.Exception.Message) $($_.ErrorDetails.Message)"
        }
    }
    throw "$Method $Uri still rate limited"
}

function Invoke-Discord([string]$Method, [string]$Path, $Body, [string]$ContentType) {
    Invoke-Api $Method "$discordApi$Path" @{ Authorization = "Bot $token"; 'User-Agent' = 'DiscordBot (local, 1.0)' } $Body $ContentType
}

# Message with file attachments: multipart/form-data with payload_json + files[n]
function Invoke-DiscordFiles([string]$Method, [string]$Path, $Payload, [hashtable]$Files) {
    $boundary = [Guid]::NewGuid().ToString('N')
    $ms = New-Object IO.MemoryStream
    $write = { param($s) $b = [Text.Encoding]::UTF8.GetBytes($s); $ms.Write($b, 0, $b.Length) }
    & $write "--$boundary`r`nContent-Disposition: form-data; name=`"payload_json`"`r`nContent-Type: application/json`r`n`r`n"
    & $write (ConvertTo-Json -InputObject $Payload -Depth 10 -Compress)
    $i = 0
    foreach ($name in $Files.Keys) {
        & $write "`r`n--$boundary`r`nContent-Disposition: form-data; name=`"files[$i]`"; filename=`"$name`"`r`nContent-Type: application/octet-stream`r`n`r`n"
        $ms.Write($Files[$name], 0, $Files[$name].Length)
        $i++
    }
    & $write "`r`n--$boundary--`r`n"
    Invoke-Discord $Method $Path $ms.ToArray() "multipart/form-data; boundary=$boundary"
}

# Footer keys of this bot's recent messages in a channel
function Get-PostedKeys([string]$ChannelId) {
    $keys = New-Object System.Collections.Generic.List[string]
    if (-not $token) { return , $keys }
    if (-not $script:botId) { $script:botId = (Invoke-Discord GET '/users/@me').id }
    foreach ($m in @(Invoke-Discord GET "/channels/$ChannelId/messages?limit=100")) {
        if ($m.author.id -ne $script:botId) { continue }
        foreach ($e in @($m.embeds)) {
            if ($e.footer.text -match '#(\S+)$') { $keys.Add($Matches[1]) }
        }
    }
    return , $keys
}

function Send-Embed([string]$ChannelId, $Embed, [string]$Key, [switch]$Silent) {
    $Embed.footer = @{ text = "$($Embed.footer.text) · #$Key" }
    $body = @{ embeds = @($Embed) }
    if ($Silent) { $body.flags = 4096 }  # SUPPRESS_NOTIFICATIONS
    if ($DryRun) {
        "[dry-run] -> $ChannelId silent=$([bool]$Silent)"
        ConvertTo-Json -InputObject $body -Depth 10
        return
    }
    Invoke-Discord POST "/channels/$ChannelId/messages" $body | Out-Null
    $script:postedAny = $true
    "Posted $Key"
}

function Get-Events {
    if ($Fixture) {
        $j = Get-Content $Fixture -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        if (-not $apiKey) { throw 'No lolesports API key (config lolesportsApiKey or env LOLESPORTS_API_KEY)' }
        $ids = ($cfg.leagues.PSObject.Properties | ForEach-Object { $_.Value.id }) -join ','
        $j = Invoke-Api GET "https://esports-api.lolesports.com/persisted/gw/getSchedule?hl=zh-TW&leagueId=$ids" @{ 'x-api-key' = $apiKey } $null
    }
    $slugs = @($cfg.leagues.PSObject.Properties.Name)
    @($j.data.schedule.events | Where-Object { $_.type -eq 'match' -and $slugs -contains $_.league.slug })
}

function Get-LeagueColor($ev) { [int]$cfg.leagues.($ev.league.slug).color }
function Format-TW([DateTime]$utc) { $utc.AddHours(8).ToString('HH:mm') }

. "$root\odds.ps1"

$events = Get-Events
$silent = $nowTW.Hour -ge $cfg.silentFromHourTW -and $nowTW.Hour -lt $cfg.silentToHourTW

# ---- Daily schedule: window is [today 10:00 TW, tomorrow 10:00 TW) ----
if ($nowTW.Hour -ge $cfg.scheduleHourTW) {
    $day = $nowTW.Date
    $key = 'sched-' + $day.ToString('yyyy-MM-dd')
    $winStart = $day.AddHours($cfg.scheduleHourTW - 8)   # back to UTC
    $winEnd = $winStart.AddDays(1)
    $todays = @($events | Where-Object { $t = ConvertTo-Utc $_.startTime; $t -ge $winStart -and $t -lt $winEnd } |
        Sort-Object { ConvertTo-Utc $_.startTime })
    if ($todays.Count -and -not ((Get-PostedKeys $cfg.channels.schedule) -contains $key)) {
        $fields = @()
        foreach ($g in ($todays | Group-Object { $_.league.name })) {
            $lines = foreach ($ev in $g.Group) {
                $t = ConvertTo-Utc $ev.startTime
                $time = Format-TW $t
                if ($t.AddHours(8).Date -gt $day) { $time += '（隔日）' }
                $a = $ev.match.teams[0].code; $b = $ev.match.teams[1].code
                "``$time`` **$a** vs **$b** · BO$($ev.match.strategy.count) · $($ev.blockName)"
            }
            $fields += @{ name = $g.Name; value = ($lines -join "`n"); inline = $false }
        }
        $dow = '日一二三四五六'[[int]$day.DayOfWeek]
        $embed = @{
            title  = "📅 $($day.ToString('M/d'))（週$dow）賽程"
            description = '時間為台灣時間，涵蓋今天 10:00 到明天 10:00'
            color  = Get-LeagueColor $todays[0]
            fields = $fields
            footer = @{ text = 'LoL Esports' }
        }
        Send-Embed $cfg.channels.schedule $embed $key
    }
}

# ---- Results: one card per finished game, one summary per finished series ----
$since = [Math]::Max((ConvertTo-Utc $cfg.postResultsSince).Ticks, $nowUtc.AddHours(-$cfg.resultsLookbackHours).Ticks)
$live = @($events | Where-Object {
        ($_.state -eq 'inProgress' -or $_.state -eq 'completed') -and (ConvertTo-Utc $_.startTime).Ticks -ge $since })
if ($live.Count) {
    $posted = Get-PostedKeys $cfg.channels.results
    foreach ($ev in $live) {
        $m = $ev.match; $id = $m.id
        $ta = $m.teams[0]; $tb = $m.teams[1]
        $a = [int]$ta.result.gameWins; $b = [int]$tb.result.gameWins
        $bo = [int]$m.strategy.count
        $color = Get-LeagueColor $ev
        $footer = "$($ev.league.name) · $($ev.blockName)"

        # Last game card we posted for this match: key g-<id>-<n>-<a>-<b>
        $lastN = 0; $la = 0; $lb = 0
        foreach ($k in $posted) {
            if ($k -match "^g-$id-(\d+)-(\d+)-(\d+)$" -and [int]$Matches[1] -gt $lastN) {
                $lastN = [int]$Matches[1]; $la = [int]$Matches[2]; $lb = [int]$Matches[3]
            }
        }
        $n = $a + $b
        # A series that finished while we missed several games only gets the summary card
        $caughtUpLate = $ev.state -eq 'completed' -and $n - $lastN -gt 1
        if ($bo -gt 1 -and $n -gt $lastN -and -not $caughtUpLate) {
            if ($n - $lastN -eq 1) {
                $w = if ($a -gt $la) { $ta } else { $tb }
                $title = "第 $n 局：$($w.code) 獲勝"
            } else {
                $w = $null
                $title = '比分更新'
            }
            $embed = @{
                title = $title
                description = "**$($ta.code)** $a – $b **$($tb.code)**　（BO$bo）"
                color = $color
                footer = @{ text = $footer }
            }
            if ($w -and $w.image) { $embed.thumbnail = @{ url = $w.image } }
            Send-Embed $cfg.channels.results $embed "g-$id-$n-$a-$b" -Silent:$silent
        }

        if ($ev.state -eq 'completed' -and -not ($posted -contains "s-$id")) {
            $w = if ($ta.result.outcome -eq 'win') { $ta } elseif ($tb.result.outcome -eq 'win') { $tb } else { $null }
            $title = if ($w) { "🏆 $($w.name) 拿下比賽" } else { '比賽結束' }
            $desc = "**$($ta.code)** $a – $b **$($tb.code)**　（BO$bo）"
            if ($ta.record -and $tb.record) {
                $desc += "`n戰績：$($ta.code) $($ta.record.wins)-$($ta.record.losses)　$($tb.code) $($tb.record.wins)-$($tb.record.losses)"
            }
            if ($ev.league.slug -eq $cfg.odds.league) {
                try { $line = Get-OddsChangeLine @($ta.code, $tb.code) (ConvertTo-Utc $ev.startTime); if ($line) { $desc += "`n$line" } }
                catch { "odds line failed: $_" }
            }
            $embed = @{ title = $title; description = $desc; color = $color; footer = @{ text = $footer } }
            if ($w -and $w.image) { $embed.thumbnail = @{ url = $w.image } }
            Send-Embed $cfg.channels.results $embed "s-$id" -Silent:$silent
        }
    }
}

# ---- Worlds title odds (pinned message); never let it break the results above ----
if ($cfg.channels.odds) {
    try { Update-OddsMessage -Force:([bool]$script:postedAny) } catch { "odds update failed: $_" }
}
