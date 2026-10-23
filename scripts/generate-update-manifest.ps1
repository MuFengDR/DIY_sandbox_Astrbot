$ErrorActionPreference = 'Stop'
$skinRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $skinRoot 'skin-update-manifest.json'
$main = [IO.File]::ReadAllText((Join-Path $skinRoot 'main.lua'))
$versionMatch = [regex]::Match($main, 'local\s+LUA_SCRIPT_VERSION\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) { throw 'Cannot read LUA_SCRIPT_VERSION from main.lua' }

# Runtime modules and resources are discovered instead of maintaining another
# hard-coded list. Development directories are never shipped to the phone.
$excludedRoots = @('scripts', 'local-package', 'keys')
$files = @(Get-ChildItem -LiteralPath $skinRoot -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($skinRoot.Length + 1).Replace('\', '/')
    $parts = $relative.Split('/')
    $hidden = @($parts | Where-Object { $_.StartsWith('.') }).Count -gt 0
    if (-not $hidden -and $parts[0] -notin $excludedRoots -and
        $_.Name -ne 'AGENTS.md' -and $relative -ne 'skin-update-manifest.json' -and
        ($parts.Length -gt 1 -or $_.Extension -eq '.lua' -or $_.Name -eq 'README.md')) {
        $relative
    }
} | Sort-Object)
if ($files.Count -eq 0 -or $files.Count -gt 512) { throw 'Invalid runtime file count' }
foreach ($required in @('main.lua', 'skin_updater.lua')) {
    if ($files -notcontains $required) { throw "Missing runtime file: $required" }
}
foreach ($path in $files) {
    if ($path.Length -gt 240 -or $path -cnotmatch '^[A-Za-z0-9_-][A-Za-z0-9._/-]*$') {
        throw "Unsupported update path: $path"
    }
}
$manifest = [ordered]@{
    format = 'astrbot-skin-update-v1'
    version = $versionMatch.Groups[1].Value
    files = $files
}
$json = ($manifest | ConvertTo-Json -Depth 4) + "`n"
[IO.File]::WriteAllText($manifestPath, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Generated: $manifestPath ($($files.Count) files)"
