$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
$dependency = (Get-Content -LiteralPath (Join-Path $packageRoot 'dependencies.json') -Raw | ConvertFrom-Json).'v4-core'
$libraryPath = Join-Path $packageRoot 'lib/v4-core'

function Invoke-GitChecked {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw "git failed with exit code $LASTEXITCODE" }
}

if (!(Test-Path -LiteralPath $libraryPath)) {
    Invoke-GitChecked clone --no-checkout --depth 1 $dependency.repository $libraryPath
    Invoke-GitChecked -C $libraryPath fetch --depth 1 origin $dependency.commit
    Invoke-GitChecked -C $libraryPath checkout --detach $dependency.commit
}
$actualRevision = & git -C $libraryPath rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $dependency.commit) {
    throw 'Existing v4-core checkout does not match dependencies.json; inspect it before changing revisions.'
}
Invoke-GitChecked -C $libraryPath submodule update --init --depth 1 lib/forge-std lib/openzeppelin-contracts lib/solmate
foreach ($submodule in $dependency.submodules.PSObject.Properties) {
    $revision = & git -C (Join-Path $libraryPath $submodule.Name) rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $revision -ne $submodule.Value) { throw "Dependency revision mismatch: $($submodule.Name)" }
}
Write-Output 'Pinned Solidity dependencies verified.'
