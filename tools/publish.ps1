<#
.SYNOPSIS
    Pushes SuperAlarm to GitHub so the macOS runner can build the .ipa.

.DESCRIPTION
    The app can be written on Windows but not compiled here — Xcode, the iOS
    SDK and codesign only exist on macOS. GitHub's macOS runners are free and
    unlimited on public repositories, so this pushes the repo and points you at
    the build.

    Create an empty repository at https://github.com/new first. Do not add a
    README, .gitignore or licence — this repo already has its own history.

.EXAMPLE
    .\tools\publish.ps1 -RepoUrl https://github.com/yourname/SuperAlarm.git
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "e.g. https://github.com/you/SuperAlarm.git")]
    [string]$RepoUrl
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

Write-Host "Running the local checks first..." -ForegroundColor Cyan
foreach ($check in @('preflight.js', 'symbol-check.js', 'typecheck-lite.js')) {
    node "tools/$check" | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) {
        throw "tools/$check failed. Fix that before pushing."
    }
}

if (-not (git rev-parse --git-dir 2>$null)) {
    throw "This is not a git repository."
}

$dirty = git status --porcelain
if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    Write-Host "`nUncommitted changes found; committing them." -ForegroundColor Yellow
    git add -A
    git commit -m "Local changes before publishing"
}

if (git remote | Select-String -Pattern '^origin$' -Quiet) {
    Write-Host "`nUpdating existing 'origin' remote." -ForegroundColor Yellow
    git remote set-url origin $RepoUrl
} else {
    git remote add origin $RepoUrl
}

git branch -M main

Write-Host "`nPushing to $RepoUrl" -ForegroundColor Cyan
Write-Host "A browser sign-in may appear the first time." -ForegroundColor DarkGray
git push -u origin main

# Turn the clone URL into a web URL for the Actions tab.
$web = $RepoUrl -replace '\.git$', ''
Write-Host "`nPushed." -ForegroundColor Green
Write-Host "The build starts automatically. Watch it here:" -ForegroundColor Green
Write-Host "  $web/actions" -ForegroundColor White
Write-Host ""
Write-Host "When it finishes, download the 'SuperAlarm-ipa' artifact from that run."
Write-Host "Then sign and install it with Sideloadly over USB - see README.md."
Write-Host ""
Write-Host "Paste $web/actions back into the chat and I'll read the build myself." -ForegroundColor Cyan
