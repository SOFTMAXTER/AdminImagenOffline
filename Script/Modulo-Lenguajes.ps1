<#
.SYNOPSIS
    Integra idiomas y crea medios multilingues de Windows 10/11.
.DESCRIPTION
    Modulo complementario para AdminImagenOffline. Implementa un flujo
    transaccional de mantenimiento para medios de instalacion extraidos:

      - Detecta install.wim o convierte install.esd a WIM antes del servicio.
      - Permite seleccionar uno, varios o todos los indices de install.wim.
      - Detecta automaticamente paquetes de idioma/FOD CAB/ESD y sus metadatos (LXP APPX queda fuera de este flujo CBS).
      - Detecta componentes Language Features on Demand por identidad CBS.
      - Detecta automaticamente el ADK y el complemento de Windows PE.
      - Combina los paquetes WinPE instalados con el repositorio seleccionado.
      - Valida idioma, arquitectura y familia de build antes de modificar el medio.
      - Obtiene bases CBS de cada indice WIM/ESD y consulta aplicabilidad antes de integrar, sin tablas de builds.
      - Aplaza la limpieza si hay operaciones pendientes o no se puede consultar su estado.
      - Distingue paquetes WinPE encontrados de los realmente compatibles con el medio.
      - Diagnostica por separado paquetes WinPE encontrados, compatibles e incompatibles.
      - Integra paquetes de idioma antes de sus componentes dependientes.
      - Integra componentes linguisticos en un orden estable y verificable.
      - Actualiza winre.wim sin reutilizar una copia incompatible entre ediciones.
      - Actualiza opcionalmente todos los indices de boot.wim.
      - Sincroniza archivos localizados de Setup y genera lang.ini.
      - Estrategia WinPE: lp.cab y satelites localizados solo cuando el paquete neutral esta realmente instalado en el indice.
      - Copia lang.ini y recursos MUI de Setup dentro del indice de instalacion de boot.wim.
      - Verifica /Get-Intl, paquetes CBS, lang.ini y recursos MUI antes y despues de guardar boot.wim.
      - Impide declarar exito si el selector inicial de Windows Setup no queda realmente multilingue.
      - Si no hay WinPE Add-on compatible, aplica el modo de compatibilidad: lang.ini y recursos MUI en el indice Setup, sin afirmar que WinPE completo fue traducido.
      - El modo FullWinPE exige lp.cab para cada idioma; para ja/ko/zh tambien exige WinPE-FontSupport.
      - Sin WinPE completo, los idiomas de Asia oriental reutilizan fuentes capturadas desde install.wim en ambos indices de boot.wim mediante el modo de compatibilidad integrado.
      - Identifica el indice Setup por metadatos, paquetes Setup-Client/Server/ASZ, setup.exe, winpeshl.ini y fallback seguro al indice 2.
      - La verificacion final revisa solamente los indices de boot.wim realmente modificados.
      - Permite conservar el idioma actual o establecer uno nuevo como predeterminado.
      - Exporta solo la edicion seleccionada cuando se elige un unico indice.
      - Reconstruye WIM con compresion maxima y reemplazo atomico real en el volumen de destino.
      - Crea un respaldo Preflight validado antes de la primera modificacion.
      - Muestra un resumen obligatorio del respaldo y progreso SHA-256 compacto.
      - Usa AdminImagenOffline_Backup junto al medio, igual que el modulo de actualizaciones.
      - Puede restaurar el medio desde un respaldo creado por este modulo.
      - Registra la salida de DISM, genera reportes JSON/HTML y un diagnostico ZIP.
      - Maneja codigos HRESULT sin conversiones incompatibles con Windows PowerShell 5.1.
      - Registra montajes antes de DISM para garantizar descarte y recuperacion tras errores.
      - No depende de 7-Zip: usa expand.exe para CAB y DISM para contenedores ESD.
      - Optimiza enumeracion, hashes, metadatos, copias verificadas y escritura atomica sin paralelizar WIM.
      - Al finalizar correctamente, recuerda aplicar el modulo de Actualizaciones.

    Estructura recomendada del repositorio:

        Lenguajes\
        |-- LanguagePacks\
        |   |-- x64\
        |   `-- x86\
        |-- FeaturesOnDemand\
        |   |-- x64\
        |   `-- x86\
        `-- WinPE\
            |-- amd64\WinPE_OCs\
            `-- x86\WinPE_OCs\

    Tambien se admite una carpeta plana. La clasificacion se realiza mediante
    nombres, estructura y metadatos internos de los paquetes.
.NOTES
    Implementacion original para AdminImagenOffline.
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

$script:AIOLangNativeSystemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
$script:AIOLangSystemDismPath = Join-Path $script:AIOLangNativeSystemDirectory 'dism.exe'
$script:AIOLangDismPath = $script:AIOLangSystemDismPath
$script:AIOLangDismSource = 'Sistema'
$script:AIOLangHResultNotApplicable = [uint32]2148468766 # 0x800F081E
$script:AIOLangAdkInfo = $null
$script:AIOLangExpandPath = Join-Path $script:AIOLangNativeSystemDirectory 'expand.exe'
$script:AIOLangSessionRoot = $null
$script:AIOLangDismTranscript = $null
$script:AIOLangCurrentPhase = 'Inicializacion'
$script:AIOLangLastDiagnosticPath = $null
$script:AIOLangLastPersistentLogPath = $null
$script:AIOLangLastTerminalState = $null
$script:AIOLangMountedPaths = New-Object System.Collections.ArrayList
$script:AIOLangOperationLog = New-Object System.Collections.ArrayList
$script:AIOLangPackageMetadataCache = @{}
$script:AIOLangImageServicingCache = @{}
$script:AIOLangApplicationRoot = Split-Path -Parent $PSScriptRoot
$script:AIOLangReportsRoot = Join-Path $script:AIOLangApplicationRoot 'Reportes\Idiomas'
$script:AIOLangFileHashCache = @{}
$script:AIOLangRepositoryInventoryCache = @{}
$script:AIOLangOptimizationStats = [ordered]@{
    HashCacheHits = 0
    HashCacheMisses = 0
    MetadataCacheHits = 0
    RepositoryCacheHits = 0
}


# Politicas centralizadas para reducir mantenimiento disperso. Las fronteras de
# compatibilidad se basan en metadatos reales; estas tablas solo normalizan
# alias y excepciones de producto/edicion conocidas.
$script:AIOLangPolicy = [ordered]@{
    ArchitectureAliases = [ordered]@{
        x86   = @('0', 'x86', 'i386', 'i686')
        x64   = @('9', 'x64', 'amd64', 'x86_64')
        arm64 = @('12', 'arm64', 'aarch64')
        arm   = @('5', 'arm')
    }
    WinPEFolderMap = [ordered]@{
        x64   = 'amd64'
        x86   = 'x86'
        arm64 = 'arm64'
        arm   = 'arm'
    }
    RestrictedMultilingualEditionPattern = '(?i)(SingleLanguage|CountrySpecific)'
    EastAsianLocales = @('ja-JP','ko-KR','zh-CN','zh-HK','zh-TW')
    WinPEFontSupportPatterns = @('WinPE-FontSupport','FontSupport')
    EastAsianFontFiles = [ordered]@{
        'ja-jp' = @('meiryo.ttc','msgothic.ttc')
        'ko-kr' = @('malgun.ttf','gulim.ttc')
        'zh-cn' = @('msyh.ttc','mingliub.ttc','simsun.ttc','msyhl.ttc')
        'zh-hk' = @('msjh.ttc','mingliub.ttc','simsun.ttc')
        'zh-tw' = @('msjh.ttc','mingliub.ttc','simsun.ttc')
    }
    ProductPatterns = [ordered]@{
        Server = '(?i)(server-languagepack|servercore|windows-server|winpe-setup-server)'
        Client = '(?i)(client-languagepack|windows-client|winpe-setup-client)'
        WinPE  = '(?i)(winpe[_/-]|winpe-)'
    }
    WinPEPriorityRules = @(
        [pscustomobject]@{ Pattern = '(?:^|[-_])lp(?:[._-]|$)|common-foundation'; Priority = 10 },
        [pscustomobject]@{ Pattern = 'rejuv|storagewmi|hta|winpe-srt'; Priority = 20 },
        [pscustomobject]@{ Pattern = 'enhancedstorage|scripting|securestartup|wds-tools|winpe-wmi'; Priority = 30 },
        [pscustomobject]@{ Pattern = 'winpe-setup'; Priority = 40 }
    )
    FodPriorityRules = @(
        [pscustomobject]@{ Pattern = 'languagefeatures-basic'; Priority = 10 },
        [pscustomobject]@{ Pattern = 'languagefeatures-fonts'; Priority = 20 },
        [pscustomobject]@{ Pattern = 'languagefeatures-(texttospeech|handwriting|ocr|speech)|internationalfeatures'; Priority = 30 },
        [pscustomobject]@{ Pattern = 'ethernet|wifi'; Priority = 40 },
        [pscustomobject]@{ Pattern = 'mspaint|notepad|powershell-ise|internetexplorer'; Priority = 50 },
        [pscustomobject]@{ Pattern = 'snippingtool|stepsrecorder|wordpad|printing'; Priority = 60 },
        [pscustomobject]@{ Pattern = 'mediaplayer|wmic|terminalservices|virtualmachineplatform'; Priority = 70 },
        [pscustomobject]@{ Pattern = 'projfs|telnet|tftp|vbscript|winocr|smbdirect|simpletcp|senseclient|enterpriseclientsync|directoryservices'; Priority = 80 },
        [pscustomobject]@{ Pattern = 'servercorefonts'; Priority = 90 }
    )
    SetupCoreMui = @('setup.exe.mui','setupplatform.exe.mui','w32uires.dll.mui','winsetup.dll.mui','spwizres.dll.mui')
    SetupLocalizedFiles = @(
        'appraiser.dll.mui','arunres.dll.mui','cmisetup.dll.mui','compatctrl.dll.mui',
        'compatprovider.dll.mui','deployprovider.dll.mui','dism.exe.mui','dismapi.dll.mui',
        'dismcore.dll.mui','dismprov.dll.mui','folderprovider.dll.mui','imagingprovider.dll.mui',
        'input.dll.mui','logprovider.dll.mui','mediasetupuimgr.dll.mui','nlsbres.dll.mui',
        'osimageprovider.dll.mui','pnpibs.dll.mui','reagent.dll.mui','rollback.exe.mui',
        'setup.exe.mui','setupcompat.dll.mui','setupcore.dll.mui','setupmgr.dll.mui',
        'setupplatform.exe.mui','setupprep.exe.mui','smiengine.dll.mui','spwizres.dll.mui',
        'upgloader.dll.mui','uxlibres.dll.mui','vhdprovider.dll.mui','w32uires.dll.mui',
        'wdsclient.dll.mui','wdsimage.dll.mui','wimgapi.dll.mui','wimprovider.dll.mui',
        'windlp.dll.mui','winsetup.dll.mui','reagent.adml'
    )
    SetupLocalizedRtf = @('vofflps.rtf','credits.rtf','oobe_help_opt_in_details.rtf')
}

function Test-AIOLangPolicyPatternSet {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$Text,
        [Parameter(Mandatory = $true)] [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
        if ($Text -match [string]$pattern) { return $true }
    }
    return $false
}

function Write-AIOLangLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        try { Write-Log -LogLevel $Level -Message "Idiomas: $Message" }
        catch {}
    }
}

function Add-AIOLangOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Phase,
        [Parameter(Mandatory = $true)] [string]$Context,
        [Parameter(Mandatory = $true)] [string]$State,
        [AllowNull()] [object]$Details
    )

    [void]$script:AIOLangOperationLog.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        Phase     = $Phase
        Context   = $Context
        State     = $State
        Details   = $Details
    })
}

function Wait-AIOLangUser {
    [CmdletBinding()]
    param(
        [string]$Message = 'Presiona ENTER para volver al menu del modulo'
    )

    try {
        [void](Read-Host "`n$Message")
    }
    catch {
        # Un host no interactivo no debe ocultar el resumen ni provocar otro error.
        Start-Sleep -Seconds 2
    }
}

function Initialize-AIOLangTerminalState {
    [CmdletBinding()]
    param()

    $script:AIOLangLastTerminalState = [pscustomobject]@{
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
    return $script:AIOLangLastTerminalState
}

function Show-AIOLangTerminalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Cancelled')]
        [string]$Status,
        [AllowNull()] [string]$Message
    )

    $state = $script:AIOLangLastTerminalState
    if (-not $state) { $state = Initialize-AIOLangTerminalState }
    $state.Status = $Status
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $state.Message = $Message }

    $title = switch ($Status) {
        'Success'   { 'INTEGRACION COMPLETADA Y VERIFICADA' }
        'Failed'    { 'INTEGRACION FINALIZADA CON ERROR' }
        'Cancelled' { 'OPERACION CANCELADA' }
    }
    $color = switch ($Status) {
        'Success'   { 'Green' }
        'Failed'    { 'Red' }
        'Cancelled' { 'Yellow' }
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

function Select-AIOLangFolder {
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
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    }
    catch {
        Write-Host "No se pudo abrir el selector grafico: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $manual = (Read-Host $Title).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($manual)) { return $null }
    return $manual
}

function Read-AIOLangYesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Prompt,
        [Nullable[bool]]$Default = $null
    )

    # Default conserva la recomendacion del asistente, pero nunca confirma por
    # el usuario. Toda decision requiere S/Si o N/No de forma explicita.
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

function Format-AIOLangByteSize {
    [CmdletBinding()]
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Initialize-AIOLangDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [switch]$Empty
    )

    if ($Empty -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop)
    }
}

function Test-AIOLangAdministrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Convert-AIOLangArchitectureName {
    [CmdletBinding()]
    param([AllowNull()] [object]$Architecture)

    $value = ([string]$Architecture).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { return 'Unknown' }

    foreach ($entry in $script:AIOLangPolicy.ArchitectureAliases.GetEnumerator()) {
        if ($value -in @($entry.Value)) { return [string]$entry.Key }
    }
    return $value
}


function Convert-AIOLangExitCodeToUInt32 {
    [CmdletBinding()]
    param([int]$ExitCode)

    if ($ExitCode -lt 0) { return [uint32]([int64]$ExitCode + 4294967296) }
    return [uint32]$ExitCode
}

function Get-AIOLangExitCodeText {
    [CmdletBinding()]
    param([int]$ExitCode)

    $code = Convert-AIOLangExitCodeToUInt32 -ExitCode $ExitCode
    switch ($code) {
        0          { return 'Operacion completada correctamente.' }
        2          { return 'No se encontro un archivo requerido.' }
        3          { return 'No se encontro la ruta especificada.' }
        5          { return 'Acceso denegado.' }
        32         { return 'Un archivo esta siendo utilizado por otro proceso.' }
        87         { return 'Parametro incorrecto.' }
        112        { return 'No hay espacio suficiente en el disco.' }
        123        { return 'La sintaxis de la ruta es incorrecta.' }
        740        { return 'La operacion requiere elevacion.' }
        3010       { return 'Operacion completada; se requiere reinicio.' }
        2147942402 { return 'No se encontro un archivo requerido.' } # 0x80070002
        2147942403 { return 'No se encontro la ruta especificada.' } # 0x80070003
        2147942405 { return 'Acceso denegado.' } # 0x80070005
        2147942432 { return 'El archivo esta en uso por otro proceso.' } # 0x80070020
        2147942512 { return 'Espacio insuficiente en el disco.' } # 0x80070070
        2148468741 { return 'El paquete especificado no es valido.' } # 0x800F0805
        2148468766 { return 'El paquete no es aplicable a esta imagen.' } # 0x800F081E
        2148468771 { return 'El paquete requiere otro paquete previo.' } # 0x800F0823
        2148468773 { return 'El paquete no se puede desinstalar.' } # 0x800F0825
        2148468784 { return 'El paquete no es compatible con esta imagen.' } # 0x800F0830
        2148468785 { return 'Falta el manifiesto o paquete de origen requerido.' } # 0x800F0831
        2148468998 { return 'No se pudieron descargar o localizar archivos de origen.' } # 0x800F0906
        2148469076 { return 'No se encontro el origen de Features on Demand.' } # 0x800F0954
        3242328343 { return 'El directorio de montaje no esta vacio o tiene una sesion invalida.' } # 0xC1420117
        default    { return 'Error DISM no clasificado por el modulo.' }
    }
}

function ConvertTo-AIOLangNativeArgument {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

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

function Add-AIOLangDismTranscriptLine {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [AllowNull()] [string]$Line)

    if (-not $script:AIOLangDismTranscript) { return }
    try {
        if ($null -eq $Line) { $Line = '' }
        ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Line) |
            Out-File -LiteralPath $script:AIOLangDismTranscript -Append -Encoding utf8
    }
    catch {}
}


function Invoke-AIOLangDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
        [Parameter(Mandatory = $true)] [string]$Context,
        [int[]]$SuccessCodes = @(0, 3010),
        [switch]$AllowNotApplicable,
        [switch]$NoThrow,
        [switch]$Quiet
    )

    if (-not (Test-Path -LiteralPath $script:AIOLangDismPath -PathType Leaf)) {
        throw "No se encontro DISM en '$script:AIOLangDismPath'."
    }

    $safeContext = ($Context -replace '[^A-Za-z0-9_.-]', '_')
    if ($safeContext.Length -gt 72) { $safeContext = $safeContext.Substring(0, 72) }
    $dismLog = if ($script:AIOLangSessionRoot) {
        Join-Path $script:AIOLangSessionRoot ("DISM_{0}_{1}.log" -f (Get-Date -Format 'HHmmssfff'), $safeContext)
    }
    else {
        Join-Path $env:TEMP ("AIO_LANG_DISM_{0}.log" -f [guid]::NewGuid().ToString('N'))
    }

    $effectiveArguments = @('/English') + $Arguments
    if (@($effectiveArguments | Where-Object { $_ -match '^/LogPath:' }).Count -eq 0) {
        $effectiveArguments += "/LogPath:$dismLog"
    }

    Write-AIOLangLog -Level ACTION -Message "$Context | dism.exe $($effectiveArguments -join ' ')"
    Add-AIOLangDismTranscriptLine -Line ("INICIO | {0} | dism.exe {1}" -f $Context, ($effectiveArguments -join ' '))
    if (-not $Quiet) { Write-Host "`n>> $Context" -ForegroundColor Cyan }

    $nativeArgumentLine = (@($effectiveArguments | ForEach-Object {
        ConvertTo-AIOLangNativeArgument -Argument ([string]$_)
    }) -join ' ')

    $captured = New-Object System.Collections.Generic.List[string]
    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:AIOLangDismPath
        $startInfo.Arguments = $nativeArgumentLine
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = [bool]$Quiet
        if ($Quiet) {
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'No se pudo iniciar dism.exe.' }

        $stdoutTask = $null
        $stderrTask = $null
        if ($Quiet) {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }

        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        if ($Quiet) {
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            foreach ($line in @($stdout -split "`r?`n") + @($stderr -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    [void]$captured.Add($line.TrimEnd())
                }
            }
        }
    }
    catch {
        $message = "No se pudo iniciar DISM para '$Context': $($_.Exception.Message)"
        Write-AIOLangLog -Level ERROR -Message $message
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'FailedToStart' -Details $message
        if (-not $NoThrow) { throw $message }
        return [pscustomobject]@{
            Success = $false; State = 'FailedToStart'; ExitCode = -1; UnsignedCode = [uint32]::MaxValue
            Output = [string[]]$captured.ToArray(); LogPath = $dismLog; Context = $Context
        }
    }
    finally {
        if ($process) { $process.Dispose() }
    }

    $unsigned = Convert-AIOLangExitCodeToUInt32 -ExitCode $exitCode
    $notApplicable = ($unsigned -eq $script:AIOLangHResultNotApplicable)
    $success = ($exitCode -in $SuccessCodes) -or ($AllowNotApplicable -and $notApplicable)
    Add-AIOLangDismTranscriptLine -Line ("FIN | {0} | Codigo={1} | Hex=0x{2}" -f $Context, $exitCode, ('{0:X8}' -f $unsigned))

    if ($success) {
        $state = if ($notApplicable) { 'NotApplicable' } else { 'Success' }
        $level = if ($notApplicable) { 'WARN' } else { 'INFO' }
        Write-AIOLangLog -Level $level -Message "$Context finalizo con codigo $exitCode."
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State $state -Details @{ ExitCode = $exitCode; LogPath = $dismLog }
        return [pscustomobject]@{
            Success = $true; State = $state; ExitCode = $exitCode; UnsignedCode = $unsigned
            Output = [string[]]$captured.ToArray(); LogPath = $dismLog; Context = $Context
        }
    }

    $hexCode = '0x{0:X8}' -f $unsigned
    $description = Get-AIOLangExitCodeText -ExitCode $exitCode
    $message = "$Context fallo. Codigo DISM: $exitCode ($hexCode). $description"
    Write-AIOLangLog -Level ERROR -Message $message
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'Failed' -Details @{ ExitCode = $exitCode; HexCode = $hexCode; Description = $description; LogPath = $dismLog }
    if (-not $NoThrow) { throw $message }

    return [pscustomobject]@{
        Success = $false; State = 'Failed'; ExitCode = $exitCode; UnsignedCode = $unsigned
        Output = [string[]]$captured.ToArray(); LogPath = $dismLog; Context = $Context
    }
}

function Assert-AIOLangNoMountedImages {
    [CmdletBinding()]
    param()

    if ($Script:IMAGE_MOUNTED -and [int]$Script:IMAGE_MOUNTED -ne 0) {
        throw 'AdminImagenOffline tiene una imagen montada. Guardala o desmontala antes de integrar idiomas en un medio completo.'
    }

    $mounted = @()
    try { $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.MountStatus -ne 'Invalid' }) }
    catch {
        $result = Invoke-AIOLangDism -Arguments @('/Get-MountedImageInfo') -Context 'Comprobar montajes existentes' -Quiet -NoThrow
        if ($result.Output -match '(?i)Mount Dir|Mount Directory') {
            throw 'DISM reporta imagenes montadas. Desmonta o descarta esas sesiones antes de continuar.'
        }
    }

    if ($mounted.Count -gt 0) {
        $paths = @($mounted | ForEach-Object { $_.Path })
        throw "Hay imagenes montadas por DISM: $($paths -join ', ')."
    }
}

function Test-AIOLangMediaWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot)

    $probe = Join-Path $MediaRoot ('.aio_lang_write_' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'test')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Mount-AIOLangImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ReadOnly
    )

    if ($MountPath -in $script:AIOLangMountedPaths) {
        throw "El montaje '$MountPath' sigue pendiente; no se vaciara ni reutilizara."
    }
    Initialize-AIOLangDirectory -Path $MountPath -Empty

    # Registrar antes de invocar DISM. Si DISM monta la imagen y una validacion
    # posterior falla, la rutina global de recuperacion aun podra descartarla.
    if ($MountPath -notin $script:AIOLangMountedPaths) {
        [void]$script:AIOLangMountedPaths.Add($MountPath)
    }

    try {
        $mountArguments = @(
            '/Mount-Image', "/ImageFile:$ImagePath", "/Index:$Index", "/MountDir:$MountPath", "/ScratchDir:$ScratchPath"
        )
        if ($ReadOnly) { $mountArguments += '/ReadOnly' }
        [void](Invoke-AIOLangDism -Arguments $mountArguments -Context $Context)
    }
    catch {
        # La ruta permanece registrada para Clear-AIOLangMountedImages. Si el
        # montaje nunca se creo, DISM devolvera un error controlado al descartar.
        throw
    }
}

function Dismount-AIOLangImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [ValidateSet('Commit', 'Discard')] [string]$Mode,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$NoThrow
    )

    # --- INYECCIÓN DE SEGURIDAD: Liberación forzada de handles ---
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()

    $action = if ($Mode -eq 'Commit') { '/Commit' } else { '/Discard' }
    $arguments = @('/Unmount-Image', "/MountDir:$MountPath", $action)
    if ($Mode -eq 'Commit') { $arguments += '/CheckIntegrity' }
    
    $result = Invoke-AIOLangDism -Arguments $arguments -Context $Context -NoThrow:$NoThrow
    
    if ($result.Success) {
        [void]$script:AIOLangMountedPaths.Remove($MountPath)
        if (Test-Path -LiteralPath $MountPath) {
            Get-ChildItem -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $result
}

function Clear-AIOLangMountedImages {
    [CmdletBinding()]
    param()

    foreach ($mountPath in @($script:AIOLangMountedPaths | Select-Object -Unique)) {
        try {
            $result = Dismount-AIOLangImage -MountPath $mountPath -Mode Discard -Context "Descartar montaje pendiente $mountPath" -NoThrow
            if ($result.Success) { continue }
        }
        catch { Write-AIOLangLog -Level WARN -Message "No se pudo desmontar '${mountPath}': $($_.Exception.Message)" }

        # Si /Mount-Image fallo antes de crear el montaje, solo liberar la
        # ruta cuando DISM confirme que ya no figura en su registro.
        try {
            $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop)
            $pending = @($mounted | Where-Object {
                ([string]$_.Path).TrimEnd('\', '/') -ieq $mountPath.TrimEnd('\', '/')
            })
            if ($pending.Count -eq 0) {
                [void]$script:AIOLangMountedPaths.Remove($mountPath)
                continue
            }
        }
        catch { Write-AIOLangLog -Level WARN -Message "No se pudo comprobar el estado de '${mountPath}': $($_.Exception.Message)" }
        Write-AIOLangLog -Level WARN -Message "Se conserva el montaje pendiente '$mountPath' y su carpeta de trabajo."
    }
    return ($script:AIOLangMountedPaths.Count -eq 0)
}

function Expand-AIOLangCabNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$CabPath,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [string[]]$FilePatterns = @('*'),
        [switch]$AllowEmpty
    )

    if (-not (Test-Path -LiteralPath $script:AIOLangExpandPath -PathType Leaf)) {
        throw "No se encontro expand.exe en '$script:AIOLangExpandPath'."
    }
    if (-not (Test-Path -LiteralPath $CabPath -PathType Leaf)) {
        throw "No existe el CAB '$CabPath'."
    }

    Initialize-AIOLangDirectory -Path $Destination
    $before = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue).Count
    $attempts = New-Object System.Collections.Generic.List[object]

    foreach ($filePattern in @($FilePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        # No usar -i: expand.exe conserva la estructura de directorios del CAB.
        $output = @(& $script:AIOLangExpandPath $CabPath ("-F:$filePattern") $Destination 2>&1)
        $exitCode = [int]$LASTEXITCODE
        [void]$attempts.Add([pscustomobject]@{
            Pattern  = $filePattern
            ExitCode = $exitCode
            Output   = [string[]]$output
        })
    }

    $after = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue).Count
    $extracted = [int]($after - $before)
    if ($extracted -le 0 -and -not $AllowEmpty) {
        $details = @($attempts | ForEach-Object { "Patron '$($_.Pattern)' codigo $($_.ExitCode)" }) -join '; '
        throw "expand.exe no extrajo archivos de '$CabPath'. $details"
    }

    return [pscustomobject]@{
        ArchivePath    = $CabPath
        Destination    = $Destination
        ExtractedFiles = $extracted
        Attempts       = [object[]]$attempts.ToArray()
    }
}


function Get-AIOLangImageIndexes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$ImagePath)

    $indexes = New-Object System.Collections.Generic.List[int]
    $query = Invoke-AIOLangDism -Arguments @('/Get-ImageInfo', "/ImageFile:$ImagePath") -Context "Inspeccionar imagen $([System.IO.Path]::GetFileName($ImagePath))" -Quiet -NoThrow
    if ($query.Success) {
        foreach ($line in @($query.Output)) {
            if ([string]$line -match '(?i)^\s*Index\s*:\s*(\d+)\s*$') {
                $index = [int]$matches[1]
                if ($index -gt 0 -and $index -notin $indexes) { [void]$indexes.Add($index) }
            }
        }
    }

    if ($indexes.Count -eq 0 -and (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue)) {
        try {
            foreach ($image in @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)) {
                $index = [int]$image.ImageIndex
                if ($index -gt 0 -and $index -notin $indexes) { [void]$indexes.Add($index) }
            }
        }
        catch {}
    }

    if ($indexes.Count -eq 0) { throw "No se pudieron enumerar indices en '$ImagePath' con el DISM activo." }
    return [int[]]@($indexes.ToArray() | Sort-Object -Unique)
}

function Get-AIOLangImageDetailFromDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [int]$Index
    )

    $query = Invoke-AIOLangDism -Arguments @('/Get-ImageInfo', "/ImageFile:$ImagePath", "/Index:$Index") -Context "Consultar metadatos $([System.IO.Path]::GetFileName($ImagePath)) indice $Index" -Quiet -NoThrow
    if (-not $query.Success) { return $null }

    $fields = @{}
    $languages = New-Object System.Collections.Generic.List[string]
    $defaultLanguage = $null
    $inLanguages = $false
    foreach ($rawLine in @($query.Output)) {
        $line = [string]$rawLine
        if ($line -match '^\s*Languages\s*:\s*$') { $inLanguages = $true; continue }
        if ($inLanguages) {
            if ($line -match '^\s+([a-z]{2,3}(?:-[a-z]{4})?-[a-z]{2})(?:\s+\(Default\))?\s*$') {
                $locale = Normalize-AIOLangLocale -Locale $matches[1]
                if ($locale -and $locale -notin $languages) { [void]$languages.Add($locale) }
                if ($line -match '(?i)\(Default\)') { $defaultLanguage = $locale }
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($line)) { $inLanguages = $false }
        }
        if ($line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
            $key = ($matches[1] -replace '\s+', '').ToLowerInvariant()
            $fields[$key] = $matches[2]
        }
    }

    $version = $null
    try { if ($fields.ContainsKey('version')) { $version = [version]$fields['version'] } } catch {}
    if (-not $version) { return $null }
    $architecture = if ($fields.ContainsKey('architecture')) { Convert-AIOLangArchitectureName -Architecture $fields['architecture'] } else { 'Unknown' }
    $editionId = $null
    foreach ($key in @('edition','editionid')) { if ($fields.ContainsKey($key) -and $fields[$key]) { $editionId = [string]$fields[$key]; break } }
    $installationType = $null
    foreach ($key in @('installation','installationtype')) { if ($fields.ContainsKey($key) -and $fields[$key]) { $installationType = [string]$fields[$key]; break } }
    if (-not $defaultLanguage -and $languages.Count -eq 1) { $defaultLanguage = $languages[0] }

    return [pscustomobject]@{
        ImageIndex       = $Index
        ImageName        = $(if ($fields.ContainsKey('name')) { [string]$fields['name'] } else { '' })
        ImageDescription = $(if ($fields.ContainsKey('description')) { [string]$fields['description'] } else { '' })
        Architecture     = $architecture
        Version          = $version
        Build            = [int]$version.Build
        DefaultLanguage  = $defaultLanguage
        Languages        = [string[]]$languages.ToArray()
        InstallationType = $installationType
        EditionId        = $editionId
    }
}

function Get-AIOLangImageRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$ImagePath)

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($index in @(Get-AIOLangImageIndexes -ImagePath $ImagePath)) {
        $detail = Get-AIOLangImageDetailFromDism -ImagePath $ImagePath -Index $index
        if (-not $detail -and (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue)) {
            try {
                $legacy = Get-WindowsImage -ImagePath $ImagePath -Index $index -ErrorAction Stop
                $langs = New-Object System.Collections.Generic.List[string]
                foreach ($propertyName in @('Languages','Language')) {
                    $property = $legacy.PSObject.Properties[$propertyName]
                    if ($property -and $property.Value) {
                        foreach ($language in @($property.Value)) {
                            $normalized = Normalize-AIOLangLocale -Locale ([string]$language)
                            if ($normalized -and $normalized -notin $langs) { [void]$langs.Add($normalized) }
                        }
                    }
                }
                $defaultLanguage = $null
                foreach ($propertyName in @('DefaultLanguage','Default Language','Language')) {
                    $property = $legacy.PSObject.Properties[$propertyName]
                    if ($property -and $property.Value) { $defaultLanguage = Normalize-AIOLangLocale -Locale ([string]$property.Value); break }
                }
                $editionId = $null
                foreach ($propertyName in @('EditionId','EditionID','Edition')) {
                    $property = $legacy.PSObject.Properties[$propertyName]
                    if ($property -and $property.Value) { $editionId = [string]$property.Value; break }
                }
                $detail = [pscustomobject]@{
                    ImageIndex       = [int]$legacy.ImageIndex
                    ImageName        = [string]$legacy.ImageName
                    ImageDescription = [string]$legacy.ImageDescription
                    Architecture     = Convert-AIOLangArchitectureName -Architecture $legacy.Architecture
                    Version          = [version]$legacy.Version
                    Build            = [int]([version]$legacy.Version).Build
                    DefaultLanguage  = $defaultLanguage
                    Languages        = [string[]]$langs.ToArray()
                    InstallationType = [string]$legacy.InstallationType
                    EditionId        = $editionId
                }
            }
            catch {}
        }
        if (-not $detail) { throw "No se pudieron obtener metadatos verificables del indice $index en '$ImagePath'." }
        [void]$records.Add($detail)
    }
    return [object[]]$records.ToArray()
}

function Get-AIOLangEsdImageIndexes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$EsdPath)

    return [int[]]@(Get-AIOLangImageIndexes -ImagePath $EsdPath)
}


function Expand-AIOLangEsdNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$EsdPath,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $EsdPath -PathType Leaf)) {
        throw "No existe el ESD '$EsdPath'."
    }

    Initialize-AIOLangDirectory -Path $Destination -Empty
    $indexes = @(Get-AIOLangEsdImageIndexes -EsdPath $EsdPath)
    if ($indexes.Count -eq 0) {
        throw "DISM no pudo identificar indices aplicables dentro de '$EsdPath'."
    }

    foreach ($index in $indexes) {
        $applyRoot = if ($indexes.Count -eq 1) { $Destination } else { Join-Path $Destination ("Index_{0}" -f $index) }
        Initialize-AIOLangDirectory -Path $applyRoot -Empty
        $arguments = @('/Apply-Image', "/ImageFile:$EsdPath", "/Index:$index", "/ApplyDir:$applyRoot", '/CheckIntegrity')
        $nativeScratch = if ($script:AIOLangSessionRoot) { Join-Path $script:AIOLangSessionRoot 'Scratch' } else { $null }
        if ($nativeScratch -and (Test-Path -LiteralPath $nativeScratch -PathType Container)) {
            $arguments += "/ScratchDir:$nativeScratch"
        }
        [void](Invoke-AIOLangDism -Arguments $arguments -Context "Extraer ESD $([System.IO.Path]::GetFileName($EsdPath)) - indice $index/$($indexes.Count)" -Quiet)
    }

    $count = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($count -eq 0) { throw "DISM no extrajo archivos de '$EsdPath'." }
    return $Destination
}

function Get-AIOLangExecutableVersion {
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

function Get-AIOLangRegistryKitsRoots {
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

function Get-AIOLangAdkUninstallLocations {
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

function Find-AIOLangAdkDismPath {
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

function Get-AIOLangAdkInfo {
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

    foreach ($entry in Get-AIOLangRegistryKitsRoots) { & $addCandidate $entry.Path $entry.Source }
    foreach ($entry in Get-AIOLangAdkUninstallLocations) { & $addCandidate $entry.Path $entry.Source }

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
        (Join-Path $script:AIOLangApplicationRoot 'WinPE'),
        (Join-Path $script:AIOLangApplicationRoot 'Tools\WinPE')
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
            Find-AIOLangAdkDismPath -DeploymentToolsRoot $deploymentToolsRoot
        }
        else { $null }

        $architectures = New-Object System.Collections.Generic.List[string]
        # No se enumeran recursivamente los CAB del Add-on durante la deteccion
        # inicial. Ese recorrido era costoso y se repetia antes de conocer la
        # arquitectura e idiomas requeridos por el medio. El inventario se
        # difiere y se limita despues a las carpetas realmente aplicables.
        $localizedPackageCount = -1
        if (Test-Path -LiteralPath $winPeRoot -PathType Container) {
            foreach ($architectureName in @($script:AIOLangPolicy.WinPEFolderMap.Keys)) {
                $folder = [string]$script:AIOLangPolicy.WinPEFolderMap[$architectureName]
                $ocRoot = Join-Path $winPeRoot "$folder\WinPE_OCs"
                if (Test-Path -LiteralPath $ocRoot -PathType Container) {
                    [void]$architectures.Add([string]$architectureName)
                }
            }
        }

        if ($dismPath -or $architectures.Count -gt 0) {
            [void]$records.Add([pscustomobject]@{
                Root                  = $adkRoot
                Source                = $candidateMap[$adkRoot]
                DeploymentToolsRoot   = $(if ($dismPath) { $deploymentToolsRoot } else { $null })
                DismPath              = $dismPath
                DismVersion           = Get-AIOLangExecutableVersion -Path $dismPath
                WinPERoot             = $(if ($architectures.Count -gt 0) { $winPeRoot } else { $null })
                WinPEArchitectures    = [string[]]$architectures.ToArray()
                WinPELocalizedPackages = $localizedPackageCount
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

    $adkInstalled = [bool](@($recordArray | Where-Object {
        $_.DeploymentToolsRoot -or ([string]$_.Root -match '(?i)\\Windows Kits\\10\\Assessment and Deployment Kit$')
    }).Count -gt 0)

    return [pscustomobject]@{
        Detected                = ($null -ne $primary)
        AdkInstalled            = $adkInstalled
        Root                    = $(if ($primary) { $primary.Root } else { $null })
        DetectionSources        = [string[]]@($recordArray | Select-Object -ExpandProperty Source -Unique)
        DeploymentToolsRoot     = $(if ($dismRecord) { $dismRecord.DeploymentToolsRoot } else { $null })
        DismPath                = $(if ($dismRecord) { $dismRecord.DismPath } else { $null })
        DismVersion             = $(if ($dismRecord) { $dismRecord.DismVersion } else { $null })
        WinPERoot               = $(if ($winPeRecord) { $winPeRecord.WinPERoot } else { $null })
        WinPEArchitectures      = $(if ($winPeRecord) { [string[]]$winPeRecord.WinPEArchitectures } else { [string[]]@() })
        WinPELocalizedPackages  = $(if ($winPeRecord) { [int]$winPeRecord.WinPELocalizedPackages } else { 0 })
        ActiveDismPath          = $null
        ActiveDismVersion       = $null
        ActiveDismSource        = $null
    }
}

function Initialize-AIOLangServicingEnvironment {
    [CmdletBinding()]
    param()

    $adkInfo = Get-AIOLangAdkInfo
    $systemVersion = Get-AIOLangExecutableVersion -Path $script:AIOLangSystemDismPath
    $selectedPath = $script:AIOLangSystemDismPath
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

    $script:AIOLangDismPath = $selectedPath
    $script:AIOLangDismSource = $selectedSource
    $adkInfo.ActiveDismPath = $selectedPath
    $adkInfo.ActiveDismVersion = $selectedVersion
    $adkInfo.ActiveDismSource = $selectedSource
    $script:AIOLangAdkInfo = $adkInfo
    return $adkInfo
}

function Show-AIOLangAdkStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$AdkInfo,
        [AllowEmptyCollection()] [string[]]$MediaArchitectures = @()
    )

    $mediaArchitectureNames = @($MediaArchitectures | Where-Object { $_ -and $_ -ne 'Unknown' } | Select-Object -Unique)
    $mediaArchitectureText = if ($mediaArchitectureNames.Count -gt 0) { $mediaArchitectureNames -join ', ' } else { 'N/D' }
    Write-Host " Arquitecturas del medio : $mediaArchitectureText" -ForegroundColor White

    $adkInstalled = if ($AdkInfo.PSObject.Properties['AdkInstalled']) { [bool]$AdkInfo.AdkInstalled } else { [bool]$AdkInfo.Detected }
    if ($adkInstalled) {
        Write-Host ' ADK                    : Instalado/detectado' -ForegroundColor Green
        if ($AdkInfo.Root -and [string]$AdkInfo.Root -match '(?i)Windows Kits') { Write-Host " Ruta ADK               : $($AdkInfo.Root)" -ForegroundColor White }
    }
    else {
        Write-Host ' ADK                    : No instalado/detectado' -ForegroundColor Yellow
    }

    if ($AdkInfo.WinPERoot) {
        $architectures = if (@($AdkInfo.WinPEArchitectures).Count -gt 0) { @($AdkInfo.WinPEArchitectures) -join ', ' } else { 'N/D' }
        Write-Host ' Fuente WinPE           : Detectada' -ForegroundColor Green
        Write-Host " Arquitecturas en fuente : $architectures (disponibles)" -ForegroundColor White
        Write-Host " Ruta WinPE             : $($AdkInfo.WinPERoot)" -ForegroundColor DarkGray
    }
    else {
        Write-Host ' Fuente WinPE           : No detectada; boot.wim puede usar SetupResourcesOnly y WinRE solo usa CAB compatibles del repositorio.' -ForegroundColor DarkYellow
    }

    $versionText = if ($AdkInfo.ActiveDismVersion) { [string]$AdkInfo.ActiveDismVersion } else { 'N/D' }
    Write-Host " DISM activo            : $($AdkInfo.ActiveDismSource) | $versionText" -ForegroundColor White
    Write-Host " Ruta DISM              : $($AdkInfo.ActiveDismPath)" -ForegroundColor DarkGray
}

function Get-AIOLangServicingBuildEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]]$Paths,
        [Parameter(Mandatory = $true)] [string]$Architecture
    )

    $evidence = New-Object System.Collections.Generic.List[object]
    # Identidades de la base y de sus idiomas. No aceptar LCUs, FOD ajenos,
    # WinSxS, un CAB del repositorio o una cadena de version en otro archivo.
    $identity = 'Microsoft-Windows-(?:(?:Client|Server|WinPE)-LanguagePack|Foundation|WinPE)-Package'
    $pattern = '(?i)^[\\/]?Windows[\\/]servicing[\\/]Packages[\\/](' + $identity + ')~31bf3856ad364e35~([^~]+)~[^~]*~(\d+\.\d+\.\d+\.\d+)\.mum$'
    foreach ($path in $Paths) {
        if ([string]$path -notmatch $pattern) { continue }
        $name = $matches[1]; $arch = $matches[2]; $version = [version]$matches[3]
        if ((Convert-AIOLangArchitectureName -Architecture $arch) -ne $Architecture) { continue }
        if ($version.Build -le 0) { continue }
        [void]$evidence.Add([pscustomobject]@{ Build = $version.Build; Identity = $name; Path = $path })
    }
    return [object[]]$evidence.ToArray()
}

function Get-AIOLangImageServicingEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$Architecture
    )

    $file = Get-Item -LiteralPath $ImagePath -ErrorAction Stop
    $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $file.FullName, $Index, $file.Length, $file.LastWriteTimeUtc.Ticks, $Architecture, $script:AIOLangDismPath
    if (-not $script:AIOLangImageServicingCache) { $script:AIOLangImageServicingCache = @{} }
    if ($script:AIOLangImageServicingCache.ContainsKey($key)) {
        return [object[]]$script:AIOLangImageServicingCache[$key]
    }
    # List-Image lee la metadata del contenedor WIM/ESD sin montar, exportar
    # ni modificar el medio. La aplicabilidad final se consulta en CBS.
    $listing = Invoke-AIOLangDism -Arguments @('/List-Image', "/ImageFile:$ImagePath", "/Index:$Index") -Context "Consultar base CBS del indice $Index" -Quiet
    $paths = [string[]]@($listing.Output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '(?i)^[\\/]?Windows[\\/]servicing[\\/]Packages[\\/].+\.mum$' })
    $evidence = @(Get-AIOLangServicingBuildEvidence -Paths $paths -Architecture $Architecture)
    $script:AIOLangImageServicingCache[$key] = [object[]]$evidence
    $bases = @($evidence | Select-Object -ExpandProperty Build -Unique | Sort-Object)
    Write-AIOLangLog -Level INFO -Message "Base CBS observada: '$ImagePath', indice $Index, $Architecture; builds=$($bases -join ',')."
    if ($bases.Count -eq 0) {
        Write-AIOLangLog -Level WARN -Message 'No se identifico una base CBS: solo se aceptara coincidencia exacta de build, sin inferir equivalencias.'
    }
    return [object[]]$evidence
}

function Get-AIOLangImageServicingBuilds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Image)
    if ($Image.PSObject.Properties['ServicingBuilds']) { return [int[]]@($Image.ServicingBuilds) }
    return [int[]]@()
}

function Test-AIOLangBuildCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$TargetBuild,
        [AllowNull()] [object]$PackageBuild,
        [AllowNull()] [AllowEmptyCollection()] [int[]]$ServicingBuilds = @()
    )

    [int]$package = 0
    if ($TargetBuild -le 0 -or $null -eq $PackageBuild -or
        -not [int]::TryParse([string]$PackageBuild, [ref]$package) -or $package -le 0) {
        return $false
    }
    # Las bases proceden de los paquetes del indice concreto, nunca del
    # repositorio ni de proximidad numerica entre versiones comerciales.
    $observed = @($ServicingBuilds | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($observed.Count -gt 0) { return ($package -in $observed) }
    return ($package -eq $TargetBuild)
}

function Get-AIOLangBuildFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$Build,
        [AllowEmptyCollection()] [int[]]$ReferenceBuilds = @(),
        [AllowNull()] [AllowEmptyCollection()] [int[]]$ServicingBuilds = @()
    )

    if ($Build -le 0) { return $Build }

    # Solo relacionar referencias con bases CBS observadas en el indice.
    # La mera presencia de un CAB en el repositorio no acredita compatibilidad.
    $compatibleReferences = @($ReferenceBuilds | Where-Object {
        $_ -gt 0 -and (Test-AIOLangBuildCompatibility -TargetBuild $Build -PackageBuild $_ -ServicingBuilds $ServicingBuilds)
    } | Sort-Object -Unique -Descending)

    if ($compatibleReferences.Count -gt 0) {
        return [int]$compatibleReferences[0]
    }

    return $Build
}

function Get-AIOLangBuildFamiliesFromImages {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]]$Images = @(),
        [AllowEmptyCollection()] [int[]]$ReferenceBuilds = @()
    )

    $families = New-Object System.Collections.Generic.List[int]
    foreach ($image in @($Images | Where-Object { $null -ne $_ })) {
        $build = 0
        try {
            if ($image.PSObject.Properties['Build'] -and $null -ne $image.Build) {
                $build = [int]$image.Build
            }
        }
        catch { $build = 0 }

        if ($build -le 0) { continue }
        $family = Get-AIOLangBuildFamily -Build $build -ReferenceBuilds $ReferenceBuilds -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $image)
        if ($family -gt 0 -and $family -notin $families) { [void]$families.Add($family) }
    }
    return [int[]]@($families.ToArray() | Sort-Object)
}

function Get-AIOLangBuildFamiliesFromPackages {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Packages = @())

    $builds = New-Object System.Collections.Generic.List[int]
    foreach ($package in @($Packages | Where-Object { $null -ne $_ })) {
        $build = 0
        try {
            if ($package.PSObject.Properties['Build'] -and $null -ne $package.Build) {
                $build = [int]$package.Build
            }
        }
        catch { $build = 0 }

        if ($build -gt 0 -and $build -notin $builds) { [void]$builds.Add($build) }
    }
    return [int[]]@($builds.ToArray() | Sort-Object)
}

function Normalize-AIOLangLocale {
    [CmdletBinding()]
    param([AllowNull()] [string]$Locale)

    if ([string]::IsNullOrWhiteSpace($Locale)) { return $null }
    $parts = $Locale.Trim().Replace('_', '-').Split('-')
    if ($parts.Count -eq 1) { return $parts[0].ToLowerInvariant() }
    if ($parts.Count -eq 2) {
        if ($parts[1].Length -eq 4) {
            return ('{0}-{1}' -f $parts[0].ToLowerInvariant(), ($parts[1].Substring(0,1).ToUpperInvariant() + $parts[1].Substring(1).ToLowerInvariant()))
        }
        return ('{0}-{1}' -f $parts[0].ToLowerInvariant(), $parts[1].ToUpperInvariant())
    }
    if ($parts.Count -ge 3) {
        return ('{0}-{1}-{2}' -f $parts[0].ToLowerInvariant(), ($parts[1].Substring(0,1).ToUpperInvariant() + $parts[1].Substring(1).ToLowerInvariant()), $parts[2].ToUpperInvariant())
    }
    return $Locale
}

function Get-AIOLangLocaleFromText {
    [CmdletBinding()]
    param([AllowNull()] [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $matches = [regex]::Matches($Text, '(?i)(?<![a-z])([a-z]{2,3}(?:-[a-z]{4})?-[a-z]{2})(?![a-z])')
    if ($matches.Count -gt 0) {
        return Normalize-AIOLangLocale -Locale $matches[$matches.Count - 1].Groups[1].Value
    }
    return $null
}

function Get-AIOLangArchitectureFromText {
    [CmdletBinding()]
    param([AllowNull()] [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -match '(?i)(?:^|[^a-z0-9])(amd64|x64|x86_64)(?:[^a-z0-9]|$)') { return 'x64' }
    if ($Text -match '(?i)(?:^|[^a-z0-9])(arm64|aarch64)(?:[^a-z0-9]|$)') { return 'arm64' }
    if ($Text -match '(?i)(?:^|[^a-z0-9])(x86|i386|i686)(?:[^a-z0-9]|$)') { return 'x86' }
    if ($Text -match '(?i)(?:^|[^a-z0-9])(arm)(?:[^a-z0-9]|$)') { return 'arm' }
    return $null
}

function Get-AIOLangVersionFromText {
    [CmdletBinding()]
    param([AllowNull()] [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $matches = [regex]::Matches($Text, '(?<!\d)(\d+\.\d+\.\d+\.\d+)(?!\d)')
    if ($matches.Count -gt 0) {
        try { return [version]$matches[$matches.Count - 1].Groups[1].Value }
        catch {}
    }
    return $null
}

function Get-AIOLangArchiveMetadataFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PackagePath,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    Initialize-AIOLangDirectory -Path $Destination -Empty
    $extension = [System.IO.Path]::GetExtension($PackagePath).ToLowerInvariant()

    try {
        switch ($extension) {
            '.cab' {
                [void](Expand-AIOLangCabNative -CabPath $PackagePath -Destination $Destination -FilePatterns @('*.mum', 'langcfg.ini') -AllowEmpty)
            }
            '.esd' {
                [void](Expand-AIOLangEsdNative -EsdPath $PackagePath -Destination $Destination)
            }
            default { return $false }
        }
    }
    catch {
        Write-AIOLangLog -Level WARN -Message "No se pudieron extraer metadatos de '$PackagePath': $($_.Exception.Message)"
        return $false
    }

    return (@(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -ieq '.mum' -or $_.Name -ieq 'langcfg.ini'
    }).Count -gt 0)
}

function Read-AIOLangAssemblyIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MumPath)

    $text = Get-Content -LiteralPath $MumPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $name = $null; $arch = $null; $language = $null; $version = $null; $token = $null
    try {
        [xml]$xml = $text
        $node = $xml.SelectSingleNode("//*[local-name()='assemblyIdentity']")
        if ($node) {
            $name = [string]$node.name
            $arch = [string]$node.processorArchitecture
            $language = [string]$node.language
            $version = [string]$node.version
            $token = [string]$node.publicKeyToken
        }
    }
    catch {}

    if (-not $name -and $text -match '(?is)<assemblyIdentity\b[^>]*\bname\s*=\s*["'']([^"'']+)') { $name = $matches[1] }
    if (-not $arch -and $text -match '(?is)<assemblyIdentity\b[^>]*\bprocessorArchitecture\s*=\s*["'']([^"'']+)') { $arch = $matches[1] }
    if (-not $language -and $text -match '(?is)<assemblyIdentity\b[^>]*\blanguage\s*=\s*["'']([^"'']+)') { $language = $matches[1] }
    if (-not $version -and $text -match '(?is)<assemblyIdentity\b[^>]*\bversion\s*=\s*["'']([^"'']+)') { $version = $matches[1] }
    if (-not $token -and $text -match '(?is)<assemblyIdentity\b[^>]*\bpublicKeyToken\s*=\s*["'']([^"'']+)') { $token = $matches[1] }

    if (-not $name) { return $null }
    $versionObject = $null
    try { if ($version) { $versionObject = [version]$version } } catch {}
    $locale = if ($language -and $language -ne 'neutral' -and $language -ne '*') { Normalize-AIOLangLocale -Locale $language } else { Get-AIOLangLocaleFromText -Text $name }
    $architecture = if ($arch) { Convert-AIOLangArchitectureName -Architecture $arch } else { Get-AIOLangArchitectureFromText -Text $name }
    $packageName = if ($token -and $arch -and $version) {
        '{0}~{1}~{2}~{3}~{4}' -f $name, $token, $arch, $(if ($language -and $language -notin @('*', 'neutral')) { $language } else { '' }), $version
    }
    else { $null }

    return [pscustomobject]@{
        Name         = $name
        Architecture = $architecture
        Locale       = $locale
        Version      = $versionObject
        PackageName  = $packageName
        MumPath      = $MumPath
    }
}


function Get-AIOLangPackageProductFamily {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$IdentityName,
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [AllowNull()] [string]$Category
    )

    if ($Category -eq 'WinPE') { return 'WinPE' }
    $textValue = (([string]$IdentityName) + ' ' + $FilePath).ToLowerInvariant()
    if ($textValue -match $script:AIOLangPolicy.ProductPatterns.Server) { return 'Server' }
    if ($textValue -match $script:AIOLangPolicy.ProductPatterns.Client) { return 'Client' }
    if ($textValue -match $script:AIOLangPolicy.ProductPatterns.WinPE) { return 'WinPE' }
    return 'Neutral'
}

function Get-AIOLangImageProductFamily {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Image)

    $installationType = if ($Image.PSObject.Properties['InstallationType']) { [string]$Image.InstallationType } else { '' }
    $name = if ($Image.PSObject.Properties['ImageName']) { [string]$Image.ImageName } else { '' }
    $description = if ($Image.PSObject.Properties['ImageDescription']) { [string]$Image.ImageDescription } else { '' }
    $combined = "$installationType $name $description"
    if ($combined -match '(?i)(Windows PE|Windows Setup|WinPE)') { return 'WinPE' }
    if ($combined -match '(?i)(Server|Azure Stack HCI)') { return 'Server' }
    if ($installationType -match '(?i)Client') { return 'Client' }
    return 'Client'
}

function Test-AIOLangProductCompatibility {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$ImageFamily,
        [AllowNull()] [string]$PackageFamily,
        [AllowNull()] [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($PackageFamily) -or $PackageFamily -eq 'Neutral') { return $true }
    if ([string]::IsNullOrWhiteSpace($ImageFamily) -or $ImageFamily -eq 'Unknown') { return $true }
    if ($Category -eq 'WinPE') { return ($PackageFamily -in @('WinPE','Neutral')) }
    if ($ImageFamily -eq 'WinPE') { return $true }
    return ($ImageFamily -eq $PackageFamily)
}

function Test-AIOLangEditionSupportsAdditionalLanguages {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Image)

    $editionId = if ($Image.PSObject.Properties['EditionId']) { [string]$Image.EditionId } else { '' }
    $name = if ($Image.PSObject.Properties['ImageName']) { [string]$Image.ImageName } else { '' }
    return -not (("$editionId $name") -match $script:AIOLangPolicy.RestrictedMultilingualEditionPattern)
}

function Assert-AIOLangEditionLanguageSupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [int[]]$Indexes
    )

    $restricted = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes -and -not (Test-AIOLangEditionSupportsAdditionalLanguages -Image $_) })
    if ($restricted.Count -gt 0) {
        $details = @($restricted | ForEach-Object {
            $edition = if ($_.PSObject.Properties['EditionId'] -and $_.EditionId) { $_.EditionId } else { $_.ImageName }
            "indice $($_.ImageIndex): $edition"
        }) -join '; '
        throw "Las siguientes ediciones restringen la adicion de idiomas completos: $details. Selecciona una edicion multilingue compatible."
    }
}

function Assert-AIOLangProductFamilyConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [int[]]$Indexes
    )

    $selected = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes })
    $families = @($selected | ForEach-Object {
        if ($_.PSObject.Properties['ProductFamily'] -and $_.ProductFamily) { [string]$_.ProductFamily }
        else { Get-AIOLangImageProductFamily -Image $_ }
    } | Where-Object { $_ -in @('Client','Server') } | Select-Object -Unique)
    if ($families.Count -gt 1) {
        throw "La seleccion mezcla imagenes Client y Server. Procesalas por separado para que los Language Packs y los recursos de Windows Setup mantengan una unica familia de producto."
    }
}

function Get-AIOLangPackageCategory {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$IdentityName,
        [Parameter(Mandatory = $true)] [string]$FilePath
    )

    $pathText = ($FilePath -replace '\\', '/').ToLowerInvariant()
    if ($pathText -match '/winpe_ocs/') { return 'WinPE' }

    # La identidad CBS es la autoridad para el resto de casos. El nombre y la
    # carpeta solo se usan cuando el contenedor no expone una identidad
    # utilizable.
    $identityText = ([string]$IdentityName).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($identityText)) {
        if ($identityText -match 'winpe[_/-]|winpe-') { return 'WinPE' }
        if ($identityText -match 'languagepack-package|language-pack|client-languagepack|server-languagepack|common-foundation-package') { return 'LanguagePack' }
        if ($identityText -match 'languagefeatures-|internationalfeatures|languageexperience|languagecomponents') { return 'LanguageFOD' }
    }

    $fallbackText = (([System.IO.Path]::GetFileName($FilePath) + ' ' + $FilePath) -replace '\\', '/').ToLowerInvariant()
    if ($fallbackText -match 'winpe[_/-]|winpe-|/winpe/') { return 'WinPE' }
    if ($fallbackText -match 'languagepack-package|language-pack|client-languagepack|server-languagepack|common-foundation-package|(?:^|/)lp\.(?:cab|esd)$') { return 'LanguagePack' }
    if ($fallbackText -match 'languagefeatures-|internationalfeatures|languageexperience|languagecomponents') { return 'LanguageFOD' }
    if ($fallbackText -match '/(fod|featuresondemand|ondemand|languagesandoptionalfeatures)/|(?:^|[-_/])fod(?:[-_./]|$)') { return 'LanguageFOD' }
    return 'Unknown'
}

function Get-AIOLangPackagePriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Category,
        [AllowNull()] [string]$IdentityName,
        [Parameter(Mandatory = $true)] [string]$FilePath
    )

    $textValue = ($IdentityName + ' ' + [System.IO.Path]::GetFileName($FilePath)).ToLowerInvariant()
    if ($Category -eq 'LanguagePack') { return 0 }
    if ($Category -eq 'WinPE') {
        if (Test-AIOLangPolicyPatternSet -Text $textValue -Patterns ([string[]]$script:AIOLangPolicy.WinPEFontSupportPatterns)) { return 15 }
        foreach ($rule in @($script:AIOLangPolicy.WinPEPriorityRules)) {
            if ($textValue -match [string]$rule.Pattern) { return [int]$rule.Priority }
        }
        return 35
    }
    foreach ($rule in @($script:AIOLangPolicy.FodPriorityRules)) {
        if ($textValue -match [string]$rule.Pattern) { return [int]$rule.Priority }
    }
    return 75
}

function Get-AIOLangPreferredPackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Identities,
        [Parameter(Mandatory = $true)] [string]$PackagePath
    )

    if (-not $Identities -or $Identities.Count -eq 0) { return $null }
    $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath).ToLowerInvariant()

    $preferred = @($Identities | Sort-Object @{ Expression = {
        $identityName = ([string]$_.Name).ToLowerInvariant()
        $score = 500

        # La identidad cuyo nombre coincide con el CAB tiene prioridad absoluta.
        # Algunos CAB contienen manifiestos auxiliares (por ejemplo WordBreaking)
        # que no representan el paquete principal y antes podian usarse como etiqueta.
        if (-not [string]::IsNullOrWhiteSpace($identityName)) {
            if ($fileStem.StartsWith($identityName)) { $score = 0 }
            elseif ($fileStem.Contains($identityName)) { $score = 5 }
            elseif ($fileStem -match 'languagefeatures-texttospeech' -and $identityName -match 'languagefeatures-texttospeech') { $score = 10 }
            elseif ($fileStem -match 'languagefeatures-handwriting' -and $identityName -match 'languagefeatures-handwriting') { $score = 10 }
            elseif ($fileStem -match 'languagefeatures-speech' -and $identityName -match 'languagefeatures-speech') { $score = 10 }
            elseif ($fileStem -match 'languagefeatures-basic' -and $identityName -match 'languagefeatures-basic') { $score = 10 }
            elseif ($fileStem -match 'languagefeatures-ocr' -and $identityName -match 'languagefeatures-ocr') { $score = 10 }
            elseif ($fileStem -match 'languagefeatures-fonts' -and $identityName -match 'languagefeatures-fonts') { $score = 10 }
            elseif ($fileStem -match 'languagepack|language-pack|client-languagepack|server-languagepack' -and $identityName -match 'languagepack|language-pack|client-languagepack|server-languagepack') { $score = 20 }
            elseif ($fileStem -match 'winpe' -and $identityName -match 'winpe') { $score = 30 }
            elseif ($identityName -match 'languagefeatures|internationalfeatures') { $score = 60 }
            elseif ($identityName -match 'languagepack') { $score = 65 }
            elseif ($identityName -match 'common-foundation') { $score = 72 }
            elseif ($identityName -match 'winpe') { $score = 80 }
        }
        $score
    }}, @{ Expression = { ([string]$_.Name).Length }; Descending = $false }, Name | Select-Object -First 1)

    if ($preferred.Count -gt 0) { return $preferred[0] }
    return $null
}

function Get-AIOLangPackageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PackagePath,
        [Parameter(Mandatory = $true)] [string]$MetadataRoot
    )

    $resolved = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
    $file = Get-Item -LiteralPath $resolved -ErrorAction Stop
    $metadataCacheKey = ('{0}|{1}|{2}' -f $resolved.ToLowerInvariant(), [int64]$file.Length, [int64]$file.LastWriteTimeUtc.Ticks)
    if ($script:AIOLangPackageMetadataCache.ContainsKey($metadataCacheKey)) {
        $script:AIOLangOptimizationStats.MetadataCacheHits++
        return $script:AIOLangPackageMetadataCache[$metadataCacheKey]
    }
    $nameText = $file.Name + ' ' + $file.DirectoryName
    $architecture = Get-AIOLangArchitectureFromText -Text $nameText
    $locale = Get-AIOLangLocaleFromText -Text $nameText
    $version = Get-AIOLangVersionFromText -Text $nameText
    $identityName = $null
    $packageName = $null
    $detectedProductFamily = 'Neutral'
    $reason = 'Clasificacion por nombre y ruta.'
    $supported = $true

    $metaDir = Join-Path $MetadataRoot ([guid]::NewGuid().ToString('N'))
    $expanded = $false
    try { $expanded = Get-AIOLangArchiveMetadataFiles -PackagePath $resolved -Destination $metaDir }
    catch { $expanded = $false }

    if ($expanded) {
        $ini = Get-ChildItem -LiteralPath $metaDir -Recurse -File -Filter 'langcfg.ini' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ini) {
            foreach ($line in Get-Content -LiteralPath $ini.FullName -ErrorAction SilentlyContinue) {
                if ($line -match '(?i)^\s*Language\s*=\s*(.+?)\s*$') {
                    $locale = Normalize-AIOLangLocale -Locale $matches[1]
                    break
                }
            }
        }

        $identities = New-Object System.Collections.Generic.List[object]
        foreach ($mum in Get-ChildItem -LiteralPath $metaDir -Recurse -File -Filter '*.mum' -ErrorAction SilentlyContinue) {
            $identity = Read-AIOLangAssemblyIdentity -MumPath $mum.FullName
            if ($identity) { [void]$identities.Add($identity) }
        }

        $identityNames = @($identities.ToArray() | Select-Object -ExpandProperty Name -Unique)
        $allIdentityText = ($identityNames -join ' ')
        if ($allIdentityText -match $script:AIOLangPolicy.ProductPatterns.Server) { $detectedProductFamily = 'Server' }
        elseif ($allIdentityText -match $script:AIOLangPolicy.ProductPatterns.Client) { $detectedProductFamily = 'Client' }
        elseif ($allIdentityText -match $script:AIOLangPolicy.ProductPatterns.WinPE) { $detectedProductFamily = 'WinPE' }

        $preferred = Get-AIOLangPreferredPackageIdentity -Identities ([object[]]$identities.ToArray()) -PackagePath $resolved

        if ($preferred) {
            $identityName = $preferred.Name
            if ($preferred.Architecture -and $preferred.Architecture -ne 'Unknown') { $architecture = $preferred.Architecture }
            if ($preferred.Locale) { $locale = $preferred.Locale }
            if ($preferred.Version) { $version = $preferred.Version }
            if ($preferred.PackageName) { $packageName = $preferred.PackageName }
            $reason = 'Clasificacion por manifiesto CBS principal coincidente con el archivo.'
        }
    }
    elseif ([System.IO.Path]::GetExtension($resolved).ToLowerInvariant() -eq '.esd') {
        $supported = $false
        $reason = 'No se pudo inspeccionar el ESD mediante DISM; el contenedor no expone indices aplicables o esta danado.'
    }

    if (Test-Path -LiteralPath $metaDir) {
        Remove-Item -LiteralPath $metaDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $category = Get-AIOLangPackageCategory -IdentityName $identityName -FilePath $resolved
    if (-not $identityName) { $identityName = [System.IO.Path]::GetFileNameWithoutExtension($resolved) }
    if (-not $locale) { $locale = Get-AIOLangLocaleFromText -Text $identityName }
    if (-not $architecture) { $architecture = Get-AIOLangArchitectureFromText -Text $identityName }
    if (-not $version) { $version = Get-AIOLangVersionFromText -Text $identityName }
    $architecture = if ($architecture) { Convert-AIOLangArchitectureName -Architecture $architecture } else { 'Unknown' }
    $build = if ($version) { [int]$version.Build } else { $null }

    if ($category -ne 'Unknown') {
        $metadataProblems = New-Object System.Collections.Generic.List[string]
        if (-not $locale) { [void]$metadataProblems.Add('idioma') }
        if ($architecture -eq 'Unknown') { [void]$metadataProblems.Add('arquitectura') }
        if ($null -eq $build -or $build -le 0) { [void]$metadataProblems.Add('build') }
        if ($metadataProblems.Count -gt 0) {
            $supported = $false
            $reason = "Metadatos incompletos: $($metadataProblems -join ', ')."
        }
    }

    $object = [pscustomobject]@{
        FilePath     = $resolved
        Name         = $file.Name
        Extension    = $file.Extension.ToLowerInvariant()
        Size         = [long]$file.Length
        Category     = $category
        Locale       = $locale
        Architecture = $architecture
        Version      = $version
        Build        = $build
        IdentityName = $identityName
        PackageName  = $packageName
        ProductFamily = $(if ($category -eq 'WinPE') { 'WinPE' } elseif ($detectedProductFamily -ne 'Neutral') { $detectedProductFamily } else { Get-AIOLangPackageProductFamily -IdentityName $identityName -FilePath $resolved -Category $category })
        Priority     = Get-AIOLangPackagePriority -Category $category -IdentityName $identityName -FilePath $resolved
        Supported    = $supported
        Reason       = $reason
    }
    $script:AIOLangPackageMetadataCache[$metadataCacheKey] = $object
    return $object
}

function Test-AIOLangCandidatePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [System.IO.FileInfo]$File)

    # No se exige que el nombre contenga "language", "FOD" o "WinPE".
    # La clasificacion real se realiza despues mediante manifiestos CBS,
    # langcfg.ini y metadatos del contenedor.
    return ($File.Extension -in @('.cab', '.esd'))
}

function Get-AIOLangAdkWinPEPackageFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WinPERoot,
        [AllowEmptyCollection()] [string[]]$LocaleFilter = @(),
        [AllowEmptyCollection()] [string[]]$ArchitectureFilter = @()
    )

    $resolved = (Resolve-Path -LiteralPath $WinPERoot -ErrorAction Stop).Path
    $locales = [string[]]@(
        $LocaleFilter |
            ForEach-Object { Normalize-AIOLangLocale -Locale $_ } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    $architectures = [string[]]@(
        $ArchitectureFilter |
            ForEach-Object { Convert-AIOLangArchitectureName -Architecture $_ } |
            Where-Object { $_ -and $_ -ne 'Unknown' } |
            Select-Object -Unique
    )
    if ($architectures.Count -eq 0) { $architectures = @('x64', 'x86', 'arm64', 'arm') }

    $folderMap = $script:AIOLangPolicy.WinPEFolderMap
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $seen = @{}

    foreach ($architecture in $architectures) {
        if (-not $folderMap.Contains($architecture)) { continue }
        $ocRoot = Join-Path $resolved "$($folderMap[$architecture])\WinPE_OCs"
        if (-not (Test-Path -LiteralPath $ocRoot -PathType Container)) { continue }

        if ($locales.Count -eq 0) {
            # Sin filtro de idioma se enumeran solo carpetas con formato locale,
            # no todo el arbol neutral del ADK.
            foreach ($directory in @(Get-ChildItem -LiteralPath $ocRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '^[a-z]{2,3}(?:-[a-z]{4})?-[a-z]{2}$'
            })) {
                foreach ($path in [System.IO.Directory]::EnumerateFiles($directory.FullName, '*.cab', [System.IO.SearchOption]::AllDirectories)) {
                    $key = $path.ToLowerInvariant()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$files.Add((New-Object System.IO.FileInfo -ArgumentList $path))
                    }
                }
            }
            continue
        }

        foreach ($locale in $locales) {
            $localeDirectory = Join-Path $ocRoot $locale
            if (Test-Path -LiteralPath $localeDirectory -PathType Container) {
                foreach ($path in [System.IO.Directory]::EnumerateFiles($localeDirectory, '*.cab', [System.IO.SearchOption]::AllDirectories)) {
                    $key = $path.ToLowerInvariant()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$files.Add((New-Object System.IO.FileInfo -ArgumentList $path))
                    }
                }
            }

            # Algunos complementos colocan CAB localizados en la raiz de WinPE_OCs.
            $escapedLocale = [regex]::Escape($locale)
            foreach ($path in [System.IO.Directory]::EnumerateFiles($ocRoot, '*.cab', [System.IO.SearchOption]::TopDirectoryOnly)) {
                $name = [System.IO.Path]::GetFileName($path)
                $isLocaleCab = [bool]($name -match "(?i)(?:_|-)$escapedLocale\.cab$")
                $isFontSupport = (Test-AIOLangPolicyPatternSet -Text $name -Patterns ([string[]]$script:AIOLangPolicy.WinPEFontSupportPatterns))
                if (-not $isLocaleCab -and -not ($isFontSupport -and $name -match "(?i)$escapedLocale")) { continue }
                $key = $path.ToLowerInvariant()
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    [void]$files.Add((New-Object System.IO.FileInfo -ArgumentList $path))
                }
            }
        }
    }

    return [System.IO.FileInfo[]]@($files.ToArray() | Sort-Object FullName)
}

function Get-AIOLangAdkProbeFiles {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [System.IO.FileInfo[]]$Files = @())

    return [System.IO.FileInfo[]]@(
        $Files |
            Group-Object {
                $architecture = Get-AIOLangArchitectureFromText -Text $_.FullName
                $locale = Get-AIOLangLocaleFromText -Text $_.FullName
                "$architecture|$locale"
            } |
            ForEach-Object {
                @($_.Group | Sort-Object @{ Expression = {
                    if ($_.Name -ieq 'lp.cab') { 0 }
                    elseif ($_.Name -match '(?i)languagepack|common-foundation') { 1 }
                    else { 2 }
                }}, Length, Name | Select-Object -First 1)[0]
            }
    )
}

function Get-AIOLangLogicalPackageKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $identity = if ($Package.IdentityName) { [string]$Package.IdentityName } else { [System.IO.Path]::GetFileNameWithoutExtension([string]$Package.Name) }
    $version = if ($Package.Version) { [string]$Package.Version } elseif ($Package.Build) { [string]$Package.Build } else { '0' }
    $productFamily = if ($Package.PSObject.Properties['ProductFamily'] -and $Package.ProductFamily) { [string]$Package.ProductFamily } else { 'Neutral' }
    return ('{0}|{1}|{2}|{3}|{4}|{5}' -f $Package.Category, $Package.Locale, $Package.Architecture, $productFamily, $identity, $version).ToLowerInvariant()
}

function Merge-AIOLangLogicalInventory {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Inventory = @())

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($Inventory | Where-Object { $null -ne $_ } | Group-Object { Get-AIOLangLogicalPackageKey -Package $_ })) {
        $sortProperties = @(
            @{ Expression = { if ($_.Supported) { 0 } else { 1 } } }
            @{ Expression = { if ($_.Source -eq 'Repositorio') { 0 } else { 1 } } }
            @{ Expression = { if ($_.Extension -eq '.cab') { 0 } elseif ($_.Extension -eq '.esd') { 1 } else { 2 } } }
            'Priority'
            'FilePath'
        )
        $ordered = @($group.Group | Sort-Object -Property $sortProperties)
        if ($ordered.Count -eq 0) { continue }
        $selected = $ordered[0]
        $alternates = [string[]]@($ordered | Select-Object -Skip 1 | Select-Object -ExpandProperty FilePath)
        if ($selected.PSObject.Properties['DuplicateCount']) { $selected.DuplicateCount = $ordered.Count }
        else { $selected | Add-Member -MemberType NoteProperty -Name DuplicateCount -Value $ordered.Count }
        if ($selected.PSObject.Properties['AlternateFiles']) { $selected.AlternateFiles = $alternates }
        else { $selected | Add-Member -MemberType NoteProperty -Name AlternateFiles -Value $alternates }
        [void]$result.Add($selected)
    }
    return [object[]]@($result.ToArray() | Sort-Object Category, Locale, Architecture, Priority, Name)
}

function Get-AIOLangRepositoryInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot,
        [string]$SourceName = 'Repositorio',
        [switch]$LocalizedWinPEOnly,
        [string[]]$LocaleFilter,
        [string[]]$ArchitectureFilter,
        [int[]]$TargetBuilds,
        [switch]$FastAdkProbe,
        [switch]$AllowEmpty
    )

    $normalizedLocales = [string[]]@(
        $LocaleFilter |
            ForEach-Object { Normalize-AIOLangLocale -Locale $_ } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    $normalizedArchitectures = [string[]]@(
        $ArchitectureFilter |
            ForEach-Object { Convert-AIOLangArchitectureName -Architecture $_ } |
            Where-Object { $_ -and $_ -ne 'Unknown' } |
            Select-Object -Unique
    )

    $files = if ($LocalizedWinPEOnly) {
        @(Get-AIOLangAdkWinPEPackageFiles -WinPERoot $RepositoryRoot -LocaleFilter $normalizedLocales -ArchitectureFilter $normalizedArchitectures)
    }
    else {
        @(Get-AIOLangRepositoryPackageFiles -RepositoryRoot $RepositoryRoot)
    }

    if ($SourceName -eq 'ADK WinPE') {
        $script:AIOLangAdkScanSummary = [pscustomobject]@{
            CandidateCount  = $files.Count
            AnalyzedCount   = 0
            FullScanSkipped = $false
            Reason          = $null
        }
    }

    $signatureLines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        [void]$signatureLines.Add(('{0}|{1}|{2}' -f $file.FullName.ToLowerInvariant(), [int64]$file.Length, [int64]$file.LastWriteTimeUtc.Ticks))
    }
    [void]$signatureLines.Add(('Locales={0};Architectures={1};Builds={2};Fast={3}' -f ($normalizedLocales -join ','), ($normalizedArchitectures -join ','), (@($TargetBuilds) -join ','), [bool]$FastAdkProbe))
    $inventoryCacheKey = Get-AIOLangTextSha256 -Text (([string]$SourceName + "`n" + ($signatureLines -join "`n")) + "`n")

    $rawInventory = $null
    if ($script:AIOLangRepositoryInventoryCache.ContainsKey($inventoryCacheKey)) {
        $script:AIOLangOptimizationStats.RepositoryCacheHits++
        $rawInventory = [object[]]$script:AIOLangRepositoryInventoryCache[$inventoryCacheKey]
        if ($SourceName -eq 'ADK WinPE' -and $script:AIOLangAdkScanSummary) {
            $script:AIOLangAdkScanSummary.AnalyzedCount = $rawInventory.Count
            $script:AIOLangAdkScanSummary.Reason = 'Inventario reutilizado desde cache de la sesion.'
        }
    }
    else {
        if ($files.Count -eq 0) {
            if ($AllowEmpty) { return [object[]]@() }
            throw 'No se encontraron archivos CAB/ESD en el repositorio seleccionado.'
        }

        $metadataRoot = Join-Path $ScratchRoot 'Metadata'
        Initialize-AIOLangDirectory -Path $metadataRoot -Empty
        $inventory = New-Object System.Collections.Generic.List[object]
        $scanFiles = [System.IO.FileInfo[]]$files
        $skipFullScan = $false

        try {
            if ($FastAdkProbe -and $LocalizedWinPEOnly -and @($TargetBuilds).Count -gt 0) {
                $probeFiles = @(Get-AIOLangAdkProbeFiles -Files $files)
                $probeInventory = New-Object System.Collections.Generic.List[object]
                foreach ($probeFile in $probeFiles) {
                    try {
                        $probeItem = Get-AIOLangPackageMetadata -PackagePath $probeFile.FullName -MetadataRoot $metadataRoot
                        if ($probeItem.Category -ne 'Unknown') {
                            if ($probeItem.PSObject.Properties['Source']) { $probeItem.Source = $SourceName }
                            else { $probeItem | Add-Member -MemberType NoteProperty -Name Source -Value $SourceName }
                            if ($probeItem.PSObject.Properties['SourceRoot']) { $probeItem.SourceRoot = $RepositoryRoot }
                            else { $probeItem | Add-Member -MemberType NoteProperty -Name SourceRoot -Value $RepositoryRoot }
                            [void]$probeInventory.Add($probeItem)
                        }
                    }
                    catch {
                        Write-AIOLangLog -Level WARN -Message "No se pudo sondear '$($probeFile.FullName)': $($_.Exception.Message)"
                    }
                }

                $probeItems = [object[]]$probeInventory.ToArray()
                $knownProbeBuilds = @($probeItems | Where-Object { $_.Build } | Select-Object -ExpandProperty Build -Unique)
                $hasCompatibleFamily = $false
                foreach ($targetBuild in @($TargetBuilds | Where-Object { $_ -gt 0 })) {
                    foreach ($packageBuild in $knownProbeBuilds) {
                        if (Test-AIOLangBuildCompatibility -TargetBuild $targetBuild -PackageBuild $packageBuild) {
                            $hasCompatibleFamily = $true
                            break
                        }
                    }
                    if ($hasCompatibleFamily) { break }
                }

                if ($probeItems.Count -gt 0 -and $knownProbeBuilds.Count -gt 0 -and -not $hasCompatibleFamily) {
                    foreach ($probeItem in $probeItems) { [void]$inventory.Add($probeItem) }
                    $skipFullScan = $true
                    if ($script:AIOLangAdkScanSummary) {
                        $script:AIOLangAdkScanSummary.AnalyzedCount = $probeItems.Count
                        $script:AIOLangAdkScanSummary.FullScanSkipped = $true
                        $script:AIOLangAdkScanSummary.Reason = "Familia WinPE incompatible detectada mediante sondeo: $($knownProbeBuilds -join ', ')."
                    }
                    Write-AIOLangLog -Level INFO -Message ("ADK WinPE: se analizaron {0} paquete(s) representativo(s) de {1}; el escaneo completo se omitio porque la build {2} no es compatible con los objetivos {3}." -f $probeItems.Count, $files.Count, ($knownProbeBuilds -join ', '), (@($TargetBuilds) -join ', '))
                }
            }

            if (-not $skipFullScan) {
                $position = 0
                foreach ($file in $scanFiles) {
                    Write-Progress -Activity "Analizando $SourceName" -Status "$position de $($scanFiles.Count) procesados; actual: $($file.Name)" -PercentComplete ([int][math]::Floor(($position * 100.0) / [math]::Max(1, $scanFiles.Count)))
                    try {
                        $item = Get-AIOLangPackageMetadata -PackagePath $file.FullName -MetadataRoot $metadataRoot
                        if ($item.Category -ne 'Unknown') {
                            if ($item.PSObject.Properties['Source']) { $item.Source = $SourceName }
                            else { $item | Add-Member -MemberType NoteProperty -Name Source -Value $SourceName }
                            if ($item.PSObject.Properties['SourceRoot']) { $item.SourceRoot = $RepositoryRoot }
                            else { $item | Add-Member -MemberType NoteProperty -Name SourceRoot -Value $RepositoryRoot }
                            [void]$inventory.Add($item)
                        }
                        else {
                            Write-AIOLangLog -Level WARN -Message "Archivo CAB/ESD no reconocido como paquete de idioma: '$($file.FullName)'."
                        }
                    }
                    catch {
                        Write-AIOLangLog -Level WARN -Message "No se pudo analizar '$($file.FullName)': $($_.Exception.Message)"
                    }
                    finally {
                        $position++
                        Write-Progress -Activity "Analizando $SourceName" -Status "$position de $($scanFiles.Count) procesados: $($file.Name)" -PercentComplete ([int][math]::Floor(($position * 100.0) / [math]::Max(1, $scanFiles.Count)))
                    }
                }
                if ($script:AIOLangAdkScanSummary) {
                    $script:AIOLangAdkScanSummary.AnalyzedCount = $scanFiles.Count
                    $script:AIOLangAdkScanSummary.FullScanSkipped = $false
                    $script:AIOLangAdkScanSummary.Reason = 'Build potencialmente compatible; se completo el inventario localizado.'
                }
            }
        }
        finally {
            Write-Progress -Activity "Analizando $SourceName" -Completed
            Remove-Item -LiteralPath $metadataRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $rawInventory = [object[]]($inventory.ToArray() | Sort-Object Category, Locale, Architecture, Priority, Name)
        $script:AIOLangRepositoryInventoryCache[$inventoryCacheKey] = $rawInventory
    }

    $resultInventory = [object[]]$rawInventory
    if ($normalizedLocales.Count -gt 0) {
        $resultInventory = [object[]]@(
            $rawInventory | Where-Object {
                $_.Locale -and (Normalize-AIOLangLocale -Locale ([string]$_.Locale)) -in $normalizedLocales
            }
        )
    }
    if ($normalizedArchitectures.Count -gt 0) {
        $resultInventory = [object[]]@($resultInventory | Where-Object { $_.Architecture -in $normalizedArchitectures })
    }

    if ($resultInventory.Count -eq 0 -and -not $AllowEmpty) {
        if ($normalizedLocales.Count -gt 0) {
            throw "No se encontraron paquetes compatibles para los idiomas solicitados: $($normalizedLocales -join ', ')."
        }
        throw 'No se encontraron paquetes CAB/ESD reconocidos como LanguagePack, LanguageFOD o WinPE.'
    }

    return $resultInventory
}

function Show-AIOLangInventorySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [object[]]$TargetImages
    )

    $languages = @($Inventory | Where-Object { $_.Category -eq 'LanguagePack' -and $_.Locale } | Group-Object Locale | Sort-Object Name)
    if ($languages.Count -eq 0) {
        Write-Host ' No se detectaron paquetes de idioma principales.' -ForegroundColor Red
        return
    }

    $showCompatibilityLegend = $false
    foreach ($group in $languages) {
        $locale = $group.Name
        Write-Host " $locale" -ForegroundColor Cyan
        $targetArchitectures = @($TargetImages | ForEach-Object { Convert-AIOLangArchitectureName -Architecture $_.Architecture } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($archGroup in @($group.Group | Group-Object Architecture | Sort-Object Name)) {
            $architecture = Convert-AIOLangArchitectureName -Architecture $archGroup.Name
            if ($targetArchitectures.Count -gt 0 -and $architecture -notin $targetArchitectures) { continue }
            $targetImagesForArchitecture = @($TargetImages | Where-Object {
                (Convert-AIOLangArchitectureName -Architecture $_.Architecture) -eq $architecture
            })

            $lpCount = @($archGroup.Group | Where-Object { $_.Supported }).Count
            $allFod = @($Inventory | Where-Object {
                $_.Category -eq 'LanguageFOD' -and $_.Locale -eq $locale -and
                $_.Architecture -eq $architecture -and $_.Supported
            })
            $allWinPE = @($Inventory | Where-Object {
                $_.Category -eq 'WinPE' -and $_.Locale -eq $locale -and
                $_.Architecture -eq $architecture -and $_.Supported
            })

            if ($targetImagesForArchitecture.Count -gt 0) {
                $compatibleFod = @(Get-AIOLangCompatiblePackagesForTargets -Inventory $Inventory -TargetImages $targetImagesForArchitecture -Locales @($locale) -Category 'LanguageFOD')
                $compatibleWinPE = @(Get-AIOLangCompatiblePackagesForTargets -Inventory $Inventory -TargetImages $targetImagesForArchitecture -Locales @($locale) -Category 'WinPE')
            }
            else {
                $compatibleFod = $allFod
                $compatibleWinPE = $allWinPE
            }

            $fodText = if ($compatibleFod.Count -eq $allFod.Count) {
                [string]$compatibleFod.Count
            }
            else {
                $showCompatibilityLegend = $true
                "$($compatibleFod.Count)/$($allFod.Count)"
            }

            $winPeText = if ($compatibleWinPE.Count -eq $allWinPE.Count) {
                [string]$compatibleWinPE.Count
            }
            else {
                $showCompatibilityLegend = $true
                "$($compatibleWinPE.Count)/$($allWinPE.Count)"
            }

            $bytes = [long](($archGroup.Group | Measure-Object Size -Sum).Sum)
            Write-Host ("   {0,-5} PaqueteIdioma: {1,2} | FOD: {2,7} | WinPE: {3,7} | {4}" -f $architecture, $lpCount, $fodText, $winPeText, (Format-AIOLangByteSize -Bytes $bytes)) -ForegroundColor White
        }
    }

    if ($showCompatibilityLegend) {
        Write-Host '       Formato compatible/total respecto a las arquitecturas y builds del medio.' -ForegroundColor DarkGray
    }

    $targetArchitectures = @($TargetImages | ForEach-Object { Convert-AIOLangArchitectureName -Architecture $_.Architecture } | Where-Object { $_ } | Select-Object -Unique)
    $hiddenArchitectures = @($Inventory | Where-Object {
        $_.Category -eq 'LanguagePack' -and $_.Supported -and
        $targetArchitectures.Count -gt 0 -and $_.Architecture -notin $targetArchitectures
    } | Select-Object -ExpandProperty Architecture -Unique | Sort-Object)
    if ($hiddenArchitectures.Count -gt 0) {
        Write-Host "       Arquitecturas detectadas pero no aplicables al medio: $($hiddenArchitectures -join ', ')." -ForegroundColor DarkGray
    }

    $unsupported = @($Inventory | Where-Object { -not $_.Supported })
    if ($unsupported.Count -gt 0) {
        Write-Host "`n [ADVERTENCIA] $($unsupported.Count) paquete(s) no pudieron inspeccionarse completamente:" -ForegroundColor Yellow
        foreach ($item in $unsupported | Select-Object -First 12) {
            Write-Host "   - $($item.Name): $($item.Reason)" -ForegroundColor DarkGray
        }
    }
}

function Get-AIOLangInstallImagePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot)

    $sources = Join-Path $MediaRoot 'sources'
    $wim = Join-Path $sources 'install.wim'
    $esd = Join-Path $sources 'install.esd'
    $swm = Join-Path $sources 'install.swm'
    if (Test-Path -LiteralPath $wim -PathType Leaf) { return $wim }
    if (Test-Path -LiteralPath $esd -PathType Leaf) { return $esd }
    if (Test-Path -LiteralPath $swm -PathType Leaf) {
        throw 'El medio contiene install.swm dividido. Une o exporta los archivos SWM a install.wim antes de usar este modulo.'
    }
    throw "No se encontro sources\install.wim ni sources\install.esd en '$MediaRoot'."
}

function Get-AIOLangImageMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$ImagePath)

    $records = @(Get-AIOLangImageRecords -ImagePath $ImagePath)
    if ($records.Count -eq 0) { throw "No se encontraron indices en '$ImagePath'." }
    $details = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        $languages = New-Object System.Collections.Generic.List[string]
        foreach ($language in @($record.Languages)) {
            $normalized = Normalize-AIOLangLocale -Locale ([string]$language)
            if ($normalized -and $normalized -notin $languages) { [void]$languages.Add($normalized) }
        }
        $defaultLanguage = Normalize-AIOLangLocale -Locale ([string]$record.DefaultLanguage)
        if ($defaultLanguage -and $defaultLanguage -notin $languages) { [void]$languages.Add($defaultLanguage) }
        $obj = [pscustomobject]@{
            ImageIndex       = [int]$record.ImageIndex
            ImageName        = [string]$record.ImageName
            ImageDescription = [string]$record.ImageDescription
            Architecture     = Convert-AIOLangArchitectureName -Architecture $record.Architecture
            Version          = [version]$record.Version
            Build            = [int]$record.Build
            DefaultLanguage  = $defaultLanguage
            Languages        = [string[]]$languages.ToArray()
            InstallationType = [string]$record.InstallationType
            EditionId        = [string]$record.EditionId
            ProductFamily    = $null
        }
        $obj.ProductFamily = Get-AIOLangImageProductFamily -Image $obj
        $evidence = @(Get-AIOLangImageServicingEvidence -ImagePath $ImagePath -Index $obj.ImageIndex -Architecture $obj.Architecture)
        $obj | Add-Member -NotePropertyName ServicingBuilds -NotePropertyValue ([int[]]@($evidence | Select-Object -ExpandProperty Build -Unique))
        $obj | Add-Member -NotePropertyName ServicingEvidence -NotePropertyValue ([object[]]$evidence)
        [void]$details.Add($obj)
    }
    return [object[]]$details.ToArray()
}


function Select-AIOLangInstallIndexes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object[]]$Images)

    Write-Host "`n Indices disponibles en install.wim:" -ForegroundColor Yellow
    foreach ($image in $Images) {
        $knownLanguages = @($image.Languages | Where-Object { $_ } | Select-Object -Unique)
        $languageText = if ($image.DefaultLanguage) {
            $image.DefaultLanguage
        }
        elseif ($knownLanguages.Count -eq 1) {
            $knownLanguages[0]
        }
        elseif ($knownLanguages.Count -gt 1) {
            "$($knownLanguages[0]) (+$($knownLanguages.Count - 1))"
        }
        else {
            'N/D'
        }
        Write-Host ("   [{0}] {1} | {2} | {3} | Idioma: {4}" -f $image.ImageIndex, $image.ImageName, $image.Version, $image.Architecture, $languageText) -ForegroundColor White
    }

    while ($true) {
        $answer = (Read-Host "`nIndices a procesar separados por coma/espacio, o T para todos").Trim().ToUpperInvariant()
        if ($answer -eq 'T') { return @($Images | ForEach-Object { [int]$_.ImageIndex }) }
        $requested = @($answer -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        $valid = @($Images | ForEach-Object { [int]$_.ImageIndex })
        $invalid = @($requested | Where-Object { $_ -notin $valid })
        if ($requested.Count -gt 0 -and $invalid.Count -eq 0) { return $requested }
        Write-Host 'Seleccion invalida. Usa indices existentes o T.' -ForegroundColor Red
    }
}

function Get-AIOLangCompatiblePackagesForTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$TargetImages,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [ValidateSet('LanguagePack', 'LanguageFOD', 'WinPE')] [string]$Category
    )

    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($image in @($TargetImages)) {
        foreach ($package in @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category $Category)) {
            if (-not $package -or [string]::IsNullOrWhiteSpace([string]$package.FilePath)) { continue }
            if ($seen.ContainsKey($package.FilePath)) { continue }
            $seen[$package.FilePath] = $true
            [void]$result.Add($package)
        }
    }
    return [object[]]$result.ToArray()
}

function Select-AIOLangLocales {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [object[]]$TargetImages
    )

    $targetArchitectures = @($TargetImages | ForEach-Object { Convert-AIOLangArchitectureName -Architecture $_.Architecture } | Where-Object { $_ } | Select-Object -Unique)
    $candidateLocales = @($Inventory | Where-Object {
        $_.Category -eq 'LanguagePack' -and $_.Locale -and $_.Supported -and
        ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures)
    } | Select-Object -ExpandProperty Locale -Unique | Sort-Object)
    if (@($TargetImages).Count -gt 0) {
        $locales = @($candidateLocales | Where-Object {
            $localeCandidate = [string]$_
            $missingTarget = @($TargetImages | Where-Object {
                $family = if ($_.PSObject.Properties['ProductFamily'] -and $_.ProductFamily) { [string]$_.ProductFamily } else { Get-AIOLangImageProductFamily -Image $_ }
                -not (Get-AIOLangBestPackage -Packages $Inventory -Locale $localeCandidate -Architecture $_.Architecture -Build $_.Build -Category 'LanguagePack' -ProductFamily $family -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $_))
            })
            $missingTarget.Count -eq 0
        })
    }
    else { $locales = $candidateLocales }
    if ($locales.Count -eq 0) { throw 'No hay idiomas principales compatibles con todas las imagenes seleccionables del medio.' }

    Write-Host "`n Idiomas disponibles:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $locales.Count; $i++) {
        $locale = $locales[$i]
        $architectures = @($Inventory | Where-Object {
            $_.Category -eq 'LanguagePack' -and $_.Locale -eq $locale -and $_.Supported -and
            ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures)
        } | Select-Object -ExpandProperty Architecture -Unique | Sort-Object)
        $allFod = @($Inventory | Where-Object {
            $_.Category -eq 'LanguageFOD' -and $_.Locale -eq $locale -and $_.Supported -and
            ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures)
        })
        $allWinPE = @($Inventory | Where-Object {
            $_.Category -eq 'WinPE' -and $_.Locale -eq $locale -and $_.Supported -and
            ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures)
        })

        if (@($TargetImages).Count -gt 0) {
            $compatibleFod = @(Get-AIOLangCompatiblePackagesForTargets -Inventory $Inventory -TargetImages $TargetImages -Locales @($locale) -Category 'LanguageFOD')
            $compatibleWinPE = @(Get-AIOLangCompatiblePackagesForTargets -Inventory $Inventory -TargetImages $TargetImages -Locales @($locale) -Category 'WinPE')
        }
        else {
            $compatibleFod = $allFod
            $compatibleWinPE = $allWinPE
        }

        $fodText = if ($compatibleFod.Count -eq $allFod.Count) { [string]$compatibleFod.Count } else { "$($compatibleFod.Count)/$($allFod.Count)" }
        $winPeText = if ($compatibleWinPE.Count -eq $allWinPE.Count) { [string]$compatibleWinPE.Count } else { "$($compatibleWinPE.Count)/$($allWinPE.Count)" }
        Write-Host ("   [{0}] {1,-12} | Arquitecturas: {2,-12} | FOD: {3,7} | WinPE: {4,7}" -f ($i + 1), $locale, ($architectures -join ', '), $fodText, $winPeText) -ForegroundColor White
    }

    Write-Host '       Formato compatible/total cuando existen paquetes de otra build o arquitectura.' -ForegroundColor DarkGray

    while ($true) {
        $answer = (Read-Host "`nIdiomas separados por coma/espacio, o T para todos").Trim().ToUpperInvariant()
        if ($answer -eq 'T') { return [string[]]$locales }
        $numbers = @($answer -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        $invalid = @($numbers | Where-Object { $_ -lt 1 -or $_ -gt $locales.Count })
        if ($numbers.Count -gt 0 -and $invalid.Count -eq 0) {
            return [string[]]@($numbers | ForEach-Object { $locales[$_ - 1] })
        }
        Write-Host 'Seleccion invalida.' -ForegroundColor Red
    }
}

function Get-AIOLangBestPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Locale,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [Parameter(Mandatory = $true)] [string]$Category,
        [string]$ProductFamily = 'Unknown',
        [AllowNull()] [AllowEmptyCollection()] [int[]]$ServicingBuilds = @()
    )

    $normalizedPackages = @($Packages | Where-Object { $null -ne $_ })
    if ($normalizedPackages.Count -eq 0) { return $null }

    $candidates = @($normalizedPackages | Where-Object {
        $packageFamily = if ($_.PSObject.Properties['ProductFamily']) { [string]$_.ProductFamily } else { 'Neutral' }
        $_.Category -eq $Category -and $_.Supported -and $_.Locale -eq $Locale -and
        $_.Architecture -eq $Architecture -and
        (Test-AIOLangBuildCompatibility -TargetBuild $Build -PackageBuild $_.Build -ServicingBuilds $ServicingBuilds) -and
        (Test-AIOLangProductCompatibility -ImageFamily $ProductFamily -PackageFamily $packageFamily -Category $Category)
    })
    if ($candidates.Count -eq 0) { return $null }

    return @($candidates | Sort-Object @{ Expression = {
        $packageFamily = if ($_.PSObject.Properties['ProductFamily']) { [string]$_.ProductFamily } else { 'Neutral' }
        if ($ProductFamily -notin @('Unknown','WinPE') -and $packageFamily -eq $ProductFamily) { 0 }
        elseif ($packageFamily -eq 'Neutral') { 1 }
        else { 2 }
    }}, @{ Expression = {
        if ($null -ne $_.Build -and [int]$_.Build -eq $Build) { 0 }
        elseif ($null -ne $_.Build -and [int]$_.Build -gt 0) { 1 }
        else { 2 }
    }}, @{ Expression = { if ($null -ne $_.Build) { [int]$_.Build } else { 0 } }; Descending = $true },
       @{ Expression = { if ($_.Version) { $_.Version } else { [version]'0.0.0.0' } }; Descending = $true }, Name | Select-Object -First 1)[0]
}


function Assert-AIOLangPackageCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [int[]]$Indexes,
        [Parameter(Mandatory = $true)] [string[]]$Locales
    )

    $selectedImages = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes })
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($image in $selectedImages) {
        foreach ($locale in $Locales) {
            $imageFamily = if ($image.PSObject.Properties['ProductFamily'] -and $image.ProductFamily) { [string]$image.ProductFamily } else { Get-AIOLangImageProductFamily -Image $image }
            $package = Get-AIOLangBestPackage -Packages $Inventory -Locale $locale -Architecture $image.Architecture -Build $image.Build -Category 'LanguagePack' -ProductFamily $imageFamily -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $image)
            if (-not $package) {
                [void]$missing.Add("$locale / $($image.Architecture) / build $($image.Build) (indice $($image.ImageIndex))")
            }
        }
    }
    if ($missing.Count -gt 0) {
        throw "Faltan paquetes de idioma compatibles para: $($missing -join '; ')."
    }

    return [pscustomobject]@{
        Images        = $selectedImages
        Architectures = @($selectedImages | Select-Object -ExpandProperty Architecture -Unique | Sort-Object)
        Builds        = @($selectedImages | Select-Object -ExpandProperty Build -Unique | Sort-Object)
    }
}

function Select-AIOLangDefaultLocale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$SelectedImages,
        [Parameter(Mandatory = $true)] [string[]]$SelectedLocales
    )

    $commonExisting = @()
    $imagesWithLanguageMetadata = @($SelectedImages | Where-Object { @($_.Languages | Where-Object { $_ }).Count -gt 0 })
    if ($imagesWithLanguageMetadata.Count -eq $SelectedImages.Count -and $SelectedImages.Count -gt 0) {
        $commonExisting = @($imagesWithLanguageMetadata[0].Languages | Where-Object { $_ } | ForEach-Object { Normalize-AIOLangLocale -Locale $_ } | Select-Object -Unique)
        foreach ($image in $imagesWithLanguageMetadata | Select-Object -Skip 1) {
            $imageLanguages = @($image.Languages | Where-Object { $_ } | ForEach-Object { Normalize-AIOLangLocale -Locale $_ } | Select-Object -Unique)
            $commonExisting = @($commonExisting | Where-Object { $_ -in $imageLanguages })
        }
    }
    else {
        $defaults = @($SelectedImages | Where-Object { $_.DefaultLanguage } | Select-Object -ExpandProperty DefaultLanguage -Unique)
        if ($defaults.Count -eq 1 -and @($SelectedImages | Where-Object { $_.DefaultLanguage -eq $defaults[0] }).Count -eq $SelectedImages.Count) {
            $commonExisting = @($defaults[0])
        }
    }

    $options = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($commonExisting | Sort-Object) + $SelectedLocales) {
        if ($item -and $item -notin $options) { [void]$options.Add($item) }
    }
    if ($options.Count -eq 0) { return $SelectedLocales[0] }

    Write-Host "`n Idioma predeterminado del medio:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $options.Count; $i++) {
        $tag = if ($options[$i] -in $commonExisting) { 'actual en todos los indices' } else { 'nuevo' }
        Write-Host ("   [{0}] {1} ({2})" -f ($i + 1), $options[$i], $tag) -ForegroundColor White
    }
    while ($true) {
        $answer = (Read-Host 'Selecciona el idioma predeterminado').Trim()
        if ($answer -match '^\d+$') {
            $number = [int]$answer
            if ($number -ge 1 -and $number -le $options.Count) { return $options[$number - 1] }
        }
        Write-Host 'Seleccion invalida.' -ForegroundColor Red
    }
}

function Get-AIOLangPackagesForImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object]$Image,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [ValidateSet('LanguagePack', 'LanguageFOD', 'WinPE')] [string]$Category
    )

    $imageFamily = if ($Image.PSObject.Properties['ProductFamily'] -and $Image.ProductFamily) { [string]$Image.ProductFamily } else { Get-AIOLangImageProductFamily -Image $Image }
    $result = @($Inventory | Where-Object {
        $packageFamily = if ($_.PSObject.Properties['ProductFamily']) { [string]$_.ProductFamily } else { 'Neutral' }
        $_.Category -eq $Category -and $_.Supported -and $_.Locale -in $Locales -and
        $_.Architecture -eq $Image.Architecture -and
        (Test-AIOLangBuildCompatibility -TargetBuild ([int]$Image.Build) -PackageBuild $_.Build -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $Image)) -and
        (Test-AIOLangProductCompatibility -ImageFamily $imageFamily -PackageFamily $packageFamily -Category $Category)
    })

    if ($Category -eq 'LanguagePack') {
        $best = New-Object System.Collections.Generic.List[object]
        foreach ($locale in $Locales) {
            $item = Get-AIOLangBestPackage -Packages $result -Locale $locale -Architecture $Image.Architecture -Build $Image.Build -Category 'LanguagePack' -ProductFamily $imageFamily -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $Image)
            if ($item) { [void]$best.Add($item) }
        }
        return [object[]]$best.ToArray()
    }

    $deduplicated = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($result | Group-Object Locale, IdentityName)) {
        $item = @($group.Group | Sort-Object @{ Expression = {
            $packageFamily = if ($_.PSObject.Properties['ProductFamily']) { [string]$_.ProductFamily } else { 'Neutral' }
            if ($imageFamily -notin @('Unknown','WinPE') -and $packageFamily -eq $imageFamily) { 0 }
            elseif ($packageFamily -eq 'Neutral' -or $Category -eq 'WinPE') { 1 }
            else { 2 }
        }}, @{ Expression = {
            if ($null -ne $_.Build -and [int]$_.Build -eq [int]$Image.Build) { 0 }
            elseif ($null -ne $_.Build -and [int]$_.Build -gt 0) { 1 }
            else { 2 }
        }}, @{ Expression = { if ($null -ne $_.Build) { [int]$_.Build } else { 0 } }; Descending = $true },
           @{ Expression = { if ($_.Version) { $_.Version } else { [version]'0.0.0.0' } }; Descending = $true }, Name | Select-Object -First 1)[0]
        [void]$deduplicated.Add($item)
    }
    return [object[]]($deduplicated.ToArray() | Sort-Object Priority, Locale, Name)
}


function Get-AIOLangWinPECompatibilityReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$TargetImages,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ExcludeAdkSource
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $seenTargets = @{}
    foreach ($image in @($TargetImages)) {
        $architecture = Convert-AIOLangArchitectureName -Architecture $image.Architecture
        $build = [int]$image.Build
        $key = "$architecture|$build|$((Get-AIOLangImageServicingBuilds -Image $image) -join ',')"
        if ($seenTargets.ContainsKey($key)) { continue }
        $seenTargets[$key] = $true

        $compatibleRaw = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'WinPE')
        $compatible = $compatibleRaw
        if ($ExcludeAdkSource) {
            $compatible = @($compatibleRaw | Where-Object {
                $pkgSource = if ($_.PSObject.Properties['Source']) { $_.Source } else { 'Repositorio' }
                $pkgSource -ne 'ADK WinPE'
            })
        }
        # Microsoft indica usar el idioma del ISO de Languages and Optional
        # Features (no el ADK) para localizar WinRE. Si el unico CAB WinPE
        # compatible por build/arquitectura/idioma viene del ADK, se marca
        # para que el diagnostico lo explique en vez de mostrar un simple
        # desfase de build.
        $adkOnlyMatch = [bool]($ExcludeAdkSource -and $compatible.Count -eq 0 -and $compatibleRaw.Count -gt 0)
        $sameTarget = @($Inventory | Where-Object {
            $_.Category -eq 'WinPE' -and $_.Supported -and $_.Locale -in $Locales -and $_.Architecture -eq $architecture
        })
        $availableBuilds = @($sameTarget | Where-Object { $null -ne $_.Build } | Select-Object -ExpandProperty Build -Unique | Sort-Object)
        $referenceBuilds = @($Inventory | Where-Object {
            $_.Supported -and $_.Locale -in $Locales -and $_.Architecture -eq $architecture -and
            $_.Category -in @('LanguagePack', 'LanguageFOD') -and $null -ne $_.Build
        } | Select-Object -ExpandProperty Build -Unique | Sort-Object)
        $family = Get-AIOLangBuildFamily -Build $build -ReferenceBuilds $referenceBuilds -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $image)
        $availableFamilies = @(Get-AIOLangBuildFamiliesFromPackages -Packages $sameTarget)
        $availableVersions = @($sameTarget | Where-Object { $_.Version } | Select-Object -ExpandProperty Version -Unique | Sort-Object)
        $availableSources = @($sameTarget | ForEach-Object { if ($_.PSObject.Properties['Source']) { $_.Source } else { 'Repositorio' } } | Select-Object -Unique | Sort-Object)

        [void]$rows.Add([pscustomobject]@{
            Context           = $Context
            Architecture      = $architecture
            ImageBuild        = $build
            RequiredFamily    = $family
            Locales           = [string[]]$Locales
            CompatibleCount   = $compatible.Count
            AdkOnlyMatch      = $adkOnlyMatch
            AvailableCount    = $sameTarget.Count
            AvailableBuilds   = [int[]]$availableBuilds
            AvailableFamilies = [int[]]$availableFamilies
            AvailableVersions = [version[]]$availableVersions
            AvailableSources  = [string[]]$availableSources
        })
    }
    return [object[]]$rows.ToArray()
}

function Show-AIOLangWinPECompatibilityDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Reports,
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [AllowNull()] [object]$AdkInfo
    )

    $mismatches = @($Reports | Where-Object { $_.CompatibleCount -eq 0 })
    if ($mismatches.Count -eq 0) { return }

    Write-Host "`n Diagnostico de compatibilidad WinPE:" -ForegroundColor Yellow
    foreach ($report in $mismatches) {
        $requiredText = if ($report.ImageBuild -eq $report.RequiredFamily) {
            "build $($report.ImageBuild)"
        }
        else {
            "build $($report.ImageBuild), familia $($report.RequiredFamily)"
        }

        if ($report.PSObject.Properties['AdkOnlyMatch'] -and $report.AdkOnlyMatch) {
            Write-Host " [NO PERMITIDO] $($report.Context) $($report.Architecture): el unico CAB WinPE compatible ($requiredText) proviene del ADK." -ForegroundColor Yellow
            Write-Host "                Microsoft indica no usar el ADK para localizar WinRE; usa el mismo arbol WinPE_OCs pero tomado del ISO de Languages and Optional Features." -ForegroundColor DarkYellow
        }
        elseif ($report.AvailableCount -gt 0) {
            $buildText = if (@($report.AvailableBuilds).Count -gt 0) { @($report.AvailableBuilds) -join ', ' } else { 'N/D' }
            $familyText = if (@($report.AvailableFamilies).Count -gt 0) { @($report.AvailableFamilies) -join ', ' } else { 'N/D' }
            $sourceText = if (@($report.AvailableSources).Count -gt 0) { @($report.AvailableSources) -join ', ' } else { 'N/D' }
            Write-Host " [INCOMPATIBLE] $($report.Context) $($report.Architecture): requiere $requiredText; disponibles build $buildText (familia $familyText)." -ForegroundColor Yellow
            Write-Host "                Origen: $sourceText | Idiomas: $(@($report.Locales) -join ', ')" -ForegroundColor DarkYellow
        }
        else {
            Write-Host " [FALTANTE] $($report.Context) $($report.Architecture): requiere $requiredText y no hay CAB WinPE para los idiomas seleccionados." -ForegroundColor Yellow
        }
    }

    $requiredFamilies = @($mismatches | Select-Object -ExpandProperty RequiredFamily -Unique | Sort-Object)
    $requiredArchitectures = @($mismatches | Select-Object -ExpandProperty Architecture -Unique | Sort-Object)
    Write-Host " [ACCION] Usa componentes WinPE de la familia $($requiredFamilies -join ', ') para $($requiredArchitectures -join ', ')." -ForegroundColor Cyan
    Write-Host "          El repositorio puede contenerlos bajo: $RepositoryRoot\WinPE\<arquitectura>\WinPE_OCs" -ForegroundColor DarkCyan
    if ($AdkInfo -and $AdkInfo.ActiveDismSource -eq 'ADK') {
        Write-Host " [NOTA] DISM $($AdkInfo.ActiveDismVersion) puede seguir utilizandose como herramienta; la incompatibilidad corresponde a los paquetes CAB WinPE." -ForegroundColor DarkGray
    }
}


function Test-AIOLangEastAsianLocale {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Locale)

    $normalized = Normalize-AIOLangLocale -Locale $Locale
    return [bool]($normalized -and $normalized -in @($script:AIOLangPolicy.EastAsianLocales))
}

function Test-AIOLangWinPEBaseLanguagePack {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $identity = if ($Package.PSObject.Properties['IdentityName']) { [string]$Package.IdentityName } else { '' }
    $packageName = if ($Package.PSObject.Properties['PackageName']) { [string]$Package.PackageName } else { '' }
    $name = if ($Package.PSObject.Properties['Name']) { [string]$Package.Name } else { '' }
    $combined = "$identity $packageName $name"
    return [bool]($combined -match '(?i)Microsoft-Windows-WinPE-LanguagePack-Package' -or $name -ieq 'lp.cab')
}

function Test-AIOLangWinPEFontSupportPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $identity = if ($Package.PSObject.Properties['IdentityName']) { [string]$Package.IdentityName } else { '' }
    $packageName = if ($Package.PSObject.Properties['PackageName']) { [string]$Package.PackageName } else { '' }
    $name = if ($Package.PSObject.Properties['Name']) { [string]$Package.Name } else { '' }
    return (Test-AIOLangPolicyPatternSet -Text "$identity $packageName $name" -Patterns ([string[]]$script:AIOLangPolicy.WinPEFontSupportPatterns))
}

function Get-AIOLangWinPELocalizationMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$TargetImages,
        [Parameter(Mandatory = $true)] [string[]]$Locales
    )

    $targets = @($TargetImages | Where-Object { $null -ne $_ })
    if ($targets.Count -eq 0) {
        return [pscustomobject]@{ Mode = 'NotAvailable'; Complete = $false; MissingBase = [string[]]@(); MissingFontSupport = [string[]]@() }
    }

    $missingBase = New-Object System.Collections.Generic.List[string]
    $missingFonts = New-Object System.Collections.Generic.List[string]
    foreach ($image in $targets) {
        foreach ($locale in $Locales) {
            $packages = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales @($locale) -Category 'WinPE')
            if (@($packages | Where-Object { Test-AIOLangWinPEBaseLanguagePack -Package $_ }).Count -eq 0) {
                [void]$missingBase.Add("$($image.Architecture):$locale")
                continue
            }
            if ((Test-AIOLangEastAsianLocale -Locale $locale) -and @($packages | Where-Object { Test-AIOLangWinPEFontSupportPackage -Package $_ }).Count -eq 0) {
                [void]$missingFonts.Add("$($image.Architecture):$locale")
            }
        }
    }

    $complete = ($missingBase.Count -eq 0 -and $missingFonts.Count -eq 0)
    return [pscustomobject]@{
        Mode = $(if ($complete) { 'FullWinPE' } else { 'SetupResourcesOnly' })
        Complete = [bool]$complete
        MissingBase = [string[]]$missingBase.ToArray()
        MissingFontSupport = [string[]]$missingFonts.ToArray()
    }
}

function Save-AIOLangEastAsianFontPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Payloads,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$CacheRoot
    )

    $eastAsian = @($Locales | ForEach-Object { Normalize-AIOLangLocale -Locale $_ } | Where-Object { $_ -and (Test-AIOLangEastAsianLocale -Locale $_) } | Select-Object -Unique)
    if ($eastAsian.Count -eq 0) { return @() }

    $archRoot = Join-Path $CacheRoot $Architecture
    $bootSource = Join-Path $MountPath 'Windows\Boot\Fonts'
    $bootCache = Join-Path $archRoot 'BootFonts'
    if (-not (Test-Path -LiteralPath $bootSource -PathType Container)) {
        throw "No existe Windows\\Boot\\Fonts en el indice usado para preparar soporte de fuentes de Asia oriental ($Architecture)."
    }
    if (-not (Test-Path -LiteralPath $bootCache -PathType Container)) {
        Initialize-AIOLangDirectory -Path $bootCache -Empty
        Copy-AIOLangTree -Source $bootSource -Destination $bootCache
    }
    $bootCount = @(Get-ChildItem -LiteralPath $bootCache -File -ErrorAction SilentlyContinue).Count
    if ($bootCount -eq 0) { throw "No se pudieron capturar fuentes de arranque para $Architecture." }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($locale in $eastAsian) {
        $key = $locale.ToLowerInvariant()
        $fontNames = @($script:AIOLangPolicy.EastAsianFontFiles[$key])
        if ($fontNames.Count -eq 0) { continue }
        $systemCache = Join-Path $archRoot ("$locale\SystemFonts")
        Initialize-AIOLangDirectory -Path $systemCache -Empty
        $captured = New-Object System.Collections.Generic.List[string]
        foreach ($fontName in $fontNames) {
            $source = Join-Path $MountPath ("Windows\Fonts\$fontName")
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                Write-AIOLangLog -Level WARN -Message "Fuente EA '$fontName' no encontrada para $locale en install.wim; se continuara con las disponibles."
                continue
            }
            Copy-AIOLangFileWithRetry -Source $source -Destination (Join-Path $systemCache $fontName)
            [void]$captured.Add($fontName)
        }
        if ($captured.Count -eq 0) {
            throw "No se encontraron fuentes de respaldo para '$locale'. Sin WinPE FontSupport, Windows Setup podria mostrar caracteres vacios."
        }

        $support = [pscustomobject]@{
            Locale = $locale
            Architecture = $Architecture
            BootFontsRoot = $bootCache
            BootFontCount = $bootCount
            SystemFontsRoot = $systemCache
            SystemFontNames = [string[]]$captured.ToArray()
        }
        foreach ($payload in @($Payloads | Where-Object { $_.Architecture -eq $Architecture -and $_.Locale -eq $locale })) {
            $payload | Add-Member -MemberType NoteProperty -Name EastAsianFontSupport -Value $support -Force
        }
        [void]$results.Add($support)
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context "Capturar fuentes EA $locale" -State 'Success' -Details $support
    }
    return [object[]]$results.ToArray()
}

function Add-AIOLangEastAsianFontSupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Payloads,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $supports = @($Payloads | Where-Object {
        $_.Architecture -eq $Architecture -and $_.Locale -in $Locales -and $_.PSObject.Properties['EastAsianFontSupport'] -and $null -ne $_.EastAsianFontSupport
    } | ForEach-Object { $_.EastAsianFontSupport } | Sort-Object Locale -Unique)
    if ($supports.Count -eq 0) {
        return [pscustomobject]@{ Applied = $false; FileCount = 0; Locales = [string[]]@(); SystemFontNames = [string[]]@() }
    }

    $bootDestination = Join-Path $MountPath 'Windows\Boot\Fonts'
    $systemDestination = Join-Path $MountPath 'Windows\Fonts'
    Initialize-AIOLangDirectory -Path $bootDestination
    Initialize-AIOLangDirectory -Path $systemDestination
    $files = New-Object System.Collections.Generic.List[string]
    $processed = New-Object System.Collections.Generic.List[string]
    foreach ($support in $supports) {
        if (Test-Path -LiteralPath $support.BootFontsRoot -PathType Container) {
            Copy-AIOLangTree -Source $support.BootFontsRoot -Destination $bootDestination
        }
        foreach ($fontName in @($support.SystemFontNames)) {
            $source = Join-Path $support.SystemFontsRoot $fontName
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Falta la fuente EA preparada '$source'." }
            Copy-AIOLangFileWithRetry -Source $source -Destination (Join-Path $systemDestination $fontName)
            if ($fontName -notin $files) { [void]$files.Add($fontName) }
        }
        if ($support.Locale -notin $processed) { [void]$processed.Add($support.Locale) }
    }

    $result = [pscustomobject]@{
        Applied = $true
        FileCount = $files.Count
        Locales = [string[]]$processed.ToArray()
        SystemFontNames = [string[]]$files.ToArray()
    }
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'Success' -Details $result
    Write-AIOLangLog -Level INFO -Message ("Soporte de fuentes EA aplicado en boot.wim: idiomas {0}; fuentes especificas {1}." -f ($processed -join ', '), ($files -join ', '))
    return $result
}

function Assert-AIOLangEastAsianFontSupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]]$ExpectedFontFiles,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$Context,
        [string]$Mode = 'FontSupportOnly'
    )

    $bootRoot = Join-Path $MountPath 'Windows\Boot\Fonts'
    $bootCount = if (Test-Path -LiteralPath $bootRoot -PathType Container) { @(Get-ChildItem -LiteralPath $bootRoot -File -ErrorAction SilentlyContinue).Count } else { 0 }
    $missing = @($ExpectedFontFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $MountPath ("Windows\Fonts\$_")) -PathType Leaf) })
    if ($bootCount -eq 0 -or $missing.Count -gt 0) {
        throw "$Context fallo: soporte de fuentes EA incompleto. BootFonts=$bootCount; faltantes=$($missing -join ', ')."
    }
    $result = [pscustomobject]@{
        Context = $Context
        Mode = $Mode
        EastAsianLocales = [string[]]$Locales
        ExpectedSystemFonts = [string[]]$ExpectedFontFiles
        MissingSystemFonts = [string[]]$missing
        BootFontCount = $bootCount
        Complete = $true
    }
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'VerifiedEastAsianFonts' -Details $result
    return $result
}

function Expand-AIOLangArchiveFull {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ArchivePath,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    Initialize-AIOLangDirectory -Path $Destination -Empty
    $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()

    switch ($extension) {
        '.cab' {
            [void](Expand-AIOLangCabNative -CabPath $ArchivePath -Destination $Destination -FilePatterns @('*'))
        }
        '.esd' {
            [void](Expand-AIOLangEsdNative -EsdPath $ArchivePath -Destination $Destination)
        }
        default {
            throw "Formato no admitido para extraer recursos: '$ArchivePath'."
        }
    }

    $count = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($count -eq 0) { throw "No se extrajeron recursos de '$ArchivePath'." }
    return $Destination
}

function Initialize-AIOLangLanguagePayloads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$LanguagePackages,
        [Parameter(Mandatory = $true)] [string]$PayloadRoot
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($package in $LanguagePackages) {
        $safe = (($package.Architecture + '_' + $package.Locale + '_' + [System.IO.Path]::GetFileNameWithoutExtension($package.Name)) -replace '[^A-Za-z0-9_.-]', '_')
        if ($safe.Length -gt 100) { $safe = $safe.Substring(0, 100) }
        $destination = Join-Path $PayloadRoot $safe
        Write-Host " -> Extrayendo recursos de $($package.Locale) / $($package.Architecture)..." -ForegroundColor DarkGray
        Expand-AIOLangArchiveFull -ArchivePath $package.FilePath -Destination $destination | Out-Null

        $packagePath = $package.FilePath
        if ($package.Extension -eq '.esd') {
            $mumCandidates = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter '*.mum' -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '(?i)LanguagePack|Common-Foundation|^update\.mum$'
            } | Sort-Object @{ Expression = { if ($_.Name -ieq 'update.mum') { 0 } else { 1 } } }, FullName)
            if ($mumCandidates.Count -eq 0) { throw "No se encontro un manifiesto instalable dentro de '$($package.Name)'." }
            $packagePath = $mumCandidates[0].FullName
        }

        [void]$result.Add([pscustomobject]@{
            Locale       = $package.Locale
            Architecture = $package.Architecture
            Build        = $package.Build
            Package      = $package
            PackagePath  = $packagePath
            ExtractRoot  = $destination
        })
    }
    return [object[]]$result.ToArray()
}

function Copy-AIOLangTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) { return }
    Initialize-AIOLangDirectory -Path $Destination
    Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
}

function Merge-AIOLangSetupPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$Payload,
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [switch]$Server,
        [switch]$AzureStackHci
    )

    $locale = $Payload.Locale
    $extractRoot = $Payload.ExtractRoot
    $sourcesLocale = Join-Path $MediaRoot ("sources\$locale")
    Initialize-AIOLangDirectory -Path $sourcesLocale

    $setupLocaleDirs = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -match '(?i)[\\/]setup[\\/]sources[\\/]' + [regex]::Escape($locale) + '$'
    })
    if ($setupLocaleDirs.Count -eq 0) {
        # Algunos paquetes almacenan directamente los recursos bajo Setup\\Sources,
        # sin una carpeta intermedia con el nombre del idioma.
        $setupRoots = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -match '(?i)[\\/]setup[\\/]sources$'
        })
        foreach ($root in $setupRoots) {
            $localizedChildren = @(Get-ChildItem -LiteralPath $root.FullName -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '^[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$'
            })
            $directResources = @(Get-ChildItem -LiteralPath $root.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -in @('.mui','.rtf','.adml')
            })
            if ($localizedChildren.Count -eq 0 -and $directResources.Count -gt 0) {
                $setupLocaleDirs += $root
                Write-AIOLangLog -Level WARN -Message "Se normalizo el arbol Setup\\Sources sin carpeta de idioma para '$locale'."
            }
        }
    }
    if ($setupLocaleDirs.Count -eq 0) {
        Write-AIOLangLog -Level WARN -Message "No se encontro el arbol Setup\\Sources para '$locale' dentro de '$($Payload.Package.Name)'."
    }
    foreach ($directory in $setupLocaleDirs) {
        foreach ($child in Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue) {
            if ($child.PSIsContainer -and $child.Name -in @('dlmanifests','etwproviders','replacementmanifests','tdb')) { continue }
            if ($child.PSIsContainer -and $child.Name -eq 'cli') {
                Copy-AIOLangTree -Source $child.FullName -Destination $sourcesLocale
                continue
            }
            if ($child.PSIsContainer -and $child.Name -eq 'svr') {
                if ($Server) { Copy-AIOLangTree -Source $child.FullName -Destination $sourcesLocale }
                continue
            }
            if ($child.PSIsContainer -and $child.Name -eq 'asz') {
                if ($AzureStackHci) { Copy-AIOLangTree -Source $child.FullName -Destination $sourcesLocale }
                continue
            }
            Copy-Item -LiteralPath $child.FullName -Destination $sourcesLocale -Recurse -Force -ErrorAction Stop
        }
    }

    foreach ($name in @('credits.rtf','oobe_help_opt_in_details.rtf','vofflps.rtf')) {
        $file = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($file) {
            Copy-Item -LiteralPath $file.FullName -Destination $sourcesLocale -Force -ErrorAction Stop
            if ($name -eq 'vofflps.rtf') { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $sourcesLocale 'privacy.rtf') -Force -ErrorAction Stop }
        }
    }

    $bootMui = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'bootsect.exe.mui' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bootMui) {
        $bootLocale = Join-Path $MediaRoot ("boot\$locale")
        Initialize-AIOLangDirectory -Path $bootLocale
        Copy-Item -LiteralPath $bootMui.FullName -Destination $bootLocale -Force -ErrorAction Stop
    }

    foreach ($setupDir in $setupLocaleDirs) {
        foreach ($kind in @('dlmanifests','replacementmanifests')) {
            $kindRoot = Join-Path $setupDir.FullName $kind
            if (-not (Test-Path -LiteralPath $kindRoot)) { continue }
            foreach ($component in Get-ChildItem -LiteralPath $kindRoot -Directory -ErrorAction SilentlyContinue) {
                $destination = Join-Path $MediaRoot ("sources\$kind\$($component.Name)\$locale")
                Copy-AIOLangTree -Source $component.FullName -Destination $destination
            }
        }
        $etw = Join-Path $setupDir.FullName 'etwproviders'
        if (Test-Path -LiteralPath $etw) {
            Copy-AIOLangTree -Source $etw -Destination (Join-Path $MediaRoot ("sources\etwproviders\$locale"))
            Copy-AIOLangTree -Source $etw -Destination (Join-Path $MediaRoot ("support\logging\$locale"))
        }
    }
}


function Get-AIOLangFileCacheKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return ('{0}|{1}|{2}' -f $item.FullName.ToLowerInvariant(), [int64]$item.Length, [int64]$item.LastWriteTimeUtc.Ticks)
}

function Clear-AIOLangFileHashCache {
    [CmdletBinding()]
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        $script:AIOLangFileHashCache = @{}
        return
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant() + '|'
        foreach ($key in @($script:AIOLangFileHashCache.Keys)) {
            if ([string]$key -like "$full*") { $script:AIOLangFileHashCache.Remove($key) }
        }
    }
    catch {}
}

function Write-AIOLangAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Text
    )

    $parent = Split-Path -Parent $Path
    Initialize-AIOLangDirectory -Path $parent
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Path) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    $encoding = New-Object System.Text.UTF8Encoding($true)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Replace($temporary, $Path, $null) }
        else { [System.IO.File]::Move($temporary, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AIOLangAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$InputObject,
        [int]$Depth = 12
    )
    Write-AIOLangAtomicText -Path $Path -Text ($InputObject | ConvertTo-Json -Depth $Depth)
}

function Copy-AIOLangFileVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $parent = Split-Path -Parent $Destination
    Initialize-AIOLangDirectory -Path $parent
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
        if (Test-Path -LiteralPath $Destination -PathType Leaf) { [System.IO.File]::Replace($temporary, $Destination, $null) }
        else { [System.IO.File]::Move($temporary, $Destination) }
        [System.IO.File]::SetLastWriteTimeUtc($Destination, $sourceItem.LastWriteTimeUtc)
        Clear-AIOLangFileHashCache -Path $Destination
        $sourceHash = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '').ToUpperInvariant()
        $sourceKey = Get-AIOLangFileCacheKey -Path $Source
        $script:AIOLangFileHashCache[$sourceKey] = $sourceHash
        $destinationHash = Get-AIOLangFileHashRequired -Path $Destination
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

function Get-AIOLangRepositoryPackageFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$RepositoryRoot)

    $resolved = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($path in [System.IO.Directory]::EnumerateFiles($resolved, '*', [System.IO.SearchOption]::AllDirectories)) {
        $file = New-Object -TypeName System.IO.FileInfo -ArgumentList $path
        if (Test-AIOLangCandidatePackage -File $file) { [void]$list.Add($file) }
    }
    return [System.IO.FileInfo[]]@($list.ToArray() | Sort-Object FullName)
}


function Get-AIOLangFileHashSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    try { return Get-AIOLangFileHashRequired -Path $Path }
    catch { return $null }
}


function Get-AIOLangFileHashRequired {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $key = Get-AIOLangFileCacheKey -Path $Path
    if ($script:AIOLangFileHashCache.ContainsKey($key)) {
        $script:AIOLangOptimizationStats.HashCacheHits++
        return [string]$script:AIOLangFileHashCache[$key]
    }
    $script:AIOLangOptimizationStats.HashCacheMisses++
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ([string]::IsNullOrWhiteSpace([string]$hash) -or $hash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "No se pudo obtener un SHA-256 valido para '$Path'."
    }
    $normalized = $hash.ToUpperInvariant()
    $script:AIOLangFileHashCache[$key] = $normalized
    return $normalized
}

function Get-AIOLangTextSha256 {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Text = '')

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}


function Get-AIOLangDirectoryTreeHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "No existe el directorio para calcular hash de arbol: '$Path'." }
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
    $paths = [string[]]@([System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories))
    [Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
    $lines = New-Object System.Collections.Generic.List[string]
    [int64]$totalBytes = 0
    foreach ($path in $paths) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $relative = $path.Substring($root.Length).TrimStart('\').Replace('/', '\').ToLowerInvariant()
        $hash = Get-AIOLangFileHashRequired -Path $path
        [void]$lines.Add(('{0}|{1}|{2}' -f $relative, [int64]$item.Length, $hash))
        $totalBytes += [int64]$item.Length
    }
    return [pscustomobject]@{
        SHA256 = Get-AIOLangTextSha256 -Text (($lines -join "`n") + "`n")
        FileCount = $paths.Count
        TotalBytes = $totalBytes
    }
}

function Get-AIOLangEntriesIndexSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Entries)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Entries | Sort-Object { ([string]$_.RelativePath).ToLowerInvariant() })) {
        $relative = ([string]$entry.RelativePath).Replace('/', '\').TrimStart('\').ToLowerInvariant()
        $hash = ([string]$entry.Sha256).ToUpperInvariant()
        [void]$lines.Add(('{0}|{1}|{2}|{3}|{4}|{5}' -f $relative, [bool]$entry.Existed, [string]$entry.Type, [int64]$entry.Size, [int]$entry.FileCount, $hash))
    }
    return Get-AIOLangTextSha256 -Text (($lines -join "`n") + "`n")
}


function Get-AIOLangVolumeFreeSpace {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $probe = $Path
    while (-not (Test-Path -LiteralPath $probe) -and -not [string]::IsNullOrWhiteSpace($probe)) {
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    if ([string]::IsNullOrWhiteSpace($probe)) { throw "No se pudo resolver un volumen para '$Path'." }
    $resolvedProbe = (Resolve-Path -LiteralPath $probe -ErrorAction Stop).Path
    $root = [System.IO.Path]::GetPathRoot($resolvedProbe)
    try {
        $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $root
        return [pscustomobject]@{ Root = $root; FreeBytes = [int64]$drive.AvailableFreeSpace; TotalBytes = [int64]$drive.TotalSize; Measurable = $true }
    }
    catch {
        $psDrive = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -and $resolvedProbe.StartsWith([string]$_.Root, [System.StringComparison]::OrdinalIgnoreCase) } | Sort-Object { ([string]$_.Root).Length } -Descending | Select-Object -First 1)
        if ($psDrive.Count -gt 0 -and $null -ne $psDrive[0].Free) {
            return [pscustomobject]@{ Root = [string]$psDrive[0].Root; FreeBytes = [int64]$psDrive[0].Free; TotalBytes = [int64]($psDrive[0].Used + $psDrive[0].Free); Measurable = $true }
        }
        Write-AIOLangLog -Level WARN -Message "No se pudo medir espacio libre para '$Path'; se conserva el resto del Preflight."
        return [pscustomobject]@{ Root = $root; FreeBytes = [int64]-1; TotalBytes = [int64]-1; Measurable = $false }
    }
}

function Assert-AIOLangPreflightDiskSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$SessionRoot,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$SelectedImages,
        [Parameter(Mandatory = $true)] [string[]]$Locales
    )

    $backupPlan = Get-AIOLangBackupPlan -MediaRoot $MediaRoot -Locales $Locales
    [int64]$wimBytes = 0
    [int64]$largestWim = 0
    foreach ($candidate in @('sources\install.wim','sources\install.esd','sources\boot.wim')) {
        $path = Join-Path $MediaRoot $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $length = [int64](Get-Item -LiteralPath $path -ErrorAction Stop).Length
            $wimBytes += $length
            if ($length -gt $largestWim) { $largestWim = $length }
        }
    }

    $packagePathSet = @{}
    foreach ($image in @($SelectedImages)) {
        foreach ($category in @('LanguagePack','LanguageFOD','WinPE')) {
            foreach ($package in @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category $category)) {
                if ($package -and $package.FilePath) { $packagePathSet[[string]$package.FilePath] = $true }
            }
        }
    }
    $packagePaths = @($packagePathSet.Keys)
    [int64]$packageBytes = 0
    foreach ($path in $packagePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $packageBytes += [int64](Get-Item -LiteralPath $path -ErrorAction SilentlyContinue).Length }
    }

    [int64]$gb = 1GB
    [int64]$mediaNeed = [int64]([math]::Ceiling([double]$backupPlan.TotalBytes + ([double]$largestWim * 1.20) + (2 * $gb)))
    [int64]$scratchNeed = [int64]([math]::Ceiling(([double]$wimBytes * 2.0) + ([double]$packageBytes * 1.5) + (5 * $gb)))
    $mediaSpace = Get-AIOLangVolumeFreeSpace -Path $MediaRoot
    $scratchSpace = Get-AIOLangVolumeFreeSpace -Path $SessionRoot

    if ($mediaSpace.Root -ieq $scratchSpace.Root) {
        $required = $mediaNeed + $scratchNeed
        if ($mediaSpace.Measurable) {
            Write-AIOLangLog -Level INFO -Message ("Preflight de espacio: requerido aprox. {0}; disponible {1} en {2}." -f (Format-AIOLangByteSize -Bytes $required), (Format-AIOLangByteSize -Bytes $mediaSpace.FreeBytes), $mediaSpace.Root)
            if ($mediaSpace.FreeBytes -lt $required) {
                throw "Espacio insuficiente en $($mediaSpace.Root): se requieren aproximadamente $(Format-AIOLangByteSize -Bytes $required) y hay $(Format-AIOLangByteSize -Bytes $mediaSpace.FreeBytes)."
            }
        }
    }
    else {
        if ($mediaSpace.Measurable) {
            Write-AIOLangLog -Level INFO -Message ("Preflight de espacio del medio: requerido {0}; disponible {1} en {2}." -f (Format-AIOLangByteSize -Bytes $mediaNeed), (Format-AIOLangByteSize -Bytes $mediaSpace.FreeBytes), $mediaSpace.Root)
            if ($mediaSpace.FreeBytes -lt $mediaNeed) { throw "Espacio insuficiente en el volumen del medio $($mediaSpace.Root)." }
        }
        if ($scratchSpace.Measurable) {
            Write-AIOLangLog -Level INFO -Message ("Preflight de espacio temporal: requerido {0}; disponible {1} en {2}." -f (Format-AIOLangByteSize -Bytes $scratchNeed), (Format-AIOLangByteSize -Bytes $scratchSpace.FreeBytes), $scratchSpace.Root)
            if ($scratchSpace.FreeBytes -lt $scratchNeed) { throw "Espacio insuficiente en el volumen temporal $($scratchSpace.Root)." }
        }
    }

    return [pscustomobject]@{
        BackupBytes = [int64]$backupPlan.TotalBytes
        WimBytes = $wimBytes
        PackageBytes = $packageBytes
        MediaRequiredBytes = $mediaNeed
        ScratchRequiredBytes = $scratchNeed
        MediaVolume = $mediaSpace.Root
        ScratchVolume = $scratchSpace.Root
    }
}

function Get-AIOLangBackupTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string[]]$Locales
    )

    # Se respaldan completos los arboles compartidos que pueden recibir recursos
    # de varios idiomas. De este modo tambien se eliminan correctamente durante
    # una restauracion los componentes creados por primera vez.
    $relativePaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        'sources\install.wim', 'sources\install.esd', 'sources\boot.wim',
        'sources\lang.ini', 'sources\setup.exe', 'setup.exe',
        'boot\fonts', 'efi\microsoft\boot\fonts',
        'sources\dlmanifests', 'sources\replacementmanifests',
        'sources\etwproviders', 'support\logging'
    )) {
        if ($path -notin $relativePaths) { [void]$relativePaths.Add($path) }
    }

    foreach ($locale in $Locales) {
        foreach ($path in @("sources\$locale", "boot\$locale")) {
            if ($path -notin $relativePaths) { [void]$relativePaths.Add($path) }
        }
    }
    return [string[]]$relativePaths.ToArray()
}

function Get-AIOLangBackupLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot)

    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    $mediaParent = Split-Path -Parent $media
    $mediaLeaf = Split-Path -Leaf $media
    if ([string]::IsNullOrWhiteSpace($mediaLeaf)) { $mediaLeaf = 'MediaWindows' }

    $backupBase = Join-Path $mediaParent 'AdminImagenOffline_Backup'
    $sessionRoot = Join-Path (Join-Path $backupBase $mediaLeaf) (Get-Date -Format 'yyyyMMdd_HHmmss')
    $preflightRoot = Join-Path $sessionRoot 'Preflight'

    return [pscustomobject]@{
        MediaRoot     = $media
        BackupBase    = $backupBase
        SessionRoot   = $sessionRoot
        PreflightRoot = $preflightRoot
    }
}

function Resolve-AIOLangPreflightBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $selected = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $selected -PathType Container)) {
        throw "No existe la carpeta de respaldo '$selected'."
    }
    if ((Split-Path -Leaf $selected) -ine 'Preflight') {
        throw "Selecciona directamente la carpeta Preflight del respaldo actual."
    }

    $manifestPath = Join-Path $selected 'manifest.json'
    $payloadRoot = Join-Path $selected 'Media'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "El respaldo '$selected' no contiene manifest.json."
    }
    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        throw "El respaldo '$selected' no contiene la carpeta Media."
    }

    return [pscustomobject]@{
        Root         = $selected
        ManifestPath = $manifestPath
        PayloadRoot  = $payloadRoot
    }
}

function Get-AIOLangBackupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string[]]$Locales
    )

    $resolvedMedia = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    $entries = New-Object System.Collections.Generic.List[object]
    [int64]$totalBytes = 0
    [int]$totalFiles = 0

    foreach ($relative in Get-AIOLangBackupTargets -MediaRoot $resolvedMedia -Locales $Locales) {
        $source = Join-Path $resolvedMedia $relative
        if (-not (Test-Path -LiteralPath $source)) {
            [void]$entries.Add([pscustomobject]@{
                RelativePath = $relative
                SourcePath   = $source
                Existed      = $false
                Type         = 'Missing'
                Files        = [object[]]@()
                FileCount    = 0
                TotalBytes   = [int64]0
            })
            continue
        }

        $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            $fileRecord = [pscustomobject]@{
                SourcePath        = $item.FullName
                RelativeInTarget  = ''
                MediaRelativePath = $relative.Replace('/', '\')
                Length            = [int64]$item.Length
            }
            [void]$entries.Add([pscustomobject]@{
                RelativePath = $relative
                SourcePath   = $item.FullName
                Existed      = $true
                Type         = 'File'
                Files        = [object[]]@($fileRecord)
                FileCount    = 1
                TotalBytes   = [int64]$item.Length
            })
            $totalFiles++
            $totalBytes += [int64]$item.Length
            continue
        }

        $sourceRoot = $item.FullName.TrimEnd('\')
        $paths = [string[]]@([System.IO.Directory]::EnumerateFiles($sourceRoot, '*', [System.IO.SearchOption]::AllDirectories))
        [Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
        $files = New-Object System.Collections.Generic.List[object]
        [int64]$entryBytes = 0
        foreach ($path in $paths) {
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $relativeInTarget = $path.Substring($sourceRoot.Length).TrimStart('\').Replace('/', '\')
            $mediaRelative = if ([string]::IsNullOrWhiteSpace($relativeInTarget)) {
                $relative.Replace('/', '\')
            }
            else {
                (($relative.TrimEnd('\').TrimEnd('/')) + '\' + $relativeInTarget).Replace('/', '\')
            }
            [void]$files.Add([pscustomobject]@{
                SourcePath        = $file.FullName
                RelativeInTarget  = $relativeInTarget
                MediaRelativePath = $mediaRelative
                Length            = [int64]$file.Length
            })
            $entryBytes += [int64]$file.Length
        }

        [void]$entries.Add([pscustomobject]@{
            RelativePath = $relative
            SourcePath   = $sourceRoot
            Existed      = $true
            Type         = 'Directory'
            Files        = [object[]]$files.ToArray()
            FileCount    = $files.Count
            TotalBytes   = $entryBytes
        })
        $totalFiles += $files.Count
        $totalBytes += $entryBytes
    }

    return [pscustomobject]@{
        Entries    = [object[]]$entries.ToArray()
        TotalFiles = $totalFiles
        TotalBytes = $totalBytes
    }
}

function Copy-AIOLangBackupPlanEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$PlanEntry,
        [Parameter(Mandatory = $true)] [string]$PayloadRoot,
        [Parameter(Mandatory = $true)] [hashtable]$ProgressState
    )

    $destination = Join-Path $PayloadRoot ([string]$PlanEntry.RelativePath)
    if (-not [bool]$PlanEntry.Existed) {
        return [pscustomobject]@{ SHA256 = $null; FileCount = 0; TotalBytes = [int64]0 }
    }

    if ([string]$PlanEntry.Type -eq 'File') {
        Initialize-AIOLangDirectory -Path (Split-Path -Parent $destination)
        $file = @($PlanEntry.Files)[0]
        $showDetail = ([string]$file.MediaRelativePath -match '(?i)^sources\\(boot|install)\.(wim|esd)$')
        if ($showDetail) {
            Write-Host ("   [{0}/{1}] Copiando y verificando {2}..." -f ([int]$ProgressState.Current + 1), $ProgressState.Total, $file.MediaRelativePath) -ForegroundColor Gray
        }
        $copy = Copy-AIOLangFileVerified -Source $file.SourcePath -Destination $destination
        # Solo una copia cuya verificacion SHA-256 termino cuenta como respaldada.
        $ProgressState.Current = [int]$ProgressState.Current + 1
        $percent = if ([int]$ProgressState.Total -gt 0) {
            [math]::Min(100, [math]::Floor(([double]$ProgressState.Current / [double]$ProgressState.Total) * 100))
        }
        else { 100 }
        Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("{0}/{1} archivos verificados ({2}%)" -f $ProgressState.Current, $ProgressState.Total, $percent) -PercentComplete $percent
        if ($showDetail) {
            Write-Host '      [VERIFICADO] SHA-256 coincide.' -ForegroundColor Green
        }
        return [pscustomobject]@{ SHA256 = [string]$copy.SHA256; FileCount = 1; TotalBytes = [int64]$copy.Length }
    }

    Initialize-AIOLangDirectory -Path $destination -Empty
    $records = New-Object System.Collections.Generic.List[object]
    [int64]$totalBytes = 0
    foreach ($file in @($PlanEntry.Files)) {
        $target = Join-Path $destination ([string]$file.RelativeInTarget)
        $showDetail = ([string]$file.MediaRelativePath -match '(?i)^sources\\(boot|install)\.(wim|esd)$')
        if ($showDetail) {
            Write-Host ("   [{0}/{1}] Copiando y verificando {2}..." -f ([int]$ProgressState.Current + 1), $ProgressState.Total, $file.MediaRelativePath) -ForegroundColor Gray
        }
        $copy = Copy-AIOLangFileVerified -Source $file.SourcePath -Destination $target
        # Solo una copia cuya verificacion SHA-256 termino cuenta como respaldada.
        $ProgressState.Current = [int]$ProgressState.Current + 1
        $percent = if ([int]$ProgressState.Total -gt 0) {
            [math]::Min(100, [math]::Floor(([double]$ProgressState.Current / [double]$ProgressState.Total) * 100))
        }
        else { 100 }
        Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("{0}/{1} archivos verificados ({2}%)" -f $ProgressState.Current, $ProgressState.Total, $percent) -PercentComplete $percent
        if ($showDetail) {
            Write-Host '      [VERIFICADO] SHA-256 coincide.' -ForegroundColor Green
        }
        [void]$records.Add([pscustomobject]@{
            RelativePath = ([string]$file.RelativeInTarget).ToLowerInvariant()
            Length       = [int64]$copy.Length
            SHA256       = [string]$copy.SHA256
        })
        $totalBytes += [int64]$copy.Length
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($record in $records) {
        [void]$lines.Add(('{0}|{1}|{2}' -f $record.RelativePath, $record.Length, $record.SHA256))
    }
    return [pscustomobject]@{
        SHA256    = Get-AIOLangTextSha256 -Text (($lines -join "`n") + "`n")
        FileCount = $records.Count
        TotalBytes = $totalBytes
    }
}

function New-AIOLangPreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string[]]$Locales
    )

    $layout = Get-AIOLangBackupLayout -MediaRoot $MediaRoot
    $backupRoot = $layout.PreflightRoot
    $payloadRoot = Join-Path $backupRoot 'Media'
    $manifestPath = Join-Path $backupRoot 'manifest.json'
    $incompletePath = Join-Path $backupRoot 'BACKUP_INCOMPLETO.txt'
    $plan = Get-AIOLangBackupPlan -MediaRoot $layout.MediaRoot -Locales $Locales

    Initialize-AIOLangDirectory -Path $backupRoot -Empty
    Initialize-AIOLangDirectory -Path $payloadRoot
    Set-Content -LiteralPath $incompletePath -Value 'El respaldo no se completo. No utilizar como restauracion.' -Encoding utf8

    Write-Host ''
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host ' RESPALDO PREVIO OBLIGATORIO' -ForegroundColor Cyan
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host (" Archivos a respaldar : {0}" -f $plan.TotalFiles) -ForegroundColor White
    Write-Host (" Tamano aproximado    : {0}" -f (Format-AIOLangByteSize -Bytes $plan.TotalBytes)) -ForegroundColor White
    Write-Host (" Destino              : {0}" -f $backupRoot) -ForegroundColor White
    Write-Host ' Hash                 : SHA-256 para todos los archivos' -ForegroundColor White

    $entries = New-Object System.Collections.Generic.List[object]
    [int64]$totalBytes = 0
    [int]$hashedFileCount = 0
    $progress = @{ Current = 0; Total = [int]$plan.TotalFiles }
    Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("0/{0} archivos verificados (0%)" -f $progress.Total) -PercentComplete 0

    try {
        foreach ($planEntry in @($plan.Entries)) {
            $result = Copy-AIOLangBackupPlanEntry -PlanEntry $planEntry -PayloadRoot $payloadRoot -ProgressState $progress
            $hash = if ([bool]$planEntry.Existed) { [string]$result.SHA256 } else { $null }
            $size = if ([bool]$planEntry.Existed) { [int64]$result.TotalBytes } else { [int64]0 }
            $fileCount = if ([bool]$planEntry.Existed) { [int]$result.FileCount } else { 0 }
            $totalBytes += $size
            $hashedFileCount += $fileCount

            [void]$entries.Add([pscustomobject]@{
                RelativePath = [string]$planEntry.RelativePath
                Existed      = [bool]$planEntry.Existed
                Type         = [string]$planEntry.Type
                Size         = $size
                FileCount    = $fileCount
                Sha256       = $hash
            })
        }
    }
    finally {
        Write-Progress -Activity 'Respaldo previo obligatorio' -Completed
    }

    if ($hashedFileCount -ne [int]$plan.TotalFiles -or $progress.Current -ne [int]$plan.TotalFiles) {
        throw "La cobertura del respaldo no coincide con el plan: esperados=$($plan.TotalFiles), respaldados=$hashedFileCount, progreso=$($progress.Current)."
    }
    if ($totalBytes -ne [int64]$plan.TotalBytes) {
        throw "El tamano respaldado no coincide con el plan: esperado=$($plan.TotalBytes), respaldado=$totalBytes."
    }

    $entriesIndexSha256 = Get-AIOLangEntriesIndexSha256 -Entries ([object[]]$entries.ToArray())
    $manifest = [pscustomobject]@{
        SchemaVersion      = 3
        FormatVersion      = 3
        CreatedAt          = (Get-Date).ToString('o')
        MediaRoot          = $layout.MediaRoot
        BackupRoot         = $backupRoot
        Locales            = $Locales
        HashAlgorithm      = 'SHA256'
        HashCoverage       = 'FilesAndDirectoryTrees'
        HashedFileCount    = $hashedFileCount
        EntriesIndexSha256 = $entriesIndexSha256
        EntryCount         = $entries.Count
        TotalBytes         = $totalBytes
        Entries            = [object[]]$entries.ToArray()
    }
    Write-AIOLangAtomicJson -Path $manifestPath -InputObject $manifest -Depth 8

    $writtenManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$writtenManifest.SchemaVersion -ne 3 -or
        [int]$writtenManifest.FormatVersion -ne 3 -or
        [string]$writtenManifest.EntriesIndexSha256 -ne $entriesIndexSha256 -or
        [int]$writtenManifest.HashedFileCount -ne $hashedFileCount) {
        throw 'El manifest.json de idiomas no supero la verificacion posterior a escritura.'
    }

    Remove-Item -LiteralPath $incompletePath -Force -ErrorAction Stop

    Write-Host (" [OK] Respaldo previo completado y verificado ({0} hashes SHA-256)." -f $hashedFileCount) -ForegroundColor Green
    Write-AIOLangLog -Level INFO -Message "Respaldo Preflight creado en '$backupRoot' con $hashedFileCount archivo(s) cubiertos por SHA-256; indice=$entriesIndexSha256."
    Add-AIOLangOperation -Phase 'Preflight' -Context 'Crear respaldo del medio' -State 'Success' -Details @{ BackupRoot = $backupRoot; Entries = $entries.Count; TotalBytes = $totalBytes; HashedFileCount = $hashedFileCount; EntriesIndexSha256 = $entriesIndexSha256 }

    return [pscustomobject]@{
        Root               = $backupRoot
        SessionRoot        = $layout.SessionRoot
        PayloadRoot        = $payloadRoot
        ManifestPath       = $manifestPath
        Manifest           = $manifest
        HashedFileCount    = $hashedFileCount
        EntriesIndexSha256 = $entriesIndexSha256
    }
}

function Test-AIOLangPreflightBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$BackupRoot)

    $context = Resolve-AIOLangPreflightBackup -Path $BackupRoot
    $incompletePath = Join-Path $context.Root 'BACKUP_INCOMPLETO.txt'
    if (Test-Path -LiteralPath $incompletePath -PathType Leaf) {
        throw "El respaldo Preflight esta marcado como incompleto: '$($context.Root)'."
    }

    $manifest = Get-Content -LiteralPath $context.ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $requiredManifestProperties = @(
        'SchemaVersion', 'FormatVersion', 'CreatedAt', 'MediaRoot',
        'BackupRoot', 'Locales', 'HashAlgorithm', 'HashCoverage',
        'HashedFileCount', 'EntriesIndexSha256', 'EntryCount',
        'TotalBytes', 'Entries'
    )
    foreach ($propertyName in $requiredManifestProperties) {
        if (-not $manifest.PSObject.Properties[$propertyName]) {
            throw "El manifiesto '$($context.ManifestPath)' no contiene la propiedad obligatoria '$propertyName'."
        }
    }

    $schema = [int]$manifest.SchemaVersion
    $format = [int]$manifest.FormatVersion
    if ($schema -ne 3 -or $format -ne 3) {
        throw "Respaldo no compatible: se requiere SchemaVersion/FormatVersion 3/3 y se recibio $schema/$format. Los respaldos anteriores deben recrearse."
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.MediaRoot) -or
        [string]::IsNullOrWhiteSpace([string]$manifest.BackupRoot)) {
        throw "El manifiesto '$($context.ManifestPath)' contiene rutas obligatorias vacias."
    }

    $createdAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$manifest.CreatedAt, [ref]$createdAt)) {
        throw "El manifiesto '$($context.ManifestPath)' contiene una fecha CreatedAt invalida."
    }

    $entries = @($manifest.Entries)
    if ([int]$manifest.EntryCount -ne $entries.Count) {
        throw "El manifiesto declara $($manifest.EntryCount) elementos, pero contiene $($entries.Count)."
    }

    if ([string]$manifest.HashAlgorithm -cne 'SHA256' -or [string]$manifest.HashCoverage -cne 'FilesAndDirectoryTrees') {
        throw 'El manifiesto 3/3 no declara la cobertura SHA-256 esperada.'
    }
    $indexHash = Get-AIOLangEntriesIndexSha256 -Entries $entries
    if ($indexHash -ne [string]$manifest.EntriesIndexSha256) {
        throw 'EntriesIndexSha256 no coincide con el contenido del manifiesto.'
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [int64]$calculatedTotalBytes = 0
    [int]$calculatedHashedFiles = 0
    foreach ($entry in $entries) {
        $requiredEntryProperties = @('RelativePath', 'Existed', 'Type', 'Size', 'FileCount', 'Sha256')
        foreach ($propertyName in $requiredEntryProperties) {
            if (-not $entry.PSObject.Properties[$propertyName]) {
                throw "Una entrada del manifiesto no contiene la propiedad obligatoria '$propertyName'."
            }
        }

        $relative = [string]$entry.RelativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted($relative) -or
            (@($relative -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0)) {
            throw "El manifiesto contiene una ruta relativa invalida: '$relative'."
        }
        if (-not $seenPaths.Add($relative)) {
            throw "El manifiesto contiene una entrada duplicada: '$relative'."
        }

        $entryType = [string]$entry.Type
        $entrySize = [int64]$entry.Size
        $entryFileCount = [int]$entry.FileCount
        $existed = [bool]$entry.Existed
        if ($entrySize -lt 0 -or $entryFileCount -lt 0) {
            throw "La entrada '$relative' contiene valores numericos invalidos."
        }

        $path = Join-Path $context.PayloadRoot $relative
        if (-not $existed) {
            if ($entryType -ne 'Missing' -or $entrySize -ne 0 -or $entryFileCount -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$entry.Sha256)) {
                throw "La entrada ausente '$relative' no cumple el formato Preflight actual."
            }
            if (Test-Path -LiteralPath $path) {
                throw "El respaldo contiene datos inesperados para la entrada ausente '$relative'."
            }
            continue
        }

        if ($entryType -notin @('File', 'Directory')) {
            throw "La entrada existente '$relative' tiene un tipo no admitido: '$entryType'."
        }
        if (-not (Test-Path -LiteralPath $path)) {
            throw "El respaldo esta incompleto: falta '$relative'."
        }

        if ($entryType -eq 'File') {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "La entrada '$relative' debe ser un archivo."
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.Sha256) -or [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw "La entrada de archivo '$relative' no contiene un SHA-256 valido."
            }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ([int64]$item.Length -ne $entrySize) {
                throw "Tamano invalido en '$relative'."
            }
            $hash = Get-AIOLangFileHashRequired -Path $path
            if ($hash -ne [string]$entry.Sha256) {
                throw "Hash invalido en '$relative'."
            }
            if ($entryFileCount -ne 1) {
                throw "FileCount invalido en el archivo '$relative'."
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                throw "La entrada '$relative' debe ser un directorio."
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.Sha256) -or [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw "El directorio '$relative' no contiene un hash de arbol SHA-256 valido."
            }
            $tree = Get-AIOLangDirectoryTreeHash -Path $path
            if ([int64]$tree.TotalBytes -ne $entrySize -or [int]$tree.FileCount -ne $entryFileCount -or [string]$tree.SHA256 -ne [string]$entry.Sha256) {
                throw "Hash de arbol invalido en el directorio '$relative'."
            }
        }

        $calculatedTotalBytes += $entrySize
        $calculatedHashedFiles += $entryFileCount
    }

    if ([int64]$manifest.TotalBytes -ne $calculatedTotalBytes) {
        throw 'El total de bytes del manifiesto no coincide con el contenido del respaldo.'
    }
    if ([int]$manifest.HashedFileCount -ne $calculatedHashedFiles) {
        throw 'HashedFileCount no coincide con los archivos cubiertos por los hashes.'
    }

    return [pscustomobject]@{
        Root            = $context.Root
        Manifest        = $manifest
        PayloadRoot     = $context.PayloadRoot
        ManifestPath    = $context.ManifestPath
        ValidatedHashes = $calculatedHashedFiles
    }
}

function Restore-AIOLangPreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BackupRoot,
        [string]$MediaRoot,
        [switch]$Force
    )

    Assert-AIOLangNoMountedImages
    $validated = Test-AIOLangPreflightBackup -BackupRoot $BackupRoot
    $manifest = $validated.Manifest
    if ([string]::IsNullOrWhiteSpace($MediaRoot)) { $MediaRoot = [string]$manifest.MediaRoot }
    if (-not (Test-Path -LiteralPath $MediaRoot -PathType Container)) { throw "No existe el medio destino '$MediaRoot'." }
    if (-not $Force -and -not (Read-AIOLangYesNo -Prompt "Restaurar el medio '$MediaRoot' desde este respaldo" -Default $false)) { return $false }

    $entries = @($manifest.Entries)
    $position = 0
    Write-Progress -Activity 'Restaurando medio multilingue' -Status "0/$($entries.Count) elementos restaurados (0%)" -PercentComplete 0

    try {
        foreach ($entry in $entries) {
            $position++
            $relative = [string]$entry.RelativePath
            $destination = Join-Path $MediaRoot $relative
            
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop
            }
            if ($entry.Existed) {
                $source = Join-Path $validated.PayloadRoot $relative
                Initialize-AIOLangDirectory -Path (Split-Path -Parent $destination)
                Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force -ErrorAction Stop
                
                if ($entry.Type -eq 'File' -and $entry.Sha256) {
                    $hash = Get-AIOLangFileHashSafe -Path $destination
                    if ($hash -ne [string]$entry.Sha256) { throw "La restauracion de '$relative' no supero la verificacion SHA-256." }
                }
                elseif ($entry.Type -eq 'Directory') {
                    $tree = Get-AIOLangDirectoryTreeHash -Path $destination
                    if ([long]$tree.TotalBytes -ne [long]$entry.Size -or
                        [int]$tree.FileCount -ne [int]$entry.FileCount -or
                        [string]$tree.SHA256 -ne [string]$entry.Sha256) {
                        throw "La restauracion del directorio '$relative' no supero la verificacion del arbol SHA-256."
                    }
                }
            }

            $percent = if ($entries.Count -gt 0) { [math]::Min(100, [math]::Floor(($position * 100.0) / $entries.Count)) } else { 100 }
            Write-Progress -Activity 'Restaurando medio multilingue' -Status ("{0}/{1} elementos restaurados ({2}%)" -f $position, $entries.Count, $percent) -PercentComplete $percent
        }
    } finally {
        Write-Progress -Activity 'Restaurando medio multilingue' -Completed
    }

    Write-AIOLangLog -Level INFO -Message "Medio restaurado desde '$($validated.Root)'."
    return $true
}

function Show-AIOLangRestoreMenu {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host '             RESTAURAR MEDIO MULTILINGUE              ' -ForegroundColor Cyan
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host ''

    $selected = Select-AIOLangFolder -Title 'Selecciona directamente la carpeta Preflight'
    if (-not $selected) { return }

    try {
        $validated = Test-AIOLangPreflightBackup -BackupRoot $selected
        $manifest = $validated.Manifest
        $target = [string]$manifest.MediaRoot
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            $target = Select-AIOLangFolder -Title 'Selecciona el medio de Windows que deseas restaurar'
            if (-not $target) { return }
        }

        $created = [string]$manifest.CreatedAt
        $entryCount = [int]$manifest.EntryCount
        Write-Host " Respaldo : $($validated.Root)" -ForegroundColor White
        Write-Host " Creado   : $created" -ForegroundColor White
        Write-Host " Elementos: $entryCount" -ForegroundColor White
        Write-Host " Destino  : $target" -ForegroundColor White
        Write-Host ''
        Write-Host 'La restauracion reemplazara los WIM y recursos localizados respaldados.' -ForegroundColor Yellow
        $confirmation = (Read-Host 'Escribe RESTAURAR para confirmar').Trim().ToUpperInvariant()
        if ($confirmation -ne 'RESTAURAR') {
            Write-Host 'Restauracion cancelada.' -ForegroundColor Yellow
            Wait-AIOLangUser
            return
        }

        [void](Restore-AIOLangPreflightBackup -BackupRoot $validated.Root -MediaRoot $target -Force)
        Write-Host 'Restauracion completada.' -ForegroundColor Green
    }
    catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red }
    Wait-AIOLangUser
}

function Invoke-AIOLangAtomicReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourcePath,
        [Parameter(Mandatory = $true)] [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "No existe '$SourcePath'." }
    $destinationDirectory = Split-Path -Parent $DestinationPath
    Initialize-AIOLangDirectory -Path $destinationDirectory

    # El archivo nuevo se materializa y verifica primero EN EL MISMO VOLUMEN
    # del destino. Solo el ultimo File.Replace/Move es el cambio visible.
    $stagedNew = Join-Path $destinationDirectory ('.' + [System.IO.Path]::GetFileName($DestinationPath) + '.aio_new_' + [guid]::NewGuid().ToString('N'))
    $temporaryOld = Join-Path $destinationDirectory ('.' + [System.IO.Path]::GetFileName($DestinationPath) + '.aio_old_' + [guid]::NewGuid().ToString('N'))
    $sourceResolved = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
    $replacementComplete = $false
    $replacementPublished = $false
    $hadDestination = Test-Path -LiteralPath $DestinationPath -PathType Leaf
    try {
        $stagedCopy = Copy-AIOLangFileVerified -Source $sourceResolved -Destination $stagedNew
        if ($hadDestination) {
            [System.IO.File]::Replace($stagedNew, $DestinationPath, $temporaryOld, $true)
        }
        else {
            [System.IO.File]::Move($stagedNew, $DestinationPath)
        }
        $replacementPublished = $true
        Clear-AIOLangFileHashCache -Path $DestinationPath
        $sourceHash = [string]$stagedCopy.SHA256
        $destinationHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not $sourceHash -or $sourceHash -ne $destinationHash) { throw "Verificacion SHA-256 fallida despues de reemplazar '$DestinationPath'." }
        $replacementComplete = $true
    }
    catch {
        $replacementError = $_
        if (Test-Path -LiteralPath $temporaryOld -PathType Leaf) {
            try {
                # Restaurar sin borrar primero el destino. Si el archivo esta
                # bloqueado, File.Replace falla conservando el respaldo.
                if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
                    [System.IO.File]::Replace($temporaryOld, $DestinationPath, $stagedNew, $true)
                }
                else { [System.IO.File]::Move($temporaryOld, $DestinationPath) }
                Clear-AIOLangFileHashCache -Path $DestinationPath
            }
            catch {
                throw "Fallo el reemplazo: $($replacementError.Exception.Message). Restauracion incompleta de '$DestinationPath': $($_.Exception.Message). Original conservado en '$temporaryOld'."
            }
        }
        elseif (-not $hadDestination -and $replacementPublished) {
            try { Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop }
            catch { throw "Fallo el reemplazo: $($replacementError.Exception.Message). No se pudo retirar el destino nuevo no verificado '$DestinationPath': $($_.Exception.Message)" }
        }
        throw $replacementError
    }
    finally {
        # Nunca eliminar temporaryOld desde finally: puede ser la unica copia
        # local recuperable si fallo la restauracion.
        if (Test-Path -LiteralPath $stagedNew -PathType Leaf) { Remove-Item -LiteralPath $stagedNew -Force -ErrorAction SilentlyContinue }
    }
    if ($replacementComplete) {
        if (Test-Path -LiteralPath $temporaryOld -PathType Leaf) {
            try { Remove-Item -LiteralPath $temporaryOld -Force -ErrorAction Stop }
            catch { Write-AIOLangLog -Level WARN -Message "Reemplazo verificado; se conserva el respaldo temporal '$temporaryOld' porque no pudo eliminarse: $($_.Exception.Message)" }
        }
        if ($sourceResolved -ine $DestinationPath -and (Test-Path -LiteralPath $sourceResolved -PathType Leaf)) {
            Remove-Item -LiteralPath $sourceResolved -Force -ErrorAction SilentlyContinue
        }
    }
}


function Convert-AIOLangEsdToWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$EsdPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath
    )

    $destination = Join-Path (Split-Path -Parent $EsdPath) 'install.wim'
    $temporary = Join-Path $ScratchPath 'install.converted.wim'
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    $indexes = @(Get-AIOLangImageIndexes -ImagePath $EsdPath)
    if ($indexes.Count -eq 0) { throw "No se encontraron indices en '$EsdPath'." }

    $position = 0
    foreach ($index in $indexes) {
        $position++
        [void](Invoke-AIOLangDism -Arguments @(
            '/Export-Image', "/SourceImageFile:$EsdPath", "/SourceIndex:$index",
            "/DestinationImageFile:$temporary", '/Compress:max', '/CheckIntegrity'
        ) -Context "Convertir install.esd - indice $position/$($indexes.Count)")
    }
    Invoke-AIOLangAtomicReplacement -SourcePath $temporary -DestinationPath $destination
    Remove-Item -LiteralPath $EsdPath -Force -ErrorAction Stop
    Write-AIOLangLog -Level INFO -Message 'install.esd convertido a install.wim.'
    return $destination
}


function Rebuild-AIOLangWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [string]$Context = 'Reconstruir WIM'
    )

    $indexes = @(Get-AIOLangImageIndexes -ImagePath $WimPath)
    $temporary = Join-Path $ScratchPath (([System.IO.Path]::GetFileNameWithoutExtension($WimPath)) + '.rebuild.wim')
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    $position = 0
    foreach ($index in $indexes) {
        $position++
        [void](Invoke-AIOLangDism -Arguments @(
            '/Export-Image', "/SourceImageFile:$WimPath", "/SourceIndex:$index",
            "/DestinationImageFile:$temporary", '/Compress:max', '/CheckIntegrity'
        ) -Context "$Context - indice $position/$($indexes.Count)")
    }
    Invoke-AIOLangAtomicReplacement -SourcePath $temporary -DestinationPath $WimPath
}


function Export-AIOLangSingleInstallIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$ScratchPath
    )

    $temporary = Join-Path $ScratchPath 'install.single.wim'
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    [void](Invoke-AIOLangDism -Arguments @(
        '/Export-Image', "/SourceImageFile:$InstallWim", "/SourceIndex:$Index",
        "/DestinationImageFile:$temporary", '/Compress:max', '/CheckIntegrity'
    ) -Context "Exportar solo el indice $Index de install.wim")
    Invoke-AIOLangAtomicReplacement -SourcePath $temporary -DestinationPath $InstallWim
}

function Get-AIOLangMountedPackageInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MountPath)

    # Usar el DISM seleccionado por el modulo (sistema o ADK) y su salida
    # /English estable. No depender de la version del modulo PowerShell DISM.
    $result = Invoke-AIOLangDism -Arguments @("/Image:$MountPath", '/Get-Packages', '/Format:List') -Context 'Consultar estado CBS de los paquetes' -Quiet
    $packages = New-Object System.Collections.Generic.List[object]
    $identity = $null
    foreach ($line in @($result.Output)) {
        if ([string]$line -match '^\s*Package Identity\s*:\s*(.+?)\s*$') {
            $identity = $matches[1]
        }
        elseif ($identity -and [string]$line -match '^\s*State\s*:\s*(.+?)\s*$') {
            [void]$packages.Add([pscustomobject]@{ PackageName = $identity; PackageState = ($matches[1] -replace '\s', '') })
            $identity = $null
        }
    }
    if ($packages.Count -eq 0) { throw "DISM no devolvio un inventario CBS verificable para '$MountPath'." }
    return [object[]]$packages.ToArray()
}

function Get-AIOLangPackageInstallMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object]$Package,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    if (-not $PSBoundParameters.ContainsKey('InstalledInventory')) {
        $InstalledInventory = @(Get-AIOLangMountedPackageInventory -MountPath $MountPath)
    }
    $expected = [string]$Package.PackageName
    $expectedParts = $expected -split '~'
    $expectedVersion = $null
    if ($expectedParts.Count -eq 5) {
        [void][version]::TryParse($expectedParts[4], [ref]$expectedVersion)
    }
    $found = $null
    foreach ($entry in @($InstalledInventory)) {
        $state = ([string]$entry.PackageState -replace '\s', '')
        if ($state -notin @('Installed', 'InstallPending')) { continue }
        $name = [string]$entry.PackageName
        $parts = $name -split '~'
        if ($parts.Count -ne 5) { continue }
        $version = $null
        if (-not [version]::TryParse($parts[4], [ref]$version)) { continue }
        $matchesIdentity = $false
        if ($expectedParts.Count -eq 5 -and $expectedVersion) {
            # Misma identidad, token, arquitectura e idioma; version igual o
            # posterior. Un manifiesto antiguo no satisface el paquete pedido.
            $matchesIdentity = (($parts[0..3] -join '~') -ieq ($expectedParts[0..3] -join '~') -and $version -ge $expectedVersion)
        }
        elseif ($Package.IdentityName -and $Package.Version -and $Package.Architecture -and $Package.Locale) {
            $arch = Convert-AIOLangArchitectureName -Architecture $parts[2]
            $requestedArch = Convert-AIOLangArchitectureName -Architecture $Package.Architecture
            $matchesIdentity = ($parts[0] -ieq [string]$Package.IdentityName -and
                $arch -ne 'Unknown' -and $arch -eq $requestedArch -and
                $parts[3] -ieq [string]$Package.Locale -and $version -ge [version]$Package.Version)
        }
        if ($matchesIdentity) { $found = $entry; break }
    }
    return [pscustomobject]@{
        Installed = [bool]($null -ne $found)
        MatchedBy = $(if ($found) { 'CbsIdentityAndState' } else { 'NoInstalledCbsMatch' })
        MatchPath = $(if ($found) { Join-Path (Join-Path $MountPath 'Windows\Servicing\Packages') ($found.PackageName + '.mum') } else { $null })
        PackageState = $(if ($found) { [string]$found.PackageState } else { $null })
    }
}

function Get-AIOLangPackageDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    if (-not [string]::IsNullOrWhiteSpace([string]$Package.IdentityName)) { return [string]$Package.IdentityName }
    if (-not [string]::IsNullOrWhiteSpace([string]$Package.Name)) { return [System.IO.Path]::GetFileNameWithoutExtension([string]$Package.Name) }
    return 'Paquete sin nombre'
}

function Test-AIOLangNeutralParentPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object]$Package,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    if ($Package.Category -eq 'LanguagePack') { return $true }
    $packagesRoot = Join-Path $MountPath 'Windows\Servicing\Packages'
    if (-not (Test-Path -LiteralPath $packagesRoot)) { return $true }
    $text = ([string]$Package.IdentityName + ' ' + [string]$Package.Name).ToLowerInvariant()

    if ($Package.Category -eq 'WinPE') {
        # Paquetes base globales de WinPE y fuentes que no requieren un componente neutral previo.
        if ((Test-AIOLangPolicyPatternSet -Text $text -Patterns ([string[]]$script:AIOLangPolicy.WinPEFontSupportPatterns)) -or $text -match '(?:^|[-_])lp(?:[._-]|$)|common-foundation|winpe-languagepack') { return $true }

        # Para satelites WinPE, no basta con que exista un .mum neutral en
        # Windows\Servicing\Packages: el manifiesto puede estar almacenado pero
        # el paquete padre no estar instalado/aplicable en ese indice. Consultar
        # el estado CBS real y exigir un padre neutral Installed/InstallPending.
        $packageName = if ($Package.PSObject.Properties['PackageName']) { [string]$Package.PackageName } else { '' }
        $parts = @($packageName -split '~')
        if ($parts.Count -eq 5 -and -not [string]::IsNullOrWhiteSpace($parts[3])) {
            $requestedVersion = $null
            if ([version]::TryParse($parts[4], [ref]$requestedVersion)) {
                $inventory = if ($PSBoundParameters.ContainsKey('InstalledInventory')) { @($InstalledInventory) } else { @(Get-AIOLangMountedPackageInventory -MountPath $MountPath) }
                foreach ($entry in $inventory) {
                    $state = ([string]$entry.PackageState -replace '\s', '')
                    if ($state -notin @('Installed', 'InstallPending')) { continue }

                    $candidateParts = @(([string]$entry.PackageName) -split '~')
                    if ($candidateParts.Count -ne 5) { continue }
                    if (-not [string]::IsNullOrWhiteSpace($candidateParts[3])) { continue }
                    if ($candidateParts[0] -ine $parts[0] -or $candidateParts[1] -ine $parts[1] -or $candidateParts[2] -ine $parts[2]) { continue }

                    $candidateVersion = $null
                    if (-not [version]::TryParse($candidateParts[4], [ref]$candidateVersion)) { continue }

                    # CBS declara para estos satelites una relacion de padre con
                    # Major/Minor/Build iguales y revision igual o posterior.
                    if ($candidateVersion.Major -eq $requestedVersion.Major -and
                        $candidateVersion.Minor -eq $requestedVersion.Minor -and
                        $candidateVersion.Build -eq $requestedVersion.Build -and
                        $candidateVersion.Revision -ge $requestedVersion.Revision) {
                        return $true
                    }
                }

                Write-AIOLangLog -Level INFO -Message ("WinPE: se omite {0}; el padre neutral {1}~~{2} no esta Installed/InstallPending con version compatible." -f $Package.Name, $parts[0], $parts[4])
                return $false
            }
        }

        # Fallback para paquetes antiguos cuyo metadata no expone PackageName.
        # En ese caso conservar la deteccion por manifiesto, pero sin considerar
        # el propio satelite localizado como prueba del padre neutral.
        $featureName = $null
        if ($Package.IdentityName -match '(?i)^(WinPE-[A-Za-z0-9_-]+?)(?:-Package)?$') {
            $featureName = $matches[1]
        }
        elseif ($Package.Name -match '(?i)^(WinPE-[A-Za-z0-9-]+?)(?:_[a-z]{2}-[a-z]{2,4})?\.cab$') {
            $featureName = $matches[1]
        }

        if ($featureName) {
            if ($featureName -match '(?i)^WinPE-Setup') {
                return (@(Get-ChildItem -LiteralPath $packagesRoot -File -Filter "*$featureName*~~*.mum" -ErrorAction SilentlyContinue).Count -gt 0)
            }
            return (@(Get-ChildItem -LiteralPath $packagesRoot -File -Filter "*$featureName*~~*.mum" -ErrorAction SilentlyContinue).Count -gt 0)
        }

        return $false
    }

    # Paquetes FOD (Features on Demand)
    if ($text -match 'languagefeatures-|internationalfeatures|languageexperience|client-languagepack|server-languagepack') {
        return $true
    }

    $patterns = @()
    if ($text -match 'mspaint') { $patterns = @('*MSPaint*Package*.mum') }
    elseif ($text -match 'notepad-system') { $patterns = @('*Notepad-System*Package*.mum') }
    elseif ($text -match 'notepad') { $patterns = @('*Notepad-FoD*Package*.mum') }
    elseif ($text -match 'powershell-ise') { $patterns = @('*PowerShell-ISE*Package*.mum') }
    elseif ($text -match 'printing-pmcppc') { $patterns = @('*Printing-PMCPPC*Package*.mum') }
    elseif ($text -match 'printing-wfs') { $patterns = @('*Printing-WFS*Package*.mum') }
    elseif ($text -match 'wordpad') { $patterns = @('*WordPad*Package*.mum') }
    elseif ($text -match 'stepsrecorder') { $patterns = @('*StepsRecorder*Package*.mum') }
    elseif ($text -match 'snippingtool') { $patterns = @('*SnippingTool*Package*.mum') }
    elseif ($text -match 'internetexplorer') { $patterns = @('*InternetExplorer-Optional*Package*.mum') }
    elseif ($text -match 'ethernet') { $patterns = @('*Ethernet-Client*Package*.mum') }
    elseif ($text -match 'wifi') { $patterns = @('*Wifi-Client*Package*.mum') }
    elseif ($text -match 'mediaplayer') { $patterns = @('*MediaPlayer*Package*.mum') }
    elseif ($text -match 'wmic') { $patterns = @('*WMIC*Package*.mum') }
    elseif ($text -match 'terminalservices') { $patterns = @('*TerminalServices-AppServer-Client*Package*.mum') }
    elseif ($text -match 'virtualmachineplatform') { $patterns = @('*VirtualMachinePlatform-Client-Disabled*Package*.mum') }
    elseif ($text -match 'projfs') { $patterns = @('*ProjFS*Package*.mum') }
    elseif ($text -match 'telnet') { $patterns = @('*Telnet-Client*Package*.mum') }
    elseif ($text -match 'tftp') { $patterns = @('*TFTP-Client*Package*.mum') }
    elseif ($text -match 'vbscript') { $patterns = @('*VBSCRIPT*Package*.mum') }
    elseif ($text -match 'winocr') { $patterns = @('*WinOcr*Package*.mum') }
    elseif ($text -match 'smbdirect') { $patterns = @('*SmbDirect*Package*.mum') }
    elseif ($text -match 'simpletcp') { $patterns = @('*SimpleTCP*Package*.mum') }
    elseif ($text -match 'senseclient') { $patterns = @('*SenseClient*Package*.mum') }
    elseif ($text -match 'enterpriseclientsync') { $patterns = @('*EnterpriseClientSync*Package*.mum') }
    elseif ($text -match 'directoryservices-adam') { $patterns = @('*DirectoryServices-ADAM*Package*.mum') }
    elseif ($text -match 'servercorefonts') { $patterns = @('*ServerCoreFonts*Package*.mum') }
    else { return $true }

    foreach ($pattern in $patterns) {
        if (@(Get-ChildItem -LiteralPath $packagesRoot -File -Filter $pattern -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

function Add-AIOLangPackageToImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object]$Package,
        [Parameter(Mandatory = $true)] [string]$PackagePath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory,
        [switch]$AllowNotApplicable
    )

    $displayName = Get-AIOLangPackageDisplayName -Package $Package
    $installMatch = if ($PSBoundParameters.ContainsKey('InstalledInventory')) { Get-AIOLangPackageInstallMatch -MountPath $MountPath -Package $Package -InstalledInventory $InstalledInventory } else { Get-AIOLangPackageInstallMatch -MountPath $MountPath -Package $Package }
    if ($installMatch.Installed) {
        Write-Host " [YA PRESENTE] $displayName" -ForegroundColor DarkGray
        Add-AIOLangDismTranscriptLine -Line ("VERIFICAR | {0} | Estado=YaPresente | Coincidencia={1} | Archivo={2}" -f $displayName, $installMatch.MatchedBy, $installMatch.MatchPath)
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'AlreadyPresent' -Details ([pscustomobject]@{
            Package   = $displayName
            MatchedBy = $installMatch.MatchedBy
            MatchPath = $installMatch.MatchPath
        })
        return [pscustomobject]@{ Success = $true; State = 'AlreadyPresent'; ExitCode = 0; Match = $installMatch }
    }
    $parentPresent = if ($PSBoundParameters.ContainsKey('InstalledInventory')) { Test-AIOLangNeutralParentPresent -MountPath $MountPath -Package $Package -InstalledInventory $InstalledInventory } else { Test-AIOLangNeutralParentPresent -MountPath $MountPath -Package $Package }
    if (-not $parentPresent) {
        Write-Host " [OMITIDO] $($Package.Name) - componente neutral no presente." -ForegroundColor DarkYellow
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'SkippedMissingParent' -Details $Package.Name
        return [pscustomobject]@{ Success = $true; State = 'SkippedMissingParent'; ExitCode = 0 }
    }

    # Get-PackageInfo admite CAB. Los manifiestos expandidos de un ESD
    # conservan la comprobacion nativa de Add-Package y la verificacion CBS
    # posterior; no asumir que Get-PackageInfo admite un archivo .mum.
    if ([System.IO.Path]::GetExtension($PackagePath) -ieq '.cab') {
        $info = Invoke-AIOLangDism -Arguments @("/Image:$MountPath", '/Get-PackageInfo', "/PackagePath:$PackagePath") -Context "$Context - comprobar aplicabilidad CBS" -Quiet
        $applicability = @($info.Output | Where-Object { [string]$_ -match '^\s*Applicable\s*:\s*(Yes|No)\s*$' })
        if ($applicability.Count -ne 1) { throw "No se pudo determinar la aplicabilidad CBS de '$($Package.Name)' en '$MountPath'." }
        if ([string]$applicability[0] -match ':\s*No\s*$') {
            Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'NotApplicable' -Details @{ Package = $Package.Name; MountPath = $MountPath; Evidence = [string]$applicability[0] }
            if (-not $AllowNotApplicable) { throw "CBS indica que '$($Package.Name)' no es aplicable a '$MountPath'." }
            Write-Host " [OMITIDO] $($Package.Name) - CBS indica que no es aplicable." -ForegroundColor DarkYellow
            return [pscustomobject]@{ Success = $true; State = 'NotApplicable'; ExitCode = 0 }
        }
    }
    else {
        Write-AIOLangLog -Level INFO -Message "${Context}: manifiesto expandido; aplicabilidad a cargo de Add-Package y verificacion posterior de identidades CBS."
    }

    $scratch = if ($Script:Scratch_DIR) { $Script:Scratch_DIR } else { Join-Path $script:AIOLangSessionRoot 'Scratch' }
    Initialize-AIOLangDirectory -Path $scratch
    return Invoke-AIOLangDism -Arguments @(
        "/Image:$MountPath", '/Add-Package', "/PackagePath:$PackagePath", "/ScratchDir:$scratch"
    ) -Context $Context -AllowNotApplicable:$AllowNotApplicable
}

function Add-AIOLangLanguagePacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [object[]]$Payloads,
        [Parameter(Mandatory = $true)] [string]$ContextPrefix
    )

    foreach ($package in $Packages | Sort-Object Locale, Name) {
        $payload = $Payloads | Where-Object { $_.Package.FilePath -eq $package.FilePath } | Select-Object -First 1
        if (-not $payload) { throw "No se preparo el contenido de '$($package.Name)'." }
        $context = "$ContextPrefix - paquete de idioma $($package.Locale)"
        $result = Add-AIOLangPackageToImage -MountPath $MountPath -Package $package -PackagePath $payload.PackagePath -Context $context
        if (-not $result.Success) { throw "$context fallo." }
    }
}

function Add-AIOLangFeaturePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$ContextPrefix
    )

    $normalizedPackages = @($Packages | Where-Object { $null -ne $_ } | Sort-Object Priority, Locale, Name)
    if ($normalizedPackages.Count -eq 0) {
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $ContextPrefix -State 'NoCompatiblePackages' -Details @{ Count = 0 }
        return @()
    }

    $applied = New-Object System.Collections.Generic.List[object]
    $installedInventory = @(Get-AIOLangMountedPackageInventory -MountPath $MountPath)
    foreach ($package in $normalizedPackages) {
        $context = "$ContextPrefix - $($package.Locale) - $($package.IdentityName)"
        $res = Add-AIOLangPackageToImage -MountPath $MountPath -Package $package -PackagePath $package.FilePath -Context $context -InstalledInventory $installedInventory -AllowNotApplicable
        if ($res -and $res.Success -and ($res.State -in @('Success', 'AlreadyPresent'))) {
            [void]$applied.Add($package)
            # Actualizar el inventario solamente cuando DISM pudo cambiar el
            # estado CBS. Esto permite que un satelite posterior detecte un
            # padre neutral instalado durante la misma secuencia.
            if ($res.State -eq 'Success') {
                $installedInventory = @(Get-AIOLangMountedPackageInventory -MountPath $MountPath)
            }
        }
    }
    return [object[]]$applied.ToArray()
}

function Assert-AIOLangInstalledPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $installedInventory = @(Get-AIOLangMountedPackageInventory -MountPath $MountPath)
    $results = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($package in @($Packages | Where-Object { $null -ne $_ } | Sort-Object Category, Locale, Name -Unique)) {
        $displayName = Get-AIOLangPackageDisplayName -Package $package
        $match = Get-AIOLangPackageInstallMatch -MountPath $MountPath -Package $package -InstalledInventory $installedInventory
        $state = if ($match.Installed) { $match.PackageState } else { 'Missing' }
        $result = [pscustomobject]@{
            Category   = $package.Category
            Locale     = $package.Locale
            Package    = $displayName
            Installed  = [bool]$match.Installed
            PackageState = $match.PackageState
            MatchedBy  = $match.MatchedBy
            MatchPath  = $match.MatchPath
        }
        [void]$results.Add($result)

        Add-AIOLangDismTranscriptLine -Line ("VERIFICAR | {0} | Categoria={1} | Idioma={2} | Estado={3} | Coincidencia={4} | Archivo={5}" -f $displayName, $package.Category, $package.Locale, $state, $match.MatchedBy, $match.MatchPath)
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State $state -Details $result

        if ($match.Installed) {
            Write-Host " [VERIFICADO] $displayName" -ForegroundColor DarkGreen
        }
        else {
            Write-Host " [FALTANTE] $displayName" -ForegroundColor Red
            [void]$missing.Add($displayName)
        }
    }

    if ($missing.Count -gt 0) {
        throw "La verificacion de paquetes detecto componentes ausentes: $($missing -join ', ')."
    }
    return [object[]]$results.ToArray()
}

function Set-AIOLangInternationalSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$DefaultLocale,
        [Parameter(Mandatory = $true)] [string]$ContextPrefix,
        [string]$DistributionPath,
        [switch]$SkipLangIni
    )

    [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-AllIntl:$DefaultLocale", '/Quiet') -Context "$ContextPrefix - Set-AllIntl")
    [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-SKUIntlDefaults:$DefaultLocale", '/Quiet') -Context "$ContextPrefix - Set-SKUIntlDefaults")
    if ($DistributionPath) {
        # Gen-LangINI reconstruye sources\lang.ini a partir del inventario de
        # paquetes de ESTA imagen. Microsoft (Add languages to Windows Setup,
        # paso 4) solo lo ejecuta una vez, contra install.wim -- la unica
        # imagen que conoce todas las ediciones/idiomas reales del medio. Si
        # tambien corriera contra boot.wim (WinPE), el lang.ini queda
        # truncado al inventario de WinPE y corrompe el selector de idioma
        # de Windows Setup. $SkipLangIni evita eso cuando $MountPath es boot.wim.
        if (-not $SkipLangIni) {
            [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", '/Gen-LangINI', "/Distribution:$DistributionPath", '/Quiet') -Context "$ContextPrefix - Generar lang.ini")
        }
        [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-SetupUILang:$DefaultLocale", "/Distribution:$DistributionPath", '/Quiet') -Context "$ContextPrefix - Idioma de Setup")
    }
}

function Get-AIOLangPendingServicingState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MountPath)
    try {
        if (Test-Path -LiteralPath (Join-Path $MountPath 'Windows\WinSxS\pending.xml') -PathType Leaf -ErrorAction Stop) {
            return [pscustomobject]@{ Known = $true; Pending = $true; Reason = 'pending.xml presente; la limpieza requiere completar las operaciones pendientes.' }
        }
        $packages = @(Get-AIOLangMountedPackageInventory -MountPath $MountPath)
        $pending = @($packages | Where-Object { ([string]$_.PackageState -replace '\s', '') -in @('InstallPending', 'UninstallPending', 'PartiallyInstalled') })
        return [pscustomobject]@{ Known = $true; Pending = ($pending.Count -gt 0); Reason = $(if ($pending.Count) { 'CBS tiene paquetes pendientes: ' + (($pending | ForEach-Object { $_.PackageName }) -join ', ') } else { 'Sin operaciones CBS pendientes.' }) }
    }
    catch {
        return [pscustomobject]@{ Known = $false; Pending = $false; Reason = "No se pudo comprobar el estado CBS: $($_.Exception.Message)" }
    }
}

function Invoke-AIOLangComponentCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ResetBase
    )

    $state = Get-AIOLangPendingServicingState -MountPath $MountPath
    if (-not $state.Known -or $state.Pending) {
        $status = if ($state.Pending) { 'SkippedPendingActions' } else { 'SkippedUnknownServicingState' }
        Write-Host " [APLAZADO] ${Context}: $($state.Reason)" -ForegroundColor Yellow
        Write-AIOLangLog -Level WARN -Message "${Context}: $status; $($state.Reason)"
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State $status -Details $state
        return
    }
    $scratch = if ($Script:Scratch_DIR) { $Script:Scratch_DIR } else { Join-Path $script:AIOLangSessionRoot 'Scratch' }
    $arguments = @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup', "/ScratchDir:$scratch")
    if ($ResetBase) { $arguments += '/ResetBase' }
    [void](Invoke-AIOLangDism -Arguments $arguments -Context $Context)
}

function Get-AIOLangWinPEImageDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build
    )

    return [pscustomobject]@{
        Architecture = $Architecture
        Build        = $Build
        ImageIndex   = 1
        ImageName    = 'WinPE'
        ImageDescription = 'Windows Recovery Environment / WinPE'
        InstallationType = 'WinPE'
        EditionId    = 'WinPE'
        ProductFamily = 'WinPE'
    }
}

function Update-AIOLangWinREImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WinREPath,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$DefaultLocale,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [switch]$Cleanup,
        [switch]$ResetBase
    )

    $winREImages = @(Get-AIOLangBootImageMetadata -BootWim $WinREPath)
    if ($winREImages.Count -ne 1) { throw 'winre.wim debe contener exactamente un indice.' }
    $descriptor = $winREImages[0]
    if ($descriptor.Architecture -ne $Architecture) { throw 'La arquitectura de WinRE no coincide con install.wim.' }
    $Build = [int]$descriptor.Build
    # Microsoft: "Use languages from the Languages and Optional Features ISO,
    # not from the Windows 10 ADK, to localize WinRE." El ADK solo es fuente
    # valida para boot.wim/Setup; aqui se excluye para no depender de un
    # arbol WinPE_OCs que puede no coincidir con el build real de winre.wim.
    $winREInventory = @($Inventory | Where-Object {
        $pkgSource = if ($_.PSObject.Properties['Source']) { $_.Source } else { 'Repositorio' }
        $_.Category -ne 'WinPE' -or ($pkgSource -ne 'ADK WinPE')
    })
    $packages = @(Get-AIOLangPackagesForImage -Inventory $winREInventory -Image $descriptor -Locales $Locales -Category 'WinPE')
    if ($packages.Count -eq 0) { throw "No se encontraron paquetes WinPE compatibles para $Architecture / build $Build (deben provenir del repositorio/ISO de Languages and Optional Features, no del ADK)." }

    Mount-AIOLangImage -ImagePath $WinREPath -Index 1 -MountPath $MountPath -ScratchPath $ScratchPath -Context 'Montar winre.wim'
    $committed = $false
    try {
        $script:AIOLangCurrentPhase = 'WinRE'
        $appliedWinRE = @(Add-AIOLangFeaturePackages -MountPath $MountPath -Packages $packages -ContextPrefix 'Integrar idioma en WinRE')
        Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix 'Configurar WinRE'
        if ($appliedWinRE.Count -gt 0) {
            [void](Assert-AIOLangInstalledPackages -MountPath $MountPath -Packages $appliedWinRE -Context 'Verificar paquetes de idioma en WinRE')
        }
        [void](Assert-AIOLangMountedWinPELocalization -MountPath $MountPath -Locales $Locales -Context 'Verificar idiomas de WinRE')
        if ($Cleanup) { Invoke-AIOLangComponentCleanup -MountPath $MountPath -Context 'Limpiar winre.wim' -ResetBase:$ResetBase }
        [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Commit -Context 'Guardar winre.wim')
        $committed = $true
    }
    finally {
        if (-not $committed -and $MountPath -in $script:AIOLangMountedPaths) {
            [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context 'Descartar winre.wim por error' -NoThrow)
        }
    }

    Rebuild-AIOLangWim -WimPath $WinREPath -ScratchPath $ScratchPath -Context 'Optimizar winre.wim'
}

function Initialize-AIOLangFileReparseNative {
    [CmdletBinding()]
    param()

    if ('AdminImagenOffline.AIOLangReparseNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace AdminImagenOffline {
    public static class AIOLangReparseNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct AttributeTagInformation {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess,
            uint shareMode, IntPtr securityAttributes, uint creationDisposition,
            uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,
            int informationClass, out AttributeTagInformation information, uint bufferSize);

        public static AttributeTagInformation ReadInfo(string path) {
            string fullPath = Path.GetFullPath(path);
            if (!fullPath.StartsWith(@"\\?\", StringComparison.Ordinal)) {
                fullPath = fullPath.StartsWith(@"\\", StringComparison.Ordinal)
                    ? @"\\?\UNC\" + fullPath.Substring(2) : @"\\?\" + fullPath;
            }
            // Access=0: consultar metadatos. Compartir lectura/escritura/borrado.
            // OPEN_REPARSE_POINT evita resolver el enlace del archivo final.
            using (SafeFileHandle handle = CreateFileW(fullPath, 0, 7, IntPtr.Zero,
                3, 0x00200000 | 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "No se pudo abrir para consultar el reparse tag: " + path);
                }
                AttributeTagInformation information;
                if (!GetFileInformationByHandleEx(handle, 9, out information,
                    (uint)Marshal.SizeOf(typeof(AttributeTagInformation)))) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "No se pudo consultar el reparse tag: " + path);
                }
                if ((information.FileAttributes & 0x400) == 0) information.ReparseTag = 0;
                return information;
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Get-AIOLangFileReparseInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    Initialize-AIOLangFileReparseNative
    $info = [AdminImagenOffline.AIOLangReparseNative]::ReadInfo($Path)
    $tag = [uint32]$info.ReparseTag
    $tagHex = '0x{0:X8}' -f $tag
    $kind = switch ($tagHex) {
        '0x00000000' { 'None' }
        '0x80000008' { 'WIM' }
        '0x80000017' { 'WOF' }
        '0xA0000003' { 'MountPoint' }
        '0xA000000C' { 'SymbolicLink' }
        default { 'Other' }
    }
    return [pscustomobject]@{
        AttributesValue = [int]$info.FileAttributes
        Tag = $tag
        TagHex = $tagHex
        Kind = $kind
    }
}

function Assert-AIOLangFileReparsePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$Snapshot
    )

    if (($Snapshot.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0) { return }
    if ($null -eq $Snapshot.ReparseTag) {
        throw "No se pudo identificar el punto de reanalisis de '${Path}': $($Snapshot.Errors -join ' | ')"
    }
    # WIM y WOF son filtros de almacenamiento, no enlaces que redirigen a
    # otra ruta. El filtro gestiona su materializacion durante la escritura.
    # No borrar el reparse point ni modificar las ACL de su carpeta padre.
    $tagHex = '0x{0:X8}' -f [uint32]$Snapshot.ReparseTag
    $isDirectory = ($Snapshot.AttributesValue -band [int][System.IO.FileAttributes]::Directory) -ne 0
    if ($isDirectory -or $tagHex -notin @('0x80000008', '0x80000017')) {
        throw "Punto de reanalisis no admitido para escritura: '$Path' (tag $tagHex)."
    }
    Write-AIOLangLog -Level INFO -Message "Archivo respaldado por WIM/WOF admitido para copia: '$Path' (tag $tagHex)."
}


function Get-AIOLangFileAccessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $state = [ordered]@{
        Path = $Path; Exists = $false; Attributes = $null; AttributesValue = $null
        OwnerSid = $null; Sddl = $null; AccessSddl = $null; Errors = @()
        ReparseTag = $null; ReparseTagHex = $null; ReparseKind = $null
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $state.Exists = $true
        $state.Attributes = [string]$item.Attributes
        $state.AttributesValue = [int]$item.Attributes
    }
    catch { $state.Errors += $_.Exception.Message }
    if ($state.Exists -and ($state.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        try {
            $reparse = Get-AIOLangFileReparseInfo -Path $Path
            # Leer atributos y tag del mismo handle. Si el filtro materializo
            # el archivo desde Get-Item, aceptar su nuevo estado sin reparse.
            $state.AttributesValue = $reparse.AttributesValue
            $state.Attributes = [string][System.IO.FileAttributes]$reparse.AttributesValue
            $state.ReparseTag = $reparse.Tag
            $state.ReparseTagHex = $reparse.TagHex
            $state.ReparseKind = $reparse.Kind
        }
        catch { $state.Errors += "ReparseTag: $($_.Exception.Message)" }
    }
    if ($state.Exists) {
        try {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
            $state.OwnerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            $state.Sddl = $acl.GetSecurityDescriptorSddlForm($sections)
            $state.AccessSddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        }
        catch { $state.Errors += $_.Exception.Message }
    }
    return [pscustomobject]$state
}

function Write-AIOLangFileCopyDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [Parameter(Mandatory = $true)] [string]$Phase,
        [Parameter(Mandatory = $true)] [string]$Message,
        [AllowNull()] [object]$OriginalDestination
    )

    # Se captura antes del desmontaje de emergencia; el paquete de diagnostico
    # ya recoge los .log de la sesion, incluso cuando el WIM fue descartado.
    try {
        $record = [ordered]@{
            Timestamp = (Get-Date).ToString('o'); Phase = $Phase; Message = $Message
            OriginalDestination = $OriginalDestination
            Source = Get-AIOLangFileAccessSnapshot -Path $Source
            Destination = Get-AIOLangFileAccessSnapshot -Path $Destination
            Parent = Get-AIOLangFileAccessSnapshot -Path (Split-Path -Parent $Destination)
        }
        $json = $record | ConvertTo-Json -Depth 8 -Compress
        Write-AIOLangLog -Level WARN -Message "Idiomas/acceso: $json"
        if ($script:AIOLangSessionRoot -and (Test-Path -LiteralPath $script:AIOLangSessionRoot -PathType Container)) {
            Add-Content -LiteralPath (Join-Path $script:AIOLangSessionRoot 'Idiomas_FileAccess.log') -Value $json -Encoding UTF8 -ErrorAction Stop
        }
    }
    catch { Write-AIOLangLog -Level WARN -Message "No se pudo registrar el acceso de Idiomas a '${Destination}': $($_.Exception.Message)" }
}

function Invoke-AIOLangFileSecurityCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('takeown.exe', 'icacls.exe')] [string]$Name,
        [Parameter(Mandatory = $true)] [string[]]$Arguments
    )

    $executable = Join-Path $script:AIOLangNativeSystemDirectory $Name
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "No se encontro '$executable'." }
    # En Windows PowerShell 5.1 stderr nativo puede producir ErrorRecord.
    # Capturarlo no debe impedir leer y comprobar el codigo real del proceso.
    $ErrorActionPreference = 'Continue'
    # El proceso nativo actualiza la variable global, no una copia local.
    $global:LASTEXITCODE = $null
    $output = & $executable @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    $detail = ($output | Out-String).Trim()
    Write-AIOLangLog -Level INFO -Message "Idiomas: $Name; codigo=$exitCode; $detail"
    if ($null -eq $exitCode -or $exitCode -ne 0) { throw "Idiomas: $Name fallo con codigo '${exitCode}': $detail" }
}

function Set-AIOLangCopyFileAttributes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [System.IO.FileAttributes]$Attributes
    )

    # File.SetAttributes solo admite estos atributos basicos. SparseFile,
    # Compressed, Encrypted, Directory y ReparsePoint requieren otras APIs
    # o describen el almacenamiento/tipo del archivo. No se restauran aqui.
    # Al sobrescribir un archivo disperso de un WIM, SparseFile puede cambiar
    # sin alterar los bytes; su integridad se verifica por SHA-256 en la copia.
    $settableMask = [System.IO.FileAttributes]::ReadOnly -bor
        [System.IO.FileAttributes]::Hidden -bor
        [System.IO.FileAttributes]::System -bor
        [System.IO.FileAttributes]::Archive -bor
        [System.IO.FileAttributes]::Temporary -bor
        [System.IO.FileAttributes]::Offline -bor
        [System.IO.FileAttributes]::NotContentIndexed
    $requested = [System.IO.FileAttributes]([int]$Attributes -band [int]$settableMask)
    $current = [System.IO.File]::GetAttributes($Path)
    if (([int]$current -band [int]$settableMask) -eq [int]$requested) { return }

    # Normal es el valor para quitar todos los atributos editables; no se
    # combina con otros bits ni se compara como un indicador independiente.
    $toSet = if ([int]$requested -eq 0) { [System.IO.FileAttributes]::Normal } else { $requested }
    [System.IO.File]::SetAttributes($Path, $toSet)
    $observed = [System.IO.File]::GetAttributes($Path)
    if (([int]$observed -band [int]$settableMask) -ne [int]$requested) {
        throw "No se pudieron establecer los atributos editables '$requested' en '$Path'. Atributos observados: '$observed'."
    }
}

function Restore-AIOLangCopyFileSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$Original
    )

    $failures = New-Object System.Collections.Generic.List[string]
    # Devolver el propietario mientras el permiso temporal aun permite WRITE_DAC.
    # El SID permite restaurarlo sin depender del idioma del sistema.
    try {
        $current = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($current.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $Original.OwnerSid) {
            Invoke-AIOLangFileSecurityCommand -Name 'icacls.exe' -Arguments @($Path, '/setowner', ('*' + $Original.OwnerSid), '/Q')
        }
    }
    catch { [void]$failures.Add("Propietario: $($_.Exception.Message)") }
    # Restaurar solo la DACL; no cambiar grupo ni auditoria, ni inventar un
    # propietario TrustedInstaller como alternativa a la identidad original.
    try {
        $current = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($current.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access) -cne $Original.AccessSddl) {
            $restoreAcl = New-Object System.Security.AccessControl.FileSecurity
            $restoreAcl.SetSecurityDescriptorSddlForm($Original.Sddl, [System.Security.AccessControl.AccessControlSections]::Access)
            Set-Acl -LiteralPath $Path -AclObject $restoreAcl -ErrorAction Stop
        }
    }
    catch { [void]$failures.Add("DACL: $($_.Exception.Message)") }
    try {
        $restored = Get-AIOLangFileAccessSnapshot -Path $Path
        if ($restored.OwnerSid -ne $Original.OwnerSid -or $restored.Sddl -cne $Original.Sddl) {
            throw 'La comprobacion de propietario/DACL no coincide con el respaldo original.'
        }
    }
    catch { [void]$failures.Add($_.Exception.Message) }
    if ($failures.Count -gt 0) { throw "No se pudo restaurar la seguridad de '${Path}': $($failures -join ' | ')" }
}

function Copy-AIOLangProtectedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $original = $null
    $securityTouched = $false
    $attributesTouched = $false
    $copyError = $null
    try {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf -ErrorAction Stop)) { throw "No existe el archivo Idiomas '$Source'." }
        if (Test-Path -LiteralPath $Destination -PathType Container -ErrorAction Stop) { throw "El destino Idiomas es un directorio: '$Destination'." }
        $hadDestination = Test-Path -LiteralPath $Destination -PathType Leaf -ErrorAction Stop
        if ($hadDestination) {
            $original = Get-AIOLangFileAccessSnapshot -Path $Destination
            if ($null -eq $original.AttributesValue) { throw "No se pudieron respaldar los atributos de '$Destination'." }
            if (($original.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Assert-AIOLangFileReparsePolicy -Path $Destination -Snapshot $original
            }
            $mask = [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden
            $writableAttributes = [System.IO.FileAttributes]($original.AttributesValue -band (-bnot [int]$mask))
        }

        try {
            try {
                if ($hadDestination) {
                    $attributesTouched = $true
                    Set-AIOLangCopyFileAttributes -Path $Destination -Attributes $writableAttributes
                }
                Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            }
            catch {
                $accessDenied = $false
                $exception = $_.Exception
                while ($null -ne $exception) {
                    if ($exception -is [System.UnauthorizedAccessException] -or (($exception.HResult -band 0xFFFF) -eq 5)) { $accessDenied = $true; break }
                    $exception = $exception.InnerException
                }
                if (-not $hadDestination -or -not $accessDenied) { throw }
                Write-AIOLangFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'BeforePermissionRetry' -Message $_.Exception.Message -OriginalDestination $original

                if (-not $original.Sddl -or -not $original.OwnerSid -or -not $original.AccessSddl) {
                    throw "No se puede reintentar '$Destination': no se pudo respaldar su propietario/DACL. $($original.Errors -join ' | ')"
                }
                $securityTouched = $true
                Invoke-AIOLangFileSecurityCommand -Name 'takeown.exe' -Arguments @('/F', $Destination, '/A')
                Invoke-AIOLangFileSecurityCommand -Name 'icacls.exe' -Arguments @($Destination, '/grant', '*S-1-5-32-544:F', '/Q')
                Set-AIOLangCopyFileAttributes -Path $Destination -Attributes $writableAttributes
                Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
                Write-AIOLangLog -Level INFO -Message "Idiomas: copia recuperada tras ajustar permisos de '$Destination'."
            }
            $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
            $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($sourceHash -ne $destinationHash) { throw "Verificacion SHA-256 fallida para el archivo Idiomas '$Destination'." }
        }
        catch {
            $copyError = $_
            Write-AIOLangFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'CopyFailed' -Message $_.Exception.Message -OriginalDestination $original
            throw
        }
        finally {
            $restoreErrors = New-Object System.Collections.Generic.List[string]
            # Atributos primero: todavia contamos con el permiso temporal.
            if ($attributesTouched) {
                try { Set-AIOLangCopyFileAttributes -Path $Destination -Attributes ([System.IO.FileAttributes]$original.AttributesValue) }
                catch { [void]$restoreErrors.Add("Atributos: $($_.Exception.Message)") }
            }
            if ($securityTouched) {
                try { Restore-AIOLangCopyFileSecurity -Path $Destination -Original $original }
                catch { [void]$restoreErrors.Add($_.Exception.Message) }
            }
            if ($restoreErrors.Count -gt 0) {
                $copyDetail = if ($copyError) { " Error de copia: $($copyError.Exception.Message)." } else { '' }
                # Una restauracion fallida impide commit aunque la copia funciono.
                throw "Idiomas: fallo la restauracion de '${Destination}': $($restoreErrors -join ' | ').$copyDetail"
            }
        }
    }
    catch {
        Write-AIOLangFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'FinalFailure' -Message $_.Exception.Message -OriginalDestination $original
        throw
    }
}

function Copy-AIOLangFileWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [ValidateRange(1, 20)] [int]$Retries = 8
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Copy-AIOLangProtectedFile -Source $Source -Destination $Destination
            return
        }
        catch {
            # Solo repetir bloqueos transitorios; un error de permisos o de
            # restauracion de seguridad debe detener el commit de la imagen.
            $transient = $false
            $exception = $_.Exception
            while ($null -ne $exception) {
                if (($exception.HResult -band 0xFFFF) -in @(32, 33)) { $transient = $true; break }
                $exception = $exception.InnerException
            }
            if (-not $transient -or $attempt -eq $Retries) { throw }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
}

function Update-AIOLangInstallWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [int[]]$Indexes,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$Payloads,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$DefaultLocale,
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$WinREMountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$WinRECacheRoot,
        [Parameter(Mandatory = $true)] [string]$EastAsianFontCacheRoot,
        [switch]$IntegrateFod,
        [switch]$UpdateWinRE,
        [switch]$Cleanup,
        [switch]$ResetBase
    )

    $winreCache = @{}
    $selectedImages = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes } | Sort-Object ImageIndex)
    for ($position = 0; $position -lt $selectedImages.Count; $position++) {
        $image = $selectedImages[$position]
        $index = [int]$image.ImageIndex
        $script:AIOLangCurrentPhase = "install.wim indice $index"
        Mount-AIOLangImage -ImagePath $InstallWim -Index $index -MountPath $MountPath -ScratchPath $ScratchPath -Context "Montar install.wim - indice $index/$($Images.Count)"
        $committed = $false
        try {
            $languagePackages = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'LanguagePack')
            Add-AIOLangLanguagePacks -MountPath $MountPath -Packages $languagePackages -Payloads $Payloads -ContextPrefix "install.wim indice $index"

            $fodPackages = @()
            $appliedFod = @()
            if ($IntegrateFod) {
                $fodPackages = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'LanguageFOD')
                if ($fodPackages.Count -gt 0) {
                    $appliedFod = @(Add-AIOLangFeaturePackages -MountPath $MountPath -Packages $fodPackages -ContextPrefix "FOD indice $index")
                }
                else {
                    Write-Host ' [OMITIDO] No hay Features on Demand compatibles para este indice.' -ForegroundColor DarkYellow
                }
            }

            $expectedPackages = @($languagePackages) + @($appliedFod)
            [void](Assert-AIOLangInstalledPackages -MountPath $MountPath -Packages $expectedPackages -Context "Verificar paquetes install.wim indice $index")

            # En modo sin localizacion WinPE completa, se conservan las fuentes de
            # Asia oriental desde install.wim. Se capturan una sola vez desde el
            # ultimo indice seleccionado, despues de integrar LP/FOD, para reutilizarlas
            # en ambos indices de boot.wim cuando se entra en SetupResourcesOnly.
            if ($position -eq ($selectedImages.Count - 1)) {
                [void](Save-AIOLangEastAsianFontPayload -MountPath $MountPath -Payloads $Payloads -Architecture $image.Architecture -Locales $Locales -CacheRoot $EastAsianFontCacheRoot)
            }

            $distribution = if ($position -eq ($selectedImages.Count - 1)) { $MediaRoot } else { $null }
            Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix "Configurar idioma indice $index" -DistributionPath $distribution

            $winreSource = Join-Path $MountPath 'Windows\System32\Recovery\winre.wim'
            if ($UpdateWinRE -and (Test-Path -LiteralPath $winreSource -PathType Leaf)) {
                $hash = (Get-FileHash -LiteralPath $winreSource -Algorithm SHA256 -ErrorAction Stop).Hash
                $hashToken = ($hash -replace '[^A-Za-z0-9]', '')
                if ([string]::IsNullOrWhiteSpace($hashToken)) { $hashToken = [guid]::NewGuid().ToString('N') }
                $cacheKey = "$($image.Architecture)_$hash"
                if (-not $winreCache.ContainsKey($cacheKey)) {
                    $winreWork = Join-Path $WinRECacheRoot ("winre_{0}_{1}.wim" -f $image.Architecture, $hashToken)
                    Copy-AIOLangFileWithRetry -Source $winreSource -Destination $winreWork
                    Update-AIOLangWinREImage -WinREPath $winreWork -Architecture $image.Architecture -Build $image.Build -Inventory $Inventory -Locales $Locales -DefaultLocale $DefaultLocale -MountPath $WinREMountPath -ScratchPath $ScratchPath -Cleanup:$Cleanup -ResetBase:$ResetBase
                    $winreCache[$cacheKey] = $winreWork
                }
                Copy-AIOLangFileWithRetry -Source $winreCache[$cacheKey] -Destination $winreSource
                Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Reinyectar winre.wim actualizado' -State 'Success' -Details @{ Index = $index; CacheKey = $cacheKey }
            }
            elseif ($UpdateWinRE) {
                Write-Host ' [OMITIDO] Este indice no contiene winre.wim.' -ForegroundColor DarkYellow
            }

            if ($Cleanup) { Invoke-AIOLangComponentCleanup -MountPath $MountPath -Context "Limpiar install.wim indice $index" -ResetBase:$ResetBase }
            [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Commit -Context "Guardar install.wim indice $index")
            $committed = $true
        }
        finally {
            if (-not $committed -and $MountPath -in $script:AIOLangMountedPaths) {
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Descartar install.wim indice $index por error" -NoThrow)
            }
        }
    }
}

function Get-AIOLangBootImageMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$BootWim)
    $images = @(Get-AIOLangImageMetadata -ImagePath $BootWim)
    foreach ($image in $images) {
        $image.InstallationType = 'WinPE'; $image.EditionId = 'WinPE'; $image.ProductFamily = 'WinPE'
    }
    return [object[]]$images
}

function Get-AIOLangPayloadFileIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Payload)

    if ($Payload.PSObject.Properties['FileIndex'] -and $null -ne $Payload.FileIndex) {
        return $Payload.FileIndex
    }

    $root = [string]$Payload.ExtractRoot
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "No existe el arbol extraido del payload de idioma '$($Payload.Locale)': '$root'."
    }

    $builders = @{}
    foreach ($file in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
        $key = [System.IO.Path]::GetFileName($file).ToLowerInvariant()
        if (-not $builders.ContainsKey($key)) {
            $builders[$key] = New-Object System.Collections.Generic.List[string]
        }
        [void]$builders[$key].Add($file)
    }

    $index = @{}
    foreach ($key in @($builders.Keys)) {
        $index[$key] = [string[]]@($builders[$key].ToArray() | Sort-Object)
    }

    $Payload | Add-Member -MemberType NoteProperty -Name FileIndex -Value $index -Force
    return $index
}

function Get-AIOLangPreferredPayloadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$Payload,
        [Parameter(Mandatory = $true)] [string]$FileName,
        [Parameter(Mandatory = $true)] [string]$Locale,
        [switch]$Server,
        [switch]$AzureStackHci
    )

    $index = Get-AIOLangPayloadFileIndex -Payload $Payload
    $key = $FileName.ToLowerInvariant()
    if (-not $index.ContainsKey($key)) { return $null }

    $localeLower = $Locale.ToLowerInvariant()
    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($index[$key])) {
        $normalized = ([string]$candidate).Replace('/', '\').ToLowerInvariant()
        $directory = [System.IO.Path]::GetDirectoryName($normalized)
        $score = 100

        if ($AzureStackHci -and $normalized -match ('\\setup\\sources\\' + [regex]::Escape($localeLower) + '\\asz\\')) { $score = 0 }
        elseif ($Server -and $normalized -match ('\\setup\\sources\\' + [regex]::Escape($localeLower) + '\\svr\\')) { $score = 0 }
        elseif (-not $Server -and -not $AzureStackHci -and $normalized -match ('\\setup\\sources\\' + [regex]::Escape($localeLower) + '\\cli\\')) { $score = 0 }
        elseif ($directory -and $directory.EndsWith("\setup\sources\$localeLower")) { $score = 5 }
        elseif ($normalized -match ('\\setup\\sources\\' + [regex]::Escape($localeLower) + '\\cli\\')) { $score = 8 }
        elseif ($normalized -match ('\\setup\\sources\\' + [regex]::Escape($localeLower) + '\\')) { $score = 15 }
        elseif ($normalized -match '\\setup\\sources\\') { $score = 30 }
        elseif ($normalized -match ('\\' + [regex]::Escape($localeLower) + '\\')) { $score = 50 }

        [void]$ranked.Add([pscustomobject]@{ Score = $score; Path = [string]$candidate })
    }

    $selected = @($ranked.ToArray() | Sort-Object Score, Path | Select-Object -First 1)
    if ($selected.Count -eq 0) { return $null }
    return [string]$selected[0].Path
}

function Get-AIOLangLangIniLocalesFromPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $locales = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [string[]]@() }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ($line -match '^\s*([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)\s*=') {
            $locale = Normalize-AIOLangLocale -Locale $matches[1]
            if ($locale -and $locale -notin $locales) { [void]$locales.Add($locale) }
        }
    }
    return [string[]]$locales.ToArray()
}

function Copy-AIOLangMediaLangIniToBootImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$MountPath
    )

    $source = Join-Path $MediaRoot 'sources\lang.ini'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "No existe '$source'; no se puede sincronizar el selector de idioma de Windows Setup."
    }
    $destinationDirectory = Join-Path $MountPath 'sources'
    Initialize-AIOLangDirectory -Path $destinationDirectory
    Copy-AIOLangFileWithRetry -Source $source -Destination (Join-Path $destinationDirectory 'lang.ini')
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Copiar lang.ini al indice Setup de boot.wim' -State 'Success' -Details @{ Source = $source }
}

function Get-AIOLangIntlLocalesFromMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $result = Invoke-AIOLangDism -Arguments @("/Image:$MountPath", '/Get-Intl') -Context $Context -Quiet
    $locales = New-Object System.Collections.Generic.List[string]
    # Invoke-AIOLangDism fuerza /English; aceptar exclusivamente las entradas
    # de idiomas instalados, nunca System locale, teclado o idioma de reserva.
    foreach ($line in @($result.Output)) {
        if ([string]$line -match '^\s*Installed language\(s\)\s*:\s*(\S+)\s*$') {
            $locale = Normalize-AIOLangLocale -Locale $matches[1]
            if ($locale -and $locale -notin $locales) { [void]$locales.Add($locale) }
        }
    }
    return [string[]]$locales.ToArray()
}

function Assert-AIOLangMountedWinPELocalization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$SetupImage,
        [switch]$AllowSetupResourcesOnly
    )

    $intlLocales = @(Get-AIOLangIntlLocalesFromMount -MountPath $MountPath -Context "$Context - Get-Intl")
    $missingIntl = @($Locales | Where-Object { $_ -notin $intlLocales })
    $resourcesOnly = [bool]($missingIntl.Count -gt 0 -and $SetupImage -and $AllowSetupResourcesOnly)
    if ($missingIntl.Count -gt 0 -and -not $resourcesOnly) {
        throw "${Context}: DISM /Get-Intl no reporta los idiomas $($missingIntl -join ', ')."
    }

    $langIniLocales = @()
    $resourceChecks = New-Object System.Collections.Generic.List[object]
    if ($SetupImage) {
        $langIni = Join-Path $MountPath 'sources\lang.ini'
        $langIniLocales = @(Get-AIOLangLangIniLocalesFromPath -Path $langIni)
        $missingLangIni = @($Locales | Where-Object { $_ -notin $langIniLocales })
        if ($missingLangIni.Count -gt 0) {
            throw "${Context}: sources\lang.ini interno no contiene $($missingLangIni -join ', ')."
        }

        $coreNames = [string[]]$script:AIOLangPolicy.SetupCoreMui
        foreach ($locale in $Locales) {
            $localeRoot = Join-Path $MountPath "sources\$locale"
            $muiFiles = if (Test-Path -LiteralPath $localeRoot -PathType Container) {
                @(Get-ChildItem -LiteralPath $localeRoot -File -Filter '*.mui' -ErrorAction SilentlyContinue)
            }
            else { @() }
            $coreFound = @($coreNames | Where-Object { Test-Path -LiteralPath (Join-Path $localeRoot $_) -PathType Leaf })
            if ($muiFiles.Count -eq 0 -or $coreFound.Count -eq 0) {
                throw "${Context}: faltan recursos MUI esenciales de Windows Setup para $locale en '$localeRoot'."
            }
            [void]$resourceChecks.Add([pscustomobject]@{
                Locale = $locale
                MuiCount = $muiFiles.Count
                CoreFiles = [string[]]$coreFound
            })
        }
    }

    $mode = if ($resourcesOnly) { 'SetupResourcesOnly' } else { 'FullWinPE' }
    $verification = [pscustomobject]@{
        Context = $Context
        Mode = $mode
        SetupImage = [bool]$SetupImage
        IntlLocales = [string[]]$intlLocales
        MissingIntlLocales = [string[]]$missingIntl
        LangIniLocales = [string[]]$langIniLocales
        ResourceChecks = [object[]]$resourceChecks.ToArray()
        Complete = $true
    }
    $state = if ($resourcesOnly) { 'VerifiedSetupResourcesOnly' } else { 'Verified' }
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State $state -Details $verification
    if ($resourcesOnly) {
        Write-AIOLangLog -Level WARN -Message "${Context}: selector de Setup habilitado por lang.ini/MUI; WinPE no contiene todos los paquetes de idioma compatibles."
    }
    return $verification
}

function Get-AIOLangSetupBootImageIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object[]]$Images)

    $normalized = @($Images | Where-Object { $null -ne $_ } | Sort-Object ImageIndex)
    if ($normalized.Count -eq 0) { return 0 }

    $named = @($normalized | Where-Object {
        ([string]$_.ImageName -match '(?i)\bsetup\b') -or
        ([string]$_.ImageDescription -match '(?i)\bsetup\b')
    } | Select-Object -First 1)
    if ($named.Count -gt 0) { return [int]$named[0].ImageIndex }

    # Los medios cliente de Microsoft usan normalmente el indice 2 para Windows Setup.
    # Se conserva como fallback solo cuando los metadatos no identifican el rol.
    $indexTwo = @($normalized | Where-Object { [int]$_.ImageIndex -eq 2 } | Select-Object -First 1)
    if ($indexTwo.Count -gt 0) { return 2 }

    return [int](@($normalized | Sort-Object ImageIndex -Descending | Select-Object -First 1)[0].ImageIndex)
}

function Get-AIOLangMountedBootImageRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object]$Image,
        [Parameter(Mandatory = $true)] [int]$FallbackSetupIndex
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $nameText = ('{0} {1}' -f [string]$Image.ImageName, [string]$Image.ImageDescription)
    if ($nameText -match '(?i)\bsetup\b') { [void]$reasons.Add('MetadataSetup') }

    $packagesRoot = Join-Path $MountPath 'Windows\Servicing\Packages'
    if (Test-Path -LiteralPath $packagesRoot -PathType Container) {
        foreach ($mum in [System.IO.Directory]::EnumerateFiles($packagesRoot, '*.mum', [System.IO.SearchOption]::TopDirectoryOnly)) {
            $name = [System.IO.Path]::GetFileName($mum)
            # Incluye WinPE-Setup-Package, WinPE-Setup-Client-Package,
            # WinPE-Setup-Server-Package y WinPE-Setup-ASZ-Package.
            if ($name -match '(?i)WinPE-Setup(?:-[A-Za-z0-9]+)*-Package') {
                [void]$reasons.Add('WinPESetupPackage')
                break
            }
        }
    }

    if (Test-Path -LiteralPath (Join-Path $MountPath 'sources\setup.exe') -PathType Leaf) {
        [void]$reasons.Add('SourcesSetupExe')
    }

    $winpeshl = Join-Path $MountPath 'Windows\System32\winpeshl.ini'
    if (Test-Path -LiteralPath $winpeshl -PathType Leaf) {
        try {
            $winpeshlText = Get-Content -LiteralPath $winpeshl -Raw -ErrorAction Stop
            if ($winpeshlText -match '(?i)(?:\\|/)sources(?:\\|/)setup\.exe|\bsetup\.exe\b') {
                [void]$reasons.Add('WinPEShellSetup')
            }
        }
        catch {
            Write-AIOLangLog -Level WARN -Message "No se pudo leer '$winpeshl' para identificar el rol de boot.wim: $($_.Exception.Message)"
        }
    }

    if ($reasons.Count -eq 0 -and [int]$Image.ImageIndex -eq $FallbackSetupIndex) {
        [void]$reasons.Add('FallbackSetupIndex')
    }

    return [pscustomobject]@{
        IsSetup = [bool]($reasons.Count -gt 0)
        Reasons = [string[]]$reasons.ToArray()
        FallbackSetupIndex = $FallbackSetupIndex
    }
}

function Test-AIOLangBootWimLocalization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BootWim,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [object[]]$UpdateResults,
        [switch]$AllowSetupResourcesOnly
    )

    $images = @(Get-AIOLangBootImageMetadata -BootWim $BootWim)
    $fallbackSetupIndex = Get-AIOLangSetupBootImageIndex -Images $images
    $results = New-Object System.Collections.Generic.List[object]
    $updatesByIndex = @{}
    foreach ($update in @($UpdateResults | Where-Object { $null -ne $_ })) {
        $updatesByIndex[[int]$update.Index] = $update
    }
    $hasUpdatePlan = [bool]($updatesByIndex.Count -gt 0)

    foreach ($image in $images) {
        $index = [int]$image.ImageIndex
        $plannedUpdate = if ($updatesByIndex.ContainsKey($index)) { $updatesByIndex[$index] } else { $null }

        # La verificacion final debe reflejar el plan real. Los indices omitidos
        # deliberadamente no tienen que contener los idiomas nuevos.
        if ($hasUpdatePlan -and ($null -eq $plannedUpdate -or [string]$plannedUpdate.Mode -eq 'NotModified')) {
            [void]$results.Add([pscustomobject]@{
                Context = "Verificacion final boot.wim indice $index"
                Index = $index
                Mode = 'NotModified'
                SetupImage = [bool]($plannedUpdate -and $plannedUpdate.SetupImage)
                Complete = $true
            })
            Write-AIOLangLog -Level INFO -Message "Verificacion final boot.wim indice ${index}: omitida porque el indice no fue modificado."
            continue
        }

        Mount-AIOLangImage -ImagePath $BootWim -Index $index -MountPath $MountPath -ScratchPath $ScratchPath -Context "Verificar localizacion boot.wim indice $index" -ReadOnly
        $mounted = $true
        try {
            $role = Get-AIOLangMountedBootImageRole -MountPath $MountPath -Image $image -FallbackSetupIndex $fallbackSetupIndex
            $isSetup = [bool]$role.IsSetup

            if ($plannedUpdate -and [string]$plannedUpdate.Mode -eq 'FontSupportOnly') {
                $fontResult = Assert-AIOLangEastAsianFontSupport -MountPath $MountPath -ExpectedFontFiles @($plannedUpdate.EastAsianFontFiles) -Locales @($plannedUpdate.EastAsianLocales) -Context "Verificacion final fuentes EA boot.wim indice $index" -Mode 'FontSupportOnly'
                $fontResult | Add-Member -MemberType NoteProperty -Name Index -Value $index -Force
                [void]$results.Add($fontResult)
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Cerrar verificacion fuentes EA boot.wim indice $index")
                $mounted = $false
                continue
            }

            $allowResourcesOnlyForIndex = [bool](
                ($plannedUpdate -and [string]$plannedUpdate.Mode -eq 'SetupResourcesOnly') -or
                ($AllowSetupResourcesOnly -and $isSetup)
            )
            Write-AIOLangLog -Level INFO -Message ("boot.wim indice {0}: rol Setup={1}; deteccion={2}." -f $index, $isSetup, (@($role.Reasons) -join ','))

            $result = Assert-AIOLangMountedWinPELocalization -MountPath $MountPath -Locales $Locales -Context "Verificacion final boot.wim indice $index" -SetupImage:$isSetup -AllowSetupResourcesOnly:$allowResourcesOnlyForIndex
            if ($plannedUpdate -and [string]$plannedUpdate.Mode -eq 'SetupResourcesOnly') { $result | Add-Member -MemberType NoteProperty -Name Mode -Value 'SetupResourcesOnly' -Force }
            if ($plannedUpdate -and @($plannedUpdate.EastAsianFontFiles).Count -gt 0) {
                $fontVerification = Assert-AIOLangEastAsianFontSupport -MountPath $MountPath -ExpectedFontFiles @($plannedUpdate.EastAsianFontFiles) -Locales @($plannedUpdate.EastAsianLocales) -Context "Verificacion final fuentes EA boot.wim indice $index" -Mode ([string]$plannedUpdate.Mode)
                $result | Add-Member -MemberType NoteProperty -Name EastAsianFontVerification -Value $fontVerification -Force
            }
            $result | Add-Member -MemberType NoteProperty -Name Index -Value $index -Force
            [void]$results.Add($result)
            [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Cerrar verificacion boot.wim indice $index")
            $mounted = $false
        }
        finally {
            if ($mounted -and $MountPath -in $script:AIOLangMountedPaths) {
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Descartar verificacion boot.wim indice $index" -NoThrow)
            }
        }
    }
    return [object[]]$results.ToArray()
}

function Merge-AIOLangPayloadIntoBootImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Payloads,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [switch]$SetupImage,
        [switch]$Server,
        [switch]$AzureStackHci
    )

    if (-not $SetupImage) {
        return [pscustomobject]@{ Copied = 0; Locales = [string[]]@(); SetupImage = $false }
    }

    $bootMuiNames = [string[]]$script:AIOLangPolicy.SetupLocalizedFiles
    $rtfNames = [string[]]$script:AIOLangPolicy.SetupLocalizedRtf
    $coreNames = [string[]]$script:AIOLangPolicy.SetupCoreMui
    $copied = 0
    $processedLocales = New-Object System.Collections.Generic.List[string]

    foreach ($payload in @($Payloads | Where-Object { $_.Architecture -eq $Architecture -and $_.Locale -in $Locales })) {
        $localeDestination = Join-Path $MountPath ("sources\$($payload.Locale)")
        Initialize-AIOLangDirectory -Path $localeDestination
        $coreCopied = New-Object System.Collections.Generic.List[string]

        foreach ($name in $bootMuiNames) {
            $source = Get-AIOLangPreferredPayloadFile -Payload $payload -FileName $name -Locale $payload.Locale -Server:$Server -AzureStackHci:$AzureStackHci
            if (-not $source) { continue }
            $destination = Join-Path $localeDestination $name
            Copy-AIOLangFileWithRetry -Source $source -Destination $destination
            $copied++
            if ($name -in $coreNames) { [void]$coreCopied.Add($name) }
        }

        foreach ($name in $rtfNames) {
            $source = Get-AIOLangPreferredPayloadFile -Payload $payload -FileName $name -Locale $payload.Locale -Server:$Server -AzureStackHci:$AzureStackHci
            if (-not $source) { continue }
            Copy-AIOLangFileWithRetry -Source $source -Destination (Join-Path $localeDestination $name)
            $copied++
            if ($name -eq 'vofflps.rtf') {
                Copy-AIOLangFileWithRetry -Source $source -Destination (Join-Path $localeDestination 'privacy.rtf')
                $copied++
            }
        }

        if ($coreCopied.Count -eq 0) {
            throw "El paquete de idioma $($payload.Locale) no contiene recursos MUI esenciales de Setup compatibles con $Architecture."
        }
        if ($payload.Locale -notin $processedLocales) { [void]$processedLocales.Add($payload.Locale) }
    }

    $result = [pscustomobject]@{
        Copied = $copied
        Locales = [string[]]$processedLocales.ToArray()
        SetupImage = $true
    }
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Copiar recursos MUI de Setup a boot.wim' -State 'Success' -Details $result
    Write-AIOLangLog -Level INFO -Message "Recursos MUI de Setup integrados en boot.wim: $copied archivo(s), idiomas: $($processedLocales -join ', ')."
    return $result
}

function Sync-AIOLangBootFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [switch]$SetupImage
    )

    $mountedSources = Join-Path $MountPath 'sources'
    $mediaSources = Join-Path $MediaRoot 'sources'

    # Solo exportar los binarios de sources del indice Setup. El lanzador
    # setup.exe de la raiz de WinPE NO es el setup.exe de la raiz del medio.
    if ($SetupImage) {
        foreach ($name in @('setup.exe', 'setuphost.exe')) {
            $source = Join-Path $mountedSources $name
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                Copy-AIOLangFileWithRetry -Source $source -Destination (Join-Path $mediaSources $name)
            }
        }
    }

    # sources\<locale> y sources\lang.ini en el medio ya los puebla
    # Merge-AIOLangSetupPayload directamente desde el Language Pack completo
    # (arbol real de Setup, con dlmanifests/etwproviders/cli/svr/asz).
    # Copiar de vuelta el subconjunto de boot.wim (~39 MUI de WinPE) o su
    # lang.ini (regenerado solo con inventario de WinPE) pisaria ese
    # resultado completo. La sincronizacion es de un solo sentido: medio ->
    # boot.wim (Copy-AIOLangMediaLangIniToBootImage), nunca al reves.

    $mountedBootFonts = Join-Path $MountPath 'Windows\Boot\Fonts'
    if (Test-Path -LiteralPath $mountedBootFonts -PathType Container) {
        Copy-AIOLangTree -Source $mountedBootFonts -Destination (Join-Path $MediaRoot 'boot\fonts')
        Copy-AIOLangTree -Source $mountedBootFonts -Destination (Join-Path $MediaRoot 'efi\microsoft\boot\fonts')
    }

    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context "Sincronizar archivos de boot.wim indice $Index" -State 'Success' -Details @{ Locales = $Locales; SetupImage = [bool]$SetupImage }
}

function Update-AIOLangBootWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BootWim,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$Payloads,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$DefaultLocale,
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [switch]$Cleanup,
        [switch]$ResetBase
    )

    $images = @(Get-AIOLangBootImageMetadata -BootWim $BootWim)
    $fallbackSetupIndex = Get-AIOLangSetupBootImageIndex -Images $images
    $localizationPlan = Get-AIOLangWinPELocalizationMode -Inventory $Inventory -TargetImages $images -Locales $Locales
    $useFullWinPE = ([string]$localizationPlan.Mode -eq 'FullWinPE')
    Write-AIOLangLog -Level INFO -Message ("Modo de localizacion boot.wim: {0}; LP base faltantes={1}; FontSupport faltantes={2}." -f $localizationPlan.Mode, (@($localizationPlan.MissingBase) -join ','), (@($localizationPlan.MissingFontSupport) -join ','))
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($image in $images) {
        $index = [int]$image.ImageIndex
        $script:AIOLangCurrentPhase = "boot.wim indice $index"
        Mount-AIOLangImage -ImagePath $BootWim -Index $index -MountPath $MountPath -ScratchPath $ScratchPath -Context "Montar boot.wim indice $index/$($images.Count)"
        $committed = $false
        try {
            $packagesRoot = Join-Path $MountPath 'Windows\Servicing\Packages'
            $role = Get-AIOLangMountedBootImageRole -MountPath $MountPath -Image $image -FallbackSetupIndex $fallbackSetupIndex
            $isSetup = [bool]$role.IsSetup
            $setupMums = if (Test-Path -LiteralPath $packagesRoot -PathType Container) {
                @([System.IO.Directory]::EnumerateFiles($packagesRoot, '*.mum', [System.IO.SearchOption]::TopDirectoryOnly) | Where-Object {
                    [System.IO.Path]::GetFileName($_) -match '(?i)WinPE-Setup(?:-[A-Za-z0-9]+)*-Package'
                })
            }
            else { @() }
            $isServerSetup = @($setupMums | Where-Object { [System.IO.Path]::GetFileName($_) -match '(?i)WinPE-Setup-Server-Package' }).Count -gt 0
            $isAzureStackHci = @($setupMums | Where-Object { [System.IO.Path]::GetFileName($_) -match '(?i)WinPE-Setup-ASZ-Package' }).Count -gt 0
            Write-AIOLangLog -Level INFO -Message ("boot.wim indice {0}: rol Setup={1}; deteccion={2}; fallback={3}." -f $index, $isSetup, (@($role.Reasons) -join ','), $fallbackSetupIndex)

            # La localizacion WinPE completa exige el Language Pack base (lp.cab)
            # para todos los idiomas. Para idiomas de Asia oriental tambien se exige
            # el paquete FontSupport correspondiente; si falta cualquiera de esos
            # componentes, todo boot.wim entra en SetupResourcesOnly para evitar una
            # localizacion parcial e inconsistente.
            $packageList = New-Object System.Collections.Generic.List[object]
            if ($useFullWinPE) {
                foreach ($candidate in @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'WinPE')) {
                    if ($null -ne $candidate) { [void]$packageList.Add($candidate) }
                }
            }
            $packages = [object[]]$packageList.ToArray()
            $fullWinPE = [bool]$useFullWinPE
            $appliedWinPE = @()
            $eaFonts = [pscustomobject]@{ Applied = $false; FileCount = 0; Locales = [string[]]@(); SystemFontNames = [string[]]@() }
            if ($fullWinPE) {
                $appliedWinPE = @(Add-AIOLangFeaturePackages -MountPath $MountPath -Packages ([object[]]$packageList.ToArray()) -ContextPrefix "WinPE indice $index")
            }
            else {
                $eaFonts = Add-AIOLangEastAsianFontSupport -MountPath $MountPath -Payloads $Payloads -Architecture $image.Architecture -Locales $Locales -Context "Fuentes EA boot.wim indice $index"
            }

            if (-not $fullWinPE -and -not $isSetup -and -not $eaFonts.Applied) {
                Write-Host " [OMITIDO] boot.wim indice $index no es Setup; sin WinPE completo ni fuentes EA que aplicar." -ForegroundColor DarkYellow
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Cerrar boot.wim indice $index sin cambios")
                $committed = $true
                [void]$results.Add([pscustomobject]@{ Index = $index; Mode = 'NotModified'; SetupImage = $false; PackageCount = 0; EastAsianFontFiles = [string[]]@(); EastAsianLocales = [string[]]@(); Detection = [string[]]$role.Reasons })
                continue
            }
            elseif (-not $fullWinPE -and -not $isSetup -and $eaFonts.Applied) {
                Write-Host " [FUENTES EA] boot.wim indice $index recibira soporte tipografico para $(@($eaFonts.Locales) -join ', ')." -ForegroundColor Yellow
                $fontVerification = Assert-AIOLangEastAsianFontSupport -MountPath $MountPath -ExpectedFontFiles @($eaFonts.SystemFontNames) -Locales @($eaFonts.Locales) -Context "Verificar fuentes EA boot.wim indice $index" -Mode 'FontSupportOnly'
                Sync-AIOLangBootFiles -MountPath $MountPath -MediaRoot $MediaRoot -Index $index -Locales $Locales -SetupImage:$false
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Commit -Context "Guardar boot.wim indice $index")
                $committed = $true
                [void]$results.Add([pscustomobject]@{
                    Index = $index; Mode = 'FontSupportOnly'; SetupImage = $false; PackageCount = 0
                    EastAsianFontFiles = [string[]]$eaFonts.SystemFontNames; EastAsianLocales = [string[]]$eaFonts.Locales
                    Verification = $fontVerification; Detection = [string[]]$role.Reasons
                })
                continue
            }
            elseif (-not $fullWinPE) {
                Write-Host ' [MODO SetupResourcesOnly] Sin LP WinPE completo; se integraran lang.ini y recursos MUI de Setup.' -ForegroundColor Yellow
                if ($eaFonts.Applied) { Write-Host " [FUENTES EA] Se agregara soporte tipografico para $(@($eaFonts.Locales) -join ', ')." -ForegroundColor Yellow }
                Write-AIOLangLog -Level INFO -Message "boot.wim indice ${index}: SetupResourcesOnly sin localizacion WinPE completa."
            }

            if ($isSetup) {
                [void](Merge-AIOLangPayloadIntoBootImage -MountPath $MountPath -Payloads $Payloads -Architecture $image.Architecture -Locales $Locales -SetupImage -Server:$isServerSetup -AzureStackHci:$isAzureStackHci)
            }

            if ($fullWinPE) {
                if ($isSetup) {
                    # Set-SetupUILang se aplica sobre boot.wim, pero /Distribution
                    # apunta al medio real (MediaRoot), nunca a $MountPath; Gen-LangINI
                    # se omite aqui porque ya corrio una vez contra install.wim.
                    Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix "Configurar boot.wim indice $index" -DistributionPath $MediaRoot -SkipLangIni
                }
                else {
                    Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix "Configurar boot.wim indice $index"
                }
                if ($appliedWinPE.Count -gt 0) {
                    [void](Assert-AIOLangInstalledPackages -MountPath $MountPath -Packages $appliedWinPE -Context "Verificar paquetes WinPE indice $index")
                }
            }

            if ($isSetup) {
                # Se copia al final, ya con Set-SetupUILang aplicado sobre el
                # lang.ini maestro del medio (orden documentado por Microsoft:
                # Gen-LangINI -> Set-SetupUILang -> xcopy hacia boot.wim).
                Copy-AIOLangMediaLangIniToBootImage -MediaRoot $MediaRoot -MountPath $MountPath
            }

            $verification = Assert-AIOLangMountedWinPELocalization -MountPath $MountPath -Locales $Locales -Context "Verificar localizacion antes de commit boot.wim indice $index" -SetupImage:$isSetup -AllowSetupResourcesOnly:(-not $fullWinPE)
            if (-not $fullWinPE -and $isSetup) { $verification | Add-Member -MemberType NoteProperty -Name Mode -Value 'SetupResourcesOnly' -Force }
            if ($eaFonts.Applied) {
                $fontVerification = Assert-AIOLangEastAsianFontSupport -MountPath $MountPath -ExpectedFontFiles @($eaFonts.SystemFontNames) -Locales @($eaFonts.Locales) -Context "Verificar fuentes EA boot.wim indice $index" -Mode ([string]$verification.Mode)
                $verification | Add-Member -MemberType NoteProperty -Name EastAsianFontVerification -Value $fontVerification -Force
            }

            if ($Cleanup -and $fullWinPE) { Invoke-AIOLangComponentCleanup -MountPath $MountPath -Context "Limpiar boot.wim indice $index" -ResetBase:$ResetBase }
            Sync-AIOLangBootFiles -MountPath $MountPath -MediaRoot $MediaRoot -Index $index -Locales $Locales -SetupImage:$isSetup
            [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Commit -Context "Guardar boot.wim indice $index")
            $committed = $true
            [void]$results.Add([pscustomobject]@{
                Index = $index
                Mode = $verification.Mode
                SetupImage = [bool]$isSetup
                PackageCount = $packages.Count
                EastAsianFontFiles = [string[]]$eaFonts.SystemFontNames
                EastAsianLocales = [string[]]$eaFonts.Locales
                Verification = $verification
                Detection = [string[]]$role.Reasons
            })
        }
        finally {
            if (-not $committed -and $MountPath -in $script:AIOLangMountedPaths) {
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Descartar boot.wim indice $index por error" -NoThrow)
            }
        }
    }
    return [object[]]$results.ToArray()
}

function Get-AIOLangMediaVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$DefaultLocale,
        [int[]]$Indexes
    )

    $installImages = @(Get-AIOLangImageMetadata -ImagePath $InstallWim)
    $selectedImages = if ($Indexes -and $Indexes.Count -gt 0) {
        @($installImages | Where-Object { $_.ImageIndex -in $Indexes })
    }
    else { $installImages }

    if (@($selectedImages).Count -eq 0) { throw 'No se encontraron indices de install.wim para verificar.' }
    if ($Indexes -and @($Indexes | Where-Object { $_ -notin @($selectedImages.ImageIndex) }).Count -gt 0) {
        throw 'Faltan indices seleccionados en los metadatos de install.wim.'
    }
    $imageLanguageChecks = New-Object System.Collections.Generic.List[object]
    foreach ($image in $selectedImages) {
        $reportedLanguages = @($image.Languages | Where-Object { $_ } | ForEach-Object { Normalize-AIOLangLocale -Locale $_ } | Select-Object -Unique)
        $missing = @($Locales | Where-Object { $_ -notin $reportedLanguages })
        [void]$imageLanguageChecks.Add([pscustomobject]@{
            ImageIndex        = $image.ImageIndex
            ImageName         = $image.ImageName
            DefaultLanguage   = $image.DefaultLanguage
            ReportedLanguages = [string[]]$reportedLanguages
            MetadataAvailable = [bool]($reportedLanguages.Count -gt 0)
            MissingLanguages  = [string[]]$missing
            Complete          = [bool]($reportedLanguages.Count -gt 0 -and $missing.Count -eq 0)
        })
    }

    $bootWim = Join-Path $MediaRoot 'sources\boot.wim'
    $bootImages = if (Test-Path -LiteralPath $bootWim -PathType Leaf) { @(Get-AIOLangBootImageMetadata -BootWim $bootWim) } else { @() }
    $payloadChecks = New-Object System.Collections.Generic.List[object]
    foreach ($locale in $Locales) {
        $sourcesLocale = Join-Path $MediaRoot "sources\$locale"
        $sourceResources = if (Test-Path -LiteralPath $sourcesLocale -PathType Container) {
            @(Get-ChildItem -LiteralPath $sourcesLocale -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -in @('.mui','.rtf','.adml')
            })
        }
        else { @() }
        [void]$payloadChecks.Add([pscustomobject]@{
            Locale               = $locale
            SourcesFolder        = Test-Path -LiteralPath $sourcesLocale -PathType Container
            SourcesResourceCount = $sourceResources.Count
            SourcesPopulated     = [bool]($sourceResources.Count -gt 0)
            BootFolder           = Test-Path -LiteralPath (Join-Path $MediaRoot "boot\$locale") -PathType Container
        })
    }

    $langIniPath = Join-Path $MediaRoot 'sources\lang.ini'
    $langIniLocales = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $langIniPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $langIniPath -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)\s*=') {
                $normalized = Normalize-AIOLangLocale -Locale $matches[1]
                if ($normalized -and $normalized -notin $langIniLocales) { [void]$langIniLocales.Add($normalized) }
            }
        }
    }

    $missingLangIniLocales = @($Locales | Where-Object { $_ -notin $langIniLocales })

    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Verificar idiomas en metadatos de install.wim' -State $(if (@($imageLanguageChecks | Where-Object { -not $_.Complete }).Count -eq 0) { 'Success' } else { 'Failed' }) -Details @{ ImagesChecked = @($selectedImages).Count }
    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Verificar carpetas localizadas de sources y boot' -State 'Success' -Details @{ LocalesChecked = $Locales.Count }
    
    if (Test-Path -LiteralPath $langIniPath -PathType Leaf) {
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Verificar estructura y contenido de lang.ini' -State 'Success' -Details @{ LocalesEncontrados = $langIniLocales.Count }
    }

    return [pscustomobject]@{
        MediaRoot          = $MediaRoot
        InstallWim         = $InstallWim
        InstallWimHash     = Get-AIOLangFileHashSafe -Path $InstallWim
        InstallImages      = $installImages
        ImageLanguageChecks = [object[]]$imageLanguageChecks.ToArray()
        BootWim            = $(if (Test-Path -LiteralPath $bootWim) { $bootWim } else { $null })
        BootWimHash        = $(if (Test-Path -LiteralPath $bootWim) { Get-AIOLangFileHashSafe -Path $bootWim } else { $null })
        BootImages         = $bootImages
        LangIniPresent      = Test-Path -LiteralPath $langIniPath -PathType Leaf
        LangIniLocales      = [string[]]$langIniLocales.ToArray()
        MissingLangIniLocales = [string[]]$missingLangIniLocales
        DefaultLocale       = $DefaultLocale
        DefaultInLangIni    = [bool]($DefaultLocale -in $langIniLocales)
        PayloadChecks       = [object[]]$payloadChecks.ToArray()
    }
}

function Export-AIOLangReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Report
    )

    Initialize-AIOLangDirectory -Path $script:AIOLangReportsRoot
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonPath = Join-Path $script:AIOLangReportsRoot ("Idiomas_$stamp.json")
    $htmlPath = Join-Path $script:AIOLangReportsRoot ("Idiomas_$stamp.html")
    Write-AIOLangAtomicJson -Path $jsonPath -InputObject $Report -Depth 12

    $operationRows = foreach ($operation in @($Report.Operations)) {
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f
            [System.Net.WebUtility]::HtmlEncode([string]$operation.Timestamp),
            [System.Net.WebUtility]::HtmlEncode([string]$operation.Phase),
            [System.Net.WebUtility]::HtmlEncode([string]$operation.Context),
            [System.Net.WebUtility]::HtmlEncode([string]$operation.State)
    }
    $languages = [System.Net.WebUtility]::HtmlEncode((@($Report.Configuration.Locales) -join ', '))
    $indexes = [System.Net.WebUtility]::HtmlEncode((@($Report.Configuration.Indexes) -join ', '))
    $media = [System.Net.WebUtility]::HtmlEncode([string]$Report.Configuration.MediaRoot)
    $status = [System.Net.WebUtility]::HtmlEncode([string]$Report.Status)
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
code{background:#f0f0f0;padding:2px 5px;border-radius:4px}
</style>
</head>
<body><main>
<h1>AdminImagenOffline - Integracion de idiomas</h1>

<h2>Resumen</h2>
<table>
    <tbody>
        <tr><th>Estado</th><td><span class="$(if ($Report.Status -eq 'Success') {'ok'} else {'failed'})">$status</span></td></tr>
        <tr><th>Medio</th><td><code>$media</code></td></tr>
        <tr><th>Indices</th><td>$indexes</td></tr>
        <tr><th>Idiomas</th><td>$languages</td></tr>
        <tr><th>Predeterminado</th><td>$([System.Net.WebUtility]::HtmlEncode([string]$Report.Configuration.DefaultLocale))</td></tr>
        <tr><th>Inicio</th><td>$([System.Net.WebUtility]::HtmlEncode([string]$Report.Started))</td></tr>
        <tr><th>Fin</th><td>$([System.Net.WebUtility]::HtmlEncode([string]$Report.Finished))</td></tr>
    </tbody>
</table>

<h2>Operaciones</h2>
<table>
    <thead>
        <tr><th>Fecha</th><th>Fase</th><th>Contexto</th><th>Estado</th></tr>
    </thead>
    <tbody>
        $($operationRows -join "`n")
    </tbody>
</table>
</main></body>
</html>
"@
    $html | Set-Content -LiteralPath $htmlPath -Encoding utf8
    return [pscustomobject]@{ JsonPath = $jsonPath; HtmlPath = $htmlPath }
}

function New-AIOLangDiagnosticBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()] [psobject]$Configuration,
        [AllowNull()] [string]$BackupRoot
    )

    $diagnosticRoot = Join-Path $script:AIOLangReportsRoot ('Diagnostico_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Initialize-AIOLangDirectory -Path $diagnosticRoot -Empty
    $errorText = @"
Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Fase: $script:AIOLangCurrentPhase
Mensaje: $($ErrorRecord.Exception.Message)
Tipo: $($ErrorRecord.Exception.GetType().FullName)
Linea: $($ErrorRecord.InvocationInfo.ScriptLineNumber)
Codigo: $($ErrorRecord.InvocationInfo.Line)
Pila:
$($ErrorRecord.ScriptStackTrace)
"@
    $errorText | Set-Content -LiteralPath (Join-Path $diagnosticRoot 'Error.txt') -Encoding utf8
    if ($Configuration) { Write-AIOLangAtomicJson -Path (Join-Path $diagnosticRoot 'Configuracion.json') -InputObject $Configuration -Depth 10 }
    Write-AIOLangAtomicJson -Path (Join-Path $diagnosticRoot 'Operaciones.json') -InputObject ([object[]]@($script:AIOLangOperationLog)) -Depth 10
    if ($script:AIOLangDismTranscript -and (Test-Path -LiteralPath $script:AIOLangDismTranscript)) {
        Copy-Item -LiteralPath $script:AIOLangDismTranscript -Destination (Join-Path $diagnosticRoot 'DISM_Consola.log') -Force -ErrorAction SilentlyContinue
    }
    if ($script:AIOLangSessionRoot -and (Test-Path -LiteralPath $script:AIOLangSessionRoot -PathType Container)) {
        Get-ChildItem -LiteralPath $script:AIOLangSessionRoot -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Copy-Item -Destination $diagnosticRoot -Force -ErrorAction SilentlyContinue
    }
    if ($BackupRoot) {
        try {
            $backupContext = Resolve-AIOLangPreflightBackup -Path $BackupRoot
            Copy-Item -LiteralPath $backupContext.ManifestPath -Destination (Join-Path $diagnosticRoot 'Preflight_manifest.json') -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
    try {
        & $script:AIOLangDismPath '/English' '/Get-MountedImageInfo' *> (Join-Path $diagnosticRoot 'DISM_MountedImageInfo.txt')
    }
    catch {}

    $zipPath = $diagnosticRoot + '.zip'
    try {
        Compress-Archive -Path (Join-Path $diagnosticRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $diagnosticRoot -Recurse -Force -ErrorAction SilentlyContinue
        $script:AIOLangLastDiagnosticPath = $zipPath
        return $zipPath
    }
    catch {
        $script:AIOLangLastDiagnosticPath = $diagnosticRoot
        return $diagnosticRoot
    }
}

function Invoke-AIOLangMediaIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [int[]]$Indexes,
        [Parameter(Mandatory = $true)] [string[]]$Locales,
        [Parameter(Mandatory = $true)] [string]$DefaultLocale,
        [switch]$IntegrateFod,
        [switch]$UpdateWinRE,
        [switch]$UpdateBootWim,
        [switch]$Cleanup,
        [switch]$ResetBase,
        [switch]$ExportSingleIndex,
        [switch]$OptimizeWims
    )

    if ($script:AIOLangMountedPaths.Count -gt 0 -and -not (Clear-AIOLangMountedImages)) {
        throw "Hay montajes pendientes de una sesion anterior: $($script:AIOLangMountedPaths -join ', ')."
    }
    $started = Get-Date
    $script:AIOLangOperationLog = New-Object System.Collections.ArrayList
    $script:AIOLangMountedPaths = New-Object System.Collections.ArrayList
    $script:AIOLangLastDiagnosticPath = $null
    $script:AIOLangLastPersistentLogPath = $null
    if (-not $script:AIOLangLastTerminalState) { [void](Initialize-AIOLangTerminalState) }
    $script:AIOLangLastTerminalState.Status = 'Running'
    $script:AIOLangLastTerminalState.Phase = 'Inicializacion'
    $script:AIOLangLastTerminalState.MediaRoot = $MediaRoot
    $script:AIOLangCurrentPhase = 'Inicializacion'
    $sessionBase = if ($Script:Scratch_DIR -and (Test-Path -LiteralPath $Script:Scratch_DIR -PathType Container)) { $Script:Scratch_DIR } else { $env:TEMP }
    $script:AIOLangSessionRoot = Join-Path $sessionBase ('AIOL_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Initialize-AIOLangDirectory -Path $script:AIOLangSessionRoot -Empty
    $script:AIOLangDismTranscript = Join-Path $script:AIOLangSessionRoot 'DISM_Consola.log'

    $scratch = Join-Path $script:AIOLangSessionRoot 'Scratch'
    $payloadRoot = Join-Path $script:AIOLangSessionRoot 'Payloads'
    $mountInstall = Join-Path $script:AIOLangSessionRoot 'Mount_Install'
    $mountWinRE = Join-Path $script:AIOLangSessionRoot 'Mount_WinRE'
    $mountBoot = Join-Path $script:AIOLangSessionRoot 'Mount_Boot'
    $winreCacheRoot = Join-Path $script:AIOLangSessionRoot 'WinRE_Cache'
    $eastAsianFontCacheRoot = Join-Path $script:AIOLangSessionRoot 'EastAsianFonts'
    foreach ($path in @($scratch, $payloadRoot, $mountInstall, $mountWinRE, $mountBoot, $winreCacheRoot, $eastAsianFontCacheRoot)) {
        Initialize-AIOLangDirectory -Path $path
    }

    $selectedImages = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes } | Sort-Object ImageIndex)
    $configuration = [pscustomobject]@{
        MediaRoot       = $MediaRoot
        RepositoryRoot  = $RepositoryRoot
        PackageSources  = [string[]]@($Inventory | ForEach-Object { if ($_.PSObject.Properties['Source']) { $_.Source } else { 'Repositorio' } } | Select-Object -Unique)
        AdkDetected     = [bool]$(if ($script:AIOLangAdkInfo -and $script:AIOLangAdkInfo.PSObject.Properties['AdkInstalled']) { $script:AIOLangAdkInfo.AdkInstalled } elseif ($script:AIOLangAdkInfo) { $script:AIOLangAdkInfo.Detected } else { $false })
        AdkRoot         = $(if ($script:AIOLangAdkInfo) { $script:AIOLangAdkInfo.Root } else { $null })
        WinPERoot       = $(if ($script:AIOLangAdkInfo) { $script:AIOLangAdkInfo.WinPERoot } else { $null })
        DismPath        = $script:AIOLangDismPath
        DismSource      = $script:AIOLangDismSource
        DismVersion     = Get-AIOLangExecutableVersion -Path $script:AIOLangDismPath
        Indexes         = $Indexes
        Locales         = $Locales
        DefaultLocale   = $DefaultLocale
        IntegrateFod    = [bool]$IntegrateFod
        UpdateWinRE     = [bool]$UpdateWinRE
        UpdateBootWim   = [bool]$UpdateBootWim
        Cleanup         = [bool]$Cleanup
        ResetBase       = [bool]$ResetBase
        ExportSingle    = [bool]$ExportSingleIndex
        OptimizeWims    = [bool]$OptimizeWims
        ImageServicingEvidence = [object[]]@($selectedImages | Select-Object ImageIndex, Build, Architecture, ServicingBuilds, ServicingEvidence)
    }

    $backup = $null
    $reportPaths = $null
    $mediaMutationStarted = $false
    $installImage = Get-AIOLangInstallImagePath -MediaRoot $MediaRoot
    try {
        Assert-AIOLangNoMountedImages
        if (-not (Test-AIOLangMediaWritable -MediaRoot $MediaRoot)) { throw "El medio '$MediaRoot' no permite escritura." }

        # El respaldo debe existir antes de cualquier extraccion de payloads o
        # normalizacion de recursos. Aunque esas operaciones usan la sesion
        # temporal, este orden garantiza un punto de restauracion inequivoco.
        $script:AIOLangCurrentPhase = 'Preflight'
        [void](Assert-AIOLangPreflightDiskSpace -MediaRoot $MediaRoot -SessionRoot $script:AIOLangSessionRoot -Inventory $Inventory -SelectedImages $selectedImages -Locales $Locales)
        Write-Host "`n>> Creando respaldo obligatorio del medio" -ForegroundColor Cyan
        $backup = New-AIOLangPreflightBackup -MediaRoot $MediaRoot -Locales $Locales
        $script:AIOLangLastTerminalState.BackupRoot = $backup.Root
        [void](Test-AIOLangPreflightBackup -BackupRoot $backup.Root)

        $script:AIOLangCurrentPhase = 'Preparar paquetes'
        $languagePackages = New-Object System.Collections.Generic.List[object]
        foreach ($image in $selectedImages) {
            foreach ($package in Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'LanguagePack') {
                if ($package.FilePath -notin @($languagePackages | ForEach-Object { $_.FilePath })) { [void]$languagePackages.Add($package) }
            }
        }

        $bootWim = Join-Path $MediaRoot 'sources\boot.wim'
        $bootDescriptors = if (Test-Path -LiteralPath $bootWim -PathType Leaf) { @(Get-AIOLangBootImageMetadata -BootWim $bootWim) } else { @() }
        $setupDescriptor = if ($bootDescriptors.Count -gt 0) { @($bootDescriptors | Where-Object { $_.ImageName -match '(?i)setup' } | Sort-Object ImageIndex | Select-Object -First 1)[0] } else { $selectedImages[0] }
        if (-not $setupDescriptor -and $bootDescriptors.Count -gt 0) { $setupDescriptor = @($bootDescriptors | Sort-Object ImageIndex -Descending | Select-Object -First 1)[0] }
        $selectedProductFamilies = @($selectedImages | ForEach-Object { if ($_.PSObject.Properties['ProductFamily']) { $_.ProductFamily } else { Get-AIOLangImageProductFamily -Image $_ } } | Where-Object { $_ -and $_ -ne 'WinPE' } | Select-Object -Unique)
        $mediaProductFamily = if ($selectedProductFamilies.Count -eq 1) { [string]$selectedProductFamilies[0] } else { 'Unknown' }
        foreach ($locale in $Locales) {
            $setupPackage = Get-AIOLangBestPackage -Packages $Inventory -Locale $locale -Architecture $setupDescriptor.Architecture -Build $setupDescriptor.Build -Category 'LanguagePack' -ProductFamily $mediaProductFamily -ServicingBuilds (Get-AIOLangImageServicingBuilds -Image $setupDescriptor)
            if (-not $setupPackage) {
                throw "Falta el paquete $locale compatible con la arquitectura de Setup $($setupDescriptor.Architecture) / build $($setupDescriptor.Build)."
            }
            if ($setupPackage.FilePath -notin @($languagePackages | ForEach-Object { $_.FilePath })) { [void]$languagePackages.Add($setupPackage) }
        }
        $setupArchitecture = $setupDescriptor.Architecture
        $payloads = @(Initialize-AIOLangLanguagePayloads -LanguagePackages ([object[]]$languagePackages.ToArray()) -PayloadRoot $payloadRoot)

        if ([System.IO.Path]::GetExtension($installImage).ToLowerInvariant() -eq '.esd') {
            $mediaMutationStarted = $true
            $script:AIOLangCurrentPhase = 'Convertir install.esd'
            $installImage = Convert-AIOLangEsdToWim -EsdPath $installImage -ScratchPath $scratch
        }

        $server = @($selectedImages | Where-Object { $_.InstallationType -match '(?i)Server' -or $_.ImageName -match '(?i)Server' }).Count -gt 0
        $asz = @($selectedImages | Where-Object { $_.ImageName -match '(?i)AzureStackHCI' }).Count -gt 0
        $script:AIOLangCurrentPhase = 'Archivos de Setup'
        $setupPayloads = @($payloads | Where-Object { $_.Architecture -eq $setupArchitecture })
        if ($setupPayloads.Count -gt 0) { $mediaMutationStarted = $true }
        foreach ($payload in $setupPayloads) {
            Merge-AIOLangSetupPayload -Payload $payload -MediaRoot $MediaRoot -Server:$server -AzureStackHci:$asz
        }

        $mediaMutationStarted = $true
        $script:AIOLangCurrentPhase = 'install.wim'
        Update-AIOLangInstallWim -InstallWim $installImage -Images $Images -Indexes $Indexes -Inventory $Inventory -Payloads $payloads -Locales $Locales -DefaultLocale $DefaultLocale -MediaRoot $MediaRoot -MountPath $mountInstall -WinREMountPath $mountWinRE -ScratchPath $scratch -WinRECacheRoot $winreCacheRoot -EastAsianFontCacheRoot $eastAsianFontCacheRoot -IntegrateFod:$IntegrateFod -UpdateWinRE:$UpdateWinRE -Cleanup:$Cleanup -ResetBase:$ResetBase

        if ($ExportSingleIndex -and $Indexes.Count -eq 1) {
            $script:AIOLangCurrentPhase = 'Exportar edicion unica'
            Export-AIOLangSingleInstallIndex -InstallWim $installImage -Index $Indexes[0] -ScratchPath $scratch
        }
        elseif ($OptimizeWims) {
            $script:AIOLangCurrentPhase = 'Optimizar install.wim'
            Rebuild-AIOLangWim -WimPath $installImage -ScratchPath $scratch -Context 'Optimizar install.wim'
        }

        $bootUpdateResults = @()
        $bootLocalizationVerification = @()
        if ($UpdateBootWim -and (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
            $script:AIOLangCurrentPhase = 'boot.wim'
            $bootUpdateResults = @(Update-AIOLangBootWim -BootWim $bootWim -Inventory $Inventory -Payloads $payloads -Locales $Locales -DefaultLocale $DefaultLocale -MediaRoot $MediaRoot -MountPath $mountBoot -ScratchPath $scratch -Cleanup:$Cleanup -ResetBase:$ResetBase)
            $bootChanged = @($bootUpdateResults | Where-Object { $_.Mode -ne 'NotModified' }).Count -gt 0
            if ($OptimizeWims -and $bootChanged) {
                $script:AIOLangCurrentPhase = 'Optimizar boot.wim'
                Rebuild-AIOLangWim -WimPath $bootWim -ScratchPath $scratch -Context 'Optimizar boot.wim'
            }
            elseif ($OptimizeWims) {
                Write-AIOLangLog -Level INFO -Message 'Se omitio la reconstruccion de boot.wim porque ningun indice fue modificado.'
            }
            $setupResourcesOnly = @($bootUpdateResults | Where-Object { $_.Mode -eq 'SetupResourcesOnly' }).Count -gt 0
            $actualBootModes = [string[]]@($bootUpdateResults | Select-Object -ExpandProperty Mode -Unique)
            $configuration | Add-Member -MemberType NoteProperty -Name BootLocalizationMode -Value $(if ($actualBootModes.Count -gt 0) { $actualBootModes -join '+' } else { 'NotModified' }) -Force
            $script:AIOLangCurrentPhase = 'Verificar boot.wim final'
            $bootLocalizationVerification = @(Test-AIOLangBootWimLocalization -BootWim $bootWim -Locales $Locales -MountPath $mountBoot -ScratchPath $scratch -UpdateResults $bootUpdateResults -AllowSetupResourcesOnly:$setupResourcesOnly)
        }

        $script:AIOLangCurrentPhase = 'Verificacion'
        $verificationIndexes = if ($ExportSingleIndex -and $Indexes.Count -eq 1) { [int[]]@(1) } else { [int[]]$Indexes }
        $verification = Get-AIOLangMediaVerification -MediaRoot $MediaRoot -InstallWim $installImage -Locales $Locales -DefaultLocale $DefaultLocale -Indexes $verificationIndexes
        $missingPayload = @($verification.PayloadChecks | Where-Object { -not $_.SourcesFolder -or -not $_.SourcesPopulated })
        if ($missingPayload.Count -gt 0) {
            throw "Faltan recursos localizados de Setup para: $(@($missingPayload.Locale) -join ', ')."
        }
        if (-not $verification.LangIniPresent) { throw 'No se genero sources\lang.ini.' }
        if (@($verification.MissingLangIniLocales).Count -gt 0) {
            throw "sources\lang.ini no contiene: $(@($verification.MissingLangIniLocales) -join ', ')."
        }
        if (-not $verification.DefaultInLangIni) {
            throw "El idioma predeterminado '$DefaultLocale' no aparece en sources\lang.ini."
        }
        $failedLanguageChecks = @($verification.ImageLanguageChecks | Where-Object { -not $_.Complete })
        if ($failedLanguageChecks.Count -gt 0) {
            $details = @($failedLanguageChecks | ForEach-Object {
                "indice $($_.ImageIndex): $(@($_.MissingLanguages) -join ', ')"
            }) -join '; '
            throw "La verificacion de install.wim detecto idiomas ausentes en $details."
        }

		Write-Host "`n=======================================================" -ForegroundColor DarkCyan
        Write-Host '             RESUMEN FINAL DE VERIFICACION' -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor DarkCyan
        Write-Host " [OK] Estructura de install.wim e idiomas verificados" -ForegroundColor Green
        Write-Host " [OK] Recursos localizados de Setup generados correctamente" -ForegroundColor Green
        Write-Host " [OK] Archivo sources\lang.ini actualizado y validado" -ForegroundColor Green
        if ($UpdateWinRE) { Write-Host " [OK] winre.wim actualizado con nuevos componentes WinPE" -ForegroundColor Green }
        if ($UpdateBootWim) {
            $resourcesOnlyCount = @($bootLocalizationVerification | Where-Object { $_.Mode -eq 'SetupResourcesOnly' }).Count
            $fontOnlyCount = @($bootLocalizationVerification | Where-Object { $_.Mode -eq 'FontSupportOnly' }).Count
            if ($resourcesOnlyCount -gt 0) {
                Write-Host " [OK] Selector de idiomas de Windows Setup habilitado mediante lang.ini y recursos MUI" -ForegroundColor Green
                if ($fontOnlyCount -gt 0 -or @($Locales | Where-Object { Test-AIOLangEastAsianLocale -Locale $_ }).Count -gt 0) {
                    Write-Host " [OK] Soporte de fuentes de Asia oriental aplicado a boot.wim sin requerir WinPE Add-on" -ForegroundColor Green
                }
                Write-Host " [ADVERTENCIA] WinPE completo no contiene todos los paquetes de idioma; usa un Add-on compatible para traduccion total." -ForegroundColor Yellow
            }
            else {
                Write-Host " [OK] boot.wim multilingue verificado: paquetes WinPE, Get-Intl, lang.ini y recursos MUI de Setup" -ForegroundColor Green
            }
        }
        if ($ExportSingleIndex -and $Indexes.Count -eq 1) { Write-Host " [OK] install.wim exportado como edicion unica" -ForegroundColor Green }
        elseif ($OptimizeWims) { Write-Host " [OK] Imagenes WIM reconstruidas y optimizadas" -ForegroundColor Green }
        Write-Host ""
        Add-AIOLangOperation -Phase 'Finalizacion' -Context 'Sugerencia posterior' -State 'Info' -Details @{ Recommendation = 'Aplicar actualizaciones despues de integrar idiomas.' }

        $report = [pscustomobject]@{
            Status        = 'Success'
            Started       = $started.ToString('o')
            Finished      = (Get-Date).ToString('o')
            Configuration = $configuration
            BackupRoot    = $backup.Root
            Verification  = $verification
            BootUpdateResults = [object[]]$bootUpdateResults
            BootLocalizationVerification = [object[]]$bootLocalizationVerification
            Operations    = [object[]]@($script:AIOLangOperationLog)
        }
        $reportPaths = Export-AIOLangReport -Report $report
        Write-AIOLangLog -Level INFO -Message 'Integracion de idiomas completada y verificada.'
        Write-AIOLangLog -Level INFO -Message ("Optimizacion: HashCacheHits={0}; HashCacheMisses={1}; MetadataCacheHits={2}; RepositoryCacheHits={3}." -f $script:AIOLangOptimizationStats.HashCacheHits, $script:AIOLangOptimizationStats.HashCacheMisses, $script:AIOLangOptimizationStats.MetadataCacheHits, $script:AIOLangOptimizationStats.RepositoryCacheHits)
        Write-Host ' [SUGERENCIA] La integracion de idiomas termino correctamente.' -ForegroundColor Cyan
        Write-Host '              Ahora ejecuta el modulo de Actualizaciones para integrar las LCU, SafeOS, SetupDU y demas paquetes.' -ForegroundColor Cyan
        $script:AIOLangLastTerminalState.Status = 'Success'
        $script:AIOLangLastTerminalState.Phase = 'Finalizacion'
        $script:AIOLangLastTerminalState.Message = 'La integracion de idiomas termino correctamente.'
        $script:AIOLangLastTerminalState.MediaRoot = $MediaRoot
        $script:AIOLangLastTerminalState.BackupRoot = $backup.Root
        $script:AIOLangLastTerminalState.ReportJson = $reportPaths.JsonPath
        $script:AIOLangLastTerminalState.ReportHtml = $reportPaths.HtmlPath
        $script:AIOLangLastTerminalState.MediaMutationStarted = [bool]$mediaMutationStarted
        $script:AIOLangLastTerminalState.RestorationStatus = 'No requerida'
        $script:AIOLangLastTerminalState.CompletedTargets = [object[]]@($script:AIOLangOperationLog | Where-Object { $_.State -eq 'Success' } | Select-Object -ExpandProperty Context -Unique)
        return [pscustomobject]@{
            Success          = $true
            MediaRoot        = $MediaRoot
            InstallWim       = $installImage
            BackupRoot       = $backup.Root
            ReportJson       = $reportPaths.JsonPath
            ReportHtml       = $reportPaths.HtmlPath
            Verification     = $verification
            BootUpdateResults = [object[]]$bootUpdateResults
            BootLocalizationVerification = [object[]]$bootLocalizationVerification
        }
    }
    catch {
        $integrationError = $_
        $failedPhase = $script:AIOLangCurrentPhase
        $restorationStatus = 'No requerida'
        $mountsCleared = Clear-AIOLangMountedImages
        $diagnostic = $null
        try {
            $diagnostic = New-AIOLangDiagnosticBundle -ErrorRecord $integrationError -Configuration $configuration -BackupRoot $(if ($backup) { $backup.Root } else { $null })
        }
        catch {
            Write-AIOLangLog -Level WARN -Message "No se pudo generar el diagnostico automatico: $($_.Exception.Message)"
        }
        if ($backup -and $mediaMutationStarted -and -not $mountsCleared) {
            $restorationStatus = 'Pendiente: no se pudieron desmontar todas las imagenes'
            Write-AIOLangLog -Level WARN -Message "Restauracion aplazada. Se conserva el respaldo '$($backup.Root)' y la sesion '$script:AIOLangSessionRoot'."
        }
        elseif ($backup -and $mediaMutationStarted) {
            Write-Host "`nLa operacion fallo despues de iniciar cambios en el medio." -ForegroundColor Yellow
            if (Read-AIOLangYesNo -Prompt 'Restaurar automaticamente el medio al estado inicial' -Default $true) {
                try {
                    $script:AIOLangCurrentPhase = 'Recuperacion'
                    [void](Restore-AIOLangPreflightBackup -BackupRoot $backup.Root -MediaRoot $MediaRoot -Force)
                    Write-Host 'El medio fue restaurado y verificado correctamente.' -ForegroundColor Green
                    $restorationStatus = 'Restaurado y verificado'
                    Add-AIOLangOperation -Phase 'Recuperacion' -Context 'Restauracion automatica tras error' -State 'Success' -Details @{ BackupRoot = $backup.Root }
                }
                catch {
                    Write-Host "[ERROR] No se pudo completar la restauracion automatica: $($_.Exception.Message)" -ForegroundColor Red
                    $restorationStatus = "Fallo: $($_.Exception.Message)"
                    Add-AIOLangOperation -Phase 'Recuperacion' -Context 'Restauracion automatica tras error' -State 'Failed' -Details $_.Exception.Message
                }
            }
            else {
                $restorationStatus = 'No solicitada por el usuario'
            }
        }
        elseif ($backup) {
            Write-Host "`nLa operacion fallo antes de modificar el medio; no es necesario restaurarlo." -ForegroundColor Yellow
            Write-Host "El respaldo Preflight se conserva en: $($backup.Root)" -ForegroundColor DarkGray
            $restorationStatus = 'No requerida; el medio no fue modificado'
            Add-AIOLangOperation -Phase 'Recuperacion' -Context 'Restauracion no requerida' -State 'Skipped' -Details @{ BackupRoot = $backup.Root; Reason = 'Fallo anterior a la primera modificacion del medio.' }
        }

        $failureReport = [pscustomobject]@{
            Status        = 'Failed'
            Started       = $started.ToString('o')
            Finished      = (Get-Date).ToString('o')
            Configuration = $configuration
            BackupRoot    = $(if ($backup) { $backup.Root } else { $null })
            Error         = [pscustomobject]@{
                Message = $integrationError.Exception.Message
                Line    = $integrationError.InvocationInfo.ScriptLineNumber
                Code    = $integrationError.InvocationInfo.Line
                Phase   = $failedPhase
            }
            MediaMutationStarted = [bool]$mediaMutationStarted
            DiagnosticPath = $diagnostic
            Operations     = [object[]]@($script:AIOLangOperationLog)
        }
        try { $reportPaths = Export-AIOLangReport -Report $failureReport } catch { $reportPaths = $null }
        $script:AIOLangLastTerminalState.Status = 'Failed'
        $script:AIOLangLastTerminalState.Phase = $failedPhase
        $script:AIOLangLastTerminalState.Message = $integrationError.Exception.Message
        $script:AIOLangLastTerminalState.MediaRoot = $MediaRoot
        $script:AIOLangLastTerminalState.BackupRoot = $(if ($backup) { $backup.Root } else { $null })
        $script:AIOLangLastTerminalState.DiagnosticPath = $diagnostic
        $script:AIOLangLastTerminalState.ReportJson = $(if ($reportPaths) { $reportPaths.JsonPath } else { $null })
        $script:AIOLangLastTerminalState.ReportHtml = $(if ($reportPaths) { $reportPaths.HtmlPath } else { $null })
        $script:AIOLangLastTerminalState.MediaMutationStarted = [bool]$mediaMutationStarted
        $script:AIOLangLastTerminalState.RestorationStatus = $restorationStatus
        $script:AIOLangLastTerminalState.CompletedTargets = [object[]]@($script:AIOLangOperationLog | Where-Object { $_.State -eq 'Success' } | Select-Object -ExpandProperty Context -Unique)
        $script:AIOLangLastTerminalState.ErrorLine = $integrationError.InvocationInfo.ScriptLineNumber
        $script:AIOLangLastTerminalState.ErrorCode = $(if ($integrationError.InvocationInfo.Line) { $integrationError.InvocationInfo.Line.Trim() } else { $null })
        throw $integrationError
    }
    finally {
        $mountsCleared = Clear-AIOLangMountedImages
        if ($script:AIOLangSessionRoot -and (Test-Path -LiteralPath $script:AIOLangSessionRoot)) {
            if ($script:AIOLangDismTranscript -and (Test-Path -LiteralPath $script:AIOLangDismTranscript)) {
                Initialize-AIOLangDirectory -Path $script:AIOLangReportsRoot
                $transcriptCopy = Join-Path $script:AIOLangReportsRoot ("DISM_Idiomas_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                Copy-Item -LiteralPath $script:AIOLangDismTranscript -Destination $transcriptCopy -Force -ErrorAction SilentlyContinue
                $script:AIOLangLastPersistentLogPath = $transcriptCopy
                if ($script:AIOLangLastTerminalState) { $script:AIOLangLastTerminalState.LogPath = $transcriptCopy }
            }
            if ($mountsCleared) {
                Remove-Item -LiteralPath $script:AIOLangSessionRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Host "Se conserva la sesion para recuperar los montajes pendientes: $script:AIOLangSessionRoot" -ForegroundColor Yellow
                Write-AIOLangLog -Level WARN -Message "Limpieza aplazada: $script:AIOLangSessionRoot"
            }
        }
        if ($mountsCleared) {
            $script:AIOLangSessionRoot = $null
            $script:AIOLangDismTranscript = $null
        }
        $script:AIOLangCurrentPhase = 'Inicializacion'
    }
}

function Start-AIOLangIntegrationWizard {
    [CmdletBinding()]
    param()

    $scanRoot = $null
    [void](Initialize-AIOLangTerminalState)
    try {
        if (-not (Test-AIOLangAdministrator)) { throw 'Ejecuta AdminImagenOffline como Administrador.' }
        $adkInfo = Initialize-AIOLangServicingEnvironment
        Assert-AIOLangNoMountedImages

        $mediaRoot = Select-AIOLangFolder -Title 'Selecciona la carpeta raiz del medio de Windows extraido'
        if (-not $mediaRoot) { return }
        $mediaRoot = (Resolve-Path -LiteralPath $mediaRoot -ErrorAction Stop).Path
        $script:AIOLangLastTerminalState.MediaRoot = $mediaRoot
        if (-not (Test-Path -LiteralPath (Join-Path $mediaRoot 'sources') -PathType Container)) { throw 'La carpeta seleccionada no contiene el directorio sources.' }
        $installImage = Get-AIOLangInstallImagePath -MediaRoot $mediaRoot
        $bootWim = Join-Path $mediaRoot 'sources\boot.wim'

        $defaultRepository = Join-Path $script:AIOLangApplicationRoot 'Lenguajes'
        $repositoryRoot = $null
        if (Test-Path -LiteralPath $defaultRepository -PathType Container) {
            Write-Host "`nRepositorio detectado: $defaultRepository" -ForegroundColor Cyan
            if (Read-AIOLangYesNo -Prompt 'Usar este repositorio' -Default $true) { $repositoryRoot = $defaultRepository }
        }
        if (-not $repositoryRoot) {
            $repositoryRoot = Select-AIOLangFolder -Title 'Selecciona el repositorio de paquetes de idioma'
            if (-not $repositoryRoot) { return }
        }
        $repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot -ErrorAction Stop).Path

        $scanBase = if ($Script:Scratch_DIR -and (Test-Path -LiteralPath $Script:Scratch_DIR -PathType Container)) { $Script:Scratch_DIR } else { $env:TEMP }
        $scanRoot = Join-Path $scanBase ('AIOL_SCAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOLangDirectory -Path $scanRoot -Empty
        $script:AIOLangPackageMetadataCache = @{}
        $script:AIOLangImageServicingCache = @{}

        # Se obtiene primero la metadata de las imagenes. Asi el ADK se limita
        # desde el principio a la arquitectura, idiomas y builds realmente
        # requeridos, en lugar de inspeccionar miles de CAB de todo el Add-on.
        $images = @(Get-AIOLangImageMetadata -ImagePath $installImage)
        $bootImages = if (Test-Path -LiteralPath $bootWim -PathType Leaf) { @(Get-AIOLangBootImageMetadata -BootWim $bootWim) } else { @() }
        $targetImagesForAdk = @($images) + @($bootImages)
        $targetArchitecturesForAdk = [string[]]@($targetImagesForAdk | ForEach-Object {
            Convert-AIOLangArchitectureName -Architecture $_.Architecture
        } | Where-Object { $_ -and $_ -ne 'Unknown' } | Select-Object -Unique)
        $targetBuildsForAdk = [int[]]@($targetImagesForAdk | ForEach-Object { $_.Build; Get-AIOLangImageServicingBuilds -Image $_ } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)

        $script:AIOLangAdkScanSummary = $null
        $adkInventoryError = $null
        $inventoryBuffer = New-Object System.Collections.Generic.List[object]
        $repositoryInventory = @(Get-AIOLangRepositoryInventory -RepositoryRoot $repositoryRoot -ScratchRoot (Join-Path $scanRoot 'Repositorio') -SourceName 'Repositorio')
        foreach ($item in $repositoryInventory) { [void]$inventoryBuffer.Add($item) }

        $adkInventory = @()
        if ($adkInfo.WinPERoot) {
            $repositoryLocales = [string[]]@($repositoryInventory | Where-Object {
                $_.Category -eq 'LanguagePack' -and $_.Locale -and
                ($targetArchitecturesForAdk.Count -eq 0 -or $_.Architecture -in $targetArchitecturesForAdk)
            } | Select-Object -ExpandProperty Locale -Unique)
            try {
                $adkInventoryParameters = @{
                    RepositoryRoot    = $adkInfo.WinPERoot
                    ScratchRoot       = (Join-Path $scanRoot 'ADK')
                    SourceName        = 'ADK WinPE'
                    LocalizedWinPEOnly = $true
                    LocaleFilter      = $repositoryLocales
                    ArchitectureFilter = $targetArchitecturesForAdk
                    TargetBuilds      = $targetBuildsForAdk
                    FastAdkProbe      = $true
                    AllowEmpty        = $true
                }
                $adkInventory = @(Get-AIOLangRepositoryInventory @adkInventoryParameters)
                foreach ($item in $adkInventory) { [void]$inventoryBuffer.Add($item) }
            }
            catch {
                $adkInventoryError = $_.Exception.Message
                Write-AIOLangLog -Level WARN -Message "No se pudo analizar el complemento WinPE detectado: $adkInventoryError"
                Write-Host "[ADVERTENCIA] Se detecto WinPE, pero no pudo analizarse: $adkInventoryError" -ForegroundColor Yellow
            }
        }

        $inventory = @(Merge-AIOLangLogicalInventory -Inventory ([object[]]$inventoryBuffer.ToArray()))

        Clear-Host
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host '                    RESUMEN PREVIO                     ' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host " Medio origen           : $mediaRoot" -ForegroundColor White
        Write-Host " Repositorio            : $repositoryRoot" -ForegroundColor White
        Write-Host " Imagen                 : $([System.IO.Path]::GetFileName($installImage))" -ForegroundColor White
        Show-AIOLangAdkStatus -AdkInfo $adkInfo -MediaArchitectures $targetArchitecturesForAdk
        if ($adkInfo.WinPERoot) {
            $adkWinPeBuilds = @($adkInventory | Where-Object { $_.Build } | Select-Object -ExpandProperty Build -Unique | Sort-Object)
            $adkBuildText = if ($adkWinPeBuilds.Count -gt 0) { $adkWinPeBuilds -join ", " } else { 'N/D' }
            $adkLocales = [string[]]@($adkInventory | Where-Object { $_.Locale } | Select-Object -ExpandProperty Locale -Unique)
            $adkCompatibleInstall = if (@($adkInventory).Count -gt 0 -and $adkLocales.Count -gt 0) {
                @(Get-AIOLangCompatiblePackagesForTargets -Inventory $adkInventory -TargetImages $images -Locales $adkLocales -Category 'WinPE')
            }
            else {
                @()
            }
            $scanSummary = $script:AIOLangAdkScanSummary
            if ($adkInventoryError) {
                Write-Host " Inventario WinPE       : No se pudo completar: $adkInventoryError" -ForegroundColor Yellow
            }
            elseif ($scanSummary -and $scanSummary.FullScanSkipped) {
                Write-Host " Inventario WinPE       : Parcial | $($scanSummary.AnalyzedCount) sondeado(s) de $($scanSummary.CandidateCount) | Build(s): $adkBuildText" -ForegroundColor White
                Write-Host '                         Escaneo completo omitido: la familia WinPE no es compatible con el medio.' -ForegroundColor DarkGray
            }
            else {
                $analyzedCount = if ($scanSummary) { $scanSummary.AnalyzedCount } else { @($adkInventory).Count }
                Write-Host " Inventario WinPE       : $analyzedCount analizados para las arquitecturas e idiomas del medio | Build(s): $adkBuildText" -ForegroundColor White
            }
            if (-not $adkInventoryError) {
                Write-Host " Compatibilidad WinPE   : $(@($adkCompatibleInstall).Count) coinciden con arquitectura/build de install.wim" -ForegroundColor White
            }
        }
        Write-Host ''
        Show-AIOLangInventorySummary -Inventory $inventory -TargetImages $images

        $indexes = Select-AIOLangInstallIndexes -Images $images
        Assert-AIOLangEditionLanguageSupport -Images $images -Indexes $indexes
        Assert-AIOLangProductFamilyConsistency -Images $images -Indexes $indexes
        $selectedImagesForChoice = @($images | Where-Object { [int]$_.ImageIndex -in $indexes })
        $locales = Select-AIOLangLocales -Inventory $inventory -TargetImages $selectedImagesForChoice
        $coverage = Assert-AIOLangPackageCoverage -Inventory $inventory -Images $images -Indexes $indexes -Locales $locales
        $defaultLocale = Select-AIOLangDefaultLocale -SelectedImages $coverage.Images -SelectedLocales $locales

        # Microsoft: "Use languages from the Languages and Optional Features
        # ISO, not from the Windows 10 ADK, to localize WinRE." El ADK solo es
        # fuente valida para boot.wim/Setup; winre.wim solo debe tomar CAB
        # WinPE del repositorio del usuario (LOF ISO).
        $winReWinPEInventory = @($inventory | Where-Object {
            $pkgSource = if ($_.PSObject.Properties['Source']) { $_.Source } else { 'Repositorio' }
            $_.Category -ne 'WinPE' -or ($pkgSource -ne 'ADK WinPE')
        })

        $relevantFod = @()
        $winRePackages = @()
        foreach ($image in $coverage.Images) {
            $relevantFod += @(Get-AIOLangPackagesForImage -Inventory $inventory -Image $image -Locales $locales -Category 'LanguageFOD')
            $winRePackages += @(Get-AIOLangPackagesForImage -Inventory $winReWinPEInventory -Image $image -Locales $locales -Category 'WinPE')
        }
        $relevantFod = @($relevantFod | Sort-Object FilePath -Unique)
        $winRePackages = @($winRePackages | Sort-Object FilePath -Unique)

        $bootPackages = @()
        foreach ($bootImage in $bootImages) {
            $bootPackages += @(Get-AIOLangPackagesForImage -Inventory $inventory -Image $bootImage -Locales $locales -Category 'WinPE')
        }
        $bootPackages = @($bootPackages | Sort-Object FilePath -Unique)
        $bootLocalizationPlan = if ($bootImages.Count -gt 0) { Get-AIOLangWinPELocalizationMode -Inventory $inventory -TargetImages $bootImages -Locales $locales } else { [pscustomobject]@{ Mode = 'NotAvailable'; Complete = $false; MissingBase = [string[]]@(); MissingFontSupport = [string[]]@() } }
        $relevantWinPE = @($winRePackages + $bootPackages | Sort-Object FilePath -Unique)

        $winPeCompatibility = @()
        $winPeCompatibility += @(Get-AIOLangWinPECompatibilityReport -Inventory $inventory -TargetImages $coverage.Images -Locales $locales -Context 'winre.wim' -ExcludeAdkSource)
        if ($bootImages.Count -gt 0) {
            $winPeCompatibility += @(Get-AIOLangWinPECompatibilityReport -Inventory $inventory -TargetImages $bootImages -Locales $locales -Context 'boot.wim')
        }

        $winPeMismatchReports = @($winPeCompatibility | Where-Object {
            $null -ne $_ -and $_.PSObject.Properties['CompatibleCount'] -and [int]$_.CompatibleCount -eq 0
        })

        Write-Host "`n Configuracion:" -ForegroundColor Yellow
        if ($winPeMismatchReports.Count -gt 0) {
            Show-AIOLangWinPECompatibilityDiagnostics -Reports $winPeMismatchReports -RepositoryRoot $repositoryRoot -AdkInfo $adkInfo
        }

        $integrateFod = $false
        if ($relevantFod.Count -gt 0) {
            $integrateFod = Read-AIOLangYesNo -Prompt "Integrar Features on Demand detectadas ($($relevantFod.Count))" -Default $true
        }
        else { Write-Host ' [OMITIDO] No se detectaron Features on Demand compatibles.' -ForegroundColor DarkGray }

        $updateWinRE = $false
        if ($winRePackages.Count -gt 0) {
            $updateWinRE = Read-AIOLangYesNo -Prompt "Actualizar winre.wim con componentes WinPE ($($winRePackages.Count))" -Default $true
        }
        else {
            Write-Host ' [OMITIDO] No hay paquetes WinPE compatibles para winre.wim.' -ForegroundColor DarkGray
        }

        $updateBootWim = $false
        if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
            Write-Host ' [OMITIDO] El medio no contiene sources\boot.wim.' -ForegroundColor DarkGray
        }
        elseif ([string]$bootLocalizationPlan.Mode -eq 'FullWinPE') {
            $updateBootWim = Read-AIOLangYesNo -Prompt "Actualizar boot.wim con localizacion WinPE completa ($($bootPackages.Count) paquetes compatibles)" -Default $true
        }
        else {
            Write-Host ' [MODO SetupResourcesOnly] No hay un juego WinPE completo para todos los idiomas seleccionados.' -ForegroundColor Yellow
            Write-Host '   - install.wim: localizacion completa mediante LP/FOD' -ForegroundColor DarkYellow
            Write-Host '   - boot.wim Setup: lang.ini + recursos MUI de Setup' -ForegroundColor DarkYellow
            if (@($locales | Where-Object { Test-AIOLangEastAsianLocale -Locale $_ }).Count -gt 0) { Write-Host '   - boot.wim indices 1/2: soporte de fuentes de Asia oriental desde install.wim' -ForegroundColor DarkYellow }
            Write-Host '   - winre.wim: solo se modifica si existen CAB WinPE compatibles del repositorio' -ForegroundColor DarkYellow
            if (@($bootLocalizationPlan.MissingBase).Count -gt 0) { Write-Host "   LP WinPE faltante: $(@($bootLocalizationPlan.MissingBase) -join ', ')" -ForegroundColor DarkGray }
            if (@($bootLocalizationPlan.MissingFontSupport).Count -gt 0) { Write-Host "   FontSupport faltante: $(@($bootLocalizationPlan.MissingFontSupport) -join ', ')" -ForegroundColor DarkGray }
            $updateBootWim = Read-AIOLangYesNo -Prompt 'Habilitar los idiomas en Windows Setup mediante SetupResourcesOnly' -Default $true
        }

        if ($relevantWinPE.Count -eq 0 -and $adkInfo.WinPERoot -and $winPeMismatchReports.Count -eq 0) {
            # Ruta de respaldo: no depende del objeto de diagnostico. Esto evita mensajes
            # vacios si una fuente no devuelve filas de compatibilidad.
            $requiredTargetImages = @($coverage.Images) + @($bootImages)
            $targetArchitectures = @($requiredTargetImages | Where-Object { $null -ne $_ } | ForEach-Object {
                Convert-AIOLangArchitectureName -Architecture $_.Architecture
            } | Where-Object { $_ } | Select-Object -Unique)
            $referenceBuilds = @($inventory | Where-Object {
                $_.Supported -and $_.Locale -in $locales -and
                $_.Category -in @('LanguagePack', 'LanguageFOD') -and
                ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures) -and
                $null -ne $_.Build
            } | Select-Object -ExpandProperty Build -Unique | Sort-Object)
            $requiredFamilies = @(Get-AIOLangBuildFamiliesFromImages -Images $requiredTargetImages -ReferenceBuilds $referenceBuilds)
            $availableWinPePackages = @($inventory | Where-Object {
                $_.Category -eq 'WinPE' -and $_.Supported -and $_.Locale -in $locales -and
                ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures)
            })
            $availableFamilies = @(Get-AIOLangBuildFamiliesFromPackages -Packages $availableWinPePackages)

            $requiredText = if ($requiredFamilies.Count -gt 0) { $requiredFamilies -join ', ' } else { 'N/D' }
            $availableText = if ($availableFamilies.Count -gt 0) { $availableFamilies -join ', ' } else { 'N/D' }
            Write-Host " [ADVERTENCIA] WinPE detectado, pero no aplicable. Requerido: familia $requiredText; disponible: familia $availableText." -ForegroundColor Yellow
        }

        $cleanup = Read-AIOLangYesNo -Prompt 'Ejecutar StartComponentCleanup' -Default $true
        $resetBase = $false
        if ($cleanup) { $resetBase = Read-AIOLangYesNo -Prompt 'Usar ResetBase (impide desinstalar componentes)' -Default $false }
        $optimizeWims = Read-AIOLangYesNo -Prompt 'Reconstruir y optimizar los WIM al terminar' -Default $true
        $exportSingle = $false
        if ($indexes.Count -eq 1) { $exportSingle = Read-AIOLangYesNo -Prompt 'Exportar solo el indice seleccionado en install.wim' -Default $true }

        Write-Host "`n=======================================================" -ForegroundColor DarkCyan
        Write-Host ' PLAN DE EJECUCION' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor DarkCyan
        Write-Host " Indices install.wim : $($indexes -join ', ')" -ForegroundColor White
        Write-Host " Idiomas              : $($locales -join ', ')" -ForegroundColor White
        Write-Host " Predeterminado       : $defaultLocale" -ForegroundColor White
        Write-Host " Features on Demand   : $integrateFod ($($relevantFod.Count) detectadas)" -ForegroundColor White
        $adkInstalledForPlan = if ($adkInfo.PSObject.Properties['AdkInstalled']) { [bool]$adkInfo.AdkInstalled } else { [bool]$adkInfo.Detected }
        Write-Host " ADK instalado        : $adkInstalledForPlan" -ForegroundColor White
        $compatibleWinPeCount = @($relevantWinPE).Count
        Write-Host " Fuente WinPE         : $([bool]$adkInfo.WinPERoot) ($(@($adkInventory).Count) analizadas | $compatibleWinPeCount compatibles)" -ForegroundColor White
        Write-Host " winre.wim            : $updateWinRE ($($winRePackages.Count) compatibles)" -ForegroundColor White
        Write-Host " boot.wim             : $updateBootWim ($($bootPackages.Count) compatibles)" -ForegroundColor White
        Write-Host " Modo boot.wim        : $($bootLocalizationPlan.Mode)" -ForegroundColor White
        Write-Host " DISM                  : $($adkInfo.ActiveDismSource) $($adkInfo.ActiveDismVersion)" -ForegroundColor White
        Write-Host " Limpieza             : $cleanup | ResetBase: $resetBase" -ForegroundColor White
        Write-Host " Optimizar WIM        : $optimizeWims" -ForegroundColor White
        Write-Host " Salida edicion unica : $exportSingle" -ForegroundColor White
        Write-Host ' Respaldo previo      : Obligatorio y verificado' -ForegroundColor White
        Write-Host ''
        $start = (Read-MenuOption 'Escribe I para INICIAR o V para volver').Trim().ToUpperInvariant()
        if ($start -ne 'I') {
            $script:AIOLangLastTerminalState.Status = 'Cancelled'
            $script:AIOLangLastTerminalState.Phase = 'Confirmacion del plan'
            $script:AIOLangLastTerminalState.Message = 'No se realizaron cambios en el medio.'
            Show-AIOLangTerminalSummary -Status Cancelled -Message $script:AIOLangLastTerminalState.Message
            Wait-AIOLangUser
            return
        }

        $result = Invoke-AIOLangMediaIntegration -MediaRoot $mediaRoot -RepositoryRoot $repositoryRoot -Inventory $inventory -Images $images -Indexes $indexes -Locales $locales -DefaultLocale $defaultLocale -IntegrateFod:$integrateFod -UpdateWinRE:$updateWinRE -UpdateBootWim:$updateBootWim -Cleanup:$cleanup -ResetBase:$resetBase -ExportSingleIndex:$exportSingle -OptimizeWims:$optimizeWims

        Show-AIOLangTerminalSummary -Status Success -Message 'La integracion de idiomas termino correctamente.'
        Wait-AIOLangUser
    }
    catch {
        $errorLine = $_.InvocationInfo.ScriptLineNumber
        $errorCode = if ($_.InvocationInfo.Line) { $_.InvocationInfo.Line.Trim() } else { '' }
        if (-not $script:AIOLangLastTerminalState) { [void](Initialize-AIOLangTerminalState) }
        $script:AIOLangLastTerminalState.Status = 'Failed'
        if (-not $script:AIOLangLastTerminalState.Phase -or $script:AIOLangLastTerminalState.Phase -eq 'Inicializacion') {
            $script:AIOLangLastTerminalState.Phase = $script:AIOLangCurrentPhase
        }
        $script:AIOLangLastTerminalState.Message = $_.Exception.Message
        $script:AIOLangLastTerminalState.ErrorLine = $errorLine
        $script:AIOLangLastTerminalState.ErrorCode = $errorCode
        if ($script:AIOLangLastDiagnosticPath) { $script:AIOLangLastTerminalState.DiagnosticPath = $script:AIOLangLastDiagnosticPath }
        if ($script:AIOLangLastPersistentLogPath) { $script:AIOLangLastTerminalState.LogPath = $script:AIOLangLastPersistentLogPath }
        Write-AIOLangLog -Level ERROR -Message $_.Exception.Message
        if ($errorLine) { Write-AIOLangLog -Level ERROR -Message "Linea ${errorLine}: $errorCode" }
        Show-AIOLangTerminalSummary -Status Failed -Message $_.Exception.Message
        Wait-AIOLangUser
    }
    finally {
        if ($scanRoot -and (Test-Path -LiteralPath $scanRoot)) { Remove-Item -LiteralPath $scanRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Show-LanguageIntegrator-Menu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host '          INTEGRADOR DE IDIOMAS DE WINDOWS             ' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '   [1] Integrar idiomas / crear medio multilingue' -ForegroundColor Green
        Write-Host '       Paquetes de idioma, FOD, WinRE, boot.wim y Setup' -ForegroundColor Gray
        Write-Host ''
        Write-Host '   [2] Restaurar un respaldo Preflight' -ForegroundColor Yellow
        Write-Host '       Revierte WIM y archivos localizados del medio' -ForegroundColor Gray
        Write-Host ''
        Write-Host '   [V] Volver al menu principal' -ForegroundColor Red
        $choice = (Read-MenuOption "`nSelecciona una opcion").Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { Start-AIOLangIntegrationWizard }
            '2' { Show-AIOLangRestoreMenu }
            'V' { return }
            default {
                Write-Host 'Opcion invalida.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

function LanguagePack-Menu {
    [CmdletBinding()]
    param()

    Show-LanguageIntegrator-Menu
}
