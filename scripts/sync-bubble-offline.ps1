param(
    [string]$BubbleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
)
$ErrorActionPreference = 'Stop'
$skinRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$assetRoot = Join-Path $skinRoot 'assets'
New-Item -ItemType Directory -Force -Path $assetRoot | Out-Null
foreach ($name in @('offline-installer.py', 'bootstrap-offline.tar.gz', 'initialize-dashboard.py')) {
    Copy-Item -LiteralPath (Join-Path $BubbleRoot "assets\$name") -Destination $assetRoot -Force
}
Copy-Item -LiteralPath (Join-Path $BubbleRoot 'assets\astrbot-startup.sh') -Destination (Join-Path $assetRoot 'bundled-component-installer.sh') -Force
$bootstrapText = [IO.File]::ReadAllText((Join-Path $BubbleRoot 'assets\astrbot-installer-bootstrap.sh')).Replace("`r`n", "`n")
$module = "-- Bootstrap mirrored from the Bubble asset; supports the same offline engine.`nreturn [==[`n" + $bootstrapText + "`n]==]`n"
[IO.File]::WriteAllText((Join-Path $skinRoot 'installer_bootstrap.lua'), $module, [Text.UTF8Encoding]::new($false))
Write-Host 'Synced the Bubble installer and bootstrap resources.'
