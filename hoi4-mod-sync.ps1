param(
    [ValidateSet("status", "setup-link", "sync-copy", "sync-mod-to-repo", "watch-mod-to-repo", "check-up-to-date", "cleanup-old")]
    [string]$Mode = "status",
    [string]$RepoPath = $PSScriptRoot,
    [string]$ModName = "",
    [string]$Hoi4ModDir = (Join-Path $env:USERPROFILE "Documents\Paradox Interactive\Hearts of Iron IV\mod"),
    [int]$WatchDebounceMs = 1200
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ModName)) {
    $DescriptorPath = Join-Path $RepoPath "descriptor.mod"
    if (Test-Path $DescriptorPath) {
        $DescriptorName = Select-String -LiteralPath $DescriptorPath -Pattern '^name="([^"]+)"$' | Select-Object -First 1
        if ($DescriptorName) {
            $ModName = $DescriptorName.Matches[0].Groups[1].Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($ModName)) {
        $ModName = Split-Path -Path $RepoPath -Leaf
    }
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

function Invoke-RobocopyMirror {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [switch]$ListOnly
    )

    $args = @(
        '"' + $Source + '"'
        '"' + $Destination + '"'
        '/MIR'
    )

    if ($ListOnly) {
        $args += @('/L', '/NJH', '/NJS', '/NDL', '/NFL', '/NP')
    }

    $args += @('/XD', '.git', '.vscode')

    $cmd = "robocopy " + ($args -join ' ')
    if (-not $ListOnly) {
        Write-Host "Running: $cmd"
    }

    cmd.exe /c $cmd | Out-Host

    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw "robocopy failed with exit code $exitCode"
    }

    return $exitCode
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

        Write-Host "Reverse sync options:" 
        Write-Host "- One-shot mod -> repo copy: -Mode sync-mod-to-repo"
        Write-Host "- Auto-sync while editing mod folder: -Mode watch-mod-to-repo"
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

        Invoke-RobocopyMirror -Source $RepoPath -Destination $ModPath | Out-Null

        Write-LauncherModFile -Path $LauncherModFile -Name $ModName
        Write-Host "Copy sync complete (upload-safe folder mode)."
        Write-Host "Tip: run -Mode setup-link afterward to go back to instant live-link mode."
    }

    "sync-mod-to-repo" {
        if (-not (Test-Path $ModPath)) {
            throw "Mod path not found: $ModPath"
        }

        if (-not (Test-Path $RepoPath)) {
            throw "Repo path not found: $RepoPath"
        }

        $state = Get-LinkState -Path $ModPath
        if ($state -eq "reparse") {
            $item = Get-Item -LiteralPath $ModPath -Force
            $repoNorm = Get-NormalizedPath -Path $RepoPath
            $targetNorm = Get-NormalizedPath -Path ([string]$item.Target)

            if ($repoNorm -ieq $targetNorm) {
                Write-Host "Mod path is already a live link to this repo. No copy needed."
                break
            }
        }

        Invoke-RobocopyMirror -Source $ModPath -Destination $RepoPath | Out-Null
        Write-Host "Copy sync complete (mod folder -> repo)."
    }

    "watch-mod-to-repo" {
        if (-not (Test-Path $ModPath)) {
            throw "Mod path not found: $ModPath"
        }

        if (-not (Test-Path $RepoPath)) {
            throw "Repo path not found: $RepoPath"
        }

        Write-Host "Starting initial sync (mod folder -> repo)..."
        Invoke-RobocopyMirror -Source $ModPath -Destination $RepoPath | Out-Null
        Write-Host "Initial sync complete."

        $watcher = New-Object IO.FileSystemWatcher
        $watcher.Path = $ModPath
        $watcher.Filter = '*'
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size, CreationTime'
        $watcher.EnableRaisingEvents = $true

        $script:pendingSync = $false
        $script:lastEventAt = Get-Date

        $eventAction = {
            $path = $Event.SourceEventArgs.FullPath
            if ($path -match '\\\\.git(\\\\|$)' -or $path -match '\\\\.vscode(\\\\|$)') {
                return
            }

            $script:lastEventAt = Get-Date
            $script:pendingSync = $true
        }

        $subs = @(
            Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $eventAction
            Register-ObjectEvent -InputObject $watcher -EventName Created -Action $eventAction
            Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $eventAction
            Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $eventAction
        )

        Write-Host "Watching $ModPath for changes."
        Write-Host "Auto-sync target: $RepoPath"
        Write-Host "Press Ctrl+C to stop."

        try {
            while ($true) {
                if ($script:pendingSync) {
                    $elapsedMs = ((Get-Date) - $script:lastEventAt).TotalMilliseconds
                    if ($elapsedMs -ge $WatchDebounceMs) {
                        $script:pendingSync = $false
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Syncing mod -> repo..."
                        Invoke-RobocopyMirror -Source $ModPath -Destination $RepoPath | Out-Null
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Sync done."
                    }
                }

                Start-Sleep -Milliseconds 300
            }
        }
        finally {
            foreach ($sub in $subs) {
                Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue
            }

            if ($watcher) {
                $watcher.EnableRaisingEvents = $false
                $watcher.Dispose()
            }

            Write-Host "Stopped watch mode."
        }
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

        $exitCode = Invoke-RobocopyMirror -Source $RepoPath -Destination $ModPath -ListOnly

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
