$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $packageRoot '.env'
if (!(Test-Path -LiteralPath $envPath)) {
    throw "Missing $envPath. Copy .env.example to .env and fill the required values."
}

$loaded = 0
foreach ($rawLine in Get-Content -LiteralPath $envPath) {
    $line = $rawLine.Trim()
    if (!$line -or $line.StartsWith('#')) { continue }
    $parts = $line.Split('=', 2)
    if ($parts.Count -ne 2) { throw "Invalid .env line: $rawLine" }
    $name = $parts[0].Trim()
    $value = $parts[1].Trim()
    if ($name -notmatch '^[A-Z][A-Z0-9_]*$') { throw "Invalid environment variable name: $name" }
    if (!$value) { continue }
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    $loaded++
}
Write-Output "Loaded $loaded non-empty contract settings into this PowerShell process."
