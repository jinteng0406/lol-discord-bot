# One pass of the LoL esports poster: daily schedule, reminders, lineups, results, pick'em and title odds.
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

# This bot's recent messages in a channel with their footer keys; cached per pass and updated as we post
function Get-BotMessages([string]$ChannelId) {
    if (-not $script:msgCache) { $script:msgCache = @{} }
    if (-not $script:msgCache.ContainsKey($ChannelId)) {
        $list = New-Object System.Collections.Generic.List[object]
        if ($token) {
            if (-not $script:botId) { $script:botId = (Invoke-Discord GET '/users/@me').id }
            foreach ($m in @(Invoke-Discord GET "/channels/$ChannelId/messages?limit=100")) {
                if ($m.author.id -ne $script:botId) { continue }
                $key = $null
                foreach ($e in @($m.embeds)) { if ($e.footer.text -match '#(\S+)$') { $key = $Matches[1] } }
                $list.Add([pscustomobject]@{ id = $m.id; key = $key; msg = $m })
            }
        }
        $script:msgCache[$ChannelId] = $list
    }
    , $script:msgCache[$ChannelId]
}

function Get-PostedKeys([string]$ChannelId) {
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($x in (Get-BotMessages $ChannelId)) { if ($x.key) { $keys.Add($x.key) } }
    , $keys
}

function Find-BotMessage([string]$ChannelId, [string]$Key) {
    (Get-BotMessages $ChannelId) | Where-Object { $_.key -eq $Key } | Select-Object -First 1
}

# Posts an embed tagged with $Key; the created message is left in $script:lastPosted
function Send-Embed([string]$ChannelId, $Embed, [string]$Key, [switch]$Silent, [byte[]]$Png) {
    $Embed.footer = @{ text = "$($Embed.footer.text) · #$Key" }
    $body = @{ embeds = @($Embed) }
    if ($Silent) { $body.flags = 4096 }  # SUPPRESS_NOTIFICATIONS
    if ($Png) { $body.attachments = @(@{ id = 0; filename = 'stats.png' }) }
    if ($DryRun) {
        "[dry-run] -> $ChannelId silent=$([bool]$Silent)"
        ConvertTo-Json -InputObject $body -Depth 10
        if ($Png) { [IO.File]::WriteAllBytes("$root\stats-preview-$Key.png", $Png) }
        $script:lastPosted = $null
        return
    }
    if ($Png) {
        $msg = Invoke-DiscordFiles POST "/channels/$ChannelId/messages" $body @{ 'stats.png' = $Png }
    } else {
        $msg = Invoke-Discord POST "/channels/$ChannelId/messages" $body
    }
    (Get-BotMessages $ChannelId).Add([pscustomobject]@{ id = $msg.id; key = $Key; msg = $msg })
    $script:lastPosted = $msg
    $script:postedAny = $true
    "Posted $Key"
}

# Replaces the embed of one of our messages (edits never notify)
function Edit-Embed([string]$ChannelId, [string]$MessageId, $Embed, [string]$Key) {
    $Embed.footer = @{ text = "$($Embed.footer.text) · #$Key" }
    if ($DryRun) {
        "[dry-run] edit $MessageId -> $ChannelId"
        ConvertTo-Json -InputObject @{ embeds = @($Embed) } -Depth 10
        return
    }
    Invoke-Discord PATCH "/channels/$ChannelId/messages/$MessageId" @{ embeds = @($Embed) } | Out-Null
    "Edited $Key"
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
function Test-TeamsKnown($ev) { -not (@($ev.match.teams) | Where-Object { -not $_.code -or $_.code -eq 'TBD' }) }

# A failing section is recorded and skipped so the others still run; any failure makes the pass exit 1
$script:problems = New-Object System.Collections.Generic.List[string]
function Invoke-Section([string]$Name, [scriptblock]$Block) {
    try { & $Block } catch { $script:problems.Add("${Name}: $_"); "$Name failed: $_" }
}

# Read as UTF-8 explicitly: PS 5.1 would parse a BOM-less file as ANSI and break the Chinese strings
foreach ($part in 'odds.ps1', 'stats.ps1', 'live.ps1', 'pickem.ps1') {
    . ([ScriptBlock]::Create((Get-Content "$root\$part" -Raw -Encoding UTF8)))
}

try {
    $events = Get-Events
} catch {
    Set-Content "$root\last-error.txt" "schedule: $_" -Encoding UTF8
    throw
}
$silent = $nowTW.Hour -ge $cfg.silentFromHourTW -and $nowTW.Hour -lt $cfg.silentToHourTW
$since = [Math]::Max((ConvertTo-Utc $cfg.postResultsSince).Ticks, $nowUtc.AddHours(-$cfg.resultsLookbackHours).Ticks)

Invoke-Section 'schedule' { Update-Schedule }
Invoke-Section 'reminders' { Send-Reminders }
Invoke-Section 'lineups' { Send-Lineups }

# ---- Results: one card per finished game, one summary per finished series ----
Invoke-Section 'results' {
    $live = @($events | Where-Object {
            ($_.state -eq 'inProgress' -or $_.state -eq 'completed') -and (ConvertTo-Utc $_.startTime).Ticks -ge $since })
    if (-not $live.Count) { return }
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
            $png = $null
            if ($w) {
                $png = Add-GameStatsIfReady $embed $id $n $w.code
                if ($png -is [string]) { continue }   # feed still live: post next pass with stats
            }
            Send-Embed $cfg.channels.results $embed "g-$id-$n-$a-$b" -Silent:$silent -Png $png
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
            $png = $null
            if ($bo -eq 1 -and $w) {
                # BO1 has no game card, so its stats go on the summary
                $png = Add-GameStatsIfReady $embed $id 1 $w.code
                if ($png -is [string]) { continue }
            }
            Send-Embed $cfg.channels.results $embed "s-$id" -Silent:$silent -Png $png
        }
    }
}

if ($cfg.channels.pickem) { Invoke-Section 'pickem' { Update-Pickem } }
if ($cfg.channels.odds) {
    Invoke-Section 'champion' { Send-ChampionCard }
    Invoke-Section 'odds' { Update-OddsMessage -Force:([bool]$script:postedAny) }
}

if ($script:problems.Count) {
    Set-Content "$root\last-error.txt" ($script:problems -join "`n") -Encoding UTF8
    exit 1
}
