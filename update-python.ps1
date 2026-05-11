



<#
    Full Python / pip / Conda / VS Code updater for Windows

    Behavior:
    - Finds Python interpreters from:
      * py launcher
      * PATH
      * registry uninstall entries
      * common filesystem locations
      * optional deep recursive filesystem scan
    - Detects Conda / Anaconda / Miniconda and their environments.
    - For every discovered Python interpreter:
      * lists installed pip packages
      * lists outdated pip packages
    - For every Conda environment:
      * lists conda packages
      * lists pip packages inside that exact env
      * lists outdated pip packages inside that exact env
    - Checks whether Python and VS Code can be upgraded through winget.
    - Prompts the user to update:
      * all
      * only Python
      * only packages
      * optionally VS Code too
    - Verifies each update step and logs errors.

    Notes:
    - This script avoids using plain "pip" and instead uses:
      python -m pip
      or
      conda run -p <env> python -m pip
      to reduce interpreter mismatch.
    - Mixing pip and conda updates in the same environment can still be risky.
      The script keeps Conda package updates and pip package updates separate.

    Run example:
      powershell -ExecutionPolicy Bypass -File .\Update-All-Python-And-VSCode.ps1

    Optional:
      -DeepSearch
      -ExtraSearchRoots "E:\Tools","F:\PortableApps"
#>

[CmdletBinding()]
param(
    [string[]]$ExtraSearchRoots = @(),
    [switch]$DeepSearch,
    [string]$LogFile = ".\python_update_log.txt"
)

$ErrorActionPreference = "Stop"
$script:Failures = New-Object System.Collections.Generic.List[object]

# --------------------------------------------------
# Logging and execution helpers
# --------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    $line | Tee-Object -FilePath $LogFile -Append
}

function Add-Failure {
    param(
        [string]$Stage,
        [string]$Target,
        [string]$Message,
        [string]$Command = ""
    )
    $obj = [pscustomobject]@{
        Time    = Get-Date
        Stage   = $Stage
        Target  = $Target
        Message = $Message
        Command = $Command
    }
    $script:Failures.Add($obj)
    Write-Log "$Stage | $Target | $Message" ERROR
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string]$Target,
        [string]$CommandDescription = ""
    )

    try {
        Write-Log "$Stage => $Target" STEP
        $output = & $ScriptBlock 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }

        if ($exitCode -ne 0) {
            $msg = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($msg)) {
                $msg = "Command exited with code $exitCode"
            }
            Add-Failure -Stage $Stage -Target $Target -Message $msg -Command $CommandDescription
            return [pscustomobject]@{
                Success  = $false
                ExitCode = $exitCode
                Output   = $output
            }
        }

        Write-Log "$Stage succeeded for $Target" OK
        return [pscustomobject]@{
            Success  = $true
            ExitCode = 0
            Output   = $output
        }
    }
    catch {
        Add-Failure -Stage $Stage -Target $Target -Message $_.Exception.Message -Command $CommandDescription
        return [pscustomobject]@{
            Success  = $false
            ExitCode = -1
            Output   = $_.Exception.Message
        }
    }
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$Allowed
    )
    while ($true) {
        $answer = (Read-Host "$Prompt [$($Allowed -join '/')]").Trim().ToUpperInvariant()
        if ($Allowed -contains $answer) { return $answer }
        Write-Host "Invalid choice." -ForegroundColor Yellow
    }
}

function Normalize-PathSafe {
    param([string]$Path)
    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        return $Path
    }
}

function Get-UniqueObjectsByProperty {
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [Parameter(Mandatory)] [string]$Property
    )

    $seen = @{}
    foreach ($item in $Items) {
        $value = $item.$Property
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            if (-not $seen.ContainsKey($value)) {
                $seen[$value] = $item
            }
        }
    }
    return $seen.Values
}

# --------------------------------------------------
# Search roots
# --------------------------------------------------

function Get-DefaultSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($p in @(
        $env:LOCALAPPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:USERPROFILE
    )) {
        if ($p -and (Test-Path $p)) {
            $roots.Add($p)
        }
    }

    foreach ($x in $ExtraSearchRoots) {
        if ($x -and (Test-Path $x)) {
            $roots.Add($x)
        }
    }

    return $roots | Select-Object -Unique
}

# --------------------------------------------------
# Python discovery
# --------------------------------------------------

function Get-PythonFromPyLauncher {
    $results = @()
    if (-not (Test-CommandExists "py")) { return $results }

    $res = Invoke-Checked -Stage "Discover py launcher" -Target "py -0p" -CommandDescription "py -0p" -ScriptBlock {
        py -0p
    }

    if (-not $res.Success) { return $results }

    foreach ($line in ($res.Output | ForEach-Object { "$_" })) {
        if ($line -match '^\s*-V:(?<tag>\S+)\s+\*?\s*(?<path>[A-Za-z]:\\.+?python(?:\.exe)?)\s*$') {
            $path = $matches['path']
            $tag  = $matches['tag']
            $results += [pscustomobject]@{
                Source       = "py-launcher"
                PythonPath   = Normalize-PathSafe $path
                DisplayName  = $tag
                IsConda      = ($tag -match 'Anaconda|Miniconda|ContinuumAnalytics|conda')
            }
        }
    }

    return $results
}

function Get-PythonFromPath {
    $results = @()

    foreach ($cmdName in @("python","python3")) {
        $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -match 'python(\.exe)?$') {
            $results += [pscustomobject]@{
                Source       = "PATH"
                PythonPath   = Normalize-PathSafe $cmd.Source
                DisplayName  = $cmdName
                IsConda      = ($cmd.Source -match 'Anaconda|Miniconda|conda')
            }
        }
    }

    return $results
}

function Get-PythonFromRegistry {
    $results = @()
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($root in $roots) {
        try {
            $items = Get-ItemProperty $root -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                $dn = $item.DisplayName
                $loc = $item.InstallLocation

                if ($dn -match 'Python|Anaconda|Miniconda') {
                    $candidatePaths = @()

                    if ($loc) {
                        $candidatePaths += (Join-Path $loc "python.exe")
                    }

                    if ($item.DisplayIcon -and ($item.DisplayIcon -match 'python\.exe')) {
                        $candidatePaths += (($item.DisplayIcon -split ',')[0].Trim('"'))
                    }

                    foreach ($candidate in ($candidatePaths | Select-Object -Unique)) {
                        if ($candidate -and (Test-Path $candidate)) {
                            $results += [pscustomobject]@{
                                Source       = "Registry"
                                PythonPath   = Normalize-PathSafe $candidate
                                DisplayName  = $dn
                                IsConda      = ($dn -match 'Anaconda|Miniconda' -or $candidate -match 'Anaconda|Miniconda|conda')
                            }
                        }
                    }
                }
            }
        }
        catch {
            Add-Failure -Stage "Registry scan" -Target $root -Message $_.Exception.Message
        }
    }

    return $results
}

function Get-PythonFromFilesystem {
    param([switch]$UseDeepSearch)

    $results = @()
    $roots = Get-DefaultSearchRoots
    $hintPatterns = @("Python*", "*Anaconda*", "*Miniconda*", "*conda*")

    foreach ($root in $roots) {
        try {
            $files = @()

            if ($UseDeepSearch) {
                $files = Get-ChildItem -Path $root -Filter "python.exe" -File -Recurse -ErrorAction SilentlyContinue
            }
            else {
                foreach ($hint in $hintPatterns) {
                    $dirs = Get-ChildItem -Path $root -Directory -Filter $hint -ErrorAction SilentlyContinue
                    foreach ($dir in $dirs) {
                        $cand = Join-Path $dir.FullName "python.exe"
                        if (Test-Path $cand) {
                            $files += Get-Item $cand
                        }

                        $envs = Join-Path $dir.FullName "envs"
                        if (Test-Path $envs) {
                            $files += Get-ChildItem -Path $envs -Filter "python.exe" -File -Recurse -ErrorAction SilentlyContinue
                        }
                    }
                }
            }

            foreach ($file in ($files | Sort-Object FullName -Unique)) {
                $results += [pscustomobject]@{
                    Source       = if ($UseDeepSearch) { "Filesystem-Recursive" } else { "Filesystem-Hinted" }
                    PythonPath   = Normalize-PathSafe $file.FullName
                    DisplayName  = $file.Directory.Name
                    IsConda      = ($file.FullName -match 'Anaconda|Miniconda|conda')
                }
            }
        }
        catch {
            Add-Failure -Stage "Filesystem scan" -Target $root -Message $_.Exception.Message
        }
    }

    return $results
}

function Get-PythonInfo {
    param([string]$PythonPath)

    $cmdText = "`"$PythonPath`" -c ""import sys,json,platform; print(json.dumps({'version':sys.version.split()[0],'executable':sys.executable,'prefix':sys.prefix,'base_prefix':getattr(sys,'base_prefix',sys.prefix),'is_venv':sys.prefix!=getattr(sys,'base_prefix',sys.prefix),'platform':platform.platform()}, ensure_ascii=False))"""
    $res = Invoke-Checked -Stage "Inspect Python" -Target $PythonPath -CommandDescription $cmdText -ScriptBlock {
        & $PythonPath -c "import sys,json,platform; print(json.dumps({'version':sys.version.split()[0],'executable':sys.executable,'prefix':sys.prefix,'base_prefix':getattr(sys,'base_prefix',sys.prefix),'is_venv':sys.prefix!=getattr(sys,'base_prefix',sys.prefix),'platform':platform.platform()}, ensure_ascii=False))"
    }

    if (-not $res.Success) { return $null }

    try {
        return (($res.Output | Out-String).Trim() | ConvertFrom-Json)
    }
    catch {
        Add-Failure -Stage "Parse Python info" -Target $PythonPath -Message $_.Exception.Message -Command $cmdText
        return $null
    }
}

# --------------------------------------------------
# pip interrogation for exact interpreter
# --------------------------------------------------

function Get-PipPackagesExact {
    param(
        [string]$PythonPath,
        [string]$Label = ""
    )

    $cmdDesc = "`"$PythonPath`" -m pip list --format json"
    $res = Invoke-Checked -Stage "List pip packages" -Target ($(if ($Label) { $Label } else { $PythonPath })) -CommandDescription $cmdDesc -ScriptBlock {
        & $PythonPath -m pip list --format json
    }

    if (-not $res.Success) { return @() }

    try {
        $txt = ($res.Output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
        return ($txt | ConvertFrom-Json)
    }
    catch {
        Add-Failure -Stage "Parse pip package list" -Target ($(if ($Label) { $Label } else { $PythonPath })) -Message $_.Exception.Message -Command $cmdDesc
        return @()
    }
}

function Get-OutdatedPipPackagesExact {
    param(
        [string]$PythonPath,
        [string]$Label = ""
    )

    $cmdDesc = "`"$PythonPath`" -m pip list --outdated --format json"
    $res = Invoke-Checked -Stage "List outdated pip packages" -Target ($(if ($Label) { $Label } else { $PythonPath })) -CommandDescription $cmdDesc -ScriptBlock {
        & $PythonPath -m pip list --outdated --format json
    }

    if (-not $res.Success) { return @() }

    try {
        $txt = ($res.Output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
        return ($txt | ConvertFrom-Json)
    }
    catch {
        Add-Failure -Stage "Parse outdated pip package list" -Target ($(if ($Label) { $Label } else { $PythonPath })) -Message $_.Exception.Message -Command $cmdDesc
        return @()
    }
}

# --------------------------------------------------
# Conda discovery and interrogation
# --------------------------------------------------

function Get-CondaCommand {
    $candidates = @()

    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($root in Get-DefaultSearchRoots) {
        foreach ($p in @(
            (Join-Path $root "Anaconda3\Scripts\conda.exe"),
            (Join-Path $root "Miniconda3\Scripts\conda.exe"),
            (Join-Path $root "anaconda3\Scripts\conda.exe"),
            (Join-Path $root "miniconda3\Scripts\conda.exe")
        )) {
            if (Test-Path $p) {
                $candidates += $p
            }
        }
    }

    return ($candidates | Select-Object -Unique | Select-Object -First 1)
}

function Get-CondaEnvs {
    param([string]$CondaExe)

    if (-not $CondaExe) { return @() }

    $res = Invoke-Checked -Stage "List conda envs" -Target $CondaExe -CommandDescription "`"$CondaExe`" info --envs --json" -ScriptBlock {
        & $CondaExe info --envs --json
    }

    if (-not $res.Success) { return @() }

    try {
        $json = (($res.Output | Out-String) | ConvertFrom-Json)
        $envs = @()

        if ($json.envs) {
            foreach ($item in $json.envs) {
                if ($item -is [string]) {
                    $envs += [pscustomobject]@{
                        Name = Split-Path $item -Leaf
                        Path = $item
                    }
                }
                else {
                    $envs += [pscustomobject]@{
                        Name = $item.name
                        Path = $item.path
                    }
                }
            }
        }

        return $envs
    }
    catch {
        Add-Failure -Stage "Parse conda envs" -Target $CondaExe -Message $_.Exception.Message
        return @()
    }
}

function Get-CondaPackages {
    param(
        [string]$CondaExe,
        [string]$EnvPath
    )

    $res = Invoke-Checked -Stage "List conda packages" -Target $EnvPath -CommandDescription "`"$CondaExe`" list -p `"$EnvPath`" --json" -ScriptBlock {
        & $CondaExe list -p $EnvPath --json
    }

    if (-not $res.Success) { return @() }

    try {
        return ((($res.Output | Out-String).Trim()) | ConvertFrom-Json)
    }
    catch {
        Add-Failure -Stage "Parse conda package list" -Target $EnvPath -Message $_.Exception.Message
        return @()
    }
}

function Get-CondaPipPackagesExact {
    param(
        [string]$CondaExe,
        [string]$EnvPath
    )

    $cmdDesc = "`"$CondaExe`" run -p `"$EnvPath`" python -m pip list --format json"
    $res = Invoke-Checked -Stage "List conda-env pip packages" -Target $EnvPath -CommandDescription $cmdDesc -ScriptBlock {
        & $CondaExe run -p $EnvPath python -m pip list --format json
    }

    if (-not $res.Success) { return @() }

    try {
        $txt = ($res.Output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
        return ($txt | ConvertFrom-Json)
    }
    catch {
        Add-Failure -Stage "Parse conda-env pip package list" -Target $EnvPath -Message $_.Exception.Message -Command $cmdDesc
        return @()
    }
}

function Get-CondaOutdatedPipPackagesExact {
    param(
        [string]$CondaExe,
        [string]$EnvPath
    )

    $cmdDesc = "`"$CondaExe`" run -p `"$EnvPath`" python -m pip list --outdated --format json"
    $res = Invoke-Checked -Stage "List conda-env outdated pip packages" -Target $EnvPath -CommandDescription $cmdDesc -ScriptBlock {
        & $CondaExe run -p $EnvPath python -m pip list --outdated --format json
    }

    if (-not $res.Success) { return @() }

    try {
        $txt = ($res.Output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
        return ($txt | ConvertFrom-Json)
    }
    catch {
        Add-Failure -Stage "Parse conda-env outdated pip package list" -Target $EnvPath -Message $_.Exception.Message -Command $cmdDesc
        return @()
    }
}

# --------------------------------------------------
# winget helpers
# --------------------------------------------------

function Test-Winget {
    return (Test-CommandExists "winget")
}

function Test-WingetPackageUpgradeable {
    param([string[]]$PossibleIds)

    if (-not (Test-Winget)) { return $null }

    foreach ($id in $PossibleIds) {
        $res = Invoke-Checked -Stage "Check winget package" -Target $id -CommandDescription "winget upgrade --id $id --exact" -ScriptBlock {
            winget upgrade --id $id --exact
        }

        $text = ($res.Output | Out-String)
        if ($text -match [regex]::Escape($id)) {
            return [pscustomobject]@{
                Id  = $id
                Raw = $text
            }
        }
    }

    return $null
}

function Invoke-WingetUpgrade {
    param([string]$Id)

    return Invoke-Checked -Stage "winget upgrade" -Target $Id -CommandDescription "winget upgrade --id $Id --exact --silent --accept-source-agreements --accept-package-agreements" -ScriptBlock {
        winget upgrade --id $Id --exact --silent --accept-source-agreements --accept-package-agreements
    }
}

# --------------------------------------------------
# Update actions
# --------------------------------------------------

function Update-PipPackages {
    param(
        [string]$PythonPath,
        [object[]]$OutdatedPackages
    )

    foreach ($pkg in $OutdatedPackages) {
        $name = $pkg.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $cmdDesc = "`"$PythonPath`" -m pip install --upgrade $name"
        $result = Invoke-Checked -Stage "Update pip package" -Target "$name via $PythonPath" -CommandDescription $cmdDesc -ScriptBlock {
            & $PythonPath -m pip install --upgrade $name
        }

        if ($result.Success) {
            $verify = Get-OutdatedPipPackagesExact -PythonPath $PythonPath -Label $PythonPath | Where-Object { $_.name -eq $name }
            if ($verify) {
                Add-Failure -Stage "Verify pip update" -Target "$name via $PythonPath" -Message "Package still appears outdated after upgrade" -Command $cmdDesc
            }
            else {
                Write-Log "Verified pip package update: $name via $PythonPath" OK
            }
        }
    }
}

function Update-CondaPipPackages {
    param(
        [string]$CondaExe,
        [string]$EnvPath,
        [object[]]$OutdatedPackages
    )

    foreach ($pkg in $OutdatedPackages) {
        $name = $pkg.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $cmdDesc = "`"$CondaExe`" run -p `"$EnvPath`" python -m pip install --upgrade $name"
        $result = Invoke-Checked -Stage "Update conda-env pip package" -Target "$name in $EnvPath" -CommandDescription $cmdDesc -ScriptBlock {
            & $CondaExe run -p $EnvPath python -m pip install --upgrade $name
        }

        if ($result.Success) {
            $verify = Get-CondaOutdatedPipPackagesExact -CondaExe $CondaExe -EnvPath $EnvPath | Where-Object { $_.name -eq $name }
            if ($verify) {
                Add-Failure -Stage "Verify conda-env pip update" -Target "$name in $EnvPath" -Message "Package still appears outdated after upgrade" -Command $cmdDesc
            }
            else {
                Write-Log "Verified conda-env pip package update: $name in $EnvPath" OK
            }
        }
    }
}

function Update-CondaAllPackages {
    param(
        [string]$CondaExe,
        [string]$EnvPath
    )

    $cmdDesc = "`"$CondaExe`" update -p `"$EnvPath`" --all -y"
    $result = Invoke-Checked -Stage "Update conda packages" -Target $EnvPath -CommandDescription $cmdDesc -ScriptBlock {
        & $CondaExe update -p $EnvPath --all -y
    }

    if ($result.Success) {
        $verify = Get-CondaPackages -CondaExe $CondaExe -EnvPath $EnvPath
        if (-not $verify) {
            Add-Failure -Stage "Verify conda environment" -Target $EnvPath -Message "Conda package listing failed after update" -Command $cmdDesc
        }
        else {
            Write-Log "Verified conda environment after update: $EnvPath" OK
        }
    }
}

# --------------------------------------------------
# Main discovery
# --------------------------------------------------

if (Test-Path $LogFile) {
    Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
}

Write-Log "Starting discovery"

$discovered = @()
$discovered += Get-PythonFromPyLauncher
$discovered += Get-PythonFromPath
$discovered += Get-PythonFromRegistry
$discovered += Get-PythonFromFilesystem -UseDeepSearch:$DeepSearch

$discovered = Get-UniqueObjectsByProperty -Items $discovered -Property "PythonPath" |
    Where-Object { $_.PythonPath -and (Test-Path $_.PythonPath) }

$pythonInstalls = @()

foreach ($item in $discovered) {
    $info = Get-PythonInfo -PythonPath $item.PythonPath
    if ($info) {
        $pythonInstalls += [pscustomobject]@{
            Source      = $item.Source
            PythonPath  = $info.executable
            Version     = $info.version
            Prefix      = $info.prefix
            BasePrefix  = $info.base_prefix
            IsVenv      = [bool]$info.is_venv
            IsConda     = ($item.IsConda -or $info.prefix -match 'Anaconda|Miniconda|conda')
            DisplayName = $item.DisplayName
        }
    }
}

$pythonInstalls = Get-UniqueObjectsByProperty -Items $pythonInstalls -Property "PythonPath"

Write-Log "Found $($pythonInstalls.Count) Python interpreter(s)"

$condaExe = Get-CondaCommand
$condaEnvs = @()

if ($condaExe) {
    Write-Log "Found conda command at $condaExe"
    $condaEnvs = Get-CondaEnvs -CondaExe $condaExe
    Write-Log "Found $($condaEnvs.Count) conda environment(s)"
}
else {
    Write-Log "Conda command not found" WARN
}

# --------------------------------------------------
# Inventory build
# --------------------------------------------------

$pythonInventory = @()

foreach ($py in $pythonInstalls) {
    $installed = Get-PipPackagesExact -PythonPath $py.PythonPath -Label $py.PythonPath
    $outdated  = Get-OutdatedPipPackagesExact -PythonPath $py.PythonPath -Label $py.PythonPath

    $pythonInventory += [pscustomobject]@{
        Kind              = "Python"
        Name              = $py.DisplayName
        PythonPath        = $py.PythonPath
        Version           = $py.Version
        Source            = $py.Source
        IsConda           = $py.IsConda
        Prefix            = $py.Prefix
        InstalledPackages = @($installed)
        InstalledCount    = @($installed).Count
        OutdatedPackages  = @($outdated)
        OutdatedCount     = @($outdated).Count
    }
}

$condaInventory = @()

if ($condaExe) {
    foreach ($env in $condaEnvs) {
        $condaPkgs    = Get-CondaPackages -CondaExe $condaExe -EnvPath $env.Path
        $pipInstalled = Get-CondaPipPackagesExact -CondaExe $condaExe -EnvPath $env.Path
        $pipOutdated  = Get-CondaOutdatedPipPackagesExact -CondaExe $condaExe -EnvPath $env.Path

        $condaInventory += [pscustomobject]@{
            Kind              = "Conda"
            EnvName           = $env.Name
            EnvPath           = $env.Path
            CondaPackages     = @($condaPkgs)
            CondaPackageCount = @($condaPkgs).Count
            PipPackages       = @($pipInstalled)
            PipPackageCount   = @($pipInstalled).Count
            PipOutdated       = @($pipOutdated)
            PipOutdatedCount  = @($pipOutdated).Count
        }
    }
}

# --------------------------------------------------
# Check winget updates
# --------------------------------------------------

$wingetAvailable = Test-Winget
$vsCodeUpgrade = $null
$pythonUpgradeCandidates = @()

if ($wingetAvailable) {
    $candidatePythonIds = @(
        "Python.Python.3.13",
        "Python.Python.3.12",
        "Python.Python.3.11",
        "Python.Python.3.10"
    )

    foreach ($id in $candidatePythonIds) {
        $hit = Test-WingetPackageUpgradeable -PossibleIds @($id)
        if ($hit) { $pythonUpgradeCandidates += $hit }
    }

    $vsCodeUpgrade = Test-WingetPackageUpgradeable -PossibleIds @(
        "Microsoft.VisualStudioCode",
        "Microsoft.VisualStudioCode.User"
    )
}

# --------------------------------------------------
# Report
# --------------------------------------------------

Write-Host ""
Write-Host "========== DISCOVERY ==========" -ForegroundColor Cyan

if ($pythonInventory.Count -eq 0) {
    Write-Host "No Python interpreters found." -ForegroundColor Yellow
}
else {
    foreach ($item in $pythonInventory) {
        Write-Host ("Python: {0}" -f $item.PythonPath) -ForegroundColor Green
        Write-Host ("  Version:            {0}" -f $item.Version)
        Write-Host ("  Installed pip:      {0}" -f $item.InstalledCount)
        Write-Host ("  Outdated pip:       {0}" -f $item.OutdatedCount)
        Write-Host ("  IsConda interpreter:{0}" -f $item.IsConda)
    }
}

if ($condaInventory.Count -gt 0) {
    Write-Host ""
    Write-Host "========== CONDA ENVIRONMENTS ==========" -ForegroundColor Cyan
    foreach ($env in $condaInventory) {
        Write-Host ("Conda env: {0}" -f $env.EnvPath) -ForegroundColor Magenta
        Write-Host ("  Conda packages:     {0}" -f $env.CondaPackageCount)
        Write-Host ("  Pip packages:       {0}" -f $env.PipPackageCount)
        Write-Host ("  Outdated pip:       {0}" -f $env.PipOutdatedCount)

        foreach ($pkg in $env.PipOutdated) {
            Write-Host ("    - {0}: {1} -> {2}" -f $pkg.name, $pkg.version, $pkg.latest_version) -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========== PIP OUTDATED REPORT ==========" -ForegroundColor Cyan
foreach ($item in $pythonInventory) {
    if ($item.OutdatedCount -gt 0) {
        Write-Host ("Interpreter: {0}" -f $item.PythonPath) -ForegroundColor Green
        foreach ($pkg in $item.OutdatedPackages) {
            Write-Host ("  - {0}: {1} -> {2}" -f $pkg.name, $pkg.version, $pkg.latest_version) -ForegroundColor Yellow
        }
    }
}

if ($pythonUpgradeCandidates.Count -gt 0) {
    Write-Host ""
    Write-Host "Winget reports Python upgrade candidate(s):" -ForegroundColor Cyan
    $pythonUpgradeCandidates | Select-Object -ExpandProperty Id -Unique | ForEach-Object {
        Write-Host " - $_"
    }
}
else {
    Write-Host ""
    Write-Host "No Python winget upgrade candidate detected." -ForegroundColor Yellow
}

if ($vsCodeUpgrade) {
    Write-Host "VS Code update appears available for: $($vsCodeUpgrade.Id)" -ForegroundColor Cyan
}
else {
    Write-Host "No VS Code update detected." -ForegroundColor Yellow
}

# --------------------------------------------------
# Decide update scope
# --------------------------------------------------

$hasAnyOutdatedPip = @($pythonInventory | Where-Object { $_.OutdatedCount -gt 0 }).Count -gt 0
if (-not $hasAnyOutdatedPip) {
    $hasAnyOutdatedPip = @($condaInventory | Where-Object { $_.PipOutdatedCount -gt 0 }).Count -gt 0
}

$hasPythonUpdate = $pythonUpgradeCandidates.Count -gt 0
$hasConda = $condaInventory.Count -gt 0
$hasVsCodeUpdate = $null -ne $vsCodeUpgrade

if (-not ($hasAnyOutdatedPip -or $hasPythonUpdate -or $hasConda -or $hasVsCodeUpdate)) {
    Write-Host ""
    Write-Host "Nothing eligible for update was found." -ForegroundColor Green
    Write-Host "Log file: $LogFile"
    return
}

Write-Host ""
$mainChoice = Read-Choice -Prompt "Update mode: A=all, P=only Python, G=only packages, N=nothing" -Allowed @("A","P","G","N")

if ($mainChoice -eq "N") {
    Write-Host "No updates selected."
    Write-Host "Log file: $LogFile"
    return
}

$includeVsCode = $false
if ($hasVsCodeUpdate) {
    $vsChoice = Read-Choice -Prompt "VS Code update found. Include it" -Allowed @("Y","N")
    $includeVsCode = ($vsChoice -eq "Y")
}

# --------------------------------------------------
# Execute Python updates
# --------------------------------------------------

if ($mainChoice -in @("A","P")) {
    if ($hasPythonUpdate) {
        foreach ($candidate in ($pythonUpgradeCandidates | Select-Object -ExpandProperty Id -Unique)) {
            Invoke-WingetUpgrade -Id $candidate | Out-Null
        }
    }
    else {
        Write-Host "No Python winget update target found." -ForegroundColor Yellow
    }
}

# --------------------------------------------------
# Execute package updates
# --------------------------------------------------

if ($mainChoice -in @("A","G")) {

    # Non-Conda interpreters
    foreach ($item in $pythonInventory | Where-Object { -not $_.IsConda -and $_.OutdatedCount -gt 0 }) {
        Write-Host "Updating pip packages for $($item.PythonPath)" -ForegroundColor Cyan
        Update-PipPackages -PythonPath $item.PythonPath -OutdatedPackages $item.OutdatedPackages
    }

    # Conda interpreters discovered outside env listing
    foreach ($item in $pythonInventory | Where-Object { $_.IsConda -and $_.OutdatedCount -gt 0 }) {
        $answer = Read-Choice -Prompt "Interpreter $($item.PythonPath) looks Conda-based. Update its pip packages with pip" -Allowed @("Y","N")
        if ($answer -eq "Y") {
            Update-PipPackages -PythonPath $item.PythonPath -OutdatedPackages $item.OutdatedPackages
        }
    }

    # Conda package updates
    if ($condaExe -and $condaInventory.Count -gt 0) {
        $condaChoice = Read-Choice -Prompt "Update all Conda packages in all Conda environments too" -Allowed @("Y","N")
        if ($condaChoice -eq "Y") {
            $baseEnv = $condaInventory | Where-Object { $_.EnvName -eq "base" } | Select-Object -First 1
            if ($baseEnv) {
                Invoke-Checked -Stage "Update conda itself" -Target $baseEnv.EnvPath -CommandDescription "`"$condaExe`" update -n base conda -y" -ScriptBlock {
                    & $condaExe update -n base conda -y
                } | Out-Null
            }

            foreach ($env in $condaInventory) {
                Write-Host "Updating Conda packages in $($env.EnvPath)" -ForegroundColor Cyan
                Update-CondaAllPackages -CondaExe $condaExe -EnvPath $env.EnvPath
            }
        }

        $condaPipChoice = Read-Choice -Prompt "Update pip-only packages inside Conda environments too" -Allowed @("Y","N")
        if ($condaPipChoice -eq "Y") {
            foreach ($env in $condaInventory | Where-Object { $_.PipOutdatedCount -gt 0 }) {
                Write-Host "Updating pip packages in Conda env $($env.EnvPath)" -ForegroundColor Cyan
                Update-CondaPipPackages -CondaExe $condaExe -EnvPath $env.EnvPath -OutdatedPackages $env.PipOutdated
            }
        }
    }
}

# --------------------------------------------------
# Execute VS Code update
# --------------------------------------------------

if ($includeVsCode -and $vsCodeUpgrade) {
    Invoke-WingetUpgrade -Id $vsCodeUpgrade.Id | Out-Null
}

# --------------------------------------------------
# Final re-check
# --------------------------------------------------

Write-Host ""
Write-Host "========== POST-CHECK ==========" -ForegroundColor Cyan

foreach ($item in $pythonInventory) {
    $recheck = Get-OutdatedPipPackagesExact -PythonPath $item.PythonPath -Label $item.PythonPath
    Write-Host ("Post-check pip outdated for {0}: {1}" -f $item.PythonPath, @($recheck).Count)
}

if ($condaExe -and $condaInventory.Count -gt 0) {
    foreach ($env in $condaInventory) {
        $verifyPip = Get-CondaOutdatedPipPackagesExact -CondaExe $condaExe -EnvPath $env.EnvPath
        Write-Host ("Post-check conda-env pip outdated for {0}: {1}" -f $env.EnvPath, @($verifyPip).Count)

        $verifyConda = Get-CondaPackages -CondaExe $condaExe -EnvPath $env.EnvPath
        if ($verifyConda) {
            Write-Host ("Post-check conda env ok: {0}" -f $env.EnvPath)
        }
        else {
            Write-Host ("Post-check conda env failed: {0}" -f $env.EnvPath) -ForegroundColor Yellow
        }
    }
}

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "Completed with errors. Failure count: $($script:Failures.Count)" -ForegroundColor Yellow
    $script:Failures | Format-Table -AutoSize
}
else {
    Write-Host "Completed without recorded errors." -ForegroundColor Green
}

Write-Host "Log file: $LogFile"



