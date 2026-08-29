<#
.SYNOPSIS
    Integra idiomas y crea medios multilingues de Windows 10/11.
.DESCRIPTION
    Modulo complementario para AdminImagenOffline. Implementa un flujo
    transaccional de mantenimiento para medios de instalacion extraidos:

      - Detecta install.wim o convierte install.esd a WIM antes del servicio.
      - Permite seleccionar uno, varios o todos los indices de install.wim.
      - Detecta automaticamente paquetes de idioma CAB/ESD y sus metadatos.
      - Detecta componentes Language Features on Demand por identidad CBS.
      - Detecta automaticamente el ADK y el complemento de Windows PE.
      - Combina los paquetes WinPE instalados con el repositorio seleccionado.
      - Valida idioma, arquitectura y familia de build antes de modificar el medio.
      - Infiere la familia de build desde los paquetes detectados, sin tablas fijas.
      - Distingue paquetes WinPE encontrados de los realmente compatibles con el medio.
      - Diagnostica por separado paquetes WinPE encontrados, compatibles e incompatibles.
      - Integra paquetes de idioma antes de sus componentes dependientes.
      - Integra componentes linguisticos en un orden estable y verificable.
      - Actualiza winre.wim sin reutilizar una copia incompatible entre ediciones.
      - Actualiza opcionalmente todos los indices de boot.wim.
      - Sincroniza archivos localizados de Setup y genera lang.ini.
      - La Estrategia para WinPE: lp.cab, WinPE-SRT y paquetes Setup localizados segun los componentes neutrales presentes.
      - Copia lang.ini y recursos MUI de Setup dentro del indice de instalacion de boot.wim.
      - Verifica /Get-Intl, paquetes CBS, lang.ini y recursos MUI antes y despues de guardar boot.wim.
      - Impide declarar exito si el selector inicial de Windows Setup no queda realmente multilingue.
      - Si no hay WinPE Add-on compatible, aplica el modo de compatibilidad: lang.ini y recursos MUI en el indice Setup, sin afirmar que WinPE completo fue traducido.
      - Identifica el indice Setup por metadatos, paquetes Setup-Client/Server/ASZ, setup.exe, winpeshl.ini y fallback seguro al indice 2.
      - La verificacion final revisa solamente los indices de boot.wim realmente modificados.
      - Permite conservar el idioma actual o establecer uno nuevo como predeterminado.
      - Exporta solo la edicion seleccionada cuando se elige un unico indice.
      - Reconstruye WIM con compresion maxima y reemplazo atomico opcional.
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
    switch -Regex ($value) {
        '^(0|x86|i386|i686)$'    { return 'x86' }
        '^(9|x64|amd64|x86_64)$' { return 'x64' }
        '^(12|arm64|aarch64)$'   { return 'arm64' }
        '^(5|arm)$'               { return 'arm' }
        default {
            if ([string]::IsNullOrWhiteSpace($value)) { return 'Unknown' }
            return $value
        }
    }
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
    param([Parameter(Mandatory = $true)] [string]$Line)

    if (-not $script:AIOLangDismTranscript) { return }
    try {
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
        if (Test-Path -LiteralPath $mountPath) {
            [void](Dismount-AIOLangImage -MountPath $mountPath -Mode Discard -Context "Descartar montaje pendiente $mountPath" -NoThrow)
        }
    }
    $script:AIOLangMountedPaths.Clear()
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

function Get-AIOLangEsdImageIndexes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$EsdPath)

    $indexes = New-Object System.Collections.Generic.List[int]
    if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
        try {
            foreach ($image in @(Get-WindowsImage -ImagePath $EsdPath -ErrorAction Stop)) {
                if ([int]$image.ImageIndex -gt 0 -and [int]$image.ImageIndex -notin $indexes) {
                    [void]$indexes.Add([int]$image.ImageIndex)
                }
            }
        }
        catch {}
    }

    if ($indexes.Count -eq 0) {
        $query = Invoke-AIOLangDism -Arguments @('/Get-ImageInfo', "/ImageFile:$EsdPath") -Context "Inspeccionar ESD $([System.IO.Path]::GetFileName($EsdPath))" -Quiet -NoThrow
        if ($query.Success) {
            foreach ($line in @($query.Output)) {
                if ([string]$line -match '(?i)^\s*Index\s*:\s*(\d+)\s*$') {
                    $index = [int]$matches[1]
                    if ($index -gt 0 -and $index -notin $indexes) { [void]$indexes.Add($index) }
                }
            }
        }
    }

    return [int[]]@($indexes.ToArray() | Sort-Object -Unique)
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

    return [pscustomobject]@{
        Detected                = ($null -ne $primary)
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
    param([Parameter(Mandatory = $true)] [object]$AdkInfo)

    if ($AdkInfo.Detected) {
        Write-Host ' ADK          : Detectado' -ForegroundColor Green
        if ($AdkInfo.Root) { Write-Host " Ruta ADK     : $($AdkInfo.Root)" -ForegroundColor White }
        if ($AdkInfo.WinPERoot) {
            $architectures = if (@($AdkInfo.WinPEArchitectures).Count -gt 0) { @($AdkInfo.WinPEArchitectures) -join ', ' } else { 'N/D' }
            $inventoryText = if ([int]$AdkInfo.WinPELocalizedPackages -ge 0) { "$($AdkInfo.WinPELocalizedPackages) paquete(s)" } else { 'inventario diferido' }
            Write-Host " WinPE Add-on : Detectado | $architectures | $inventoryText" -ForegroundColor Green
            Write-Host " Ruta WinPE   : $($AdkInfo.WinPERoot)" -ForegroundColor DarkGray
        }
        else {
            Write-Host ' WinPE Add-on : No detectado. Instala el complemento de Windows PE para integrar boot.wim y winre.wim.' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ' ADK          : No detectado' -ForegroundColor Yellow
        Write-Host ' WinPE Add-on : No detectado; solo se usaran paquetes WinPE presentes en el repositorio.' -ForegroundColor DarkYellow
    }

    $versionText = if ($AdkInfo.ActiveDismVersion) { [string]$AdkInfo.ActiveDismVersion } else { 'N/D' }
    Write-Host " DISM activo  : $($AdkInfo.ActiveDismSource) | $versionText" -ForegroundColor White
    Write-Host " Ruta DISM    : $($AdkInfo.ActiveDismPath)" -ForegroundColor DarkGray
}

function Test-AIOLangBuildCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$TargetBuild,
        [AllowNull()] [object]$PackageBuild,
        [ValidateRange(1, 999)] [int]$MaximumBuildDelta = 500
    )

    # Los paquetes sin build legible conservan el comportamiento permisivo
    # anterior; DISM sigue siendo la comprobacion final de aplicabilidad.
    [int]$normalizedPackageBuild = 0
    if ($null -eq $PackageBuild -or
        -not [int]::TryParse([string]$PackageBuild, [ref]$normalizedPackageBuild) -or
        $normalizedPackageBuild -le 0 -or $TargetBuild -le 0) {
        return $true
    }

    if ($normalizedPackageBuild -eq $TargetBuild) { return $true }
    if ($normalizedPackageBuild -gt $TargetBuild) { return $false }

    # Las familias de mantenimiento comparten la misma rama de millar. La
    # diferencia maxima evita aceptar generaciones distintas que coincidan
    # solo por prefijo (por ejemplo, 22000 frente a 22621), sin enumerar builds.
    $targetBranch = [int][math]::Floor($TargetBuild / 1000)
    $packageBranch = [int][math]::Floor($normalizedPackageBuild / 1000)
    if ($targetBranch -ne $packageBranch) { return $false }

    return (($TargetBuild - $normalizedPackageBuild) -le $MaximumBuildDelta)
}

function Get-AIOLangBuildFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$Build,
        [AllowEmptyCollection()] [int[]]$ReferenceBuilds = @()
    )

    if ($Build -le 0) { return $Build }

    # La familia se infiere de las builds realmente disponibles en los
    # paquetes de idioma/FOD. Se prefiere la referencia compatible mas alta,
    # por ser la base mas cercana a la imagen objetivo. Sin referencias, la
    # build se conserva tal cual y no se depende de una tabla mantenida a mano.
    $compatibleReferences = @($ReferenceBuilds | Where-Object {
        $_ -gt 0 -and (Test-AIOLangBuildCompatibility -TargetBuild $Build -PackageBuild $_)
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
        $family = Get-AIOLangBuildFamily -Build $build -ReferenceBuilds $ReferenceBuilds
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
        '{0}~{1}~{2}~{3}~{4}' -f $name, $token, $arch, $(if ($language -and $language -ne '*') { $language } else { '' }), $version
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

function Get-AIOLangPackageCategory {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$IdentityName,
        [Parameter(Mandatory = $true)] [string]$FilePath
    )

    # La identidad CBS es la autoridad. El nombre y la carpeta solo se usan
    # cuando el contenedor no expone una identidad utilizable.
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

    $text = ($IdentityName + ' ' + [System.IO.Path]::GetFileName($FilePath)).ToLowerInvariant()
    if ($Category -eq 'LanguagePack') { return 0 }
    if ($Category -eq 'WinPE') {
        if ($text -match '(?:^|[-_])lp(?:[._-]|$)|common-foundation|winpe-srt') { return 10 }
        if ($text -match 'fontsupport') { return 15 }
        if ($text -match 'rejuv|storagewmi|hta') { return 20 }
        if ($text -match 'enhancedstorage|scripting|securestartup|wds-tools|winpe-wmi') { return 30 }
        if ($text -match 'winpe-setup') { return 40 }
        return 35
    }
    if ($text -match 'languagefeatures-basic') { return 10 }
    if ($text -match 'languagefeatures-fonts') { return 20 }
    if ($text -match 'languagefeatures-(texttospeech|handwriting|ocr|speech)|internationalfeatures') { return 30 }
    if ($text -match 'ethernet|wifi') { return 40 }
    if ($text -match 'mspaint|notepad|powershell-ise|internetexplorer') { return 50 }
    if ($text -match 'snippingtool|stepsrecorder|wordpad|printing') { return 60 }
    if ($text -match 'mediaplayer|wmic|terminalservices|virtualmachineplatform') { return 70 }
    if ($text -match 'projfs|telnet|tftp|vbscript|winocr|smbdirect|simpletcp|senseclient|enterpriseclientsync|directoryservices') { return 80 }
    if ($text -match 'servercorefonts') { return 90 }
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
            elseif ($identityName -match 'languagepack|common-foundation') { $score = 70 }
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

    $folderMap = @{ x64 = 'amd64'; x86 = 'x86'; arm64 = 'arm64'; arm = 'arm' }
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $seen = @{}

    foreach ($architecture in $architectures) {
        if (-not $folderMap.ContainsKey($architecture)) { continue }
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

            # Algunos Add-on colocan CAB localizados en la raiz de WinPE_OCs.
            $escapedLocale = [regex]::Escape($locale)
            foreach ($path in [System.IO.Directory]::EnumerateFiles($ocRoot, '*.cab', [System.IO.SearchOption]::TopDirectoryOnly)) {
                $name = [System.IO.Path]::GetFileName($path)
                if ($name -notmatch "(?i)(?:_|-)$escapedLocale\.cab$|^WinPE-FontSupport-$escapedLocale\.cab$") { continue }
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
    return ('{0}|{1}|{2}|{3}|{4}' -f $Package.Category, $Package.Locale, $Package.Architecture, $identity, $version).ToLowerInvariant()
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
                    $position++
                    Write-Progress -Activity "Analizando $SourceName" -Status $file.Name -PercentComplete (($position / $scanFiles.Count) * 100)
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

    $summaries = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)
    if ($summaries.Count -eq 0) { throw "No se encontraron indices en '$ImagePath'." }

    $details = New-Object System.Collections.Generic.List[object]
    foreach ($summary in $summaries) {
        $index = [int]$summary.ImageIndex
        $detail = Get-WindowsImage -ImagePath $ImagePath -Index $index -ErrorAction Stop
        if (-not $detail.Version) { throw "DISM no devolvio la version del indice $index." }
        $defaultLanguage = $null
        foreach ($propertyName in @('DefaultLanguage', 'Default Language', 'Language')) {
            $property = $detail.PSObject.Properties[$propertyName]
            if ($property -and $property.Value) {
                $defaultLanguage = Normalize-AIOLangLocale -Locale ([string]$property.Value)
                break
            }
        }
        $languages = New-Object System.Collections.Generic.List[string]
        foreach ($propertyName in @('Languages', 'Language')) {
            $property = $detail.PSObject.Properties[$propertyName]
            if ($property -and $property.Value) {
                foreach ($language in @($property.Value)) {
                    $normalized = Normalize-AIOLangLocale -Locale ([string]$language)
                    if ($normalized -and $normalized -notin $languages) { [void]$languages.Add($normalized) }
                }
            }
        }
        if ($defaultLanguage -and $defaultLanguage -notin $languages) { [void]$languages.Add($defaultLanguage) }

        [void]$details.Add([pscustomobject]@{
            ImageIndex       = $index
            ImageName        = [string]$detail.ImageName
            ImageDescription = [string]$detail.ImageDescription
            Architecture     = Convert-AIOLangArchitectureName -Architecture $detail.Architecture
            Version          = [version]$detail.Version
            Build            = [int]([version]$detail.Version).Build
            DefaultLanguage  = $defaultLanguage
            Languages        = [string[]]$languages.ToArray()
            InstallationType = [string]$detail.InstallationType
        })
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
    $locales = @($Inventory | Where-Object {
        $_.Category -eq 'LanguagePack' -and $_.Locale -and $_.Supported -and
        ($targetArchitectures.Count -eq 0 -or $_.Architecture -in $targetArchitectures)
    } | Select-Object -ExpandProperty Locale -Unique | Sort-Object)
    if ($locales.Count -eq 0) { throw 'No hay idiomas principales utilizables en el repositorio.' }

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
        [Parameter(Mandatory = $true)] [string]$Category
    )

    $normalizedPackages = @($Packages | Where-Object { $null -ne $_ })
    if ($normalizedPackages.Count -eq 0) { return $null }

    $candidates = @($normalizedPackages | Where-Object {
        $_.Category -eq $Category -and $_.Supported -and $_.Locale -eq $Locale -and
        $_.Architecture -eq $Architecture -and
        (Test-AIOLangBuildCompatibility -TargetBuild $Build -PackageBuild $_.Build)
    })
    if ($candidates.Count -eq 0) { return $null }

    return @($candidates | Sort-Object @{ Expression = {
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
            $package = Get-AIOLangBestPackage -Packages $Inventory -Locale $locale -Architecture $image.Architecture -Build $image.Build -Category 'LanguagePack'
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

    $result = @($Inventory | Where-Object {
        $_.Category -eq $Category -and $_.Supported -and $_.Locale -in $Locales -and
        $_.Architecture -eq $Image.Architecture -and
        (Test-AIOLangBuildCompatibility -TargetBuild ([int]$Image.Build) -PackageBuild $_.Build)
    })

    if ($Category -eq 'LanguagePack') {
        $best = New-Object System.Collections.Generic.List[object]
        foreach ($locale in $Locales) {
            $item = Get-AIOLangBestPackage -Packages $result -Locale $locale -Architecture $Image.Architecture -Build $Image.Build -Category 'LanguagePack'
            if ($item) { [void]$best.Add($item) }
        }
        return [object[]]$best.ToArray()
    }

    $deduplicated = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($result | Group-Object Locale, IdentityName)) {
        $item = @($group.Group | Sort-Object @{ Expression = {
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
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $seenTargets = @{}
    foreach ($image in @($TargetImages)) {
        $architecture = Convert-AIOLangArchitectureName -Architecture $image.Architecture
        $build = [int]$image.Build
        $key = "$architecture|$build"
        if ($seenTargets.ContainsKey($key)) { continue }
        $seenTargets[$key] = $true

        $compatible = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'WinPE')
        $sameTarget = @($Inventory | Where-Object {
            $_.Category -eq 'WinPE' -and $_.Supported -and $_.Locale -in $Locales -and $_.Architecture -eq $architecture
        })
        $availableBuilds = @($sameTarget | Where-Object { $null -ne $_.Build } | Select-Object -ExpandProperty Build -Unique | Sort-Object)
        $referenceBuilds = @($Inventory | Where-Object {
            $_.Supported -and $_.Locale -in $Locales -and $_.Architecture -eq $architecture -and
            $_.Category -in @('LanguagePack', 'LanguageFOD') -and $null -ne $_.Build
        } | Select-Object -ExpandProperty Build -Unique | Sort-Object)
        $family = Get-AIOLangBuildFamily -Build $build -ReferenceBuilds $referenceBuilds
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

        if ($report.AvailableCount -gt 0) {
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
        $ProgressState.Current = [int]$ProgressState.Current + 1
        $percent = if ([int]$ProgressState.Total -gt 0) {
            [math]::Min(100, [math]::Floor(([double]$ProgressState.Current / [double]$ProgressState.Total) * 100))
        }
        else { 100 }
        Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("{0}/{1} archivos verificados ({2}%)" -f $ProgressState.Current, $ProgressState.Total, $percent) -PercentComplete $percent
        $showDetail = ([string]$file.MediaRelativePath -match '(?i)^sources\\(boot|install)\.(wim|esd)$')
        if ($showDetail) {
            Write-Host ("   [{0}/{1}] Copiando y verificando {2}..." -f $ProgressState.Current, $ProgressState.Total, $file.MediaRelativePath) -ForegroundColor Gray
        }
        $copy = Copy-AIOLangFileVerified -Source $file.SourcePath -Destination $destination
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
        $ProgressState.Current = [int]$ProgressState.Current + 1
        $percent = if ([int]$ProgressState.Total -gt 0) {
            [math]::Min(100, [math]::Floor(([double]$ProgressState.Current / [double]$ProgressState.Total) * 100))
        }
        else { 100 }
        Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("{0}/{1} archivos verificados ({2}%)" -f $ProgressState.Current, $ProgressState.Total, $percent) -PercentComplete $percent
        $showDetail = ([string]$file.MediaRelativePath -match '(?i)^sources\\(boot|install)\.(wim|esd)$')
        if ($showDetail) {
            Write-Host ("   [{0}/{1}] Copiando y verificando {2}..." -f $ProgressState.Current, $ProgressState.Total, $file.MediaRelativePath) -ForegroundColor Gray
        }
        $copy = Copy-AIOLangFileVerified -Source $file.SourcePath -Destination $target
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

    foreach ($entry in @($manifest.Entries)) {
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
    $temporaryOld = $DestinationPath + '.aio_old_' + [guid]::NewGuid().ToString('N')
    try {
        if (Test-Path -LiteralPath $DestinationPath) { Move-Item -LiteralPath $DestinationPath -Destination $temporaryOld -Force -ErrorAction Stop }
        Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $temporaryOld) { Remove-Item -LiteralPath $temporaryOld -Force -ErrorAction Stop }
    }
    catch {
        if (-not (Test-Path -LiteralPath $DestinationPath) -and (Test-Path -LiteralPath $temporaryOld)) {
            Move-Item -LiteralPath $temporaryOld -Destination $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        throw
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
    $images = @(Get-WindowsImage -ImagePath $EsdPath -ErrorAction Stop)
    if ($images.Count -eq 0) { throw "No se encontraron indices en '$EsdPath'." }

    foreach ($image in $images) {
        [void](Invoke-AIOLangDism -Arguments @(
            '/Export-Image', "/SourceImageFile:$EsdPath", "/SourceIndex:$($image.ImageIndex)",
            "/DestinationImageFile:$temporary", '/Compress:max', '/CheckIntegrity'
        ) -Context "Convertir install.esd - indice $($image.ImageIndex)/$($images.Count)")
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

    $images = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop)
    $temporary = Join-Path $ScratchPath (([System.IO.Path]::GetFileNameWithoutExtension($WimPath)) + '.rebuild.wim')
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    foreach ($image in $images) {
        [void](Invoke-AIOLangDism -Arguments @(
            '/Export-Image', "/SourceImageFile:$WimPath", "/SourceIndex:$($image.ImageIndex)",
            "/DestinationImageFile:$temporary", '/Compress:max', '/CheckIntegrity'
        ) -Context "$Context - indice $($image.ImageIndex)/$($images.Count)")
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

function Get-AIOLangPackageInstallMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object]$Package
    )

    $packagesRoot = Join-Path $MountPath 'Windows\Servicing\Packages'
    if (-not (Test-Path -LiteralPath $packagesRoot -PathType Container)) {
        return [pscustomobject]@{ Installed = $false; MatchedBy = 'PackagesRootMissing'; MatchPath = $null }
    }

    if ($Package.PackageName) {
        $exactPath = Join-Path $packagesRoot ([string]$Package.PackageName + '.mum')
        if (Test-Path -LiteralPath $exactPath -PathType Leaf) {
            return [pscustomobject]@{ Installed = $true; MatchedBy = 'PackageNameExact'; MatchPath = $exactPath }
        }
    }

    # Los CAB de Features on Demand suelen omitir la version despues de "~~".
    # Buscar por el nombre completo del CAB evita confundir Speech con
    # TextToSpeech o Basic con un manifiesto auxiliar incluido en el mismo CAB.
    $fileStem = [System.IO.Path]::GetFileNameWithoutExtension([string]$Package.Name)
    if (-not [string]::IsNullOrWhiteSpace($fileStem)) {
        $fileMatches = @(Get-ChildItem -LiteralPath $packagesRoot -File -Filter ($fileStem + '*.mum') -ErrorAction SilentlyContinue)
        if ($fileMatches.Count -gt 0) {
            return [pscustomobject]@{ Installed = $true; MatchedBy = 'CabIdentityPrefix'; MatchPath = $fileMatches[0].FullName }
        }
    }

    $identity = [string]$Package.IdentityName
    $locale = [string]$Package.Locale
    if (-not [string]::IsNullOrWhiteSpace($identity)) {
        $identityMatches = @(Get-ChildItem -LiteralPath $packagesRoot -File -Filter '*.mum' -ErrorAction SilentlyContinue | Where-Object {
            $_.BaseName.IndexOf($identity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            ([string]::IsNullOrWhiteSpace($locale) -or $_.BaseName.IndexOf($locale, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        })
        if ($identityMatches.Count -gt 0) {
            return [pscustomobject]@{ Installed = $true; MatchedBy = 'IdentityAndLocale'; MatchPath = $identityMatches[0].FullName }
        }
    }

    return [pscustomobject]@{ Installed = $false; MatchedBy = 'NoMatch'; MatchPath = $null }
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
        [Parameter(Mandatory = $true)] [object]$Package
    )

    if ($Package.Category -eq 'LanguagePack') { return $true }
    $packagesRoot = Join-Path $MountPath 'Windows\Servicing\Packages'
    if (-not (Test-Path -LiteralPath $packagesRoot)) { return $true }
    $text = ([string]$Package.IdentityName + ' ' + [string]$Package.Name).ToLowerInvariant()

    if ($Package.Category -eq 'WinPE') {
        $tokens = @()
        if ($text -match 'winpe-srt') { $tokens = @('WinPE-SRT-Package') }
        elseif ($text -match 'winpe-setup-(client|server|asz)') { $tokens = @('WinPE-Setup-', 'WinPE-Setup-Package') }
        elseif ($text -match 'winpe-setup') { $tokens = @('WinPE-Setup-Package') }
        elseif ($text -match 'winpe-rejuv') { $tokens = @('WinPE-Rejuv-Package') }
        elseif ($text -match 'winpe-hta') { $tokens = @('WinPE-HTA-Package') }
        elseif ($text -match 'winpe-storagewmi') { $tokens = @('WinPE-StorageWMI-Package') }
        elseif ($text -match 'winpe-enhancedstorage') { $tokens = @('WinPE-EnhancedStorage-Package') }
        elseif ($text -match 'winpe-scripting') { $tokens = @('WinPE-Scripting-Package') }
        elseif ($text -match 'winpe-securestartup') { $tokens = @('WinPE-SecureStartup-Package') }
        elseif ($text -match 'winpe-wds-tools') { $tokens = @('WinPE-WDS-Tools-Package') }
        elseif ($text -match 'winpe-wmi') { $tokens = @('WinPE-WMI-Package') }
        elseif ($text -match 'fontsupport|(?:^|[-_])lp(?:[._-]|$)|common-foundation') { return $true }
        else { return $true }

        foreach ($token in $tokens) {
            if (@(Get-ChildItem -LiteralPath $packagesRoot -File -Filter "*$token*.mum" -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
        }
        return $false
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
        [switch]$AllowNotApplicable
    )

    $displayName = Get-AIOLangPackageDisplayName -Package $Package
    $installMatch = Get-AIOLangPackageInstallMatch -MountPath $MountPath -Package $Package
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
    if (-not (Test-AIOLangNeutralParentPresent -MountPath $MountPath -Package $Package)) {
        Write-Host " [OMITIDO] $($Package.Name) - componente neutral no presente." -ForegroundColor DarkYellow
        Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context $Context -State 'SkippedMissingParent' -Details $Package.Name
        return [pscustomobject]@{ Success = $true; State = 'SkippedMissingParent'; ExitCode = 0 }
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
        return
    }

    foreach ($package in $normalizedPackages) {
        $context = "$ContextPrefix - $($package.Locale) - $($package.IdentityName)"
        [void](Add-AIOLangPackageToImage -MountPath $MountPath -Package $package -PackagePath $package.FilePath -Context $context -AllowNotApplicable)
    }
}

function Assert-AIOLangInstalledPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $results = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($package in @($Packages | Where-Object { $null -ne $_ } | Sort-Object Category, Locale, Name -Unique)) {
        $displayName = Get-AIOLangPackageDisplayName -Package $package
        $match = Get-AIOLangPackageInstallMatch -MountPath $MountPath -Package $package
        $state = if ($match.Installed) { 'Installed' } else { 'Missing' }
        $result = [pscustomobject]@{
            Category   = $package.Category
            Locale     = $package.Locale
            Package    = $displayName
            Installed  = [bool]$match.Installed
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
        [switch]$SetupImage
    )

    [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-AllIntl:$DefaultLocale", '/Quiet') -Context "$ContextPrefix - Set-AllIntl")
    [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-SKUIntlDefaults:$DefaultLocale", '/Quiet') -Context "$ContextPrefix - Set-SKUIntlDefaults")
    if ($DistributionPath) {
        [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", '/Gen-LangINI', "/Distribution:$DistributionPath", '/Quiet') -Context "$ContextPrefix - Generar lang.ini")
        [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-SetupUILang:$DefaultLocale", "/Distribution:$DistributionPath", '/Quiet') -Context "$ContextPrefix - Idioma de Setup")
    }
    elseif ($SetupImage) {
        [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", '/Gen-LangINI', "/Distribution:$MountPath", '/Quiet') -Context "$ContextPrefix - Generar lang.ini de WinPE")
        [void](Invoke-AIOLangDism -Arguments @("/Image:$MountPath", "/Set-SetupUILang:$DefaultLocale", "/Distribution:$MountPath", '/Quiet') -Context "$ContextPrefix - Idioma de Setup WinPE")
    }
}

function Invoke-AIOLangComponentCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ResetBase
    )

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

    $descriptor = Get-AIOLangWinPEImageDescriptor -MountPath $MountPath -Architecture $Architecture -Build $Build
    $packages = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $descriptor -Locales $Locales -Category 'WinPE')
    if ($packages.Count -eq 0) { throw "No se encontraron paquetes WinPE compatibles para $Architecture / build $Build." }

    Mount-AIOLangImage -ImagePath $WinREPath -Index 1 -MountPath $MountPath -ScratchPath $ScratchPath -Context 'Montar winre.wim'
    $committed = $false
    try {
        $script:AIOLangCurrentPhase = 'WinRE'
        Add-AIOLangFeaturePackages -MountPath $MountPath -Packages $packages -ContextPrefix 'Integrar idioma en WinRE'
        Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix 'Configurar WinRE'
        $expectedPackages = @($packages | Where-Object { Test-AIOLangNeutralParentPresent -MountPath $MountPath -Package $_ })
        if ($expectedPackages.Count -gt 0) {
            [void](Assert-AIOLangInstalledPackages -MountPath $MountPath -Packages $expectedPackages -Context 'Verificar paquetes de idioma en WinRE')
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

function Copy-AIOLangFileWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [int]$Retries = 8
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $Retries) { throw }
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
            if ($IntegrateFod) {
                $fodPackages = @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'LanguageFOD')
                if ($fodPackages.Count -gt 0) {
                    Add-AIOLangFeaturePackages -MountPath $MountPath -Packages $fodPackages -ContextPrefix "FOD indice $index"
                }
                else {
                    Write-Host ' [OMITIDO] No hay Features on Demand compatibles para este indice.' -ForegroundColor DarkYellow
                }
            }

            $expectedPackages = @($languagePackages)
            if ($IntegrateFod) { $expectedPackages += @($fodPackages) }
            [void](Assert-AIOLangInstalledPackages -MountPath $MountPath -Packages $expectedPackages -Context "Verificar paquetes install.wim indice $index")

            $distribution = if ($position -eq ($selectedImages.Count - 1)) { $MediaRoot } else { $null }
            Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix "Configurar idioma indice $index" -DistributionPath $distribution

            $winreSource = Join-Path $MountPath 'Windows\System32\Recovery\winre.wim'
            if ($UpdateWinRE -and (Test-Path -LiteralPath $winreSource -PathType Leaf)) {
                $hash = Get-AIOLangFileHashSafe -Path $winreSource
                if (-not $hash) {
                    $winreItem = Get-Item -LiteralPath $winreSource -ErrorAction Stop
                    $hash = ('FALLBACK_{0}_{1}' -f $winreItem.Length, $winreItem.LastWriteTimeUtc.Ticks)
                }
                $hashToken = ($hash -replace '[^A-Za-z0-9]', '')
                if ([string]::IsNullOrWhiteSpace($hashToken)) { $hashToken = [guid]::NewGuid().ToString('N') }
                $cacheKey = "$($image.Architecture)_$hash"
                if (-not $winreCache.ContainsKey($cacheKey)) {
                    $winreWork = Join-Path $WinRECacheRoot ("winre_{0}_{1}.wim" -f $image.Architecture, $hashToken.Substring(0, [Math]::Min(12, $hashToken.Length)))
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

    $images = @(Get-WindowsImage -ImagePath $BootWim -ErrorAction Stop)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($summary in $images) {
        $detail = Get-WindowsImage -ImagePath $BootWim -Index ([int]$summary.ImageIndex) -ErrorAction Stop
        [void]$result.Add([pscustomobject]@{
            ImageIndex       = [int]$detail.ImageIndex
            ImageName        = [string]$detail.ImageName
            ImageDescription = [string]$detail.ImageDescription
            Architecture     = Convert-AIOLangArchitectureName -Architecture $detail.Architecture
            Version          = [version]$detail.Version
            Build            = [int]([version]$detail.Version).Build
        })
    }
    return [object[]]$result.ToArray()
}


function Get-AIOLangPayloadFileIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Payload)

    if ($Payload.PSObject.Properties['FileIndex'] -and $Payload.FileIndex) {
        return $Payload.FileIndex
    }

    $index = @{}
    if (Test-Path -LiteralPath $Payload.ExtractRoot -PathType Container) {
        foreach ($path in [System.IO.Directory]::EnumerateFiles($Payload.ExtractRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
            $key = [System.IO.Path]::GetFileName($path).ToLowerInvariant()
            if (-not $index.ContainsKey($key)) {
                $index[$key] = New-Object System.Collections.Generic.List[string]
            }
            [void]$index[$key].Add($path)
        }
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
    foreach ($line in @($result.Output)) {
        foreach ($match in [regex]::Matches([string]$line, '(?<![A-Za-z0-9])([A-Za-z]{2,3}(?:-[A-Za-z]{4})?-[A-Za-z]{2})(?![A-Za-z0-9])')) {
            $locale = Normalize-AIOLangLocale -Locale $match.Groups[1].Value
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

        $coreNames = @('setup.exe.mui','setupplatform.exe.mui','w32uires.dll.mui','winsetup.dll.mui','spwizres.dll.mui')
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
            $allowResourcesOnlyForIndex = [bool](
                ($plannedUpdate -and [string]$plannedUpdate.Mode -eq 'SetupResourcesOnly') -or
                ($AllowSetupResourcesOnly -and $isSetup)
            )
            Write-AIOLangLog -Level INFO -Message ("boot.wim indice {0}: rol Setup={1}; deteccion={2}." -f $index, $isSetup, (@($role.Reasons) -join ','))

            $result = Assert-AIOLangMountedWinPELocalization -MountPath $MountPath -Locales $Locales -Context "Verificacion final boot.wim indice $index" -SetupImage:$isSetup -AllowSetupResourcesOnly:$allowResourcesOnlyForIndex
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

    $bootMuiNames = @(
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
    $rtfNames = @('vofflps.rtf','credits.rtf','oobe_help_opt_in_details.rtf')
    $coreNames = @('setup.exe.mui','setupplatform.exe.mui','w32uires.dll.mui','winsetup.dll.mui','spwizres.dll.mui')
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

    if (Test-Path -LiteralPath (Join-Path $mountedSources 'setup.exe')) {
        Copy-AIOLangFileWithRetry -Source (Join-Path $mountedSources 'setup.exe') -Destination (Join-Path $mediaSources 'setup.exe')
    }
    if (Test-Path -LiteralPath (Join-Path $MountPath 'setup.exe')) {
        Copy-AIOLangFileWithRetry -Source (Join-Path $MountPath 'setup.exe') -Destination (Join-Path $MediaRoot 'setup.exe')
    }

    foreach ($locale in $Locales) {
        $mountedLocale = Join-Path $mountedSources $locale
        if (Test-Path -LiteralPath $mountedLocale -PathType Container) {
            Copy-AIOLangTree -Source $mountedLocale -Destination (Join-Path $mediaSources $locale)
        }
    }

    if ($SetupImage) {
        $mountedLangIni = Join-Path $mountedSources 'lang.ini'
        if (-not (Test-Path -LiteralPath $mountedLangIni -PathType Leaf)) {
            throw "boot.wim indice $Index no contiene sources\lang.ini despues de configurar Windows Setup."
        }
        Copy-AIOLangFileWithRetry -Source $mountedLangIni -Destination (Join-Path $mediaSources 'lang.ini')
    }

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

            # PowerShell 5.1 puede convertir la ausencia de salida de una funcion en $null
            # al enlazar un parametro de tipo object[]. Se normaliza expresamente la
            # coleccion y se eliminan elementos nulos antes de decidir el modo WinPE.
            $packageList = New-Object System.Collections.Generic.List[object]
            foreach ($candidate in @(Get-AIOLangPackagesForImage -Inventory $Inventory -Image $image -Locales $Locales -Category 'WinPE')) {
                if ($null -ne $candidate) { [void]$packageList.Add($candidate) }
            }
            $packages = [object[]]$packageList.ToArray()
            $fullWinPE = [bool]($packageList.Count -gt 0)
            if ($fullWinPE) {
                Add-AIOLangFeaturePackages -MountPath $MountPath -Packages ([object[]]$packageList.ToArray()) -ContextPrefix "WinPE indice $index"
            }
            elseif (-not $isSetup) {
                Write-Host " [OMITIDO] boot.wim indice $index no es Setup y no tiene paquetes WinPE compatibles." -ForegroundColor DarkYellow
                [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Discard -Context "Cerrar boot.wim indice $index sin cambios")
                $committed = $true
                [void]$results.Add([pscustomobject]@{ Index = $index; Mode = 'NotModified'; SetupImage = $false; PackageCount = 0; Detection = [string[]]$role.Reasons })
                continue
            }
            else {
                Write-Host ' [MODO COMPATIBILIDAD] No hay paquetes WinPE compatibles; se integraran lang.ini y recursos MUI de Setup.' -ForegroundColor Yellow
                Write-AIOLangLog -Level WARN -Message "boot.wim indice ${index}: se aplicara el modo de recursos Setup sin paquetes WinPE compatibles."
            }

            if ($isSetup) {
                Copy-AIOLangMediaLangIniToBootImage -MediaRoot $MediaRoot -MountPath $MountPath
                [void](Merge-AIOLangPayloadIntoBootImage -MountPath $MountPath -Payloads $Payloads -Architecture $image.Architecture -Locales $Locales -SetupImage -Server:$isServerSetup -AzureStackHci:$isAzureStackHci)
            }

            if ($fullWinPE) {
                Set-AIOLangInternationalSettings -MountPath $MountPath -DefaultLocale $DefaultLocale -ContextPrefix "Configurar boot.wim indice $index" -SetupImage:$isSetup
                $expectedPackages = @($packages | Where-Object { $null -ne $_ -and (Test-AIOLangNeutralParentPresent -MountPath $MountPath -Package $_) })
                if ($expectedPackages.Count -gt 0) {
                    [void](Assert-AIOLangInstalledPackages -MountPath $MountPath -Packages $expectedPackages -Context "Verificar paquetes WinPE indice $index")
                }
            }

            $verification = Assert-AIOLangMountedWinPELocalization -MountPath $MountPath -Locales $Locales -Context "Verificar localizacion antes de commit boot.wim indice $index" -SetupImage:$isSetup -AllowSetupResourcesOnly:(-not $fullWinPE)

            if ($Cleanup -and $fullWinPE) { Invoke-AIOLangComponentCleanup -MountPath $MountPath -Context "Limpiar boot.wim indice $index" -ResetBase:$ResetBase }
            Sync-AIOLangBootFiles -MountPath $MountPath -MediaRoot $MediaRoot -Index $index -Locales $Locales -SetupImage:$isSetup
            [void](Dismount-AIOLangImage -MountPath $MountPath -Mode Commit -Context "Guardar boot.wim indice $index")
            $committed = $true
            [void]$results.Add([pscustomobject]@{
                Index = $index
                Mode = $verification.Mode
                SetupImage = [bool]$isSetup
                PackageCount = $packages.Count
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

    $imageLanguageChecks = New-Object System.Collections.Generic.List[object]
    foreach ($image in $selectedImages) {
        $reportedLanguages = @($image.Languages | Where-Object { $_ } | ForEach-Object { Normalize-AIOLangLocale -Locale $_ } | Select-Object -Unique)
        $missing = if ($reportedLanguages.Count -gt 0) { @($Locales | Where-Object { $_ -notin $reportedLanguages }) } else { @() }
        [void]$imageLanguageChecks.Add([pscustomobject]@{
            ImageIndex        = $image.ImageIndex
            ImageName         = $image.ImageName
            DefaultLanguage   = $image.DefaultLanguage
            ReportedLanguages = [string[]]$reportedLanguages
            MetadataAvailable = [bool]($reportedLanguages.Count -gt 0)
            MissingLanguages  = [string[]]$missing
            Complete          = [bool]($reportedLanguages.Count -eq 0 -or $missing.Count -eq 0)
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

    Add-AIOLangOperation -Phase $script:AIOLangCurrentPhase -Context 'Verificar idiomas en metadatos de install.wim' -State 'Success' -Details @{ ImagesChecked = @($selectedImages).Count }
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
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Reporte de integracion de idiomas</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#202124}h1{font-size:24px}table{border-collapse:collapse;width:100%;margin-top:18px}th,td{border:1px solid #d0d7de;padding:8px;text-align:left}th{background:#f6f8fa}.ok{color:#137333;font-weight:600}.fail{color:#b3261e;font-weight:600}code{background:#f6f8fa;padding:2px 5px}</style>
</head>
<body>
<h1>Integracion de idiomas</h1>
<p>Estado: <span class="$(if ($Report.Status -eq 'Success') {'ok'} else {'fail'})">$status</span></p>
<p>Medio: <code>$media</code></p>
<p>Indices: $indexes</p>
<p>Idiomas: $languages</p>
<p>Predeterminado: $([System.Net.WebUtility]::HtmlEncode([string]$Report.Configuration.DefaultLocale))</p>
<p>Inicio: $([System.Net.WebUtility]::HtmlEncode([string]$Report.Started))<br>Fin: $([System.Net.WebUtility]::HtmlEncode([string]$Report.Finished))</p>
<h2>Operaciones</h2>
<table><thead><tr><th>Fecha</th><th>Fase</th><th>Contexto</th><th>Estado</th></tr></thead><tbody>$($operationRows -join "`n")</tbody></table>
</body>
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
    foreach ($path in @($scratch, $payloadRoot, $mountInstall, $mountWinRE, $mountBoot, $winreCacheRoot)) {
        Initialize-AIOLangDirectory -Path $path
    }

    $selectedImages = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes } | Sort-Object ImageIndex)
    $configuration = [pscustomobject]@{
        MediaRoot       = $MediaRoot
        RepositoryRoot  = $RepositoryRoot
        PackageSources  = [string[]]@($Inventory | ForEach-Object { if ($_.PSObject.Properties['Source']) { $_.Source } else { 'Repositorio' } } | Select-Object -Unique)
        AdkDetected     = [bool]$(if ($script:AIOLangAdkInfo) { $script:AIOLangAdkInfo.Detected } else { $false })
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
        foreach ($locale in $Locales) {
            $setupPackage = Get-AIOLangBestPackage -Packages $Inventory -Locale $locale -Architecture $setupDescriptor.Architecture -Build $setupDescriptor.Build -Category 'LanguagePack'
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
        Update-AIOLangInstallWim -InstallWim $installImage -Images $Images -Indexes $Indexes -Inventory $Inventory -Payloads $payloads -Locales $Locales -DefaultLocale $DefaultLocale -MediaRoot $MediaRoot -MountPath $mountInstall -WinREMountPath $mountWinRE -ScratchPath $scratch -WinRECacheRoot $winreCacheRoot -IntegrateFod:$IntegrateFod -UpdateWinRE:$UpdateWinRE -Cleanup:$Cleanup -ResetBase:$ResetBase

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
        $failedLanguageChecks = @($verification.ImageLanguageChecks | Where-Object { $_.MetadataAvailable -and -not $_.Complete })
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
            if ($resourcesOnlyCount -gt 0) {
                Write-Host " [OK] Selector de idiomas de Windows Setup habilitado mediante lang.ini y recursos MUI" -ForegroundColor Green
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
        Clear-AIOLangMountedImages
        $diagnostic = $null
        try {
            $diagnostic = New-AIOLangDiagnosticBundle -ErrorRecord $integrationError -Configuration $configuration -BackupRoot $(if ($backup) { $backup.Root } else { $null })
        }
        catch {
            Write-AIOLangLog -Level WARN -Message "No se pudo generar el diagnostico automatico: $($_.Exception.Message)"
        }
        if ($backup -and $mediaMutationStarted) {
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
        Clear-AIOLangMountedImages
        if ($script:AIOLangSessionRoot -and (Test-Path -LiteralPath $script:AIOLangSessionRoot)) {
            if ($script:AIOLangDismTranscript -and (Test-Path -LiteralPath $script:AIOLangDismTranscript)) {
                Initialize-AIOLangDirectory -Path $script:AIOLangReportsRoot
                $transcriptCopy = Join-Path $script:AIOLangReportsRoot ("DISM_Idiomas_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                Copy-Item -LiteralPath $script:AIOLangDismTranscript -Destination $transcriptCopy -Force -ErrorAction SilentlyContinue
                $script:AIOLangLastPersistentLogPath = $transcriptCopy
                if ($script:AIOLangLastTerminalState) { $script:AIOLangLastTerminalState.LogPath = $transcriptCopy }
            }
            Remove-Item -LiteralPath $script:AIOLangSessionRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:AIOLangSessionRoot = $null
        $script:AIOLangDismTranscript = $null
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

        # Se obtiene primero la metadata de las imagenes. Asi el ADK se limita
        # desde el principio a la arquitectura, idiomas y builds realmente
        # requeridos, en lugar de inspeccionar miles de CAB de todo el Add-on.
        $images = @(Get-AIOLangImageMetadata -ImagePath $installImage)
        $bootImages = if (Test-Path -LiteralPath $bootWim -PathType Leaf) { @(Get-AIOLangBootImageMetadata -BootWim $bootWim) } else { @() }
        $targetImagesForAdk = @($images) + @($bootImages)
        $targetArchitecturesForAdk = [string[]]@($targetImagesForAdk | ForEach-Object {
            Convert-AIOLangArchitectureName -Architecture $_.Architecture
        } | Where-Object { $_ -and $_ -ne 'Unknown' } | Select-Object -Unique)
        $targetBuildsForAdk = [int[]]@($targetImagesForAdk | Where-Object { $_.Build } | Select-Object -ExpandProperty Build -Unique)

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
                Write-AIOLangLog -Level WARN -Message "No se pudo analizar el complemento WinPE detectado: $($_.Exception.Message)"
                Write-Host "[ADVERTENCIA] Se detecto WinPE, pero no pudo analizarse: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $inventory = @(Merge-AIOLangLogicalInventory -Inventory ([object[]]$inventoryBuffer.ToArray()))

        Clear-Host
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host '                    RESUMEN PREVIO                     ' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host " Medio origen : $mediaRoot" -ForegroundColor White
        Write-Host " Repositorio  : $repositoryRoot" -ForegroundColor White
        Write-Host " Imagen       : $([System.IO.Path]::GetFileName($installImage))" -ForegroundColor White
        Show-AIOLangAdkStatus -AdkInfo $adkInfo
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
            if ($scanSummary -and $scanSummary.FullScanSkipped) {
                Write-Host " WinPE ADK    : $($scanSummary.AnalyzedCount) sondeado(s) de $($scanSummary.CandidateCount) | 0 compatibles con install.wim | Build(s): $adkBuildText" -ForegroundColor White
                Write-Host '               Escaneo completo omitido: la familia WinPE no es compatible con el medio.' -ForegroundColor DarkGray
            }
            else {
                $analyzedCount = if ($scanSummary) { $scanSummary.AnalyzedCount } else { @($adkInventory).Count }
                Write-Host " WinPE ADK    : $analyzedCount analizados | $(@($adkCompatibleInstall).Count) compatibles con install.wim | Build(s): $adkBuildText" -ForegroundColor White
            }
        }
        Write-Host ''
        Show-AIOLangInventorySummary -Inventory $inventory -TargetImages $images

        $indexes = Select-AIOLangInstallIndexes -Images $images
        $selectedImagesForChoice = @($images | Where-Object { [int]$_.ImageIndex -in $indexes })
        $locales = Select-AIOLangLocales -Inventory $inventory -TargetImages $selectedImagesForChoice
        $coverage = Assert-AIOLangPackageCoverage -Inventory $inventory -Images $images -Indexes $indexes -Locales $locales
        $defaultLocale = Select-AIOLangDefaultLocale -SelectedImages $coverage.Images -SelectedLocales $locales

        $relevantFod = @()
        $winRePackages = @()
        foreach ($image in $coverage.Images) {
            $relevantFod += @(Get-AIOLangPackagesForImage -Inventory $inventory -Image $image -Locales $locales -Category 'LanguageFOD')
            $winRePackages += @(Get-AIOLangPackagesForImage -Inventory $inventory -Image $image -Locales $locales -Category 'WinPE')
        }
        $relevantFod = @($relevantFod | Sort-Object FilePath -Unique)
        $winRePackages = @($winRePackages | Sort-Object FilePath -Unique)

        $bootPackages = @()
        foreach ($bootImage in $bootImages) {
            $bootPackages += @(Get-AIOLangPackagesForImage -Inventory $inventory -Image $bootImage -Locales $locales -Category 'WinPE')
        }
        $bootPackages = @($bootPackages | Sort-Object FilePath -Unique)
        $relevantWinPE = @($winRePackages + $bootPackages | Sort-Object FilePath -Unique)

        $winPeCompatibility = @()
        $winPeCompatibility += @(Get-AIOLangWinPECompatibilityReport -Inventory $inventory -TargetImages $coverage.Images -Locales $locales -Context 'winre.wim')
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
        elseif ($bootPackages.Count -gt 0) {
            $updateBootWim = Read-AIOLangYesNo -Prompt "Actualizar boot.wim y habilitar los idiomas en la pantalla inicial de Windows Setup ($($bootPackages.Count) paquetes WinPE)" -Default $true
        }
        else {
            Write-Host ' [ADVERTENCIA] No hay paquetes WinPE compatibles para boot.wim.' -ForegroundColor Yellow
            Write-Host '               Puede usarse el modo de compatibilidad: copia lang.ini y recursos MUI al indice Setup.' -ForegroundColor DarkYellow
            $updateBootWim = Read-AIOLangYesNo -Prompt 'Habilitar de todos modos los idiomas en la pantalla inicial de Windows Setup' -Default $true
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
        Write-Host " ADK                  : $($adkInfo.Detected)" -ForegroundColor White
        $compatibleWinPeCount = @($relevantWinPE).Count
        Write-Host " WinPE Add-on         : $([bool]$adkInfo.WinPERoot) ($(@($adkInventory).Count) analizadas | $compatibleWinPeCount compatibles)" -ForegroundColor White
        Write-Host " winre.wim            : $updateWinRE ($($winRePackages.Count) compatibles)" -ForegroundColor White
        Write-Host " boot.wim             : $updateBootWim ($($bootPackages.Count) compatibles)" -ForegroundColor White
        Write-Host " DISM                  : $($adkInfo.ActiveDismSource) $($adkInfo.ActiveDismVersion)" -ForegroundColor White
        Write-Host " Limpieza             : $cleanup | ResetBase: $resetBase" -ForegroundColor White
        Write-Host " Optimizar WIM        : $optimizeWims" -ForegroundColor White
        Write-Host " Salida edicion unica : $exportSingle" -ForegroundColor White
        Write-Host ' Respaldo previo      : Obligatorio y verificado' -ForegroundColor White
        Write-Host ''
        $start = (Read-Host 'Escribe I para INICIAR o V para volver').Trim().ToUpperInvariant()
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
        $choice = (Read-Host "`nSelecciona una opcion").Trim().ToUpperInvariant()
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
