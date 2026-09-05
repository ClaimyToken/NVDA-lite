$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
$siteRoot = Split-Path -Parent $packageRoot
$outputDirectory = Join-Path $siteRoot 'public/contracts'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$sourceItems = @('src', 'test', 'script', 'scripts', 'config', 'README.md', 'foundry.toml', 'dependencies.json', '.env.example') |
    ForEach-Object { Join-Path $packageRoot $_ }
Compress-Archive -LiteralPath $sourceItems -DestinationPath (Join-Path $outputDirectory 'nvda-liquidity-source.zip') -Force
Write-Output 'Packaged source and tests without build output, dependencies, or credentials.'
