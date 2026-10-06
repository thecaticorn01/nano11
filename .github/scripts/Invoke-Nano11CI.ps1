#Requires -Version 5.1
<#
.SYNOPSIS
    CI launcher for nano11builder.ps1 (used by .github/workflows/build-nano11.yml).
.DESCRIPTION
    Translates the workflow_dispatch inputs (exposed as NANO11_* environment variables)
    into validated nano11builder.ps1 parameters, runs the builder unattended and
    verifies that an ISO was produced.

    Inputs are never evaluated as PowerShell code: every value is checked against the
    builder's own param() block and handed over by splatting.
.PARAMETER SourceIso
    Path to the Windows 11 ISO passed to the builder as -SourceDrive.
.PARAMETER WorkDir
    Working directory passed to the builder as -WorkDir.
.PARAMETER PlanOnly
    Resolve and print the builder parameters, then exit without building.
#>
[CmdletBinding()]
param(
    [string]$SourceIso,
    [string]$WorkDir,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
$builderPath = Join-Path -Path $repoRoot -ChildPath 'nano11builder.ps1'
if (-not (Test-Path -LiteralPath $builderPath)) {
    throw "nano11builder.ps1 not found at $builderPath"
}

function Get-InputValue {
    param([string]$Name, [string]$Default = '')
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Write-Summary {
    param([string[]]$Lines)
    if ($env:GITHUB_STEP_SUMMARY) {
        # AppendAllText writes BOM-less UTF-8, which is what the runner expects.
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, (($Lines -join "`n") + "`n"))
    }
}

function Write-StepOutput {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name=$Value`n")
    }
}

# ------------------------------------------------------------------------------
# Builder parameter metadata (canonical names + aliases)
# ------------------------------------------------------------------------------
$builderCmd = Get-Command -Name $builderPath -CommandType ExternalScript
$commonParams = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

# Parameters the workflow controls itself, or that cannot work on a headless runner.
$reservedParams = @('SourceDrive', 'WorkDir', 'NonInteractive', 'Interactive', 'GUI', 'TestSelf', 'Resume', 'SaveProfile', 'LoadProfile')

$paramLookup = @{}
foreach ($p in $builderCmd.Parameters.Values) {
    if ($p.Name -in $commonParams) { continue }
    $paramLookup[$p.Name.ToLowerInvariant()] = $p
    foreach ($a in $p.Aliases) { $paramLookup[$a.ToLowerInvariant()] = $p }
}

function Resolve-BuilderParam {
    param([string]$Name)
    $meta = $paramLookup[$Name.ToLowerInvariant()]
    if (-not $meta) {
        throw "Unknown nano11builder.ps1 parameter: -$Name"
    }
    if ($meta.Name -in $reservedParams) {
        throw "Parameter -$($meta.Name) is managed by the workflow and cannot be set via extra_args."
    }
    return $meta
}

$builderParams = [ordered]@{}

function Set-BuilderParam {
    param([string]$Name, $Value)
    $meta = Resolve-BuilderParam -Name $Name
    if ($builderParams.Contains($meta.Name)) {
        throw "Parameter -$($meta.Name) was specified more than once (check extra_args against the dedicated inputs)."
    }
    $builderParams[$meta.Name] = $Value
}

# ------------------------------------------------------------------------------
# Dedicated workflow inputs
# ------------------------------------------------------------------------------
$profileName = Get-InputValue 'NANO11_PROFILE' 'none'
if ($profileName -ne 'none') {
    if ($profileName -notmatch '^[A-Za-z0-9,-]+$') { throw "Invalid profile: $profileName" }
    Set-BuilderParam 'Profile' $profileName.ToLowerInvariant()
}

$imageIndex = Get-InputValue 'NANO11_INDEX'
if ($imageIndex) {
    if ($imageIndex -notmatch '^\d{1,2}$') { throw "image_index must be a number (got '$imageIndex')." }
    Set-BuilderParam 'Index' $imageIndex
}

# Both values are substituted verbatim into autounattend.xml, so keep them to safe characters.
$computerName = Get-InputValue 'NANO11_COMPUTER_NAME'
if ($computerName) {
    if ($computerName -ne '*' -and $computerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {
        throw "computer_name must be '*' or 1-15 letters, digits or hyphens (got '$computerName')."
    }
    Set-BuilderParam 'ComputerName' $computerName
}

$userName = Get-InputValue 'NANO11_USER_NAME'
if ($userName) {
    if ($userName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$') {
        throw "user_name must be 1-20 letters, digits, '.', '_' or '-' (got '$userName')."
    }
    Set-BuilderParam 'UserName' $userName
}

# Paired keep/remove switches: input value -> builder switch. 'default' leaves the profile/builder default.
$toggleInputs = [ordered]@{
    NANO11_DEFENDER          = @{ keep = 'KeepDefender';      remove  = 'RemoveDefender' }
    NANO11_ASIAN_IME         = @{ keep = 'KeepIME';           remove  = 'RemoveIME' }
    NANO11_FONTS             = @{ keep = 'KeepFonts';         remove  = 'RemoveFonts' }
    NANO11_DRIVERS           = @{ keep = 'KeepDrivers';       remove  = 'RemoveDrivers' }
    NANO11_WINDOWS_UPDATE    = @{ keep = 'KeepWindowsUpdate'; disable = 'DisableWindowsUpdate' }
    NANO11_BLUETOOTH         = @{ keep = 'KeepBluetooth';     disable = 'DisableBluetooth' }
    NANO11_WSL               = @{ enable = 'EnableWSL';       disable = 'DisableWSL' }
    NANO11_RECOVERY          = @{ keep = 'KeepRecovery';      remove  = 'RemoveRecovery' }
    NANO11_WINSXS_MODE       = @{ safe = 'SafeDebloat';       aggressive = 'AggressiveWinSxS' }
    NANO11_ULTRASLIM         = @{ enable = 'UltraSlim';       disable = 'NoUltraSlim' }
    NANO11_JAPANESE_KEYBOARD = @{ enable = 'JapaneseKeyboard'; disable = 'NoJapaneseKeyboard' }
    NANO11_ATLAS_REVIOS      = @{ enable = 'AtlasReviOS';     disable = 'NoAtlasReviOS' }
    NANO11_STORE             = @{ keep = 'KeepStore';         remove  = 'RemoveStore' }
    NANO11_XBOX_SERVICES     = @{ keep = 'KeepXboxServices';  remove  = 'RemoveXboxServices' }
}
foreach ($envName in $toggleInputs.Keys) {
    $choice = (Get-InputValue $envName 'default').ToLowerInvariant()
    if ($choice -eq 'default') { continue }
    $map = $toggleInputs[$envName]
    if (-not $map.ContainsKey($choice)) {
        throw "Invalid value '$choice' for $envName (expected: default, $($map.Keys -join ', '))."
    }
    Set-BuilderParam $map[$choice] $true
}

$payloadFormat = (Get-InputValue 'NANO11_PAYLOAD_FORMAT' 'default').ToLowerInvariant()
switch ($payloadFormat) {
    'default' { }
    'wim'     { Set-BuilderParam 'ExportWIM' $true; Set-BuilderParam 'NoSplitWIM' $true }
    'esd'     { Set-BuilderParam 'ExportESD' $true }
    'swm'     { Set-BuilderParam 'SplitWIM' $true }
    default   { throw "Invalid payload_format '$payloadFormat' (expected: default, wim, esd, swm)." }
}

$activationBypass = (Get-InputValue 'NANO11_ACTIVATION_BYPASS' 'default').ToLowerInvariant()
switch ($activationBypass) {
    'default' { }
    'enable'  { Set-BuilderParam 'BypassActivationRestrictions' $true }
    'disable' { Set-BuilderParam 'BypassActivationRestrictions' $false }
    default   { throw "Invalid activation_bypass '$activationBypass' (expected: default, enable, disable)." }
}

# ------------------------------------------------------------------------------
# extra_args: any other builder parameter, e.g.
#   -DisableFSE -HibernateMode Off -PowerPreset Handheld -TweakGroupOverrides VisualFX=false,TimerBCD=true
# ------------------------------------------------------------------------------
$extraArgs = Get-InputValue 'NANO11_EXTRA_ARGS'
if ($extraArgs) {
    $tokens = @($extraArgs -split '\s+' | Where-Object { $_ })
    $i = 0
    while ($i -lt $tokens.Count) {
        $tok = $tokens[$i]
        if ($tok -notmatch '^-([A-Za-z][A-Za-z0-9]*)(?::(.+))?$') {
            throw "extra_args: expected a parameter name starting with '-', got '$tok'."
        }
        $name = $matches[1]
        $inlineValue = $matches[2]
        $meta = Resolve-BuilderParam -Name $name
        $type = $meta.ParameterType

        if ($type -eq [System.Management.Automation.SwitchParameter]) {
            $value = $true
            if ($inlineValue) {
                switch -Regex ($inlineValue) {
                    '^\$?(true|1)$'  { $value = $true }
                    '^\$?(false|0)$' { $value = $false }
                    default { throw "extra_args: switch -$name only accepts :`$true or :`$false (got '$inlineValue')." }
                }
            }
            Set-BuilderParam $meta.Name $value
            $i++
            continue
        }

        if ($inlineValue) {
            $raw = $inlineValue
            $i++
        } else {
            if ($i + 1 -ge $tokens.Count) { throw "extra_args: -$name requires a value." }
            $raw = $tokens[$i + 1]
            $i += 2
        }

        if ($type -eq [hashtable]) {
            # -TweakGroupOverrides Key=true,Key2=false
            $ht = @{}
            foreach ($pair in ($raw -split ',')) {
                if ($pair -notmatch '^([A-Za-z0-9]+)=\$?(true|false|1|0)$') {
                    throw "extra_args: -$name expects Key=true,Key=false pairs (got '$pair')."
                }
                $ht[$matches[1]] = ($matches[2] -in @('true', '1'))
            }
            Set-BuilderParam $meta.Name $ht
        } elseif ($type -eq [int]) {
            if ($raw -notmatch '^\d+$') { throw "extra_args: -$name expects an integer (got '$raw')." }
            Set-BuilderParam $meta.Name ([int]$raw)
        } else {
            if ($raw -notmatch '^[A-Za-z0-9_.,:\\/-]+$') {
                throw "extra_args: value '$raw' for -$name contains unsupported characters."
            }
            if ($meta.Name -eq 'InjectDrivers' -and -not [System.IO.Path]::IsPathRooted($raw)) {
                # Driver folders are expected to be committed to the repository.
                $raw = Join-Path -Path $repoRoot -ChildPath $raw
            }
            # ValidateSet attributes (HibernateMode, PowerPreset, ...) are enforced by the builder on binding.
            Set-BuilderParam $meta.Name $raw
        }
    }
}

# Fail before the multi-GB ISO download instead of deep into the build (mirrors the builder's own check).
$conflictPairs = @(
    @('KeepDefender', 'RemoveDefender'), @('KeepIME', 'RemoveIME'), @('KeepFonts', 'RemoveFonts'),
    @('KeepDrivers', 'RemoveDrivers'), @('KeepWindowsUpdate', 'DisableWindowsUpdate'),
    @('KeepBluetooth', 'DisableBluetooth'), @('EnableWSL', 'DisableWSL'), @('KeepRecovery', 'RemoveRecovery'),
    @('SafeDebloat', 'AggressiveWinSxS'), @('UltraSlim', 'NoUltraSlim'), @('JapaneseKeyboard', 'NoJapaneseKeyboard'),
    @('AtlasReviOS', 'NoAtlasReviOS'), @('ExportESD', 'ExportWIM'), @('SplitWIM', 'NoSplitWIM'),
    @('ExportESD', 'SplitWIM'), @('KeepStore', 'RemoveStore'), @('KeepXboxServices', 'RemoveXboxServices')
)
foreach ($pair in $conflictPairs) {
    $a = $builderParams.Contains($pair[0]) -and $builderParams[$pair[0]] -eq $true
    $b = $builderParams.Contains($pair[1]) -and $builderParams[$pair[1]] -eq $true
    if ($a -and $b) {
        throw "Conflicting options: -$($pair[0]) and -$($pair[1]) cannot be used together (check extra_args against the dedicated inputs)."
    }
}

$builderParams['NonInteractive'] = $true
if ($SourceIso) { $builderParams['SourceDrive'] = $SourceIso }
if ($WorkDir)   { $builderParams['WorkDir'] = $WorkDir }

# ------------------------------------------------------------------------------
# Report resolved configuration
# ------------------------------------------------------------------------------
$displayArgs = foreach ($k in $builderParams.Keys) {
    $v = $builderParams[$k]
    if ($v -is [bool]) {
        if ($v) { "-$k" } else { "-${k}:`$false" }
    } elseif ($v -is [hashtable]) {
        "-$k @{ " + (($v.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=`$$($_.Value.ToString().ToLower())" }) -join '; ') + ' }'
    } elseif ($v -is [int]) {
        "-$k $v"
    } else {
        "-$k '$v'"
    }
}
$commandLine = ".\nano11builder.ps1 " + ($displayArgs -join ' ')
Write-Host "Resolved builder command:" -ForegroundColor Cyan
Write-Host "  $commandLine"

if ($PlanOnly) {
    Write-Summary @(
        '### nano11 build configuration',
        '',
        '```powershell',
        $commandLine,
        '```',
        ''
    )
    exit 0
}

# ------------------------------------------------------------------------------
# Run the builder
# ------------------------------------------------------------------------------
if (-not $SourceIso -or -not (Test-Path -LiteralPath $SourceIso)) {
    throw "Source ISO not found: '$SourceIso'"
}

# Without elevation the builder relaunches itself via UAC in a new window and exits 0,
# which would look like a silent success on a headless runner.
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "The runner is not elevated. nano11builder.ps1 needs Administrator rights for DISM and offline registry servicing."
}

# Record the exact command in the logs artifact so a run's settings can be checked afterwards.
$ciLogDir = Join-Path -Path $repoRoot -ChildPath 'logs'
New-Item -ItemType Directory -Force -Path $ciLogDir | Out-Null
Set-Content -LiteralPath (Join-Path -Path $ciLogDir -ChildPath 'ci-build-command.txt') -Value $commandLine -Encoding utf8

$isDryRun = $builderParams.Contains('DryRun') -and $builderParams['DryRun']
$buildStart = Get-Date

# Run the builder in its own process, exactly like a local run. Invoking it in-process
# from inside try/catch would turn its (normally non-fatal) statement errors into a
# terminating error and abort the build. Parameters travel via CliXml so they are
# still splatted with their real types rather than re-parsed from a command line.
$paramsFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'nano11-ci-params.xml'
[hashtable]$splat = @{}
foreach ($k in $builderParams.Keys) { $splat[$k] = $builderParams[$k] }
$splat | Export-Clixml -LiteralPath $paramsFile

$quote = { param($s) "'" + ($s -replace "'", "''") + "'" }
$childCommand = "`$p = Import-Clixml -LiteralPath $(& $quote $paramsFile); & $(& $quote $builderPath) @p"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $childCommand
$builderExit = $LASTEXITCODE
Remove-Item -LiteralPath $paramsFile -Force -ErrorAction SilentlyContinue

# The builder's last native command is often robocopy (exit 1 = success), so the exit
# code alone is not a reliable failure signal; the presence of the ISO decides below.
$builderFailed = $false
if ($builderExit -ne 0) {
    Write-Host "nano11builder.ps1 exited with code $builderExit."
    if ($isDryRun) { $builderFailed = $true }
}

if ($isDryRun) {
    Write-Host "Dry run requested; no ISO is expected."
    Write-Summary @('**Result:** dry run completed (no ISO produced).', '')
    if ($builderFailed) { exit 1 }
    exit 0
}

$isos = @(Get-ChildItem -LiteralPath $repoRoot -Filter 'nano11_*.iso' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $buildStart.AddMinutes(-1) } |
    Sort-Object LastWriteTime -Descending)

if ($builderFailed -or $isos.Count -eq 0) {
    Write-Host "::error::No nano11 ISO was produced. See the build logs artifact for details."
    Write-Summary @('**Result:** :x: build failed, no ISO produced.', '')
    exit 1
}

$hashLines = @()
$summary = @('**Result:** :white_check_mark: build succeeded', '', '| ISO | Size | SHA256 |', '| --- | --- | --- |')
foreach ($iso in $isos) {
    $hash = (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash
    $hashLines += "$hash *$($iso.Name)"
    $summary += "| ``$($iso.Name)`` | $([math]::Round($iso.Length / 1GB, 2)) GB | ``$hash`` |"
}
$hashFile = Join-Path -Path $repoRoot -ChildPath 'nano11_SHA256SUMS.txt'
Set-Content -LiteralPath $hashFile -Value $hashLines -Encoding ascii

Write-Summary ($summary + '')
Write-StepOutput 'iso_name' $isos[0].Name
Write-StepOutput 'iso_path' $isos[0].FullName
Write-StepOutput 'hash_file' $hashFile
Write-Host "Built $($isos.Count) ISO(s):" -ForegroundColor Green
$isos | ForEach-Object { Write-Host "  $($_.FullName)" }
exit 0
