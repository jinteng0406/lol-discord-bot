# One-off server re-layout (2026-10-29): category order, channel moves/order and unified names.
# Undo data: channels-backup-2026-10-29.json.  -DryRun prints the plan only.
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$gid = '1546011524680777798'
$tok = ((Get-Content "$root\.env" -Encoding UTF8) -replace '^DISCORD_TOKEN=', '').Trim()
$h = @{ Authorization = "Bot $tok"; 'User-Agent' = 'DiscordBot (local, 1.0)' }

function Send([string]$Method, [string]$Path, $Body) {
    if ($DryRun) { "[dry-run] $Method $Path $(ConvertTo-Json -InputObject $Body -Compress -Depth 5)"; return }
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Compress -Depth 5))
            Invoke-WebRequest -UseBasicParsing -Method $Method "https://discord.com/api/v10$Path" -Headers $h -Body $bytes -ContentType 'application/json; charset=utf-8' | Out-Null
            return
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 429) {
                $wait = 3; try { $wait = [double](ConvertFrom-Json $_.ErrorDetails.Message).retry_after } catch {}
                Start-Sleep -Milliseconds ([int]($wait * 1000) + 300); continue
            }
            throw "$Method $Path failed: $($_.Exception.Message) $($_.ErrorDetails.Message)"
        }
    }
}

$cat = @{ text = '1546011525985337354'; voice = '1546011525985337355'; lol = '1565223110322683924'; study = '1546023207465910333'; er = '1546022331674140753' }

# Category order and names
$categories = @(
    @{ id = $cat.text; name = '💬 文字頻道' },
    @{ id = $cat.voice; name = '🔊 語音頻道' },
    @{ id = $cat.lol; name = '🎮 英雄聯盟' },
    @{ id = $cat.study; name = '📚 STUDY' },
    @{ id = $cat.er; name = '💍 ELDEN RING 攻略' }
)

# Channels in display order per category (text channels list before voice anyway)
$layout = [ordered]@{
    $cat.text  = @(
        @('1546011525985337356', '🏠｜𝑳𝑶𝑩𝑩𝒀'),
        @('1550029364698292274', '📢｜𝑨𝑰機器人注意事項'),
        @('1550054502181240832', '🤖｜𝑭𝑨𝑲𝑬𝑹聊天室'))
    $cat.voice = @(
        @('1546026331614224414', '🔊｜別的遊戲房'),
        @('1546011525985337357', '💍｜Elden Ring'),
        @('1546023970267074690', '🔫｜VALORANT'),
        @('1558316994648997960', '🐉｜Monster Hunter'),
        @('1546017759320735815', '💤｜掛機房'))
    $cat.lol   = @(
        @('1565223113950630051', '💬｜𝑳𝑶𝑳聊天'),
        @('1565223116832116876', '📅｜每日賽程'),
        @('1565223118664896572', '📊｜賽況更新'),
        @('1565228423238918245', '🏆｜奪冠機率'),
        @('1565235782908772422', '🎯｜競猜'),
        @('1563247570594308188', '🎉｜觀賽派對'),
        @('1546171439588180079', '🎲｜ARAM'))
    $cat.study = @(
        @('1547856453224636446', '💼｜社畜'),
        @('1546017570598031440', '📖｜讀書房'))
    $cat.er    = @(
        @('1546015480899436654', '🌐｜攻略網頁'),
        @('1546359088651173888', '🗺️｜跑圖攻略'),
        @('1549992742199894026', '🗡️｜武器攻略'),
        @('1548719609123704862', '👹｜𝑩𝒐𝒔𝒔攻略'),
        @('1548162850382418021', '👴｜老大哥攻略'),
        @('1546015070457434122', '🧩｜𝑴𝑶𝑫擺放區'),
        @('1546014892341993523', '🛡️｜流浪騎士'),
        @('1546014755754348554', '🏯｜武士'),
        @('1546021065636057158', '🔭｜觀星者'),
        @('1546021184704086136', '🕯️｜密使'),
        @('1546021292665348146', '🔮｜預言家'),
        @('1546021364484538378', '⛓️｜囚犯'),
        @('1546021493190959185', '🤺｜劍士'),
        @('1546021747533418576', '🪓｜勇者'),
        @('1546021804534009876', '🥷｜盜賊'))
}

# 1) Category order
$order = @(for ($i = 0; $i -lt $categories.Count; $i++) { @{ id = $categories[$i].id; position = $i } })
Send PATCH "/guilds/$gid/channels" $order
'Category order set'

# 2) Parents: Discord allows only one parent change per bulk call, so move those channels one by one
$r = Invoke-WebRequest -UseBasicParsing "https://discord.com/api/v10/guilds/$gid/channels" -Headers $h
$current = @{}
foreach ($c in @([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json | ForEach-Object { $_ })) { $current[$c.id] = "$($c.parent_id)" }
foreach ($parent in $layout.Keys) {
    foreach ($c in $layout[$parent]) {
        if ($current[$c[0]] -ne $parent) { Send PATCH "/channels/$($c[0])" @{ parent_id = $parent }; "moved $($c[0]) -> $parent" }
    }
}

# 3) Order inside each category
$moves = @()
foreach ($parent in $layout.Keys) {
    $i = 0
    foreach ($c in $layout[$parent]) { $moves += @{ id = $c[0]; position = $i }; $i++ }
}
Send PATCH "/guilds/$gid/channels" $moves
'Channels ordered'

# 4) Names
foreach ($c in $categories) { Send PATCH "/channels/$($c.id)" @{ name = $c.name }; "renamed category -> $($c.name)" }
foreach ($parent in $layout.Keys) {
    foreach ($c in $layout[$parent]) { Send PATCH "/channels/$($c[0])" @{ name = $c[1] }; "renamed -> $($c[1])" }
}

# 5) Topics that point at the LoL chat: use a channel mention so they follow future renames
$chat = '<#1565223113950630051>'
Send PATCH '/channels/1565223116832116876' @{ topic = "每日賽程預告，討論請至 $chat" }
Send PATCH '/channels/1565223118664896572' @{ topic = "比賽結果與即時比分，討論請至 $chat" }
'Topics updated'
