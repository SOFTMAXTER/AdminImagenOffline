<#
.SYNOPSIS
    Integra actualizaciones offline en medios de Windows 10/11.
.DESCRIPTION
    Modulo complementario para AdminImagenOffline. Implementa en PowerShell
    un flujo de mantenimiento:

      - Detecta medios extraidos con install.wim y boot.wim.
      - Acepta un repositorio plano o subcarpetas por categoria.
      - Clasifica CAB/MSU por identidades y contenido interno, sin listas KB.
      - Extrae el SSU integrado en la LCU y lo reutiliza en WinRE/WinPE.
      - Procesa SSU, Enablement y ESU antes de la LCU final.
      - Actualiza winre.wim por separado y lo reinyecta en install.wim.
      - Puede actualizar opcionalmente todos los indices de boot.wim.
      - Puede aplicar opcionalmente Setup Dynamic Update al directorio sources.
      - Si se selecciona un solo indice, exporta install.wim con esa unica edicion.
      - Aplica SetupDU antes de sincronizar Setup y archivos de arranque.
      - Sincroniza archivos de arranque sin degradar versiones existentes.
      - Verifica operaciones, identidades esperadas, version de servicio y estructura final de los WIM.
      - Conserva la salida nativa de DISM y su barra de progreso en una sola linea.
      - Tolera la consolidacion normal de paquetes superseded durante una LCU.
      - Filtra arquitectura y familia de Windows; aprende relaciones de build desde Enablement y deja la aplicabilidad general a CBS.
      - Detecta paquetes ya presentes antes de invocar DISM.
      - Reaplica automaticamente los paquetes CBS ya presentes sin desinstalarlos.
      - Integra SetupDU dentro del indice Setup de boot.wim y sincroniza sources.
      - Actualiza Defender mediante plataforma/firmas, no como paquete CBS generico.
      - Maneja WinPE-Rejuv en builds modernas y archivos UEFI CA 2023.
      - Verifica la retirada de WinPE-Rejuv por identidad exacta y consolida sus avisos.
      - Distingue claramente la familia CBS observada de la version final de la imagen.
      - Evita duplicar la arquitectura cuando el nombre WIM ya la incluye.
      - Restaura automaticamente un medio desde un respaldo Preflight validado.
      - Ordena paquetes por identidades CBS propias; ignora prerrequisitos externos compartidos.
      - Registra por separado el orden planeado y el orden realmente ejecutado.
      - Genera un paquete ZIP de diagnostico ante errores antes de limpiar la sesion.
      - Exporta reportes estructurados JSON y HTML al completar o fallar.
      - Crea y verifica un respaldo previo antes del primer montaje o modificacion.
      - Reutiliza Preflight como respaldo maestro y evita duplicar WIM/Setup durante la misma sesion.
      - Puede reconstruir todos los WIM y ajustar su fecha interna de creacion.
      - Busca herramientas compartidas en AdminImagenOffline\Tools y, como respaldo, en el PATH del sistema.
      - La politica LCU de WinRE es automatica y no requiere seleccion manual.
      - Optimiza enumeracion, hashes, metadatos CBS, escritura atomica y deduplicacion sin paralelizar WIM.
      - Detecta automaticamente AdminImagenOffline\Actualizaciones como repositorio predeterminado.
      - Detecta automaticamente Windows ADK y el complemento WinPE; utiliza el DISM mas reciente disponible.
      - Verifica despues de SetupDU que boot.wim conserve lang.ini y los recursos MUI de todos los TrustedLocales.

    Estructura opcional recomendada:

        Actualizaciones\
        |-- SSU\
        |-- LCU\
        |-- SafeOS\
        |-- SecureBoot\
        |-- SetupDU\
        |-- ESU\
        |-- Enablement\
        |-- OS\
        |-- DotNet\
        |-- WinPE\
        `-- Defender\

    Tambien puede seleccionarse una carpeta plana. El modulo intentara
    clasificar cada CAB/MSU por nombre y metadatos internos.
.NOTES
    Implementacion original para AdminImagenOffline.
	No modifica ni omite comprobaciones de licencia ESU.
.AUTHOR
    SOFTMAXTER

# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
#
# DUAL LICENSING NOTICE:
# This software is dual-licensed. By default, AdminImagenOffline is 
# distributed under the GNU General Public License v3.0 (GPLv3).
# 
# 1. OPEN SOURCE (GPLv3):
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details: <https://www.gnu.org/licenses/>.
#
# 2. COMMERCIAL LICENSE:
# If you wish to integrate this software into a proprietary/commercial product, 
# distribute it without revealing your source code, or require commercial 
# support, you must obtain a commercial license from the original author.
#
# Please contact softmaxter@hotmail.com for commercial licensing inquiries.
# ==============================================================================
#>

$script:AIOUpdateNativeSystemDirectory = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
$script:AIOUpdateSystemDismPath = Join-Path $script:AIOUpdateNativeSystemDirectory 'dism.exe'
$script:AIOUpdateDismPath = $script:AIOUpdateSystemDismPath
$script:AIOUpdateDismSource = 'Sistema'
$script:AIOUpdateAdkInfo = $null
$script:AIOUpdateExpandPath = Join-Path $script:AIOUpdateNativeSystemDirectory 'expand.exe'
$script:AIOUpdateSessionRoot = $null
$script:AIOUpdateDismTranscript = $null
$script:AIOUpdatePackagePathMap = @{}
$script:AIOUpdateLcuStageRoot = $null
$script:AIOUpdateEmbeddedSsuPackages = @()
$script:AIOUpdateWimlibPath = $null
$script:AIOUpdateServicingBuildRelations = @{}
$script:AIOUpdatePreflightContext = $null
$script:AIOUpdateDependencyPlans = New-Object System.Collections.ArrayList
$script:AIOUpdateExecutionPositionByContext = @{}
$script:AIOUpdateLastDiagnosticPath = $null
$script:AIOUpdateLastPersistentLogPath = $null
$script:AIOUpdateLastTerminalState = $null
$script:AIOUpdateCurrentPhase = 'Inicializacion'
$script:AIOUpdateStructuredReport = $null
$script:AIOUpdatePreflightPathIndex = @{}
$script:AIOUpdatePreflightLocalesBySurface = @{}
$script:AIOUpdateSessionCreatedPathIndex = @{}
$script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
$script:AIOUpdateTrustedLocales = @{}
$script:AIOUpdateApplicationRoot = Split-Path -Parent $PSScriptRoot
$script:AIOUpdateReportsRoot = Join-Path $script:AIOUpdateApplicationRoot 'Reportes\Actualizaciones'
$script:AIOUpdateDiagnosticsRoot = Join-Path $script:AIOUpdateApplicationRoot 'Reportes\Diagnosticos\Actualizaciones'
$script:AIOUpdateFileHashCache = @{}
$script:AIOUpdateCbsFactsCache = @{}
$script:AIOUpdateRepositoryInventoryCache = @{}
$script:AIOUpdateInstalledNameCache = @{}
$script:AIOUpdateOptimizationStats = [ordered]@{
    HashCacheHits = 0
    HashCacheMisses = 0
    CbsCacheHits = 0
    RepositoryCacheHits = 0
    DuplicatePackagesSkipped = 0
}


function Get-AIOUpdateExecutableVersion {
    [CmdletBinding()]
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $versionInfo = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
        foreach ($candidate in @($versionInfo.FileVersion, $versionInfo.ProductVersion)) {
            if ([string]$candidate -match '(\d+\.\d+\.\d+\.\d+)') {
                try { return [version]$matches[1] } catch {}
            }
        }
    }
    catch {}
    return $null
}

function Get-AIOUpdateRegistryKitsRoots {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $subKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $subKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
            if ($subKey) {
                $root = [string]$subKey.GetValue('KitsRoot10')
                if (-not [string]::IsNullOrWhiteSpace($root)) {
                    [void]$results.Add([pscustomobject]@{
                        Path   = [Environment]::ExpandEnvironmentVariables($root.Trim().Trim('"'))
                        Source = "Registro $view"
                    })
                }
            }
        }
        catch {}
        finally {
            if ($subKey) { $subKey.Dispose() }
            if ($baseKey) { $baseKey.Dispose() }
        }
    }

    return [object[]]($results.ToArray() | Group-Object Path | ForEach-Object { $_.Group[0] })
}

function Get-AIOUpdateAdkUninstallLocations {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $uninstallKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $uninstallKey) { continue }

            foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                $itemKey = $null
                try {
                    $itemKey = $uninstallKey.OpenSubKey($subKeyName)
                    if (-not $itemKey) { continue }
                    $displayName = [string]$itemKey.GetValue('DisplayName')
                    if ($displayName -notmatch '(?i)Assessment and Deployment Kit|Windows Preinstallation Environment.*Add-ons?|Windows PE.*Add-on') { continue }
                    $installLocation = [string]$itemKey.GetValue('InstallLocation')
                    if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                        [void]$results.Add([pscustomobject]@{
                            Path        = [Environment]::ExpandEnvironmentVariables($installLocation.Trim().Trim('"'))
                            Source      = "Programas instalados $view"
                            DisplayName = $displayName
                        })
                    }
                }
                catch {}
                finally { if ($itemKey) { $itemKey.Dispose() } }
            }
        }
        catch {}
        finally {
            if ($uninstallKey) { $uninstallKey.Dispose() }
            if ($baseKey) { $baseKey.Dispose() }
        }
    }

    return [object[]]($results.ToArray() | Group-Object Path | ForEach-Object { $_.Group[0] })
}

function Find-AIOUpdateAdkDismPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$DeploymentToolsRoot)

    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { [string]$env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE }
    $folders = switch -Regex ($nativeArchitecture) {
        'ARM64' { @('arm64', 'x86'); break }
        'AMD64' { @('amd64', 'x86'); break }
        default { @('x86') }
    }
    foreach ($folder in $folders) {
        $candidate = Join-Path $DeploymentToolsRoot "$folder\DISM\dism.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function Get-AIOUpdateAdkInfo {
    [CmdletBinding()]
    param()

    $candidateMap = @{}
    $addCandidate = {
        param([AllowNull()] [string]$CandidatePath, [string]$Source)
        if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return }
        $expanded = [Environment]::ExpandEnvironmentVariables($CandidatePath.Trim().Trim('"')).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($expanded)) { return }

        $possibleRoots = New-Object System.Collections.Generic.List[string]
        $leaf = Split-Path -Leaf $expanded
        if ($leaf -in @('Deployment Tools', 'Windows Preinstallation Environment')) {
            [void]$possibleRoots.Add((Split-Path -Parent $expanded))
        }
        elseif ($leaf -eq 'Assessment and Deployment Kit') {
            [void]$possibleRoots.Add($expanded)
        }
        else {
            [void]$possibleRoots.Add((Join-Path $expanded 'Assessment and Deployment Kit'))
            [void]$possibleRoots.Add($expanded)
        }

        foreach ($possibleRoot in $possibleRoots) {
            if (-not (Test-Path -LiteralPath $possibleRoot -PathType Container)) { continue }
            try { $resolved = (Resolve-Path -LiteralPath $possibleRoot -ErrorAction Stop).Path.TrimEnd('\') }
            catch { continue }
            if (-not $candidateMap.ContainsKey($resolved)) { $candidateMap[$resolved] = $Source }
        }
    }

    foreach ($entry in Get-AIOUpdateRegistryKitsRoots) { & $addCandidate $entry.Path $entry.Source }
    foreach ($entry in Get-AIOUpdateAdkUninstallLocations) { & $addCandidate $entry.Path $entry.Source }

    foreach ($environmentPath in @(
        $env:WindowsSdkDir,
        $env:KitsRoot10,
        $env:ADK_PATH,
        $env:ADKPath,
        $env:WINPEPATH,
        $env:WinPEPath
    )) {
        & $addCandidate $environmentPath 'Variable de entorno'
    }

    foreach ($standardPath in @(
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Windows Kits\10' }),
        'C:\Program Files (x86)\Windows Kits\10',
        'C:\Program Files\Windows Kits\10',
        (Join-Path $script:AIOUpdateApplicationRoot 'WinPE'),
        (Join-Path $script:AIOUpdateApplicationRoot 'Tools\WinPE')
    )) {
        & $addCandidate $standardPath 'Ruta estandar'
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($adkRoot in $candidateMap.Keys) {
        $deploymentToolsRoot = Join-Path $adkRoot 'Deployment Tools'
        $winPeRoot = Join-Path $adkRoot 'Windows Preinstallation Environment'
        if (-not (Test-Path -LiteralPath $winPeRoot -PathType Container)) {
            $directWinPE = @('amd64', 'x86', 'arm64', 'arm') | Where-Object {
                Test-Path -LiteralPath (Join-Path $adkRoot "$_\WinPE_OCs") -PathType Container
            }
            if (@($directWinPE).Count -gt 0) { $winPeRoot = $adkRoot }
        }
        $dismPath = if (Test-Path -LiteralPath $deploymentToolsRoot -PathType Container) {
            Find-AIOUpdateAdkDismPath -DeploymentToolsRoot $deploymentToolsRoot
        }
        else { $null }

        $architectures = New-Object System.Collections.Generic.List[string]
        # El modulo de Actualizaciones solo necesita localizar DISM y conocer
        # que arquitecturas WinPE existen. No requiere contar todos los CAB del
        # Add-on; omitir ese recorrido reduce notablemente el arranque.
        $packageCount = -1
        if (Test-Path -LiteralPath $winPeRoot -PathType Container) {
            foreach ($architecture in @(
                [pscustomobject]@{ Folder = 'amd64'; Name = 'x64' },
                [pscustomobject]@{ Folder = 'x86'; Name = 'x86' },
                [pscustomobject]@{ Folder = 'arm64'; Name = 'arm64' },
                [pscustomobject]@{ Folder = 'arm'; Name = 'arm' }
            )) {
                $ocRoot = Join-Path $winPeRoot "$($architecture.Folder)\WinPE_OCs"
                if (Test-Path -LiteralPath $ocRoot -PathType Container) {
                    [void]$architectures.Add($architecture.Name)
                }
            }
        }

        if ($dismPath -or $architectures.Count -gt 0) {
            [void]$records.Add([pscustomobject]@{
                Root                = $adkRoot
                Source              = $candidateMap[$adkRoot]
                DeploymentToolsRoot = $(if ($dismPath) { $deploymentToolsRoot } else { $null })
                DismPath            = $dismPath
                DismVersion         = Get-AIOUpdateExecutableVersion -Path $dismPath
                WinPERoot           = $(if ($architectures.Count -gt 0) { $winPeRoot } else { $null })
                WinPEArchitectures  = [string[]]$architectures.ToArray()
                WinPEPackageCount   = $packageCount
            })
        }
    }

    $recordArray = [object[]]$records.ToArray()
    $bestDism = @($recordArray | Where-Object { $_.DismPath } | Sort-Object @{ Expression = {
        if ($_.DismVersion) { $_.DismVersion } else { [version]'0.0.0.0' }
    }; Descending = $true }, Root | Select-Object -First 1)
    $bestWinPE = @($recordArray | Where-Object { $_.WinPERoot } | Sort-Object @{ Expression = { @($_.WinPEArchitectures).Count }; Descending = $true }, Root | Select-Object -First 1)

    $dismRecord = if ($bestDism.Count -gt 0) { $bestDism[0] } else { $null }
    $winPeRecord = if ($bestWinPE.Count -gt 0) { $bestWinPE[0] } else { $null }
    $primary = if ($dismRecord) { $dismRecord } elseif ($winPeRecord) { $winPeRecord } else { $null }

    return [pscustomobject]@{
        Detected             = ($null -ne $primary)
        Root                 = $(if ($primary) { $primary.Root } else { $null })
        DetectionSources     = [string[]]@($recordArray | Select-Object -ExpandProperty Source -Unique)
        DeploymentToolsRoot  = $(if ($dismRecord) { $dismRecord.DeploymentToolsRoot } else { $null })
        DismPath             = $(if ($dismRecord) { $dismRecord.DismPath } else { $null })
        DismVersion          = $(if ($dismRecord) { $dismRecord.DismVersion } else { $null })
        WinPERoot            = $(if ($winPeRecord) { $winPeRecord.WinPERoot } else { $null })
        WinPEArchitectures   = $(if ($winPeRecord) { [string[]]$winPeRecord.WinPEArchitectures } else { [string[]]@() })
        WinPEPackageCount    = $(if ($winPeRecord) { [int]$winPeRecord.WinPEPackageCount } else { 0 })
        ActiveDismPath       = $null
        ActiveDismVersion    = $null
        ActiveDismSource     = $null
    }
}

function Initialize-AIOUpdateServicingEnvironment {
    [CmdletBinding()]
    param()

    $adkInfo = Get-AIOUpdateAdkInfo
    $systemVersion = Get-AIOUpdateExecutableVersion -Path $script:AIOUpdateSystemDismPath
    $selectedPath = $script:AIOUpdateSystemDismPath
    $selectedVersion = $systemVersion
    $selectedSource = 'Sistema'

    if ($adkInfo.DismPath) {
        $preferAdk = -not (Test-Path -LiteralPath $selectedPath -PathType Leaf)
        if (-not $preferAdk) {
            if ($adkInfo.DismVersion -and $systemVersion) { $preferAdk = ($adkInfo.DismVersion -gt $systemVersion) }
            elseif ($adkInfo.DismVersion -and -not $systemVersion) { $preferAdk = $true }
        }
        if ($preferAdk) {
            $selectedPath = $adkInfo.DismPath
            $selectedVersion = $adkInfo.DismVersion
            $selectedSource = 'ADK'
        }
    }

    if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
        throw 'No se encontro una herramienta DISM valida en Windows ni en el ADK.'
    }

    $script:AIOUpdateDismPath = $selectedPath
    $script:AIOUpdateDismSource = $selectedSource
    $adkInfo.ActiveDismPath = $selectedPath
    $adkInfo.ActiveDismVersion = $selectedVersion
    $adkInfo.ActiveDismSource = $selectedSource
    $script:AIOUpdateAdkInfo = $adkInfo

    Write-AIOUpdateLog -Level INFO -Message ("ADK detectado={0}; DISM activo={1} {2}; Ruta={3}." -f $adkInfo.Detected, $selectedSource, $selectedVersion, $selectedPath)
    return $adkInfo
}

function Show-AIOUpdateAdkStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$AdkInfo)

    Write-Host ''
    Write-Host ' Herramientas de mantenimiento:' -ForegroundColor Yellow
    if ($AdkInfo.Detected) {
        Write-Host ' ADK          : Detectado' -ForegroundColor Green
        if ($AdkInfo.Root) { Write-Host " Ruta ADK     : $($AdkInfo.Root)" -ForegroundColor White }
    }
    else {
        Write-Host ' ADK          : No detectado' -ForegroundColor Yellow
    }

    $versionText = if ($AdkInfo.ActiveDismVersion) { [string]$AdkInfo.ActiveDismVersion } else { 'N/D' }
    Write-Host " DISM activo  : $($AdkInfo.ActiveDismSource) | $versionText" -ForegroundColor White
    Write-Host " Ruta DISM    : $($AdkInfo.ActiveDismPath)" -ForegroundColor DarkGray
}

function Write-AIOUpdateLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        try {
            Write-Log -LogLevel $Level -Message "Updates: $Message"
        }
        catch {}
    }
}

function Wait-AIOUpdateUser {
    [CmdletBinding()]
    param(
        [string]$Message = 'Presiona ENTER para volver al menu principal'
    )

    try {
        [void](Read-Host "`n$Message")
    }
    catch {
        Start-Sleep -Seconds 2
    }
}

function Initialize-AIOUpdateTerminalState {
    [CmdletBinding()]
    param()

    $script:AIOUpdateLastTerminalState = [pscustomobject]@{
        Status               = 'NotStarted'
        Phase                = 'Inicializacion'
        Message              = $null
        MediaRoot            = $null
        BackupRoot           = $null
        ReportJson           = $null
        ReportHtml           = $null
        DiagnosticPath       = $null
        LogPath              = $null
        MediaMutationStarted = $false
        RestorationStatus    = 'No requerida'
        CompletedTargets     = [object[]]@()
        ErrorLine            = $null
        ErrorCode            = $null
    }
    return $script:AIOUpdateLastTerminalState
}

function Show-AIOUpdateTerminalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Cancelled', 'Restored')]
        [string]$Status,
        [AllowNull()] [string]$Message
    )

    $state = $script:AIOUpdateLastTerminalState
    if (-not $state) { $state = Initialize-AIOUpdateTerminalState }
    $state.Status = $Status
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $state.Message = $Message }

    $title = switch ($Status) {
        'Success'   { 'INTEGRACION COMPLETADA Y VERIFICADA' }
        'Failed'    { 'INTEGRACION FINALIZADA CON ERROR' }
        'Cancelled' { 'OPERACION CANCELADA' }
        'Restored'  { 'RESTAURACION COMPLETADA Y VERIFICADA' }
    }
    $color = switch ($Status) {
        'Success'   { 'Green' }
        'Failed'    { 'Red' }
        'Cancelled' { 'Yellow' }
        'Restored'  { 'Green' }
    }

    Write-Host "`n=======================================================" -ForegroundColor $color
    Write-Host (" {0}" -f $title) -ForegroundColor $color
    Write-Host '=======================================================' -ForegroundColor $color
    if ($state.Message) { Write-Host " Mensaje          : $($state.Message)" -ForegroundColor White }
    if ($state.Phase) { Write-Host " Fase             : $($state.Phase)" -ForegroundColor White }
    if ($state.MediaRoot) { Write-Host " Medio            : $($state.MediaRoot)" -ForegroundColor White }
    Write-Host " Cambios iniciados: $([bool]$state.MediaMutationStarted)" -ForegroundColor White
    if ($Status -eq 'Failed' -or $state.RestorationStatus -ne 'No requerida') {
        $restoreColor = if ($state.RestorationStatus -like 'Restaurado*') { 'Green' } elseif ($state.RestorationStatus -like 'Fallo*') { 'Red' } else { 'Yellow' }
        Write-Host " Restauracion     : $($state.RestorationStatus)" -ForegroundColor $restoreColor
    }
    if ($state.BackupRoot) { Write-Host " Respaldo         : $($state.BackupRoot)" -ForegroundColor Gray }
    if ($state.ReportJson) { Write-Host " Reporte JSON     : $($state.ReportJson)" -ForegroundColor Gray }
    if ($state.ReportHtml) { Write-Host " Reporte HTML     : $($state.ReportHtml)" -ForegroundColor Gray }
    if ($state.DiagnosticPath) { Write-Host " Diagnostico      : $($state.DiagnosticPath)" -ForegroundColor Yellow }
    if ($state.LogPath) { Write-Host " Registro DISM    : $($state.LogPath)" -ForegroundColor DarkGray }
    if ($state.ErrorLine) { Write-Host " Linea            : $($state.ErrorLine)" -ForegroundColor DarkRed }
    if ($state.ErrorCode) { Write-Host " Codigo           : $($state.ErrorCode)" -ForegroundColor DarkRed }

    $completed = @($state.CompletedTargets | Where-Object { $null -ne $_ })
    if ($completed.Count -gt 0) {
        Write-Host "`n Operaciones completadas:" -ForegroundColor Cyan
        foreach ($item in @($completed | Select-Object -First 10)) {
            Write-Host "   [OK] $item" -ForegroundColor Green
        }
        if ($completed.Count -gt 10) {
            Write-Host "   ... y $($completed.Count - 10) operacion(es) adicional(es)." -ForegroundColor DarkGray
        }
    }
}

function Select-AIOUpdateFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    if (Get-Command Select-PathDialog -ErrorAction SilentlyContinue) {
        return Select-PathDialog -DialogType Folder -Title $Title
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Title
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    }
    catch {
        Write-Warning "No se pudo abrir el selector de carpetas: $($_.Exception.Message)"
    }

    return $null
}

function Test-AIOUpdateAdministrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Convert-AIOUpdateExitCodeToUInt32 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    return [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($ExitCode), 0)
}

function Get-AIOUpdateExitCodeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $unsigned = Convert-AIOUpdateExitCodeToUInt32 -ExitCode $ExitCode
    switch ($unsigned) {
        0          { return 'Operacion completada.' }
        3010       { return 'Operacion completada; reinicio requerido.' }
        2148468766 { return 'El paquete no es aplicable a esta imagen.' }
        2148468771 { return 'El paquete requiere una pila de mantenimiento mas reciente.' }
        2148468785 { return 'Falta un manifiesto o paquete prerrequisito.' }
        2148468992 { return 'CBS no pudo procesar el paquete.' }
        2147956499 { return 'El almacen de componentes quedo en un estado no mantenible (0x80073713). Revisa el orden y los prerrequisitos de los paquetes.' }
        552        { return 'El MSU no pudo aplicar su archivo Unattend.xml (0x80070228). En Windows 11 24H2/25H2 suele ocurrir al procesar un checkpoint LCU desde una carpeta mezclada con otros MSU.' }
        2147942512 { return 'No hay espacio suficiente en el disco.' }
        3242328343 { return 'El directorio de montaje ya esta en uso.' }
        default    { return 'Error DISM no clasificado por el modulo.' }
    }
}

function Initialize-AIOUpdateDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Empty
    )

    if ($Empty -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
}



function Get-AIOUpdateFileCacheKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return ('{0}|{1}|{2}' -f $item.FullName.ToLowerInvariant(), [int64]$item.Length, [int64]$item.LastWriteTimeUtc.Ticks)
}

function Clear-AIOUpdateFileHashCache {
    [CmdletBinding()]
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        $script:AIOUpdateFileHashCache = @{}
        return
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant() + '|'
        foreach ($key in @($script:AIOUpdateFileHashCache.Keys)) {
            if ([string]$key -like "$full*") { $script:AIOUpdateFileHashCache.Remove($key) }
        }
    }
    catch {}
}

function Write-AIOUpdateAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Text
    )

    $parent = Split-Path -Parent $Path
    Initialize-AIOUpdateDirectory -Path $parent
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Path) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    $encoding = New-Object System.Text.UTF8Encoding($true)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, $null)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AIOUpdateAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$InputObject,
        [int]$Depth = 12
    )

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    Write-AIOUpdateAtomicText -Path $Path -Text $json
}

function Copy-AIOUpdateFileVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $parent = Split-Path -Parent $Destination
    Initialize-AIOUpdateDirectory -Path $parent
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Destination) + '.copy-' + [guid]::NewGuid().ToString('N'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceStream = New-Object -TypeName System.IO.FileStream -ArgumentList @($sourceItem.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 1048576, [System.IO.FileOptions]::SequentialScan)
        $destinationStream = New-Object -TypeName System.IO.FileStream -ArgumentList @($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576, [System.IO.FileOptions]::SequentialScan)
        $buffer = New-Object byte[] 1048576
        [int64]$length = 0
        while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $destinationStream.Write($buffer, 0, $read)
            $length += $read
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $destinationStream.Flush($true)
        $destinationStream.Dispose(); $destinationStream = $null
        $sourceStream.Dispose(); $sourceStream = $null
        if ($length -ne [int64]$sourceItem.Length) { throw "La copia de '$Source' no coincide en tamano." }

        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Destination, $null)
        }
        else {
            [System.IO.File]::Move($temporary, $Destination)
        }
        [System.IO.File]::SetLastWriteTimeUtc($Destination, $sourceItem.LastWriteTimeUtc)
        Clear-AIOUpdateFileHashCache -Path $Destination
        $sourceHash = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '').ToUpperInvariant()
        $sourceKey = Get-AIOUpdateFileCacheKey -Path $Source
        $script:AIOUpdateFileHashCache[$sourceKey] = $sourceHash
        $destinationHash = Get-AIOUpdateFileSha256 -Path $Destination
        if ($sourceHash -ne $destinationHash) { throw "La copia de '$Source' no coincide por SHA-256." }
        return [pscustomobject]@{ SHA256 = $sourceHash; Length = $length; Destination = $Destination }
    }
    finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        $sha.Dispose()
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AIOUpdateRepositoryPackageFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$RepositoryRoot)

    $resolved = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($path in [System.IO.Directory]::EnumerateFiles($resolved, '*', [System.IO.SearchOption]::AllDirectories)) {
        $extension = [System.IO.Path]::GetExtension($path)
        if ($extension -ieq '.cab' -or $extension -ieq '.msu') {
            [void]$list.Add((New-Object -TypeName System.IO.FileInfo -ArgumentList $path))
        }
    }
    return [System.IO.FileInfo[]]@($list.ToArray() | Sort-Object FullName)
}

function Get-AIOUpdateUniquePackages {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyCollection()] [object[]]$Packages)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Packages)) {
        $identity = [string](@($package.IdentityHints | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)[0])
        $architecture = @($package.Architectures | Sort-Object) -join ','
        if ([string]::IsNullOrWhiteSpace([string]$package.KB) -and [string]::IsNullOrWhiteSpace($identity)) {
            $key = [string]$package.FullName
        }
        else {
            $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f [string]$package.Category, [string]$package.KB, [string]$package.Version, [bool]$package.IsCheckpoint, $architecture, $identity
        }
        if ($seen.Add($key)) { [void]$unique.Add($package) }
        else {
            $script:AIOUpdateOptimizationStats.DuplicatePackagesSkipped++
            Write-AIOUpdateLog -Level WARN -Message "Paquete duplicado omitido antes de DISM: $($package.Name). Clave=$key"
        }
    }
    return [object[]]$unique.ToArray()
}

function Get-AIOUpdateTextSha256 {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Text = '')

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}


function Get-AIOUpdateFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $key = Get-AIOUpdateFileCacheKey -Path $Path
    if ($script:AIOUpdateFileHashCache.ContainsKey($key)) {
        $script:AIOUpdateOptimizationStats.HashCacheHits++
        return [string]$script:AIOUpdateFileHashCache[$key]
    }
    $script:AIOUpdateOptimizationStats.HashCacheMisses++
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ([string]::IsNullOrWhiteSpace([string]$hash) -or $hash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "No se pudo obtener un SHA-256 valido para '$Path'."
    }
    $normalized = $hash.ToUpperInvariant()
    $script:AIOUpdateFileHashCache[$key] = $normalized
    return $normalized
}

function Get-AIOUpdateFilesIndexSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Records)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($Records | Sort-Object { ([string]$_.RelativePath).ToLowerInvariant() })) {
        $relative = ([string]$record.RelativePath).Replace('/', '\').TrimStart('\').ToLowerInvariant()
        $length = [int64]$record.Length
        $hash = ([string]$record.SHA256).ToUpperInvariant()
        [void]$lines.Add(('{0}|{1}|{2}' -f $relative, $length, $hash))
    }
    return Get-AIOUpdateTextSha256 -Text (($lines -join "`n") + "`n")
}

function Get-AIOUpdateLocalesFromLangIniPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $locales = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $clean = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($clean) -or $clean.StartsWith(';') -or $clean.StartsWith('#')) { continue }
        foreach ($pattern in @(
            '^\s*([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)\s*=',
            '=\s*([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)\s*$'
        )) {
            if ($clean -match $pattern) { [void]$locales.Add($Matches[1]) }
        }
    }
    return [string[]]@($locales | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
}


function Get-AIOUpdatePreflightBackupFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [switch]$IncludeSetupSurface
    )

    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $addFile = {
        param([string]$Candidate)
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return }
        $item = Get-Item -LiteralPath $Candidate -Force -ErrorAction Stop
        if ($item.FullName -match '(?i)[\\/]AdminImagenOffline_Backup[\\/]') { return }
        if ($seen.Add($item.FullName)) { [void]$files.Add($item) }
    }

    foreach ($relative in @('sources\install.wim', 'sources\boot.wim')) {
        & $addFile (Join-Path $media $relative)
    }

    if ($IncludeSetupSurface) {
        foreach ($relativeDirectory in @('sources', 'boot', 'efi')) {
            $directory = Join-Path $media $relativeDirectory
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
            foreach ($path in [System.IO.Directory]::EnumerateFiles($directory, '*', [System.IO.SearchOption]::AllDirectories)) {
                & $addFile $path
            }
        }
        foreach ($relativeFile in @('setup.exe', 'bootmgr', 'bootmgr.efi', 'autorun.inf')) {
            & $addFile (Join-Path $media $relativeFile)
        }
    }

    return [System.IO.FileInfo[]]@($files.ToArray() | Sort-Object FullName)
}

function New-AIOUpdatePreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$BackupRoot,
        [switch]$IncludeSetupSurface
    )

    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    $preflightRoot = Join-Path $BackupRoot 'Preflight'
    $mirrorRoot = Join-Path $preflightRoot 'Media'
    $manifestPath = Join-Path $preflightRoot 'manifest.json'
    $incompletePath = Join-Path $preflightRoot 'BACKUP_INCOMPLETO.txt'

    Write-Host "`n=======================================================" -ForegroundColor DarkCyan
    Write-Host ' RESPALDO PREVIO OBLIGATORIO' -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor DarkCyan

    Initialize-AIOUpdateDirectory -Path $preflightRoot -Empty
    Initialize-AIOUpdateDirectory -Path $mirrorRoot
    Set-Content -LiteralPath $incompletePath -Value 'El respaldo no se completo. No utilizar como restauracion.' -Encoding UTF8

    $files = @(Get-AIOUpdatePreflightBackupFiles -MediaRoot $media -IncludeSetupSurface:$IncludeSetupSurface)
    if ($files.Count -eq 0) {
        throw 'No se encontraron archivos del medio para crear el respaldo previo.'
    }

    [int64]$totalBytes = 0
    foreach ($file in $files) { $totalBytes += [int64]$file.Length }

    $driveRoot = [System.IO.Path]::GetPathRoot($BackupRoot)
    if (-not [string]::IsNullOrWhiteSpace($driveRoot)) {
        try {
            $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $driveRoot
            [int64]$criticalBytes = 0
            foreach ($critical in @($files | Where-Object { $_.FullName -match '(?i)[\\/]sources[\\/](install|boot)\.wim$' })) {
                $criticalBytes += [int64]$critical.Length
            }
            [int64]$reserve = [math]::Max([int64](2GB), [int64]($criticalBytes + ($totalBytes * 0.20)))
            [int64]$required = $totalBytes + $reserve
            if ($drive.AvailableFreeSpace -lt $required) {
                throw ("Espacio insuficiente para el respaldo previo. Requerido aproximado: {0:N2} GB; disponible: {1:N2} GB." -f ($required / 1GB), ($drive.AvailableFreeSpace / 1GB))
            }
        }
        catch {
            if ($_.Exception.Message -match 'Espacio insuficiente') { throw }
            Write-AIOUpdateLog -Level WARN -Message "No se pudo comprobar el espacio libre del respaldo previo: $($_.Exception.Message)"
        }
    }

    Write-Host (" Archivos a respaldar : {0}" -f $files.Count) -ForegroundColor White
    Write-Host (" Tamano aproximado    : {0:N2} GB" -f ($totalBytes / 1GB)) -ForegroundColor White
    Write-Host " Destino              : $preflightRoot" -ForegroundColor White
    Write-Host ' Hash                 : SHA-256 para todos los archivos' -ForegroundColor DarkGray

    $records = New-Object System.Collections.Generic.List[object]
    $criticalNames = @('sources\install.wim', 'sources\boot.wim')
    $position = 0

    foreach ($file in $files) {
        $position++
        $relative = $file.FullName.Substring($media.Length).TrimStart('\')
        $destination = Join-Path $mirrorRoot $relative
        Initialize-AIOUpdateDirectory -Path (Split-Path -Parent $destination)

        if ($relative -in $criticalNames) {
            Write-Host "   [$position/$($files.Count)] Copiando y verificando $relative..." -ForegroundColor Gray
        }

        $copyResult = Copy-AIOUpdateFileVerified -Source $file.FullName -Destination $destination
        $sourceHash = [string]$copyResult.SHA256
        if ($relative -in $criticalNames) {
            Write-Host '      [VERIFICADO] SHA-256 coincide.' -ForegroundColor DarkGray
        }

        [void]$records.Add([pscustomobject]@{
            RelativePath     = $relative
            Length           = [int64]$file.Length
            LastWriteTimeUtc = $file.LastWriteTimeUtc
            SHA256           = $sourceHash
        })
    }

    $filesIndexSha256 = Get-AIOUpdateFilesIndexSha256 -Records ([object[]]$records.ToArray())
    $trustedLocales = @(Get-AIOUpdateLocalesFromLangIniPath -Path (Join-Path $media 'sources\lang.ini'))
    if ($IncludeSetupSurface -and $trustedLocales.Count -eq 0) {
        throw 'No se pudo derivar una lista confiable de idiomas desde sources\lang.ini; no se continuara con una superficie Setup modificable.'
    }
    $manifest = [pscustomobject]@{
        SchemaVersion       = 3
        FormatVersion       = 3
        Structure           = 'Preflight\Media'
        CreatedAt           = (Get-Date).ToString('o')
        MediaRoot           = $media
        IncludeSetupSurface = [bool]$IncludeSetupSurface
        HashAlgorithm       = 'SHA256'
        HashCoverage        = 'AllFiles'
        LocalePolicy        = 'LangIni'
        TrustedLocales      = [string[]]$trustedLocales
        HashedFileCount     = $records.Count
        FilesIndexSha256    = $filesIndexSha256
        FileCount           = $records.Count
        TotalBytes          = $totalBytes
        Files               = [object[]]($records.ToArray())
    }
    Write-AIOUpdateAtomicJson -Path $manifestPath -InputObject $manifest -Depth 6

    # Releer inmediatamente evita aceptar un JSON truncado o no serializable.
    $writtenManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$writtenManifest.SchemaVersion -ne 3 -or
        [int]$writtenManifest.FormatVersion -ne 3 -or
        [string]$writtenManifest.FilesIndexSha256 -ne $filesIndexSha256 -or
        [int]$writtenManifest.HashedFileCount -ne $records.Count) {
        throw 'El manifest.json del respaldo no supero la verificacion posterior a escritura.'
    }

    Remove-Item -LiteralPath $incompletePath -Force -ErrorAction Stop

    Write-AIOUpdateLog -Level INFO -Message ("Respaldo previo completado y verificado: {0} archivo(s), {1:N2} GB, {2} hashes SHA-256, indice={3}, destino '{4}'." -f $records.Count, ($totalBytes / 1GB), $records.Count, $filesIndexSha256, $preflightRoot)
    Write-Host " [OK] Respaldo previo completado y verificado ($($records.Count) hashes SHA-256)." -ForegroundColor Green

    return [pscustomobject]@{
        Success             = $true
        MediaRoot           = $media
        Root                = $preflightRoot
        MirrorRoot          = $mirrorRoot
        ManifestPath        = $manifestPath
        FileCount           = $records.Count
        TotalBytes          = $totalBytes
        IncludeSetupSurface = [bool]$IncludeSetupSurface
        SchemaVersion       = 3
        FormatVersion       = 3
        HashAlgorithm       = 'SHA256'
        TrustedLocales      = [string[]]$trustedLocales
        HashedFileCount     = $records.Count
        FilesIndexSha256    = $filesIndexSha256
    }
}

function Get-AIOUpdatePreflightBackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $context = $script:AIOUpdatePreflightContext
    if ($null -eq $context -or -not $context.Success) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$context.MediaRoot) -or
        [string]::IsNullOrWhiteSpace([string]$context.MirrorRoot)) {
        return $null
    }

    try {
        $mediaRoot = [System.IO.Path]::GetFullPath([string]$context.MediaRoot).TrimEnd('\')
        $destinationPath = [System.IO.Path]::GetFullPath($Destination)
        $prefix = $mediaRoot + '\'
        if (-not $destinationPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        $relative = $destinationPath.Substring($prefix.Length)
        $candidate = Join-Path ([string]$context.MirrorRoot) $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo resolver la copia Preflight de '$Destination': $($_.Exception.Message)"
    }

    return $null
}

function Initialize-AIOUpdatePreflightRuntimeIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$Context
    )

    $script:AIOUpdatePreflightPathIndex = @{}
    $script:AIOUpdatePreflightLocalesBySurface = @{
        Sources = @{}
        Boot    = @{}
        EfiBoot = @{}
    }
    $script:AIOUpdateSessionCreatedPathIndex = @{}
    $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
    $script:AIOUpdateTrustedLocales = @{}

    if ($null -eq $Context -or -not $Context.Success -or
        [string]::IsNullOrWhiteSpace([string]$Context.ManifestPath) -or
        -not (Test-Path -LiteralPath $Context.ManifestPath -PathType Leaf)) {
        return
    }

    try {
        $manifest = Get-Content -LiteralPath $Context.ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($record in @($manifest.Files)) {
            $relative = [string]$record.RelativePath
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $key = $relative.Replace('/', '\').TrimStart('\').ToLowerInvariant()
            $script:AIOUpdatePreflightPathIndex[$key] = $true

            foreach ($surface in @(
                @{ Name = 'Sources'; Pattern = '^(?i)sources[\\/]([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)(?:[\\/]|$)' },
                @{ Name = 'Boot';    Pattern = '^(?i)boot[\\/]([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)(?:[\\/]|$)' },
                @{ Name = 'EfiBoot'; Pattern = '^(?i)efi[\\/]microsoft[\\/]boot[\\/]([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)(?:[\\/]|$)' }
            )) {
                if ($relative -match $surface.Pattern) {
                    $locale = $Matches[1].ToLowerInvariant()
                    $script:AIOUpdatePreflightLocalesBySurface[$surface.Name][$locale] = $true
                }
            }
        }

        if ([int]$manifest.SchemaVersion -ne 3 -or [int]$manifest.FormatVersion -ne 3) {
            throw 'El indice de ejecucion solo admite manifiestos Preflight 3/3.'
        }
        $trustedLocales = @($manifest.TrustedLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
        if ([bool]$Context.IncludeSetupSurface -and $trustedLocales.Count -eq 0) {
            throw 'El manifiesto Preflight 3/3 no contiene TrustedLocales para filtrar SetupDU.'
        }
        foreach ($locale in $trustedLocales) { $script:AIOUpdateTrustedLocales[$locale] = $true }
        foreach ($surfaceName in @('Sources', 'Boot', 'EfiBoot')) {
            $script:AIOUpdatePreflightLocalesBySurface[$surfaceName] = @{}
            foreach ($locale in $trustedLocales) {
                $script:AIOUpdatePreflightLocalesBySurface[$surfaceName][$locale] = $true
            }
        }
        if ($trustedLocales.Count -gt 0) {
            Write-AIOUpdateLog -Level INFO -Message "Politica de idiomas confiable leida del manifiesto Preflight 3/3: $($trustedLocales -join ', ')."
        }
    }
    catch {
        $script:AIOUpdatePreflightPathIndex = @{}
        $script:AIOUpdatePreflightLocalesBySurface = @{}
        $script:AIOUpdateSessionCreatedPathIndex = @{}
        $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
        $script:AIOUpdateTrustedLocales = @{}
        Write-AIOUpdateLog -Level ERROR -Message "No se pudo crear el indice runtime del Preflight 3/3: $($_.Exception.Message)"
        throw
    }
}

function Get-AIOUpdatePreflightAllowedLocales {
    [CmdletBinding()]
    param(
        [ValidateSet('Sources', 'Boot', 'EfiBoot')]
        [string]$Surface = 'Sources'
    )

    if (-not $script:AIOUpdatePreflightLocalesBySurface.ContainsKey($Surface)) { return @() }
    return [string[]]@($script:AIOUpdatePreflightLocalesBySurface[$Surface].Keys | Sort-Object)
}

function Get-AIOUpdateMediaRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $context = $script:AIOUpdatePreflightContext
    if ($null -eq $context -or -not $context.Success -or
        [string]::IsNullOrWhiteSpace([string]$context.MediaRoot)) { return $null }

    $mediaRoot = [System.IO.Path]::GetFullPath([string]$context.MediaRoot).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $prefix = $mediaRoot + '\'
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $candidate.Substring($prefix.Length).Replace('/', '\').TrimStart('\')
}

function Register-AIOUpdateSessionCreatedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [AllowNull()] [string]$Source,
        [string]$Reason = 'Creado por el modulo'
    )

    try {
        $relative = Get-AIOUpdateMediaRelativePath -Path $Path
        if ([string]::IsNullOrWhiteSpace([string]$relative)) { return $false }
        $key = $relative.ToLowerInvariant()
        if ($script:AIOUpdatePreflightPathIndex.ContainsKey($key)) { return $false }
        if (-not $script:AIOUpdateSessionCreatedPathIndex.ContainsKey($key)) {
            $event = [pscustomobject]@{
                RelativePath = $relative
                Destination  = [System.IO.Path]::GetFullPath($Path)
                Source       = $Source
                Reason       = $Reason
                CreatedAt    = (Get-Date).ToString('o')
            }
            $script:AIOUpdateSessionCreatedPathIndex[$key] = $event
            [void]$script:AIOUpdateSessionCreatedPathEvents.Add($event)
            Write-AIOUpdateLog -Level INFO -Message "Archivo registrado explicitamente como creado por la sesion: '$relative'."
        }
        return $true
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo registrar como creado por la sesion '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Test-AIOUpdateSessionCreatedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    try {
        $relative = Get-AIOUpdateMediaRelativePath -Path $Path
        if ([string]::IsNullOrWhiteSpace([string]$relative)) { return $false }
        return $script:AIOUpdateSessionCreatedPathIndex.ContainsKey($relative.ToLowerInvariant())
    }
    catch { return $false }
}

function Get-AIOUpdatePreflightPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $context = $script:AIOUpdatePreflightContext
    if ($null -eq $context -or -not $context.Success -or
        [string]::IsNullOrWhiteSpace([string]$context.MediaRoot)) {
        return [pscustomobject]@{ InsideMedia = $false; RelativePath = ''; Tracked = $false; CoveredSurface = $false; KnownNew = $false }
    }

    try {
        $relative = Get-AIOUpdateMediaRelativePath -Path $Destination
        if ([string]::IsNullOrWhiteSpace([string]$relative)) {
            return [pscustomobject]@{ InsideMedia = $false; RelativePath = ''; Tracked = $false; CoveredSurface = $false; KnownNew = $false }
        }
        $key = $relative.ToLowerInvariant()
        $tracked = $script:AIOUpdatePreflightPathIndex.ContainsKey($key)
        $criticalWim = $relative -match '^(?i)sources[\\/](install|boot)\.wim$'
        $setupSurface = [bool]$context.IncludeSetupSurface -and (
            $relative -match '^(?i)(sources|boot|efi)[\\/]' -or
            $relative -match '^(?i)(setup\.exe|bootmgr|bootmgr\.efi|autorun\.inf)$'
        )
        $covered = $criticalWim -or $setupSurface
        $knownNew = $covered -and -not $tracked -and (Test-AIOUpdateSessionCreatedPath -Path $Destination)

        return [pscustomobject]@{
            InsideMedia    = $true
            RelativePath   = $relative
            Tracked        = $tracked
            CoveredSurface = $covered
            KnownNew       = $knownNew
        }
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo evaluar la cobertura Preflight de '$Destination': $($_.Exception.Message)"
        return [pscustomobject]@{ InsideMedia = $false; RelativePath = ''; Tracked = $false; CoveredSurface = $false; KnownNew = $false }
    }
}

function Test-AIOUpdateLocaleRelativePathAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RelativePath,
        [ValidateSet('Sources', 'Boot', 'EfiBoot')]
        [string]$Surface = 'Sources'
    )

    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -eq 0) { return $true }
    $candidate = [string]$parts[0]
    if ($candidate -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') { return $true }

    $allowed = @(Get-AIOUpdatePreflightAllowedLocales -Surface $Surface)
    if ($allowed.Count -eq 0) { return $true }
    return ($candidate.ToLowerInvariant() -in $allowed)
}

function Remove-AIOUpdateUnexpectedMediaLocaleDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot
    )

    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($surface in @(
        @{ Name = 'Sources'; Relative = 'sources' },
        @{ Name = 'Boot';    Relative = 'boot' },
        @{ Name = 'EfiBoot'; Relative = 'efi\microsoft\boot' }
    )) {
        $allowed = @(Get-AIOUpdatePreflightAllowedLocales -Surface $surface.Name)
        if ($allowed.Count -eq 0) { continue }

        $root = Join-Path $MediaRoot $surface.Relative
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($directory.Name -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') { continue }
            $locale = $directory.Name.ToLowerInvariant()
            if ($locale -in $allowed) { continue }

            foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue)) {
                attrib -R -S -H $item.FullName 2>$null
            }
            attrib -R -S -H $directory.FullName 2>$null
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            [void]$removed.Add([pscustomobject]@{
                Surface = $surface.Name
                Locale  = $directory.Name
                Path    = $directory.FullName
            })
            Write-AIOUpdateLog -Level WARN -Message "Idioma no presente en Preflight eliminado de la superficie $($surface.Name): '$($directory.Name)' ($($directory.FullName))."
        }
    }

    return [object[]]($removed.ToArray())
}

function Test-AIOUpdateMediaLocalePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot)

    $unexpected = New-Object System.Collections.Generic.List[object]
    foreach ($surface in @(
        @{ Name = 'Sources'; Relative = 'sources' },
        @{ Name = 'Boot';    Relative = 'boot' },
        @{ Name = 'EfiBoot'; Relative = 'efi\microsoft\boot' }
    )) {
        $allowed = @(Get-AIOUpdatePreflightAllowedLocales -Surface $surface.Name)
        if ($allowed.Count -eq 0) { continue }
        $root = Join-Path $MediaRoot $surface.Relative
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($directory.Name -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') { continue }
            if ($directory.Name.ToLowerInvariant() -notin $allowed) {
                [void]$unexpected.Add([pscustomobject]@{ Surface = $surface.Name; Locale = $directory.Name; Path = $directory.FullName })
            }
        }
    }
    return [pscustomobject]@{
        Success            = ($unexpected.Count -eq 0)
        AllowedLocales     = [string[]]@($script:AIOUpdateTrustedLocales.Keys | Sort-Object)
        UnexpectedLocales  = [object[]]$unexpected.ToArray()
    }
}

function Invoke-AIOUpdateAtomicReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$MoveSource,
        [scriptblock]$Verifier
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "${Context}: no existe el archivo de reemplazo '$Source'."
    }

    $destinationDirectory = Split-Path -Parent $Destination
    Initialize-AIOUpdateDirectory -Path $destinationDirectory

    $hadDestination = Test-Path -LiteralPath $Destination -PathType Leaf
    $rollbackPath = $null
    if ($hadDestination) {
        $rollbackName = '.aio-rollback-' + [guid]::NewGuid().ToString('N') + '-' + [System.IO.Path]::GetFileName($Destination)
        $rollbackPath = Join-Path $destinationDirectory $rollbackName
        attrib -R -S -H $Destination 2>$null
        Move-Item -LiteralPath $Destination -Destination $rollbackPath -Force -ErrorAction Stop
    }

    try {
        if ($MoveSource) {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        }
        else {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        }

        if ($Verifier) {
            & $Verifier $Destination
        }

        if ($rollbackPath -and (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
            Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction Stop
        }

        return [pscustomobject]@{
            Success      = $true
            Destination  = $Destination
            HadOriginal  = $hadDestination
            RollbackUsed = [bool]$rollbackPath
        }
    }
    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if ($rollbackPath -and (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
            Move-Item -LiteralPath $rollbackPath -Destination $Destination -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}


function Resolve-AIOUpdatePreflightRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
    if ((Split-Path -Leaf $resolved) -ine 'Preflight') {
        throw "Selecciona directamente la carpeta 'Preflight' del respaldo actual."
    }

    $manifestPath = Join-Path $resolved 'manifest.json'
    $mirrorRoot = Join-Path $resolved 'Media'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "La carpeta seleccionada no contiene el manifest.json actual: '$resolved'."
    }
    if (-not (Test-Path -LiteralPath $mirrorRoot -PathType Container)) {
        throw "La carpeta seleccionada no contiene la estructura actual 'Preflight\Media': '$resolved'."
    }

    return $resolved
}

function Read-AIOUpdatePreflightManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PreflightRoot
    )

    $root = Resolve-AIOUpdatePreflightRoot -Path $PreflightRoot
    $manifestPath = Join-Path $root 'manifest.json'
    $incomplete = Join-Path $root 'BACKUP_INCOMPLETO.txt'

    if (Test-Path -LiteralPath $incomplete -PathType Leaf) {
        throw "El respaldo Preflight esta marcado como incompleto: '$root'."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $requiredProperties = @(
        'SchemaVersion', 'FormatVersion', 'Structure', 'CreatedAt', 'MediaRoot',
        'IncludeSetupSurface', 'HashAlgorithm', 'HashCoverage', 'LocalePolicy',
        'TrustedLocales', 'HashedFileCount', 'FilesIndexSha256', 'FileCount',
        'TotalBytes', 'Files'
    )
    foreach ($propertyName in $requiredProperties) {
        if (-not $manifest.PSObject.Properties[$propertyName]) {
            throw "El manifiesto Preflight no contiene la propiedad obligatoria '$propertyName'."
        }
    }

    $schema = [int]$manifest.SchemaVersion
    $format = [int]$manifest.FormatVersion
    if ($schema -ne 3 -or $format -ne 3) {
        throw "Respaldo no compatible: se requiere SchemaVersion/FormatVersion 3/3 y se recibio $schema/$format. Los respaldos anteriores deben recrearse."
    }
    if ([string]$manifest.Structure -cne 'Preflight\Media') {
        throw "La estructura del respaldo no es valida: se requiere 'Preflight\Media'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.MediaRoot)) {
        throw 'El manifiesto Preflight no contiene MediaRoot.'
    }
    $createdAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$manifest.CreatedAt, [ref]$createdAt)) {
        throw 'El manifiesto Preflight contiene una fecha CreatedAt invalida.'
    }
    if (-not $manifest.Files -or @($manifest.Files).Count -eq 0) {
        throw 'El manifiesto Preflight no contiene archivos.'
    }
    if ([int]$manifest.FileCount -ne @($manifest.Files).Count) {
        throw 'FileCount no coincide con la lista Files del manifiesto Preflight.'
    }
    if ([string]$manifest.HashAlgorithm -cne 'SHA256' -or [string]$manifest.HashCoverage -cne 'AllFiles') {
        throw 'El manifiesto no declara cobertura SHA256 para todos los archivos.'
    }
    if ([string]$manifest.LocalePolicy -cne 'LangIni') {
        throw 'El manifiesto no declara la politica de idiomas LangIni.'
    }

    $trustedLocales = @($manifest.TrustedLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($locale in $trustedLocales) {
        if ($locale -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') {
            throw "El manifiesto contiene un idioma confiable invalido: '$locale'."
        }
    }
    if ([bool]$manifest.IncludeSetupSurface -and $trustedLocales.Count -eq 0) {
        throw 'El manifiesto no contiene idiomas confiables para la superficie Setup.'
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [int64]$declaredBytes = 0
    foreach ($record in @($manifest.Files)) {
        foreach ($propertyName in @('RelativePath', 'Length', 'LastWriteTimeUtc', 'SHA256')) {
            if (-not $record.PSObject.Properties[$propertyName]) {
                throw "Un registro de archivos no contiene la propiedad obligatoria '$propertyName'."
            }
        }
        $relative = [string]$record.RelativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted($relative) -or
            (@($relative -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0)) {
            throw "El manifiesto Preflight contiene una ruta invalida: '$relative'."
        }
        if (-not $seen.Add($relative)) {
            throw "El manifiesto Preflight contiene una ruta duplicada: '$relative'."
        }
        if ($null -eq $record.Length -or [int64]$record.Length -lt 0) {
            throw "El registro '$relative' no contiene una longitud valida."
        }
        $hash = [string]$record.SHA256
        if ($hash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "El registro '$relative' no contiene un SHA-256 valido."
        }
        $declaredBytes += [int64]$record.Length
    }

    if ([int64]$manifest.TotalBytes -ne $declaredBytes) {
        throw 'TotalBytes no coincide con la suma de los registros Files.'
    }
    if ([int]$manifest.HashedFileCount -ne @($manifest.Files).Count) {
        throw 'HashedFileCount no coincide con la lista Files.'
    }
    $indexHash = Get-AIOUpdateFilesIndexSha256 -Records @($manifest.Files)
    if ($indexHash -ne [string]$manifest.FilesIndexSha256) {
        throw 'FilesIndexSha256 no coincide con el contenido del manifiesto.'
    }

    $mirrorRoot = Join-Path $root 'Media'
    if (-not (Test-Path -LiteralPath $mirrorRoot -PathType Container)) {
        throw "No existe la carpeta Media del respaldo: '$mirrorRoot'."
    }

    return [pscustomobject]@{
        Root         = $root
        ManifestPath = $manifestPath
        MirrorRoot   = $mirrorRoot
        Manifest     = $manifest
    }
}

function Test-AIOUpdatePreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PreflightRoot,
        [ValidateSet('All', 'InstallWim', 'BootWim', 'Setup')]
        [string]$Scope = 'All'
    )

    $context = Read-AIOUpdatePreflightManifest -PreflightRoot $PreflightRoot
    $records = @($context.Manifest.Files)

    switch ($Scope) {
        'InstallWim' { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\install.wim' }) }
        'BootWim'    { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\boot.wim' }) }
        'Setup'      { $records = @($records | Where-Object { $_.RelativePath -notin @('sources\install.wim', 'sources\boot.wim') }) }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    [int64]$validatedBytes = 0
    [int]$validatedHashes = 0
    foreach ($record in $records) {
        $source = Join-Path $context.MirrorRoot ([string]$record.RelativePath)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            [void]$errors.Add("Falta '$($record.RelativePath)'.")
            continue
        }

        $file = Get-Item -LiteralPath $source -ErrorAction Stop
        if ([int64]$file.Length -ne [int64]$record.Length) {
            [void]$errors.Add("Tamano incorrecto en '$($record.RelativePath)'.")
            continue
        }
        $validatedBytes += [int64]$file.Length

        $expectedHash = [string]$record.SHA256
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            [void]$errors.Add("SHA-256 ausente o invalido en '$($record.RelativePath)'.")
            continue
        }
        $hash = Get-AIOUpdateFileSha256 -Path $source
        $validatedHashes++
        if ($hash -ne $expectedHash) {
            [void]$errors.Add("SHA-256 incorrecto en '$($record.RelativePath)'.")
        }
    }

    if ($Scope -eq 'All' -and [int64]$context.Manifest.TotalBytes -ne $validatedBytes) {
        [void]$errors.Add('TotalBytes no coincide con los archivos validados.')
    }
    if ($Scope -eq 'All' -and [int]$context.Manifest.HashedFileCount -ne $validatedHashes) {
        [void]$errors.Add('HashedFileCount no coincide con los hashes verificados.')
    }

    return [pscustomobject]@{
        Success          = ($errors.Count -eq 0)
        Root             = $context.Root
        MirrorRoot       = $context.MirrorRoot
        Manifest         = $context.Manifest
        Scope            = $Scope
        RecordCount      = $records.Count
        ValidatedBytes   = $validatedBytes
        ValidatedHashes  = $validatedHashes
        Errors           = [string[]]($errors.ToArray())
    }
}

function Restore-AIOUpdatePreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PreflightRoot,
        [AllowNull()] [string]$TargetMediaRoot,
        [ValidateSet('All', 'InstallWim', 'BootWim', 'Setup')]
        [string]$Scope = 'All'
    )

    Assert-AIOUpdateNoMountedImages

    $validation = Test-AIOUpdatePreflightBackup -PreflightRoot $PreflightRoot -Scope $Scope
    if (-not $validation.Success) {
        throw "El respaldo Preflight no supero la validacion: $($validation.Errors -join ' ')"
    }

    $manifest = $validation.Manifest
    $target = if (-not [string]::IsNullOrWhiteSpace($TargetMediaRoot)) {
        (Resolve-Path -LiteralPath $TargetMediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    }
    elseif (Test-Path -LiteralPath ([string]$manifest.MediaRoot) -PathType Container) {
        (Resolve-Path -LiteralPath ([string]$manifest.MediaRoot) -ErrorAction Stop).Path.TrimEnd('\')
    }
    else {
        throw 'El medio original ya no existe. Especifica TargetMediaRoot.'
    }

    if (-not (Test-AIOUpdateMediaWritable -MediaRoot $target)) {
        throw "El destino de restauracion no es escribible: '$target'."
    }

    $records = @($manifest.Files)
    switch ($Scope) {
        'InstallWim' { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\install.wim' }) }
        'BootWim'    { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\boot.wim' }) }
        'Setup'      { $records = @($records | Where-Object { $_.RelativePath -notin @('sources\install.wim', 'sources\boot.wim') }) }
    }
    if ($records.Count -eq 0) {
        throw "El respaldo no contiene archivos para el alcance '$Scope'."
    }

    $started = Get-Date
    $restored = New-Object System.Collections.Generic.List[object]
    $expected = @{}
    foreach ($record in $records) {
        $expected[[string]$record.RelativePath.ToLowerInvariant()] = $true
    }

    Write-Host "`n=======================================================" -ForegroundColor DarkCyan
    Write-Host ' RESTAURANDO RESPALDO PREFLIGHT' -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor DarkCyan
    Write-Host " Origen  : $($validation.Root)" -ForegroundColor White
    Write-Host " Destino : $target" -ForegroundColor White
    Write-Host " Alcance : $Scope" -ForegroundColor White
    Write-Host " Archivos: $($records.Count)" -ForegroundColor White

    $position = 0
    foreach ($record in $records) {
        $position++
        $relative = [string]$record.RelativePath
        $source = Join-Path $validation.MirrorRoot $relative
        $destination = Join-Path $target $relative
        $expectedLength = [int64]$record.Length
        $expectedHash = [string]$record.SHA256

        if ($relative -match '(?i)^sources[\\/](install|boot)\.wim$') {
            Write-Host "   [$position/$($records.Count)] Restaurando $relative..." -ForegroundColor Gray
        }

        $verifier = {
            param($path)
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            if ([int64]$file.Length -ne $expectedLength) {
                throw "La restauracion de '$relative' no coincide en tamano."
            }
            if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($hash -ne $expectedHash) {
                    throw "La restauracion de '$relative' no coincide por SHA-256."
                }
            }
        }.GetNewClosure()

        [void](Invoke-AIOUpdateAtomicReplacement -Source $source -Destination $destination -Context "Restaurando $relative" -Verifier $verifier)
        try {
            (Get-Item -LiteralPath $destination -ErrorAction Stop).LastWriteTimeUtc = [datetime]$record.LastWriteTimeUtc
        }
        catch {}

        [void]$restored.Add([pscustomobject]@{
            RelativePath = $relative
            Length       = $expectedLength
            SHA256       = $expectedHash
        })
    }

    # Para restauracion completa o de Setup se eliminan archivos agregados por
    # SetupDU que no existian en el manifiesto. Los WIM quedan protegidos cuando
    # el alcance es solamente Setup.
    $removedExtras = New-Object System.Collections.Generic.List[string]
    if ($Scope -in @('All', 'Setup')) {
        $protected = @{}
        if ($Scope -eq 'Setup') {
            $protected['sources\install.wim'] = $true
            $protected['sources\boot.wim'] = $true
        }

        foreach ($relativeDirectory in @('sources', 'boot', 'efi')) {
            $directory = Join-Path $target $relativeDirectory
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }

            foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $relative = $file.FullName.Substring($target.Length).TrimStart('\')
                $key = $relative.ToLowerInvariant()
                if ($protected.ContainsKey($key)) { continue }
                if (-not $expected.ContainsKey($key)) {
                    attrib -R -S -H $file.FullName 2>$null
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    [void]$removedExtras.Add($relative)
                }
            }

            foreach ($folder in @(Get-ChildItem -LiteralPath $directory -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
                if (@(Get-ChildItem -LiteralPath $folder.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $folder.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        foreach ($relative in @('setup.exe', 'bootmgr', 'bootmgr.efi', 'autorun.inf')) {
            $key = $relative.ToLowerInvariant()
            $candidate = Join-Path $target $relative
            if (-not $expected.ContainsKey($key) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                attrib -R -S -H $candidate 2>$null
                Remove-Item -LiteralPath $candidate -Force -ErrorAction Stop
                [void]$removedExtras.Add($relative)
            }
        }
    }

    $ended = Get-Date
    $result = [pscustomobject]@{
        Success          = $true
        Status           = 'Restored'
        MediaRoot        = $target
        Scope            = $Scope
        PreflightRoot    = $validation.Root
        StartedAt        = $started
        EndedAt          = $ended
        DurationSeconds  = [math]::Round(($ended - $started).TotalSeconds, 2)
        RestoredFiles    = [object[]]($restored.ToArray())
        RemovedExtraFiles = [string[]]($removedExtras.ToArray())
    }

    $reportRoot = Join-Path $script:AIOUpdateReportsRoot 'Restauracion'
    $report = Export-AIOUpdateStructuredReport -Status 'Restored' -OutputDirectory $reportRoot -MediaRoot $target -StartedAt $started -EndedAt $ended -CompletedTargets @("Restauracion $Scope completada") -PreflightBackup ([pscustomobject]@{ Root = $validation.Root; ManifestPath = Join-Path $validation.Root 'manifest.json'; FileCount = $records.Count; TotalBytes = [int64]$manifest.TotalBytes }) -Options ([pscustomobject]@{ Scope = $Scope; RemovedExtraFiles = $removedExtras.Count })
    $result | Add-Member -NotePropertyName StructuredReport -NotePropertyValue $report

    Write-AIOUpdateLog -Level INFO -Message "Restauracion Preflight completada. Alcance=$Scope; archivos=$($restored.Count); extras eliminados=$($removedExtras.Count); destino='$target'."
    Write-Host " [OK] Restauracion completada y verificada." -ForegroundColor Green
    Write-Host " Reporte JSON: $($report.JsonPath)" -ForegroundColor DarkGray
    Write-Host " Reporte HTML: $($report.HtmlPath)" -ForegroundColor DarkGray
    return $result
}

function ConvertTo-AIOUpdateNativeArgument {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    # Reglas de escape de CommandLineToArgvW: duplica las barras que
    # preceden comillas y las barras finales cuando el argumento va citado.
    $builder = New-Object System.Text.StringBuilder
    $backslash = [char]92
    [void]$builder.Append('"')
    $slashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq $backslash) {
            $slashes++
            continue
        }

        if ($character -eq '"') {
            if ($slashes -gt 0) {
                [void]$builder.Append(($backslash.ToString() * ($slashes * 2)))
            }
            [void]$builder.Append($backslash)
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }

        if ($slashes -gt 0) {
            [void]$builder.Append(($backslash.ToString() * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($slashes -gt 0) {
        [void]$builder.Append(($backslash.ToString() * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Add-AIOUpdateDismTranscriptLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if (-not $script:AIOUpdateDismTranscript) { return }
    try {
        ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Line) |
            Out-File -LiteralPath $script:AIOUpdateDismTranscript -Append -Encoding utf8
    }
    catch {}
}

function Invoke-AIOUpdateDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [int[]]$SuccessCodes = @(0, 3010),

        [switch]$AllowNotApplicable,

        [switch]$NoThrow,

        [switch]$Quiet
    )

    if (-not (Test-Path -LiteralPath $script:AIOUpdateDismPath -PathType Leaf)) {
        throw "No se encontro DISM en '$script:AIOUpdateDismPath'."
    }

    $safeContext = ($Context -replace '[^A-Za-z0-9_.-]', '_')
    if ($safeContext.Length -gt 70) { $safeContext = $safeContext.Substring(0, 70) }
    $dismLog = if ($script:AIOUpdateSessionRoot) {
        Join-Path $script:AIOUpdateSessionRoot ("DISM_{0}_{1}.log" -f (Get-Date -Format 'HHmmssfff'), $safeContext)
    }
    else {
        Join-Path $env:TEMP ("AIO_DISM_{0}.log" -f [guid]::NewGuid().ToString('N'))
    }

    $effectiveArguments = @('/English') + $Arguments
    $hasExplicitLogPath = (@($effectiveArguments | Where-Object { $_ -match '^/LogPath:' }).Count -gt 0)
    if (-not $hasExplicitLogPath) {
        $effectiveArguments += "/LogPath:$dismLog"
    }

    Write-AIOUpdateLog -Level ACTION -Message "$Context | dism.exe $($effectiveArguments -join ' ')"
    Add-AIOUpdateDismTranscriptLine -Line ("INICIO | {0} | dism.exe {1}" -f $Context, ($effectiveArguments -join ' '))

    if (-not $Quiet) {
        Write-Host "`n>> $Context" -ForegroundColor Cyan
    }

    $captured = New-Object System.Collections.Generic.List[string]
    $nativeArgumentLine = (@($effectiveArguments | ForEach-Object { ConvertTo-AIOUpdateNativeArgument -Argument ([string]$_) }) -join ' ')
    $process = $null

    try { 
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:AIOUpdateDismPath
        $startInfo.Arguments = $nativeArgumentLine
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false

        if ($Quiet) {
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.CreateNoWindow = $true
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw 'System.Diagnostics.Process.Start() devolvio False.'
        }

        $stdoutTask = $null
        $stderrTask = $null
        if ($Quiet) {
            # Lectura asincrona de ambos canales para evitar interbloqueos
            # si alguno llena su buffer antes de finalizar dism.exe.
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }

        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode

        if ($Quiet) {
            $quietBlocks = @()
            if ($stdoutTask) { $quietBlocks += [string]$stdoutTask.GetAwaiter().GetResult() }
            if ($stderrTask) { $quietBlocks += [string]$stderrTask.GetAwaiter().GetResult() }

            foreach ($block in $quietBlocks) {
                if ([string]::IsNullOrWhiteSpace($block)) { continue }
                foreach ($line in @($block -split "\r?\n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$captured.Add([string]$line)
                    Add-AIOUpdateDismTranscriptLine -Line ([string]$line)
                }
            }
        }
    }
    catch {
        $message = "No se pudo iniciar DISM para '$Context': $($_.Exception.Message)"
        Write-AIOUpdateLog -Level ERROR -Message $message
        Add-AIOUpdateDismTranscriptLine -Line ("ERROR | {0}" -f $message)
        if (-not $NoThrow) { throw $message }
        return [pscustomobject]@{
            Success       = $false
            State         = 'FailedToStart'
            ExitCode      = -1
            UnsignedCode  = [uint32]4294967295
            Output        = [string[]]($captured.ToArray())
            LogPath       = $dismLog
            Context       = $Context
        }
    }
    finally {
        if ($process) {
            try { $process.Dispose() } catch {}
        }
    }

    $unsigned = Convert-AIOUpdateExitCodeToUInt32 -ExitCode $exitCode
    $notApplicable = ($unsigned -eq [uint32]2148468766)
    $success = ($SuccessCodes -contains $exitCode) -or ($AllowNotApplicable -and $notApplicable)
    Add-AIOUpdateDismTranscriptLine -Line ("FIN | {0} | Codigo={1} | Hex=0x{2}" -f $Context, $exitCode, ('{0:X8}' -f $unsigned))

    if ($success) {
        $state = if ($notApplicable) { 'NotApplicable' } else { 'Success' }
        $level = if ($notApplicable) { 'WARN' } else { 'INFO' }
        Write-AIOUpdateLog -Level $level -Message "$Context finalizo con codigo $exitCode (0x$('{0:X8}' -f $unsigned))."
        return [pscustomobject]@{
            Success       = $true
            State         = $state
            ExitCode      = $exitCode
            UnsignedCode  = $unsigned
            Output        = [string[]]($captured.ToArray())
            LogPath       = $dismLog
            Context       = $Context
        }
    }

    $hexCode = '0x{0:X8}' -f $unsigned
    $description = Get-AIOUpdateExitCodeText -ExitCode $exitCode
    $message = "$Context fallo. Codigo DISM: $exitCode ($hexCode). $description"
    Write-AIOUpdateLog -Level ERROR -Message $message

    if (-not $NoThrow) { throw $message }

    return [pscustomobject]@{
        Success       = $false
        State         = 'Failed'
        ExitCode      = $exitCode
        UnsignedCode  = $unsigned
        Output        = [string[]]($captured.ToArray())
        LogPath       = $dismLog
        Context       = $Context
    }
}

function Assert-AIOUpdateNoMountedImages {
    [CmdletBinding()]
    param()

    try {
        $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object {
            $_.MountStatus -notin @('Invalid', 'NeedsRemount')
        })
        if ($mounted.Count -gt 0) {
            $paths = $mounted | ForEach-Object { $_.Path }
            throw "Hay imagenes montadas por DISM: $($paths -join ', '). Desmonta o descarta esos montajes antes de continuar."
        }
    }
    catch {
        if ($_.Exception.Message -like 'Hay imagenes montadas*') { throw }
        Write-AIOUpdateLog -Level WARN -Message "No se pudo consultar Get-WindowsImage -Mounted: $($_.Exception.Message)"
    }
}

function Test-AIOUpdateMediaWritable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MediaRoot
    )

    $probe = Join-Path $MediaRoot ('.aio_write_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($probe, 'test', [System.Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Get-AIOUpdateKbId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '(?i)KB\d{6,8}')
    if ($match.Success) { return $match.Value.ToUpperInvariant() }
    return $null
}

function Get-AIOUpdateVersionFromText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return [version]'0.0.0.0' }
    $matches = [regex]::Matches($Text, '(?<!\d)(\d{4,5})\.(\d+)\.(\d+)\.(\d+)(?!\d)')
    if ($matches.Count -gt 0) {
        try { return [version]$matches[$matches.Count - 1].Value }
        catch {}
    }
    return [version]'0.0.0.0'
}

function Get-AIOUpdatePackageVersionInfo {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$FileName,
        [AllowNull()] [string]$UpdateMumText
    )

    # Solo se aceptan versiones de Windows procedentes del update.mum principal
    # o de un nombre explicito build.revision (por ejemplo, SSU-26100.8737).
    # No se examinan todos los manifiestos secundarios: pueden contener versiones
    # de .NET, herramientas o componentes como 4.8.9335.0 / 10.0.1.0 que no
    # representan la familia de mantenimiento del paquete.
    $sources = @(
        [pscustomobject]@{ Name = 'update.mum'; Text = [string]$UpdateMumText },
        [pscustomobject]@{ Name = 'Nombre';     Text = [string]$FileName }
    )

    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace($source.Text)) { continue }
        $candidates = New-Object System.Collections.Generic.List[System.Version]

        foreach ($match in [regex]::Matches($source.Text, '(?<!\d)(\d+)\.(\d+)\.(\d{4,5})\.(\d+)(?!\d)')) {
            try {
                $candidate = [version]$match.Value
                $isWindowsVersion = (
                    ($candidate.Major -eq 10 -and $candidate.Minor -eq 0 -and $candidate.Build -ge 7600 -and $candidate.Build -le 99999) -or
                    ($candidate.Major -eq 6 -and $candidate.Minor -ge 0 -and $candidate.Minor -le 3 -and $candidate.Build -ge 7600)
                )
                if ($isWindowsVersion) { [void]$candidates.Add($candidate) }
            }
            catch {}
        }

        if ($candidates.Count -gt 0) {
            $selected = $candidates.ToArray() |
                Sort-Object @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Revision }; Descending = $true } |
                Select-Object -First 1
            return [pscustomobject]@{
                Version  = [version]$selected
                Build    = [int]$selected.Build
                Reliable = $true
                Source   = [string]$source.Name
            }
        }

        # Nombres de SSU/CAB extraidos suelen usar solamente build.revision.
        if ($source.Name -eq 'Nombre') {
            $shortMatches = [regex]::Matches($source.Text, '(?<!\d)(\d{4,5})\.(\d{1,6})(?!\d)')
            $shortCandidates = New-Object System.Collections.Generic.List[System.Version]
            foreach ($match in $shortMatches) {
                try {
                    $build = [int]$match.Groups[1].Value
                    $revision = [int]$match.Groups[2].Value
                    if ($build -ge 7600 -and $build -le 99999) {
                        [void]$shortCandidates.Add([version]("10.0.$build.$revision"))
                    }
                }
                catch {}
            }
            if ($shortCandidates.Count -gt 0) {
                $selected = $shortCandidates.ToArray() |
                    Sort-Object @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Revision }; Descending = $true } |
                    Select-Object -First 1
                return [pscustomobject]@{
                    Version  = [version]$selected
                    Build    = [int]$selected.Build
                    Reliable = $true
                    Source   = 'Nombre build.revision'
                }
            }
        }
    }

    return [pscustomobject]@{
        Version  = [version]'0.0.0.0'
        Build    = 0
        Reliable = $false
        Source   = 'No determinada'
    }
}

function Add-AIOUpdateServicingBuildRelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$First,
        [Parameter(Mandatory = $true)] [int]$Second
    )

    if ($First -lt 7600 -or $Second -lt 7600) { return }
    foreach ($build in @($First, $Second)) {
        if (-not $script:AIOUpdateServicingBuildRelations.ContainsKey($build)) {
            $script:AIOUpdateServicingBuildRelations[$build] = New-Object System.Collections.ArrayList
        }
    }
    if ($Second -notin @($script:AIOUpdateServicingBuildRelations[$First])) {
        [void]$script:AIOUpdateServicingBuildRelations[$First].Add($Second)
    }
    if ($First -notin @($script:AIOUpdateServicingBuildRelations[$Second])) {
        [void]$script:AIOUpdateServicingBuildRelations[$Second].Add($First)
    }
}

function Get-AIOUpdateEnablementTargetBuilds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package
    )

    $values = New-Object System.Collections.Generic.List[int]
    $probe = @(
        $Package.Name
        $Package.IdentityHints
        if ($Package.Metadata) { $Package.Metadata.UpdateMumIdentityNames }
        if ($Package.Metadata) { $Package.Metadata.UpdateMumPackageIdentifiers }
        if ($Package.Metadata) { $Package.Metadata.MetadataNames }
    ) -join "`n"

    # Identidades modernas incluyen el build objetivo, por ejemplo:
    # Microsoft-Windows-Ge-Client-Server-26200-Version-Enablement-Package.
    foreach ($match in [regex]::Matches($probe, '(?i)(?<!\d)(\d{5})(?!\d)(?=[^~\r\n]{0,80}(?:Version[-_ ]+)?Enablement[-_ ]+Package)')) {
        $build = [int]$match.Groups[1].Value
        if ($build -ge 7600 -and $build -le 99999) { [void]$values.Add($build) }
    }

    # Las identidades SV2MomentN representan una rama derivada base + N.
    $baseBuild = if ($Package.VersionReliable) { [int]$Package.VersionBuild } else { 0 }
    if ($baseBuild -ge 7600) {
        foreach ($match in [regex]::Matches($probe, '(?i)SV2Moment(\d+)Enablement[-_ ]+Package')) {
            $offset = [int]$match.Groups[1].Value
            if ($offset -gt 0 -and $offset -lt 100) { [void]$values.Add($baseBuild + $offset) }
        }
    }

    return [int[]]@($values.ToArray() | Sort-Object -Unique)
}

function Initialize-AIOUpdateServicingBuildRelations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    $script:AIOUpdateServicingBuildRelations = @{}
    foreach ($package in @($Inventory | Where-Object { $_.Category -eq 'Enablement' })) {
        $baseBuild = if ($package.VersionReliable) { [int]$package.VersionBuild } else { 0 }
        if ($baseBuild -lt 7600) { continue }
        foreach ($targetBuild in @(Get-AIOUpdateEnablementTargetBuilds -Package $package)) {
            Add-AIOUpdateServicingBuildRelation -First $baseBuild -Second $targetBuild
            Write-AIOUpdateLog -Level INFO -Message "Relacion de mantenimiento detectada dinamicamente: $baseBuild <-> $targetBuild ($($package.Name))."
        }
    }
}

function Get-AIOUpdateServicingBuildFamily {
    [CmdletBinding()]
    param([int]$Build)

    if ($Build -lt 7600 -or -not $script:AIOUpdateServicingBuildRelations.ContainsKey($Build)) {
        return $Build
    }

    $pending = New-Object System.Collections.ArrayList
    $visited = @{}
    [void]$pending.Add($Build)
    while ($pending.Count -gt 0) {
        $current = [int]$pending[0]
        $pending.RemoveAt(0)
        if ($visited.ContainsKey($current)) { continue }
        $visited[$current] = $true
        if ($script:AIOUpdateServicingBuildRelations.ContainsKey($current)) {
            foreach ($related in @($script:AIOUpdateServicingBuildRelations[$current])) {
                if (-not $visited.ContainsKey([int]$related)) { [void]$pending.Add([int]$related) }
            }
        }
    }

    return [int](($visited.Keys | ForEach-Object { [int]$_ } | Sort-Object | Select-Object -First 1))
}

function Test-AIOUpdateAuxiliaryPackageName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $leaf = [System.IO.Path]::GetFileName($Name)
    return (
        $leaf -match '(?i)AggregatedMetadata.*\.cab$' -or
        $leaf -match '(?i)^DesktopDeployment(?:_x86)?\.cab$' -or
        $leaf -match '(?i)CompDB.*\.cab$'
    )
}

function Get-AIOUpdateExplicitCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path.TrimEnd('\')
    $relative = $File.FullName.Substring($root.Length).TrimStart('\')
    $first = ($relative -split '[\\/]', 2)[0]

    switch -Regex ($first) {
        '^(?i)SSU$'        { return 'SSU' }
        '^(?i)LCU$'        { return 'LCU' }
        '^(?i)SafeOS$'     { return 'SafeOS' }
        '^(?i)SecureBoot$'  { return 'SecureBoot' }
        '^(?i)SetupDU$'    { return 'SetupDU' }
        '^(?i)ESU$'        { return 'ESU' }
        '^(?i)Enablement$' { return 'Enablement' }
        '^(?i)OS$'         { return 'OS' }
        '^(?i)DotNet$'     { return 'DotNet' }
        '^(?i)WinPE$'      { return 'WinPE' }
        '^(?i)Defender$'   { return 'Defender' }
        default            { return $null }
    }
}


function Get-AIOUpdateCbsManifestFacts {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$XmlText
    )

    $cacheKey = Get-AIOUpdateTextSha256 -Text ([string]$XmlText)
    if ($script:AIOUpdateCbsFactsCache.ContainsKey($cacheKey)) {
        $script:AIOUpdateOptimizationStats.CbsCacheHits++
        return $script:AIOUpdateCbsFactsCache[$cacheKey]
    }

    $own = New-Object System.Collections.Generic.List[string]
    $dependencies = New-Object System.Collections.Generic.List[string]
    $parents = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        $emptyResult = [pscustomobject]@{
            OwnIdentities = [string[]]@()
            Dependencies  = [string[]]@()
            Parents       = [string[]]@()
        }
        $script:AIOUpdateCbsFactsCache[$cacheKey] = $emptyResult
        return $emptyResult
    }

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.PreserveWhitespace = $false
        $document.LoadXml($XmlText)

        foreach ($node in @($document.SelectNodes("//*[local-name()='assemblyIdentity']"))) {
            $name = [string]$node.GetAttribute('name')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $name = $name.Trim()

            $ancestorNames = New-Object System.Collections.Generic.List[string]
            $ancestor = $node.ParentNode
            while ($ancestor) {
                if ($ancestor.LocalName) { [void]$ancestorNames.Add([string]$ancestor.LocalName) }
                $ancestor = $ancestor.ParentNode
            }

            if ($ancestorNames -contains 'parent') {
                [void]$parents.Add($name)
            }
            elseif ($ancestorNames -contains 'dependency' -or $ancestorNames -contains 'dependentAssembly') {
                [void]$dependencies.Add($name)
            }
            else {
                [void]$own.Add($name)
            }
        }

        foreach ($package in @($document.SelectNodes("//*[local-name()='package']"))) {
            $identifier = [string]$package.GetAttribute('identifier')
            if (-not [string]::IsNullOrWhiteSpace($identifier)) {
                [void]$own.Add($identifier.Trim())
            }
        }
    }
    catch {
        $matches = [regex]::Matches($XmlText, '(?is)<assemblyIdentity\b[^>]*\bname\s*=\s*"([^"]+)"')
        $first = $true
        foreach ($match in $matches) {
            $name = $match.Groups[1].Value.Trim()
            if (-not $name) { continue }
            if ($first) {
                [void]$own.Add($name)
                $first = $false
            }
            else {
                [void]$dependencies.Add($name)
            }
        }
    }

    $result = [pscustomobject]@{
        OwnIdentities = [string[]]@($own.ToArray() | Sort-Object -Unique)
        Dependencies  = [string[]]@($dependencies.ToArray() | Sort-Object -Unique)
        Parents       = [string[]]@($parents.ToArray() | Sort-Object -Unique)
    }
    $script:AIOUpdateCbsFactsCache[$cacheKey] = $result
    return $result
}

function Expand-AIOUpdatePackageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$ScratchRoot
    )

    $metadataRoot = Join-Path $ScratchRoot ('Meta_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    Initialize-AIOUpdateDirectory -Path $metadataRoot -Empty

    $text = New-Object System.Text.StringBuilder
    $updateMumText = New-Object System.Text.StringBuilder
    $listedNames = New-Object System.Collections.Generic.List[string]
    $identityNames = New-Object System.Collections.Generic.List[string]
    $packageIdentifiers = New-Object System.Collections.Generic.List[string]
    $updateMumIdentityNames = New-Object System.Collections.Generic.List[string]
    $updateMumPackageIdentifiers = New-Object System.Collections.Generic.List[string]
    $metadataNames = New-Object System.Collections.Generic.List[string]
    $cbsOwnIdentities = New-Object System.Collections.Generic.List[string]
    $cbsDependencies = New-Object System.Collections.Generic.List[string]
    $cbsParents = New-Object System.Collections.Generic.List[string]
    $hasMum = $false
    $hasManifest = $false
    $hasUpdateMum = $false

    try {
        if (-not (Test-Path -LiteralPath $script:AIOUpdateExpandPath -PathType Leaf)) {
            return [pscustomobject]@{
                Text                        = ''
                UpdateMumText               = ''
                Names                       = [string[]]@()
                IdentityNames               = [string[]]@()
                PackageIdentifiers          = [string[]]@()
                UpdateMumIdentityNames      = [string[]]@()
                UpdateMumPackageIdentifiers = [string[]]@()
                MetadataNames               = [string[]]@()
                CbsOwnIdentities             = [string[]]@()
                CbsDependencies              = [string[]]@()
                CbsParents                   = [string[]]@()
                Version                     = [version]'0.0.0.0'
                VersionBuild                = 0
                VersionReliable             = $false
                VersionSource               = 'No determinada'
                HasMum                      = $false
                HasManifest                 = $false
                HasUpdateMum                = $false
                HasEnablementMum            = $false
                HasBaseline                 = $false
            }
        }

        $containers = New-Object System.Collections.Generic.List[string]
        [void]$containers.Add($File.FullName)

        if ($File.Extension -ieq '.msu') {
            $innerRoot = Join-Path $metadataRoot 'Inner'
            Initialize-AIOUpdateDirectory -Path $innerRoot
            & $script:AIOUpdateExpandPath '-F:*.cab' $File.FullName $innerRoot *> $null
            foreach ($inner in @(Get-ChildItem -LiteralPath $innerRoot -Filter '*.cab' -File -ErrorAction SilentlyContinue)) {
                [void]$containers.Add($inner.FullName)
                [void]$listedNames.Add($inner.Name)
            }
        }

        $counter = 0
        foreach ($container in $containers) {
            $counter++
            $mumRoot = Join-Path $metadataRoot ("Mum_$counter")
            Initialize-AIOUpdateDirectory -Path $mumRoot

            # update.mum es la autoridad para distinguir paquetes CBS, SafeOS,
            # LCU y SetupDU. Se extrae expresamente para no perderlo entre los
            # cientos de manifiestos que puede contener una acumulativa.
            foreach ($pattern in @(
                'update.mum',
                '*enablement-package*.mum',
                '*_microsoft-windows-sysreset_*.manifest',
                '*_microsoft-windows-winpe_tools_*.manifest',
                '*_microsoft-windows-winre-tools_*.manifest',
                '*rejuvenation*.manifest',
                '*_microsoft-windows-servicingstack_*.manifest',
                '*_netfx4*.manifest',
                '*.mum',
                '*.manifest'
            )) {
                & $script:AIOUpdateExpandPath ("-F:$pattern") $container $mumRoot *> $null
            }

            $listOutput = & $script:AIOUpdateExpandPath '-D' $container 2>$null
            foreach ($line in @($listOutput)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                    [void]$listedNames.Add(([string]$line).Trim())
                }
            }

            # Se priorizan update.mum y los MUM de habilitacion. El limite solo
            # afecta metadatos secundarios; las identidades decisivas siempre
            # quedan incluidas.
            foreach ($meta in @(
                Get-ChildItem -LiteralPath $mumRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Sort-Object @{
                        Expression = {
                            if ($_.Name -ieq 'update.mum') { 0 }
                            elseif ($_.Name -match '(?i)enablement-package.*\.mum$') { 1 }
                            elseif ($_.Extension -ieq '.mum') { 2 }
                            elseif ($_.Name -match '(?i)(sysreset|winpe_tools|winre-tools|rejuvenation|servicingstack|netfx4)') { 3 }
                            else { 4 }
                        }
                    }, Name |
                    Select-Object -First 500
            )) {
                try {
                    [void]$metadataNames.Add($meta.Name)
                    if ($meta.Extension -ieq '.mum') { $hasMum = $true }
                    if ($meta.Extension -ieq '.manifest') { $hasManifest = $true }

                    $content = Get-Content -LiteralPath $meta.FullName -Raw -ErrorAction Stop
                    if ($content.Length -gt 1048576) { $content = $content.Substring(0, 1048576) }
                    [void]$text.AppendLine($content)

                    $isUpdateMum = ($meta.Name -ieq 'update.mum')
                    if ($isUpdateMum) {
                        $hasUpdateMum = $true
                        [void]$updateMumText.AppendLine($content)
                        $cbsFacts = Get-AIOUpdateCbsManifestFacts -XmlText $content
                        foreach ($value in @($cbsFacts.OwnIdentities)) { [void]$cbsOwnIdentities.Add([string]$value) }
                        foreach ($value in @($cbsFacts.Dependencies)) { [void]$cbsDependencies.Add([string]$value) }
                        foreach ($value in @($cbsFacts.Parents)) { [void]$cbsParents.Add([string]$value) }
                    }

                    foreach ($match in [regex]::Matches($content, '(?is)<assemblyIdentity\b[^>]*\bname\s*=\s*"([^"]+)"')) {
                        $value = $match.Groups[1].Value.Trim()
                        if ($value) {
                            [void]$identityNames.Add($value)
                            if ($isUpdateMum) { [void]$updateMumIdentityNames.Add($value) }
                        }
                    }

                    foreach ($match in [regex]::Matches($content, '(?is)<package\b[^>]*\bidentifier\s*=\s*"([^"]+)"')) {
                        $value = $match.Groups[1].Value.Trim()
                        if ($value) {
                            [void]$packageIdentifiers.Add($value)
                            if ($isUpdateMum) { [void]$updateMumPackageIdentifiers.Add($value) }
                        }
                    }
                }
                catch {}
            }
        }

        $combined = $text.ToString()
        $updateCombined = $updateMumText.ToString()
        $allNamesProbe = @(
            $listedNames.ToArray()
            $metadataNames.ToArray()
        ) -join "`n"
        $versionInfo = Get-AIOUpdatePackageVersionInfo -FileName $File.Name -UpdateMumText $updateCombined

        return [pscustomobject]@{
            Text                        = $combined
            UpdateMumText               = $updateCombined
            Names                       = [string[]]@($listedNames.ToArray() | Sort-Object -Unique)
            IdentityNames               = [string[]]@($identityNames.ToArray() | Sort-Object -Unique)
            PackageIdentifiers          = [string[]]@($packageIdentifiers.ToArray() | Sort-Object -Unique)
            UpdateMumIdentityNames      = [string[]]@($updateMumIdentityNames.ToArray() | Sort-Object -Unique)
            UpdateMumPackageIdentifiers = [string[]]@($updateMumPackageIdentifiers.ToArray() | Sort-Object -Unique)
            MetadataNames               = [string[]]@($metadataNames.ToArray() | Sort-Object -Unique)
            CbsOwnIdentities             = [string[]]@($cbsOwnIdentities.ToArray() | Sort-Object -Unique)
            CbsDependencies              = [string[]]@($cbsDependencies.ToArray() | Sort-Object -Unique)
            CbsParents                   = [string[]]@($cbsParents.ToArray() | Sort-Object -Unique)
            Version                     = [version]$versionInfo.Version
            VersionBuild                = [int]$versionInfo.Build
            VersionReliable             = [bool]$versionInfo.Reliable
            VersionSource               = [string]$versionInfo.Source
            HasMum                      = [bool]$hasMum
            HasManifest                 = [bool]$hasManifest
            HasUpdateMum                = [bool]$hasUpdateMum
            HasEnablementMum            = [bool]($allNamesProbe -match '(?i)enablement-package.*\.mum')
            HasBaseline                 = [bool](
                $combined -match '(?i)\b(?:Baseline|Checkpoint)\b' -or
                $allNamesProbe -match '(?i)(?:Baseline|Checkpoint)'
            )
        }
    }
    finally {
        Remove-Item -LiteralPath $metadataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-AIOUpdatePackageCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ScratchRoot
    )

    if (Test-AIOUpdateAuxiliaryPackageName -Name $File.Name) {
        return [pscustomobject]@{ Category = 'Auxiliary'; Reason = 'Archivo auxiliar de UUP/CompDB'; Metadata = $null }
    }

    # Las subcarpetas conservan el papel de anulacion manual. En una carpeta
    # plana, la clasificacion se basa primero en los metadatos del paquete.
    $explicit = Get-AIOUpdateExplicitCategory -File $File -RepositoryRoot $RepositoryRoot
    if ($explicit) {
        $metadata = $null
        if ($explicit -in @('SSU', 'LCU', 'SafeOS', 'SecureBoot', 'ESU', 'Enablement', 'OS', 'DotNet', 'WinPE')) {
            $metadata = Expand-AIOUpdatePackageMetadata -File $File -ScratchRoot $ScratchRoot
        }
        return [pscustomobject]@{ Category = $explicit; Reason = "Subcarpeta $explicit (anulacion manual)"; Metadata = $metadata }
    }

    $metadata = Expand-AIOUpdatePackageMetadata -File $File -ScratchRoot $ScratchRoot
    $identityProbe = @(
        $metadata.IdentityNames
        $metadata.PackageIdentifiers
        $metadata.MetadataNames
    ) -join "`n"
    $updateMumProbe = @(
        $metadata.UpdateMumIdentityNames
        $metadata.UpdateMumPackageIdentifiers
        $metadata.UpdateMumText
    ) -join "`n"
    $nameProbe = @(
        $metadata.Names
        $metadata.MetadataNames
    ) -join "`n"
    $contentProbe = @(
        $File.Name
        $nameProbe
        $identityProbe
        $metadata.Text
    ) -join "`n"

    # Las identidades especificas tienen prioridad sobre componentes secundarios
    # incluidos en el mismo contenedor.
    if ($metadata.HasEnablementMum -or
        $identityProbe -match '(?i)(?:Microsoft-Windows-[^\r\n]*Enablement(?:-Package)?|Enablement[-_. ]?Package|Package_for_(?:Feature_?)?Enablement|Feature[-_. ]?Update[-_. ]?Enablement)') {
        return [pscustomobject]@{ Category = 'Enablement'; Reason = 'MUM/identidad interna de paquete de habilitacion'; Metadata = $metadata }
    }

    $isRollup = ($updateMumProbe -match '(?i)Package_for_(?:RollupFix|RevisedFix)')
    $hasSafeOsManifest = ($nameProbe -match '(?i)(?:_microsoft-windows-(?:sysreset|winpe_tools|winre-tools)_|rejuvenation).*\.manifest')
    if ($updateMumProbe -match '(?i)Package_for_SafeOSDU|SafeOSDU' -or
        ($hasSafeOsManifest -and -not $isRollup)) {
        return [pscustomobject]@{ Category = 'SafeOS'; Reason = 'update.mum o manifiestos exclusivos de SafeOS/WinRE'; Metadata = $metadata }
    }

    if (($updateMumProbe -match '(?i)Package_for_DotNetRollup|DotNetRollup') -or
        (($nameProbe -match '(?i)_netfx4.*\.manifest') -and -not $isRollup) -or
        ($identityProbe -match '(?i)Microsoft-Windows-NetFx|NDP\d')) {
        return [pscustomobject]@{ Category = 'DotNet'; Reason = 'Identidad interna de .NET'; Metadata = $metadata }
    }

    if ($contentProbe -match '(?i)(?:ExtendedSecurityUpdates|ESU[-_. ]?(?:Licens|Preparation)|Licens[^\r\n]*ESU|Package_for_ESU)') {
        return [pscustomobject]@{ Category = 'ESU'; Reason = 'Identidad interna de preparacion/licenciamiento ESU'; Metadata = $metadata }
    }

    if (($nameProbe -match '(?i)_microsoft-windows-s.*boot-firmwareupdate_.*\.manifest') -and -not $isRollup) {
        return [pscustomobject]@{ Category = 'SecureBoot'; Reason = 'Manifiesto interno de actualizacion de firmware Secure Boot'; Metadata = $metadata }
    }

    if ($isRollup -or $updateMumProbe -match '(?i)LCUCompDB|PSFX|CumulativeUpdate') {
        return [pscustomobject]@{ Category = 'LCU'; Reason = 'update.mum de actualizacion acumulativa'; Metadata = $metadata }
    }

    if ($updateMumProbe -match '(?i)Package_for_ServicingStack|ServicingStack' -or
        $nameProbe -match '(?i)_microsoft-windows-servicingstack_.*\.manifest') {
        return [pscustomobject]@{ Category = 'SSU'; Reason = 'Identidad interna de pila de mantenimiento'; Metadata = $metadata }
    }

    if ($contentProbe -match '(?i)defender-dism|mpam-fe|mpam-d|Microsoft-Windows-Defender') {
        return [pscustomobject]@{ Category = 'Defender'; Reason = 'Contenido de Microsoft Defender'; Metadata = $metadata }
    }

    # WinPE se evalua despues de las familias mas especificas. Solo se acepta
    # cuando update.mum declara WinPE y no presenta una lista de ediciones OS.
    if ($updateMumProbe -match '(?i)WinPE' -and $updateMumProbe -notmatch '(?i)Edition\s*=|Edition"') {
        return [pscustomobject]@{ Category = 'WinPE'; Reason = 'update.mum especifico de WinPE'; Metadata = $metadata }
    }

    if (-not $metadata.HasMum -and $contentProbe -match '(?i)CompDB|AggregatedMetadata|DesktopDeployment') {
        return [pscustomobject]@{ Category = 'Auxiliary'; Reason = 'Metadatos auxiliares de UUP/CompDB'; Metadata = $metadata }
    }

    # Un solo bloque de respaldo por nombre cubre contenedores cuyos metadatos
    # estan encapsulados en WIM/PSF. Nunca tiene prioridad sobre CBS/update.mum.
    switch -Regex ($File.Name) {
        '(?i)NDP\d|DotNet|NetFx'                   { return [pscustomobject]@{ Category = 'DotNet'; Reason = 'Nombre de paquete .NET; metadatos internos no concluyentes'; Metadata = $metadata } }
        '(?i)SafeOS|SafeOSDU|WinRE.*Update'         { return [pscustomobject]@{ Category = 'SafeOS'; Reason = 'Nombre de paquete SafeOS/WinRE; metadatos internos no concluyentes'; Metadata = $metadata } }
        '(?i)^SSU[-_.]|Servicing[ _-]?Stack'        { return [pscustomobject]@{ Category = 'SSU'; Reason = 'Nombre de paquete de pila de mantenimiento'; Metadata = $metadata } }
        '(?i)Enablement|Feature.?Update'             { return [pscustomobject]@{ Category = 'Enablement'; Reason = 'Nombre de paquete de habilitacion'; Metadata = $metadata } }
        '(?i)defender-dism|mpam-fe|mpam-d'          { return [pscustomobject]@{ Category = 'Defender'; Reason = 'Nombre de paquete de Microsoft Defender'; Metadata = $metadata } }
        '(?i)SetupDU|Setup.*Dynamic|Dynamic.*Setup' { return [pscustomobject]@{ Category = 'SetupDU'; Reason = 'Nombre de Setup Dynamic Update'; Metadata = $metadata } }
        '(?i)SecureBoot|FirmwareUpdate|DBXUpdate'   { return [pscustomobject]@{ Category = 'SecureBoot'; Reason = 'Nombre de actualizacion Secure Boot'; Metadata = $metadata } }
    }

    # Los MSU acumulativos modernos pueden ocultar update.mum en WIM/PSF. Se
    # acepta como LCU unicamente el patron oficial de Windows + KB + arquitectura.
    if ($File.Extension -ieq '.msu') {
        if ($File.Name -match '(?i)^Windows(?:10|11)\.0-KB\d+-(?:x86|x64|arm64)\.msu$') {
            return [pscustomobject]@{ Category = 'LCU'; Reason = 'MSU de Windows con KB y arquitectura; sin evidencia de otra familia'; Metadata = $metadata }
        }
        return [pscustomobject]@{ Category = 'Unknown'; Reason = 'MSU sin metadatos ni nombre suficientes para clasificacion segura'; Metadata = $metadata }
    }

    # Un CAB sin update.mum solo se considera SetupDU cuando contiene varias
    # superficies caracteristicas de Windows Setup. La sola ausencia de MUM no
    # basta, porque tambien existen CAB de datos y auxiliares no instalables.
    if (-not $metadata.HasUpdateMum) {
        $setupProbe = @(
            $metadata.Names
            $metadata.MetadataNames
        ) -join "`n"
        $setupSignalCount = @(
            @(
                ($setupProbe -match '(?i)setupplatform\.(?:dll|exe)')
                ($setupProbe -match '(?i)setuphost\.exe')
                ($setupProbe -match '(?i)setupcore\.dll')
                ($setupProbe -match '(?i)setupmgr\.dll')
                ($setupProbe -match '(?i)(?:^|[\\/])sources[\\/](?:replacementmanifests|dlmanifests|compatresources|appraiser)')
            ) | Where-Object { $_ }
        ).Count
        if ($setupSignalCount -ge 2) {
            return [pscustomobject]@{ Category = 'SetupDU'; Reason = "CAB sin update.mum con $setupSignalCount evidencias de Windows Setup"; Metadata = $metadata }
        }
        return [pscustomobject]@{ Category = 'Unknown'; Reason = 'CAB sin update.mum y sin evidencias suficientes de SetupDU'; Metadata = $metadata }
    }

    if ($metadata.HasMum) {
        return [pscustomobject]@{ Category = 'OS'; Reason = 'Paquete CBS general de sistema operativo'; Metadata = $metadata }
    }

    return [pscustomobject]@{ Category = 'Unknown'; Reason = 'No se encontraron metadatos suficientes para clasificar el paquete'; Metadata = $metadata }
}


function Find-AIOUpdateWimlib {
    [CmdletBinding()]
    param()

    if ($script:AIOUpdateWimlibPath -and (Test-Path -LiteralPath $script:AIOUpdateWimlibPath -PathType Leaf)) {
        return $script:AIOUpdateWimlibPath
    }

    # Directorio compartido de herramientas de AdminImagenOffline:
    #   <AdminImagenOffline>\Tools\wimlib-imagex.exe
    $applicationRoot = Split-Path -Parent $PSScriptRoot
    $candidates = New-Object System.Collections.Generic.List[string]
    [void]$candidates.Add((Join-Path $applicationRoot 'Tools\wimlib-imagex.exe'))

    try {
        $command = Get-Command wimlib-imagex.exe -ErrorAction Stop
        if ($command.Source) { [void]$candidates.Add([string]$command.Source) }
    }
    catch {}

    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programRoot)) { continue }
        [void]$candidates.Add((Join-Path $programRoot 'wimlib\wimlib-imagex.exe'))
        [void]$candidates.Add((Join-Path $programRoot 'wimlib-imagex\wimlib-imagex.exe'))
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $script:AIOUpdateWimlibPath = (Resolve-Path -LiteralPath $candidate).Path
            return $script:AIOUpdateWimlibPath
        }
    }

    return $null
}

function Assert-AIOUpdateRepositorySupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot
    )

    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $psf = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.psf' -File -ErrorAction SilentlyContinue)
    $updateWims = @(
        Get-ChildItem -LiteralPath $root -Recurse -Filter '*.wim' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)Windows1.*KB|LCU|Cumulative' }
    )
    $metadata = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*AggregatedMetadata*.cab' -File -ErrorAction SilentlyContinue)
    $completeMsu = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.msu' -File -ErrorAction SilentlyContinue)

    if (($psf.Count -gt 0 -or $updateWims.Count -gt 0) -and $metadata.Count -gt 0 -and $completeMsu.Count -eq 0) {
        $message = @"
Se detecto un repositorio UUP dividido (WIM/PSF/CompDB) sin un MSU reconstruido.
Este modulo no intenta aplicar esos fragmentos directamente porque produciria
una imagen incompleta. Reconstruye primero la LCU como MSU con W10UI o coloca
el MSU completo en el repositorio.
"@
        throw $message.Trim()
    }
}

function Get-AIOUpdatePackageArchitectureHints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$File,
        [AllowNull()] [psobject]$Metadata
    )

    $probe = $File.Name
    if ($Metadata) {
        $probe += "`n" + [string]$Metadata.UpdateMumText + "`n" + [string]$Metadata.Text
    }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($probe, '(?i)processorArchitecture\s*=\s*"([^"]+)"')) {
        $raw = $match.Groups[1].Value
        $value = if ($raw -match '(?i)^wow64$') { 'x64' } else { Convert-AIOUpdateArchitectureName -Architecture $raw }
        if ($value -and $value -notin @('Unknown', 'neutral', 'msil')) { [void]$values.Add($value) }
    }

    foreach ($match in [regex]::Matches($File.Name, '(?i)(?:^|[-_.])(amd64|x64|x86|arm64|arm)(?:[-_.]|$)')) {
        $value = Convert-AIOUpdateArchitectureName -Architecture $match.Groups[1].Value
        if ($value -and $value -ne 'Unknown') { [void]$values.Add($value) }
    }

    return [string[]]@($values.ToArray() | Sort-Object -Unique)
}

function Get-AIOUpdatePackageEditionHints {
    [CmdletBinding()]
    param(
        [AllowNull()] [psobject]$Metadata
    )

    if (-not $Metadata) { return @() }
    $probe = [string]$Metadata.UpdateMumText
    if ([string]::IsNullOrWhiteSpace($probe)) { return @() }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($probe, '(?i)\bEdition(?:ID)?\s*=\s*"([^"]*)"')) {
        $raw = $match.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $value = ($raw -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($value -and $value -notin @('all', 'any', 'neutral', 'client', 'windows')) {
            [void]$values.Add($value)
        }
    }
    foreach ($match in [regex]::Matches($probe, '(?i)Microsoft-Windows-([A-Za-z0-9-]+)Edition(?:Pack|~|\b)')) {
        $value = ($match.Groups[1].Value -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($value -and $value -notin @('client', 'server', 'windows')) {
            [void]$values.Add($value)
        }
    }

    return [string[]]@($values.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Get-AIOUpdateImageEditionHints {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$ImageName
    )

    if ([string]::IsNullOrWhiteSpace($ImageName)) { return @() }
    $name = $ImageName.ToLowerInvariant()
    $values = New-Object System.Collections.Generic.List[string]

    if ($name -match 'home single language') { foreach ($v in @('coresinglelanguage','home','core')) { [void]$values.Add($v) } }
    elseif ($name -match 'home n') { foreach ($v in @('coren','homen')) { [void]$values.Add($v) } }
    elseif ($name -match 'home') { foreach ($v in @('core','home')) { [void]$values.Add($v) } }

    if ($name -match 'pro for workstations') { foreach ($v in @('professionalworkstation','professionalworkstations','proworkstation')) { [void]$values.Add($v) } }
    elseif ($name -match 'pro education') { foreach ($v in @('professionaleducation','proeducation')) { [void]$values.Add($v) } }
    elseif ($name -match 'pro n') { foreach ($v in @('professionaln','pron')) { [void]$values.Add($v) } }
    elseif ($name -match '\bpro\b') { foreach ($v in @('professional','pro')) { [void]$values.Add($v) } }

    if ($name -match 'enterprise') { [void]$values.Add('enterprise') }
    if ($name -match 'education') { [void]$values.Add('education') }
    if ($name -match 'server') { [void]$values.Add('server') }

    return [string[]]@($values.ToArray() | Sort-Object -Unique)
}

function Get-AIOUpdatePackageProductHint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$File,
        [AllowNull()] [psobject]$Metadata,
        [AllowNull()] [string]$Category
    )

    # El nombre externo es una pista mas fiable para la familia de Windows que
    # los cientos de dependencias internas. Paquetes cliente pueden contener
    # componentes compartidos con "Server" y no deben marcarse como Server-only.
    if ($File.Name -match '(?i)Windows10\.0') { return 'Windows10' }
    if ($File.Name -match '(?i)Windows11\.0') { return 'Windows11' }
    if ($File.Name -match '(?i)(?:WindowsServer|Server20\d{2}|AzureStackHCI)') { return 'Server' }

    # Las familias amplias usan reglas CBS de aplicabilidad. No se intenta
    # deducir Client/Server a partir de identidades secundarias incluidas en el
    # paquete, porque eso produce falsos positivos en LCU, .NET, SafeOS y EP.
    if ($Category -in @('SSU','LCU','SafeOS','SecureBoot','SetupDU','ESU','Enablement','DotNet','WinPE','Defender')) {
        return 'Any'
    }

    if ($Metadata) {
        $topLevel = @(
            $Metadata.UpdateMumPackageIdentifiers
            $Metadata.UpdateMumIdentityNames
        ) -join "`n"
        $serverSpecific = ($topLevel -match '(?i)Microsoft-Windows-(?:ServerCore|NanoServer|ServerDatacenter|ServerStandard).*Edition')
        $clientSpecific = ($topLevel -match '(?i)Microsoft-Windows-(?:Core|Professional|Enterprise|Education).*Edition')
        if ($serverSpecific -and -not $clientSpecific) { return 'Server' }
    }

    return 'Any'
}

function Test-AIOUpdatePackageCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [AllowNull()] [string]$ImageName
    )

    if ($Package.Auxiliary) {
        return [pscustomobject]@{ Compatible = $false; Reason = 'Archivo auxiliar' }
    }
    if ($Package.PSObject.Properties['Installable'] -and -not [bool]$Package.Installable) {
        return [pscustomobject]@{ Compatible = $false; Reason = "Paquete no instalable: $($Package.Reason)" }
    }

    $targetArch = Convert-AIOUpdateArchitectureName -Architecture $Architecture
    $hints = @($Package.Architectures)
    if ($hints.Count -gt 0 -and $targetArch -notin $hints) {
        return [pscustomobject]@{
            Compatible = $false
            Reason = "Arquitectura del paquete: $($hints -join ', '); destino: $targetArch"
        }
    }

    $product = [string]$Package.ProductHint
    if ($product -eq 'Windows10' -and $Build -ge 22000) {
        return [pscustomobject]@{ Compatible = $false; Reason = "Paquete Windows 10 para una imagen build $Build" }
    }
    if ($product -eq 'Windows11' -and $Build -lt 22000) {
        return [pscustomobject]@{ Compatible = $false; Reason = "Paquete Windows 11 para una imagen build $Build" }
    }
    if ($product -eq 'Server' -and $ImageName -and $ImageName -notmatch '(?i)Server|Azure Stack HCI') {
        return [pscustomobject]@{ Compatible = $false; Reason = 'Paquete orientado a Windows Server' }
    }

    $editionHints = @(
        $Package.Editions |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )

    # deja que CBS evalúe la aplicabilidad de las familias generales.
    # Los atributos Edition de LCU, SafeOS, SetupDU, Enablement y .NET suelen
    # describir relaciones internas, no una exclusividad real de edición.
    # Solo los paquetes OS expresamente orientados a una edición se filtran aquí.
    if ($Package.Category -eq 'OS' -and $editionHints.Count -gt 0 -and $editionHints.Count -le 8 -and $ImageName) {
        $targetEditions = @(Get-AIOUpdateImageEditionHints -ImageName $ImageName)
        if ($targetEditions.Count -gt 0 -and @($editionHints | Where-Object { $_ -in $targetEditions }).Count -eq 0) {
            return [pscustomobject]@{
                Compatible = $false
                Reason = "Edicion no aplicable: paquete $($editionHints -join ', '); imagen $ImageName"
            }
        }
    }

    # El build no se usa como bloqueo previo. Las ramas visibles pueden cambiar
    # mediante Enablement mientras la base CBS permanece en otra build. Mantener
    # una tabla de equivalencias obliga a modificar el modulo en cada version.
    # Arquitectura y producto se validan aqui; CBS/DISM decide la aplicabilidad
    # exacta y devuelve NotApplicable sin modificar la imagen cuando corresponde.
    # Las relaciones dinamicas de Enablement se conservan para verificar la
    # version final, pero nunca para descartar preventivamente un paquete valido.

    return [pscustomobject]@{ Compatible = $true; Reason = 'Compatible' }
}

function Get-AIOUpdateCompatiblePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string[]]$Category,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [AllowNull()] [string]$ImageName,
        [switch]$Quiet
    )

    $compatible = New-Object System.Collections.Generic.List[object]
    foreach ($package in @(Get-AIOUpdatePackages -Inventory $Inventory -Category $Category)) {
        $test = Test-AIOUpdatePackageCompatibility -Package $package -Architecture $Architecture -Build $Build -ImageName $ImageName
        if ($test.Compatible) {
            [void]$compatible.Add($package)
        }
        elseif (-not $Quiet) {
            Write-Host "   [INCOMPATIBLE] $($package.Name): $($test.Reason)" -ForegroundColor DarkYellow
            Write-AIOUpdateLog -Level WARN -Message "Paquete omitido por incompatibilidad: $($package.Name). $($test.Reason)"
        }
    }

    return [object[]]($compatible.ToArray())
}

function Test-AIOUpdatePackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    if (@($InstalledInventory).Count -eq 0) { return $false }
    $inventoryKeyLines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($InstalledInventory)) {
        if ([string]$entry.PackageState -match '(?i)Installed|Superseded|InstallPending') { [void]$inventoryKeyLines.Add(([string]$entry.PackageName).ToLowerInvariant()) }
    }
    $inventoryKey = Get-AIOUpdateTextSha256 -Text ((@($inventoryKeyLines | Sort-Object) -join "`n") + "`n")
    if ($script:AIOUpdateInstalledNameCache.ContainsKey($inventoryKey)) {
        $installedNames = [string[]]$script:AIOUpdateInstalledNameCache[$inventoryKey]
    }
    else {
        $installedNames = [string[]]@($inventoryKeyLines.ToArray())
        $script:AIOUpdateInstalledNameCache[$inventoryKey] = $installedNames
    }
    $packageVersion = [version]$Package.Version

    if ($Package.KB) {
        foreach ($name in @($installedNames | Where-Object { $_ -match [regex]::Escape([string]$Package.KB) })) {
            $installedVersion = Get-AIOUpdateVersionFromText -Text $name
            if ($packageVersion -eq [version]'0.0.0.0' -or
                $installedVersion -eq [version]'0.0.0.0' -or
                $installedVersion -ge $packageVersion) {
                return $true
            }
        }
    }

    foreach ($hint in @($Package.IdentityHints)) {
        $hintText = [string]$hint
        if ([string]::IsNullOrWhiteSpace($hintText) -or $hintText.Length -lt 8) { continue }
        # Se evitan identidades genericas como Package_for_RollupFix, porque
        # coincidirian con cualquier LCU anterior. Solo se usan pistas que
        # incluyan KB o una version/identidad completa.
        if ($hintText -notmatch '(?i)KB\d{6,8}|~.*\d{4,5}\.\d+|\d{4,5}\.\d+\.\d+\.\d+') { continue }

        foreach ($name in @($installedNames | Where-Object { $_ -match [regex]::Escape($hintText) })) {
            $installedVersion = Get-AIOUpdateVersionFromText -Text $name
            if ($packageVersion -eq [version]'0.0.0.0' -or
                $installedVersion -eq [version]'0.0.0.0' -or
                $installedVersion -ge $packageVersion) {
                return $true
            }
        }
    }

    return $false
}


function Copy-AIOUpdateDirectoryWithBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourceRoot,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot,
        [string[]]$ExcludePatterns = @(),
        [switch]$OnlyExisting,
        [switch]$OnlyIfNewer,
        [ValidateSet('Sources', 'Boot', 'EfiBoot')]
        [string]$LocaleSurface
    )

    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        return @()
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($SourceRoot.Length).TrimStart('\')
        if ($LocaleSurface -and -not (Test-AIOUpdateLocaleRelativePathAllowed -RelativePath $relative -Surface $LocaleSurface)) {
            Write-AIOUpdateLog -Level INFO -Message "Se omitio recurso de idioma no presente en Preflight: $LocaleSurface\$relative"
            continue
        }
        $skip = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($relative -match $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }

        $destination = Join-Path $DestinationRoot $relative
        if ($OnlyExisting -and -not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }

        $copyArgs = @{
            Source      = $file.FullName
            Destination = $destination
        }
        if ($OnlyIfNewer) { $copyArgs.OnlyIfNewer = $true }
        $result = Copy-AIOUpdateFileWithBackup @copyArgs
        if ($result) { [void]$results.Add($result) }
    }

    return [object[]]($results.ToArray())
}

function Merge-AIOUpdateSetupDUIntoDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ExtractRoot,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $ExtractRoot -PathType Container)) { return 0 }
    Initialize-AIOUpdateDirectory -Path $DestinationRoot
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($ExtractRoot.Length).TrimStart('\')
        if ($relative -match '^(?i)sources[\\/](.+)$') { $relative = $Matches[1] }
        if ($relative -match '(?i)(?:^|[\\/])(update\.mum|update\.cat|WSUSSCAN\.cab)$') { continue }
        if (-not (Test-AIOUpdateLocaleRelativePathAllowed -RelativePath $relative -Surface Sources)) {
            Write-AIOUpdateLog -Level INFO -Message "SetupDU/boot.wim: se omitio idioma ausente del Preflight: $relative"
            continue
        }
        $destination = Join-Path $DestinationRoot $relative
        Initialize-AIOUpdateDirectory -Path (Split-Path -Parent $destination)
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
        $count++
    }
    return $count
}

function Remove-AIOUpdateWinPERejuv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [int]$Build,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    if ($Build -lt 26052) { return @() }
    $packages = @(
        $InstalledInventory |
            Where-Object {
                $_.PackageName -match '(?i)WinPE-Rejuv-Package' -and
                $_.PackageState -match '(?i)^Installed$|^Install ?Pending$|^Staged$|^Partially ?Installed$'
            } |
            Select-Object -ExpandProperty PackageName -Unique
    )
    if ($packages.Count -eq 0) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($packageName in $packages) {
        Write-Host "   [WINPE] Retirando $packageName antes de la LCU..." -ForegroundColor DarkYellow
        $result = Invoke-AIOUpdateDism -Arguments @(
            "/Image:$MountPath",
            '/Remove-Package',
            "/PackageName:$packageName",
            "/ScratchDir:$ScratchPath"
        ) -Context "Boot: retirando WinPE-Rejuv" -AllowNotApplicable

        $postRemovalInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $MountPath -Strict)
        $exactEntries = @(
            $postRemovalInventory |
                Where-Object { [string]$_.PackageName -ieq $packageName }
        )
        $states = @(
            $exactEntries |
                ForEach-Object { [string]$_.PackageState } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $blockingStates = @(
            $exactEntries |
                Where-Object {
                    [string]$_.PackageState -match '(?i)^Installed$|^Install ?Pending$|^Staged$|^Partially ?Installed$'
                }
        )
        $removalVerified = ($blockingStates.Count -eq 0)
        $stateText = if ($states.Count -eq 0) { 'Ausente' } else { $states -join ', ' }

        $isNeutralRejuv = ($packageName -match '(?i)~(?:amd64|x86|arm64|arm)~~')
        $advisoryOnly = (-not $removalVerified -and $isNeutralRejuv)

        if ($removalVerified) {
            Write-Host "      [VERIFICADO] Estado inmediato posterior: $stateText" -ForegroundColor DarkGray
        }
        elseif ($advisoryOnly) {
            Write-Host "      [PENDIENTE] CBS aun informa '$stateText'; se confirmara despues de la LCU y la limpieza." -ForegroundColor DarkYellow
            Write-Host '      [INFORMATIVO] Es el componente neutro de Rejuv; no bloqueara el mantenimiento si CBS lo conserva o restablece.' -ForegroundColor DarkGray
        }
        else {
            Write-Host "      [AVISO] La identidad localizada sigue activa: $stateText" -ForegroundColor Yellow
        }

        [void]$results.Add([pscustomobject]@{
            Package = [pscustomobject]@{
                Name                    = $packageName
                Category                = 'WinPE-Rejuv'
                RemovalVerified         = $removalVerified
                RemovalState            = $stateText
                RemovalCheckedBeforeLcu = $true
                IsNeutralRejuv          = $isNeutralRejuv
                AdvisoryOnly            = $advisoryOnly
            }
            Result  = $result
        })
    }
    return [object[]]($results.ToArray())
}

function Test-AIOUpdateDirectoryHashMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourceRoot,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot,
        [string[]]$ExcludeNames = @()
    )

    $verified = 0
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction Stop)) {
        if ($sourceFile.Name -in $ExcludeNames) { continue }
        $relative = $sourceFile.FullName.Substring($SourceRoot.Length).TrimStart('\')
        $destination = Join-Path $DestinationRoot $relative
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "Falta el archivo copiado '$destination'."
        }
        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "El archivo '$destination' no coincide por SHA-256."
        }
        $verified++
    }
    return $verified
}

function Apply-AIOUpdateDefenderPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot,
        [Parameter(Mandatory = $true)] [string]$DismScratch,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    if (@($Packages).Count -eq 0) { return @() }
    $results = New-Object System.Collections.Generic.List[object]
    $defenderRoot = Join-Path $MountPath 'ProgramData\Microsoft\Windows Defender'

    foreach ($package in $Packages) {
        $extractRoot = Join-Path $ScratchRoot ('Defender_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOUpdateDirectory -Path $extractRoot -Empty
        try {
            $verifiedFiles = 0
            & $script:AIOUpdateExpandPath '-R' '-F:*' $package.FullName $extractRoot *> $null
            $definitions = @(
                Get-ChildItem -LiteralPath $extractRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match '(?i)Definition Updates[\\/]Updates$' } |
                    Select-Object -First 1
            )
            $platform = @(
                Get-ChildItem -LiteralPath $extractRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'Platform' -and @(Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue).Count -gt 0 } |
                    Select-Object -First 1
            )

            if ($definitions.Count -eq 0 -and $platform.Count -eq 0) {
                foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $MountPath -Packages @($package) -ScratchPath $DismScratch -Context 'Install: Defender CBS' -AllowNotApplicable -InstalledInventory $InstalledInventory)) {
                    [void]$results.Add($entry)
                }
                continue
            }

            if ($definitions.Count -gt 0) {
                $destination = Join-Path $defenderRoot 'Definition Updates\Updates'
                Initialize-AIOUpdateDirectory -Path $destination
                Copy-Item -Path (Join-Path $definitions[0].FullName '*') -Destination $destination -Recurse -Force -ErrorAction Stop
                Remove-Item -LiteralPath (Join-Path $destination 'MpSigStub.exe') -Force -ErrorAction SilentlyContinue
                $verifiedFiles += Test-AIOUpdateDirectoryHashMirror -SourceRoot $definitions[0].FullName -DestinationRoot $destination -ExcludeNames @('MpSigStub.exe')
            }

            if ($platform.Count -gt 0) {
                $destination = Join-Path $defenderRoot 'Platform'
                Initialize-AIOUpdateDirectory -Path $destination
                Copy-Item -Path (Join-Path $platform[0].FullName '*') -Destination $destination -Recurse -Force -ErrorAction Stop
                Get-ChildItem -LiteralPath $destination -Recurse -Filter 'MpSigStub.exe' -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $verifiedFiles += Test-AIOUpdateDirectoryHashMirror -SourceRoot $platform[0].FullName -DestinationRoot $destination -ExcludeNames @('MpSigStub.exe')
            }

            $result = [pscustomobject]@{
                Success      = $true
                State        = 'Success'
                ExitCode     = 0
                UnsignedCode = [uint32]0
                Context      = "Defender - $($package.Name)"
                VerifiedFiles = [int]$verifiedFiles
            }
            [void]$results.Add([pscustomobject]@{ Package = $package; Result = $result })
            Write-AIOUpdateLog -Level INFO -Message "Defender actualizado mediante copia de plataforma/firmas: $($package.Name)"
        }
        finally {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [object[]]($results.ToArray())
}

function Save-AIOUpdateBootDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$RelativePath,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [hashtable]$CaptureTable
    )

    $source = Join-Path $MountPath $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { return }
    $destination = Join-Path $CaptureRoot $Key
    Initialize-AIOUpdateDirectory -Path $destination -Empty
    Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force -ErrorAction Stop
    $CaptureTable[$Key] = $destination
}

function Rebuild-AIOUpdateWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [switch]$Bootable
    )

    $images = @(Get-AIOUpdateImageMetadata -ImagePath $WimPath | Sort-Object ImageIndex)
    if ($images.Count -eq 0) { throw "No hay indices para reconstruir '$WimPath'." }

    $leaf = [System.IO.Path]::GetFileName($WimPath)
    $temp = Join-Path $StagingRoot ($leaf + '.rebuild.wim')
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    foreach ($image in $images) {
        $arguments = @(
            '/Export-Image',
            "/SourceImageFile:$WimPath",
            "/SourceIndex:$($image.ImageIndex)",
            "/DestinationImageFile:$temp",
            '/Compress:max',
            '/CheckIntegrity',
            "/ScratchDir:$ScratchPath"
        )
        [void](Invoke-AIOUpdateDism -Arguments $arguments -Context "Reconstruyendo $leaf indice $($image.ImageIndex)")
    }

    $rebuilt = @(Get-AIOUpdateImageMetadata -ImagePath $temp | Sort-Object ImageIndex)
    if ($rebuilt.Count -ne $images.Count) {
        throw "La reconstruccion de '$leaf' cambio el numero de indices."
    }

    $preflightPath = Get-AIOUpdatePreflightBackupPath -Destination $WimPath
    if (-not $preflightPath) {
        throw "No se encontro la copia Preflight de '$leaf'; no se reemplazara el WIM original."
    }

    $expectedCount = $images.Count
    $verifier = {
        param($candidate)
        $verifiedImages = @(Get-AIOUpdateImageMetadata -ImagePath $candidate | Sort-Object ImageIndex)
        if ($verifiedImages.Count -ne $expectedCount) {
            throw "La verificacion posterior de '$leaf' devolvio $($verifiedImages.Count) indices; se esperaban $expectedCount."
        }
    }.GetNewClosure()

    [void](Invoke-AIOUpdateAtomicReplacement -Source $temp -Destination $WimPath -Context "Reemplazando $leaf reconstruido" -MoveSource -Verifier $verifier)
    Write-AIOUpdateLog -Level INFO -Message "$leaf reconstruido y optimizado. Restauracion maestra: $preflightPath"

    return [pscustomobject]@{
        Applied       = $true
        WimPath       = $WimPath
        BackupPath    = $preflightPath
        BackupType    = 'Preflight'
        ImageCount    = $rebuilt.Count
        DuplicateCopy = $false
    }
}

function Set-AIOUpdateWimCreationTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot
    )

    $wimlib = Find-AIOUpdateWimlib
    if (-not $wimlib) {
        throw 'No se encontro wimlib-imagex.exe. Copialo en AdminImagenOffline\Tools o agregalo al PATH del sistema para modificar la fecha interna del WIM.'
    }

    $xmlPath = Join-Path $ScratchRoot ([System.IO.Path]::GetFileName($WimPath) + '.xml')
    $verifyPath = Join-Path $ScratchRoot ([System.IO.Path]::GetFileName($WimPath) + '.verify.xml')
    Remove-Item -LiteralPath $xmlPath, $verifyPath -Force -ErrorAction SilentlyContinue

    & $wimlib info $WimPath --extract-xml $xmlPath *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
        throw "wimlib no pudo extraer los metadatos de '$WimPath'."
    }

    [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
    $expected = @{}
    foreach ($image in @($xml.WIM.IMAGE)) {
        $index = [int]$image.INDEX
        $high = [string]$image.LASTMODIFICATIONTIME.HIGHPART
        $low = [string]$image.LASTMODIFICATIONTIME.LOWPART
        if ([string]::IsNullOrWhiteSpace($high) -or [string]::IsNullOrWhiteSpace($low)) { continue }

        & $wimlib info $WimPath $index `
            --image-property "CREATIONTIME/HIGHPART=$high" `
            --image-property "CREATIONTIME/LOWPART=$low" *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "wimlib no pudo modificar CREATIONTIME del indice $index en '$WimPath'."
        }
        $expected[$index] = "$high|$low"
    }

    & $wimlib info $WimPath --extract-xml $verifyPath *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $verifyPath -PathType Leaf)) {
        throw "No se pudo verificar CREATIONTIME en '$WimPath'."
    }

    [xml]$verifyXml = Get-Content -LiteralPath $verifyPath -Raw -ErrorAction Stop
    foreach ($image in @($verifyXml.WIM.IMAGE)) {
        $index = [int]$image.INDEX
        if (-not $expected.ContainsKey($index)) { continue }
        $actual = "$([string]$image.CREATIONTIME.HIGHPART)|$([string]$image.CREATIONTIME.LOWPART)"
        if ($actual -ne $expected[$index]) {
            throw "CREATIONTIME no coincide con LASTMODIFICATIONTIME en el indice $index de '$WimPath'."
        }
    }

    $file = Get-Item -LiteralPath $WimPath -ErrorAction Stop
    $file.CreationTimeUtc = $file.LastWriteTimeUtc
    Remove-Item -LiteralPath $xmlPath, $verifyPath -Force -ErrorAction SilentlyContinue
    Write-AIOUpdateLog -Level INFO -Message "Fecha CREATIONTIME igualada a LASTMODIFICATIONTIME en '$WimPath'."
    return $true
}


function Get-AIOUpdatePackageInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $files = @(Get-AIOUpdateRepositoryPackageFiles -RepositoryRoot $resolvedRoot)
    $signatureLines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) { [void]$signatureLines.Add(('{0}|{1}|{2}' -f $file.FullName.ToLowerInvariant(), [int64]$file.Length, [int64]$file.LastWriteTimeUtc.Ticks)) }
    $inventoryCacheKey = Get-AIOUpdateTextSha256 -Text (($signatureLines -join "`n") + "`n")
    if ($script:AIOUpdateRepositoryInventoryCache.ContainsKey($inventoryCacheKey)) {
        $script:AIOUpdateOptimizationStats.RepositoryCacheHits++
        return [object[]]$script:AIOUpdateRepositoryInventoryCache[$inventoryCacheKey]
    }

    $inventory = New-Object System.Collections.Generic.List[object]
    $position = 0
    foreach ($file in $files) {
        $position++
        Write-Progress -Activity 'Clasificando actualizaciones' -Status "$position de $($files.Count): $($file.Name)" -PercentComplete ([int](($position * 100) / [math]::Max(1, $files.Count)))
        $classification = Get-AIOUpdatePackageCategory -File $file -RepositoryRoot $resolvedRoot -ScratchRoot $ScratchRoot
        $metadata = $classification.Metadata
        $versionInfo = if ($metadata) {
            [pscustomobject]@{
                Version  = [version]$metadata.Version
                Build    = [int]$metadata.VersionBuild
                Reliable = [bool]$metadata.VersionReliable
                Source   = [string]$metadata.VersionSource
            }
        }
        else {
            Get-AIOUpdatePackageVersionInfo -FileName $file.Name -UpdateMumText $null
        }
        $version = [version]$versionInfo.Version
        $isCheckpoint = $false
        if ($classification.Category -eq 'LCU' -and $file.Extension -ieq '.msu' -and $metadata) {
            $checkpointProbe = @(
                $metadata.IdentityNames
                $metadata.PackageIdentifiers
                $metadata.MetadataNames
                $metadata.Names
                $metadata.Text
            ) -join "`n"
            $isCheckpoint = (
                $metadata.HasBaseline -or
                $checkpointProbe -match '(?i)(?:Checkpoint|Baseline)(?:[-_. ]?(?:LCU|Cumulative|Package|Update))?'
            )
        }

        $identityHints = @()
        if ($metadata) {
            $identityHints = @(
                $metadata.UpdateMumPackageIdentifiers
                $metadata.PackageIdentifiers
                $metadata.UpdateMumIdentityNames
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique
        }

        [void]$inventory.Add([pscustomobject]@{
            File          = $file
            FullName      = $file.FullName
            Name          = $file.Name
            Extension     = $file.Extension.ToLowerInvariant()
            Category      = $classification.Category
            Reason        = $classification.Reason
            KB            = Get-AIOUpdateKbId -Text $file.Name
            Version       = $version
            VersionBuild  = [int]$versionInfo.Build
            VersionReliable = [bool]$versionInfo.Reliable
            VersionSource = [string]$versionInfo.Source
            Size          = [long]$file.Length
            Auxiliary     = ($classification.Category -eq 'Auxiliary')
            Installable   = ($classification.Category -notin @('Auxiliary', 'Unknown'))
            IsCheckpoint  = [bool]$isCheckpoint
            Metadata      = $metadata
            Architectures = [string[]](Get-AIOUpdatePackageArchitectureHints -File $file -Metadata $metadata)
            Editions      = [string[]](Get-AIOUpdatePackageEditionHints -Metadata $metadata)
            ProductHint   = Get-AIOUpdatePackageProductHint -File $file -Metadata $metadata -Category $classification.Category
            IdentityHints = [string[]]$identityHints
        })
    }

    $lcuMsu = @(
        $inventory.ToArray() |
            Where-Object { $_.Category -eq 'LCU' -and $_.Extension -eq '.msu' } |
            Sort-Object Version, Size, Name
    )
    if ($lcuMsu.Count -gt 1) {
        $withVersion = @($lcuMsu | Where-Object { $_.Version -gt [version]'0.0.0.0' })
        $target = if ($withVersion.Count -gt 0) {
            $withVersion |
                Sort-Object @{ Expression = { $_.Version }; Descending = $true }, @{ Expression = { $_.Size }; Descending = $true } |
                Select-Object -First 1
        }
        else {
            $lcuMsu |
                Sort-Object @{ Expression = { $_.Size }; Descending = $true }, Name |
                Select-Object -First 1
        }

        foreach ($item in $lcuMsu) {
            if (-not [object]::ReferenceEquals($item, $target)) {
                $item.IsCheckpoint = $true
                if ($item.Reason -notmatch '(?i)checkpoint') {
                    $item.Reason = $item.Reason + '; MSU anterior de la cadena, tratado como checkpoint'
                }
            }
        }
    }

    Write-Progress -Activity 'Clasificando actualizaciones' -Completed
    $resultInventory = [object[]]($inventory.ToArray())
    Initialize-AIOUpdateServicingBuildRelations -Inventory $resultInventory
    $script:AIOUpdateRepositoryInventoryCache[$inventoryCacheKey] = $resultInventory
    return $resultInventory
}

function Get-AIOUpdatePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory,

        [Parameter(Mandatory = $true)]
        [string[]]$Category
    )

    return @(
        $Inventory |
            Where-Object { $_.Category -in $Category -and $_.Installable } |
            Sort-Object @{ Expression = { $_.Version }; Ascending = $true }, Name
    )
}

function Get-AIOUpdateInventorySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory
    )

    $categories = @('SSU', 'LCU', 'SafeOS', 'SecureBoot', 'SetupDU', 'ESU', 'Enablement', 'OS', 'DotNet', 'WinPE', 'Defender', 'Auxiliary', 'Unknown')
    foreach ($category in $categories) {
        $items = @($Inventory | Where-Object { $_.Category -eq $category })
        [pscustomobject]@{
            Category = $category
            Count    = $items.Count
            Size     = [long](($items | Measure-Object -Property Size -Sum).Sum)
            Items    = $items
        }
    }
}

function Format-AIOUpdateByteSize {
    [CmdletBinding()]
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-AIOUpdateImageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

    $summaries = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)
    if ($summaries.Count -eq 0) { throw "No se encontraron indices en '$ImagePath'." }

    $details = New-Object System.Collections.Generic.List[object]
    foreach ($summary in $summaries) {
        $index = [int]$summary.ImageIndex
        try {
            $detail = Get-WindowsImage -ImagePath $ImagePath -Index $index -ErrorAction Stop
            if (-not $detail.Version -or $null -eq $detail.Architecture) {
                throw 'DISM no devolvio Version o Architecture.'
            }
            [void]$details.Add($detail)
        }
        catch {
            throw "No fue posible obtener metadatos detallados del indice $index en '$ImagePath': $($_.Exception.Message)"
        }
    }

    return [object[]]($details.ToArray())
}

function Select-AIOUpdateInstallIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Images
    )

    Write-Host ''
    Write-Host ' Indices disponibles en install.wim:' -ForegroundColor Yellow
    foreach ($image in $Images) {
        $version = if ($image.Version) { $image.Version } else { 'N/D' }
        $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
        Write-Host ("   [{0}] {1} | {2} | {3}" -f $image.ImageIndex, $image.ImageName, $version, $architecture) -ForegroundColor White
    }

    while ($true) {
        $answer = (Read-Host "`nIndices a actualizar separados por coma/espacio, o T para todos").Trim()
        if ($answer -eq 'T') {
            return @($Images | ForEach-Object { [int]$_.ImageIndex })
        }

        $requested = @(
            $answer -split '[,; ]+' |
                Where-Object { $_ -match '^\d+$' } |
                ForEach-Object { [int]$_ } |
                Sort-Object -Unique
        )
        $valid = @($Images | ForEach-Object { [int]$_.ImageIndex })
        $invalid = @($requested | Where-Object { $_ -notin $valid })
        if ($requested.Count -gt 0 -and $invalid.Count -eq 0) {
            return $requested
        }

        Write-Host 'Seleccion invalida. Usa indices existentes o T.' -ForegroundColor Red
    }
}

function Convert-AIOUpdateArchitectureName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Architecture
    )

    $value = ([string]$Architecture).Trim().ToLowerInvariant()
    switch -Regex ($value) {
        '^(0|x86|i386|i686)$'              { return 'x86' }
        '^(9|x64|amd64|x86_64)$'           { return 'x64' }
        '^(12|arm64|aarch64)$'             { return 'arm64' }
        '^(5|arm)$'                         { return 'arm' }
        default {
            if ([string]::IsNullOrWhiteSpace($value)) { return 'Unknown' }
            return $value
        }
    }
}

function Format-AIOUpdateImageDisplayName {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$ImageName,
        [AllowNull()] [object]$Architecture
    )

    $name = ([string]$ImageName).Trim()
    $architectureName = Convert-AIOUpdateArchitectureName -Architecture $Architecture

    if ([string]::IsNullOrWhiteSpace($name)) {
        return $architectureName
    }
    if ([string]::IsNullOrWhiteSpace($architectureName) -or $architectureName -eq 'Unknown') {
        return $name
    }

    $aliases = switch ($architectureName) {
        'x64'   { @('x64', 'amd64', 'x86_64') }
        'x86'   { @('x86', 'i386', 'i686') }
        'arm64' { @('arm64', 'aarch64') }
        'arm'   { @('arm') }
        default { @($architectureName) }
    }

    foreach ($alias in $aliases) {
        $escaped = [regex]::Escape([string]$alias)
        if ($name -match "(?i)(?:^|[\s\(\[\-_])$escaped(?:$|[\s\)\]\-_])") {
            return $name
        }
    }

    return "$name ($architectureName)"
}

function Assert-AIOUpdateCompatibleIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Images,

        [Parameter(Mandatory = $true)]
        [int[]]$Indexes
    )

    $selected = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes })
    $architectures = @($selected | ForEach-Object { Convert-AIOUpdateArchitectureName -Architecture $_.Architecture } | Sort-Object -Unique)
    $builds = @($selected | ForEach-Object { ([version]$_.Version).Build } | Sort-Object -Unique)

    if ($architectures.Count -gt 1) {
        throw "Los indices seleccionados tienen arquitecturas diferentes: $($architectures -join ', ')."
    }
    if ($builds.Count -gt 1) {
        throw "Los indices seleccionados tienen builds diferentes: $($builds -join ', ')."
    }

    return [pscustomobject]@{
        Images       = $selected
        Architecture = $architectures[0]
        Build        = [int]$builds[0]
        Version      = [version]$selected[0].Version
    }
}

function Assert-AIOUpdateEsuPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [psobject]$Compatibility
    )

    # Detecta la etapa ESU por la version interna de la LCU. No se modifican
    # ni se omiten comprobaciones de licencia. En imagenes cliente no LTSC,
    # el paquete de preparacion no equivale a una licencia ESU activa para
    # mantenimiento offline.
    $esuEraLcus = @($Inventory | Where-Object {
        if ($_.Category -ne 'LCU') { return $false }
        try {
            $packageVersion = [version]$_.Version
            return ($packageVersion.Build -eq 19041 -and $packageVersion.Revision -gt 6456)
        }
        catch {
            return $false
        }
    })
    if ($esuEraLcus.Count -eq 0) { return }

    $nonLtsc = @($Compatibility.Images | Where-Object {
        [string]$_.ImageName -notmatch '(?i)LTSC|Long.Term.Servicing'
    })
    if ($nonLtsc.Count -eq 0) { return }

    $targets = @($esuEraLcus | ForEach-Object { $_.Name }) -join ', '
    $message = @"
Se detecto una LCU de la etapa ESU para Windows 10 cliente no LTSC:
$targets

El modulo no suprime comprobaciones de licencia ESU. El paquete de preparacion
puede integrarse, pero no concede por si solo el derecho ESU a una imagen
offline. Despliega la imagen, activa ESU por el metodo autorizado y aplica la
LCU en el sistema en linea, o utiliza un medio LTSC compatible.
"@
    throw $message.Trim()
}


function Mount-AIOUpdateImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ReadOnly
    )

    Initialize-AIOUpdateDirectory -Path $MountPath -Empty
    $arguments = @(
        '/Mount-Image',
        "/ImageFile:$ImagePath",
        "/Index:$Index",
        "/MountDir:$MountPath",
        "/ScratchDir:$ScratchPath"
    )
    if ($ReadOnly) { $arguments += '/ReadOnly' }
    [void](Invoke-AIOUpdateDism -Arguments $arguments -Context $Context)
}

function Dismount-AIOUpdateImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [ValidateSet('Commit', 'Discard')] [string]$Mode,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$NoThrow
    )

    $action = if ($Mode -eq 'Commit') { '/Commit' } else { '/Discard' }
    $arguments = @('/Unmount-Image', "/MountDir:$MountPath", $action)
    if ($Mode -eq 'Commit') { $arguments += '/CheckIntegrity' }
    $result = Invoke-AIOUpdateDism -Arguments $arguments -Context $Context -NoThrow:$NoThrow

    if ($result.Success -and (Test-Path -LiteralPath $MountPath)) {
        Get-ChildItem -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Get-AIOUpdateMountedPackageInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPath,

        [switch]$Strict
    )

    try {
        return @(
            Get-WindowsPackage -Path $MountPath -ErrorAction Stop |
                Select-Object PackageName, PackageState, ReleaseType, InstallTime
        )
    }
    catch {
        $message = "No se pudo obtener inventario de paquetes en '$MountPath': $($_.Exception.Message)"
        Write-AIOUpdateLog -Level WARN -Message $message
        if ($Strict) { throw $message }
        return @()
    }
}

function Initialize-AIOUpdateLcuMsuStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$StagingRoot
    )

    $script:AIOUpdatePackagePathMap = @{}
    $script:AIOUpdateLcuStageRoot = $null

    $lcuMsus = @(
        $Inventory |
            Where-Object { $_.Category -eq 'LCU' -and $_.Extension -eq '.msu' -and $_.Installable } |
            Sort-Object @{ Expression = { $_.Version }; Ascending = $true }, Name
    )
    if ($lcuMsus.Count -eq 0) { return }

    $root = Join-Path $StagingRoot 'LCU_MSU'
    Initialize-AIOUpdateDirectory -Path $root -Empty
    $script:AIOUpdateLcuStageRoot = $root

    foreach ($package in $lcuMsus) {
        $version = [version]$package.Version
        $build = if ($version.Build -ge 0) { $version.Build } else { 0 }
        $revision = if ($version.Revision -ge 0) { $version.Revision } else { 0 }
        $prefix = '{0:D5}_{1:D5}' -f $build, $revision
        $commonPath = Join-Path $root ("${prefix}-$($package.Name)")
        Copy-Item -LiteralPath $package.FullName -Destination $commonPath -Force -ErrorAction Stop

        if ($package.IsCheckpoint) {
            $identity = if ($package.KB) { $package.KB } else { [System.IO.Path]::GetFileNameWithoutExtension($package.Name) }
            $identity = ($identity -replace '[^A-Za-z0-9_.-]', '_')
            $checkpointRoot = Join-Path $StagingRoot ("LCU_Checkpoint_$identity")
            Initialize-AIOUpdateDirectory -Path $checkpointRoot -Empty
            $isolatedPath = Join-Path $checkpointRoot ("${prefix}-$($package.Name)")
            Copy-Item -LiteralPath $package.FullName -Destination $isolatedPath -Force -ErrorAction Stop
            $script:AIOUpdatePackagePathMap[$package.FullName] = $isolatedPath
            Write-AIOUpdateLog -Level INFO -Message "Checkpoint LCU aislado: $($package.Name) -> $isolatedPath"
        }
        else {
            # Los destinos LCU permanecen juntos para que DISM pueda descubrir
            # automaticamente los checkpoints que necesite, sin mezclar SafeOS,
            # SetupDU u otros MSU ajenos al mantenimiento acumulativo.
            $script:AIOUpdatePackagePathMap[$package.FullName] = $commonPath
        }
    }

    Write-AIOUpdateLog -Level INFO -Message "Staging LCU MSU preparado con $($lcuMsus.Count) paquete(s) en '$root'."
}

function Get-AIOUpdateEffectivePackagePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package
    )

    if ($script:AIOUpdatePackagePathMap -and $script:AIOUpdatePackagePathMap.ContainsKey($Package.FullName)) {
        return [string]$script:AIOUpdatePackagePathMap[$Package.FullName]
    }
    return [string]$Package.FullName
}


function Get-AIOUpdateServicingVersionFromName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    $version = Get-AIOUpdateVersionFromText -Text $Text
    if ($version -ne [version]'0.0.0.0') { return $version }

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $matches = [regex]::Matches($Text, '(?<!\d)(\d{4,5})\.(\d{2,6})(?!\d)')
        if ($matches.Count -gt 0) {
            $match = $matches[$matches.Count - 1]
            try {
                return [version]("10.0.{0}.{1}" -f $match.Groups[1].Value, $match.Groups[2].Value)
            }
            catch {}
        }
    }

    return [version]'0.0.0.0'
}

function Initialize-AIOUpdateEmbeddedSsuStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$StagingRoot
    )

    $script:AIOUpdateEmbeddedSsuPackages = @()
$script:AIOUpdateWimlibPath = $null
    $lcuPackages = @(
        Get-AIOUpdatePackages -Inventory $Inventory -Category @('LCU') |
            Sort-Object @{ Expression = { [version]$_.Version }; Ascending = $true }, Name
    )
    if ($lcuPackages.Count -eq 0) { return @() }

    $root = Join-Path $StagingRoot 'Embedded_SSU'
    Initialize-AIOUpdateDirectory -Path $root -Empty
    $candidates = New-Object System.Collections.Generic.List[object]
    $knownHashes = @{}
    $packagePosition = 0

    foreach ($package in $lcuPackages) {
        $packagePosition++
        $packageRoot = Join-Path $root ("Source_{0:D2}" -f $packagePosition)
        Initialize-AIOUpdateDirectory -Path $packageRoot -Empty

        # Las LCUs combinadas publicadas desde 2021 contienen la pila de
        # mantenimiento. Se extraen solamente CAB cuyo nombre identifica SSU;
        # no se descomprime el payload acumulativo completo.
        foreach ($pattern in @('*SSU*.cab', '*ServicingStack*.cab', '*Servicing-Stack*.cab')) {
            & $script:AIOUpdateExpandPath ("-F:$pattern") $package.FullName $packageRoot *> $null
        }

        if (-not @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter '*.cab' -File -ErrorAction SilentlyContinue).Count) {
            # Algunos MSU no aceptan comodines amplios. Se consulta primero el
            # indice y se extraen por nombre exacto las entradas candidatas.
            $listing = @(& $script:AIOUpdateExpandPath '-D' $package.FullName 2>$null)
            foreach ($line in $listing) {
                $value = ([string]$line).Trim()
                $match = [regex]::Match($value, '(?i)([^\\/:*?"<>|\r\n]*(?:SSU|Servicing(?:-|_)?Stack)[^\\/:*?"<>|\r\n]*\.cab)')
                if ($match.Success) {
                    & $script:AIOUpdateExpandPath ("-F:$($match.Groups[1].Value)") $package.FullName $packageRoot *> $null
                }
            }
        }

        foreach ($cab in @(
            Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter '*.cab' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)(?:^SSU[-_.]|Servicing(?:-|_)?Stack)' }
        )) {
            try { $hash = (Get-FileHash -LiteralPath $cab.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
            catch { $hash = $cab.FullName.ToLowerInvariant() }
            if ($knownHashes.ContainsKey($hash)) { continue }
            $knownHashes[$hash] = $true

            $version = Get-AIOUpdateServicingVersionFromName -Text $cab.Name
            $safeSource = ([System.IO.Path]::GetFileNameWithoutExtension($package.Name) -replace '[^A-Za-z0-9_.-]', '_')
            $destination = Join-Path $root ("{0}_{1}" -f $safeSource, $cab.Name)
            Copy-Item -LiteralPath $cab.FullName -Destination $destination -Force -ErrorAction Stop
            $file = Get-Item -LiteralPath $destination -ErrorAction Stop

            [void]$candidates.Add([pscustomobject]@{
                File         = $file
                FullName     = $file.FullName
                Name         = $file.Name
                Extension    = '.cab'
                Category     = 'SSU'
                Reason       = "SSU integrado extraido de $($package.Name)"
                Version      = $version
                KB           = $null
                IsCheckpoint = $false
                Auxiliary    = $false
                Embedded     = $true
                SourcePackage = $package.Name
            })
        }
    }

    $script:AIOUpdateEmbeddedSsuPackages = [object[]]($candidates.ToArray())
    if ($script:AIOUpdateEmbeddedSsuPackages.Count -gt 0) {
        Write-AIOUpdateLog -Level INFO -Message "Se extrajeron $($script:AIOUpdateEmbeddedSsuPackages.Count) SSU integrado(s) desde las LCU."
    }
    else {
        Write-AIOUpdateLog -Level INFO -Message 'Las LCU no exponen un CAB SSU independiente extraible; se usaran SSU independientes si existen. Esto no impide procesar SafeOS/LCU.'
    }

    return [object[]]($script:AIOUpdateEmbeddedSsuPackages)
}

function Get-AIOUpdateEffectiveSsuPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    $all = New-Object System.Collections.Generic.List[object]
    foreach ($package in @(Get-AIOUpdatePackages -Inventory $Inventory -Category @('SSU'))) {
        [void]$all.Add($package)
    }
    foreach ($package in @($script:AIOUpdateEmbeddedSsuPackages)) {
        [void]$all.Add($package)
    }
    if ($all.Count -eq 0) { return @() }

    # instala solamente la pila de mantenimiento mas reciente. Esto
    # evita aplicar varias revisiones equivalentes procedentes de checkpoints.
    $selected = @(
        [object[]]($all.ToArray()) |
            Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true },
                        @{ Expression = { if ($_.Embedded) { 1 } else { 0 } }; Descending = $true },
                        Name |
            Select-Object -First 1
    )

    if ($selected.Count -gt 0) {
        $source = if ($selected[0].Embedded) { "extraido de $($selected[0].SourcePackage)" } else { 'paquete independiente' }
        Write-AIOUpdateLog -Level INFO -Message "SSU efectivo para WinRE/WinPE: $($selected[0].Name) ($source)."
    }
    return [object[]]$selected
}

function Invoke-AIOUpdateCheckpointMsuFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [psobject]$Package,
        [Parameter(Mandatory = $true)] [string]$PackagePath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $identity = if ($Package.KB) { $Package.KB } else { [System.IO.Path]::GetFileNameWithoutExtension($Package.Name) }
    $identity = ($identity -replace '[^A-Za-z0-9_.-]', '_')
    $expandRoot = Join-Path $script:AIOUpdateSessionRoot ("Expanded_Checkpoint_$identity")
    $outerRoot = Join-Path $expandRoot 'Outer'
    Initialize-AIOUpdateDirectory -Path $expandRoot -Empty
    Initialize-AIOUpdateDirectory -Path $outerRoot

    Write-Host '      Reintentando mediante paquetes internos del MSU...' -ForegroundColor Yellow
    Write-AIOUpdateLog -Level WARN -Message "${Context}: reintento expandido por error 0x80070228."

    & $script:AIOUpdateExpandPath '-F:*.cab' $PackagePath $outerRoot *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible expandir el checkpoint MSU '$($Package.Name)'. Codigo expand.exe: $LASTEXITCODE."
    }

    $cabs = @(Get-ChildItem -LiteralPath $outerRoot -Filter '*.cab' -File -ErrorAction Stop)
    if ($cabs.Count -eq 0) {
        throw "El checkpoint MSU '$($Package.Name)' no contiene CAB internos utilizables."
    }

    $ssuCabs = @($cabs | Where-Object { $_.Name -match '(?i)^SSU-|ServicingStack' } | Sort-Object Name)
    foreach ($ssuCab in $ssuCabs) {
        [void](Invoke-AIOUpdateDism -Arguments @(
            "/Image:$MountPath",
            '/Add-Package',
            "/PackagePath:$($ssuCab.FullName)",
            "/ScratchDir:$ScratchPath"
        ) -Context "$Context - SSU interno $($ssuCab.Name)" -AllowNotApplicable)
    }

    $mainCabs = @()
    if ($Package.KB) {
        $mainCabs = @($cabs | Where-Object { $_.Name -match [regex]::Escape($Package.KB) })
    }
    if ($mainCabs.Count -eq 0) {
        $mainCabs = @(
            $cabs |
                Where-Object { $_.Name -notmatch '(?i)^SSU-|ServicingStack|WSUSSCAN|DesktopDeployment|AggregatedMetadata' } |
                Sort-Object Length -Descending |
                Select-Object -First 1
        )
    }
    if ($mainCabs.Count -eq 0) {
        throw "No se identifico el CAB acumulativo interno de '$($Package.Name)'."
    }

    $lastResult = $null
    $counter = 0
    foreach ($mainCab in $mainCabs) {
        $counter++
        $payloadRoot = Join-Path $expandRoot ("Payload_$counter")
        Initialize-AIOUpdateDirectory -Path $payloadRoot -Empty
        & $script:AIOUpdateExpandPath '-F:*' $mainCab.FullName $payloadRoot *> $null

        $updateMum = Join-Path $payloadRoot 'update.mum'
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $updateMum -PathType Leaf)) {
            $lastResult = Invoke-AIOUpdateDism -Arguments @(
                "/Image:$MountPath",
                '/Add-Package',
                "/PackagePath:$updateMum",
                "/ScratchDir:$ScratchPath"
            ) -Context "$Context - update.mum expandido" -AllowNotApplicable
        }
        else {
            $lastResult = Invoke-AIOUpdateDism -Arguments @(
                "/Image:$MountPath",
                '/Add-Package',
                "/PackagePath:$($mainCab.FullName)",
                "/ScratchDir:$ScratchPath"
            ) -Context "$Context - CAB interno $($mainCab.Name)" -AllowNotApplicable
        }
    }

    return $lastResult
}



function Normalize-AIOUpdateCbsIdentityName {
    [CmdletBinding()]
    param([AllowNull()] [string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return $Name.Trim().ToLowerInvariant()
}

function Get-AIOUpdatePackageOrderRank {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $rank = switch ([string]$Package.Category) {
        'SSU'        { 10 }
        'SecureBoot' { 20 }
        'OS'         { 30 }
        'WinPE'      { 30 }
        'Enablement' { 40 }
        'ESU'        { 50 }
        'LCU'        { if ($Package.IsCheckpoint) { 55 } else { 60 } }
        'DotNet'     { 70 }
        'SafeOS'     { 80 }
        'Defender'   { 90 }
        'SetupDU'    { 100 }
        default      { 500 }
    }
    return [int]$rank
}

function Resolve-AIOUpdateCbsPackageOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $nodes = @(
        $Packages |
            Where-Object { $null -ne $_ } |
            Group-Object { ([string]$_.FullName).ToLowerInvariant() } |
            ForEach-Object { $_.Group[0] }
    )
    if ($nodes.Count -eq 0) { return @() }

    $nodeById = @{}
    $identityMap = @{}
    $incoming = @{}
    $outgoing = @{}
    $matchedDependencies = @{}
    $orderingConstraints = @{}

    foreach ($package in $nodes) {
        $id = ([string]$package.FullName).ToLowerInvariant()
        $nodeById[$id] = $package
        $incoming[$id] = New-Object System.Collections.Generic.HashSet[string]
        $outgoing[$id] = New-Object System.Collections.Generic.HashSet[string]
        $matchedDependencies[$id] = New-Object System.Collections.Generic.List[string]
        $orderingConstraints[$id] = New-Object System.Collections.Generic.List[string]

        # Una dependencia solo puede ser satisfecha por una identidad PROPIA
        # de otro paquete del conjunto. IdentityHints puede incluir ediciones o
        # prerrequisitos externos y no debe convertirse en proveedor CBS.
        $identities = @(
            if ($package.Metadata) { $package.Metadata.CbsOwnIdentities }
            if (-not [string]::IsNullOrWhiteSpace([string]$package.KB)) { [string]$package.KB }
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique

        foreach ($identity in $identities) {
            $key = Normalize-AIOUpdateCbsIdentityName -Name ([string]$identity)
            if (-not $key) { continue }
            if (-not $identityMap.ContainsKey($key)) {
                $identityMap[$key] = New-Object System.Collections.Generic.List[string]
            }
            if (-not $identityMap[$key].Contains($id)) {
                [void]$identityMap[$key].Add($id)
            }
        }
    }

    foreach ($package in $nodes) {
        $targetId = ([string]$package.FullName).ToLowerInvariant()
        $dependencies = @(
            if ($package.Metadata) { $package.Metadata.CbsDependencies }
            if ($package.Metadata) { $package.Metadata.CbsParents }
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique

        foreach ($dependency in $dependencies) {
            $key = Normalize-AIOUpdateCbsIdentityName -Name ([string]$dependency)
            if (-not $key -or -not $identityMap.ContainsKey($key)) { continue }

            $providers = @(
                $identityMap[$key] |
                    Where-Object { $_ -ne $targetId } |
                    ForEach-Object { $nodeById[$_] } |
                    Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, Name
            )
            if ($providers.Count -eq 0) { continue }

            $provider = $providers[0]
            $providerId = ([string]$provider.FullName).ToLowerInvariant()
            if ($incoming[$targetId].Add($providerId)) {
                [void]$outgoing[$providerId].Add($targetId)
                [void]$matchedDependencies[$targetId].Add([string]$dependency)
            }
        }
    }

    # En install.wim un paquete Enablement debe quedar después de la cadena
    # LCU que aporta su nivel CBS requerido. Es una política segura explícita,
    # no una dependencia inventada a partir de ediciones compartidas.
    if ($Context -match '(?i)^install\.wim\s+indice\s+\d+$') {
        $lcuNodes = @($nodes | Where-Object { $_.Category -eq 'LCU' })
        $enablementNodes = @($nodes | Where-Object { $_.Category -eq 'Enablement' })
        foreach ($enablement in $enablementNodes) {
            $targetId = ([string]$enablement.FullName).ToLowerInvariant()
            foreach ($lcu in $lcuNodes) {
                $providerId = ([string]$lcu.FullName).ToLowerInvariant()
                if ($providerId -eq $targetId) { continue }
                if ($incoming[$targetId].Add($providerId)) {
                    [void]$outgoing[$providerId].Add($targetId)
                }
            }
            if ($lcuNodes.Count -gt 0) {
                [void]$orderingConstraints[$targetId].Add('Politica segura: cadena LCU antes de Enablement')
            }
        }
    }

    $available = New-Object System.Collections.Generic.List[object]
    foreach ($id in $nodeById.Keys) {
        if ($incoming[$id].Count -eq 0) { [void]$available.Add($nodeById[$id]) }
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    while ($available.Count -gt 0) {
        $next = @(
            $available |
                Sort-Object `
                    @{ Expression = { Get-AIOUpdatePackageOrderRank -Package $_ }; Ascending = $true },
                    @{ Expression = { [version]$_.Version }; Ascending = $true },
                    @{ Expression = { [string]$_.Name }; Ascending = $true } |
                Select-Object -First 1
        )[0]
        [void]$available.Remove($next)
        [void]$ordered.Add($next)

        $nextId = ([string]$next.FullName).ToLowerInvariant()
        foreach ($dependentId in @($outgoing[$nextId])) {
            [void]$incoming[$dependentId].Remove($nextId)
            if ($incoming[$dependentId].Count -eq 0) {
                [void]$available.Add($nodeById[$dependentId])
            }
        }
    }

    $hadAmbiguity = ($ordered.Count -lt $nodes.Count)
    if ($hadAmbiguity) {
        $orderedIds = @{}
        foreach ($package in $ordered) { $orderedIds[([string]$package.FullName).ToLowerInvariant()] = $true }
        $remaining = @(
            $nodes |
                Where-Object { -not $orderedIds.ContainsKey(([string]$_.FullName).ToLowerInvariant()) } |
                Sort-Object `
                    @{ Expression = { Get-AIOUpdatePackageOrderRank -Package $_ }; Ascending = $true },
                    @{ Expression = { [version]$_.Version }; Ascending = $true },
                    Name
        )
        foreach ($package in $remaining) { [void]$ordered.Add($package) }
        Write-AIOUpdateLog -Level WARN -Message "Orden CBS '$Context': existe un ciclo real entre identidades propias; se completo usando el orden seguro por categoria."
    }

    $planEntries = New-Object System.Collections.Generic.List[object]
    $position = 0
    foreach ($package in $ordered) {
        $position++
        $id = ([string]$package.FullName).ToLowerInvariant()
        [void]$planEntries.Add([pscustomobject]@{
            Position             = $position
            PlannedPosition      = $position
            ExecutedPosition     = $null
            ExecutionState       = 'Pending'
            ExitCode             = $null
            FullName             = [string]$package.FullName
            Category             = [string]$package.Category
            Name                 = [string]$package.Name
            Version              = [string]$package.Version
            IsCheckpoint         = [bool]$package.IsCheckpoint
            MatchedDependencies  = [string[]]@($matchedDependencies[$id].ToArray() | Sort-Object -Unique)
            OrderingConstraints  = [string[]]@($orderingConstraints[$id].ToArray() | Sort-Object -Unique)
            MetadataDependencies = [string[]]@(
                if ($package.Metadata) { $package.Metadata.CbsDependencies }
                if ($package.Metadata) { $package.Metadata.CbsParents }
            )
        })
    }

    $plan = [pscustomobject]@{
        Context      = $Context
        Resolution   = if ($hadAmbiguity) { 'SafeCategoryFallback' } else { 'ExactIdentityGraph' }
        HadAmbiguity = $hadAmbiguity
        Packages     = [object[]]($planEntries.ToArray())
    }
    [void]$script:AIOUpdateDependencyPlans.Add($plan)

    $summary = @($ordered | ForEach-Object { "$($_.Category):$($_.Name)" }) -join ' -> '
    Write-AIOUpdateLog -Level INFO -Message "Orden CBS planeado para '$Context': $summary"
    Write-Host "   Orden CBS planeado: $(@($ordered | ForEach-Object { $_.Category }) -join ' -> ')" -ForegroundColor DarkGray

    return [object[]]($ordered.ToArray())
}

function Update-AIOUpdateDependencyPlanExecution {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$Context,
        [Parameter(Mandatory = $true)] [object]$Package,
        [Parameter(Mandatory = $true)] [object]$Result
    )

    if ([string]::IsNullOrWhiteSpace($Context)) { return }
    $plans = @($script:AIOUpdateDependencyPlans | Where-Object { [string]$_.Context -eq $Context })
    if ($plans.Count -eq 0) { return }
    $plan = $plans[-1]
    $fullName = [string]$Package.FullName
    $entry = @($plan.Packages | Where-Object { [string]$_.FullName -eq $fullName } | Select-Object -First 1)
    if ($entry.Count -eq 0) { return }

    $state = [string]$Result.State
    $executionState = if ($state -eq 'AlreadyPresent') {
        'AlreadyPresent'
    }
    elseif ($state -eq 'Reapplied') {
        'Reapplied'
    }
    elseif ($state -eq 'ReapplyNotApplicable') {
        'ReapplyNotApplicable'
    }
    elseif ($state -eq 'NotApplicable') {
        'NotApplicable'
    }
    elseif ($Result.Success) {
        'Applied'
    }
    else {
        'Failed'
    }

    $entry[0].ExecutionState = $executionState
    if ($Result.PSObject.Properties['ExitCode']) {
        $entry[0].ExitCode = [int]$Result.ExitCode
    }

    if ($executionState -ne 'AlreadyPresent') {
        if (-not $script:AIOUpdateExecutionPositionByContext.ContainsKey($Context)) {
            $script:AIOUpdateExecutionPositionByContext[$Context] = 0
        }
        $script:AIOUpdateExecutionPositionByContext[$Context]++
        $entry[0].ExecutedPosition = [int]$script:AIOUpdateExecutionPositionByContext[$Context]
    }
}

function Add-AIOUpdatePackageList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$AllowNotApplicable,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory,
        [AllowNull()] [string]$DependencyContext
    )

    $Packages = @(Get-AIOUpdateUniquePackages -Packages $Packages)
    $results = New-Object System.Collections.Generic.List[object]
    if (@($Packages).Count -eq 0) {
        Write-Host "   [OMITIDO] ${Context}: no hay paquetes." -ForegroundColor DarkGray
        return @()
    }

    $position = 0
    foreach ($package in $Packages) {
        $position++
        Write-Host ("`n   [{0}/{1}] {2}" -f $position, $Packages.Count, $package.Name) -ForegroundColor Yellow

        $alreadyPresent = Test-AIOUpdatePackageInstalled -Package $package -InstalledInventory $InstalledInventory
        $reapplyAttempt = $alreadyPresent

        if ($reapplyAttempt) {
            Write-Host '      [REAPLICAR] El paquete ya esta presente; se enviara nuevamente a DISM sin desinstalarlo.' -ForegroundColor Yellow
            Write-AIOUpdateLog -Level WARN -Message "$Context - $($package.Name): reaplicacion solicitada para un paquete Installed/InstallPending/Superseded."
        }

        $effectivePath = Get-AIOUpdateEffectivePackagePath -Package $package
        $effectiveContext = "$Context - $($package.Name)"
        if ($effectivePath -ne $package.FullName) {
            $mode = if ($package.IsCheckpoint) { 'checkpoint MSU aislado' } else { 'repositorio LCU MSU aislado' }
            Write-Host "      Staging: $mode" -ForegroundColor DarkGray
            $effectiveContext = "$effectiveContext [$mode]"
        }

        if ($reapplyAttempt) {
            $effectiveContext = "$effectiveContext [reaplicacion solicitada]"
        }

        $checkpointMsu = ($package.IsCheckpoint -and $package.Extension -eq '.msu')
        try {
            $result = Invoke-AIOUpdateDism -Arguments @(
                "/Image:$MountPath",
                '/Add-Package',
                "/PackagePath:$effectivePath",
                "/ScratchDir:$ScratchPath"
            ) -Context $effectiveContext -AllowNotApplicable:($AllowNotApplicable -or $checkpointMsu -or $reapplyAttempt) -NoThrow:$checkpointMsu
        }
        catch {
            $failedResult = [pscustomobject]@{
                Success      = $false
                State        = 'Failed'
                ExitCode     = -1
                UnsignedCode = [uint32]4294967295
                Context      = $effectiveContext
            }
            Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $failedResult
            throw
        }

        if (-not $result.Success -and $checkpointMsu -and $result.ExitCode -eq 552) {
            $result = Invoke-AIOUpdateCheckpointMsuFallback -MountPath $MountPath -Package $package -PackagePath $effectivePath -ScratchPath $ScratchPath -Context $effectiveContext
        }
        elseif (-not $result.Success) {
            Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $result
            $hexCode = '0x{0:X8}' -f $result.UnsignedCode
            $description = Get-AIOUpdateExitCodeText -ExitCode $result.ExitCode
            throw "$effectiveContext fallo. Codigo DISM: $($result.ExitCode) ($hexCode). $description"
        }

        if ($reapplyAttempt) {
            $dismState = [string]$result.State
            $result | Add-Member -NotePropertyName DismState -NotePropertyValue $dismState -Force
            $result | Add-Member -NotePropertyName ReapplyRequested -NotePropertyValue $true -Force
            $result.State = if ($dismState -eq 'NotApplicable') { 'ReapplyNotApplicable' } else { 'Reapplied' }

            if ($result.State -eq 'ReapplyNotApplicable') {
                Write-Host '      [SIN CAMBIOS] CBS determino que la reaplicacion no era necesaria o aplicable.' -ForegroundColor DarkYellow
            }
            else {
                Write-Host '      [REAPLICADO] DISM acepto nuevamente el paquete.' -ForegroundColor Green
            }
        }

        Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $result
        [void]$results.Add([pscustomobject]@{ Package = $package; Result = $result })
    }

    return [object[]]($results.ToArray())
}

function Invoke-AIOUpdateCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ResetBase,
        [switch]$WarningOnly
    )

    $arguments = @(
        "/Image:$MountPath",
        '/Cleanup-Image',
        '/StartComponentCleanup',
        "/ScratchDir:$ScratchPath"
    )
    if ($ResetBase) { $arguments += '/ResetBase' }

    $result = Invoke-AIOUpdateDism -Arguments $arguments -Context $Context -NoThrow:$WarningOnly
    if (-not $result.Success -and $WarningOnly) {
        Write-Host "   [AVISO] La limpieza fallo, pero la integracion continuara." -ForegroundColor Yellow
    }
    return $result
}

function Update-AIOUpdateServicingBuildRelationsFromInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    foreach ($item in @($Inventory | Where-Object { $_.PackageState -match '(?i)Installed|Install ?Pending|Superseded' })) {
        $name = [string]$item.PackageName
        if ($name -notmatch '(?i)Enablement[-_ ]+Package') { continue }
        $parsed = ConvertTo-AIOUpdateServicingVersion -Version (Get-AIOUpdateVersionFromText -Text $name)
        $baseBuild = [int]$parsed.Build
        if ($baseBuild -lt 7600) { continue }

        foreach ($match in [regex]::Matches($name, '(?i)(?<!\d)(\d{5})(?!\d)(?=[^~\r\n]{0,80}(?:Version[-_ ]+)?Enablement[-_ ]+Package)')) {
            $targetBuild = [int]$match.Groups[1].Value
            if ($targetBuild -ge 7600 -and $targetBuild -le 99999) {
                Add-AIOUpdateServicingBuildRelation -First $baseBuild -Second $targetBuild
            }
        }
        foreach ($match in [regex]::Matches($name, '(?i)SV2Moment(\d+)Enablement[-_ ]+Package')) {
            $offset = [int]$match.Groups[1].Value
            if ($offset -gt 0 -and $offset -lt 100) {
                Add-AIOUpdateServicingBuildRelation -First $baseBuild -Second ($baseBuild + $offset)
            }
        }
    }
}

function ConvertTo-AIOUpdateServicingVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [version]$Version
    )

    if ($Version.Major -in @(6, 10) -and $Version.Build -ge 7600) {
        return [version]("10.0.{0}.{1}" -f $Version.Build, [math]::Max(0, $Version.Revision))
    }
    if ($Version.Major -ge 7600) {
        return [version]("10.0.{0}.{1}" -f $Version.Major, [math]::Max(0, $Version.Minor))
    }
    return [version]'0.0.0.0'
}

function Get-AIOUpdateObservedServicingVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [string[]]$Patterns = @('Package_for_RollupFix', 'Package_for_SafeOSDU')
    )

    $versions = New-Object System.Collections.Generic.List[System.Version]
    foreach ($item in @($Inventory | Where-Object { $_.PackageState -match '(?i)Installed|Install ?Pending|Superseded' })) {
        $name = [string]$item.PackageName
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (@($Patterns | Where-Object { $name -match $_ }).Count -eq 0) { continue }
        $parsed = ConvertTo-AIOUpdateServicingVersion -Version (Get-AIOUpdateVersionFromText -Text $name)
        if ($parsed -ne [version]'0.0.0.0') { [void]$versions.Add($parsed) }
    }
    if ($versions.Count -eq 0) { return [version]'0.0.0.0' }
    return [version]($versions.ToArray() | Sort-Object -Descending | Select-Object -First 1)
}

function Test-AIOUpdateServicingVersionAtLeast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [version]$Actual,
        [Parameter(Mandatory = $true)] [version]$Expected
    )

    $actualNormalized = ConvertTo-AIOUpdateServicingVersion -Version $Actual
    $expectedNormalized = ConvertTo-AIOUpdateServicingVersion -Version $Expected
    if ($expectedNormalized -eq [version]'0.0.0.0') { return $true }
    if ($actualNormalized -eq [version]'0.0.0.0') { return $false }

    $actualFamily = Get-AIOUpdateServicingBuildFamily -Build $actualNormalized.Build
    $expectedFamily = Get-AIOUpdateServicingBuildFamily -Build $expectedNormalized.Build
    if ($actualFamily -eq $expectedFamily) {
        return ($actualNormalized.Revision -ge $expectedNormalized.Revision)
    }

    # Fallback generico para una rama visible habilitada sobre la base CBS:
    # misma revision o superior y salto pequeno hacia una build mayor. No se
    # guarda ninguna lista de builds y una relacion explicita siempre prevalece.
    $delta = $actualNormalized.Build - $expectedNormalized.Build
    return ($delta -gt 0 -and $delta -le 1000 -and $actualNormalized.Revision -ge $expectedNormalized.Revision)
}

function Get-AIOUpdateSemanticPackageEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Operation,
        [Parameter(Mandatory = $true)] [object[]]$AfterInventory
    )

    $package = $Operation.Package
    $result = $Operation.Result
    $name = if ($package -and $package.Name) { [string]$package.Name } else { [string]$result.Context }
    $category = if ($package -and $package.Category) { [string]$package.Category } else { 'Desconocida' }
    $state = if ($result -and $result.State) { [string]$result.State } else { 'Unknown' }

    if ($state -in @('NotApplicable', 'ReapplyNotApplicable')) {
        $status = if ($state -eq 'ReapplyNotApplicable') { 'ReapplyNotApplicable' } else { 'NotApplicable' }
        $reason = if ($state -eq 'ReapplyNotApplicable') { 'CBS determino que la reaplicacion no era necesaria o aplicable' } else { 'CBS determino que no era aplicable' }
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = $status; Reason = $reason }
    }
    if ($category -eq 'SetupDU') {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'External'; Reason = 'Verificado por mezcla y SHA-256 fuera del catalogo CBS' }
    }
    if ($category -eq 'Defender' -and $result.PSObject.Properties['VerifiedFiles'] -and [int]$result.VerifiedFiles -gt 0) {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'External'; Reason = "Plataforma/firmas verificadas por SHA-256: $($result.VerifiedFiles) archivo(s)" }
    }

    $evidenceInventory = @($AfterInventory | Where-Object { $_.PackageState -match '(?i)Installed|Install ?Pending|Superseded' })
    if ($category -eq 'WinPE-Rejuv') {
        if ($package -and
            $package.PSObject.Properties['RemovalCheckedBeforeLcu'] -and
            [bool]$package.RemovalCheckedBeforeLcu) {

            $verified = [bool]$package.RemovalVerified
            $stateText = [string]$package.RemovalState
            $advisoryOnly = (
                $package.PSObject.Properties['AdvisoryOnly'] -and
                [bool]$package.AdvisoryOnly
            )

            if ($advisoryOnly) {
                return [pscustomobject]@{
                    Package = $name
                    Category = $category
                    Success = $true
                    Status = 'NeutralRejuvPreserved'
                    Reason = "CBS conservo o restablecio el componente neutro; estado inmediato: $stateText. La LCU y la limpieza terminaron correctamente."
                }
            }

            return [pscustomobject]@{
                Package = $name
                Category = $category
                Success = $verified
                Status = if ($verified) { 'RemovedBeforeLcu' } else { 'MissingRemoval' }
                Reason = if ($verified) {
                    "Retirada confirmada inmediatamente antes de la LCU; estado exacto: $stateText"
                }
                else {
                    "La identidad localizada seguia activa inmediatamente despues de Remove-Package; estado: $stateText"
                }
            }
        }

        # Fallback para registros antiguos: se evalua solo la identidad exacta.
        # Una identidad WinPE-Rejuv nueva agregada por la LCU no invalida la
        # retirada preventiva de la version anterior.
        $exactEntries = @(
            $AfterInventory |
                Where-Object { [string]$_.PackageName -ieq $name }
        )
        $blocking = @(
            $exactEntries |
                Where-Object {
                    [string]$_.PackageState -match '(?i)^Installed$|^Install ?Pending$|^Staged$|^Partially ?Installed$'
                }
        )
        $states = @(
            $exactEntries |
                ForEach-Object { [string]$_.PackageState } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $stateText = if ($states.Count -eq 0) { 'Ausente' } else { $states -join ', ' }
        $verified = ($blocking.Count -eq 0)
        return [pscustomobject]@{
            Package = $name
            Category = $category
            Success = $verified
            Status = if ($verified) { 'Removed' } else { 'MissingRemoval' }
            Reason = if ($verified) {
                "Identidad exacta retirada o inactiva; estado final: $stateText"
            }
            else {
                "La identidad exacta que debia retirarse sigue activa; estado final: $stateText"
            }
        }
    }

    if ($package -and $package.PSObject.Properties['IsCheckpoint'] -and $package.IsCheckpoint) {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'Checkpoint'; Reason = 'Aplicado correctamente; puede quedar consolidado por la LCU final' }
    }

    if ($package -and (Test-AIOUpdatePackageInstalled -Package $package -InstalledInventory $AfterInventory)) {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'Identity'; Reason = 'KB o identidad CBS encontrada en el inventario posterior' }
    }

    $pattern = switch ($category) {
        'SSU'        { '(?i)ServicingStack|Package_for_ServicingStack' }
        'LCU'        { '(?i)Package_for_RollupFix' }
        'SafeOS'     { '(?i)Package_for_SafeOSDU|SafeOS' }
        'SecureBoot' { '(?i)SecureBoot|FirmwareUpdate|DBX' }
        'Enablement' { '(?i)Enablement-Package' }
        'DotNet'     { '(?i)Package_for_DotNetRollup|NetFx' }
        'WinPE'      { '(?i)WinPE-' }
        'ESU'        { '(?i)ExtendedSecurity|ESU' }
        'Defender'   { '(?i)Defender|Security-Intelligence|MpEngine' }
        default      { $null }
    }

    if ($pattern) {
        $matches = @($evidenceInventory | Where-Object { [string]$_.PackageName -match $pattern })
        if ($matches.Count -gt 0) {
            return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'Family'; Reason = "Familia CBS confirmada en $($matches.Count) identidad(es) posterior(es)" }
        }
    }

    # Para un OS generico sin KB/identidad verificable no se inventa una prueba.
    # La operacion DISM sigue siendo valida, pero queda marcada como indeterminada.
    if ($category -eq 'OS' -and $state -in @('Success', 'AlreadyPresent', 'Reapplied')) {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'Indeterminate'; Reason = 'Operacion correcta; el paquete OS no expone una identidad estable para correlacion' }
    }

    return [pscustomobject]@{ Package = $name; Category = $category; Success = $false; Status = 'Missing'; Reason = 'No se encontro evidencia CBS posterior del paquete o su familia' }
}

function New-AIOUpdateWimStructureReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [object[]]$BeforeImages,
        [Parameter(Mandatory = $true)] [object[]]$AfterImages,
        [Parameter(Mandatory = $true)] [int[]]$SelectedIndexes,
        [switch]$SingleIndex,
        [version]$ExpectedServicingVersion = [version]'0.0.0.0'
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]
    $expectedCount = if ($SingleIndex) { 1 } else { $BeforeImages.Count }
    if ($AfterImages.Count -ne $expectedCount) {
        [void]$issues.Add("Cantidad de indices: esperada $expectedCount, obtenida $($AfterImages.Count)")
    }

    if ($SingleIndex) {
        $source = @($BeforeImages | Where-Object { $_.ImageIndex -eq $SelectedIndexes[0] } | Select-Object -First 1)
        $destination = @($AfterImages | Where-Object { $_.ImageIndex -eq 1 } | Select-Object -First 1)
        if ($source.Count -eq 0 -or $destination.Count -eq 0) {
            [void]$issues.Add('No se pudo correlacionar el indice unico exportado')
        }
        else {
            if ([string]$source[0].ImageName -ne [string]$destination[0].ImageName) { [void]$issues.Add('El nombre de la edicion exportada cambio') }
            if ((Convert-AIOUpdateArchitectureName -Architecture $source[0].Architecture) -ne (Convert-AIOUpdateArchitectureName -Architecture $destination[0].Architecture)) { [void]$issues.Add('La arquitectura del indice exportado cambio') }
            if ([version]$destination[0].Version -lt [version]$source[0].Version) { [void]$issues.Add('La version del indice exportado disminuyo') }
            if ($ExpectedServicingVersion -ne [version]'0.0.0.0' -and -not (Test-AIOUpdateServicingVersionAtLeast -Actual ([version]$destination[0].Version) -Expected $ExpectedServicingVersion)) {
                [void]$issues.Add("Version final $($destination[0].Version) inferior a la evidencia CBS $ExpectedServicingVersion")
            }
            $displayName = Format-AIOUpdateImageDisplayName -ImageName ([string]$destination[0].ImageName) -Architecture $destination[0].Architecture
            [void]$details.Add("Indice final 1: $displayName")
            [void]$details.Add("Version final de imagen: $($destination[0].Version)")
            if ($ExpectedServicingVersion -ne [version]'0.0.0.0') {
                [void]$details.Add("Familia CBS validada    : $ExpectedServicingVersion")
            }
        }
    }
    else {
        foreach ($source in $BeforeImages) {
            $destination = @($AfterImages | Where-Object { $_.ImageIndex -eq $source.ImageIndex } | Select-Object -First 1)
            if ($destination.Count -eq 0) { [void]$issues.Add("Falta el indice $($source.ImageIndex)"); continue }
            if ([string]$source.ImageName -ne [string]$destination[0].ImageName) { [void]$issues.Add("Cambio de nombre en indice $($source.ImageIndex)") }
            if ((Convert-AIOUpdateArchitectureName -Architecture $source.Architecture) -ne (Convert-AIOUpdateArchitectureName -Architecture $destination[0].Architecture)) { [void]$issues.Add("Cambio de arquitectura en indice $($source.ImageIndex)") }
            if ([version]$destination[0].Version -lt [version]$source.Version) { [void]$issues.Add("La version disminuyo en indice $($source.ImageIndex)") }
            $displayName = Format-AIOUpdateImageDisplayName -ImageName ([string]$destination[0].ImageName) -Architecture $destination[0].Architecture
            [void]$details.Add("Indice $($source.ImageIndex): $displayName | Version final de imagen: $($destination[0].Version)")
        }
        if ($ExpectedServicingVersion -ne [version]'0.0.0.0') {
            foreach ($index in $SelectedIndexes) {
                $destination = @($AfterImages | Where-Object { $_.ImageIndex -eq $index } | Select-Object -First 1)
                if ($destination.Count -gt 0 -and -not (Test-AIOUpdateServicingVersionAtLeast -Actual ([version]$destination[0].Version) -Expected $ExpectedServicingVersion)) {
                    [void]$issues.Add("Indice ${index}: version $($destination[0].Version) inferior a la evidencia CBS $ExpectedServicingVersion")
                }
            }
        }
    }

    return [pscustomobject]@{
        Kind            = 'WimStructure'
        Target          = $Target
        Phase           = 'Final'
        Success         = ($issues.Count -eq 0)
        Reason          = if ($issues.Count -eq 0) { 'Estructura, ediciones, arquitectura y version final verificadas' } else { $issues -join '; ' }
        BeforeCount     = $BeforeImages.Count
        AfterCount      = $AfterImages.Count
        BeforeActive    = 0
        AfterActive     = 0
        NewPackages     = @()
        RetiredPackages = @()
        Failed          = $issues.Count
        Details         = [string[]]($details.ToArray())
        ExpectedServicingVersion = $ExpectedServicingVersion
        Timestamp       = Get-Date
    }
}

function New-AIOUpdateVerificationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [string]$Phase,
        [Parameter(Mandatory = $true)] [object[]]$Before,
        [Parameter(Mandatory = $true)] [object[]]$After,
        [AllowNull()] [object[]]$OperationResults
    )

    $beforeAllNames = @($Before | ForEach-Object { [string]$_.PackageName } | Where-Object { $_ })
    $afterAllNames = @($After | ForEach-Object { [string]$_.PackageName } | Where-Object { $_ })
    $beforeActive = @($Before | Where-Object { $_.PackageState -match '(?i)^Installed$|^Install ?Pending$' })
    $afterActive = @($After | Where-Object { $_.PackageState -match '(?i)^Installed$|^Install ?Pending$' })
    $afterActiveNames = @($afterActive | ForEach-Object { [string]$_.PackageName } | Where-Object { $_ })

    $newPackages = @($afterActiveNames | Where-Object { $_ -notin $beforeAllNames } | Sort-Object -Unique)
    $retiredPackages = @($beforeAllNames | Where-Object { $_ -notin $afterAllNames } | Sort-Object -Unique)
    $operations = @($OperationResults)
    $failedOps = @($operations | Where-Object { $_ -and $_.Result -and -not $_.Result.Success })
    $inventoryReadable = ($Before.Count -eq 0 -or $After.Count -gt 0)

    $semanticEvidence = @(
        $operations |
            Where-Object { $_ -and $_.Result -and $_.Result.Success } |
            ForEach-Object { Get-AIOUpdateSemanticPackageEvidence -Operation $_ -AfterInventory $After }
    )
    $missingExpected = @($semanticEvidence | Where-Object { -not $_.Success })
    $indeterminate = @($semanticEvidence | Where-Object { $_.Status -eq 'Indeterminate' })
    $rejuvWarnings = @($semanticEvidence | Where-Object { $_.Status -eq 'NeutralRejuvPreserved' })
    $verifiedExpected = @($semanticEvidence | Where-Object { $_.Success -and $_.Status -notin @('NotApplicable', 'Indeterminate') })
    Update-AIOUpdateServicingBuildRelationsFromInventory -Inventory $After
    $observedVersion = Get-AIOUpdateObservedServicingVersion -Inventory $After

    $success = ($failedOps.Count -eq 0 -and $inventoryReadable -and $missingExpected.Count -eq 0)
    $reason = if ($failedOps.Count -gt 0) {
        "$($failedOps.Count) operacion(es) DISM fallaron"
    }
    elseif (-not $inventoryReadable) {
        'El inventario posterior esta vacio o no pudo leerse'
    }
    elseif ($missingExpected.Count -gt 0) {
        "$($missingExpected.Count) paquete(s) sin evidencia semantica posterior"
    }
    elseif ($indeterminate.Count -gt 0) {
        'Operaciones correctas; algunas identidades OS no permiten correlacion exacta'
    }
    elseif ($rejuvWarnings.Count -gt 0) {
        'Operaciones, identidades esperadas e inventario verificados'
    }
    elseif ($retiredPackages.Count -gt 0) {
        'Operaciones, identidades esperadas e inventario verificados; hubo supersedencia normal'
    }
    else {
        'Operaciones, identidades esperadas e inventario verificados'
    }

    return [pscustomobject]@{
        Kind             = 'PackageInventory'
        Target           = $Target
        Phase            = $Phase
        Success          = $success
        Reason           = $reason
        BeforeCount      = $Before.Count
        AfterCount       = $After.Count
        BeforeActive     = $beforeActive.Count
        AfterActive      = $afterActive.Count
        NewPackages      = $newPackages
        RetiredPackages  = $retiredPackages
        SemanticEvidence = $semanticEvidence
        VerifiedExpected = $verifiedExpected
        MissingExpected  = $missingExpected
        Indeterminate    = $indeterminate
        RejuvWarnings    = $rejuvWarnings
        ObservedServicingVersion = $observedVersion
        Failed           = $failedOps.Count
        Timestamp        = Get-Date
    }
}

function Write-AIOUpdateVerificationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Report
    )

    $status = if ($Report.Success) { 'VERIFICADO' } else { 'ERROR' }
    $color = if ($Report.Success) { 'Green' } else { 'Red' }
    if ($Report.PSObject.Properties['Kind'] -and $Report.Kind -eq 'WimStructure') {
        Write-Host ("   [{0}] {1} - {2}: indices {3} -> {4}" -f $status, $Report.Target, $Report.Phase, $Report.BeforeCount, $Report.AfterCount) -ForegroundColor $color
        Write-Host "      $($Report.Reason)" -ForegroundColor DarkGray
        foreach ($detail in @($Report.Details)) { Write-Host "      $detail" -ForegroundColor DarkGray }
        return
    }

    if ($Report.PSObject.Properties['Kind'] -and $Report.Kind -eq 'SetupLanguagePreservation') {
        Write-Host ("   [{0}] {1} - {2}: idiomas de Windows Setup" -f $status, $Report.Target, $Report.Phase) -ForegroundColor $color
        Write-Host "      $($Report.Reason)" -ForegroundColor DarkGray
        foreach ($detail in @($Report.Details)) { Write-Host "      $detail" -ForegroundColor DarkGray }
        return
    }

    $summary = "   [{0}] {1} - {2}: catalogo {3} -> {4} | activos {5} -> {6}" -f $status, $Report.Target, $Report.Phase, $Report.BeforeCount, $Report.AfterCount, $Report.BeforeActive, $Report.AfterActive
    Write-Host $summary -ForegroundColor $color
    Write-Host "      $($Report.Reason)" -ForegroundColor DarkGray
    if ($Report.PSObject.Properties['VerifiedExpected']) {
        Write-Host "      Evidencias semanticas confirmadas: $(@($Report.VerifiedExpected).Count)" -ForegroundColor DarkGray
    }
    if ($Report.PSObject.Properties['MissingExpected'] -and @($Report.MissingExpected).Count -gt 0) {
        foreach ($missing in @($Report.MissingExpected)) {
            Write-Host "      [FALTA] $($missing.Package): $($missing.Reason)" -ForegroundColor Red
        }
    }
    if ($Report.PSObject.Properties['ObservedServicingVersion'] -and $Report.ObservedServicingVersion -ne [version]'0.0.0.0') {
        Write-Host "      Familia CBS observada      : $($Report.ObservedServicingVersion)" -ForegroundColor DarkGray
    }
    if ($Report.NewPackages.Count -gt 0) {
        Write-Host "      Paquetes nuevos detectados: $($Report.NewPackages.Count)" -ForegroundColor DarkGray
    }
    if ($Report.RetiredPackages.Count -gt 0) {
        Write-Host "      Paquetes retirados/consolidados por supersedencia: $($Report.RetiredPackages.Count)" -ForegroundColor DarkGray
    }
}


function Write-AIOUpdateConsolidatedRejuvSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Reports
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($report in @($Reports | Where-Object {
        $_.Kind -eq 'PackageInventory' -and
        $_.Phase -eq 'PostCommit' -and
        $_.Target -like 'boot.wim*'
    })) {
        foreach ($warning in @($report.RejuvWarnings)) {
            [void]$entries.Add([pscustomobject]@{
                Package = [string]$warning.Package
                Target  = [string]$report.Target
            })
        }
    }

    if ($entries.Count -eq 0) { return }

    $uniquePackages = @($entries | Select-Object -ExpandProperty Package -Unique | Sort-Object)
    $uniqueTargets = @($entries | Select-Object -ExpandProperty Target -Unique | Sort-Object)

    Write-Host ''
    Write-Host '   [AVISO CONSOLIDADO] WinPE-Rejuv neutro' -ForegroundColor Yellow
    Write-Host ("      CBS conservo o restablecio {0} identidad(es) neutra(s) en {1} indice(s)." -f $uniquePackages.Count, $uniqueTargets.Count) -ForegroundColor DarkGray
    Write-Host ("      Destinos: {0}" -f ($uniqueTargets -join ', ')) -ForegroundColor DarkGray
    foreach ($package in $uniquePackages) {
        Write-Host "      - $package" -ForegroundColor DarkGray
    }

    Write-AIOUpdateLog -Level WARN -Message ("Aviso consolidado WinPE-Rejuv: {0} identidad(es) neutra(s) conservadas/restablecidas en {1}." -f $uniquePackages.Count, ($uniqueTargets -join ', '))
}

function Copy-AIOUpdateFileWithBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [switch]$OnlyIfNewer
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $null }

    $copy = $true
    if ($OnlyIfNewer -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        try {
            $sourceInfo = Get-Item -LiteralPath $Source
            $destinationInfo = Get-Item -LiteralPath $Destination
            $sourceVersionText = [string]$sourceInfo.VersionInfo.FileVersion
            $destinationVersionText = [string]$destinationInfo.VersionInfo.FileVersion
            $sourceVersion = $null
            $destinationVersion = $null

            if (-not [string]::IsNullOrWhiteSpace($sourceVersionText)) {
                $normalized = ($sourceVersionText -replace '[^0-9.]', '').Trim('.')
                if ($normalized) { [void][version]::TryParse($normalized, [ref]$sourceVersion) }
            }
            if (-not [string]::IsNullOrWhiteSpace($destinationVersionText)) {
                $normalized = ($destinationVersionText -replace '[^0-9.]', '').Trim('.')
                if ($normalized) { [void][version]::TryParse($normalized, [ref]$destinationVersion) }
            }

            if ($null -ne $sourceVersion -and $null -ne $destinationVersion -and $sourceVersion -ne $destinationVersion) {
                $copy = ($sourceVersion -gt $destinationVersion)
            }
            else {
                $copy = ($sourceInfo.LastWriteTimeUtc -gt $destinationInfo.LastWriteTimeUtc)
            }
        }
        catch {
            $copy = $true
        }
    }

    if (-not $copy) {
        return [pscustomobject]@{
            Source = $Source
            Destination = $Destination
            Copied = $false
            Reason = 'Destino igual o mas reciente'
        }
    }

    $sourceHash = Get-AIOUpdateFileSha256 -Path $Source
    $destinationExisted = Test-Path -LiteralPath $Destination -PathType Leaf
    $preflightPath = Get-AIOUpdatePreflightBackupPath -Destination $Destination
    $preflightState = Get-AIOUpdatePreflightPathState -Destination $Destination

    if ($destinationExisted -and -not $preflightPath -and -not $preflightState.KnownNew) {
        throw "El archivo existente '$Destination' no esta cubierto por Preflight ni fue registrado explicitamente como creado por esta sesion; no se reemplazara."
    }

    $verifier = {
        param($candidate)
        $destinationHash = Get-AIOUpdateFileSha256 -Path $candidate
        if ($destinationHash -ne $sourceHash) {
            throw "La copia no coincide por SHA-256: '$candidate'."
        }
    }.GetNewClosure()

    [void](Invoke-AIOUpdateAtomicReplacement -Source $Source -Destination $Destination -Context "Copiando $([System.IO.Path]::GetFileName($Destination))" -Verifier $verifier)
    $destinationHash = Get-AIOUpdateFileSha256 -Path $Destination

    $registeredAsSessionCreated = $false
    if (-not $destinationExisted -and -not $preflightPath) {
        $registeredAsSessionCreated = Register-AIOUpdateSessionCreatedPath -Path $Destination -Source $Source -Reason 'Creado por Copy-AIOUpdateFileWithBackup'
        if ($preflightState.CoveredSurface -and -not $registeredAsSessionCreated) {
            throw "El archivo nuevo '$Destination' fue copiado, pero no pudo registrarse como creado por la sesion."
        }
    }

    return [pscustomobject]@{
        Source          = $Source
        Destination     = $Destination
        Copied          = $true
        Hash            = $destinationHash
        SourceHash      = $sourceHash
        DestinationHash = $destinationHash
        Verified        = $true
        BackupPath      = $preflightPath
        BackupType      = if ($preflightPath) { 'Preflight' } elseif ($destinationExisted -and $preflightState.KnownNew) { 'SessionCreated' } elseif ($registeredAsSessionCreated) { 'SessionCreated' } else { 'NotRequired' }
        DuplicateCopy   = $false
        Reason          = if ($preflightPath) {
            'Copiado y verificado; restauracion cubierta por Preflight'
        }
        elseif ($destinationExisted -and $preflightState.KnownNew) {
            'Archivo previamente registrado como creado por esta sesion; reemplazo permitido'
        }
        elseif ($registeredAsSessionCreated) {
            'Archivo nuevo registrado explicitamente como creado por esta sesion'
        }
        else {
            'Archivo nuevo fuera de la superficie cubierta por Preflight'
        }
    }
}

function Get-AIOUpdateWinREPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$Build,
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    $hasSafeOS = (Get-AIOUpdatePackages -Inventory $Inventory -Category @('SafeOS')).Count -gt 0
    $includeLCU = $false
    $reason = ''

    # Politica automatica alineada con el flujo moderno de mantenimiento:
    # - Windows 11 anterior a 26052: se admite la LCU en WinRE.
    # - 26052 o posterior: SafeOS mantiene WinRE; no se agrega la LCU completa.
    # - En otros escenarios no se fuerza la LCU y se prioriza SafeOS DU.
    if ($Build -ge 22000 -and $Build -lt 26052) {
        $includeLCU = $true
        $reason = 'Automatico: Windows 11 build anterior a 26052; se integrara la LCU en WinRE.'
    }
    elseif ($Build -ge 26052) {
        $includeLCU = $false
        $reason = if ($hasSafeOS) {
            'Automatico: SafeOS disponible y build 26052 o posterior; no se integra la LCU completa en WinRE.'
        }
        else {
            'Automatico: build 26052 o posterior; no se integra la LCU completa en WinRE.'
        }
    }
    else {
        $includeLCU = $false
        $reason = if ($hasSafeOS) {
            'Automatico: se prioriza SafeOS DU; no se fuerza la LCU en WinRE.'
        }
        else {
            'Automatico: no se fuerza la LCU en WinRE; se recomienda proporcionar SafeOS DU.'
        }
    }

    return [pscustomobject]@{
        IncludeLCU = $includeLCU
        HasSafeOS  = $hasSafeOS
        Mode       = 'Auto'
        Reason     = $reason
    }
}

function Get-AIOUpdateWinREFromInstallWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$InstallMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $mounted = $false
    try {
        Mount-AIOUpdateImage -ImagePath $InstallWim -Index $Index -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Extrayendo winre.wim del indice $Index"
        $mounted = $true
        $source = Join-Path $InstallMount 'Windows\System32\Recovery\winre.wim'
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "El indice $Index no contiene Windows\System32\Recovery\winre.wim."
        }
        Copy-Item -LiteralPath $source -Destination $Destination -Force -ErrorAction Stop
        [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context 'Cierre del montaje usado para extraer WinRE')
        $mounted = $false
        return $Destination
    }
    finally {
        if ($mounted) {
            [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context 'Descarte de emergencia al extraer WinRE' -NoThrow)
        }
    }
}


function Update-AIOUpdateWinRE {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourceWinRE,
        [Parameter(Mandatory = $true)] [string]$DestinationWinRE,
        [Parameter(Mandatory = $true)] [string]$WinREMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [psobject]$Policy,
        [Parameter(Mandatory = $true)] [System.Collections.IList]$VerificationReports
    )

    Copy-Item -LiteralPath $SourceWinRE -Destination $DestinationWinRE -Force -ErrorAction Stop
    $image = @(Get-AIOUpdateImageMetadata -ImagePath $DestinationWinRE | Select-Object -First 1)[0]
    $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
    $build = ([version]$image.Version).Build
    $mounted = $false

    try {
        Mount-AIOUpdateImage -ImagePath $DestinationWinRE -Index 1 -MountPath $WinREMount -ScratchPath $ScratchPath -Context 'Montando winre.wim para mantenimiento'
        $mounted = $true
        $baseline = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
        $operations = New-Object System.Collections.Generic.List[object]

        $winrePackages = New-Object System.Collections.Generic.List[object]
        foreach ($package in @(
            Get-AIOUpdateEffectiveSsuPackages -Inventory $Inventory |
                Where-Object { (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $architecture -Build $build -ImageName 'WinRE').Compatible }
        )) { [void]$winrePackages.Add($package) }

        if ($Policy.IncludeLCU) {
            foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @('LCU') -Architecture $architecture -Build $build -ImageName 'WinRE')) {
                [void]$winrePackages.Add($package)
            }
        }
        foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @('SafeOS') -Architecture $architecture -Build $build -ImageName 'WinRE')) {
            [void]$winrePackages.Add($package)
        }

        $orderedWinRE = Resolve-AIOUpdateCbsPackageOrder -Packages ([object[]]($winrePackages.ToArray())) -Context 'WinRE'
        foreach ($package in $orderedWinRE) {
            foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $WinREMount -Packages @($package) -ScratchPath $ScratchPath -Context "WinRE: integrando $($package.Category)" -AllowNotApplicable -InstalledInventory $baseline -DependencyContext 'WinRE')) {
                [void]$operations.Add($entry)
            }
        }

        [void](Invoke-AIOUpdateCleanup -MountPath $WinREMount -ScratchPath $ScratchPath -Context 'WinRE: limpieza y ResetBase' -ResetBase -WarningOnly)
        $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
        $preReport = New-AIOUpdateVerificationReport -Target 'winre.wim' -Phase 'PreCommit' -Before $baseline -After $after -OperationResults ([object[]]($operations.ToArray()))
        [void]$VerificationReports.Add($preReport)
        Write-AIOUpdateVerificationReport -Report $preReport

        [void](Dismount-AIOUpdateImage -MountPath $WinREMount -Mode Commit -Context 'Guardando winre.wim actualizado')
        $mounted = $false

        $optimized = [System.IO.Path]::ChangeExtension($DestinationWinRE, '.optimized.wim')
        Remove-Item -LiteralPath $optimized -Force -ErrorAction SilentlyContinue
        [void](Invoke-AIOUpdateDism -Arguments @(
            '/Export-Image',
            "/SourceImageFile:$DestinationWinRE",
            '/SourceIndex:1',
            "/DestinationImageFile:$optimized",
            '/Compress:max',
            '/CheckIntegrity',
            '/Bootable',
            "/ScratchDir:$ScratchPath"
        ) -Context 'Optimizando winre.wim actualizado')
        Move-Item -LiteralPath $optimized -Destination $DestinationWinRE -Force

        Mount-AIOUpdateImage -ImagePath $DestinationWinRE -Index 1 -MountPath $WinREMount -ScratchPath $ScratchPath -Context 'Verificando winre.wim guardado' -ReadOnly
        $mounted = $true
        $post = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
        $postReport = New-AIOUpdateVerificationReport -Target 'winre.wim' -Phase 'PostCommit' -Before $baseline -After $post -OperationResults ([object[]]($operations.ToArray()))
        [void]$VerificationReports.Add($postReport)
        Write-AIOUpdateVerificationReport -Report $postReport
        [void](Dismount-AIOUpdateImage -MountPath $WinREMount -Mode Discard -Context 'Cerrando verificacion de winre.wim')
        $mounted = $false

        return [pscustomobject]@{
            Path   = $DestinationWinRE
            Hash   = (Get-FileHash -LiteralPath $DestinationWinRE -Algorithm SHA256).Hash
            Policy = $Policy
        }
    }
    finally {
        if ($mounted) {
            [void](Dismount-AIOUpdateImage -MountPath $WinREMount -Mode Discard -Context 'Descarte de emergencia de winre.wim' -NoThrow)
        }
    }
}


function Update-AIOUpdateInstallWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int[]]$Indexes,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$InstallMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [AllowNull()] [psobject]$ServicedWinRE,
        [switch]$Cleanup,
        [switch]$ResetBase,
        [Parameter(Mandatory = $true)] [System.Collections.IList]$VerificationReports
    )

    $imageMetadata = @(Get-AIOUpdateImageMetadata -ImagePath $InstallWim)
    $position = 0
    foreach ($index in $Indexes) {
        $position++
        $image = $imageMetadata | Where-Object { [int]$_.ImageIndex -eq [int]$index } | Select-Object -First 1
        if (-not $image) { throw "No se encontro metadata del indice $index." }
        $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
        $build = ([version]$image.Version).Build
        $mounted = $false

        try {
            Write-Host "`n=======================================================" -ForegroundColor DarkCyan
            Write-Host " INSTALL.WIM $position/$($Indexes.Count) - INDICE $index" -ForegroundColor Cyan
            Write-Host "=======================================================" -ForegroundColor DarkCyan

            Mount-AIOUpdateImage -ImagePath $InstallWim -Index $index -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Montando install.wim indice $index"
            $mounted = $true
            $baseline = @(Get-AIOUpdateMountedPackageInventory -MountPath $InstallMount -Strict)
            $operations = New-Object System.Collections.Generic.List[object]

            if ($ServicedWinRE) {
                $winreTarget = Join-Path $InstallMount 'Windows\System32\Recovery\winre.wim'
                if (Test-Path -LiteralPath $winreTarget) { attrib -R -S -H $winreTarget 2>$null }
                Copy-Item -LiteralPath $ServicedWinRE.Path -Destination $winreTarget -Force -ErrorAction Stop
            }

            $installPackages = New-Object System.Collections.Generic.List[object]
            foreach ($category in @('SSU', 'SecureBoot', 'OS', 'Enablement', 'ESU', 'LCU', 'DotNet')) {
                foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @($category) -Architecture $architecture -Build $build -ImageName $image.ImageName)) {
                    [void]$installPackages.Add($package)
                }
            }
            $orderedInstallPackages = Resolve-AIOUpdateCbsPackageOrder -Packages ([object[]]($installPackages.ToArray())) -Context "install.wim indice $index"
            foreach ($package in $orderedInstallPackages) {
                foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $InstallMount -Packages @($package) -ScratchPath $ScratchPath -Context "Install indice ${index}: $($package.Category)" -AllowNotApplicable -InstalledInventory $baseline -DependencyContext "install.wim indice $index")) {
                    [void]$operations.Add($entry)
                }
            }

            $defender = Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @('Defender') -Architecture $architecture -Build $build -ImageName $image.ImageName
            foreach ($entry in @(Apply-AIOUpdateDefenderPackages -MountPath $InstallMount -Packages $defender -ScratchRoot $script:AIOUpdateSessionRoot -DismScratch $ScratchPath -InstalledInventory $baseline)) {
                [void]$operations.Add($entry)
            }

            if ($Cleanup) {
                [void](Invoke-AIOUpdateCleanup -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Install indice ${index}: limpieza de componentes" -ResetBase:$ResetBase -WarningOnly)
            }

            $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $InstallMount -Strict)
            $preReport = New-AIOUpdateVerificationReport -Target "install.wim indice $index" -Phase 'PreCommit' -Before $baseline -After $after -OperationResults ([object[]]($operations.ToArray()))
            [void]$VerificationReports.Add($preReport)
            Write-AIOUpdateVerificationReport -Report $preReport
            if (-not $preReport.Success) { throw "Fallo la verificacion previa al commit del indice $index." }

            [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Commit -Context "Guardando install.wim indice $index")
            $mounted = $false

            Mount-AIOUpdateImage -ImagePath $InstallWim -Index $index -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Verificando install.wim indice $index" -ReadOnly
            $mounted = $true
            $post = @(Get-AIOUpdateMountedPackageInventory -MountPath $InstallMount -Strict)
            $postReport = New-AIOUpdateVerificationReport -Target "install.wim indice $index" -Phase 'PostCommit' -Before $baseline -After $post -OperationResults ([object[]]($operations.ToArray()))
            [void]$VerificationReports.Add($postReport)
            Write-AIOUpdateVerificationReport -Report $postReport

            if ($ServicedWinRE) {
                $embeddedWinRE = Join-Path $InstallMount 'Windows\System32\Recovery\winre.wim'
                $embeddedHash = (Get-FileHash -LiteralPath $embeddedWinRE -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($embeddedHash -ne $ServicedWinRE.Hash) {
                    throw "El hash de winre.wim reinyectado no coincide en el indice $index."
                }
                Write-Host '   [VERIFICADO] winre.wim reinyectado coincide por SHA-256.' -ForegroundColor Green
            }

            [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context "Cerrando verificacion del indice $index")
            $mounted = $false
        }
        finally {
            if ($mounted) {
                [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context "Descarte de emergencia de install.wim indice $index" -NoThrow)
            }
        }
    }
}

function Export-AIOUpdateSingleInstallIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int]$SourceIndex,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchPath
    )

    $exportPath = Join-Path $StagingRoot ("install.single.{0}.wim" -f $SourceIndex)
    if (Test-Path -LiteralPath $exportPath) {
        Remove-Item -LiteralPath $exportPath -Force -ErrorAction Stop
    }

    Write-Host "`nExportando el indice $SourceIndex como install.wim de indice unico..." -ForegroundColor Cyan
    [void](Invoke-AIOUpdateDism -Arguments @(
        '/Export-Image',
        "/SourceImageFile:$InstallWim",
        "/SourceIndex:$SourceIndex",
        "/DestinationImageFile:$exportPath",
        '/Compress:max',
        '/CheckIntegrity',
        "/ScratchDir:$ScratchPath"
    ) -Context "Exportando install.wim con el unico indice $SourceIndex")

    $exportedImages = @(Get-AIOUpdateImageMetadata -ImagePath $exportPath)
    if ($exportedImages.Count -ne 1 -or [int]$exportedImages[0].ImageIndex -ne 1) {
        throw 'La verificacion del install.wim exportado no devolvio exactamente un indice.'
    }

    $preflightPath = Get-AIOUpdatePreflightBackupPath -Destination $InstallWim
    if (-not $preflightPath) {
        throw 'No se encontro la copia Preflight de install.wim; no se reemplazara el WIM original.'
    }

    $verifier = {
        param($candidate)
        $finalImages = @(Get-AIOUpdateImageMetadata -ImagePath $candidate)
        if ($finalImages.Count -ne 1 -or [int]$finalImages[0].ImageIndex -ne 1) {
            throw 'El install.wim final no contiene exactamente un indice.'
        }
    }

    [void](Invoke-AIOUpdateAtomicReplacement -Source $exportPath -Destination $InstallWim -Context 'Reemplazando install.wim por la exportacion de indice unico' -MoveSource -Verifier $verifier)
    $finalImages = @(Get-AIOUpdateImageMetadata -ImagePath $InstallWim)

    Write-AIOUpdateLog -Level INFO -Message "install.wim reducido al indice seleccionado $SourceIndex; indice final 1. Restauracion maestra: $preflightPath"
    return [pscustomobject]@{
        Applied       = $true
        OriginalIndex = $SourceIndex
        FinalIndex    = 1
        ImageName     = [string]$finalImages[0].ImageName
        Version       = [string]$finalImages[0].Version
        Architecture  = (Convert-AIOUpdateArchitectureName -Architecture $finalImages[0].Architecture)
        BackupPath    = $preflightPath
        BackupType    = 'Preflight'
        DuplicateCopy = $false
    }
}

function Save-AIOUpdateBootFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string[]]$Candidates,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [hashtable]$CaptureTable
    )

    foreach ($relative in $Candidates) {
        $source = Join-Path $MountPath $relative
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Join-Path $CaptureRoot ($Key + '_' + [System.IO.Path]::GetFileName($source))
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
            $CaptureTable[$Key] = $destination
            return
        }
    }
}


function Get-AIOUpdateBootSetupDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BootWim,
        [Parameter(Mandatory = $true)] [string]$BootMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [int]$Build
    )

    $captured = @{}
    if ($Build -lt 26100 -or -not (Test-Path -LiteralPath $BootWim -PathType Leaf)) {
        return $captured
    }

    $images = @(Get-AIOUpdateImageMetadata -ImagePath $BootWim)
    if ($images.Count -eq 0) { return $captured }
    $setupIndex = if (@($images | Where-Object { [int]$_.ImageIndex -eq 2 }).Count -gt 0) {
        2
    }
    else {
        [int](($images | Sort-Object ImageIndex -Descending | Select-Object -First 1).ImageIndex)
    }

    $mounted = $false
    try {
        Mount-AIOUpdateImage -ImagePath $BootWim -Index $setupIndex -MountPath $BootMount -ScratchPath $ScratchPath -Context 'Leyendo dependencias SetupDU desde boot.wim' -ReadOnly
        $mounted = $true
        Initialize-AIOUpdateDirectory -Path $CaptureRoot
        Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\System32\ServicingCommon.dll', 'sources\ServicingCommon.dll') -CaptureRoot $CaptureRoot -Key 'ServicingCommonDll' -CaptureTable $captured
        Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\System32\migwiz\unbcl.dll', 'sources\unbcl.dll') -CaptureRoot $CaptureRoot -Key 'UnbclDll' -CaptureTable $captured
    }
    finally {
        if ($mounted) {
            [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Discard -Context 'Cerrando lectura de dependencias SetupDU')
        }
    }

    return $captured
}


function Update-AIOUpdateBootWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BootWim,
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$BootMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$SetupDUPackages,
        [switch]$IntegrateSetupDU,
        [Parameter(Mandatory = $true)] [System.Collections.IList]$VerificationReports
    )

    Initialize-AIOUpdateDirectory -Path $CaptureRoot -Empty
    $setupIndex = if (@($Images | Where-Object { [int]$_.ImageIndex -eq 2 }).Count -gt 0) { 2 } else { [int](($Images | Sort-Object ImageIndex -Descending | Select-Object -First 1).ImageIndex) }
    $captured = @{}
    $setupExtractRoot = $null

    if ($IntegrateSetupDU -and @($SetupDUPackages).Count -gt 0) {
        $setupExtractRoot = Join-Path $StagingRoot 'SetupDU_Boot'
        Expand-AIOUpdateSetupDU -Packages $SetupDUPackages -Destination $setupExtractRoot
    }

    $position = 0
    foreach ($image in $Images) {
        $position++
        $index = [int]$image.ImageIndex
        $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
        $build = ([version]$image.Version).Build
        $mounted = $false

        try {
            Write-Host "`n=======================================================" -ForegroundColor DarkCyan
            Write-Host " BOOT.WIM $position/$($Images.Count) - INDICE $index" -ForegroundColor Cyan
            Write-Host "=======================================================" -ForegroundColor DarkCyan

            Mount-AIOUpdateImage -ImagePath $BootWim -Index $index -MountPath $BootMount -ScratchPath $ScratchPath -Context "Montando boot.wim indice $index"
            $mounted = $true
            $baseline = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
            $operations = New-Object System.Collections.Generic.List[object]

            $bootPackages = New-Object System.Collections.Generic.List[object]
            foreach ($package in @(
                Get-AIOUpdateEffectiveSsuPackages -Inventory $Inventory |
                    Where-Object { (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $architecture -Build $build -ImageName $image.ImageName).Compatible }
            )) { [void]$bootPackages.Add($package) }

            foreach ($category in @('WinPE', 'Enablement', 'LCU')) {
                foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @($category) -Architecture $architecture -Build $build -ImageName $image.ImageName)) {
                    [void]$bootPackages.Add($package)
                }
            }

            $orderedBootPackages = Resolve-AIOUpdateCbsPackageOrder -Packages ([object[]]($bootPackages.ToArray())) -Context "boot.wim indice $index"
            $rejuvPrepared = $false
            $currentInventory = $baseline
            foreach ($package in $orderedBootPackages) {
                if ($package.Category -eq 'LCU' -and -not $rejuvPrepared) {
                    $currentInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
                    foreach ($entry in @(Remove-AIOUpdateWinPERejuv -MountPath $BootMount -ScratchPath $ScratchPath -Build $build -InstalledInventory $currentInventory)) {
                        [void]$operations.Add($entry)
                    }
                    $currentInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
                    $rejuvPrepared = $true
                }

                foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $BootMount -Packages @($package) -ScratchPath $ScratchPath -Context "Boot indice ${index}: $($package.Category)" -AllowNotApplicable -InstalledInventory $currentInventory -DependencyContext "boot.wim indice $index")) {
                    [void]$operations.Add($entry)
                }
            }

            if ($index -eq $setupIndex -and $setupExtractRoot) {
                # En 26100+ algunos SetupDU esperan estas dependencias aunque no
                # vengan incluidas en el CAB. Se obtienen del propio WinPE.
                if ($build -ge 26100) {
                    $setupDependencies = @(
                        @{ Source = 'Windows\System32\ServicingCommon.dll'; Name = 'ServicingCommon.dll' },
                        @{ Source = 'Windows\System32\migwiz\unbcl.dll'; Name = 'unbcl.dll' }
                    )
                    foreach ($dependency in $setupDependencies) {
                        $alreadyIncluded = @(Get-ChildItem -LiteralPath $setupExtractRoot -Recurse -File -Filter $dependency.Name -ErrorAction SilentlyContinue).Count -gt 0
                        if ($alreadyIncluded) { continue }
                        $sourceDependency = Join-Path $BootMount $dependency.Source
                        if (Test-Path -LiteralPath $sourceDependency -PathType Leaf) {
                            Copy-Item -LiteralPath $sourceDependency -Destination (Join-Path $setupExtractRoot $dependency.Name) -Force -ErrorAction Stop
                            Write-AIOUpdateLog -Level INFO -Message "SetupDU: dependencia agregada desde WinPE: $($dependency.Name)."
                        }
                    }
                }
                $merged = Merge-AIOUpdateSetupDUIntoDirectory -ExtractRoot $setupExtractRoot -DestinationRoot (Join-Path $BootMount 'sources')
                $duResult = [pscustomobject]@{ Success = $true; State = 'Success'; ExitCode = 0; UnsignedCode = [uint32]0; Context = 'SetupDU integrado en boot.wim Setup' }
                [void]$operations.Add([pscustomobject]@{
                    Package = [pscustomobject]@{ Name = "SetupDU ($merged archivos)"; Category = 'SetupDU' }
                    Result  = $duResult
                })
                Write-AIOUpdateLog -Level INFO -Message "SetupDU integrado en boot.wim indice ${index}: $merged archivo(s)."
            }

            [void](Invoke-AIOUpdateCleanup -MountPath $BootMount -ScratchPath $ScratchPath -Context "Boot indice ${index}: limpieza WinPE" -ResetBase -WarningOnly)

            if ($index -eq $setupIndex) {
                Save-AIOUpdateBootDirectory -MountPath $BootMount -RelativePath 'sources' -CaptureRoot $CaptureRoot -Key 'SourcesDirectory' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('sources\ServicingCommon.dll', 'Windows\System32\ServicingCommon.dll') -CaptureRoot $CaptureRoot -Key 'ServicingCommonDll' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('sources\unbcl.dll', 'Windows\System32\migwiz\unbcl.dll') -CaptureRoot $CaptureRoot -Key 'UnbclDll' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('setup.exe') -CaptureRoot $CaptureRoot -Key 'RootSetupExe' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI\bootmgfw.efi') -CaptureRoot $CaptureRoot -Key 'BootMgfwEfi' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI\bootmgr.efi') -CaptureRoot $CaptureRoot -Key 'BootMgrEfi' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI\memtest.efi') -CaptureRoot $CaptureRoot -Key 'MemtestEfi' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI\boot.stl') -CaptureRoot $CaptureRoot -Key 'BootStl' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI\boot.pnd.stl') -CaptureRoot $CaptureRoot -Key 'BootPndStl' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\DVD\EFI\en-US\efisys.bin') -CaptureRoot $CaptureRoot -Key 'EfiSys' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\DVD\EFI\en-US\efisys_noprompt.bin') -CaptureRoot $CaptureRoot -Key 'EfiSysNoPrompt' -CaptureTable $captured

                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI_EX\bootmgfw_EX.efi') -CaptureRoot $CaptureRoot -Key 'BootMgfwExEfi' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\EFI_EX\bootmgr_EX.efi') -CaptureRoot $CaptureRoot -Key 'BootMgrExEfi' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\DVD_EX\EFI\en-US\efisys_EX.bin') -CaptureRoot $CaptureRoot -Key 'EfiSysEx' -CaptureTable $captured
                Save-AIOUpdateBootFile -MountPath $BootMount -Candidates @('Windows\Boot\DVD_EX\EFI\en-US\efisys_noprompt_EX.bin') -CaptureRoot $CaptureRoot -Key 'EfiSysNoPromptEx' -CaptureTable $captured
                Save-AIOUpdateBootDirectory -MountPath $BootMount -RelativePath 'Windows\Boot\FONTS_EX' -CaptureRoot $CaptureRoot -Key 'FontsExDirectory' -CaptureTable $captured
            }

            $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
            $preReport = New-AIOUpdateVerificationReport -Target "boot.wim indice $index" -Phase 'PreCommit' -Before $baseline -After $after -OperationResults ([object[]]($operations.ToArray()))
            [void]$VerificationReports.Add($preReport)
            Write-AIOUpdateVerificationReport -Report $preReport
            if (-not $preReport.Success) { throw "Fallo la verificacion previa al commit de boot.wim indice $index." }

            [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Commit -Context "Guardando boot.wim indice $index")
            $mounted = $false

            Mount-AIOUpdateImage -ImagePath $BootWim -Index $index -MountPath $BootMount -ScratchPath $ScratchPath -Context "Verificando boot.wim indice $index" -ReadOnly
            $mounted = $true
            $post = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
            $postReport = New-AIOUpdateVerificationReport -Target "boot.wim indice $index" -Phase 'PostCommit' -Before $baseline -After $post -OperationResults ([object[]]($operations.ToArray()))
            [void]$VerificationReports.Add($postReport)
            Write-AIOUpdateVerificationReport -Report $postReport

            if ($index -eq $setupIndex) {
                try {
                    $localeVerification = Assert-AIOUpdateSetupLanguagesPreserved -MountPath $BootMount -AllowedLocales @($script:AIOUpdateTrustedLocales.Keys) -Context "Verificacion de idiomas de Setup en boot.wim indice $index"
                    $localeReport = New-AIOUpdateSetupLanguageReport -Target "boot.wim indice $index" -Phase 'PostCommit' -Verification $localeVerification
                    [void]$VerificationReports.Add($localeReport)
                    Write-AIOUpdateVerificationReport -Report $localeReport
                }
                catch {
                    $localeReport = New-AIOUpdateSetupLanguageReport -Target "boot.wim indice $index" -Phase 'PostCommit' -ErrorMessage $_.Exception.Message
                    [void]$VerificationReports.Add($localeReport)
                    Write-AIOUpdateVerificationReport -Report $localeReport
                    throw
                }
            }
            [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Discard -Context "Cerrando verificacion de boot.wim indice $index")
            $mounted = $false
        }
        finally {
            if ($mounted) {
                [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Discard -Context "Descarte de emergencia de boot.wim indice $index" -NoThrow)
            }
        }
    }

    return $captured
}


function New-AIOUpdateSetupLanguageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [string]$Phase,
        [AllowNull()] [psobject]$Verification,
        [AllowNull()] [string]$ErrorMessage
    )

    $success = $null -ne $Verification -and [bool]$Verification.Success -and [string]::IsNullOrWhiteSpace($ErrorMessage)
    $details = New-Object System.Collections.Generic.List[string]
    $verified = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[object]

    if ($success) {
        $locales = @($Verification.Locales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
        $langIniLocales = @($Verification.LangIniLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
        [void]$details.Add("TrustedLocales preservados: $($locales -join ', ')")
        [void]$details.Add("sources\lang.ini: $($langIniLocales -join ', ')")

        foreach ($check in @($Verification.ResourceChecks | Where-Object { $null -ne $_ })) {
            $coreFiles = @($check.CoreFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
            [void]$details.Add("$($check.Locale): $($check.MuiCount) MUI; esenciales: $($coreFiles -join ', ')")
            [void]$verified.Add([pscustomobject]@{
                Package  = "Recursos de Windows Setup $($check.Locale)"
                Category = 'SetupLanguageResources'
                Success  = $true
                Status   = 'Verified'
                Reason   = 'lang.ini y recursos MUI presentes despues del mantenimiento'
            })
        }

        $reason = "TrustedLocales, lang.ini y recursos MUI de Windows Setup preservados: $($locales -join ', ')"
    }
    else {
        $message = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { 'La verificacion de idiomas de Windows Setup no produjo evidencia valida.' } else { $ErrorMessage }
        [void]$details.Add($message)
        [void]$missing.Add([pscustomobject]@{
            Package  = 'TrustedLocales de Windows Setup'
            Category = 'SetupLanguageResources'
            Success  = $false
            Status   = 'Missing'
            Reason   = $message
        })
        $reason = $message
    }

    return [pscustomobject]@{
        Kind                     = 'SetupLanguagePreservation'
        Target                   = $Target
        Phase                    = $Phase
        Success                  = $success
        Reason                   = $reason
        BeforeCount              = 0
        AfterCount               = 0
        BeforeActive             = 0
        AfterActive              = 0
        NewPackages              = [object[]]@()
        RetiredPackages          = [object[]]@()
        SemanticEvidence         = [object[]]$verified.ToArray()
        VerifiedExpected         = [object[]]$verified.ToArray()
        MissingExpected          = [object[]]$missing.ToArray()
        Indeterminate            = [object[]]@()
        RejuvWarnings            = [object[]]@()
        ObservedServicingVersion = [version]'0.0.0.0'
        Failed                   = if ($success) { 0 } else { 1 }
        Details                  = [string[]]$details.ToArray()
        Timestamp                = Get-Date
    }
}


function Assert-AIOUpdateSetupLanguagesPreserved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string[]]$AllowedLocales,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $normalizedLocales = @($AllowedLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($normalizedLocales.Count -eq 0) { throw "${Context}: no hay TrustedLocales para verificar." }

    $langIni = Join-Path $MountPath 'sources\lang.ini'
    $langIniLocales = @(Get-AIOUpdateLocalesFromLangIniPath -Path $langIni | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $missingLangIni = @($normalizedLocales | Where-Object { $_ -notin $langIniLocales })
    if ($missingLangIni.Count -gt 0) {
        throw "${Context}: boot.wim perdio idiomas en sources\lang.ini: $($missingLangIni -join ', ')."
    }

    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($locale in $normalizedLocales) {
        $localeRoot = Join-Path $MountPath "sources\$locale"
        $muiFiles = if (Test-Path -LiteralPath $localeRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $localeRoot -File -Filter '*.mui' -ErrorAction SilentlyContinue)
        }
        else { @() }
        $coreCandidates = @('setup.exe.mui','setupplatform.exe.mui','w32uires.dll.mui','winsetup.dll.mui','spwizres.dll.mui')
        $coreFiles = @($coreCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $localeRoot $_) -PathType Leaf })
        if ($muiFiles.Count -eq 0 -or $coreFiles.Count -eq 0) {
            throw "${Context}: faltan recursos MUI esenciales de Setup para $locale despues de aplicar actualizaciones."
        }
        [void]$checks.Add([pscustomobject]@{ Locale = $locale; MuiCount = $muiFiles.Count; CoreFiles = [string[]]$coreFiles })
    }

    Write-AIOUpdateLog -Level INFO -Message "${Context}: lang.ini y recursos MUI preservados para $($normalizedLocales -join ', ')."
    return [pscustomobject]@{
        Context = $Context
        Locales = [string[]]$normalizedLocales
        LangIniLocales = [string[]]$langIniLocales
        ResourceChecks = [object[]]$checks.ToArray()
        Success = $true
    }
}

function Expand-AIOUpdateSetupDU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    Initialize-AIOUpdateDirectory -Path $Destination -Empty
    foreach ($package in $Packages) {
        if ($package.Extension -eq '.cab') {
            & $script:AIOUpdateExpandPath '-R' '-F:*' $package.FullName $Destination *> $null
            if ($LASTEXITCODE -ne 0) { throw "No se pudo extraer SetupDU '$($package.Name)'." }
        }
        elseif ($package.Extension -eq '.msu') {
            $inner = Join-Path $Destination ('MSU_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Initialize-AIOUpdateDirectory -Path $inner
            & $script:AIOUpdateExpandPath '-F:*.cab' $package.FullName $inner *> $null
            foreach ($cab in @(Get-ChildItem -LiteralPath $inner -Filter '*.cab' -File -ErrorAction SilentlyContinue)) {
                & $script:AIOUpdateExpandPath '-R' '-F:*' $cab.FullName $Destination *> $null
            }
            Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


function Apply-AIOUpdateSetupDU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [AllowNull()] [hashtable]$DependencyFiles
    )

    if (@($Packages).Count -eq 0) {
        return [pscustomobject]@{ Applied = $false; Copied = @(); Verified = $true }
    }

    Write-Host "`n=======================================================" -ForegroundColor DarkCyan
    Write-Host ' APLICANDO SETUP DYNAMIC UPDATE' -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor DarkCyan

    $extractRoot = Join-Path $StagingRoot 'SetupDU_Media'
    Expand-AIOUpdateSetupDU -Packages $Packages -Destination $extractRoot

    if ($DependencyFiles) {
        foreach ($entry in @(
            @{ Key = 'ServicingCommonDll'; Name = 'ServicingCommon.dll' },
            @{ Key = 'UnbclDll'; Name = 'unbcl.dll' }
        )) {
            if (-not $DependencyFiles.ContainsKey($entry.Key)) { continue }
            $alreadyIncluded = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter $entry.Name -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $alreadyIncluded -and (Test-Path -LiteralPath $DependencyFiles[$entry.Key] -PathType Leaf)) {
                Copy-Item -LiteralPath $DependencyFiles[$entry.Key] -Destination (Join-Path $extractRoot $entry.Name) -Force -ErrorAction Stop
                Write-AIOUpdateLog -Level INFO -Message "SetupDU del medio: dependencia agregada: $($entry.Name)."
            }
        }
    }

    $sourcesRoot = Join-Path $MediaRoot 'sources'
    $copied = New-Object System.Collections.Generic.List[object]

    foreach ($file in @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($extractRoot.Length).TrimStart('\')
        if ($relative -match '^(?i)sources[\\/](.+)$') { $relative = $Matches[1] }
        if ($relative -match '(?i)(?:^|[\\/])(update\.mum|update\.cat|WSUSSCAN\.cab)$') { continue }
        if (-not (Test-AIOUpdateLocaleRelativePathAllowed -RelativePath $relative -Surface Sources)) {
            Write-AIOUpdateLog -Level INFO -Message "SetupDU/medio: se omitio idioma ausente del Preflight: $relative"
            continue
        }
        $destination = Join-Path $sourcesRoot $relative
        $copyArgs = @{
            Source      = $file.FullName
            Destination = $destination
        }
        # fuerza los INI; para binarios se evita degradar una version mas nueva.
        if ($file.Extension -ine '.ini') { $copyArgs.OnlyIfNewer = $true }
        $result = Copy-AIOUpdateFileWithBackup @copyArgs
        if ($result) { [void]$copied.Add($result) }
    }

    $failures = @(
        $copied | Where-Object {
            $_.Copied -and (
                -not $_.Verified -or
                -not (Test-Path -LiteralPath $_.Destination -PathType Leaf) -or
                ((Get-FileHash -LiteralPath $_.Destination -Algorithm SHA256).Hash -ne $_.SourceHash)
            )
        }
    )
    if ($failures.Count -gt 0) { throw 'Fallo la verificacion SHA-256 de archivos SetupDU.' }

    return [pscustomobject]@{
        Applied  = $true
        Copied   = [object[]]($copied.ToArray())
        Verified = $true
    }
}


function Sync-AIOUpdateMediaBootFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [hashtable]$CapturedFiles,
        [Parameter(Mandatory = $true)] [string]$Architecture
    )

    if ($CapturedFiles.Count -eq 0) { return @() }
    Write-Host "`nSincronizando Windows Setup y binarios de arranque..." -ForegroundColor Cyan
    $results = New-Object System.Collections.Generic.List[object]
    $efiBootName = if ($Architecture -match '(?i)arm64') { 'bootaa64.efi' } elseif ($Architecture -match '(?i)x86') { 'bootia32.efi' } else { 'bootx64.efi' }

    if ($CapturedFiles.ContainsKey('SourcesDirectory')) {
        foreach ($result in @(Copy-AIOUpdateDirectoryWithBackup `
            -SourceRoot $CapturedFiles['SourcesDirectory'] `
            -DestinationRoot (Join-Path $MediaRoot 'sources') `
            -ExcludePatterns @('^(?i)(install\.(?:wim|esd)|boot\.wim|install\d*\.swm)$') `
            -LocaleSurface Sources)) {
            [void]$results.Add($result)
        }
    }

    if ($CapturedFiles.ContainsKey('RootSetupExe')) {
        $result = Copy-AIOUpdateFileWithBackup -Source $CapturedFiles['RootSetupExe'] -Destination (Join-Path $MediaRoot 'setup.exe')
        if ($result) { [void]$results.Add($result) }
    }

    $useEx = $CapturedFiles.ContainsKey('BootMgfwExEfi')
    $bootMgfwKey = if ($useEx) { 'BootMgfwExEfi' } else { 'BootMgfwEfi' }
    $bootMgrKey = if ($CapturedFiles.ContainsKey('BootMgrExEfi')) { 'BootMgrExEfi' } else { 'BootMgrEfi' }
    $efiSysKey = if ($CapturedFiles.ContainsKey('EfiSysEx')) { 'EfiSysEx' } else { 'EfiSys' }
    $efiNoPromptKey = if ($CapturedFiles.ContainsKey('EfiSysNoPromptEx')) { 'EfiSysNoPromptEx' } else { 'EfiSysNoPrompt' }

    $map = @(
        @{ Key = $bootMgrKey;      Destination = (Join-Path $MediaRoot 'bootmgr.efi') },
        @{ Key = $bootMgfwKey;     Destination = (Join-Path $MediaRoot ("efi\boot\$efiBootName")) },
        @{ Key = 'BootStl';        Destination = (Join-Path $MediaRoot 'efi\microsoft\boot\boot.stl') },
        @{ Key = 'BootPndStl';     Destination = (Join-Path $MediaRoot 'efi\microsoft\boot\boot.pnd.stl') },
        @{ Key = 'MemtestEfi';     Destination = (Join-Path $MediaRoot 'efi\microsoft\boot\memtest.efi') },
        @{ Key = $efiSysKey;       Destination = (Join-Path $MediaRoot 'efi\microsoft\boot\efisys.bin') },
        @{ Key = $efiNoPromptKey;  Destination = (Join-Path $MediaRoot 'efi\microsoft\boot\efisys_noprompt.bin') }
    )

    if (Test-Path -LiteralPath (Join-Path $MediaRoot 'efi\boot\bootmgfw.efi')) {
        $map += @{ Key = $bootMgfwKey; Destination = (Join-Path $MediaRoot 'efi\boot\bootmgfw.efi') }
    }

    foreach ($entry in $map) {
        if (-not $entry.Key -or -not $CapturedFiles.ContainsKey($entry.Key)) { continue }
        $result = Copy-AIOUpdateFileWithBackup -Source $CapturedFiles[$entry.Key] -Destination $entry.Destination -OnlyIfNewer
        if ($result) { [void]$results.Add($result) }
    }

    if ($CapturedFiles.ContainsKey('FontsExDirectory')) {
        $fontDestination = Join-Path $MediaRoot 'efi\microsoft\boot\fonts'
        Initialize-AIOUpdateDirectory -Path $fontDestination
        foreach ($file in @(Get-ChildItem -LiteralPath $CapturedFiles['FontsExDirectory'] -Recurse -File -ErrorAction SilentlyContinue)) {
            $name = $file.Name -replace '(?i)_EX(?=\.ttf$)', ''
            $destination = Join-Path $fontDestination $name
            $result = Copy-AIOUpdateFileWithBackup -Source $file.FullName -Destination $destination -OnlyIfNewer
            if ($result) { [void]$results.Add($result) }
        }
    }

    return [object[]]($results.ToArray())
}



function ConvertTo-AIOUpdateCompactPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $architectures = @(
        $Package.Architectures |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    $editions = @(
        $Package.Editions |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    $cbsOwn = @()
    $cbsDependencies = @()
    if ($Package.Metadata) {
        $cbsOwn = @(
            $Package.Metadata.CbsOwnIdentities |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )
        $cbsDependencies = @(
            @(
                $Package.Metadata.CbsDependencies
                $Package.Metadata.CbsParents
            ) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )
    }

    return [pscustomobject]@{
        Name             = [string]$Package.Name
        FullName         = [string]$Package.FullName
        Category         = [string]$Package.Category
        KB               = [string]$Package.KB
        Version          = [string]$Package.Version
        Size             = [int64]$Package.Size
        IsCheckpoint     = [bool]$Package.IsCheckpoint
        Architectures    = [string[]]$architectures
        Editions         = [string[]]$editions
        CbsOwnIdentities = [string[]]$cbsOwn
        CbsDependencies  = [string[]]$cbsDependencies
    }
}

function ConvertTo-AIOUpdateCompactVerification {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Report)

    $summary = ''
    if ($Report.PSObject.Properties['Summary'] -and -not [string]::IsNullOrWhiteSpace([string]$Report.Summary)) {
        $summary = [string]$Report.Summary
    }
    elseif ($Report.PSObject.Properties['Reason']) {
        $summary = [string]$Report.Reason
    }

    $missingExpected = @()
    if ($Report.PSObject.Properties['MissingExpected']) {
        $missingExpected = @($Report.MissingExpected | Where-Object { $null -ne $_ })
    }
    $rejuvWarnings = @()
    if ($Report.PSObject.Properties['RejuvWarnings']) {
        $rejuvWarnings = @($Report.RejuvWarnings | Where-Object { $null -ne $_ })
    }
    $details = @()
    if ($Report.PSObject.Properties['Details']) {
        $details = @(
            $Report.Details |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ }
        )
    }

    $observed = ''
    if ($Report.PSObject.Properties['ObservedServicingVersion']) {
        $observed = [string]$Report.ObservedServicingVersion
        if ($observed -eq '0.0.0.0') { $observed = '' }
    }

    return [pscustomobject]@{
        Kind                     = [string]$Report.Kind
        Target                   = [string]$Report.Target
        Phase                    = [string]$Report.Phase
        Success                  = [bool]$Report.Success
        Summary                  = $summary
        CbsFamilyVersion         = $observed
        ObservedServicingVersion = $observed
        EvidenceCount            = @($Report.VerifiedExpected | Where-Object { $null -ne $_ }).Count
        NewPackageCount          = @($Report.NewPackages | Where-Object { $null -ne $_ }).Count
        RetiredPackageCount      = @($Report.RetiredPackages | Where-Object { $null -ne $_ }).Count
        MissingExpected          = [object[]]$missingExpected
        RejuvWarnings            = [object[]]$rejuvWarnings
        Details                  = [string[]]$details
    }
}

function ConvertTo-AIOUpdateCompactDependencyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Plan)

    $entries = @(
        foreach ($entry in @($Plan.Packages | Where-Object { $null -ne $_ })) {
            $matched = @($entry.MatchedDependencies | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            $constraints = @($entry.OrderingConstraints | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            $metadata = @($entry.MetadataDependencies | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            [pscustomobject]@{
                Position             = [int]$entry.PlannedPosition
                PlannedPosition      = [int]$entry.PlannedPosition
                ExecutedPosition     = if ($null -ne $entry.ExecutedPosition) { [int]$entry.ExecutedPosition } else { $null }
                ExecutionState       = [string]$entry.ExecutionState
                ExitCode             = if ($null -ne $entry.ExitCode) { [int]$entry.ExitCode } else { $null }
                Category             = [string]$entry.Category
                Name                 = [string]$entry.Name
                Version              = [string]$entry.Version
                IsCheckpoint         = [bool]$entry.IsCheckpoint
                MatchedDependencies  = [string[]]$matched
                OrderingConstraints  = [string[]]$constraints
                MetadataDependencies = [string[]]$metadata
            }
        }
    )
    $executed = @($entries | Where-Object { $null -ne $_.ExecutedPosition } | Sort-Object ExecutedPosition)
    $skipped = @($entries | Where-Object { $_.ExecutionState -eq 'AlreadyPresent' } | Sort-Object PlannedPosition)

    return [pscustomobject]@{
        Context       = [string]$Plan.Context
        Resolution    = [string]$Plan.Resolution
        HadAmbiguity  = [bool]$Plan.HadAmbiguity
        PlannedOrder  = [object[]]$entries
        ExecutedOrder = [object[]]$executed
        SkippedOrder  = [object[]]$skipped
        Packages      = [object[]]$entries
    }
}

function Export-AIOUpdateStructuredReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Restored')]
        [string]$Status,
        [Parameter(Mandatory = $true)] [string]$OutputDirectory,
        [AllowNull()] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [datetime]$StartedAt,
        [Parameter(Mandatory = $true)] [datetime]$EndedAt,
        [AllowNull()] [object]$Options,
        [AllowNull()] [object]$PreflightBackup,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Inventory,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$VerificationReports,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$CompletedTargets,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$FinalInstallImages,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$FinalBootImages,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$DependencyPlans,
        [AllowNull()] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()] [string]$Phase
    )

    Initialize-AIOUpdateDirectory -Path $OutputDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonPath = Join-Path $OutputDirectory "Resultado_AIOU_$stamp.json"
    $htmlPath = Join-Path $OutputDirectory "Resultado_AIOU_$stamp.html"

    $packages = @(
        $Inventory |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-AIOUpdateCompactPackage -Package $_ }
    )
    $verification = @(
        $VerificationReports |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-AIOUpdateCompactVerification -Report $_ }
    )
    $dependencyPlanReports = @(
        $DependencyPlans |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-AIOUpdateCompactDependencyPlan -Plan $_ }
    )
    $images = @(
        foreach ($image in @($FinalInstallImages)) {
            [pscustomobject]@{
                ImageFile = 'install.wim'
                Index     = [int]$image.ImageIndex
                Name      = [string]$image.ImageName
                Version   = [string]$image.Version
                Architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
            }
        }
        foreach ($image in @($FinalBootImages)) {
            [pscustomobject]@{
                ImageFile = 'boot.wim'
                Index     = [int]$image.ImageIndex
                Name      = [string]$image.ImageName
                Version   = [string]$image.Version
                Architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
            }
        }
    )

    $errorInfo = $null
    if ($ErrorRecord) {
        $errorInfo = [pscustomobject]@{
            Message          = [string]$ErrorRecord.Exception.Message
            ExceptionType    = [string]$ErrorRecord.Exception.GetType().FullName
            ScriptLineNumber = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
            Line             = [string]$ErrorRecord.InvocationInfo.Line
            PositionMessage  = [string]$ErrorRecord.InvocationInfo.PositionMessage
            FullyQualifiedErrorId = [string]$ErrorRecord.FullyQualifiedErrorId
            StackTrace       = [string]$ErrorRecord.ScriptStackTrace
        }
    }

    $report = [pscustomobject]@{
        SchemaVersion      = 2
        Status             = $Status
        MediaRoot          = [string]$MediaRoot
        Phase              = [string]$Phase
        StartedAt          = $StartedAt.ToString('o')
        EndedAt            = $EndedAt.ToString('o')
        DurationSeconds    = [math]::Round(($EndedAt - $StartedAt).TotalSeconds, 2)
        Host               = [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            UserName       = $env:USERNAME
            PowerShell     = [string]$PSVersionTable.PSVersion
            Is64BitProcess = [Environment]::Is64BitProcess
            OSVersion      = [Environment]::OSVersion.VersionString
            DismPath       = $script:AIOUpdateDismPath
            DismSource     = $script:AIOUpdateDismSource
            DismVersion    = $(if ($script:AIOUpdateAdkInfo) { [string]$script:AIOUpdateAdkInfo.ActiveDismVersion } else { [string](Get-AIOUpdateExecutableVersion -Path $script:AIOUpdateDismPath) })
            AdkDetected    = [bool]$(if ($script:AIOUpdateAdkInfo) { $script:AIOUpdateAdkInfo.Detected } else { $false })
            AdkRoot        = $(if ($script:AIOUpdateAdkInfo) { $script:AIOUpdateAdkInfo.Root } else { $null })
            WinPERoot      = $(if ($script:AIOUpdateAdkInfo) { $script:AIOUpdateAdkInfo.WinPERoot } else { $null })
            WinPEArchitectures = $(if ($script:AIOUpdateAdkInfo) { [string[]]$script:AIOUpdateAdkInfo.WinPEArchitectures } else { [string[]]@() })
        }
        Options            = $Options
        PreflightBackup    = $PreflightBackup
        CompletedTargets   = [object[]]@($CompletedTargets)
        Packages           = [object[]]$packages
        DependencyPlans    = [object[]]$dependencyPlanReports
        Verification       = [object[]]$verification
        FinalImages        = [object[]]$images
        Error              = $errorInfo
    }

    Write-AIOUpdateAtomicJson -Path $jsonPath -InputObject $report -Depth 12

    $summary = [pscustomobject]@{
        Estado          = $Status
        Medio           = [string]$MediaRoot
        Fase            = [string]$Phase
        Inicio          = $StartedAt
        Fin             = $EndedAt
        DuracionSegundos = $report.DurationSeconds
        Paquetes        = $packages.Count
        Verificaciones  = $verification.Count
        Respaldo        = if ($PreflightBackup) { [string]$PreflightBackup.Root } else { '' }
    }

    $summaryHtml = ($summary | ConvertTo-Html -Fragment -PreContent '<h2>Resumen</h2>') -join "`n"
    $packagesHtml = if ($packages.Count -gt 0) {
        ($packages | Select-Object Category, Name, KB, Version, IsCheckpoint, Size | ConvertTo-Html -Fragment -PreContent '<h2>Paquetes</h2>') -join "`n"
    }
    else { '<h2>Paquetes</h2><p>Sin datos.</p>' }
    $verificationHtml = if ($verification.Count -gt 0) {
        $verificationRows = @(
            $verification | ForEach-Object {
                [pscustomobject]@{
                    Objetivo            = $_.Target
                    Fase                = $_.Phase
                    Correcto            = $_.Success
                    Resumen             = $_.Summary
                    FamiliaCBS          = $_.CbsFamilyVersion
                    Evidencias          = $_.EvidenceCount
                    PaquetesNuevos      = $_.NewPackageCount
                    PaquetesRetirados   = $_.RetiredPackageCount
                    Detalles            = @($_.Details) -join '; '
                }
            }
        )
        ($verificationRows | ConvertTo-Html -Fragment -PreContent '<h2>Verificaciones</h2>') -join "`n"
    }
    else { '<h2>Verificaciones</h2><p>Sin datos.</p>' }
    $imagesHtml = if ($images.Count -gt 0) {
        ($images | ConvertTo-Html -Fragment -PreContent '<h2>Imagenes finales</h2>') -join "`n"
    }
    else { '<h2>Imagenes finales</h2><p>Sin datos.</p>' }
    $dependencyRows = @(
        foreach ($plan in @($dependencyPlanReports)) {
            foreach ($entry in @($plan.PlannedOrder)) {
                [pscustomobject]@{
                    Contexto          = [string]$plan.Context
                    Resolucion        = [string]$plan.Resolution
                    PosicionPlaneada  = [int]$entry.PlannedPosition
                    PosicionEjecutada = if ($null -ne $entry.ExecutedPosition) { [int]$entry.ExecutedPosition } else { '' }
                    EstadoEjecucion   = [string]$entry.ExecutionState
                    Categoria         = [string]$entry.Category
                    Paquete           = [string]$entry.Name
                    DependenciasCBS   = @($entry.MatchedDependencies) -join '; '
                    Restricciones     = @($entry.OrderingConstraints) -join '; '
                }
            }
        }
    )
    $dependenciesHtml = if ($dependencyRows.Count -gt 0) {
        ($dependencyRows | ConvertTo-Html -Fragment -PreContent '<h2>Orden CBS</h2>') -join "`n"
    }
    else { '<h2>Orden CBS</h2><p>No se resolvieron planes.</p>' }

    $errorHtml = ''
    if ($errorInfo) {
        $encodedMessage = [System.Net.WebUtility]::HtmlEncode([string]$errorInfo.Message)
        $encodedPosition = [System.Net.WebUtility]::HtmlEncode([string]$errorInfo.PositionMessage)
        $errorHtml = "<h2>Error</h2><pre>$encodedMessage`n$encodedPosition</pre>"
    }

    $html = @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>AdminImagenOffline - Resultado $Status</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#f5f5f5;color:#202020}
main{max-width:1400px;margin:auto;background:white;padding:24px;border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.12)}
table{border-collapse:collapse;width:100%;margin:12px 0 28px}
th,td{border:1px solid #ccc;padding:7px;text-align:left;vertical-align:top}
th{background:#ececec}
h1{margin-top:0}
pre{white-space:pre-wrap;background:#f0f0f0;padding:12px;border-radius:4px}
.ok{color:#167217}.failed{color:#a31515}
</style>
</head>
<body><main>
<h1>AdminImagenOffline - Modulo de Actualizaciones</h1>
$summaryHtml
$errorHtml
$imagesHtml
$packagesHtml
$dependenciesHtml
$verificationHtml
</main></body></html>
"@
    Write-AIOUpdateAtomicText -Path $htmlPath -Text $html

    return [pscustomobject]@{
        JsonPath = $jsonPath
        HtmlPath = $htmlPath
        Report   = $report
    }
}

function New-AIOUpdateDiagnosticBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()] [string]$MediaRoot,
        [AllowNull()] [string]$BackupRoot,
        [AllowNull()] [string]$SessionRoot,
        [AllowNull()] [string]$DismTranscript,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Inventory,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$VerificationReports,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$CompletedTargets,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$DependencyPlans,
        [AllowNull()] [object]$Options,
        [Parameter(Mandatory = $true)] [datetime]$StartedAt,
        [Parameter(Mandatory = $true)] [datetime]$EndedAt,
        [AllowNull()] [string]$Phase,
        [AllowNull()] [object]$PreflightBackup
    )

    $diagnosticBase = if (-not [string]::IsNullOrWhiteSpace([string]$script:AIOUpdateDiagnosticsRoot)) {
        $script:AIOUpdateDiagnosticsRoot
    }
    else {
        Join-Path $env:TEMP 'AdminImagenOffline_Diagnosticos'
    }
    Initialize-AIOUpdateDirectory -Path $diagnosticBase

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $folder = Join-Path $diagnosticBase "Diagnostico_AIOU_$stamp"
    Initialize-AIOUpdateDirectory -Path $folder -Empty
    $logsRoot = Join-Path $folder 'Logs'
    Initialize-AIOUpdateDirectory -Path $logsRoot

    $errorText = @(
        "Fecha: $($EndedAt.ToString('o'))"
        "Fase: $Phase"
        "Medio: $MediaRoot"
        "Mensaje: $($ErrorRecord.Exception.Message)"
        "Tipo: $($ErrorRecord.Exception.GetType().FullName)"
        "Linea: $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        "Codigo: $($ErrorRecord.InvocationInfo.Line)"
        "PositionMessage: $($ErrorRecord.InvocationInfo.PositionMessage)"
        "StackTrace:"
        [string]$ErrorRecord.ScriptStackTrace
    )
    Set-Content -LiteralPath (Join-Path $folder 'Error.txt') -Value $errorText -Encoding UTF8

    try {
        & $script:AIOUpdateDismPath '/English' '/Get-MountedImageInfo' *> (Join-Path $folder 'DISM_MountedImageInfo.txt')
    }
    catch {}

    if ($SessionRoot -and (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
        $counter = 0
        foreach ($file in @(
            Get-ChildItem -LiteralPath $SessionRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension.ToLowerInvariant() -in @('.log', '.txt', '.xml') -and $_.Length -le 50MB }
        )) {
            $counter++
            $safeName = ('{0:D4}_{1}' -f $counter, $file.Name)
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $logsRoot $safeName) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($DismTranscript -and (Test-Path -LiteralPath $DismTranscript -PathType Leaf)) {
        Copy-Item -LiteralPath $DismTranscript -Destination (Join-Path $logsRoot 'DISM_Consola.log') -Force -ErrorAction SilentlyContinue
    }

    if ($PreflightBackup -and $PreflightBackup.ManifestPath -and (Test-Path -LiteralPath $PreflightBackup.ManifestPath -PathType Leaf)) {
        Copy-Item -LiteralPath $PreflightBackup.ManifestPath -Destination (Join-Path $folder 'Preflight_manifest.json') -Force -ErrorAction SilentlyContinue
    }

    $logVariable = Get-Variable -Name logFile -Scope Script -ErrorAction SilentlyContinue
    if ($logVariable -and (Test-Path -LiteralPath ([string]$logVariable.Value) -PathType Leaf)) {
        Copy-Item -LiteralPath ([string]$logVariable.Value) -Destination (Join-Path $logsRoot 'AdminImagenOffline.log') -Force -ErrorAction SilentlyContinue
    }

    $report = Export-AIOUpdateStructuredReport -Status 'Failed' -OutputDirectory $folder -MediaRoot $MediaRoot -StartedAt $StartedAt -EndedAt $EndedAt -Options $Options -PreflightBackup $PreflightBackup -Inventory $Inventory -VerificationReports $VerificationReports -CompletedTargets $CompletedTargets -DependencyPlans $DependencyPlans -ErrorRecord $ErrorRecord -Phase $Phase

    $zipPath = "$folder.zip"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    try {
        $diagnosticFiles = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)
        if ($diagnosticFiles.Count -eq 0) {
            throw 'La carpeta de diagnostico no contiene archivos.'
        }

        if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
            Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force -ErrorAction Stop
        }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::CreateFromDirectory($folder, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        }

        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) {
            throw 'El archivo ZIP de diagnostico no fue creado correctamente.'
        }
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo comprimir el diagnostico: $($_.Exception.Message)"
        $zipPath = $null
    }

    return [pscustomobject]@{
        FolderPath = $folder
        ZipPath    = $zipPath
        Report     = $report
    }
}

function Invoke-AIOUpdateMediaIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [int[]]$InstallIndexes,
        [Parameter(Mandatory = $true)] [psobject]$Compatibility,
        [switch]$UpdateWinRE,
        [switch]$UpdateBootWim,
        [switch]$ApplySetupDU,
        [switch]$Cleanup,
        [switch]$ResetBase,
        [switch]$OptimizeWims,
        [switch]$UpdateWimCreationTime
    )

    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $installWim = Join-Path $media 'sources\install.wim'
    $bootWim = Join-Path $media 'sources\boot.wim'
    $initialInstallImages = @(Get-AIOUpdateImageMetadata -ImagePath $installWim)
    $initialBootImages = if (Test-Path -LiteralPath $bootWim -PathType Leaf) { @(Get-AIOUpdateImageMetadata -ImagePath $bootWim) } else { @() }

    $effectiveInventory = @(
        $Inventory |
            Where-Object {
                $_.Auxiliary -or
                ($_.Installable -and (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $Compatibility.Architecture -Build $Compatibility.Build -ImageName $Compatibility.Images[0].ImageName).Compatible)
            }
    )
    if (@($effectiveInventory | Where-Object { $_.Installable }).Count -eq 0) {
        throw 'Ningun paquete instalable del repositorio es compatible con los indices seleccionados.'
    }

    $baseWork = if ($Script:Scratch_DIR -and (Test-Path -LiteralPath $Script:Scratch_DIR)) { $Script:Scratch_DIR } else { $env:TEMP }
    $script:AIOUpdateSessionRoot = Join-Path $baseWork ('AIOU_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Initialize-AIOUpdateDirectory -Path $script:AIOUpdateSessionRoot -Empty
    $script:AIOUpdateDismTranscript = Join-Path $script:AIOUpdateSessionRoot 'DISM_Consola.log'

    $dismScratch = Join-Path $script:AIOUpdateSessionRoot 'S'
    $installMount = Join-Path $script:AIOUpdateSessionRoot 'I'
    $winreMount = Join-Path $script:AIOUpdateSessionRoot 'R'
    $bootMount = Join-Path $script:AIOUpdateSessionRoot 'B'
    $stagingRoot = Join-Path $script:AIOUpdateSessionRoot 'T'
    $captureRoot = Join-Path $stagingRoot 'BootCapture'
    foreach ($path in @($dismScratch, $installMount, $winreMount, $bootMount, $stagingRoot)) {
        Initialize-AIOUpdateDirectory -Path $path
    }

    # El respaldo se guarda fuera de la raíz del medio para impedir que una
    # creación posterior de ISO incorpore accidentalmente las copias.
    $mediaParent = Split-Path -Parent $media
    $mediaLeaf = Split-Path -Leaf $media
    if ([string]::IsNullOrWhiteSpace($mediaLeaf)) { $mediaLeaf = 'MediaWindows' }
    $backupBase = Join-Path $mediaParent 'AdminImagenOffline_Backup'
    $backupRoot = Join-Path (Join-Path $backupBase $mediaLeaf) (Get-Date -Format 'yyyyMMdd_HHmmss')
    $verificationReports = New-Object System.Collections.ArrayList
    $completed = New-Object System.Collections.ArrayList
    $integrationStartedAt = Get-Date
    $integrationOptions = [pscustomobject]@{
        InstallIndexes        = [int[]]$InstallIndexes
        UpdateWinRE           = [bool]$UpdateWinRE
        UpdateBootWim         = [bool]$UpdateBootWim
        ApplySetupDU          = [bool]$ApplySetupDU
        Cleanup               = [bool]$Cleanup
        ResetBase             = [bool]$ResetBase
        OptimizeWims          = [bool]$OptimizeWims
        UpdateWimCreationTime = [bool]$UpdateWimCreationTime
        ReapplyPresent        = $true
    }
    $script:AIOUpdateDependencyPlans = New-Object System.Collections.ArrayList
    $script:AIOUpdateExecutionPositionByContext = @{}
    $script:AIOUpdateLastDiagnosticPath = $null
    $script:AIOUpdateLastPersistentLogPath = $null
    if (-not $script:AIOUpdateLastTerminalState) { [void](Initialize-AIOUpdateTerminalState) }
    $script:AIOUpdateLastTerminalState.Status = 'Running'
    $script:AIOUpdateLastTerminalState.Phase = 'Inicializacion'
    $script:AIOUpdateLastTerminalState.MediaRoot = $media
    $script:AIOUpdateStructuredReport = $null
    Write-AIOUpdateLog -Level WARN -Message 'Reaplicacion automatica habilitada: los paquetes CBS ya presentes se enviaran nuevamente a DISM sin desinstalarlos.'
    $preflightBackup = $null
    $servicedWinRE = $null
    $setupDUWasApplied = $false
    $setupPackages = @()
    $finalInstallImages = @()
    $finalBootImages = @()
    $mediaMutationStarted = $false
    $restorationStatus = 'No requerida'

    try {
        # El respaldo se completa antes de preparar paquetes, montar imagenes o
        # modificar cualquier archivo del medio.
        $script:AIOUpdateCurrentPhase = 'Respaldo Preflight'
        $script:AIOUpdatePreflightContext = $null
        $script:AIOUpdatePreflightPathIndex = @{}
        $script:AIOUpdatePreflightLocalesBySurface = @{}
        $script:AIOUpdateSessionCreatedPathIndex = @{}
        $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
        $script:AIOUpdateTrustedLocales = @{}
        $preflightBackup = New-AIOUpdatePreflightBackup `
            -MediaRoot $media `
            -BackupRoot $backupRoot `
            -IncludeSetupSurface:($ApplySetupDU -or $UpdateBootWim)
        $script:AIOUpdatePreflightContext = $preflightBackup
        Initialize-AIOUpdatePreflightRuntimeIndex -Context $preflightBackup
        $script:AIOUpdateLastTerminalState.BackupRoot = $preflightBackup.Root
        [void]$completed.Add("respaldo previo verificado: $($preflightBackup.FileCount) archivo(s)")

        $script:AIOUpdateCurrentPhase = 'Staging de paquetes'
        Initialize-AIOUpdateLcuMsuStaging -Inventory $effectiveInventory -StagingRoot $stagingRoot
        if ($UpdateWinRE -or $UpdateBootWim) {
            [void](Initialize-AIOUpdateEmbeddedSsuStaging -Inventory $effectiveInventory -StagingRoot $stagingRoot)
        }

        $setupPackages = @(Get-AIOUpdatePackages -Inventory $effectiveInventory -Category @('SetupDU'))
        if ($UpdateWinRE) {
            $script:AIOUpdateCurrentPhase = 'Mantenimiento de winre.wim'
            $sourceWinRE = Join-Path $stagingRoot 'winre.original.wim'
            $updatedWinRE = Join-Path $stagingRoot 'winre.updated.wim'
            [void](Get-AIOUpdateWinREFromInstallWim -InstallWim $installWim -Index $InstallIndexes[0] -InstallMount $installMount -ScratchPath $dismScratch -Destination $sourceWinRE)
            $policy = Get-AIOUpdateWinREPolicy -Build $Compatibility.Build -Inventory $effectiveInventory
            Write-Host "`nPolitica WinRE: $($policy.Reason)" -ForegroundColor Gray
            $servicedWinRE = Update-AIOUpdateWinRE -SourceWinRE $sourceWinRE -DestinationWinRE $updatedWinRE -WinREMount $winreMount -ScratchPath $dismScratch -Inventory $effectiveInventory -Policy $policy -VerificationReports $verificationReports
            [void]$completed.Add('winre.wim actualizado y verificado')
        }

        $script:AIOUpdateCurrentPhase = 'Mantenimiento de install.wim'
        $mediaMutationStarted = $true
        $script:AIOUpdateLastTerminalState.MediaMutationStarted = $true
        Update-AIOUpdateInstallWim -InstallWim $installWim -Indexes $InstallIndexes -Inventory $effectiveInventory -InstallMount $installMount -ScratchPath $dismScratch -ServicedWinRE $servicedWinRE -Cleanup:$Cleanup -ResetBase:$ResetBase -VerificationReports $verificationReports
        [void]$completed.Add('install.wim actualizado y verificado')

        $captured = @{}
        $setupDependencyFiles = @{}
        if ($UpdateBootWim) {
            $script:AIOUpdateCurrentPhase = 'Mantenimiento de boot.wim'
            if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
                throw 'Se solicito actualizar boot.wim, pero no existe sources\boot.wim.'
            }
            $bootImages = @(Get-AIOUpdateImageMetadata -ImagePath $bootWim)
            $captured = Update-AIOUpdateBootWim -BootWim $bootWim -Images $bootImages -Inventory $effectiveInventory -BootMount $bootMount -ScratchPath $dismScratch -CaptureRoot $captureRoot -StagingRoot $stagingRoot -SetupDUPackages $setupPackages -IntegrateSetupDU:$ApplySetupDU -VerificationReports $verificationReports
            foreach ($key in @('ServicingCommonDll', 'UnbclDll')) {
                if ($captured.ContainsKey($key)) { $setupDependencyFiles[$key] = $captured[$key] }
            }
            [void]$completed.Add('boot.wim actualizado y verificado')
        }

        if ($ApplySetupDU -and $setupPackages.Count -gt 0 -and $Compatibility.Build -ge 26100 -and $setupDependencyFiles.Count -eq 0 -and (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
            $dependencyCapture = Join-Path $stagingRoot 'SetupDependencies_ReadOnly'
            $setupDependencyFiles = Get-AIOUpdateBootSetupDependencies -BootWim $bootWim -BootMount $bootMount -ScratchPath $dismScratch -CaptureRoot $dependencyCapture -Build $Compatibility.Build
        }

        if ($ApplySetupDU) {
            $script:AIOUpdateCurrentPhase = 'Aplicacion de Setup Dynamic Update'
            if ($setupPackages.Count -eq 0) {
                Write-Host ' [OMITIDO] SetupDU solicitado, pero no se encontraron paquetes de esa categoria.' -ForegroundColor DarkGray
            }
            else {
                $setupResult = Apply-AIOUpdateSetupDU -MediaRoot $media -Packages $setupPackages -StagingRoot $stagingRoot -DependencyFiles $setupDependencyFiles
                if ($setupResult.Applied) {
                    $setupDUWasApplied = $true
                    [void]$completed.Add('SetupDU aplicado al medio y verificado')
                }
            }
        }

        if ($ApplySetupDU -or $UpdateBootWim) {
            $removedLocales = @(Remove-AIOUpdateUnexpectedMediaLocaleDirectories -MediaRoot $media)
            if ($removedLocales.Count -gt 0) {
                [void]$completed.Add("idiomas ajenos al Preflight eliminados: $($removedLocales.Count)")
            }
        }

        if ($UpdateBootWim) {
            $script:AIOUpdateCurrentPhase = 'Sincronizacion de archivos de arranque'
            $bootSync = @(Sync-AIOUpdateMediaBootFiles -MediaRoot $media -CapturedFiles $captured -Architecture $Compatibility.Architecture)
            if ($bootSync.Count -gt 0) { [void]$completed.Add('Windows Setup, sources y binarios de arranque sincronizados') }

            $removedAfterSync = @(Remove-AIOUpdateUnexpectedMediaLocaleDirectories -MediaRoot $media)
            if ($removedAfterSync.Count -gt 0) {
                [void]$completed.Add("idiomas ajenos al Preflight eliminados tras sincronizacion: $($removedAfterSync.Count)")
            }
        }

        if ($ApplySetupDU -or $UpdateBootWim) {
            $localeAudit = Test-AIOUpdateMediaLocalePolicy -MediaRoot $media
            if (-not $localeAudit.Success) {
                $details = @($localeAudit.UnexpectedLocales | ForEach-Object { "$($_.Surface):$($_.Locale)" }) -join ', '
                throw "La auditoria final detecto idiomas fuera de la politica lang.ini: $details"
            }
            [void]$completed.Add("politica final de idiomas verificada: $(@($localeAudit.AllowedLocales) -join ', ')")
        }

        $script:AIOUpdateCurrentPhase = 'Exportacion y optimizacion final de WIM'
        $singleIndexExport = $null
        if ($InstallIndexes.Count -eq 1) {
            $singleIndexExport = Export-AIOUpdateSingleInstallIndex -InstallWim $installWim -SourceIndex $InstallIndexes[0] -StagingRoot $stagingRoot -ScratchPath $dismScratch
            [void]$completed.Add("install.wim exportado con una sola edicion: $($singleIndexExport.ImageName) (indice final 1)")
        }
        elseif ($OptimizeWims) {
            [void](Rebuild-AIOUpdateWim -WimPath $installWim -StagingRoot $stagingRoot -ScratchPath $dismScratch)
            [void]$completed.Add('install.wim reconstruido y optimizado')
        }

        if ($UpdateBootWim -and $OptimizeWims) {
            [void](Rebuild-AIOUpdateWim -WimPath $bootWim -StagingRoot $stagingRoot -ScratchPath $dismScratch -Bootable)
            [void]$completed.Add('boot.wim reconstruido y optimizado')
        }

        if ($UpdateWimCreationTime) {
            [void](Set-AIOUpdateWimCreationTime -WimPath $installWim -ScratchRoot $stagingRoot)
            if ($UpdateBootWim) { [void](Set-AIOUpdateWimCreationTime -WimPath $bootWim -ScratchRoot $stagingRoot) }
            [void]$completed.Add('fecha interna CREATIONTIME igualada a LASTMODIFICATIONTIME')
        }

        $script:AIOUpdateCurrentPhase = 'Verificacion estructural final'
        $finalInstallImages = @(Get-AIOUpdateImageMetadata -ImagePath $installWim)
        $finalBootImages = if ($UpdateBootWim) { @(Get-AIOUpdateImageMetadata -ImagePath $bootWim) } else { @() }

        $expectedServicingVersion = [version]'0.0.0.0'
        $observedCandidates = @(
            $verificationReports |
                Where-Object { $_.Kind -eq 'PackageInventory' -and $_.Target -like 'install.wim*' -and $_.Phase -eq 'PostCommit' -and $_.ObservedServicingVersion -ne [version]'0.0.0.0' } |
                ForEach-Object { [version]$_.ObservedServicingVersion }
        )
        if ($observedCandidates.Count -gt 0) {
            $expectedServicingVersion = [version]($observedCandidates | Sort-Object -Descending | Select-Object -First 1)
        }

        $installStructure = New-AIOUpdateWimStructureReport -Target 'install.wim estructura final' -BeforeImages $initialInstallImages -AfterImages $finalInstallImages -SelectedIndexes $InstallIndexes -SingleIndex:($InstallIndexes.Count -eq 1) -ExpectedServicingVersion $expectedServicingVersion
        [void]$verificationReports.Add($installStructure)
        if ($UpdateBootWim) {
            $bootIndexes = [int[]]@($initialBootImages | ForEach-Object { [int]$_.ImageIndex })
            $bootStructure = New-AIOUpdateWimStructureReport -Target 'boot.wim estructura final' -BeforeImages $initialBootImages -AfterImages $finalBootImages -SelectedIndexes $bootIndexes
            [void]$verificationReports.Add($bootStructure)
        }

        $failed = @($verificationReports | Where-Object { -not $_.Success })
        Write-Host "`n=======================================================" -ForegroundColor DarkCyan
        Write-Host '             RESUMEN FINAL DE VERIFICACION' -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor DarkCyan
        foreach ($report in $verificationReports) { Write-AIOUpdateVerificationReport -Report $report }
        Write-AIOUpdateConsolidatedRejuvSummary -Reports ([object[]]($verificationReports.ToArray()))
        Write-Host ''
        foreach ($item in $completed) { Write-Host " [OK] $item" -ForegroundColor Green }

        if ($failed.Count -gt 0) {
            throw "La integracion termino con $($failed.Count) verificaciones fallidas."
        }

        $script:AIOUpdateCurrentPhase = 'Generacion del reporte final'
        $integrationEndedAt = Get-Date
        $finalInstallIndexes = if ($InstallIndexes.Count -eq 1) { [int[]]@(1) } else { [int[]]$InstallIndexes }
        $resultObject = [pscustomobject]@{
            Success               = $true
            MediaRoot             = $media
            InstallIndexes        = $InstallIndexes
            FinalInstallIndexes   = $finalInstallIndexes
            SingleIndexExport     = $singleIndexExport
            BootWimUpdated        = [bool]$UpdateBootWim
            SetupDUApplied        = [bool]$setupDUWasApplied
            WimsOptimized         = [bool]$OptimizeWims
            WimCreationTimeUpdated = [bool]$UpdateWimCreationTime
            ReapplyPresent         = $true
            CompletedTargets      = [object[]]($completed.ToArray())
            VerificationReports   = [object[]]($verificationReports.ToArray())
            DependencyPlans       = [object[]]($script:AIOUpdateDependencyPlans.ToArray())
            PreflightBackup       = $preflightBackup
            BackupRoot            = if (Test-Path -LiteralPath $backupRoot) { $backupRoot } else { $null }
            FinalInstallImages    = [object[]]$finalInstallImages
            FinalBootImages       = [object[]]$finalBootImages
            WorkLog               = $script:AIOUpdateDismTranscript
            StartedAt             = $integrationStartedAt
            EndedAt               = $integrationEndedAt
        }
        $reportRoot = $script:AIOUpdateReportsRoot
        $structuredReport = Export-AIOUpdateStructuredReport -Status 'Success' -OutputDirectory $reportRoot -MediaRoot $media -StartedAt $integrationStartedAt -EndedAt $integrationEndedAt -Options $integrationOptions -PreflightBackup $preflightBackup -Inventory $effectiveInventory -VerificationReports ([object[]]($verificationReports.ToArray())) -CompletedTargets ([object[]]($completed.ToArray())) -FinalInstallImages $finalInstallImages -FinalBootImages $finalBootImages -DependencyPlans ([object[]]($script:AIOUpdateDependencyPlans.ToArray())) -Phase $script:AIOUpdateCurrentPhase
        $resultObject | Add-Member -NotePropertyName StructuredReport -NotePropertyValue $structuredReport
        $script:AIOUpdateStructuredReport = $structuredReport

        Write-AIOUpdateLog -Level INFO -Message "Integracion completada y verificada. Reporte JSON='$($structuredReport.JsonPath)'; HTML='$($structuredReport.HtmlPath)'."
        Write-AIOUpdateLog -Level INFO -Message ("Optimizacion: HashCacheHits={0}; HashCacheMisses={1}; CbsCacheHits={2}; RepositoryCacheHits={3}; DuplicadosOmitidos={4}." -f $script:AIOUpdateOptimizationStats.HashCacheHits, $script:AIOUpdateOptimizationStats.HashCacheMisses, $script:AIOUpdateOptimizationStats.CbsCacheHits, $script:AIOUpdateOptimizationStats.RepositoryCacheHits, $script:AIOUpdateOptimizationStats.DuplicatePackagesSkipped)
        Write-Host " Reporte JSON: $($structuredReport.JsonPath)" -ForegroundColor DarkGray
        Write-Host " Reporte HTML: $($structuredReport.HtmlPath)" -ForegroundColor DarkGray
        $script:AIOUpdateLastTerminalState.Status = 'Success'
        $script:AIOUpdateLastTerminalState.Phase = 'Finalizacion'
        $script:AIOUpdateLastTerminalState.Message = 'La integracion de actualizaciones termino correctamente.'
        $script:AIOUpdateLastTerminalState.MediaRoot = $media
        $script:AIOUpdateLastTerminalState.BackupRoot = $(if ($preflightBackup) { $preflightBackup.Root } else { $null })
        $script:AIOUpdateLastTerminalState.ReportJson = $structuredReport.JsonPath
        $script:AIOUpdateLastTerminalState.ReportHtml = $structuredReport.HtmlPath
        $script:AIOUpdateLastTerminalState.MediaMutationStarted = [bool]$mediaMutationStarted
        $script:AIOUpdateLastTerminalState.RestorationStatus = 'No requerida'
        $script:AIOUpdateLastTerminalState.CompletedTargets = [object[]]($completed.ToArray())
        return $resultObject
    }
    catch {
        $capturedError = $_
        $failedPhase = $script:AIOUpdateCurrentPhase
        $integrationEndedAt = Get-Date
        $errorLine = $capturedError.InvocationInfo.ScriptLineNumber
        $errorCode = if ($capturedError.InvocationInfo.Line) { $capturedError.InvocationInfo.Line.Trim() } else { '' }
        Write-AIOUpdateLog -Level ERROR -Message "Integracion interrumpida en '$($script:AIOUpdateCurrentPhase)': $($capturedError.Exception.Message). Completado: $($completed -join ', ')."
        if ($errorLine) {
            Write-AIOUpdateLog -Level ERROR -Message "Linea ${errorLine}: $($capturedError.Exception.Message) | $errorCode"
        }

        try {
            $diagnostic = New-AIOUpdateDiagnosticBundle -ErrorRecord $capturedError -MediaRoot $media -BackupRoot $backupRoot -SessionRoot $script:AIOUpdateSessionRoot -DismTranscript $script:AIOUpdateDismTranscript -Inventory $effectiveInventory -VerificationReports ([object[]]($verificationReports.ToArray())) -CompletedTargets ([object[]]($completed.ToArray())) -DependencyPlans ([object[]]($script:AIOUpdateDependencyPlans.ToArray())) -Options $integrationOptions -StartedAt $integrationStartedAt -EndedAt $integrationEndedAt -Phase $script:AIOUpdateCurrentPhase -PreflightBackup $preflightBackup
            $script:AIOUpdateLastDiagnosticPath = if ($diagnostic.ZipPath) { $diagnostic.ZipPath } else { $diagnostic.FolderPath }
            if ($diagnostic.Report) {
                $script:AIOUpdateStructuredReport = $diagnostic.Report
            }
            Write-AIOUpdateLog -Level ERROR -Message "Diagnostico automatico: $($script:AIOUpdateLastDiagnosticPath)"
            Write-Host "`n Diagnostico automatico: $($script:AIOUpdateLastDiagnosticPath)" -ForegroundColor Yellow
        }
        catch {
            Write-AIOUpdateLog -Level WARN -Message "No se pudo generar el diagnostico automatico: $($_.Exception.Message)"
        }

        if ($preflightBackup -and $mediaMutationStarted) {
            Write-Host "`nLa operacion fallo despues de iniciar cambios en el medio." -ForegroundColor Yellow
            if (Read-AIOUpdateYesNo -Prompt 'Restaurar automaticamente el medio al estado inicial' -Default $true) {
                try {
                    $script:AIOUpdateCurrentPhase = 'Recuperacion'
                    [void](Restore-AIOUpdatePreflightBackup -PreflightRoot $preflightBackup.Root -TargetMediaRoot $media -Scope All)
                    $restorationStatus = 'Restaurado y verificado'
                    Write-Host 'El medio fue restaurado y verificado correctamente.' -ForegroundColor Green
                    Write-AIOUpdateLog -Level INFO -Message "Medio restaurado desde '$($preflightBackup.Root)' despues del error."
                }
                catch {
                    $restorationStatus = "Fallo: $($_.Exception.Message)"
                    Write-Host "[ERROR] No se pudo completar la restauracion automatica: $($_.Exception.Message)" -ForegroundColor Red
                    Write-AIOUpdateLog -Level ERROR -Message "Fallo la restauracion automatica: $($_.Exception.Message)"
                }
            }
            else {
                $restorationStatus = 'No solicitada por el usuario'
            }
        }
        elseif ($preflightBackup) {
            $restorationStatus = 'No requerida; el medio no fue modificado'
        }

        $script:AIOUpdateLastTerminalState.Status = 'Failed'
        $script:AIOUpdateLastTerminalState.Phase = $failedPhase
        $script:AIOUpdateLastTerminalState.Message = $capturedError.Exception.Message
        $script:AIOUpdateLastTerminalState.MediaRoot = $media
        $script:AIOUpdateLastTerminalState.BackupRoot = $(if ($preflightBackup) { $preflightBackup.Root } else { $null })
        $script:AIOUpdateLastTerminalState.DiagnosticPath = $script:AIOUpdateLastDiagnosticPath
        $script:AIOUpdateLastTerminalState.ReportJson = $(if ($diagnostic -and $diagnostic.Report) { $diagnostic.Report.JsonPath } else { $null })
        $script:AIOUpdateLastTerminalState.ReportHtml = $(if ($diagnostic -and $diagnostic.Report) { $diagnostic.Report.HtmlPath } else { $null })
        $script:AIOUpdateLastTerminalState.MediaMutationStarted = [bool]$mediaMutationStarted
        $script:AIOUpdateLastTerminalState.RestorationStatus = $restorationStatus
        $script:AIOUpdateLastTerminalState.CompletedTargets = [object[]]($completed.ToArray())
        $script:AIOUpdateLastTerminalState.ErrorLine = $capturedError.InvocationInfo.ScriptLineNumber
        $script:AIOUpdateLastTerminalState.ErrorCode = $(if ($capturedError.InvocationInfo.Line) { $capturedError.InvocationInfo.Line.Trim() } else { $null })

        throw $capturedError
    }
    finally {
        foreach ($mount in @($winreMount, $installMount, $bootMount)) {
            if ($mount -and (Test-Path -LiteralPath (Join-Path $mount 'Windows'))) {
                [void](Dismount-AIOUpdateImage -MountPath $mount -Mode Discard -Context "Limpieza final de emergencia: $mount" -NoThrow)
            }
        }

        if ($script:AIOUpdateSessionRoot -and (Test-Path -LiteralPath $script:AIOUpdateSessionRoot)) {
            $persistentLog = $null
            if ($script:logDir -and (Test-Path -LiteralPath $script:logDir)) {
                $persistentLog = Join-Path $script:logDir ("Actualizaciones_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                if (Test-Path -LiteralPath $script:AIOUpdateDismTranscript) {
                    Copy-Item -LiteralPath $script:AIOUpdateDismTranscript -Destination $persistentLog -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $script:AIOUpdateSessionRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($persistentLog) {
                $script:AIOUpdateLastPersistentLogPath = $persistentLog
                if ($script:AIOUpdateLastTerminalState) { $script:AIOUpdateLastTerminalState.LogPath = $persistentLog }
                Write-Host "Log de actualizaciones: $persistentLog" -ForegroundColor DarkGray
            }
        }

        $script:AIOUpdateSessionRoot = $null
        $script:AIOUpdateDismTranscript = $null
        $script:AIOUpdatePackagePathMap = @{}
        $script:AIOUpdateLcuStageRoot = $null
        $script:AIOUpdateEmbeddedSsuPackages = @()
        $script:AIOUpdatePreflightContext = $null
        $script:AIOUpdatePreflightPathIndex = @{}
        $script:AIOUpdatePreflightLocalesBySurface = @{}
        $script:AIOUpdateSessionCreatedPathIndex = @{}
        $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
        $script:AIOUpdateTrustedLocales = @{}
        $script:AIOUpdateDependencyPlans = New-Object System.Collections.ArrayList
        $script:AIOUpdateExecutionPositionByContext = @{}
        $script:AIOUpdateCurrentPhase = 'Finalizado'
    }
}

function Read-AIOUpdateYesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Prompt,
        [Nullable[bool]]$Default = $null
    )

    # El parametro Default solo comunica la recomendacion visual. Nunca se
    # utiliza como respuesta implicita: ENTER, entrada vacia o cualquier valor
    # distinto de S/Si/N/No obliga a responder nuevamente.
    $recommendation = if ($null -eq $Default) {
        ''
    }
    elseif ([bool]$Default) {
        ' (recomendado: S)'
    }
    else {
        ' (recomendado: N)'
    }

    while ($true) {
        $answer = (Read-Host "$Prompt [S/N]$recommendation").Trim().ToUpperInvariant()
        if ($answer -in @('S', 'SI', 'SÍ', 'Y', 'YES')) { return $true }
        if ($answer -in @('N', 'NO')) { return $false }

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host 'Se requiere confirmacion explicita. Escribe S o N; ENTER no selecciona una opcion.' -ForegroundColor Yellow
        }
        else {
            Write-Host 'Respuesta invalida. Escribe S o N.' -ForegroundColor Red
        }
    }
}

function Show-AIOUpdateInventorySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    foreach ($entry in @(Get-AIOUpdateInventorySummary -Inventory $Inventory)) {
        $color = if ($entry.Count -gt 0) { 'Green' } else { 'DarkGray' }
        Write-Host (" {0,-11}: {1,3} paquete(s) | {2}" -f $entry.Category, $entry.Count, (Format-AIOUpdateByteSize -Bytes $entry.Size)) -ForegroundColor $color
    }
}


function Show-AIOUpdatePreflightRestoreMenu {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host '              Restaurador de respaldo Preflight' -ForegroundColor Cyan
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host ''

    $selected = Select-AIOUpdateFolder -Title 'Selecciona directamente la carpeta Preflight del respaldo actual'
    if (-not $selected) { return }

    $context = Read-AIOUpdatePreflightManifest -PreflightRoot $selected
    $manifest = $context.Manifest
    $target = [string]$manifest.MediaRoot
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        $target = Select-AIOUpdateFolder -Title 'Selecciona el medio de Windows que deseas restaurar'
        if (-not $target) { return }
    }

    Write-Host " Respaldo : $($context.Root)" -ForegroundColor White
    Write-Host " Creado   : $($manifest.CreatedAt)" -ForegroundColor White
    Write-Host " Archivos : $($manifest.FileCount)" -ForegroundColor White
    Write-Host " Destino  : $target" -ForegroundColor White
    Write-Host ''
    Write-Host ' [1] Restaurar todo el medio respaldado' -ForegroundColor White
    Write-Host ' [2] Restaurar solamente install.wim' -ForegroundColor White
    Write-Host ' [3] Restaurar solamente boot.wim' -ForegroundColor White
    Write-Host ' [4] Restaurar Setup, sources y archivos de arranque' -ForegroundColor White
    Write-Host ' [V] Volver' -ForegroundColor DarkGray

    $selection = (Read-Host 'Seleccion').Trim().ToUpperInvariant()
    $scope = switch ($selection) {
        '1' { 'All' }
        '2' { 'InstallWim' }
        '3' { 'BootWim' }
        '4' { 'Setup' }
        default { return }
    }

    $validation = Test-AIOUpdatePreflightBackup -PreflightRoot $context.Root -Scope $scope
    if (-not $validation.Success) {
        throw "El respaldo no es valido: $($validation.Errors -join ' ')"
    }

    Write-Host "`nLa restauracion reemplazara archivos del medio seleccionado." -ForegroundColor Yellow
    $confirmation = (Read-Host 'Escribe RESTAURAR para confirmar').Trim().ToUpperInvariant()
    if ($confirmation -ne 'RESTAURAR') {
        Write-Host 'Restauracion cancelada.' -ForegroundColor Yellow
        return
    }

    $restoreResult = Restore-AIOUpdatePreflightBackup -PreflightRoot $context.Root -TargetMediaRoot $target -Scope $scope
    [void](Initialize-AIOUpdateTerminalState)
    $script:AIOUpdateLastTerminalState.Status = 'Restored'
    $script:AIOUpdateLastTerminalState.Phase = 'Restauracion Preflight'
    $script:AIOUpdateLastTerminalState.Message = "Restauracion $scope completada correctamente."
    $script:AIOUpdateLastTerminalState.MediaRoot = $target
    $script:AIOUpdateLastTerminalState.BackupRoot = $context.Root
    $script:AIOUpdateLastTerminalState.RestorationStatus = 'Restaurado y verificado'
    $script:AIOUpdateLastTerminalState.CompletedTargets = [object[]]@("Restauracion $scope completada")
    if ($restoreResult.StructuredReport) {
        $script:AIOUpdateLastTerminalState.ReportJson = $restoreResult.StructuredReport.JsonPath
        $script:AIOUpdateLastTerminalState.ReportHtml = $restoreResult.StructuredReport.HtmlPath
    }
    Show-AIOUpdateTerminalSummary -Status Restored -Message $script:AIOUpdateLastTerminalState.Message
    Wait-AIOUpdateUser
}

function Show-UpdatesIntegrator-Menu {
    [CmdletBinding()]
    param()

    [void](Initialize-AIOUpdateTerminalState)
    Clear-Host
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host '                Integrador de Actualizaciones' -ForegroundColor Cyan
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ' Principal: install.wim | Opcionales: winre.wim + boot.wim + SetupDU' -ForegroundColor White
    Write-Host ''

    if (-not (Test-AIOUpdateAdministrator)) {
        Write-Host '[ERROR] Ejecuta AdminImagenOffline como Administrador.' -ForegroundColor Red
        Wait-AIOUpdateUser
        return
    }

    if ($Script:IMAGE_MOUNTED -gt 0) {
        Write-Host '[BLOQUEADO] Hay una imagen montada en AdminImagenOffline.' -ForegroundColor Yellow
        Write-Host 'Desmontala antes de iniciar la integracion masiva.' -ForegroundColor Gray
        Wait-AIOUpdateUser
        return
    }

    Write-Host ' [1] Integrar actualizaciones' -ForegroundColor White
    Write-Host ' [2] Restaurar un respaldo Preflight' -ForegroundColor White
    Write-Host ' [V] Volver' -ForegroundColor DarkGray
    $operationMode = (Read-Host 'Seleccion').Trim().ToUpperInvariant()
    if ($operationMode -eq '2') {
        try {
            $adkInfo = Initialize-AIOUpdateServicingEnvironment
            Import-Module Dism -ErrorAction Stop
            Assert-AIOUpdateNoMountedImages
            Show-AIOUpdateAdkStatus -AdkInfo $adkInfo
            Show-AIOUpdatePreflightRestoreMenu
        }
        catch {
            Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            Write-AIOUpdateLog -Level ERROR -Message "Restauracion Preflight: $($_.Exception.Message)"
            Wait-AIOUpdateUser
        }
        return
    }
    if ($operationMode -ne '1') { return }

    try {
        $adkInfo = Initialize-AIOUpdateServicingEnvironment
        Import-Module Dism -ErrorAction Stop
        Assert-AIOUpdateNoMountedImages

        $mediaRoot = Select-AIOUpdateFolder -Title 'Selecciona la carpeta RAIZ del medio de Windows extraido'
        if (-not $mediaRoot) { return }
        $mediaRoot = (Resolve-Path -LiteralPath $mediaRoot -ErrorAction Stop).Path
        $script:AIOUpdateLastTerminalState.MediaRoot = $mediaRoot

        $installWim = Join-Path $mediaRoot 'sources\install.wim'
        $installEsd = Join-Path $mediaRoot 'sources\install.esd'
        $bootWim = Join-Path $mediaRoot 'sources\boot.wim'
        if (-not (Test-Path -LiteralPath $installWim -PathType Leaf)) {
            if (Test-Path -LiteralPath $installEsd -PathType Leaf) {
                throw 'El medio contiene install.esd. Conviertelo a install.wim antes de usar este modulo.'
            }
            throw 'No se encontro sources\install.wim.'
        }
        $bootWimAvailable = Test-Path -LiteralPath $bootWim -PathType Leaf
        if (-not (Test-AIOUpdateMediaWritable -MediaRoot $mediaRoot)) {
            throw 'El medio es de solo lectura. Extrae la ISO a una carpeta local escribible.'
        }

        $repositoryRoot = $null
        $defaultRepository = Join-Path $script:AIOUpdateApplicationRoot 'Actualizaciones'
        if (Test-Path -LiteralPath $defaultRepository -PathType Container) {
            $defaultRepository = (Resolve-Path -LiteralPath $defaultRepository -ErrorAction Stop).Path
            Write-Host "`nRepositorio detectado: $defaultRepository" -ForegroundColor Cyan
            if (Read-AIOUpdateYesNo -Prompt 'Usar este repositorio' -Default $true) {
                $repositoryRoot = $defaultRepository
            }
        }

        if (-not $repositoryRoot) {
            $repositoryRoot = Select-AIOUpdateFolder -Title 'Selecciona la carpeta de actualizaciones CAB/MSU'
            if (-not $repositoryRoot) { return }
            $repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot -ErrorAction Stop).Path
        }
        Assert-AIOUpdateRepositorySupport -RepositoryRoot $repositoryRoot

        $scanRoot = Join-Path $env:TEMP ('AIO_SCAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOUpdateDirectory -Path $scanRoot -Empty
        try {
            $inventory = @(Get-AIOUpdatePackageInventory -RepositoryRoot $repositoryRoot -ScratchRoot $scanRoot)
        }
        finally {
            Remove-Item -LiteralPath $scanRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $validPackages = @($inventory | Where-Object { $_.Installable })
        if ($validPackages.Count -eq 0) {
            throw 'No se encontraron paquetes CAB/MSU utilizables.'
        }

        $installImages = @(Get-AIOUpdateImageMetadata -ImagePath $installWim)

        Clear-Host
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host '                    RESUMEN PREVIO                     ' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host " Medio       : $mediaRoot" -ForegroundColor White
        Write-Host " Paquetes    : $repositoryRoot" -ForegroundColor White
        Show-AIOUpdateAdkStatus -AdkInfo $adkInfo
        Write-Host ''
        Show-AIOUpdateInventorySummary -Inventory $inventory

        Write-Host "`n Clasificacion detectada:" -ForegroundColor Yellow
        foreach ($item in @($inventory | Where-Object { $_.Installable } | Sort-Object Category, Name)) {
            $checkpointTag = if ($item.IsCheckpoint) { ' [CHECKPOINT]' } else { '' }
            Write-Host ("   [{0,-10}] {1}{2}" -f $item.Category, $item.Name, $checkpointTag) -ForegroundColor White
            Write-Host ("                {0}" -f $item.Reason) -ForegroundColor DarkGray
        }

        $auxiliary = @($inventory | Where-Object { $_.Auxiliary })
        if ($auxiliary.Count -gt 0) {
            Write-Host "`n [AUXILIARES UUP/COMPDB - NO INSTALABLES DIRECTAMENTE]" -ForegroundColor DarkYellow
            foreach ($item in $auxiliary) { Write-Host "   - $($item.Name)" -ForegroundColor DarkGray }
            Write-Host '   Los usa para reconstruir MSU cuando existen fragmentos WIM/PSF;' -ForegroundColor DarkGray
            Write-Host '   con MSU completos no se envian a DISM /Add-Package.' -ForegroundColor DarkGray
        }

        $unknown = @($inventory | Where-Object { $_.Category -eq 'Unknown' })
        if ($unknown.Count -gt 0) {
            Write-Host "`n [NO CLASIFICADOS - OMITIDOS POR SEGURIDAD]" -ForegroundColor Yellow
            foreach ($item in $unknown) {
                Write-Host "   - $($item.Name)" -ForegroundColor Gray
                Write-Host "     $($item.Reason)" -ForegroundColor DarkGray
            }
            Write-Host '   Mueve un paquete confirmado a una subcarpeta de categoria para usar una anulacion manual.' -ForegroundColor DarkGray
        }

        $indexes = Select-AIOUpdateInstallIndexes -Images $installImages
        $compatibility = Assert-AIOUpdateCompatibleIndexes -Images $installImages -Indexes $indexes
        Assert-AIOUpdateEsuPrerequisites -Inventory $inventory -Compatibility $compatibility

        $incompatible = @(
            $inventory |
                Where-Object { $_.Installable } |
                Where-Object {
                    -not (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $compatibility.Architecture -Build $compatibility.Build -ImageName $compatibility.Images[0].ImageName).Compatible
                }
        )
        if ($incompatible.Count -gt 0) {
            Write-Host "`n [OMITIDOS POR COMPATIBILIDAD]" -ForegroundColor DarkYellow
            foreach ($item in $incompatible) {
                $test = Test-AIOUpdatePackageCompatibility -Package $item -Architecture $compatibility.Architecture -Build $compatibility.Build -ImageName $compatibility.Images[0].ImageName
                Write-Host "   - $($item.Name): $($test.Reason)" -ForegroundColor DarkGray
            }
        }

        if (@($inventory | Where-Object { $_.Category -eq 'ESU' }).Count -gt 0) {
            Write-Host "`n [ESU] Se integraran paquetes soportados, pero no se omiten comprobaciones de licencia/activacion." -ForegroundColor Yellow
        }

        Write-Host "`n Configuracion:" -ForegroundColor Yellow
        $updateWinRE = Read-AIOUpdateYesNo -Prompt 'Actualizar y reinyectar winre.wim' -Default $true
        if ($updateWinRE) {
            Write-Host ' LCU en WinRE: Automatico (politica determinada por build y disponibilidad de SafeOS).' -ForegroundColor DarkGray
        }

        $updateBootWim = $false
        if ($bootWimAvailable) {
            $updateBootWim = Read-AIOUpdateYesNo -Prompt 'Actualizar boot.wim y sincronizar binarios de arranque' -Default $true
        }
        else {
            Write-Host ' [OMITIDO] El medio no contiene sources\boot.wim.' -ForegroundColor DarkGray
        }

        $setupPackages = @(Get-AIOUpdatePackages -Inventory $inventory -Category @('SetupDU'))
        $applySetupDU = $false
        if ($setupPackages.Count -gt 0) {
            $applySetupDU = Read-AIOUpdateYesNo -Prompt 'Aplicar Setup Dynamic Update al medio' -Default $true
        }
        else {
            Write-Host ' [OMITIDO] No se detectaron paquetes SetupDU.' -ForegroundColor DarkGray
        }

        Write-Host ' Reaplicacion de paquetes presentes: Automatica.' -ForegroundColor Yellow
        Write-Host ' Los paquetes Installed, InstallPending o Superseded se enviaran nuevamente a DISM sin desinstalarlos.' -ForegroundColor DarkGray
        Write-Host ' CBS puede aceptar el paquete o indicar que la reaplicacion no es necesaria/aplicable.' -ForegroundColor DarkGray

        $cleanup = Read-AIOUpdateYesNo -Prompt 'Ejecutar StartComponentCleanup en install.wim' -Default $true
        $resetBase = $false
        if ($cleanup) {
            $resetBase = Read-AIOUpdateYesNo -Prompt 'Usar ResetBase (impide desinstalar actualizaciones)' -Default $false
        }

        $optimizeWims = Read-AIOUpdateYesNo -Prompt 'Reconstruir y optimizar los WIM al terminar' -Default $true
        $wimlib = Find-AIOUpdateWimlib
        $updateWimCreationTime = $false
        if ($wimlib) {
            $updateWimCreationTime = Read-AIOUpdateYesNo -Prompt 'Igualar CREATIONTIME interno con LASTMODIFICATIONTIME' -Default $true
        }
        else {
            Write-Host ' [OMITIDO] Fecha interna del WIM: falta AdminImagenOffline\Tools\wimlib-imagex.exe o una instalacion disponible en PATH.' -ForegroundColor DarkGray
        }

        Write-Host "`n=======================================================" -ForegroundColor DarkCyan
        Write-Host ' PLAN DE EJECUCION' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor DarkCyan
        Write-Host " Indices install.wim : $($indexes -join ', ')" -ForegroundColor White
        $installOutput = if ($indexes.Count -eq 1) { "solo la edicion seleccionada; indice final 1 (original: $($indexes[0]))" } else { 'se conservan todos los indices del WIM' }
        Write-Host " Salida install.wim  : $installOutput" -ForegroundColor White
        Write-Host " WinRE               : $updateWinRE | LCU: Automatico" -ForegroundColor White
        Write-Host " Limpieza            : $cleanup | ResetBase: $resetBase" -ForegroundColor White
        $bootPlan = if ($updateBootWim) { 'Si, todos los indices' } else { 'No' }
        $setupPlan = if (-not $applySetupDU) {
            'No'
        }
        elseif ($updateBootWim) {
            'Si (medio + indice Setup de boot.wim)'
        }
        else {
            'Si (solo medio; boot.wim omitido)'
        }
        Write-Host " boot.wim            : $bootPlan" -ForegroundColor White
        Write-Host " SetupDU             : $setupPlan" -ForegroundColor White
        Write-Host " Reaplicar presentes : Automatico (sin desinstalar)" -ForegroundColor White
        Write-Host " Optimizar WIM       : $optimizeWims" -ForegroundColor White
        Write-Host " Fecha CREATIONTIME  : $updateWimCreationTime" -ForegroundColor White
        Write-Host " Respaldo previo     : Obligatorio, antes del primer montaje" -ForegroundColor White
        Write-Host ''

        $start = (Read-Host 'Escribe I para INICIAR o V para volver').Trim().ToUpperInvariant()
        if ($start -ne 'I') {
            $script:AIOUpdateLastTerminalState.Status = 'Cancelled'
            $script:AIOUpdateLastTerminalState.Phase = 'Confirmacion del plan'
            $script:AIOUpdateLastTerminalState.Message = 'No se realizaron cambios en el medio.'
            Show-AIOUpdateTerminalSummary -Status Cancelled -Message $script:AIOUpdateLastTerminalState.Message
            Wait-AIOUpdateUser
            return
        }

        $result = Invoke-AIOUpdateMediaIntegration -MediaRoot $mediaRoot -Inventory $inventory -InstallIndexes $indexes -Compatibility $compatibility -UpdateWinRE:$updateWinRE -UpdateBootWim:$updateBootWim -ApplySetupDU:$applySetupDU -Cleanup:$cleanup -ResetBase:$resetBase -OptimizeWims:$optimizeWims -UpdateWimCreationTime:$updateWimCreationTime

        Show-AIOUpdateTerminalSummary -Status Success -Message 'La integracion de actualizaciones termino correctamente.'
        Wait-AIOUpdateUser
    }
    catch {
        $errorLine = $_.InvocationInfo.ScriptLineNumber
        $errorCode = if ($_.InvocationInfo.Line) { $_.InvocationInfo.Line.Trim() } else { '' }
        if (-not $script:AIOUpdateLastTerminalState) { [void](Initialize-AIOUpdateTerminalState) }
        $script:AIOUpdateLastTerminalState.Status = 'Failed'
        if (-not $script:AIOUpdateLastTerminalState.Phase -or $script:AIOUpdateLastTerminalState.Phase -eq 'Inicializacion') {
            $script:AIOUpdateLastTerminalState.Phase = $script:AIOUpdateCurrentPhase
        }
        $script:AIOUpdateLastTerminalState.Message = $_.Exception.Message
        $script:AIOUpdateLastTerminalState.ErrorLine = $errorLine
        $script:AIOUpdateLastTerminalState.ErrorCode = $errorCode
        if ($script:AIOUpdateLastDiagnosticPath) { $script:AIOUpdateLastTerminalState.DiagnosticPath = $script:AIOUpdateLastDiagnosticPath }
        if ($script:AIOUpdateLastPersistentLogPath) { $script:AIOUpdateLastTerminalState.LogPath = $script:AIOUpdateLastPersistentLogPath }
        Write-AIOUpdateLog -Level ERROR -Message $_.Exception.Message
        if ($errorLine) { Write-AIOUpdateLog -Level ERROR -Message "Linea ${errorLine}: $errorCode" }
        Show-AIOUpdateTerminalSummary -Status Failed -Message $_.Exception.Message
        Wait-AIOUpdateUser
    }
}

function WindowsUpdate-Menu {
    [CmdletBinding()]
    param()

    Show-UpdatesIntegrator-Menu
}