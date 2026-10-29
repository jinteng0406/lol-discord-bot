# Home-PC runner: runs bot.ps1 every minute while logged in. Started hidden at logon by run-hidden.vbs.
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$log = "$root\bot.log"

# Only one copy at a time
$mutex = New-Object Threading.Mutex($false, 'Global\DiscordLoLBot')
if (-not $mutex.WaitOne(0)) { exit }

while ($true) {
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }
    try {
        $out = & "$root\bot.ps1" 2>&1 | Out-String
        if ($out.Trim()) { Add-Content $log "$(Get-Date -Format s) $($out.Trim())" -Encoding UTF8 }
    } catch {
        Add-Content $log "$(Get-Date -Format s) ERROR $_" -Encoding UTF8
    }
    Start-Sleep -Seconds 60
}
