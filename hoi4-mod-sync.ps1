param(
    [ValidateSet("status", "setup-link", "sync-copy", "check-up-to-date", "cleanup-old")]
    [string]$Mode = "status",
    [string]$RepoPath = $PSScriptRoot,
    [string]$ModName = "",
    [string]$Hoi4ModDir = (Join-Path $env:USERPROFILE "Documents\Paradox Interactive\Hearts of Iron IV\mod")
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ModName)) {
    $ModName = Split-Path -Path $RepoPath -Leaf
}

$ModPath = Join-Path $Hoi4ModDir $ModName
$LauncherModFile = Join-Path $Hoi4ModDir ("{0}.mod" -f $ModName)
$LegacyModName = "GMFU-DEV"
$LegacyModPath = Join-Path $Hoi4ModDir $LegacyModName
$LegacyLauncherModFile = Join-Path $Hoi4ModDir ("{0}.mod" -f $LegacyModName)

function Write-LauncherModFile {
    param(
        [string]$Path,
        [string]$Name
    )

    $content = @"
version="1"
tags={
    "Alternative History"
}
name="$Name"
supported_version="*"
path="mod/$Name"
"@

    Set-Content -Path $Path -Value $content -Encoding UTF8
}

function Get-LinkState {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return "missing"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return "reparse"
    }

    return "folder"
}

function Get-NormalizedPath {
    param([string]$Path)

    try {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    catch {
        return [IO.Path]::GetFullPath($Path)
    }
}

if (-not (Test-Path $Hoi4ModDir)) {
    throw "HOI4 mod directory not found: $Hoi4ModDir"
}

switch ($Mode) {
    "status" {
        $state = Get-LinkState -Path $ModPath
        Write-Host "Repo path: $RepoPath"
        Write-Host "HOI4 mod dir: $Hoi4ModDir"
        Write-Host "Target mod path: $ModPath"

        if ($state -eq "missing") {
            Write-Host "Status: missing"
        }
        elseif ($state -eq "reparse") {
            $item = Get-Item -LiteralPath $ModPath -Force
            Write-Host "Status: live link active"
            Write-Host "Link type: $($item.LinkType)"
            Write-Host "Target: $($item.Target)"
            Write-Host "Live-link mode means edits in the repo are already instant."
        }
        else {
            Write-Host "Status: real folder copy"
            Write-Host "Manual sync needed after changes (run with -Mode sync-copy)."
        }

        if (Test-Path $LauncherModFile) {
            Write-Host "Launcher file: found at $LauncherModFile"
        }
        else {
            Write-Host "Launcher file: missing ($LauncherModFile)"
        }
    }

    "setup-link" {
        if (-not (Test-Path $RepoPath)) {
            throw "Repo path not found: $RepoPath"
        }

        if (Test-Path $ModPath) {
            Remove-Item -LiteralPath $ModPath -Recurse -Force
        }

        New-Item -ItemType Junction -Path $ModPath -Target $RepoPath | Out-Null
        Write-LauncherModFile -Path $LauncherModFile -Name $ModName

        Write-Host "Live link created: $ModPath -> $RepoPath"
        Write-Host "Launcher descriptor ensured: $LauncherModFile"
        Write-Host "You now get automatic updates with no copy step."
    }

    "sync-copy" {
        if (-not (Test-Path $RepoPath)) {
            throw "Repo path not found: $RepoPath"
        }

        $state = Get-LinkState -Path $ModPath
        if ($state -eq "reparse") {
            Remove-Item -LiteralPath $ModPath -Recurse -Force
            New-Item -ItemType Directory -Path $ModPath | Out-Null
        }
        elseif ($state -eq "missing") {
            New-Item -ItemType Directory -Path $ModPath | Out-Null
        }

        $args = @(
            '"' + $RepoPath + '"'
            '"' + $ModPath + '"'
            '/MIR'
            '/XD', '.git', '.vscode'
        )

        $cmd = "robocopy " + ($args -join ' ')
        Write-Host "Running: $cmd"
        cmd.exe /c $cmd | Out-Host

        $exitCode = $LASTEXITCODE
        if ($exitCode -ge 8) {
            throw "robocopy failed with exit code $exitCode"
        }

        Write-LauncherModFile -Path $LauncherModFile -Name $ModName
        Write-Host "Copy sync complete (upload-safe folder mode)."
        Write-Host "Tip: run -Mode setup-link afterward to go back to instant live-link mode."
    }

    "check-up-to-date" {
        if (-not (Test-Path $RepoPath)) {
            throw "Repo path not found: $RepoPath"
        }

        $state = Get-LinkState -Path $ModPath

        if ($state -eq "missing") {
            Write-Host "Not up to date: target mod folder is missing ($ModPath)."
            exit 2
        }

        if ($state -eq "reparse") {
            $item = Get-Item -LiteralPath $ModPath -Force
            $repoNorm = Get-NormalizedPath -Path $RepoPath
            $targetNorm = Get-NormalizedPath -Path ([string]$item.Target)

            if ($repoNorm -ieq $targetNorm) {
                Write-Host "Up to date: live link points to this repo."
                exit 0
            }

            Write-Host "Not up to date: live link points somewhere else."
            Write-Host "Expected: $repoNorm"
            Write-Host "Actual:   $targetNorm"
            exit 2
        }

        $args = @(
            '"' + $RepoPath + '"'
            '"' + $ModPath + '"'
            '/MIR'
            '/L'
            '/NJH'
            '/NJS'
            '/NDL'
            '/NFL'
            '/NP'
            '/XD', '.git', '.vscode'
        )

        $cmd = "robocopy " + ($args -join ' ')
        cmd.exe /c $cmd | Out-Null

        $exitCode = $LASTEXITCODE
        if ($exitCode -ge 8) {
            throw "robocopy compare failed with exit code $exitCode"
        }

        if ($exitCode -eq 0) {
            Write-Host "Up to date: mod folder copy matches repo."
            exit 0
        }

        Write-Host "Not up to date: differences detected (run -Mode sync-copy)."
        exit 1
    }

    "cleanup-old" {
        $removed = @()

        foreach ($path in @($LegacyModPath, $LegacyLauncherModFile)) {
            if (Test-Path $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
                $removed += $path
            }
        }

        if ($removed.Count -eq 0) {
            Write-Host "No legacy GMFU-DEV files found to remove."
        }
        else {
            Write-Host "Removed legacy files:"
            $removed | ForEach-Object { Write-Host "- $_" }
        }

        Write-Host "Current active mod path remains: $ModPath"
    }
}
