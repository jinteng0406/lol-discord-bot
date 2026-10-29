# Creates the LoL category and channels in the Discord server.
#   .\setup.ps1 invite   -> print the bot invite URL
#   .\setup.ps1          -> create category + channels (skips if category already exists)
param([string]$Mode = 'create')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$api = 'https://discord.com/api/v10'

$token = (Get-Content "$root\.env" -Encoding UTF8 | Where-Object { $_ -match '^DISCORD_TOKEN=' }) -replace '^DISCORD_TOKEN=', ''
$token = "$token".Trim()
if (-not $token) { throw '.env has no DISCORD_TOKEN' }
$cfg = Get-Content "$root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json

# Permission bits
$P = @{
    ViewChannel = [int64]1 -shl 10; SendMessages = [int64]1 -shl 11; ManageMessages = [int64]1 -shl 13
    EmbedLinks = [int64]1 -shl 14; ManageChannels = [int64]1 -shl 4; ManageRoles = [int64]1 -shl 28
    Administrator = [int64]1 -shl 3; CreatePublicThreads = [int64]1 -shl 35
    CreatePrivateThreads = [int64]1 -shl 36; SendInThreads = [int64]1 -shl 38
}
$invitePerms = $P.ViewChannel + $P.SendMessages + $P.ManageMessages + $P.EmbedLinks + $P.ManageChannels +
    $P.ManageRoles + $P.CreatePublicThreads + $P.CreatePrivateThreads + $P.SendInThreads

function Invoke-Discord([string]$Method, [string]$Path, $Body) {
    $headers = @{ Authorization = "Bot $token"; 'User-Agent' = 'DiscordBot (local, 1.0)' }
    while ($true) {
        try {
            if ($null -ne $Body) {
                $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10 -Compress))
                $r = Invoke-RestMethod -Method $Method -Uri "$api$Path" -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8'
            } else {
                $r = Invoke-RestMethod -Method $Method -Uri "$api$Path" -Headers $headers
            }
            # PS 5.1 emits JSON arrays as one object; assigning then returning unrolls it
            return $r
        } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($resp -and [int]$resp.StatusCode -eq 429) {
                $wait = [double]$resp.Headers['Retry-After']; if (-not $wait) { $wait = 2 }
                Start-Sleep -Milliseconds ([int]($wait * 1000) + 250); continue
            }
            $detail = ''
            if ($resp) { $detail = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() }
            throw "$Method $Path failed: $($_.Exception.Message) $detail"
        }
    }
}

if ($Mode -eq 'invite') {
    $app = Invoke-Discord GET '/oauth2/applications/@me'
    "Bot: $($app.name)"
    "https://discord.com/oauth2/authorize?client_id=$($app.id)&scope=bot&permissions=$invitePerms"
    return
}

$me = Invoke-Discord GET '/users/@me'
$guilds = @(Invoke-Discord GET '/users/@me/guilds')
$guild = $guilds | Where-Object { $_.name -like "*$($cfg.guildName)*" } | Select-Object -First 1
if (-not $guild) { throw "Bot is not in a server matching '$($cfg.guildName)'. Joined: $(($guilds | ForEach-Object name) -join ', ')" }
$gid = $guild.id
"Server: $($guild.name) ($gid)"

$full = Invoke-Discord GET "/guilds/$gid"
$community = $full.features -contains 'COMMUNITY'
"Community enabled: $community"

$channels = @(Invoke-Discord GET "/guilds/$gid/channels")
$cat = $channels | Where-Object { $_.type -eq 4 -and $_.name -eq $cfg.category } | Select-Object -First 1
if ($cat) {
    "Category '$($cfg.category)' already exists - skipping creation."
    $channels = @($channels | Where-Object { $_.id -ne $cat.id })
} else {

$readOnlyType = if ($community) { 5 } else { 0 }
$everyoneDeny = $P.SendMessages + $P.CreatePublicThreads + $P.CreatePrivateThreads + $P.SendInThreads
$botAllow = $P.ViewChannel + $P.SendMessages + $P.EmbedLinks + $P.ManageMessages
$readOnlyOverwrites = @(
    @{ id = $gid; type = 0; allow = '0'; deny = "$everyoneDeny" },
    @{ id = $me.id; type = 1; allow = "$botAllow"; deny = '0' }
)

$cat = Invoke-Discord POST "/guilds/$gid/channels" @{ name = $cfg.category; type = 4 }
"Created category: $($cat.name)"
$created = $true
foreach ($c in @(
        @{ cfg = $cfg.chat; type = 0; ow = @() },
        @{ cfg = $cfg.schedule; type = $readOnlyType; ow = $readOnlyOverwrites },
        @{ cfg = $cfg.results; type = $readOnlyType; ow = $readOnlyOverwrites })) {
    $body = @{ name = $c.cfg.name; type = $c.type; parent_id = $cat.id; topic = $c.cfg.topic }
    if ($c.ow.Count) { $body.permission_overwrites = $c.ow }
    $ch = Invoke-Discord POST "/guilds/$gid/channels" $body
    "Created channel: $($ch.name) (type $($ch.type))"
}
}

# Move a newly created category to the top of the category list (re-runs keep the server's order)
if (-not $created) { return }
$cats = @($channels | Where-Object { $_.type -eq 4 } | Sort-Object position)
$order = @(@{ id = $cat.id; position = 0 })
$i = 1
foreach ($c in $cats) { $order += @{ id = $c.id; position = $i }; $i++ }
Invoke-Discord PATCH "/guilds/$gid/channels" $order | Out-Null
"Moved category to top"

$loose = @($channels | Where-Object { $_.type -ne 4 -and -not $_.parent_id })
if ($loose.Count) { "Note: $($loose.Count) channel(s) without a category still show above all categories: $(($loose | ForEach-Object name) -join ', ')" }

$admins = @($full.roles | Where-Object { ([int64]$_.permissions -band $P.Administrator) -and $_.name -ne '@everyone' -and -not $_.managed })
if ($admins.Count) { "Note: these roles have Administrator and can still post in read-only channels: $(($admins | ForEach-Object name) -join ', ')" }
