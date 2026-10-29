# Health DM to the server owner, run by the GitHub workflow after each pass.
#   -Status failed : DM once the poll workflow has had no successful run for alertAfterMinutes
#   -Status ok     : DM "recovered" if the last DM was an open alert
# Needs DISCORD_TOKEN, plus GH_TOKEN and GITHUB_REPOSITORY for -Status failed.
param([Parameter(Mandatory)][ValidateSet('failed', 'ok')][string]$Status)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$cfg = Get-Content "$root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$headers = @{ Authorization = "Bot $($env:DISCORD_TOKEN.Trim())"; 'User-Agent' = 'DiscordBot (local, 1.0)' }

function Invoke-Discord([string]$Method, [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "https://discord.com/api/v10$Path"; Headers = $headers; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Compress))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    $text = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest @p).RawContentStream.ToArray())
    if ($text) { $r = ConvertFrom-Json $text; return $r }
}

$dm = Invoke-Discord POST '/users/@me/channels' @{ recipient_id = $cfg.alertUserId }
$last = @(Invoke-Discord GET "/channels/$($dm.id)/messages?limit=1") | Select-Object -First 1
$open = $last -and "$($last.content)".StartsWith('⚠️')
$now = [DateTime]::UtcNow.AddHours(8).ToString('M/d HH:mm')

if ($Status -eq 'ok') {
    if ($open) { Invoke-Discord POST "/channels/$($dm.id)/messages" @{ content = "✅ LoL bot 已恢復正常（$now）" } | Out-Null; 'Sent recovery DM' }
    return
}

if ($open) { return }
$runs = gh run list --repo $env:GITHUB_REPOSITORY --workflow poll.yml --limit 30 --json conclusion,createdAt | ConvertFrom-Json
# Require the previous finished run to have failed too, so one blip after a long cron gap does not alert
$prev = @($runs | Where-Object { $_.conclusion } | Sort-Object { [DateTimeOffset]::Parse("$($_.createdAt)") } -Descending)[0]
if ($prev -and $prev.conclusion -eq 'success') { return }
$lastOk = @($runs | Where-Object { $_.conclusion -eq 'success' } | ForEach-Object { [DateTimeOffset]::Parse("$($_.createdAt)").UtcDateTime } | Sort-Object -Descending)[0]
if ($lastOk -and $lastOk -gt [DateTime]::UtcNow.AddMinutes(-$cfg.alertAfterMinutes)) { return }

$err = if (Test-Path "$root\last-error.txt") { (Get-Content "$root\last-error.txt" -Raw -Encoding UTF8).Trim() } else { '(沒有錯誤訊息)' }
if ($err.Length -gt 1500) { $err = $err.Substring(0, 1500) + '…' }
$msg = "⚠️ LoL bot 已超過 $($cfg.alertAfterMinutes) 分鐘沒有成功執行（$now）`n``````$err```````n詳情：https://github.com/$($env:GITHUB_REPOSITORY)/actions"
Invoke-Discord POST "/channels/$($dm.id)/messages" @{ content = $msg } | Out-Null
'Sent failure DM'
