# =================================================================
#  Modulo-Edicion
#
#  CONTENIDO   : Show-CambioEdicion-GUI y helpers de escalado SKU
#  MOTOR       : wimlib-imagex.exe para captura/anexado/verificacion WIM;
#                dism.exe unicamente para servicio CBS (/Get-CurrentEdition,
#                /Get-TargetEditions, /Set-Edition y /Commit-Image).
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log                  : registro de eventos
#    - Get-AIOString              : internacionalizacion
#    - Invoke-AIOWithBaseLanguage : metadatos WIM en idioma base
#    - Set-AIOTabControlStyle     : estilo de pestanas (Modulo-UI.ps1)
#    - Select-SavePathDialog      : dialogo Guardar archivo
#    - Unmount-Hives              : desmontar colmenas offline
#    - Get-AIOFileIdentity / Test-AIOPathWithin / Get-AIOOutputSnapshot / Publish-AIOVerifiedFile
#    - Get-AIOWimContainerInfo (Modulo-Conversion.ps1)
#  CARGA       : . "$PSScriptRoot\Modulo-Edicion.ps1"
#
# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
#
# DUAL LICENSING NOTICE:
# This software is dual-licensed. By default, AdminImagenOffline is
# distributed under the GNU General Public License v3.0 (GPLv3).
# ==============================================================================

function Find-AIOEditionWimlib {
    $bundled = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools\wimlib\wimlib-imagex.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
    $command = Get-Command wimlib-imagex.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command wimlib-imagex -CommandType Application -ErrorAction SilentlyContinue }
    if ($command) { return $command.Source }
    throw (Get-AIOString 'errors.e450')
}

function ConvertTo-AIOEditionArgument {
    param([AllowEmptyString()][string]$Value)
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Initialize-AIOEditionNativeReader {
    if ('AIOEditionNativeReaderV1' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
public sealed class AIOEditionNativeReaderV1 : IDisposable {
    private readonly Process process;
    public readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<string> Error = new ConcurrentQueue<string>();
    public AIOEditionNativeReaderV1(string fileName, string arguments) {
        process = new Process();
        process.StartInfo = new ProcessStartInfo {
            FileName = fileName, Arguments = arguments, UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        process.OutputDataReceived += (sender, args) => { if (args.Data != null) Output.Enqueue(args.Data); };
        process.ErrorDataReceived += (sender, args) => { if (args.Data != null) Error.Enqueue(args.Data); };
    }
    public void Start() {
        if (!process.Start()) throw new InvalidOperationException("No se pudo iniciar el proceso.");
        process.BeginOutputReadLine(); process.BeginErrorReadLine();
    }
    public bool HasExited { get { return process.HasExited; } }
    public int ExitCode { get { return process.ExitCode; } }
    public void WaitForExit() { process.WaitForExit(); }
    public void Dispose() { process.Dispose(); }
}
'@
}

function Get-AIOEditionPercent {
    param([string]$Text)
    foreach ($match in [regex]::Matches($Text, '(?<![\d.,+\-])(?<percent>\d{1,3}(?:[.,]\d+)?)\s*%')) {
        $percent = [double]::Parse($match.Groups['percent'].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        if ($percent -ge 0 -and $percent -le 100) { $percent }
    }
}

function Update-AIOEditionNativeProgress {
    param([hashtable]$ProgressState, [string]$Line)
    if (-not $ProgressState -or [string]::IsNullOrWhiteSpace($Line)) { return }

    if ($Line -match '^\s*Scanning\s+') {
        $ProgressState.NativePhaseKey = 'Scanning'
        $ProgressState.NativePhase = Get-AIOString 'edition.gui_phase_scan'
        $ProgressState.NativePercent = -1.0
        return
    }

    $phase = ''; $key = ''
    if ($Line -match '^\s*Archiving file data:') { $phase = Get-AIOString 'edition.gui_phase_archive'; $key = 'Archive' }
    elseif ($Line -match '^\s*Verifying integrity of "([^"]+)":') { $phase = Get-AIOString 'edition.gui_phase_verify'; $key = 'Integrity:' + $Matches[1] }
    elseif ($Line -match '^\s*Calculating integrity table for WIM:') { $phase = Get-AIOString 'edition.gui_phase_integrity'; $key = 'IntegrityTable' }
    elseif ($Line -match '^\s*Verifying file data:') { $phase = Get-AIOString 'edition.gui_phase_verify'; $key = 'VerifyData' }
    elseif ($Line -match '^\s*\[.*\d+(?:[.,]\d+)?\s*%.*\]\s*$') { $phase = Get-AIOString 'edition.gui_phase_dism'; $key = 'DismProgress' }
    else { return }

    $percents = @(Get-AIOEditionPercent $Line)
    if ($percents.Count -eq 0) { return }
    $percent = $percents[-1]

    if ($ProgressState.NativePhaseKey -ne $key) {
        $ProgressState.NativePhaseKey = $key
        $ProgressState.NativePercent = -1.0
    }
    if ($percent -ge [double]$ProgressState.NativePercent) {
        $ProgressState.NativePhase = $phase
        $ProgressState.NativePercent = $percent
    }
}

function Invoke-AIOEditionNativeProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [hashtable]$ProgressState,
        [scriptblock]$OnTick,
        [string]$InitialPhase = ''
    )

    Initialize-AIOEditionNativeReader
    $argumentText = (@($Arguments | ForEach-Object { ConvertTo-AIOEditionArgument $_ }) -join ' ')
    $reader = New-Object AIOEditionNativeReaderV1($Executable, $argumentText)
    $tail = New-Object 'System.Collections.Generic.List[string]'

    if ($ProgressState) {
        $ProgressState.NativePercent = -1.0
        $ProgressState.NativePhaseKey = ''
        $ProgressState.NativeActive = $true
        $ProgressState.NativeSucceeded = $false
        $ProgressState.NativePhase = if ($InitialPhase) { $InitialPhase } else { Get-AIOString 'edition.gui_phase_working' }
    }

    try {
        $reader.Start()
        do {
            $exited = $reader.HasExited
            if ($exited) { $reader.WaitForExit() }
            foreach ($queue in @($reader.Output, $reader.Error)) {
                $line = $null
                while ($queue.TryDequeue([ref]$line)) {
                    Update-AIOEditionNativeProgress $ProgressState $line
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $tail.Add($line)
                        if ($tail.Count -gt 25) { $tail.RemoveAt(0) }
                    }
                }
            }
            if ($OnTick) { & $OnTick }
            [System.Windows.Forms.Application]::DoEvents()
            if (-not $exited) { Start-Sleep -Milliseconds 75 }
        } while (-not $exited)

        $exitCode = [int]$reader.ExitCode
        if ($ProgressState) {
            $ProgressState.NativeActive = $false
            $ProgressState.NativeSucceeded = ($exitCode -in @(0, 3010))
            if ($ProgressState.NativeSucceeded -and $ProgressState.NativePercent -ge 0) {
                $ProgressState.NativePercent = 100.0
            }
            if ($OnTick) { & $OnTick }
        }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Tail     = ($tail -join "`n")
        }
    } finally {
        $reader.Dispose()
        if ($ProgressState) { $ProgressState.NativeActive = $false }
    }
}

function Get-AIOEditionDismPath {
    if (Get-Command Get-AIOMountNativeDismPath -ErrorAction SilentlyContinue) {
        return Get-AIOMountNativeDismPath
    }
    $sysnative = Join-Path $env:WINDIR 'Sysnative\dism.exe'
    if (Test-Path -LiteralPath $sysnative -PathType Leaf) { return $sysnative }
    return (Join-Path $env:WINDIR 'System32\dism.exe')
}

function Get-AIOEditionWimIndexCount {
    param(
        [string]$WimlibExe,
        [string]$WimPath
    )
    try {
        $out = @(& $WimlibExe info $WimPath --header 2>$null)
        foreach ($line in $out) {
            if ($line -match '^\s*Image Count\s*:\s*(\d+)') {
                return [int]$Matches[1]
            }
        }
    } catch { }
    return -1
}

function Get-AIOEditionSourceWindowsMeta {
    param([string]$WimlibExe)
    $meta = @{
        Arch             = ''
        ProductName      = 'Microsoft® Windows® Operating System'
        InstallationType = ''
        Hal              = ''
        ProductType      = ''
        ProductSuite     = ''
        SystemRoot       = 'WINDOWS'
        Major            = ''
        Minor            = ''
        Build            = ''
        SPBuild          = ''
        SPLevel          = ''
        Languages        = @()
        DefaultLanguage  = ''
    }

    if ($Script:IMAGE_MOUNTED -eq 1 -and $Script:WIM_FILE_PATH -and (Test-Path -LiteralPath $Script:WIM_FILE_PATH -PathType Leaf)) {
        $xmlPath = Join-Path ([IO.Path]::GetTempPath()) ('AIO-edmeta-' + [Guid]::NewGuid().ToString('N') + '.xml')
        try {
            & $WimlibExe info $Script:WIM_FILE_PATH --extract-xml $xmlPath *> $null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
                [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
                $img = @($xml.WIM.IMAGE) | Where-Object { [int]$_.INDEX -eq [int]$Script:MOUNTED_INDEX } | Select-Object -First 1
                if ($null -ne $img -and $null -ne $img.WINDOWS) {
                    $w = $img.WINDOWS
                    if ($w.ARCH) { $meta.Arch = [string]$w.ARCH }
                    if ($w.PRODUCTNAME) { $meta.ProductName = [string]$w.PRODUCTNAME }
                    if ($w.INSTALLATIONTYPE) { $meta.InstallationType = [string]$w.INSTALLATIONTYPE }
                    if ($w.HAL) { $meta.Hal = [string]$w.HAL }
                    if ($w.PRODUCTTYPE) { $meta.ProductType = [string]$w.PRODUCTTYPE }
                    if ($w.PRODUCTSUITE) { $meta.ProductSuite = [string]$w.PRODUCTSUITE }
                    if ($w.SYSTEMROOT) { $meta.SystemRoot = [string]$w.SYSTEMROOT }
                    if ($null -ne $w.VERSION) {
                        if ($w.VERSION.MAJOR) { $meta.Major = [string]$w.VERSION.MAJOR }
                        if ($w.VERSION.MINOR) { $meta.Minor = [string]$w.VERSION.MINOR }
                        if ($w.VERSION.BUILD) { $meta.Build = [string]$w.VERSION.BUILD }
                        if ($w.VERSION.SPBUILD) { $meta.SPBuild = [string]$w.VERSION.SPBUILD }
                        if ($null -ne $w.VERSION.SPLEVEL -and [string]$w.VERSION.SPLEVEL -ne '') { $meta.SPLevel = [string]$w.VERSION.SPLEVEL }
                    }
                    if ($null -ne $w.LANGUAGES) {
                        $langs = @($w.LANGUAGES.LANGUAGE | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
                        if ($langs.Count -gt 0) { $meta.Languages = $langs }
                        if ($w.LANGUAGES.DEFAULT) { $meta.DefaultLanguage = [string]$w.LANGUAGES.DEFAULT }
                    }
                }
            }
        } catch {
            Write-Log -LogLevel WARN -Message "CAMBIO_EDICION: No se pudo leer XML base con wimlib: $($_.Exception.Message)"
        } finally {
            if ([IO.File]::Exists($xmlPath)) { Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue }
        }
    }

    # Respaldo desde cache del Dashboard si faltan datos (ej. VHD)
    if ($null -ne $Script:AIODashboardCache -and $null -ne $Script:AIODashboardCache.Data) {
        $d = $Script:AIODashboardCache.Data
        if (-not $meta.Arch -and $d.Arch) {
            switch -Regex ([string]$d.Arch) {
                'x64|amd64|64' { $meta.Arch = '9' }
                'arm64'        { $meta.Arch = '12' }
                'x86|32'       { $meta.Arch = '0' }
            }
        }
        if (-not $meta.Build -and $d.Build -match '^(\d+)(?:\.(\d+))?') {
            $meta.Major = '10'
            $meta.Minor = '0'
            $meta.Build = $Matches[1]
            if ($Matches[2]) { $meta.SPBuild = $Matches[2] }
        }
    }

    return $meta
}

function Set-AIOEditionWimIndexMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WimlibExe,
        [Parameter(Mandatory = $true)]
        [string]$WimPath,
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [string]$EditionID,
        [Parameter(Mandatory = $true)]
        [string]$ImageName,
        [Parameter(Mandatory = $true)]
        [string]$ImageDesc,
        [hashtable]$SourceWindowsMeta
    )

    $props = New-Object 'System.Collections.Generic.List[string]'
    $addProp = {
        param([string]$Key, [string]$Val)
        if (-not [string]::IsNullOrWhiteSpace($Val)) {
            $props.Add('--image-property')
            $props.Add("${Key}=${Val}")
        }
    }

    & $addProp 'NAME' $ImageName
    & $addProp 'DESCRIPTION' $ImageDesc
    & $addProp 'DISPLAYNAME' $ImageName
    & $addProp 'DISPLAYDESCRIPTION' $ImageDesc
    & $addProp 'FLAGS' $EditionID
    & $addProp 'WINDOWS/EDITIONID' $EditionID

    if ($null -ne $SourceWindowsMeta) {
        $isServerEd = ($EditionID -match '^Server(?!Rdsh$)')
        $instType = if ($SourceWindowsMeta.InstallationType) {
            $SourceWindowsMeta.InstallationType
        } elseif ($isServerEd) { 'Server' } else { 'Client' }
        $prodType = if ($SourceWindowsMeta.ProductType) {
            $SourceWindowsMeta.ProductType
        } elseif ($isServerEd) { 'ServerNT' } else { 'WinNT' }

        & $addProp 'WINDOWS/ARCH' ([string]$SourceWindowsMeta.Arch)
        & $addProp 'WINDOWS/PRODUCTNAME' ([string]$SourceWindowsMeta.ProductName)
        & $addProp 'WINDOWS/INSTALLATIONTYPE' $instType
        & $addProp 'WINDOWS/HAL' ([string]$SourceWindowsMeta.Hal)
        & $addProp 'WINDOWS/PRODUCTTYPE' $prodType
        & $addProp 'WINDOWS/PRODUCTSUITE' ([string]$SourceWindowsMeta.ProductSuite)
        & $addProp 'WINDOWS/SYSTEMROOT' ([string]$SourceWindowsMeta.SystemRoot)
        & $addProp 'WINDOWS/VERSION/MAJOR' ([string]$SourceWindowsMeta.Major)
        & $addProp 'WINDOWS/VERSION/MINOR' ([string]$SourceWindowsMeta.Minor)
        & $addProp 'WINDOWS/VERSION/BUILD' ([string]$SourceWindowsMeta.Build)
        & $addProp 'WINDOWS/VERSION/SPBUILD' ([string]$SourceWindowsMeta.SPBuild)
        & $addProp 'WINDOWS/VERSION/SPLEVEL' ([string]$SourceWindowsMeta.SPLevel)

        $langs = @($SourceWindowsMeta.Languages)
        if ($langs.Count -eq 1) {
            & $addProp 'WINDOWS/LANGUAGES/LANGUAGE' ([string]$langs[0])
        } elseif ($langs.Count -gt 1) {
            for ($li = 0; $li -lt $langs.Count; $li++) {
                & $addProp ("WINDOWS/LANGUAGES/LANGUAGE[$($li + 1)]") ([string]$langs[$li])
            }
        }
        & $addProp 'WINDOWS/LANGUAGES/DEFAULT' ([string]$SourceWindowsMeta.DefaultLanguage)
    }

    $infoArgs = @('info', $WimPath, [string]$Index) + @($props)
    & $WimlibExe @infoArgs *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Log -LogLevel WARN -Message "CAMBIO_EDICION (GUI): wimlib info devolvio codigo $LASTEXITCODE al aplicar metadatos al indice $Index ($EditionID)."
        return $false
    }
    Write-Log -LogLevel INFO -Message "CAMBIO_EDICION (GUI): Metadatos aplicados al indice #$Index (NAME='$ImageName', FLAGS/EDITIONID='$EditionID')."
    return $true
}

function Get-AIOEditionTierRank {
    param([string]$EditionID)
    $order = @(
        'Starter', 'StarterN',
        'Cloud', 'CloudN',
        'CloudEdition', 'CloudEditionN',
        'CoreCountrySpecific', 'CoreSingleLanguage', 'Core', 'CoreN', 'CoreK',
        'ProfessionalCountrySpecific', 'ProfessionalSingleLanguage', 'Professional', 'ProfessionalN',
        'ProfessionalEducation', 'ProfessionalEducationN',
        'ProfessionalWorkstation', 'ProfessionalWorkstationN',
        'Education', 'EducationN',
        'Enterprise', 'EnterpriseN', 'EnterpriseG', 'EnterpriseGN',
        'IoTEnterprise', 'IoTEnterpriseK', 'ServerRdsh',
        'EnterpriseS', 'EnterpriseSN', 'IoTEnterpriseS', 'IoTEnterpriseSK',
        'ServerSolution',
        'ServerStandardCoreEval', 'ServerStandardEval',
        'ServerStandardCore', 'ServerStandardACor', 'ServerStandard',
        'ServerDatacenterCoreEval', 'ServerDatacenterEval',
        'ServerDatacenterCore', 'ServerDatacenterACor', 'ServerDatacenter',
        'ServerAzureCor', 'ServerTurbineCor', 'ServerTurbine'
    )
    for ($i = 0; $i -lt $order.Count; $i++) {
        if ([string]::Equals($order[$i], $EditionID, [StringComparison]::OrdinalIgnoreCase)) {
            return $i
        }
    }
    return 999
}

function Get-AIOTargetEditionsFromMount {
    $targets = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $dismTargets = dism /Image:$Script:MOUNT_DIR /Get-TargetEditions /English 2>$null
        $dismTargets | Select-String "Target Edition :" | ForEach-Object {
            $line = ($_.Line -split ':', 2)[1].Trim()
            if ($line -and $seen.Add($line)) { $targets += $line }
        }
    } catch { }
    return ,$targets
}

function Get-AIOCurrentEditionFromMount {
    try {
        $dismEdition = dism /Image:$Script:MOUNT_DIR /Get-CurrentEdition /English 2>$null
        $currentEditionLine = $dismEdition | Select-String -Pattern "(Current Edition|Edici.n actual)\s*:"
        if ($currentEditionLine) {
            return ($currentEditionLine.Line -split ':', 2)[1].Trim()
        }
    } catch { }
    return $null
}

function Get-AIOKnownReachableEditions {
    param(
        [string]$CurrentEdition,
        [string[]]$DirectTargets
    )
    $allSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = @()

    foreach ($t in $DirectTargets) {
        if (-not [string]::IsNullOrWhiteSpace($t) -and $allSet.Add($t)) {
            $candidates += [PSCustomObject]@{ EditionID = $t; IsDirect = $true; Rank = (Get-AIOEditionTierRank $t) }
        }
    }

    $currentRank = Get-AIOEditionTierRank $CurrentEdition
    $isServer = ($CurrentEdition -match '^Server(?!Rdsh$)')
    $isLTSC = ($CurrentEdition -match '^(EnterpriseS|EnterpriseSN|IoTEnterpriseS|IoTEnterpriseSK)(Eval)?$')
    $isN = (-not $isServer) -and ($CurrentEdition -match 'N$' -or $CurrentEdition -match 'NEval$')

    $familyPool = if ($isServer) {
        @('ServerStandardCore', 'ServerStandard', 'ServerDatacenterCore', 'ServerDatacenter', 'ServerAzureCor', 'ServerTurbineCor', 'ServerTurbine')
    } elseif ($isLTSC) {
        if ($isN) { @('EnterpriseSN') } else { @('EnterpriseS', 'IoTEnterpriseS', 'IoTEnterpriseSK') }
    } elseif ($isN) {
        @('ProfessionalN', 'ProfessionalEducationN', 'ProfessionalWorkstationN', 'EducationN', 'EnterpriseN', 'EnterpriseGN')
    } else {
        @('Professional', 'ProfessionalEducation', 'ProfessionalWorkstation', 'Education', 'Enterprise', 'IoTEnterprise', 'ServerRdsh')
    }

    foreach ($ed in $familyPool) {
        if ([string]::Equals($ed, $CurrentEdition, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rank = Get-AIOEditionTierRank $ed
        if ($rank -gt $currentRank -and $allSet.Add($ed)) {
            $candidates += [PSCustomObject]@{ EditionID = $ed; IsDirect = $false; Rank = $rank }
        }
    }

    return ,@($candidates | Sort-Object -Property Rank, EditionID)
}

function Get-AIOEditionCaptureMetadata {
    param(
        [string]$EditionID,
        [string]$OsVersionPrefix
    )
    $imgName = "Windows $EditionID"
    $imgDesc = Invoke-AIOWithBaseLanguage { Get-AIOString 'save.default_desc_fmt' (Get-Date -Format 'yyyy-MM-dd') }

    try {
        $catalogPath = Join-Path $PSScriptRoot 'Catalogos\Ediciones.ps1'
        if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
            Invoke-AIOWithBaseLanguage { . $catalogPath } | Out-Null
            if (Get-Command Get-WindowsEditionMetadata -ErrorAction SilentlyContinue) {
                $meta = Get-WindowsEditionMetadata -QueryString $EditionID
                if ($null -ne $meta) {
                    $rawName = [string]$meta.Name
                    if (-not [string]::IsNullOrWhiteSpace($rawName)) {
                        if ($OsVersionPrefix -match '^Windows\s+(10|11)$' -and $EditionID -notmatch '^Server(?!Rdsh$)') {
                            $imgName = $rawName -replace '^Windows(?:\s+(?:10|11))?\s+', ($OsVersionPrefix + ' ')
                        } else {
                            $imgName = $rawName
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$meta.Description)) {
                        $imgDesc = [string]$meta.Description
                    }
                }
            }
        }
    } catch {
        Write-Log -LogLevel WARN -Message "CAMBIO_EDICION: No se pudo resolver metadatos de catalogo para '$EditionID': $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        Name        = $imgName
        Description = $imgDesc
    }
}

function New-AIOEditionDarkGrid {
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.BorderStyle = 'FixedSingle'
    $grid.GridColor = [System.Drawing.Color]::FromArgb(62, 62, 68)
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(38, 38, 42)
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersBorderStyle = 'Single'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersHeight = 28
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 228)
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(220, 220, 228)
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 44)
    $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 50)
    $grid.RowTemplate.Height = 26
    return $grid
}

function Show-CambioEdicion-GUI {
    [CmdletBinding()]
    param(
        [string]$CurrentEdition = '',
        [string]$OsVersionFriendly = 'Desconocida',
        [string[]]$InitialTargets = @()
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            (Get-AIOString 'common.mount_required_short'),
            (Get-AIOString 'common.error_title'),
            'OK', 'Error'
        ) | Out-Null
        return
    }

    $wimlibExe = $null
    try {
        $wimlibExe = Find-AIOEditionWimlib
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            (Get-AIOString 'common.error_title'),
            'OK', 'Error'
        ) | Out-Null
        return
    }
    $dismExe = Get-AIOEditionDismPath

    $editionsFile = Join-Path $PSScriptRoot 'Catalogos\Ediciones.ps1'
    if (-not (Test-Path -LiteralPath $editionsFile -PathType Leaf)) {
        $editionsFile = Join-Path $PSScriptRoot 'Modulo-Ediciones.ps1'
    }
    if (Test-Path -LiteralPath $editionsFile -PathType Leaf) {
        . $editionsFile
    }

    $getFriendly = {
        param([string]$EdId)
        if ([string]::IsNullOrWhiteSpace($EdId)) { return 'Desconocida' }
        if (Get-Command Get-WindowsEditionMetadata -ErrorAction SilentlyContinue) {
            $m = Get-WindowsEditionMetadata -QueryString $EdId
            return ($m.Name -replace '(?i)^Windows ', '')
        }
        return $EdId
    }

    $getDescription = {
        param([string]$EdId)
        if (Get-Command Get-WindowsEditionMetadata -ErrorAction SilentlyContinue) {
            $m = Get-WindowsEditionMetadata -QueryString $EdId
            if ($null -ne $m -and -not [string]::IsNullOrWhiteSpace([string]$m.Description)) {
                return [string]$m.Description
            }
        }
        return ''
    }

    $isEsd = ($Script:IMAGE_MOUNTED -eq 1 -and $Script:WIM_FILE_PATH -match '\.esd$')
    $canAppendMounted = ($Script:IMAGE_MOUNTED -eq 1 -and -not $isEsd)

    $defaultDir = 'C:\'
    $defaultBase = 'Imagen'
    if ($Script:WIM_FILE_PATH -and (Test-Path -LiteralPath $Script:WIM_FILE_PATH)) {
        $wimObj = Get-Item -LiteralPath $Script:WIM_FILE_PATH
        $defaultDir = $wimObj.DirectoryName
        $defaultBase = $wimObj.BaseName
    }
    $defaultDestWim = Join-Path $defaultDir "${defaultBase}_Escalado.wim"

    $state = [PSCustomObject]@{
        CurrentEdition = $CurrentEdition
        OsVersion      = $OsVersionFriendly
        DirectTargets  = @($InitialTargets)
        IsRunning      = $false
        CancelPending  = $false
        ProgressValue  = 0
        ProgressBusy   = $false
        Animation      = 0
        Native         = @{
            NativePercent   = -1.0
            NativePhase     = ''
            NativePhaseKey  = ''
            NativeActive    = $false
            NativeSucceeded = $false
        }
    }

    # --- Ventana principal (compacta, sin consola redundante) ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = Get-AIOString 'edition.gui_title'
    $form.Size = New-Object System.Drawing.Size(900, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(800, 560)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.AutoScaleMode = 'Dpi'

    # Layout raiz: Header | Tabs (DataGridView oscuro) | Opciones guardado | Barras de estado/progreso | Botonera
    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.Padding = New-Object System.Windows.Forms.Padding(12)
    $root.ColumnCount = 1
    $root.RowCount = 5
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 68)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 112)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 88)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 44)))
    $form.Controls.Add($root)

    # --- 1. Cabecera ---
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = 'Fill'
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 42)
    $headerPanel.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
    $root.Controls.Add($headerPanel, 0, 0)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = Get-AIOString 'edition.gui_header'
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 210, 255)
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(12, 8)
    $headerPanel.Controls.Add($lblTitle)

    $mountBadge = if ($Script:IMAGE_MOUNTED -eq 2) { 'VHD/VHDX' } elseif ($isEsd) { 'ESD' } else { "WIM #$($Script:MOUNTED_INDEX)" }
    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = Get-AIOString 'edition.gui_info_bar' -FormatArgs @($state.OsVersion, (& $getFriendly $state.CurrentEdition), $mountBadge, $Script:MOUNT_DIR)
    $lblInfo.ForeColor = [System.Drawing.Color]::Gainsboro
    $lblInfo.AutoSize = $true
    $lblInfo.Location = New-Object System.Drawing.Point(12, 36)
    $headerPanel.Controls.Add($lblInfo)

    # --- 2. Pestanas de modos ---
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 6)
    $root.Controls.Add($tabs, 0, 1)

    # === Tab 1: Cambio unico ===
    $tabSingle = New-Object System.Windows.Forms.TabPage
    $tabSingle.Text = Get-AIOString 'edition.gui_tab_single'
    $tabSingle.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $tabSingle.ForeColor = [System.Drawing.Color]::White
    $tabSingle.Padding = New-Object System.Windows.Forms.Padding(8)
    [void]$tabs.TabPages.Add($tabSingle)

    $singleLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $singleLayout.Dock = 'Fill'
    $singleLayout.ColumnCount = 1
    $singleLayout.RowCount = 2
    [void]$singleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 24)))
    [void]$singleLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $tabSingle.Controls.Add($singleLayout)

    $lblSingleHint = New-Object System.Windows.Forms.Label
    $lblSingleHint.Text = Get-AIOString 'edition.gui_single_hint'
    $lblSingleHint.ForeColor = [System.Drawing.Color]::Silver
    $lblSingleHint.Dock = 'Fill'
    $singleLayout.Controls.Add($lblSingleHint, 0, 0)

    $dgvSingle = New-AIOEditionDarkGrid
    $dgvSingle.ReadOnly = $true
    $cS1 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cS1.HeaderText = Get-AIOString 'edition.gui_col_edition'; $cS1.Width = 210; $cS1.SortMode = 'NotSortable'
    $cS2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cS2.HeaderText = Get-AIOString 'edition.gui_col_id'; $cS2.Width = 175; $cS2.SortMode = 'NotSortable'
    $cS3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cS3.HeaderText = Get-AIOString 'edition.gui_col_desc'; $cS3.AutoSizeMode = 'Fill'; $cS3.SortMode = 'NotSortable'
    [void]$dgvSingle.Columns.Add($cS1)
    [void]$dgvSingle.Columns.Add($cS2)
    [void]$dgvSingle.Columns.Add($cS3)
    $singleLayout.Controls.Add($dgvSingle, 0, 1)

    # === Tab 2: Escalado automatico ===
    $tabAuto = New-Object System.Windows.Forms.TabPage
    $tabAuto.Text = Get-AIOString 'edition.gui_tab_auto'
    $tabAuto.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $tabAuto.ForeColor = [System.Drawing.Color]::White
    $tabAuto.Padding = New-Object System.Windows.Forms.Padding(14)
    [void]$tabs.TabPages.Add($tabAuto)

    $lblAutoDesc = New-Object System.Windows.Forms.Label
    $lblAutoDesc.Text = Get-AIOString 'edition.gui_auto_desc'
    $lblAutoDesc.ForeColor = [System.Drawing.Color]::Gainsboro
    $lblAutoDesc.Dock = 'Top'
    $lblAutoDesc.Height = 64
    $tabAuto.Controls.Add($lblAutoDesc)

    # === Tab 3: Seleccion personalizada ===
    $tabCustom = New-Object System.Windows.Forms.TabPage
    $tabCustom.Text = Get-AIOString 'edition.gui_tab_custom'
    $tabCustom.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $tabCustom.ForeColor = [System.Drawing.Color]::White
    $tabCustom.Padding = New-Object System.Windows.Forms.Padding(8)
    [void]$tabs.TabPages.Add($tabCustom)

    $customLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $customLayout.Dock = 'Fill'
    $customLayout.ColumnCount = 1
    $customLayout.RowCount = 2
    [void]$customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 34)))
    [void]$customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $tabCustom.Controls.Add($customLayout)

    $customBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $customBar.Dock = 'Fill'
    $customBar.FlowDirection = 'LeftToRight'
    $customBar.WrapContents = $false
    $customLayout.Controls.Add($customBar, 0, 0)

    $btnSelAll = New-Object System.Windows.Forms.Button
    $btnSelAll.Text = Get-AIOString 'edition.gui_btn_sel_all'
    $btnSelAll.Size = New-Object System.Drawing.Size(135, 26)
    $btnSelAll.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 66)
    $btnSelAll.ForeColor = [System.Drawing.Color]::White
    $btnSelAll.FlatStyle = 'Flat'
    $customBar.Controls.Add($btnSelAll)

    $btnSelNone = New-Object System.Windows.Forms.Button
    $btnSelNone.Text = Get-AIOString 'edition.gui_btn_sel_none'
    $btnSelNone.Size = New-Object System.Drawing.Size(145, 26)
    $btnSelNone.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 66)
    $btnSelNone.ForeColor = [System.Drawing.Color]::White
    $btnSelNone.FlatStyle = 'Flat'
    $customBar.Controls.Add($btnSelNone)

    $lblCustomCount = New-Object System.Windows.Forms.Label
    $lblCustomCount.Text = Get-AIOString 'edition.gui_selected_count' -FormatArgs @(0, 0)
    $lblCustomCount.ForeColor = [System.Drawing.Color]::Cyan
    $lblCustomCount.AutoSize = $true
    $lblCustomCount.Margin = New-Object System.Windows.Forms.Padding(12, 6, 0, 0)
    $customBar.Controls.Add($lblCustomCount)

    $dgvCustom = New-AIOEditionDarkGrid
    $dgvCustom.ReadOnly = $false
    $cC0 = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $cC0.HeaderText = ''; $cC0.Width = 34; $cC0.Resizable = 'False'; $cC0.SortMode = 'NotSortable'
    $cC1 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cC1.HeaderText = Get-AIOString 'edition.gui_col_edition'; $cC1.Width = 195; $cC1.ReadOnly = $true; $cC1.SortMode = 'NotSortable'
    $cC2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cC2.HeaderText = Get-AIOString 'edition.gui_col_id'; $cC2.Width = 155; $cC2.ReadOnly = $true; $cC2.SortMode = 'NotSortable'
    $cC3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cC3.HeaderText = Get-AIOString 'edition.gui_col_avail'; $cC3.Width = 115; $cC3.ReadOnly = $true; $cC3.SortMode = 'NotSortable'
    $cC4 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cC4.HeaderText = Get-AIOString 'edition.gui_col_desc'; $cC4.AutoSizeMode = 'Fill'; $cC4.ReadOnly = $true; $cC4.SortMode = 'NotSortable'
    [void]$dgvCustom.Columns.Add($cC0)
    [void]$dgvCustom.Columns.Add($cC1)
    [void]$dgvCustom.Columns.Add($cC2)
    [void]$dgvCustom.Columns.Add($cC3)
    [void]$dgvCustom.Columns.Add($cC4)
    $customLayout.Controls.Add($dgvCustom, 0, 1)

    if (Get-Command Set-AIOTabControlStyle -ErrorAction SilentlyContinue) {
        Set-AIOTabControlStyle -TabControl $tabs
    }

    # --- 3. Opciones de guardado ---
    $grpSave = New-Object System.Windows.Forms.GroupBox
    $grpSave.Text = Get-AIOString 'edition.gui_save_group'
    $grpSave.ForeColor = [System.Drawing.Color]::FromArgb(200, 220, 255)
    $grpSave.Dock = 'Fill'
    $grpSave.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $root.Controls.Add($grpSave, 0, 2)

    $rbNewWim = New-Object System.Windows.Forms.RadioButton
    $rbNewWim.Text = Get-AIOString 'edition.gui_rb_newwim'
    $rbNewWim.Location = New-Object System.Drawing.Point(12, 20)
    $rbNewWim.AutoSize = $true
    $rbNewWim.Checked = $true
    $rbNewWim.ForeColor = [System.Drawing.Color]::LightGreen
    $grpSave.Controls.Add($rbNewWim)

    $txtDestWim = New-Object System.Windows.Forms.TextBox
    $txtDestWim.Text = $defaultDestWim
    $txtDestWim.Location = New-Object System.Drawing.Point(28, 44)
    $txtDestWim.Size = New-Object System.Drawing.Size(500, 23)
    $txtDestWim.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 50)
    $txtDestWim.ForeColor = [System.Drawing.Color]::White
    $grpSave.Controls.Add($txtDestWim)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = Get-AIOString 'edition.gui_btn_browse'
    $btnBrowse.Location = New-Object System.Drawing.Point(536, 42)
    $btnBrowse.Size = New-Object System.Drawing.Size(105, 25)
    $btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(65, 65, 72)
    $btnBrowse.ForeColor = [System.Drawing.Color]::White
    $btnBrowse.FlatStyle = 'Flat'
    $grpSave.Controls.Add($btnBrowse)

    $chkIncludeBase = New-Object System.Windows.Forms.CheckBox
    $chkIncludeBase.Text = Get-AIOString 'edition.gui_chk_include_base'
    $chkIncludeBase.Location = New-Object System.Drawing.Point(652, 44)
    $chkIncludeBase.AutoSize = $true
    $chkIncludeBase.Checked = $true
    $chkIncludeBase.ForeColor = [System.Drawing.Color]::White
    $grpSave.Controls.Add($chkIncludeBase)

    $rbAppend = New-Object System.Windows.Forms.RadioButton
    $rbAppend.Text = Get-AIOString 'edition.gui_rb_append'
    $rbAppend.Location = New-Object System.Drawing.Point(12, 74)
    $rbAppend.AutoSize = $true
    $rbAppend.Enabled = $canAppendMounted
    $rbAppend.ForeColor = if ($canAppendMounted) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Gray }
    $grpSave.Controls.Add($rbAppend)

    $chkCommitBase = New-Object System.Windows.Forms.CheckBox
    $chkCommitBase.Text = Get-AIOString 'edition.gui_chk_commit_base'
    $chkCommitBase.Location = New-Object System.Drawing.Point(435, 75)
    $chkCommitBase.AutoSize = $true
    $chkCommitBase.Checked = $true
    $chkCommitBase.Enabled = $false
    $chkCommitBase.ForeColor = [System.Drawing.Color]::Silver
    $grpSave.Controls.Add($chkCommitBase)

    # --- 4. Barras de estado y progreso dobles (en lugar de la consola) ---
    $statusBox = New-Object System.Windows.Forms.TableLayoutPanel
    $statusBox.Dock = 'Fill'
    $statusBox.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 2)
    $statusBox.RowCount = 4
    $statusBox.ColumnCount = 1
    foreach ($h in @(32, 18, 32, 18)) {
        [void]$statusBox.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', $h)))
    }
    $root.Controls.Add($statusBox, 0, 3)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = Get-AIOString 'edition.gui_status_ready'
    $lblStatus.Dock = 'Fill'
    $lblStatus.AutoEllipsis = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan

    $progress = New-Object System.Windows.Forms.Panel
    $progress.Dock = 'Fill'
    $progress.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.BackColor = [System.Drawing.Color]::LightGreen
    $progressFill.Width = 0
    $progress.Controls.Add($progressFill)

    $lblNativeStatus = New-Object System.Windows.Forms.Label
    $lblNativeStatus.Text = Get-AIOString 'edition.gui_native_idle'
    $lblNativeStatus.Dock = 'Fill'
    $lblNativeStatus.AutoEllipsis = $true
    $lblNativeStatus.ForeColor = [System.Drawing.Color]::Silver

    $nativeProgress = New-Object System.Windows.Forms.Panel
    $nativeProgress.Dock = 'Fill'
    $nativeProgress.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $nativeFill = New-Object System.Windows.Forms.Panel
    $nativeFill.BackColor = [System.Drawing.Color]::DodgerBlue
    $nativeFill.Width = 0
    $nativeProgress.Controls.Add($nativeFill)

    $statusBox.Controls.Add($lblStatus, 0, 0)
    $statusBox.Controls.Add($progress, 0, 1)
    $statusBox.Controls.Add($lblNativeStatus, 0, 2)
    $statusBox.Controls.Add($nativeProgress, 0, 3)

    # --- 5. Botonera inferior ---
    $btnBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnBar.Dock = 'Fill'
    $btnBar.FlowDirection = 'RightToLeft'
    $btnBar.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $root.Controls.Add($btnBar, 0, 4)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = Get-AIOString 'edition.gui_btn_close'
    $btnClose.Size = New-Object System.Drawing.Size(100, 32)
    $btnClose.BackColor = [System.Drawing.Color]::FromArgb(65, 65, 70)
    $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.FlatStyle = 'Flat'
    $btnBar.Controls.Add($btnClose)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = Get-AIOString 'edition.gui_btn_cancel_after'
    $btnCancel.Size = New-Object System.Drawing.Size(175, 32)
    $btnCancel.BackColor = [System.Drawing.Color]::DarkOrange
    $btnCancel.ForeColor = [System.Drawing.Color]::Black
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.Enabled = $false
    $btnBar.Controls.Add($btnCancel)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = Get-AIOString 'edition.gui_btn_run_single'
    $btnRun.Size = New-Object System.Drawing.Size(185, 32)
    $btnRun.BackColor = [System.Drawing.Color]::SeaGreen
    $btnRun.ForeColor = [System.Drawing.Color]::White
    $btnRun.FlatStyle = 'Flat'
    $btnBar.Controls.Add($btnRun)

    # --- ToolTips (patron limpio de Modulo-IntegrarIndices, sin conflictos entre contenedores) ---
    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.ShowAlways = $true

    $dgvSingle.ShowCellToolTips = $true
    $dgvCustom.ShowCellToolTips = $true

    $tips.SetToolTip($lblSingleHint, (Get-AIOString 'tips.edicion.dgvSingle'))
    $tips.SetToolTip($lblAutoDesc, (Get-AIOString 'edition.gui_auto_desc'))
    $tips.SetToolTip($lblCustomCount, (Get-AIOString 'tips.edicion.dgvCustom'))
    $tips.SetToolTip($btnSelAll, (Get-AIOString 'tips.edicion.btnSelAll'))
    $tips.SetToolTip($btnSelNone, (Get-AIOString 'tips.edicion.btnSelNone'))
    $tips.SetToolTip($rbNewWim, (Get-AIOString 'tips.edicion.rbNewWim'))
    $tips.SetToolTip($txtDestWim, (Get-AIOString 'tips.edicion.txtDestWim'))
    $tips.SetToolTip($btnBrowse, (Get-AIOString 'tips.edicion.btnBrowse'))
    $tips.SetToolTip($chkIncludeBase, (Get-AIOString 'tips.edicion.chkIncludeBase'))
    $tips.SetToolTip($rbAppend, (Get-AIOString 'tips.edicion.rbAppend'))
    $tips.SetToolTip($chkCommitBase, (Get-AIOString 'tips.edicion.chkCommitBase'))
    $tips.SetToolTip($lblStatus, (Get-AIOString 'tips.edicion.progress'))
    $tips.SetToolTip($progress, (Get-AIOString 'tips.edicion.progress'))
    $tips.SetToolTip($progressFill, (Get-AIOString 'tips.edicion.progress'))
    $tips.SetToolTip($lblNativeStatus, (Get-AIOString 'tips.edicion.nativeProgress'))
    $tips.SetToolTip($nativeProgress, (Get-AIOString 'tips.edicion.nativeProgress'))
    $tips.SetToolTip($nativeFill, (Get-AIOString 'tips.edicion.nativeProgress'))
    $tips.SetToolTip($btnRun, (Get-AIOString 'tips.edicion.btnRun'))
    $tips.SetToolTip($btnCancel, (Get-AIOString 'tips.edicion.btnCancel'))
    $tips.SetToolTip($btnClose, (Get-AIOString 'tips.edicion.btnClose'))

    # --- Renderizadores de barras de progreso ---
    $renderProgress = {
        $width = $progress.ClientSize.Width
        if ($width -le 0) { return }
        $progressFill.Height = $progress.ClientSize.Height
        if ($state.ProgressBusy) {
            $progressFill.Width = [Math]::Min($width, [Math]::Max(30, [int]($width / 5)))
            $travel = [Math]::Max(1, $width - $progressFill.Width)
            $progressFill.Left = [int](($state.Animation * 15) % $travel)
        } else {
            $progressFill.Left = 0
            $progressFill.Width = [int]($width * [Math]::Min(100, [Math]::Max(0, $state.ProgressValue)) / 100)
        }
    }

    $renderNativeProgress = {
        $width = $nativeProgress.ClientSize.Width
        if ($width -le 0) { return }
        $nativeFill.Height = $nativeProgress.ClientSize.Height
        $value = [double]$state.Native.NativePercent
        if ($value -lt 0 -and $state.Native.NativeActive) {
            $nativeFill.Width = [Math]::Min($width, [Math]::Max(30, [int]($width / 5)))
            $travel = [Math]::Max(1, $width - $nativeFill.Width)
            $nativeFill.Left = [int](($state.Animation * 15) % $travel)
            $lblNativeStatus.Text = if ($state.Native.NativePhase) { $state.Native.NativePhase + '...' } else { Get-AIOString 'edition.gui_phase_working' }
        } elseif ($value -ge 0) {
            $nativeFill.Left = 0
            $maximum = if ($state.Native.NativeSucceeded) { 100.0 } else { 99.9 }
            $display = [Math]::Max(0, [Math]::Min($maximum, $value))
            $nativeFill.Width = [int][Math]::Floor($width * $display / 100)
            $phaseLabel = if ($state.Native.NativePhase) { $state.Native.NativePhase } else { Get-AIOString 'edition.gui_phase_working' }
            $lblNativeStatus.Text = '{0}: {1:0.0}%' -f $phaseLabel, $display
        } else {
            $nativeFill.Left = 0
            $nativeFill.Width = 0
            $lblNativeStatus.Text = Get-AIOString 'edition.gui_native_idle'
        }
    }

    $onProgressTick = {
        $state.Animation++
        & $renderProgress
        & $renderNativeProgress
    }

    $progress.Add_Resize({ & $renderProgress })
    $nativeProgress.Add_Resize({ & $renderNativeProgress })

    # --- Helpers de UI ---
    $setStatus = {
        param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Cyan)
        $lblStatus.ForeColor = $Color
        $lblStatus.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }

    $updateCustomCounter = {
        $checked = 0
        foreach ($row in $dgvCustom.Rows) {
            if ([bool]$row.Cells[0].Value) { $checked++ }
        }
        $lblCustomCount.Text = Get-AIOString 'edition.gui_selected_count' -FormatArgs @($checked, $dgvCustom.Rows.Count)
    }

    $syncSaveControls = {
        $allowSave = (-not $state.IsRunning) -and ($tabs.SelectedIndex -in @(1, 2))
        $rbNewWim.Enabled = $allowSave
        $rbAppend.Enabled = ($allowSave -and $canAppendMounted)
        $txtDestWim.ReadOnly = (-not ($allowSave -and $rbNewWim.Checked))
        $btnBrowse.Enabled = ($allowSave -and $rbNewWim.Checked)
        $chkIncludeBase.Enabled = ($allowSave -and $rbNewWim.Checked)
        $chkCommitBase.Enabled = ($allowSave -and $rbAppend.Checked -and $canAppendMounted)

        switch ($tabs.SelectedIndex) {
            0 { $btnRun.Text = Get-AIOString 'edition.gui_btn_run_single' }
            1 { $btnRun.Text = Get-AIOString 'edition.gui_btn_run_auto' }
            2 { $btnRun.Text = Get-AIOString 'edition.gui_btn_run_custom' }
        }
    }

    $populateLists = {
        $lblInfo.Text = Get-AIOString 'edition.gui_info_bar' -FormatArgs @($state.OsVersion, (& $getFriendly $state.CurrentEdition), $mountBadge, $Script:MOUNT_DIR)

        $dgvSingle.Rows.Clear()
        $singleTip = Get-AIOString 'tips.edicion.dgvSingle'
        foreach ($ed in $state.DirectTargets) {
            $desc = & $getDescription $ed
            $rIdx = $dgvSingle.Rows.Add((& $getFriendly $ed), $ed, $desc)
            $row = $dgvSingle.Rows[$rIdx]
            $row.Tag = $ed
            $cellTip = if ($desc) { $desc } else { $singleTip }
            foreach ($cell in $row.Cells) { $cell.ToolTipText = $cellTip }
        }
        if ($dgvSingle.Rows.Count -gt 0) { $dgvSingle.Rows[0].Selected = $true }

        $dgvCustom.Rows.Clear()
        $cands = Get-AIOKnownReachableEditions -CurrentEdition $state.CurrentEdition -DirectTargets $state.DirectTargets
        $lblDirect = Get-AIOString 'edition.gui_avail_direct'
        $lblVia = Get-AIOString 'edition.gui_avail_via'
        $customTip = Get-AIOString 'tips.edicion.dgvCustom'
        foreach ($c in $cands) {
            $desc = & $getDescription $c.EditionID
            $rIdx = $dgvCustom.Rows.Add($false, (& $getFriendly $c.EditionID), $c.EditionID, $(if ($c.IsDirect) { $lblDirect } else { $lblVia }), $desc)
            $row = $dgvCustom.Rows[$rIdx]
            $row.Tag = $c.EditionID
            $cellTip = if ($desc) { $desc } else { $customTip }
            foreach ($cell in $row.Cells) { $cell.ToolTipText = $cellTip }
            if (-not $c.IsDirect) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Silver
            }
        }
        & $updateCustomCounter
    }

    $setRunningUi = {
        param([bool]$Running)
        $state.IsRunning = $Running
        # Nunca deshabilitar TabControl ni DataGridView para evitar fondo blanco nativo; bloquear solo edicion/botones.
        $dgvCustom.ReadOnly = $Running
        $btnSelAll.Enabled = -not $Running
        $btnSelNone.Enabled = -not $Running
        $btnRun.Enabled = -not $Running
        $btnClose.Enabled = -not $Running
        $btnCancel.Enabled = $Running
        if (-not $Running) {
            $state.ProgressBusy = $false
            $state.Native.NativeActive = $false
            & $renderProgress
            & $renderNativeProgress
        }
        & $syncSaveControls
        [System.Windows.Forms.Application]::DoEvents()
    }

    # --- Eventos ---
    $tabs.Add_Selecting({
        param($sender, $e)
        if ($state.IsRunning) { $e.Cancel = $true }
    })
    $tabs.Add_SelectedIndexChanged({ & $syncSaveControls })
    $rbNewWim.Add_CheckedChanged({ & $syncSaveControls })
    $rbAppend.Add_CheckedChanged({ & $syncSaveControls })

    $dgvCustom.Add_CurrentCellDirtyStateChanged({
        if ($dgvCustom.IsCurrentCellDirty) {
            [void]$dgvCustom.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })
    $dgvCustom.Add_CellValueChanged({ & $updateCustomCounter })
    $dgvCustom.Add_CellClick({
        param($sender, $e)
        if (-not $state.IsRunning -and $e.RowIndex -ge 0 -and $e.ColumnIndex -gt 0) {
            $cur = [bool]$dgvCustom.Rows[$e.RowIndex].Cells[0].Value
            $dgvCustom.Rows[$e.RowIndex].Cells[0].Value = -not $cur
            & $updateCustomCounter
        }
    })

    $btnSelAll.Add_Click({
        if ($state.IsRunning) { return }
        foreach ($row in $dgvCustom.Rows) { $row.Cells[0].Value = $true }
        & $updateCustomCounter
    })
    $btnSelNone.Add_Click({
        if ($state.IsRunning) { return }
        foreach ($row in $dgvCustom.Rows) { $row.Cells[0].Value = $false }
        & $updateCustomCounter
    })

    $btnBrowse.Add_Click({
        $picked = Select-SavePathDialog -Title (Get-AIOString 'edition.escalate_dialog_title') -Filter (Get-AIOString 'save.wim_filter') -DefaultFileName $txtDestWim.Text
        if ($picked) { $txtDestWim.Text = $picked }
    })

    $btnCancel.Add_Click({
        $state.CancelPending = $true
        $btnCancel.Enabled = $false
        & $setStatus (Get-AIOString 'edition.gui_cancel_requested') ([System.Drawing.Color]::Gold)
    })

    $btnClose.Add_Click({ $form.Close() })
    $form.Add_FormClosing({
        param($sender, $e)
        if ($state.IsRunning) { $e.Cancel = $true }
    })

    # --- Accion principal ---
    $btnRun.Add_Click({
        if ($state.IsRunning) { return }
        $modeIdx = $tabs.SelectedIndex

        # ===== MODO 0: CAMBIO UNICO =====
        if ($modeIdx -eq 0) {
            if ($dgvSingle.SelectedRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    (Get-AIOString 'edition.gui_select_one_warn'),
                    (Get-AIOString 'edition.gui_warn_title'),
                    'OK', 'Warning'
                ) | Out-Null
                return
            }
            $targetEd = [string]$dgvSingle.SelectedRows[0].Tag
            $curFriendly = & $getFriendly $state.CurrentEdition
            $tgtFriendly = & $getFriendly $targetEd

            $ans = [System.Windows.Forms.MessageBox]::Show(
                (Get-AIOString 'edition.gui_confirm_single' -FormatArgs @($curFriendly, $tgtFriendly)),
                (Get-AIOString 'edition.gui_title'),
                'YesNo', 'Question'
            )
            if ($ans -ne 'Yes') { return }

            & $setRunningUi $true
            $state.ProgressBusy = $true
            $state.ProgressValue = 0
            & $setStatus (Get-AIOString 'edition.changing_to' $curFriendly $tgtFriendly) ([System.Drawing.Color]::Cyan)
            Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): Cambiando edicion de '$curFriendly' a '$targetEd'."

            $res = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @("/Image:$Script:MOUNT_DIR", "/Set-Edition:$targetEd") `
                -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')

            $state.ProgressBusy = $false
            if ($res.ExitCode -in @(0, 3010)) {
                $state.ProgressValue = 100
                $Script:ForceMenuRefresh = $true
                $state.CurrentEdition = $targetEd
                $state.DirectTargets = Get-AIOTargetEditionsFromMount
                & $populateLists
                & $setStatus (Get-AIOString 'edition.done_ok') ([System.Drawing.Color]::LightGreen)
                & $setRunningUi $false
                [System.Windows.Forms.MessageBox]::Show(
                    (Get-AIOString 'edition.done_ok'),
                    (Get-AIOString 'edition.gui_title'),
                    'OK', 'Information'
                ) | Out-Null
            } else {
                $state.ProgressValue = 0
                $errMsg = Get-AIOString 'edition.failed' $res.ExitCode
                & $setStatus $errMsg ([System.Drawing.Color]::Salmon)
                Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo cambio edicion. Codigo: $($res.ExitCode)"
                & $setRunningUi $false
                [System.Windows.Forms.MessageBox]::Show(
                    $errMsg,
                    (Get-AIOString 'common.error_title'),
                    'OK', 'Error'
                ) | Out-Null
            }
            return
        }

        # ===== MODOS 1 y 2: ESCALADO AUTOMATICO / SELECTIVO =====
        $escMode = if ($modeIdx -eq 1) { 'Auto' } else { 'Custom' }
        $selectedSkus = @()
        if ($escMode -eq 'Custom') {
            foreach ($row in $dgvCustom.Rows) {
                if ([bool]$row.Cells[0].Value) { $selectedSkus += [string]$row.Tag }
            }
            if ($selectedSkus.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    (Get-AIOString 'edition.gui_select_multi_warn'),
                    (Get-AIOString 'edition.gui_warn_title'),
                    'OK', 'Warning'
                ) | Out-Null
                return
            }
        }

        $saveMode = if ($rbAppend.Checked -and $canAppendMounted) { 'AppendMounted' } else { 'NewWim' }
        $destWimPath = $txtDestWim.Text.Trim()
        $destParent = $null
        $parentIdentity = $null
        $previousSnapshot = $null
        $bootableFirst = $false
        $includeBase = [bool]$chkIncludeBase.Checked
        $commitBaseFirst = [bool]($chkCommitBase.Checked -and $saveMode -eq 'AppendMounted')

        if ($saveMode -eq 'NewWim') {
            if ([string]::IsNullOrWhiteSpace($destWimPath)) {
                [System.Windows.Forms.MessageBox]::Show(
                    (Get-AIOString 'edition.gui_dest_required'),
                    (Get-AIOString 'edition.gui_warn_title'),
                    'OK', 'Warning'
                ) | Out-Null
                return
            }
            try {
                $destParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($destWimPath))
                if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
                    throw (Get-AIOString 'errors.e014')
                }
                $parentIdentity = Get-AIOFileIdentity $destParent
                $mountIdentity = Get-AIOFileIdentity $Script:MOUNT_DIR
                $previousSnapshot = Get-AIOOutputSnapshot $destWimPath
                $sameAsSource = $false
                if ($Script:IMAGE_MOUNTED -eq 1 -and $Script:WIM_FILE_PATH -and $previousSnapshot) {
                    $sourceIdentity = Get-AIOFileIdentity $Script:WIM_FILE_PATH
                    $sameAsSource = ($previousSnapshot.Id -eq $sourceIdentity.Id)
                }
                if ((Test-AIOPathWithin $parentIdentity.Path $mountIdentity.Path) -or $sameAsSource) {
                    throw (Get-AIOString 'errors.e316')
                }
                if ($Script:IMAGE_MOUNTED -eq 1 -and $Script:WIM_FILE_PATH -and (Get-Command Get-AIOWimContainerInfo -ErrorAction SilentlyContinue)) {
                    $srcInfo = Get-AIOWimContainerInfo -Path $Script:WIM_FILE_PATH
                    $bootableFirst = ($null -ne $srcInfo -and $srcInfo.BootIndex -gt 0 -and $srcInfo.BootIndex -eq $Script:MOUNTED_INDEX)
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    $_.Exception.Message,
                    (Get-AIOString 'common.error_title'),
                    'OK', 'Error'
                ) | Out-Null
                return
            }
        }

        $destLabel = if ($saveMode -eq 'NewWim') { $destWimPath } else { $Script:WIM_FILE_PATH }
        $confirmMsg = if ($escMode -eq 'Auto') {
            Get-AIOString 'edition.gui_confirm_auto' -FormatArgs @((& $getFriendly $state.CurrentEdition), $destLabel)
        } else {
            $selNames = (($selectedSkus | Sort-Object -Property @{ Expression = { Get-AIOEditionTierRank $_ } }, @{ Expression = { $_ } }) | ForEach-Object { & $getFriendly $_ }) -join ' -> '
            Get-AIOString 'edition.gui_confirm_custom' -FormatArgs @($selectedSkus.Count, $selNames, $destLabel)
        }
        $ans = [System.Windows.Forms.MessageBox]::Show($confirmMsg, (Get-AIOString 'edition.gui_title'), 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }

        $state.CancelPending = $false
        & $setRunningUi $true

        $startEdition = $state.CurrentEdition
        $activeEdition = $startEdition
        $savedEditions = New-Object System.Collections.ArrayList
        $appendedMetaList = New-Object System.Collections.ArrayList
        $bridgeEditions = New-Object System.Collections.ArrayList
        $skippedEditions = New-Object System.Collections.ArrayList
        $initialMountedWimCount = 0
        if ($saveMode -eq 'AppendMounted' -and $Script:WIM_FILE_PATH) {
            $initialMountedWimCount = Get-AIOEditionWimIndexCount -WimlibExe $wimlibExe -WimPath $Script:WIM_FILE_PATH
            if ($initialMountedWimCount -le 0) {
                try { $initialMountedWimCount = @(Get-WindowsImage -ImagePath $Script:WIM_FILE_PATH -ErrorAction Stop).Count } catch { $initialMountedWimCount = 1 }
            }
        }
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        [void]$visited.Add($startEdition)

        $hadFatalError = $false
        $stepNum = 0
        $maxSteps = 25
        $pendingWim = if ($saveMode -eq 'NewWim') { Join-Path $destParent ('.escalado-' + [Guid]::NewGuid().ToString('N') + '.wim') } else { $null }
        $sourceWinMeta = if ($saveMode -eq 'NewWim') { Get-AIOEditionSourceWindowsMeta -WimlibExe $wimlibExe } else { $null }

        $saveGuiStep = {
            param([string]$EditionId, [string]$ImgName, [string]$ImgDesc, [bool]$IsFirst)
            Unmount-Hives
            if ($saveMode -eq 'AppendMounted') {
                Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): DISM /Commit-Image /Append para '$ImgName'."
                $r = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @('/Commit-Image', "/MountDir:$Script:MOUNT_DIR", '/Append') `
                    -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')
                if ($r.ExitCode -eq 0) {
                    $newIdx = $initialMountedWimCount + $appendedMetaList.Count + 1
                    [void]$appendedMetaList.Add([PSCustomObject]@{
                        Index       = $newIdx
                        EditionID   = $EditionId
                        Name        = $ImgName
                        Description = $ImgDesc
                    })
                }
                return [int]$r.ExitCode
            }
            if ($IsFirst -or -not (Test-Path -LiteralPath $pendingWim -PathType Leaf)) {
                Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): wimlib capture hacia '$pendingWim' ($ImgName)."
                $wArgs = @('capture', $Script:MOUNT_DIR, $pendingWim, $ImgName, $ImgDesc, '--compress=LZX', '--check')
                if ($bootableFirst -and $IsFirst) { $wArgs += '--boot' }
                $r = Invoke-AIOEditionNativeProcess -Executable $wimlibExe -Arguments $wArgs `
                    -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_archive')
                if ($r.ExitCode -eq 0) {
                    $newIdx = Get-AIOEditionWimIndexCount -WimlibExe $wimlibExe -WimPath $pendingWim
                    if ($newIdx -gt 0) {
                        [void](Set-AIOEditionWimIndexMetadata -WimlibExe $wimlibExe -WimPath $pendingWim -Index $newIdx `
                            -EditionID $EditionId -ImageName $ImgName -ImageDesc $ImgDesc -SourceWindowsMeta $sourceWinMeta)
                    }
                }
                return [int]$r.ExitCode
            } else {
                Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): wimlib append hacia '$pendingWim' ($ImgName)."
                $wArgs = @('append', $Script:MOUNT_DIR, $pendingWim, $ImgName, $ImgDesc, '--check')
                $r = Invoke-AIOEditionNativeProcess -Executable $wimlibExe -Arguments $wArgs `
                    -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_archive')
                if ($r.ExitCode -eq 0) {
                    $newIdx = Get-AIOEditionWimIndexCount -WimlibExe $wimlibExe -WimPath $pendingWim
                    if ($newIdx -gt 0) {
                        [void](Set-AIOEditionWimIndexMetadata -WimlibExe $wimlibExe -WimPath $pendingWim -Index $newIdx `
                            -EditionID $EditionId -ImageName $ImgName -ImageDesc $ImgDesc -SourceWindowsMeta $sourceWinMeta)
                    }
                }
                return [int]$r.ExitCode
            }
        }

        Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): Iniciando escalado ($escMode). Edicion inicial: '$startEdition'. Guardado: $saveMode (motor WIM: wimlib)."

        try {
            if ($escMode -eq 'Auto') {
                $state.ProgressBusy = $true
            } else {
                $state.ProgressBusy = $false
                $state.ProgressValue = 2
                & $renderProgress
            }

            if ($saveMode -eq 'AppendMounted' -and $commitBaseFirst) {
                & $setStatus (Get-AIOString 'edition.step_committing_base' -FormatArgs @($Script:MOUNTED_INDEX, (& $getFriendly $activeEdition))) ([System.Drawing.Color]::Cyan)
                Unmount-Hives
                $cRes = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @('/Commit-Image', "/MountDir:$Script:MOUNT_DIR") `
                    -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')
                if ($cRes.ExitCode -ne 0) {
                    & $setStatus (Get-AIOString 'edition.step_commit_failed' -FormatArgs @($Script:MOUNTED_INDEX, $cRes.ExitCode)) ([System.Drawing.Color]::Salmon)
                    Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo Commit previo. Codigo: $($cRes.ExitCode)"
                    $hadFatalError = $true
                }
            }

            if (-not $hadFatalError -and $saveMode -eq 'NewWim' -and $includeBase) {
                $baseMeta = Get-AIOEditionCaptureMetadata -EditionID $activeEdition -OsVersionPrefix $state.OsVersion
                & $setStatus (Get-AIOString 'edition.step_saving_base' -FormatArgs @((& $getFriendly $activeEdition))) ([System.Drawing.Color]::Cyan)
                $sc = & $saveGuiStep $activeEdition $baseMeta.Name $baseMeta.Description $true
                if ($sc -ne 0) {
                    & $setStatus (Get-AIOString 'edition.step_save_failed' -FormatArgs @((& $getFriendly $activeEdition), $sc)) ([System.Drawing.Color]::Salmon)
                    Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo al guardar base '$activeEdition'. Codigo: $sc"
                    $hadFatalError = $true
                } else {
                    [void]$savedEditions.Add((& $getFriendly $activeEdition))
                }
            }

            if (-not $hadFatalError -and $escMode -eq 'Auto') {
                while ($stepNum -lt $maxSteps) {
                    if ($state.CancelPending) { break }
                    $liveTargets = Get-AIOTargetEditionsFromMount
                    $nextCands = @($liveTargets | Where-Object { -not $visited.Contains($_) } |
                        Sort-Object -Property @{ Expression = { Get-AIOEditionTierRank $_ } }, @{ Expression = { $_ } })
                    if ($nextCands.Count -eq 0) { break }

                    $nextSku = [string]$nextCands[0]
                    $stepNum++
                    & $setStatus (Get-AIOString 'edition.step_escalating' -FormatArgs @($stepNum, (& $getFriendly $activeEdition), (& $getFriendly $nextSku))) ([System.Drawing.Color]::Cyan)
                    Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): Paso $stepNum - Escalando '$activeEdition' -> '$nextSku'."

                    $setRes = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @("/Image:$Script:MOUNT_DIR", "/Set-Edition:$nextSku") `
                        -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')
                    if ($setRes.ExitCode -notin @(0, 3010)) {
                        & $setStatus (Get-AIOString 'edition.step_set_failed' -FormatArgs @((& $getFriendly $nextSku), $setRes.ExitCode)) ([System.Drawing.Color]::Salmon)
                        Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo /Set-Edition:$nextSku. Codigo: $($setRes.ExitCode)"
                        $hadFatalError = $true
                        break
                    }

                    $Script:ForceMenuRefresh = $true
                    [void]$visited.Add($nextSku)
                    $activeEdition = $nextSku

                    $capMeta = Get-AIOEditionCaptureMetadata -EditionID $activeEdition -OsVersionPrefix $state.OsVersion
                    & $setStatus (Get-AIOString 'edition.step_saving' -FormatArgs @((& $getFriendly $activeEdition), $capMeta.Name)) ([System.Drawing.Color]::Cyan)

                    $sc = & $saveGuiStep $activeEdition $capMeta.Name $capMeta.Description ($savedEditions.Count -eq 0)
                    if ($sc -ne 0) {
                        & $setStatus (Get-AIOString 'edition.step_save_failed' -FormatArgs @((& $getFriendly $activeEdition), $sc)) ([System.Drawing.Color]::Salmon)
                        Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo al guardar '$activeEdition'. Codigo: $sc"
                        $hadFatalError = $true
                        break
                    }
                    [void]$savedEditions.Add((& $getFriendly $activeEdition))
                }
            }
            elseif (-not $hadFatalError -and $escMode -eq 'Custom') {
                $orderedQueue = @($selectedSkus | Sort-Object -Property @{ Expression = { Get-AIOEditionTierRank $_ } }, @{ Expression = { $_ } })
                $queuePos = 0
                foreach ($desiredSku in $orderedQueue) {
                    $queuePos++
                    $state.ProgressValue = [int](85 * ($queuePos - 1) / [Math]::Max(1, $orderedQueue.Count))
                    & $renderProgress

                    if ($hadFatalError -or $state.CancelPending) { break }
                    if ([string]::Equals($desiredSku, $activeEdition, [StringComparison]::OrdinalIgnoreCase)) { continue }

                    $desiredRank = Get-AIOEditionTierRank $desiredSku
                    $liveTargets = Get-AIOTargetEditionsFromMount

                    $bridgeGuard = 0
                    while (($liveTargets -inotcontains $desiredSku) -and $bridgeGuard -lt 10) {
                        $bridgeGuard++
                        $bridgeCands = @($liveTargets | Where-Object {
                            (-not $visited.Contains($_)) -and ((Get-AIOEditionTierRank $_) -lt $desiredRank)
                        } | Sort-Object -Property @{ Expression = { Get-AIOEditionTierRank $_ } }, @{ Expression = { $_ } })
                        if ($bridgeCands.Count -eq 0) { break }
                        $bridgeSku = [string]$bridgeCands[0]

                        & $setStatus (Get-AIOString 'edition.step_bridge' -FormatArgs @((& $getFriendly $desiredSku), (& $getFriendly $bridgeSku))) ([System.Drawing.Color]::Gold)
                        Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): Paso puente '$activeEdition' -> '$bridgeSku'."

                        $bRes = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @("/Image:$Script:MOUNT_DIR", "/Set-Edition:$bridgeSku") `
                            -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')
                        if ($bRes.ExitCode -notin @(0, 3010)) {
                            & $setStatus (Get-AIOString 'edition.step_set_failed' -FormatArgs @((& $getFriendly $bridgeSku), $bRes.ExitCode)) ([System.Drawing.Color]::Salmon)
                            $hadFatalError = $true
                            break
                        }
                        $Script:ForceMenuRefresh = $true
                        [void]$visited.Add($bridgeSku)
                        $activeEdition = $bridgeSku
                        [void]$bridgeEditions.Add((& $getFriendly $bridgeSku))
                        $liveTargets = Get-AIOTargetEditionsFromMount
                    }

                    if ($hadFatalError) { break }
                    if ($liveTargets -inotcontains $desiredSku) {
                        Write-Log -LogLevel WARN -Message "CAMBIO_EDICION (GUI): SKU '$desiredSku' omitida; no alcanzable desde '$activeEdition'."
                        [void]$skippedEditions.Add((& $getFriendly $desiredSku))
                        continue
                    }

                    $stepNum++
                    & $setStatus (Get-AIOString 'edition.step_escalating' -FormatArgs @($stepNum, (& $getFriendly $activeEdition), (& $getFriendly $desiredSku))) ([System.Drawing.Color]::Cyan)
                    Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION (GUI): Paso $stepNum (Custom) - Escalando '$activeEdition' -> '$desiredSku'."

                    $setRes = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @("/Image:$Script:MOUNT_DIR", "/Set-Edition:$desiredSku") `
                        -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')
                    if ($setRes.ExitCode -notin @(0, 3010)) {
                        & $setStatus (Get-AIOString 'edition.step_set_failed' -FormatArgs @((& $getFriendly $desiredSku), $setRes.ExitCode)) ([System.Drawing.Color]::Salmon)
                        Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo /Set-Edition:$desiredSku. Codigo: $($setRes.ExitCode)"
                        $hadFatalError = $true
                        break
                    }
                    $Script:ForceMenuRefresh = $true
                    [void]$visited.Add($desiredSku)
                    $activeEdition = $desiredSku

                    $capMeta = Get-AIOEditionCaptureMetadata -EditionID $activeEdition -OsVersionPrefix $state.OsVersion
                    & $setStatus (Get-AIOString 'edition.step_saving' -FormatArgs @((& $getFriendly $activeEdition), $capMeta.Name)) ([System.Drawing.Color]::Cyan)

                    $sc = & $saveGuiStep $activeEdition $capMeta.Name $capMeta.Description ($savedEditions.Count -eq 0)
                    if ($sc -ne 0) {
                        & $setStatus (Get-AIOString 'edition.step_save_failed' -FormatArgs @((& $getFriendly $activeEdition), $sc)) ([System.Drawing.Color]::Salmon)
                        Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo al guardar '$activeEdition'. Codigo: $sc"
                        $hadFatalError = $true
                        break
                    }
                    [void]$savedEditions.Add((& $getFriendly $activeEdition))
                }
            }

            $publishedSummaryLine = $null
            if ($saveMode -eq 'NewWim' -and $savedEditions.Count -gt 0 -and (Test-Path -LiteralPath $pendingWim -PathType Leaf)) {
                $state.ProgressBusy = $false
                $state.ProgressValue = 92
                & $renderProgress
                & $setStatus (Get-AIOString 'edition.publishing_wim') ([System.Drawing.Color]::Cyan)

                $idxCount = Get-AIOEditionWimIndexCount -WimlibExe $wimlibExe -WimPath $pendingWim
                if ($idxCount -ne $savedEditions.Count) { throw (Get-AIOString 'errors.e513') }
                if ((Get-AIOFileIdentity $destParent).Id -ne $parentIdentity.Id) { throw (Get-AIOString 'errors.e014') }
                Publish-AIOVerifiedFile $pendingWim $destWimPath $previousSnapshot
                if ($hadFatalError -or $state.CancelPending) {
                    $publishedSummaryLine = Get-AIOString 'edition.publish_partial' -FormatArgs @($savedEditions.Count, $destWimPath)
                    Write-Log -LogLevel WARN -Message "CAMBIO_EDICION (GUI): Publicado WIM parcial en '$destWimPath' ($($savedEditions.Count) indices)."
                } else {
                    $publishedSummaryLine = Get-AIOString 'edition.publish_ok' -FormatArgs @($destWimPath)
                    Write-Log -LogLevel INFO -Message "CAMBIO_EDICION (GUI): Publicado WIM en '$destWimPath' ($($savedEditions.Count) indices)."
                }
            }

            $state.ProgressBusy = $false
            $state.ProgressValue = if ($hadFatalError) { $state.ProgressValue } else { 100 }
        } catch {
            $state.ProgressBusy = $false
            & $setStatus $_.Exception.Message ([System.Drawing.Color]::Salmon)
            Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): $($_.Exception.Message)"
        } finally {
            if ($pendingWim -and [IO.File]::Exists($pendingWim)) {
                Remove-Item -LiteralPath $pendingWim -Force -ErrorAction Continue
            }
        }

        $unmountedAndPatched = $false
        if ($saveMode -eq 'AppendMounted' -and $appendedMetaList.Count -gt 0 -and $Script:IMAGE_MOUNTED -eq 1 -and $Script:WIM_FILE_PATH) {
            $askMeta = [System.Windows.Forms.MessageBox]::Show(
                (Get-AIOString 'edition.gui_append_fix_meta_prompt' -FormatArgs @($appendedMetaList.Count, $Script:WIM_FILE_PATH)),
                (Get-AIOString 'edition.gui_title'),
                'YesNo', 'Question'
            )
            if ($askMeta -eq 'Yes') {
                $targetWimForMeta = $Script:WIM_FILE_PATH
                & $setStatus (Get-AIOString 'edition.gui_unmounting_for_meta') ([System.Drawing.Color]::Cyan)
                Unmount-Hives
                $uRes = Invoke-AIOEditionNativeProcess -Executable $dismExe -Arguments @('/Unmount-Image', "/MountDir:$Script:MOUNT_DIR", '/Discard') `
                    -ProgressState $state.Native -OnTick $onProgressTick -InitialPhase (Get-AIOString 'edition.gui_phase_dism')
                if ($uRes.ExitCode -eq 0) {
                    $Script:IMAGE_MOUNTED = 0
                    $Script:MOUNTED_INDEX = $null
                    $Script:ForceMenuRefresh = $true
                    $patchedOk = 0
                    foreach ($am in $appendedMetaList) {
                        & $setStatus (Get-AIOString 'edition.gui_applying_meta' -FormatArgs @($am.Index, $am.Name)) ([System.Drawing.Color]::Cyan)
                        $ok = Set-AIOEditionWimIndexMetadata -WimlibExe $wimlibExe -WimPath $targetWimForMeta -Index $am.Index `
                            -EditionID $am.EditionID -ImageName $am.Name -ImageDesc $am.Description -SourceWindowsMeta $null
                        if ($ok) { $patchedOk++ }
                    }
                    $unmountedAndPatched = $true
                    Write-Log -LogLevel INFO -Message "CAMBIO_EDICION (GUI): Imagen desmontada (/Discard) y metadatos aplicados con wimlib a $patchedOk/$($appendedMetaList.Count) indices en '$targetWimForMeta'."
                } else {
                    Write-Log -LogLevel ERROR -Message "CAMBIO_EDICION (GUI): Fallo al desmontar imagen para aplicar metadatos. Codigo: $($uRes.ExitCode)"
                }
            }
        }

        if (-not $unmountedAndPatched) {
            $state.CurrentEdition = $activeEdition
            $state.DirectTargets = Get-AIOTargetEditionsFromMount
            & $populateLists
        }

        $finalFriendly = & $getFriendly $activeEdition
        $summaryLines = @(
            (Get-AIOString 'edition.summary_final_edition' -FormatArgs @($finalFriendly)),
            (Get-AIOString 'edition.summary_saved_count' -FormatArgs @($savedEditions.Count))
        )
        if ($savedEditions.Count -gt 0) {
            $summaryLines += (Get-AIOString 'edition.summary_saved_list' -FormatArgs @(($savedEditions -join ' -> ')))
        }
        if ($bridgeEditions.Count -gt 0) {
            $summaryLines += (Get-AIOString 'edition.summary_bridges_list' -FormatArgs @(($bridgeEditions -join ', ')))
        }
        if ($skippedEditions.Count -gt 0) {
            $summaryLines += (Get-AIOString 'edition.summary_skipped_list' -FormatArgs @(($skippedEditions -join ', ')))
        }
        if ($state.CancelPending) {
            $summaryLines += ''
            $summaryLines += (Get-AIOString 'edition.escalate_cancelled')
        }
        if ($publishedSummaryLine) {
            $summaryLines += ''
            $summaryLines += $publishedSummaryLine
        }
        if ($Script:IMAGE_MOUNTED -eq 1 -and (-not [string]::Equals($activeEdition, $startEdition, [StringComparison]::OrdinalIgnoreCase))) {
            $hint = if ($saveMode -eq 'NewWim') {
                Get-AIOString 'edition.summary_discard_hint_newwim' -FormatArgs @($finalFriendly)
            } else {
                Get-AIOString 'edition.summary_discard_hint_append' -FormatArgs @($finalFriendly, $Script:MOUNTED_INDEX)
            }
            $summaryLines += ''
            $summaryLines += $hint
        }

        & $setStatus (Get-AIOString 'edition.gui_status_done' -FormatArgs @($savedEditions.Count)) $(if ($hadFatalError) { [System.Drawing.Color]::Gold } else { [System.Drawing.Color]::LightGreen })
        & $setRunningUi $false

        if ($unmountedAndPatched) {
            $summaryLines += ''
            $summaryLines += (Get-AIOString 'edition.gui_append_meta_done')
        }

        [System.Windows.Forms.MessageBox]::Show(
            ($summaryLines -join [Environment]::NewLine),
            (Get-AIOString 'edition.gui_title'),
            'OK', $(if ($hadFatalError) { 'Warning' } else { 'Information' })
        ) | Out-Null
        if ($unmountedAndPatched) { $form.Close() }
    })

    $form.Add_Shown({ $form.Activate() })

    try {
        & $populateLists
        & $syncSaveControls
        [void]$form.ShowDialog()
    } finally {
        $tips.Dispose()
        $form.Dispose()
    }
}
