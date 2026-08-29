# ==============================================================================
#  Modulo-IsoMaker
#
#  CONTENIDO   : Show-IsoMaker-GUI
#  INTEGRACION : Diseñado para cargarse mediante dot-source desde
#                AdminImagenOffline. No usa exit ni modifica funciones del nucleo.
#
#  DEPENDENCIAS HEREDADAS (opcionales, con respaldo interno):
#    - Write-Log        : registro principal de eventos.
#    - $script:logDir   : directorio de logs de compilacion.
#
#  DEPENDENCIA EXTERNA:
#    - oscdimg.exe (Windows ADK Deployment Tools o carpeta Tools).
#
#  CARACTERISTICAS PRINCIPALES:
#    - Perfiles dinamicos BIOS, UEFI, BIOS+UEFI y ARM64 UEFI-only.
#    - Reintento automatico OPTIMIZADO / ESTANDAR / COMPATIBILIDAD.
#    - BootOrder para fuentes mayores de 4.5 GB, UDF 1.02 y archivos ocultos.
#    - Lectura asincronica de oscdimg sin bloqueos de stdout/stderr.
#    - Respaldo y restauracion de ISO/hash anteriores.
#    - Inyeccion y segura de autounattend.xml.
#    - Hash SHA-256 y logs detallados por compilacion.
#    - Arquitectura desconocida segura: nunca se asume X64.
#    - Validacion estructural y DISM de conjuntos install*.swm.
#    - Huella profunda y revalidacion sincronica durante preflight.
#    - Firma Authenticode y SHA-256 del motor oscdimg.exe.
#    - Verificacion post-build de arranque, imagen, etiqueta e inyecciones.
#
#  NO modificar la firma Show-IsoMaker-GUI; el nucleo la invoca por nombre.
#
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

function Show-IsoMaker-GUI {

    # Adaptador de registro: utiliza Write-Log del nucleo y mantiene un respaldo
    # local cuando el modulo se prueba de forma independiente.
    function Write-IsoMakerLog {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)]
            [ValidateSet('INFO','ACTION','WARN','ERROR')]
            [string]$LogLevel,

            [Parameter(Mandatory=$true)]
            [string]$Message
        )

        try {
            $coreLogger = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $coreLogger) {
                Write-Log -LogLevel $LogLevel -Message $Message
                return
            }
        } catch {}

        try {
            if (-not $script:IsoMaker_fallbackLog) {
                $fallbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'IsoMakerLogs'
                if (-not (Test-Path -LiteralPath $fallbackRoot -PathType Container)) {
                    New-Item -Path $fallbackRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                $script:IsoMaker_fallbackLog = Join-Path $fallbackRoot 'Registro.log'
            }
            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            "[$stamp] [$LogLevel] - $Message" | Out-File -FilePath $script:IsoMaker_fallbackLog -Append -Encoding utf8
        } catch {
            Write-Warning "ISO_Maker: No se pudo registrar el evento: $Message"
        }
    }

    # El modulo puede cargarse por dot-sourcing: nunca usar exit, porque cerraria
    # tambien AdminImagenOffline. Las validaciones terminan solo esta funcion.
    $isWindowsPlatform = ($PSVersionTable.PSEdition -eq 'Desktop') -or
                         ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)
    if (-not $isWindowsPlatform) {
        Write-IsoMakerLog -LogLevel ERROR -Message 'ISO_Maker: Este modulo solo puede ejecutarse en Windows.'
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    } catch {
        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo cargar System.Windows.Forms: $($_.Exception.Message)"
        return
    }

    $isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdministrator) {
        Write-IsoMakerLog -LogLevel WARN -Message 'ISO_Maker: Se requieren permisos de Administrador.'
        [System.Windows.Forms.MessageBox]::Show(
            "El Generador de ISO requiere permisos de Administrador para leer WIM/ESD, preparar archivos temporales y ejecutar oscdimg.exe.`n`nAbre AdminImagenOffline mediante 'Ejecutar como administrador'.",
            'ISO Maker - Permisos requeridos',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    # Directorio de logs individuales de oscdimg. Respeta $script:logDir heredado.
    try {
        $inheritedLogDir = Get-Variable -Name logDir -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $inheritedLogDir -and -not [string]::IsNullOrWhiteSpace([string]$inheritedLogDir.Value)) {
            $script:IsoMaker_logDir = [System.IO.Path]::GetFullPath([string]$inheritedLogDir.Value)
        } else {
            $moduleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
            $script:IsoMaker_logDir = Join-Path (Split-Path -Parent $moduleRoot) 'Logs'
        }
        if (-not (Test-Path -LiteralPath $script:IsoMaker_logDir -PathType Container)) {
            New-Item -Path $script:IsoMaker_logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        $script:IsoMaker_logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'IsoMakerLogs'
        New-Item -Path $script:IsoMaker_logDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo usar el directorio de Logs del nucleo. Se usara: $script:IsoMaker_logDir"
    }

    Write-IsoMakerLog -LogLevel INFO -Message '================================================='
    Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker iniciado en modo Administrador."

    # Reiniciar el estado propio del modulo para evitar residuos de una ejecucion
    # anterior y mantener compatibilidad con Set-StrictMode del nucleo.
    $isoMakerRuntimeState = @(
        'AnalyzeSrc','CaptureInterruptedBuildLog','CleanupInjectedFiles','DisposeIsoProcess','FinalizeIsoOutput',
        'InitializeInjectionState','NewBootOrderFile','PrepareInjectionTarget',
        'QuoteWindowsArgument','RemoveBootOrderFile',
        'RestoreCompileUI','SetPhase','StartOscdimgAttempt','UpdateDiskSpace',
        'UpdateValidation','analyzedSource','attemptIndex','attemptOutLogBuilder',
        'bootOrderFile','buildAttempts','buildDone','cdAngle','cleanLogBuilder',
        'detectedArchitecture','dismHandle','dismPS','dismQueue','dismRS','dismTimer',
        'errLogBuilder','errQueue','hashHandle','hashPS','hashRS','hashTimer',
        'injectedFiles','injectionBackupRoot','injectionBackups','iso','isoProc',
        'labelUserEdited','lastBuildHash','lastBuildLog','lastPct',
        'oscdimgExe','outQueue','outputTransactionStarted','pollTimer',
        'previousHashBackup','previousIsoBackup','reparsePointCount','rxPercent',
        'sizeHandle','sizePS','sizeQueue','sizeRS','sizeTimer','sourceBytes',
        'stderrHandler','stdoutHandler','sourceSnapshot','expectedIsoFiles','requireInstallImage','verificationResult','buildBootProfile'
    )
    foreach ($stateName in $isoMakerRuntimeState) {
        Set-Variable -Name ("IsoMaker_" + $stateName) -Scope Script -Value $null -Force
    }
    $form = $null

    try {
        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Iniciando interfaz grafica del generador ISO."

    # ------------------------------------------------------------------
    # 1. Busqueda de oscdimg.exe
    # ------------------------------------------------------------------
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

    # Tools se resuelve desde la raiz del proyecto. Si el modulo se aloja en
    # la carpeta Script, la dependencia se resuelve desde la raiz.
    $projectRoot = if ([string]::Equals(
        (Split-Path -Path $scriptPath -Leaf),
        'Script',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        Split-Path -Path $scriptPath -Parent
    } else {
        $scriptPath
    }

    $oscdimgPaths = @(
        (Join-Path -Path $projectRoot -ChildPath 'Tools\oscdimg.exe'),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )

    $oscdimgExe = $null
    foreach ($path in $oscdimgPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $oscdimgExe = $path; break }
    }

    if (-not $oscdimgExe) {
        $cmd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
        if ($cmd) { $oscdimgExe = $cmd.Source }
    }

    if (-not $oscdimgExe) {
        Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: oscdimg.exe no encontrado en rutas estandar. Solicitando ubicacion manual..."

        Add-Type -AssemblyName System.Windows.Forms
        $res = [System.Windows.Forms.MessageBox]::Show(
            "No se encontro 'oscdimg.exe' en las rutas estandar del ADK.`n`nDeseas buscar el ejecutable manualmente?",
            "Falta Dependencia",
            'YesNo',
            'Warning'
        )

        if ($res -eq 'Yes') {
            $ofd        = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Oscdimg (oscdimg.exe)|oscdimg.exe"
            if ($ofd.ShowDialog() -eq 'OK') {
                $oscdimgExe = $ofd.FileName
                Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: oscdimg.exe localizado manualmente por el usuario en: $oscdimgExe"
            } else {
                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: El usuario cancelo el cuadro de dialogo de busqueda manual. Saliendo."
                return
            }
        } else {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Dependencia faltante. El usuario declino buscar oscdimg.exe. Saliendo."
            $msg = "Para utilizar el Generador de ISO, es un requisito estricto contar con 'oscdimg.exe'.`n`n" +
                   "Por favor, descarga e instala el Windows Assessment and Deployment Kit (ADK)."
            [System.Windows.Forms.MessageBox]::Show($msg, "Requisito Faltante: Windows ADK", 'OK', 'Error')
            return
        }
    }

    try {
        $oscdimgItem = Get-Item -LiteralPath $oscdimgExe -ErrorAction Stop
        if ($oscdimgItem.Length -le 0) { throw "El ejecutable esta vacio." }
        $oscdimgExe = $oscdimgItem.FullName
    } catch {
        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: oscdimg.exe no es valido: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "El archivo oscdimg.exe seleccionado no es valido.`n`nDetalle:`n$($_.Exception.Message)",
            "oscdimg.exe no valido",
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    # [F4] Leer la version de oscdimg desde su encabezado PE.
    # Permite registrar exactamente que motor esta en uso y diagnosticar
    # posibles diferencias de comportamiento en UDF.
    $oscdimgVerStr = ""
    try {
        $vi = (Get-Item -LiteralPath $oscdimgExe).VersionInfo
        $oscdimgVerStr = "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: oscdimg.exe encontrado — version $oscdimgVerStr — ruta: $oscdimgExe"
    } catch {
        Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo leer la version del PE de oscdimg.exe."
    }

    # ------------------------------------------------------------------
    # 2. Cargar assemblies GUI
    # ------------------------------------------------------------------
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

# Verificar identidad e integridad del motor antes de utilizarlo.
$oscdimgHash = $null
$oscdimgSignatureStatus = 'Unknown'
$oscdimgSigner = 'Sin firmante'
try {
    $oscdimgHash = (Get-FileHash -LiteralPath $oscdimgExe -Algorithm SHA256 -ErrorAction Stop).Hash
    $signature = Get-AuthenticodeSignature -LiteralPath $oscdimgExe -ErrorAction Stop
    $oscdimgSignatureStatus = [string]$signature.Status
    if ($signature.SignerCertificate) { $oscdimgSigner = [string]$signature.SignerCertificate.Subject }
    $isTrustedMicrosoft = ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) -and
                          ($oscdimgSigner -match 'Microsoft')
    & Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: oscdimg SHA-256: $oscdimgHash | Firma: $oscdimgSignatureStatus | Firmante: $oscdimgSigner"
    if (-not $isTrustedMicrosoft) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "La firma digital de oscdimg.exe no pudo validarse como Microsoft.`n`nEstado: $oscdimgSignatureStatus`nFirmante: $oscdimgSigner`nSHA-256: $oscdimgHash`nRuta: $oscdimgExe`n`n¿Deseas continuar bajo tu responsabilidad?",
            'Verificacion de oscdimg.exe',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            & Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: Ejecucion cancelada porque oscdimg.exe no tiene una firma Microsoft valida."
            return
        }
    }
} catch {
    & Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo verificar la integridad de oscdimg.exe: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "No se pudo calcular el hash o verificar la firma de oscdimg.exe.`n`nDetalle:`n$($_.Exception.Message)",
        'oscdimg.exe no verificable', 'OK', 'Error'
    ) | Out-Null
    return
}

    # Lector asincronico puro .NET para stdout/stderr. Evita el bloqueo producido por
    # StreamReader.Peek() cuando oscdimg escribe progreso principalmente en stderr.
    if ($null -eq ("IsoMaker.ProcessOutputPump" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace IsoMaker
{
    public static class ProcessOutputPump
    {
        public static DataReceivedEventHandler CreateHandler(ConcurrentQueue<string> queue)
        {
            if (queue == null) throw new ArgumentNullException("queue");
            return delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) queue.Enqueue(e.Data);
            };
        }
    }
}
"@ -Language CSharp -ErrorAction Stop
    }

    $picCD   = $null
    $cdTimer = $null

    # Estado derivado del analisis de la fuente. Se utiliza para seleccionar
    # un perfil de arranque compatible y para aplicar el archivo BootOrder.
    $script:IsoMaker_detectedArchitecture = $null
    $script:IsoMaker_analyzedSource       = $null
    $script:IsoMaker_sourceBytes          = 0L
    $script:IsoMaker_reparsePointCount    = 0
    $script:IsoMaker_bootOrderFile        = $null
    $script:IsoMaker_sourceSnapshot       = $null
    $script:IsoMaker_expectedIsoFiles     = @()
    $script:IsoMaker_requireInstallImage  = $true
    $script:IsoMaker_verificationResult   = $null

    # ------------------------------------------------------------------
    # 3. Construccion del formulario
    # ------------------------------------------------------------------
    $uiBg        = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $uiPanel     = [System.Drawing.Color]::White
    $uiText      = [System.Drawing.Color]::White
    $uiInputText = [System.Drawing.Color]::Black
    $uiSecondary = [System.Drawing.Color]::Silver
    $uiMuted     = [System.Drawing.Color]::Gray
    $uiCyan      = [System.Drawing.Color]::Cyan
    $uiGreen     = [System.Drawing.Color]::LimeGreen
    $uiOrange    = [System.Drawing.Color]::Orange

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "ISO Maker by SOFTMAXTER"
    $form.ClientSize      = New-Object System.Drawing.Size(930, 650)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = $uiBg
    $form.ForeColor       = $uiText
    $form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::Dpi

    # --- Header ---
    $lblHeaderTitle           = New-Object System.Windows.Forms.Label
    $lblHeaderTitle.Text      = "ISO Maker"
    $lblHeaderTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $lblHeaderTitle.ForeColor = $uiText
    $lblHeaderTitle.Location  = "15, 10"
    $lblHeaderTitle.AutoSize  = $true
    $form.Controls.Add($lblHeaderTitle)

    $lblHeaderSub           = New-Object System.Windows.Forms.Label
    $lblHeaderSub.Text      = "• Creación de Medios de Instalación Windows BIOS/UEFI"
    $lblHeaderSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblHeaderSub.ForeColor = $uiSecondary
    $lblHeaderSub.Location  = "105, 18"
    $lblHeaderSub.AutoSize  = $true
    $form.Controls.Add($lblHeaderSub)

    # ================= COLUMNA IZQUIERDA =================

    # --- 1. CONFIGURACION DE IMAGEN ---
    $grpCfg           = New-Object System.Windows.Forms.GroupBox
    $grpCfg.Text      = " CONFIGURACION DE IMAGEN "
    $grpCfg.Location  = "15, 50"
    $grpCfg.Size      = "450, 190"
    $grpCfg.ForeColor = $uiCyan
    $grpCfg.BackColor = $uiBg
    $form.Controls.Add($grpCfg)

    $lblSrc           = New-Object System.Windows.Forms.Label
    $lblSrc.Text      = "CARPETA ORIGEN (boot, efi, sources...)"
    $lblSrc.Location  = "15, 25"
    $lblSrc.Size      = "425, 20"
    $lblSrc.AutoSize  = $false
    $lblSrc.BackColor = $uiBg
    $lblSrc.ForeColor = $uiSecondary
    $grpCfg.Controls.Add($lblSrc)

    $txtSrc             = New-Object System.Windows.Forms.TextBox
    $txtSrc.Location    = "15, 52"
    $txtSrc.Size        = "340, 23"
    $txtSrc.BackColor   = $uiPanel
    $txtSrc.ForeColor   = $uiInputText
    $txtSrc.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtSrc)

    $btnSrc                           = New-Object System.Windows.Forms.Button
    $btnSrc.Text                      = "Explorar..."
    $btnSrc.Location                  = "365, 51"
    $btnSrc.Size                      = "75, 25"
    $btnSrc.BackColor                 = [System.Drawing.Color]::Silver
    $btnSrc.ForeColor                 = [System.Drawing.Color]::Black
    $btnSrc.FlatStyle                 = "Flat"
    $btnSrc.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($btnSrc)

    $lblDst           = New-Object System.Windows.Forms.Label
    $lblDst.Text      = "ARCHIVO ISO DESTINO"
    $lblDst.Location  = "15, 84"
    $lblDst.Size      = "425, 20"
    $lblDst.AutoSize  = $false
    $lblDst.BackColor = $uiBg
    $lblDst.ForeColor = $uiSecondary
    $grpCfg.Controls.Add($lblDst)

    $txtDst             = New-Object System.Windows.Forms.TextBox
    $txtDst.Location    = "15, 111"
    $txtDst.Size        = "340, 23"
    $txtDst.BackColor   = $uiPanel
    $txtDst.ForeColor   = $uiInputText
    $txtDst.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtDst)

    $btnDst                           = New-Object System.Windows.Forms.Button
    $btnDst.Text                      = "Guardar"
    $btnDst.Location                  = "365, 110"
    $btnDst.Size                      = "75, 25"
    $btnDst.BackColor                 = [System.Drawing.Color]::Silver
    $btnDst.ForeColor                 = [System.Drawing.Color]::Black
    $btnDst.FlatStyle                 = "Flat"
    $btnDst.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($btnDst)

    $lblLabel           = New-Object System.Windows.Forms.Label
    $lblLabel.Text      = "ETIQUETA DE VOLUMEN:"
    $lblLabel.Location  = "15, 151"
    $lblLabel.Size      = "145, 22"
    $lblLabel.AutoSize  = $false
    $lblLabel.BackColor = $uiBg
    $lblLabel.ForeColor = $uiSecondary
    $lblLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $grpCfg.Controls.Add($lblLabel)

    $txtLabel             = New-Object System.Windows.Forms.TextBox
    $txtLabel.Location    = "165, 150"
    $txtLabel.Size        = "275, 23"
    $txtLabel.Text        = "WINDOWS_CUSTOM"
    $txtLabel.BackColor   = $uiPanel
    $txtLabel.ForeColor   = $uiInputText
    $txtLabel.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtLabel)

    # --- 2. AUTOMATIZACION OOBE ---
    $grpAuto           = New-Object System.Windows.Forms.GroupBox
    $grpAuto.Text      = " AUTOMATIZACION OOBE (Opcional) "
    $grpAuto.Location  = "15, 250"
    $grpAuto.Size      = "450, 112"
    $grpAuto.ForeColor = $uiOrange
    $grpAuto.BackColor = $uiBg
    $form.Controls.Add($grpAuto)

    $lblAutoInfo           = New-Object System.Windows.Forms.Label
    $lblAutoInfo.Text      = "INYECTAR autounattend.xml EN LA RAIZ DEL MEDIO"
    $lblAutoInfo.Location  = "15, 25"
    $lblAutoInfo.Size      = "425, 20"
    $lblAutoInfo.AutoSize  = $false
    $lblAutoInfo.BackColor = $uiBg
    $lblAutoInfo.ForeColor = $uiSecondary
    $grpAuto.Controls.Add($lblAutoInfo)

    $txtUnattend             = New-Object System.Windows.Forms.TextBox
    $txtUnattend.Location    = "15, 52"
    $txtUnattend.Size        = "340, 23"
    $txtUnattend.BackColor   = $uiPanel
    $txtUnattend.ForeColor   = $uiInputText
    $txtUnattend.BorderStyle = "FixedSingle"
    $grpAuto.Controls.Add($txtUnattend)

    $btnUnattend                           = New-Object System.Windows.Forms.Button
    $btnUnattend.Text                      = "XML..."
    $btnUnattend.Location                  = "365, 51"
    $btnUnattend.Size                      = "75, 25"
    $btnUnattend.BackColor                 = [System.Drawing.Color]::Silver
    $btnUnattend.ForeColor                 = [System.Drawing.Color]::Black
    $btnUnattend.FlatStyle                 = "Flat"
    $btnUnattend.FlatAppearance.BorderSize = 0
    $grpAuto.Controls.Add($btnUnattend)

    $lnkWeb                 = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text            = "Generador online — schneegans.de"
    $lnkWeb.Location        = "15, 84"
    $lnkWeb.Size            = "280, 22"
    $lnkWeb.AutoSize        = $false
    $lnkWeb.BackColor       = $uiBg
    $lnkWeb.LinkColor       = [System.Drawing.Color]::Yellow
    $lnkWeb.ActiveLinkColor = [System.Drawing.Color]::White
    $grpAuto.Controls.Add($lnkWeb)


    # --- 3. VALIDACION DE ORIGEN ---
    $grpVal           = New-Object System.Windows.Forms.GroupBox
    $grpVal.Text      = " VALIDACION DE ORIGEN "
    $grpVal.Location  = "15, 372"
    $grpVal.Size      = "450, 160"
    $grpVal.ForeColor = [System.Drawing.Color]::Gray
    $grpVal.BackColor = $uiBg
    $form.Controls.Add($grpVal)

    $validationFont = New-Object System.Drawing.Font("Consolas", 8.25)

    $lblValBoot           = New-Object System.Windows.Forms.Label
    $lblValBoot.Text      = "• boot\etfsboot.com"
    $lblValBoot.Location  = "10, 24"
    $lblValBoot.Size      = "430, 18"
    $lblValBoot.ForeColor = $uiMuted
    $lblValBoot.BackColor = $uiBg
    $lblValBoot.Font      = $validationFont
    $lblValBoot.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValBoot)

    $lblValEfi           = New-Object System.Windows.Forms.Label
    $lblValEfi.Text      = "• efisys.bin (UEFI)"
    $lblValEfi.Location  = "10, 46"
    $lblValEfi.Size      = "430, 18"
    $lblValEfi.ForeColor = $uiMuted
    $lblValEfi.BackColor = $uiBg
    $lblValEfi.Font      = $validationFont
    $lblValEfi.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValEfi)

    $lblValWim           = New-Object System.Windows.Forms.Label
    $lblValWim.Text      = "• sources\install.*"
    $lblValWim.Location  = "10, 68"
    $lblValWim.Size      = "430, 18"
    $lblValWim.ForeColor = $uiMuted
    $lblValWim.BackColor = $uiBg
    $lblValWim.Font      = $validationFont
    $lblValWim.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValWim)

    $lblValSpace           = New-Object System.Windows.Forms.Label
    $lblValSpace.Text      = "• Espacio libre en destino: (Esperando...)"
    $lblValSpace.Location  = "10, 90"
    $lblValSpace.Size      = "430, 18"
    $lblValSpace.ForeColor = $uiMuted
    $lblValSpace.BackColor = $uiBg
    $lblValSpace.Font      = $validationFont
    $lblValSpace.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValSpace)

    $lblValSrcSize           = New-Object System.Windows.Forms.Label
    $lblValSrcSize.Text      = "• Tamaño carpeta origen: (Esperando...)"
    $lblValSrcSize.Location  = "10, 112"
    $lblValSrcSize.Size      = "430, 18"
    $lblValSrcSize.ForeColor = $uiMuted
    $lblValSrcSize.BackColor = $uiBg
    $lblValSrcSize.Font      = $validationFont
    $lblValSrcSize.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValSrcSize)

    $lblValLang           = New-Object System.Windows.Forms.Label
    $lblValLang.Text      = "• Idioma predeterminado: (Esperando...)"
    $lblValLang.Location  = "10, 134"
    $lblValLang.Size      = "430, 18"
    $lblValLang.ForeColor = $uiMuted
    $lblValLang.BackColor = $uiBg
    $lblValLang.Font      = $validationFont
    $lblValLang.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValLang)

    # ================= COLUMNA DERECHA =================

    # --- 4. PROGRESO DE COMPILACION ---
    $grpProg           = New-Object System.Windows.Forms.GroupBox
    $grpProg.Text      = " PROGRESO DE COMPILACION "
    $grpProg.Location  = "475, 50"
    $grpProg.Size      = "440, 515"
    $grpProg.ForeColor = [System.Drawing.Color]::LightGreen
    $grpProg.BackColor = $uiBg
    $form.Controls.Add($grpProg)

    # [F4] Texto del motor incluye version de oscdimg leida del PE header.
    # Si la lectura fallo, muestra solo la ruta (comportamiento anterior).
    $motorText = if ($oscdimgVerStr) {
        "Motor: $oscdimgExe`n[v$oscdimgVerStr]"
    } else {
        "Motor: $oscdimgExe"
    }
    $lblMotorInfo           = New-Object System.Windows.Forms.Label
    $lblMotorInfo.Text      = $motorText
    $lblMotorInfo.Location  = "15, 25"
    $lblMotorInfo.Size      = "355, 42"
    $lblMotorInfo.ForeColor = $uiSecondary
    $lblMotorInfo.Font      = New-Object System.Drawing.Font("Consolas", 8.25)
    $lblMotorInfo.AutoEllipsis = $true
    $grpProg.Controls.Add($lblMotorInfo)

    # ANIMACION DE CD GIRATORIO
    $script:IsoMaker_cdAngle = 0
    $picCD          = New-Object System.Windows.Forms.PictureBox
    $picCD.Location = "385, 24"
    $picCD.Size     = "40, 40"
    $picCD.BackColor = [System.Drawing.Color]::Transparent
    $picCD.Visible   = $false
    $grpProg.Controls.Add($picCD)

    $cdTimer          = New-Object System.Windows.Forms.Timer
    $cdTimer.Interval = 40
    $cdTimer.Add_Tick({
        $script:IsoMaker_cdAngle = ($script:IsoMaker_cdAngle + 15) % 360
        $picCD.Refresh()
    })

    $picCD.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $g.TranslateTransform(20, 20)
        $g.RotateTransform($script:IsoMaker_cdAngle)
        $g.TranslateTransform(-20, -20)

        $g.FillEllipse([System.Drawing.Brushes]::MediumSpringGreen, 2, 2, 36, 36)
        $g.FillPie([System.Drawing.Brushes]::DarkSlateGray, 2, 2, 36, 36, 45, 40)
        $g.FillPie([System.Drawing.Brushes]::DarkSlateGray, 2, 2, 36, 36, 225, 40)

        $bgBrush = New-Object System.Drawing.SolidBrush($uiBg)
        $g.FillEllipse($bgBrush, 14, 14, 12, 12)
        $bgBrush.Dispose()

        $g.DrawEllipse([System.Drawing.Pens]::DarkGreen, 14, 14, 12, 12)
        $g.DrawEllipse([System.Drawing.Pens]::SeaGreen,  2,  2, 36, 36)
    })

    $lblPhase           = New-Object System.Windows.Forms.Label
    $lblPhase.Text      = "Esperando configuracion..."
    $lblPhase.Location  = "15, 82"
    $lblPhase.Size      = "410, 42"
    $lblPhase.ForeColor = $uiCyan
    $lblPhase.Font      = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
    $lblPhase.AutoEllipsis = $true
    $grpProg.Controls.Add($lblPhase)

    $pbMain          = New-Object System.Windows.Forms.ProgressBar
    $pbMain.Location = "15, 130"
    $pbMain.Size     = "410, 25"
    $pbMain.Minimum  = 0
    $pbMain.Maximum  = 100
    $pbMain.Value    = 0
    $pbMain.Style     = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $pbMain.ForeColor = $uiGreen
    $grpProg.Controls.Add($pbMain)

    $lblPercent           = New-Object System.Windows.Forms.Label
    $lblPercent.Text      = "0 % completado"
    $lblPercent.Location  = "15, 165"
    $lblPercent.AutoSize  = $true
    $lblPercent.ForeColor = $uiGreen
    $lblPercent.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $grpProg.Controls.Add($lblPercent)

    $lblFileInfo           = New-Object System.Windows.Forms.Label
    $lblFileInfo.Text      = ""
    $lblFileInfo.Location  = "15, 205"
    $lblFileInfo.Size      = "410, 20"
    $lblFileInfo.ForeColor = $uiSecondary
    $grpProg.Controls.Add($lblFileInfo)

    $lblSizeInfo           = New-Object System.Windows.Forms.Label
    $lblSizeInfo.Text      = ""
    $lblSizeInfo.Location  = "15, 232"
    $lblSizeInfo.Size      = "410, 20"
    $lblSizeInfo.ForeColor = $uiSecondary
    $grpProg.Controls.Add($lblSizeInfo)

    $lblHashInfo           = New-Object System.Windows.Forms.Label
    $lblHashInfo.Text      = ""
    $lblHashInfo.Location  = "15, 260"
    $lblHashInfo.Size      = "410, 55"
    $lblHashInfo.ForeColor = $uiGreen
    $lblHashInfo.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpProg.Controls.Add($lblHashInfo)

    # ================= FILA INFERIOR DE BOTONES =================

    $btnExportLog                            = New-Object System.Windows.Forms.Button
    $btnExportLog.Text                       = "Exportar Log"
    $btnExportLog.Location                   = "15, 575"
    $btnExportLog.Size                       = "140, 40"
    $btnExportLog.BackColor                  = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $btnExportLog.ForeColor                  = [System.Drawing.Color]::Silver
    $btnExportLog.FlatStyle                  = "Flat"
    $btnExportLog.FlatAppearance.BorderSize  = 1
    $btnExportLog.FlatAppearance.BorderColor = [System.Drawing.Color]::Gray
    $btnExportLog.Enabled                    = $false
    $form.Controls.Add($btnExportLog)

    # [F1] btnMake ocupa 590 px en reposo.
    # Al iniciar compilacion se reduce a 430 px para que aparezca btnCancel.
    $btnMake                           = New-Object System.Windows.Forms.Button
    $btnMake.Text                      = "► CREAR ISO BOOTEABLE"
    $btnMake.Location                  = "165, 575"
    $btnMake.Size                      = "590, 40"
    $btnMake.BackColor                 = [System.Drawing.Color]::SeaGreen
    $btnMake.ForeColor                 = [System.Drawing.Color]::White
    $btnMake.FlatStyle                 = "Flat"
    $btnMake.FlatAppearance.BorderSize = 0
    $btnMake.Font                      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnMake)

    # [F1] Boton Cancelar — visible solo durante la compilacion.
    # Se ubica donde estaba la mitad derecha de btnMake (605..755).
    $btnCancel                           = New-Object System.Windows.Forms.Button
    $btnCancel.Text                      = "✖  Cancelar"
    $btnCancel.Location                  = "605, 575"
    $btnCancel.Size                      = "150, 40"
    $btnCancel.BackColor                 = [System.Drawing.Color]::DarkRed
    $btnCancel.ForeColor                 = [System.Drawing.Color]::White
    $btnCancel.FlatStyle                 = "Flat"
    $btnCancel.FlatAppearance.BorderSize = 0
    $btnCancel.Font                      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnCancel.Visible                   = $false
    $form.Controls.Add($btnCancel)

    $btnOpenFolder                           = New-Object System.Windows.Forms.Button
    $btnOpenFolder.Text                      = ">> Abrir carpeta de la imagen generada"
    $btnOpenFolder.Location                  = "15, 620"
    $btnOpenFolder.Size                      = "880, 25"
    $btnOpenFolder.BackColor                 = [System.Drawing.Color]::FromArgb(0, 80, 0)
    $btnOpenFolder.ForeColor                 = [System.Drawing.Color]::LimeGreen
    $btnOpenFolder.FlatStyle                 = "Flat"
    $btnOpenFolder.FlatAppearance.BorderSize = 0
    $btnOpenFolder.Visible                   = $false
    $form.Controls.Add($btnOpenFolder)

    # Tooltips: conservan la información completa cuando una ruta o estado es
    # demasiado largo para el ancho disponible, sin llenar la interfaz de texto.
    $uiToolTip = New-Object System.Windows.Forms.ToolTip
    $uiToolTip.AutoPopDelay = 15000
    $uiToolTip.InitialDelay = 350
    $uiToolTip.ReshowDelay  = 100
    $uiToolTip.ShowAlways   = $true
    $uiToolTip.SetToolTip($lblMotorInfo, $motorText)
    foreach ($statusLabel in @($lblValBoot, $lblValEfi, $lblValWim, $lblValSpace, $lblValSrcSize, $lblValLang, $lblPhase, $lblFileInfo, $lblSizeInfo, $lblHashInfo)) {
        $statusLabel.Add_MouseEnter({
            try { $uiToolTip.SetToolTip($this, $this.Text) } catch {}
        })
    }

    # ------------------------------------------------------------------
    # 4. Helpers de UI
    # ------------------------------------------------------------------

    $script:IsoMaker_SetPhase = {
        param([string]$Text, [System.Drawing.Color]$Color = $uiCyan)
        $lblPhase.Text      = $Text
        $lblPhase.ForeColor = $Color
        try { $uiToolTip.SetToolTip($lblPhase, $Text) } catch {}
        $form.Refresh()
    }

    # Helper: restablecer barra de progreso al modo normal (Continuous) y
    # los botones de compilacion a su estado de reposo.
    # Usado por los paths de exito, error, cancelacion y excepcion.
    $script:IsoMaker_RestoreCompileUI = {
        if ($null -ne $cdTimer -and -not $cdTimer.IsDisposed) { try { $cdTimer.Stop() } catch {} }
        if ($null -ne $picCD   -and -not $picCD.IsDisposed)   { $picCD.Visible = $false }
        if ($null -ne $btnCancel -and -not $btnCancel.IsDisposed) { $btnCancel.Visible = $false }
        if ($null -ne $btnMake   -and -not $btnMake.IsDisposed)   { $btnMake.Size = "590, 40" }
        if ($null -ne $form -and -not $form.IsDisposed) {
            $btnMake.Enabled  = $true
            $grpCfg.Enabled   = $true
            $grpAuto.Enabled  = $true
            $form.Cursor      = [System.Windows.Forms.Cursors]::Default
        }
    }

    # Libera el proceso y sus lectores asincronicos sin dejar callbacks asociados.
    $script:IsoMaker_DisposeIsoProcess = {
        param([bool]$KillProcess = $false)

        if ($null -ne $script:IsoMaker_isoProc) {
            if ($KillProcess) {
                try {
                    if (-not $script:IsoMaker_isoProc.HasExited) {
                        $script:IsoMaker_isoProc.Kill()
                        # Esperar brevemente permite que los callbacks asincronicos
                        # entreguen las ultimas lineas antes de liberar el proceso.
                        [void]$script:IsoMaker_isoProc.WaitForExit(3000)
                    }
                } catch {}
            }
            try { $script:IsoMaker_isoProc.CancelOutputRead() } catch {}
            try { $script:IsoMaker_isoProc.CancelErrorRead()  } catch {}
            if ($null -ne $script:IsoMaker_stdoutHandler) {
                try { $script:IsoMaker_isoProc.remove_OutputDataReceived($script:IsoMaker_stdoutHandler) } catch {}
            }
            if ($null -ne $script:IsoMaker_stderrHandler) {
                try { $script:IsoMaker_isoProc.remove_ErrorDataReceived($script:IsoMaker_stderrHandler) } catch {}
            }
            try { $script:IsoMaker_isoProc.Dispose() } catch {}
        }
        $script:IsoMaker_isoProc       = $null
        $script:IsoMaker_stdoutHandler = $null
        $script:IsoMaker_stderrHandler = $null
    }

    # Conserva la salida disponible cuando el usuario cancela o fuerza el cierre.
    # De esta forma Exportar Log nunca apunta a una compilacion anterior y queda
    # evidencia suficiente para diagnosticar una interrupcion voluntaria.
    $script:IsoMaker_CaptureInterruptedBuildLog = {
        param(
            [string]$ResultText = 'CANCELADO POR EL USUARIO',
            [string]$FilePrefix = 'ISO_Build_CANCELLED'
        )

        try {
            $line = $null
            if ($null -ne $script:IsoMaker_outQueue -and $null -ne $script:IsoMaker_attemptOutLogBuilder) {
                while ($script:IsoMaker_outQueue.TryDequeue([ref]$line)) {
                    [void]$script:IsoMaker_attemptOutLogBuilder.AppendLine($line)
                }
            }
            if ($null -ne $script:IsoMaker_errQueue -and $null -ne $script:IsoMaker_errLogBuilder) {
                while ($script:IsoMaker_errQueue.TryDequeue([ref]$line)) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        [void]$script:IsoMaker_errLogBuilder.AppendLine($line)
                    }
                }
            }

            if ($null -eq $script:IsoMaker_cleanLogBuilder) {
                $script:IsoMaker_cleanLogBuilder = New-Object System.Text.StringBuilder
                [void]$script:IsoMaker_cleanLogBuilder.AppendLine('COMPILACION ISO INTERRUMPIDA')
            }

            if ($null -ne $script:IsoMaker_attemptOutLogBuilder) {
                $partialOutput = $script:IsoMaker_attemptOutLogBuilder.ToString()
                if (-not [string]::IsNullOrEmpty($partialOutput)) {
                    [void]$script:IsoMaker_cleanLogBuilder.Append($partialOutput)
                }
            }

            [void]$script:IsoMaker_cleanLogBuilder.AppendLine('')
            [void]$script:IsoMaker_cleanLogBuilder.AppendLine("RESULTADO: $ResultText")

            if ($null -ne $script:IsoMaker_errLogBuilder) {
                $partialError = $script:IsoMaker_errLogBuilder.ToString().Trim()
                if (-not [string]::IsNullOrWhiteSpace($partialError)) {
                    [void]$script:IsoMaker_cleanLogBuilder.AppendLine('SALIDA STDERR DISPONIBLE:')
                    [void]$script:IsoMaker_cleanLogBuilder.AppendLine($partialError)
                }
            }

            $script:IsoMaker_lastBuildLog = $script:IsoMaker_cleanLogBuilder.ToString()
            if (-not [string]::IsNullOrWhiteSpace($script:IsoMaker_lastBuildLog) -and
                $script:IsoMaker_logDir -and
                (Test-Path -LiteralPath $script:IsoMaker_logDir -PathType Container)) {
                $interruptedLog = Join-Path $script:IsoMaker_logDir ("{0}_{1}.log" -f $FilePrefix, (Get-Date -Format 'yyyyMMdd_HHmmss'))
                [System.IO.File]::WriteAllText(
                    $interruptedLog,
                    $script:IsoMaker_lastBuildLog,
                    ([System.Text.UTF8Encoding]::new($true))
                )
                Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Log de compilacion interrumpida guardado en: $interruptedLog"
                return $interruptedLog
            }
        } catch {
            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo conservar el log parcial: $($_.Exception.Message)"
        }
        return $null
    }

    # Cita un argumento conforme a las reglas de CommandLineToArgvW. En especial,
    # duplica las barras finales para que una ruta raiz como C:\ no escape la comilla.
    $script:IsoMaker_QuoteWindowsArgument = {
        param([Parameter(Mandatory=$true)][string]$Value)
        if ($Value.IndexOf([char]34) -ge 0) {
            throw "La ruta contiene un caracter de comillas no valido: $Value"
        }
        $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }

    # El archivo de orden mantiene los componentes de arranque al principio de la
    # imagen. Microsoft lo exige para imagenes mayores de 4.5 GB; ISO Maker lo genera
    # siempre porque no perjudica a imagenes menores y evita depender de una estimacion.
    $script:IsoMaker_RemoveBootOrderFile = {
        if ($script:IsoMaker_bootOrderFile -and (Test-Path -LiteralPath $script:IsoMaker_bootOrderFile)) {
            try {
                Remove-Item -LiteralPath $script:IsoMaker_bootOrderFile -Force -ErrorAction Stop
            } catch {
                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo eliminar BootOrder temporal '$script:IsoMaker_bootOrderFile': $($_.Exception.Message)"
            }
        }
        $script:IsoMaker_bootOrderFile = $null
    }

    $script:IsoMaker_NewBootOrderFile = {
        param([Parameter(Mandatory=$true)][string]$SourcePath)

        & $script:IsoMaker_RemoveBootOrderFile

        $candidates = @(
            'boot\bcd',
            'boot\boot.sdi',
            'boot\bootfix.bin',
            'boot\bootsect.exe',
            'boot\etfsboot.com',
            'boot\memtest.efi',
            'boot\memtest.exe',
            'efi\microsoft\boot\bcd',
            'efi\microsoft\boot\efisys.bin',
            'efi\microsoft\boot\efisys_noprompt.bin',
            'efi\boot\bootia32.efi',
            'efi\boot\bootx64.efi',
            'efi\boot\bootaa64.efi',
            'sources\boot.wim'
        )

        $orderedFiles = @(
            $candidates | Where-Object {
                Test-Path -LiteralPath (Join-Path $SourcePath $_) -PathType Leaf
            }
        )
        if ($orderedFiles.Count -eq 0) {
            throw "No se encontraron archivos de arranque para generar BootOrder.txt."
        }

        # Oscdimg documenta -yo<archivo> sin espacios. Para maximizar la
        # compatibilidad con analizadores de argumentos antiguos, crear el archivo
        # temporal en una ruta corta y sin espacios y pasarla sin comillas.
        $tempRoots = @(
            (Join-Path $env:SystemRoot 'Temp'),
            (Join-Path $env:SystemDrive 'IsoMakerTemp'),
            ([System.IO.Path]::GetTempPath())
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $tempRoot = $null
        foreach ($candidateRoot in $tempRoots) {
            try {
                $candidateFull = [System.IO.Path]::GetFullPath($candidateRoot)
                if ($candidateFull -match '\s') { continue }
                if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) {
                    New-Item -Path $candidateFull -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                $probe = Join-Path $candidateFull "IsoMaker_$([guid]::NewGuid().ToString('N')).tmp"
                [System.IO.File]::WriteAllText($probe, 'OK', [System.Text.Encoding]::ASCII)
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                $tempRoot = $candidateFull
                break
            } catch {}
        }
        if (-not $tempRoot) {
            throw "No se encontró una carpeta temporal escribible y sin espacios para BootOrder.txt."
        }

        $tempName = "IsoMaker_BootOrder_$([guid]::NewGuid().ToString('N')).txt"
        $script:IsoMaker_bootOrderFile = Join-Path $tempRoot $tempName
        $content = ($orderedFiles -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText(
            $script:IsoMaker_bootOrderFile,
            $content,
            [System.Text.Encoding]::ASCII
        )
        return $script:IsoMaker_bootOrderFile
    }

    # Transaccion ligera para el archivo de salida. Si se reemplaza una ISO previa,
    # se renombra temporalmente en el mismo volumen y se restaura ante fallo/cancelacion.
    $script:IsoMaker_FinalizeIsoOutput = {
        param([bool]$Success)

        # No tocar archivos cuando la transaccion de salida nunca comenzo.
        # Esto evita eliminar una ISO existente solo por cerrar el formulario.
        $transactionActive = [bool]$script:IsoMaker_outputTransactionStarted -or
                             -not [string]::IsNullOrWhiteSpace([string]$script:IsoMaker_previousIsoBackup) -or
                             -not [string]::IsNullOrWhiteSpace([string]$script:IsoMaker_previousHashBackup)
        if (-not $transactionActive) { return }

        $hashPath = if ($script:IsoMaker_iso) { [System.IO.Path]::ChangeExtension($script:IsoMaker_iso, '.sha256') } else { $null }

        # Si fallo la preparacion de los respaldos antes de lanzar oscdimg,
        # restaurar exclusivamente lo que ya se habia movido. No borrar las
        # rutas de destino porque aun pueden contener los archivos originales.
        if (-not [bool]$script:IsoMaker_outputTransactionStarted) {
            if ($script:IsoMaker_previousIsoBackup -and (Test-Path -LiteralPath $script:IsoMaker_previousIsoBackup)) {
                if (-not (Test-Path -LiteralPath $script:IsoMaker_iso)) {
                    try { Move-Item -LiteralPath $script:IsoMaker_previousIsoBackup -Destination $script:IsoMaker_iso -Force -ErrorAction Stop } catch {
                        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo restaurar la ISO durante la preparacion: $($_.Exception.Message)"
                    }
                } else {
                    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se restauro '$script:IsoMaker_previousIsoBackup' porque el destino '$script:IsoMaker_iso' ya existe."
                }
            }
            if ($script:IsoMaker_previousHashBackup -and (Test-Path -LiteralPath $script:IsoMaker_previousHashBackup)) {
                if (-not (Test-Path -LiteralPath $hashPath)) {
                    try { Move-Item -LiteralPath $script:IsoMaker_previousHashBackup -Destination $hashPath -Force -ErrorAction Stop } catch {
                        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo restaurar el hash durante la preparacion: $($_.Exception.Message)"
                    }
                } else {
                    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se restauro '$script:IsoMaker_previousHashBackup' porque el destino '$hashPath' ya existe."
                }
            }
            $script:IsoMaker_previousIsoBackup        = $null
            $script:IsoMaker_previousHashBackup       = $null
            $script:IsoMaker_outputTransactionStarted = $false
            return
        }

        if ($Success) {
            foreach ($backup in @($script:IsoMaker_previousIsoBackup, $script:IsoMaker_previousHashBackup)) {
                if ($backup -and (Test-Path -LiteralPath $backup)) {
                    try { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop } catch {
                        Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo eliminar el respaldo temporal '$backup': $($_.Exception.Message)"
                    }
                }
            }
        } else {
            if ($script:IsoMaker_iso -and (Test-Path -LiteralPath $script:IsoMaker_iso)) {
                try { Remove-Item -LiteralPath $script:IsoMaker_iso -Force -ErrorAction Stop } catch {
                    Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo retirar la ISO parcial '$script:IsoMaker_iso': $($_.Exception.Message)"
                }
            }
            if ($hashPath -and (Test-Path -LiteralPath $hashPath)) {
                try { Remove-Item -LiteralPath $hashPath -Force -ErrorAction Stop } catch {
                    Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo retirar el hash parcial '$hashPath': $($_.Exception.Message)"
                }
            }
            if ($script:IsoMaker_previousIsoBackup -and (Test-Path -LiteralPath $script:IsoMaker_previousIsoBackup)) {
                try { Move-Item -LiteralPath $script:IsoMaker_previousIsoBackup -Destination $script:IsoMaker_iso -Force -ErrorAction Stop } catch {
                    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo restaurar la ISO anterior: $($_.Exception.Message)"
                }
            }
            if ($script:IsoMaker_previousHashBackup -and (Test-Path -LiteralPath $script:IsoMaker_previousHashBackup)) {
                try { Move-Item -LiteralPath $script:IsoMaker_previousHashBackup -Destination $hashPath -Force -ErrorAction Stop } catch {
                    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo restaurar el hash anterior: $($_.Exception.Message)"
                }
            }
        }
        $script:IsoMaker_previousIsoBackup       = $null
        $script:IsoMaker_previousHashBackup      = $null
        $script:IsoMaker_outputTransactionStarted = $false
    }

# ------------------------------------------------------------------
# Helpers de integridad, arquitectura, SWM, huella y verificacion ISO
# ------------------------------------------------------------------
$script:IsoMaker_GetStringSha256 = {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

$script:IsoMaker_ResolveArchitecture = {
    param([string]$ArchitectureValue, [string]$SourcePath)

    $normalized = if ([string]::IsNullOrWhiteSpace($ArchitectureValue)) { '' } else { $ArchitectureValue.Trim().ToUpperInvariant() }
    $known = switch -Regex ($normalized) {
        '^(0|X86|INTEL)$'      { 'X86'; break }
        '^(9|X64|AMD64)$'      { 'X64'; break }
        '^(12|ARM64|AARCH64)$' { 'ARM64'; break }
        default                { $null }
    }
    if ($known) { return $known }

    $detected = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        if (Test-Path -LiteralPath (Join-Path $SourcePath 'efi\boot\bootaa64.efi') -PathType Leaf) { $detected.Add('ARM64') }
        if (Test-Path -LiteralPath (Join-Path $SourcePath 'efi\boot\bootx64.efi')  -PathType Leaf) { $detected.Add('X64') }
        if (Test-Path -LiteralPath (Join-Path $SourcePath 'efi\boot\bootia32.efi') -PathType Leaf) { $detected.Add('X86') }
    }
    $unique = @($detected | Select-Object -Unique)
    if ($unique.Count -eq 1) { return [string]$unique[0] }
    return 'DESCONOCIDA'
}

$script:IsoMaker_GetSwmSetInfo = {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [bool]$ValidateWithDism = $false
    )

    $result = [ordered]@{
        Exists       = $false
        Valid        = $false
        PartCount    = 0
        TotalBytes   = 0L
        ImageCount   = 0
        BasePath     = $null
        Pattern      = $null
        Parts        = @()
        MissingParts = @()
        Errors       = @()
        Summary      = 'No se encontro un conjunto SWM.'
    }

    try {
        $sourcesDir = Join-Path $SourcePath 'sources'
        if (-not (Test-Path -LiteralPath $sourcesDir -PathType Container)) { return [pscustomobject]$result }

        $allCandidates = @(Get-ChildItem -LiteralPath $sourcesDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue)
        if ($allCandidates.Count -eq 0) { return [pscustomobject]$result }
        $result.Exists = $true

        $numbered = @{}
        foreach ($file in $allCandidates) {
            if ($file.Name -notmatch '^install(?<n>\d*)\.swm$') {
                $result.Errors += "Nombre SWM no valido: $($file.Name)"
                continue
            }
            $part = if ([string]::IsNullOrWhiteSpace($matches['n'])) { 1 } else { [int]$matches['n'] }
            if ($part -lt 1) {
                $result.Errors += "Numero de parte SWM no valido: $($file.Name)"
                continue
            }
            if ($numbered.ContainsKey($part)) {
                $result.Errors += "Parte SWM duplicada: $part"
                continue
            }
            if ($file.Length -le 0) { $result.Errors += "Parte SWM vacia: $($file.Name)" }
            $numbered[$part] = $file
            $result.TotalBytes += [long]$file.Length
        }

        if (-not $numbered.ContainsKey(1) -or $numbered[1].Name -ine 'install.swm') {
            $result.Errors += 'Falta sources\install.swm, que debe ser la primera parte del conjunto.'
        }

        if ($numbered.Count -gt 0) {
            $maxPart = [int](($numbered.Keys | Measure-Object -Maximum).Maximum)
            for ($n = 1; $n -le $maxPart; $n++) {
                if (-not $numbered.ContainsKey($n)) { $result.MissingParts += $n }
            }
            if ($result.MissingParts.Count -gt 0) {
                $result.Errors += "Faltan partes SWM: $($result.MissingParts -join ', ')"
            }
            $result.Parts = @($numbered.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value.FullName })
            $result.PartCount = $result.Parts.Count
            $result.BasePath = if ($numbered.ContainsKey(1)) { $numbered[1].FullName } else { $null }
            $result.Pattern = Join-Path $sourcesDir 'install*.swm'
        }

        if ($result.Errors.Count -eq 0 -and $ValidateWithDism -and $result.BasePath) {
            # Validar siempre el conjunto completo mediante /SWMFile:<patron>.
            # Leer solo install.swm no garantiza que DISM haya abierto todas las partes.
            $readable = $false
            $dismCmd = Get-Command dism.exe -ErrorAction SilentlyContinue
            if ($dismCmd) {
                $dismOutput = @(& $dismCmd.Source '/English' '/Get-ImageInfo' "/ImageFile:$($result.BasePath)" "/SWMFile:$($result.Pattern)" 2>&1)
                $dismExitCode = $LASTEXITCODE
                if ($dismExitCode -eq 0) {
                    $result.ImageCount = @($dismOutput | Where-Object { [string]$_ -match '^\s*Index\s*:' }).Count
                    $readable = ($result.ImageCount -gt 0)
                    if (-not $readable) {
                        $result.Errors += 'DISM proceso el conjunto SWM, pero no devolvio ningun indice.'
                    }
                } else {
                    $detail = @($dismOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 6) -join ' | '
                    $result.Errors += ("DISM no pudo leer el conjunto SWM (codigo $dismExitCode). $detail").Trim()
                }
            } else {
                $result.Errors += 'No se encontro dism.exe para validar el conjunto SWM completo.'
            }
            if (-not $readable -and $result.Errors.Count -eq 0) {
                $result.Errors += 'DISM no devolvio indices para el conjunto SWM.'
            }
        }

        $result.Valid = ($result.Errors.Count -eq 0)
        if ($result.Valid) {
            $imagesText = if ($result.ImageCount -gt 0) { " | $($result.ImageCount) indices" } else { '' }
            $result.Summary = "Conjunto SWM valido: $($result.PartCount) partes$imagesText"
        } else {
            $result.Summary = "Conjunto SWM no valido: $($result.Errors -join ' | ')"
        }
    } catch {
        $result.Errors += $_.Exception.Message
        $result.Valid = $false
        $result.Summary = "No se pudo validar SWM: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}

$script:IsoMaker_NormalizeDirectoryPath = {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    return $full.TrimEnd([char[]]@('\','/'))
}

$script:IsoMaker_GetQuickSourceFingerprint = {
    param([Parameter(Mandatory=$true)][string]$SourcePath)
    $full = & $script:IsoMaker_NormalizeDirectoryPath $SourcePath
    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("PATH|$full")
    foreach ($relative in @('', 'sources', 'boot', 'efi', 'sources\boot.wim', 'sources\install.wim', 'sources\install.esd', 'sources\lang.ini')) {
        $candidate = if ([string]::IsNullOrEmpty($relative)) { $full } else { Join-Path $full $relative }
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            if ($item) {
                $length = if ($item.PSIsContainer) { 0L } else { [long]$item.Length }
                $items.Add("$relative|$length|$($item.LastWriteTimeUtc.Ticks)")
            }
        } else {
            $items.Add("$relative|MISSING")
        }
    }
    $sources = Join-Path $full 'sources'
    if (Test-Path -LiteralPath $sources -PathType Container) {
        foreach ($swm in @(Get-ChildItem -LiteralPath $sources -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $items.Add("SWM|$($swm.Name)|$($swm.Length)|$($swm.LastWriteTimeUtc.Ticks)")
        }
    }
    $material = $items -join "`n"
    return [pscustomobject]@{
        Path     = $full
        Value    = (& $script:IsoMaker_GetStringSha256 $material)
        Material = $material
    }
}

$script:IsoMaker_GetSourceSnapshot = {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [scriptblock]$ProgressCallback = $null
    )

    $full = & $script:IsoMaker_NormalizeDirectoryPath $SourcePath
    $bytes = 0L; $files = 0; $dirs = 0; $reparse = 0; $latestTicks = 0L
    $metadata = New-Object System.Collections.Generic.List[string]
    $lastProgress = [DateTime]::UtcNow

    Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop | ForEach-Object {
        $isReparse = (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($isReparse) { $reparse++ }
        if ($_.PSIsContainer) { $dirs++; $kind = 'D'; $length = 0L } else { $files++; $kind = 'F'; $length = [long]$_.Length; $bytes += $length }
        if ($_.LastWriteTimeUtc.Ticks -gt $latestTicks) { $latestTicks = $_.LastWriteTimeUtc.Ticks }

        $relative = $_.FullName.Substring($full.Length).TrimStart([char[]]@('\','/'))
        $metadata.Add("$relative|$kind|$length|$($_.LastWriteTimeUtc.Ticks)|$([int]$_.Attributes)")

        if ($ProgressCallback -and (([DateTime]::UtcNow - $lastProgress).TotalMilliseconds -ge 250)) {
            & $ProgressCallback $files $dirs $bytes
            $lastProgress = [DateTime]::UtcNow
        }
    }

    if ($ProgressCallback) { & $ProgressCallback $files $dirs $bytes }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $encoding = [System.Text.Encoding]::UTF8
        foreach ($line in @($metadata | Sort-Object)) {
            $buffer = $encoding.GetBytes($line + "`n")
            [void]$sha.TransformBlock($buffer, 0, $buffer.Length, $buffer, 0)
        }
        $empty = [byte[]]@()
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        $metadataFingerprint = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }

    $quick = & $script:IsoMaker_GetQuickSourceFingerprint $full
    $material = "$full|$bytes|$files|$dirs|$reparse|$latestTicks|$($quick.Value)|$metadataFingerprint"
    return [pscustomobject]@{
        Path = $full; Bytes = $bytes; FileCount = $files; DirCount = $dirs
        ReparsePointCount = $reparse; LatestWriteTicks = $latestTicks
        QuickFingerprint = $quick.Value; MetadataFingerprint = $metadataFingerprint
        FullFingerprint = (& $script:IsoMaker_GetStringSha256 $material)
    }
}



$script:IsoMaker_TestIsoImage = {
    param(
        [Parameter(Mandatory=$true)][string]$IsoPath,
        [Parameter(Mandatory=$true)][ValidateSet('BIOS','UEFI','DUAL')][string]$BootProfile,
        [bool]$RequireInstallImage = $true,
        [string[]]$ExpectedFiles = @(),
        [string]$ExpectedVolumeLabel = $null
    )

    $result = [ordered]@{ Valid = $false; Root = $null; Checks = @(); Errors = @(); Warnings = @() }
    $diskImage = $null
    $mountedByIsoCore = $false
    $isNonEmptyFile = {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        try { return ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length -gt 0) } catch { return $false }
    }

    try {
        if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw 'La ISO que se intentara verificar no existe.' }
        if ((Get-Item -LiteralPath $IsoPath -ErrorAction Stop).Length -le 0) { throw 'La ISO que se intentara verificar esta vacia.' }
        if (-not (Get-Command Mount-DiskImage -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-DiskImage -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
            throw 'Los cmdlets Mount-DiskImage, Get-DiskImage o Get-Volume no estan disponibles.'
        }

        $diskImage = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        if ($null -eq $diskImage -or -not $diskImage.Attached) {
            $diskImage = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
            $mountedByIsoCore = $true
        }

        $volumes = @()
        for ($retry = 0; $retry -lt 20 -and $volumes.Count -eq 0; $retry++) {
            $volumes = @($diskImage | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
            if ($volumes.Count -eq 0) { Start-Sleep -Milliseconds 250 }
        }
        if ($volumes.Count -eq 0) { throw 'La ISO se monto, pero no se obtuvo una letra de unidad.' }

        $root = "$($volumes[0].DriveLetter):\"
        $result.Root = $root
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVolumeLabel)) {
            $actualLabel = [string]$volumes[0].FileSystemLabel
            $labelMatches = [string]::Equals($actualLabel, $ExpectedVolumeLabel, [StringComparison]::OrdinalIgnoreCase)
            $result.Checks += [pscustomobject]@{ Item="Etiqueta de volumen ($ExpectedVolumeLabel)"; Present=$labelMatches }
            if (-not $labelMatches) { $result.Errors += "La etiqueta de volumen es '$actualLabel' y se esperaba '$ExpectedVolumeLabel'." }
        }
        $fileSystem = [string]$volumes[0].FileSystem
        if (-not [string]::IsNullOrWhiteSpace($fileSystem) -and $fileSystem -notmatch '^UDF') {
            $result.Warnings += "El sistema de archivos montado se identifico como '$fileSystem' en lugar de UDF."
        }

        $required = New-Object System.Collections.Generic.List[string]
        $required.Add('sources\boot.wim')
        if ($BootProfile -in @('BIOS','DUAL')) { $required.Add('boot\etfsboot.com') }
        if ($BootProfile -in @('UEFI','DUAL')) {
            $efiStandard = Join-Path $root 'efi\microsoft\boot\efisys.bin'
            $efiNoPrompt = Join-Path $root 'efi\microsoft\boot\efisys_noprompt.bin'
            $hasEfi = (& $isNonEmptyFile $efiStandard) -or (& $isNonEmptyFile $efiNoPrompt)
            $result.Checks += [pscustomobject]@{ Item='Arranque UEFI'; Present=$hasEfi }
            if (-not $hasEfi) { $result.Errors += 'No se encontro una imagen de arranque UEFI valida dentro de la ISO.' }
        }

        foreach ($relative in $required) {
            $present = & $isNonEmptyFile (Join-Path $root $relative)
            $result.Checks += [pscustomobject]@{ Item=$relative; Present=$present }
            if (-not $present) { $result.Errors += "Falta $relative o el archivo esta vacio dentro de la ISO." }
        }

        if ($RequireInstallImage) {
            $hasWim = & $isNonEmptyFile (Join-Path $root 'sources\install.wim')
            $hasEsd = & $isNonEmptyFile (Join-Path $root 'sources\install.esd')
            $swmInfo = & $script:IsoMaker_GetSwmSetInfo $root $false
            if ($swmInfo.Exists -and -not $swmInfo.Valid) {
                $result.Errors += "El conjunto SWM dentro de la ISO no es valido: $($swmInfo.Errors -join ' | ')"
            }
            $hasInstall = $hasWim -or $hasEsd -or ($swmInfo.Exists -and $swmInfo.Valid)
            $result.Checks += [pscustomobject]@{ Item='Imagen de instalacion'; Present=$hasInstall }
            if (-not $hasInstall) { $result.Errors += 'No se encontro install.wim, install.esd ni un conjunto install*.swm valido dentro de la ISO.' }
        }

        foreach ($relative in @($ExpectedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $cleanRelative = ([string]$relative).TrimStart([char[]]@('\','/'))
            if ([System.IO.Path]::IsPathRooted($cleanRelative) -or $cleanRelative -match '(^|\\)\.\.(\\|$)' -or $cleanRelative -match ':') {
                $result.Errors += "Ruta esperada no segura durante la verificacion: $relative"
                continue
            }
            $present = Test-Path -LiteralPath (Join-Path $root $cleanRelative) -PathType Leaf
            $result.Checks += [pscustomobject]@{ Item=$cleanRelative; Present=$present }
            if (-not $present) { $result.Errors += "Falta el archivo esperado $cleanRelative dentro de la ISO." }
        }
        $result.Valid = ($result.Errors.Count -eq 0)
    } catch {
        $result.Errors += $_.Exception.Message
        $result.Valid = $false
    } finally {
        if ($mountedByIsoCore) {
            $dismounted = $false
            $lastDismountError = $null
            for ($attempt = 1; $attempt -le 4 -and -not $dismounted; $attempt++) {
                try {
                    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null
                    $dismounted = $true
                } catch {
                    $lastDismountError = $_.Exception.Message
                    Start-Sleep -Milliseconds 300
                }
            }
            if (-not $dismounted) {
                $result.Warnings += "La estructura se verifico, pero no se pudo desmontar la ISO: $lastDismountError"
            }
        }
    }
    return [pscustomobject]$result
}



    $script:IsoMaker_UpdateValidation = {
        param([string]$srcPath)
        $okC   = $uiGreen
        $errC  = [System.Drawing.Color]::Crimson
        $warnC = [System.Drawing.Color]::Orange
        $grayC = $uiMuted

        if ([string]::IsNullOrWhiteSpace($srcPath)) {
            $lblValBoot.Text = "• boot\etfsboot.com"; $lblValBoot.ForeColor = $grayC
            $lblValEfi.Text  = "• efisys.bin (UEFI)"; $lblValEfi.ForeColor  = $grayC
            $lblValWim.Text  = "• sources\install.*"; $lblValWim.ForeColor  = $grayC
            $lblValLang.Text = "• Idioma predeterminado: (Esperando...)"; $lblValLang.ForeColor = $grayC
            return
        }
        $biosPath = Join-Path $srcPath 'boot\etfsboot.com'
        $hasBoot  = (Test-Path -LiteralPath $biosPath -PathType Leaf) -and ((Get-Item -LiteralPath $biosPath -ErrorAction SilentlyContinue).Length -gt 0)
        $lblValBoot.Text      = if ($hasBoot) { "• boot\etfsboot.com (BIOS)" } else { "• boot\etfsboot.com (BIOS no disponible)" }
        $lblValBoot.ForeColor = if ($hasBoot) { $okC } else { $warnC }

        $efiStandardPath = Join-Path $srcPath 'efi\microsoft\boot\efisys.bin'
        $efiNoPromptPath = Join-Path $srcPath 'efi\microsoft\boot\efisys_noprompt.bin'
        $hasEfiStandard  = (Test-Path -LiteralPath $efiStandardPath -PathType Leaf) -and ((Get-Item -LiteralPath $efiStandardPath -ErrorAction SilentlyContinue).Length -gt 0)
        $hasEfiNoPrompt  = (Test-Path -LiteralPath $efiNoPromptPath -PathType Leaf) -and ((Get-Item -LiteralPath $efiNoPromptPath -ErrorAction SilentlyContinue).Length -gt 0)
        $hasEfi          = $hasEfiStandard -or $hasEfiNoPrompt
        $lblValEfi.Text  = if ($hasEfiStandard) {
            "• efisys.bin (UEFI)"
        } elseif ($hasEfiNoPrompt) {
            "• efisys_noprompt.bin (UEFI automático)"
        } else {
            "• Imagen de arranque UEFI no disponible"
        }
        $lblValEfi.ForeColor = if ($hasEfi) { $okC } else { $warnC }

        $hasBootWim = Test-Path -LiteralPath (Join-Path $srcPath 'sources\boot.wim') -PathType Leaf
        $hasWim = Test-Path -LiteralPath (Join-Path $srcPath 'sources\install.wim') -PathType Leaf
        $hasEsd = Test-Path -LiteralPath (Join-Path $srcPath 'sources\install.esd') -PathType Leaf
        $swmInfo = & $script:IsoMaker_GetSwmSetInfo $srcPath $false
        $hasInstall = $hasWim -or $hasEsd -or ($swmInfo.Exists -and $swmInfo.Valid)
        $lblValWim.Text = if (-not $hasBootWim) {
            "• sources\boot.wim ausente"
        } elseif ($hasWim) {
            "• boot.wim + install.wim"
        } elseif ($hasEsd) {
            "• boot.wim + install.esd"
        } elseif ($swmInfo.Exists -and $swmInfo.Valid) {
            "• boot.wim + SWM: $($swmInfo.PartCount) partes validas"
        } elseif ($swmInfo.Exists) {
            "• SWM no valido: $($swmInfo.Errors -join '; ')"
        } else {
            "• boot.wim presente | imagen de instalacion ausente"
        }
        $lblValWim.ForeColor = if (-not $hasBootWim) { $errC } elseif ($hasInstall) { $okC } else { $warnC }
    }

    $script:IsoMaker_UpdateDiskSpace = {
        param([string]$srcPath, [string]$dstPath)

        if ([string]::IsNullOrWhiteSpace($dstPath)) {
            $lblValSpace.Text      = "• Espacio libre en destino: (Esperando...)"
            $lblValSpace.ForeColor = $uiMuted
            return
        }

        try {
            $q = Split-Path -Qualifier $dstPath -ErrorAction SilentlyContinue
            if (-not $q) {
                $lblValSpace.Text      = "• Espacio libre en destino: No disponible para esta ruta"
                $lblValSpace.ForeColor = $uiMuted
                return
            }

            $drive = Get-PSDrive -Name $q.TrimEnd(':') -ErrorAction SilentlyContinue
            if (-not $drive) {
                $lblValSpace.Text      = "• Espacio libre en destino: No disponible"
                $lblValSpace.ForeColor = $uiMuted
                return
            }

            $sourceMatches = $false
            try {
                if (-not [string]::IsNullOrWhiteSpace($srcPath) -and
                    -not [string]::IsNullOrWhiteSpace([string]$script:IsoMaker_analyzedSource)) {
                    $sourceMatches = [string]::Equals(
                        (& $script:IsoMaker_NormalizeDirectoryPath $srcPath),
                        (& $script:IsoMaker_NormalizeDirectoryPath ([string]$script:IsoMaker_analyzedSource)),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
            } catch {}

            $requiredBytes = 5GB
            if ($sourceMatches -and [long]$script:IsoMaker_sourceBytes -gt 0) {
                $requiredBytes = [long][math]::Ceiling(([double]$script:IsoMaker_sourceBytes * 1.08) + 256MB)
            }

            $freeGB     = [math]::Round($drive.Free / 1GB, 1)
            $requiredGB = [math]::Round($requiredBytes / 1GB, 1)
            $lblValSpace.Text = "• Espacio libre en destino: $freeGB GB | Estimado requerido: $requiredGB GB"
            $lblValSpace.ForeColor = if ($drive.Free -ge $requiredBytes) { $uiGreen } else { [System.Drawing.Color]::Orange }
        } catch {
            $lblValSpace.Text      = "• Espacio libre en destino: No se pudo calcular"
            $lblValSpace.ForeColor = [System.Drawing.Color]::Orange
        }
    }

    $script:IsoMaker_AnalyzeSrc = {
        param([string]$srcPath)
        $txtSrc.Text = $srcPath
        # [FIX D2] Nueva carpeta origen -> permitir que DISM auto-complete la etiqueta de nuevo
        $script:IsoMaker_labelUserEdited = $false
        try { $script:IsoMaker_analyzedSource = [System.IO.Path]::GetFullPath($srcPath) } catch { $script:IsoMaker_analyzedSource = $srcPath }
        $script:IsoMaker_detectedArchitecture = $null
        $script:IsoMaker_sourceBytes          = 0L
        $script:IsoMaker_reparsePointCount    = 0
        $btnMake.Enabled = $false
        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Carpeta origen seleccionada: $srcPath"

        # ------------------------------------------------------------------
        # [FIX E1] Cancelar timers y runspaces de un analisis anterior que
        # pudiera seguir en curso. Sin esto, los timers huerfanos siguen
        # disparandose y acceden a $script:IsoMaker_sizeQueue / $script:IsoMaker_dismQueue
        # despues de que ya fueron nulificados por la segunda llamada,
        # provocando NullReferenceException en el tick ("No se puede llamar
        # a un metodo en una expresion con valor NULL").
        # ------------------------------------------------------------------
        if ($null -ne $script:IsoMaker_sizeTimer) {
            try { $script:IsoMaker_sizeTimer.Stop(); $script:IsoMaker_sizeTimer.Dispose() } catch {}
            $script:IsoMaker_sizeTimer = $null
        }
        if ($null -ne $script:IsoMaker_sizePS) {
            try { $script:IsoMaker_sizePS.Stop(); $script:IsoMaker_sizePS.Dispose() } catch {}
            $script:IsoMaker_sizePS = $null
        }
        if ($null -ne $script:IsoMaker_sizeRS) {
            try { $script:IsoMaker_sizeRS.Close(); $script:IsoMaker_sizeRS.Dispose() } catch {}
            $script:IsoMaker_sizeRS = $null
        }
        $script:IsoMaker_sizeHandle = $null
        $script:IsoMaker_sizeQueue  = $null

        if ($null -ne $script:IsoMaker_dismTimer) {
            try { $script:IsoMaker_dismTimer.Stop(); $script:IsoMaker_dismTimer.Dispose() } catch {}
            $script:IsoMaker_dismTimer = $null
        }
        if ($null -ne $script:IsoMaker_dismPS) {
            try { $script:IsoMaker_dismPS.Stop(); $script:IsoMaker_dismPS.Dispose() } catch {}
            $script:IsoMaker_dismPS = $null
        }
        if ($null -ne $script:IsoMaker_dismRS) {
            try { $script:IsoMaker_dismRS.Close(); $script:IsoMaker_dismRS.Dispose() } catch {}
            $script:IsoMaker_dismRS = $null
        }
        $script:IsoMaker_dismHandle = $null
        $script:IsoMaker_dismQueue  = $null

        # Restaurar btnSrc por si quedara desactivado de un analisis DISM previo interrumpido
        $btnSrc.Enabled = $true

        # Restaurar barra al modo Continuous si quedara atascada en Marquee
        if ($pbMain.Style -eq [System.Windows.Forms.ProgressBarStyle]::Marquee) {
            $pbMain.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $pbMain.Value = 0
        }

        & $script:IsoMaker_UpdateValidation $srcPath
        & $script:IsoMaker_UpdateDiskSpace  $srcPath $txtDst.Text

        $lblValSrcSize.Text      = "• Calculando Tamaño de la carpeta origen..."
        $lblValSrcSize.ForeColor = $uiMuted
        $lblValLang.Text         = "• Idioma predeterminado: Detectando..."
        $lblValLang.ForeColor    = $uiMuted

        # --- Calculo de Tamaño de la carpeta (async) ---
        $script:IsoMaker_sizeQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        $script:IsoMaker_sizeRS    = [runspacefactory]::CreateRunspace()
        $script:IsoMaker_sizeRS.Open()
        $script:IsoMaker_sizeRS.SessionStateProxy.SetVariable('srcPath',   $srcPath)
        $script:IsoMaker_sizeRS.SessionStateProxy.SetVariable('sizeQueue', $script:IsoMaker_sizeQueue)

        $script:IsoMaker_sizePS = [powershell]::Create()
        $script:IsoMaker_sizePS.Runspace = $script:IsoMaker_sizeRS
        [void]$script:IsoMaker_sizePS.AddScript({
            $result = @{ Bytes = 0L; Count = 0; DirCount = 0; ReparsePointCount = 0; Error = $null }
            try {
                # Recorrido unico y en streaming: evita enumerar dos veces el medio y
                # no conserva miles de FileInfo/DirectoryInfo simultaneamente en memoria.
                Get-ChildItem -LiteralPath $srcPath -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                            $result.ReparsePointCount++
                        }
                        if ($_.PSIsContainer) {
                            $result.DirCount++
                        } else {
                            $result.Count++
                            $result.Bytes += [long]$_.Length
                        }
                    }
            } catch {
                $result.Error = $_.Exception.Message
            }
            $sizeQueue.Enqueue($result)
        })
        $script:IsoMaker_sizeHandle = $script:IsoMaker_sizePS.BeginInvoke()

        $script:IsoMaker_sizeTimer          = New-Object System.Windows.Forms.Timer
        $script:IsoMaker_sizeTimer.Interval = 150
        $script:IsoMaker_sizeTimer.Add_Tick({
            if ($null -eq $script:IsoMaker_sizeQueue) { return }
            $res = $null
            if (-not $script:IsoMaker_sizeQueue.TryDequeue([ref]$res)) { return }

            $script:IsoMaker_sizeTimer.Stop()
            $script:IsoMaker_sizeTimer.Dispose()
            $script:IsoMaker_sizeTimer = $null
            try { $script:IsoMaker_sizePS.EndInvoke($script:IsoMaker_sizeHandle) } catch {}
            try { $script:IsoMaker_sizePS.Dispose()                     } catch {}
            try { $script:IsoMaker_sizeRS.Close(); $script:IsoMaker_sizeRS.Dispose() } catch {}
            $script:IsoMaker_sizePS = $null; $script:IsoMaker_sizeRS = $null
            $script:IsoMaker_sizeHandle = $null; $script:IsoMaker_sizeQueue = $null

            if ($null -ne $res.Error) {
                $lblValSrcSize.Text      = "• No se pudo calcular el Tamaño de la carpeta origen"
                $lblValSrcSize.ForeColor = [System.Drawing.Color]::Orange
                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo calcular el Tamaño de la carpeta origen: $($res.Error)"
            } else {
                $bytes = [long]$res.Bytes
                $script:IsoMaker_sourceBytes       = $bytes
                $script:IsoMaker_reparsePointCount = [int]$res.ReparsePointCount
                $strSz = if ($bytes -ge 1GB)  { "$([math]::Round($bytes/1GB, 2)) GB"  }
                         elseif ($bytes -ge 1MB) { "$([math]::Round($bytes/1MB, 1)) MB"  }
                         else   { "$bytes bytes" }
                $color = if ($bytes -ge 8GB) { [System.Drawing.Color]::Orange }  # > 8 GB: probablemente incluye drivers/updates adicionales fuera de lo habitual
                         else                { $uiGreen }
                $lblValSrcSize.Text      = "• Tamaño carpeta origen: $strSz ($($res.Count) archivos | $($res.DirCount) directorios)"
                $lblValSrcSize.ForeColor = $color
                Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Tamaño carpeta origen: $strSz ($($res.Count) archivos | $($res.DirCount) directorios) | Reparse points: $($res.ReparsePointCount)."
            }
        })
        $script:IsoMaker_sizeTimer.Start()

        # --- Extraccion de metadatos DISM (async) ---
        $installWim  = Join-Path $srcPath "sources\install.wim"
        $installEsd  = Join-Path $srcPath "sources\install.esd"
        $bootWimMeta = Join-Path $srcPath "sources\boot.wim"
        $swmInfoAnalysis = & $script:IsoMaker_GetSwmSetInfo $srcPath $false
        $targetImage = $null
        $metadataFromBootWim = $false
        if     (Test-Path -LiteralPath $installWim -PathType Leaf) { $targetImage = $installWim }
        elseif (Test-Path -LiteralPath $installEsd -PathType Leaf) { $targetImage = $installEsd }
        elseif ($swmInfoAnalysis.Exists -and $swmInfoAnalysis.Valid -and (Test-Path -LiteralPath $bootWimMeta -PathType Leaf)) {
            # Get-WindowsImage no siempre resuelve conjuntos SWM sin un patron
            # adicional. boot.wim es suficiente para arquitectura; lang.ini
            # conserva prioridad para el idioma de Setup.
            $targetImage = $bootWimMeta
            $metadataFromBootWim = $true
        }

        if ($targetImage) {
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Imagen base detectada: $targetImage. Extrayendo metadatos DISM (async)..."
            # [FIX E5] Pasar color explicito (azul claro) en lugar del default Cyan
            & $script:IsoMaker_SetPhase "Analizando metadatos de la imagen (DISM)..." ($uiCyan)
            $btnSrc.Enabled = $false

            # [F2] Activar modo Marquee mientras DISM trabaja en background,
            # para que el usuario vea actividad visual en lugar de una barra vacia.
            $pbMain.Style                 = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $pbMain.MarqueeAnimationSpeed = 20

            $script:IsoMaker_dismQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
            $script:IsoMaker_dismRS    = [runspacefactory]::CreateRunspace()
            $script:IsoMaker_dismRS.Open()
            $langIniPath = Join-Path $srcPath "sources\lang.ini"
            $script:IsoMaker_dismRS.SessionStateProxy.SetVariable('targetImage', $targetImage)
            $script:IsoMaker_dismRS.SessionStateProxy.SetVariable('langIniPath', $langIniPath)
            $script:IsoMaker_dismRS.SessionStateProxy.SetVariable('dismQueue',   $script:IsoMaker_dismQueue)

            $script:IsoMaker_dismPS = [powershell]::Create()
            $script:IsoMaker_dismPS.Runspace = $script:IsoMaker_dismRS
            [void]$script:IsoMaker_dismPS.AddScript({
                $result = @{
                    Label              = $null
                    Architecture       = $null
                    DefaultLanguage    = $null
                    LanguageSource     = $null
                    InstalledLanguages = @()
                    Error              = $null
                }
                try {
                    Import-Module Dism -ErrorAction Stop

                    $prefix    = "CCCOMA"
                    $allImages = Get-WindowsImage -ImagePath $targetImage -ErrorAction Stop
                    $allNames  = $allImages.ImageName -join " "

                    if     ($allNames -match "Server")                            { $prefix = "SSS"   }
                    elseif ($allNames -match "Enterprise.*LTSC|LTSC.*Enterprise") { $prefix = "CCCEA" }
                    elseif ($allNames -match "Enterprise")                        { $prefix = "CCCEA" }

                    $detailedImage = Get-WindowsImage -ImagePath $targetImage -Index 1 -ErrorAction Stop

                    $archRaw = [string]$detailedImage.Architecture
                    $archStr = switch -Regex ($archRaw.Trim().ToUpperInvariant()) {
                        '^(0|X86|INTEL)$'       { "X86"; break }
                        '^(9|X64|AMD64)$'       { "X64"; break }
                        '^(12|ARM64|AARCH64)$'  { "ARM64"; break }
                        default                 { "DESCONOCIDA" }
                    }

                    # Idiomas instalados: se conservan para diagnostico, pero ya no se
                    # utiliza automaticamente Languages[0] como si fuera el predeterminado.
                    if ($null -ne $detailedImage.Languages) {
                        $result.InstalledLanguages = @(
                            $detailedImage.Languages |
                                ForEach-Object { $_.ToString().ToUpperInvariant() } |
                                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                                Select-Object -Unique
                        )
                    }

                    $langStr    = $null
                    $langSource = $null

                    # 1) lang.ini representa el idioma predeterminado de Windows Setup
                    # y tiene prioridad cuando existe. Esto evita confundir el idioma
                    # interno de boot.wim con el idioma principal del medio.
                    if (-not [string]::IsNullOrWhiteSpace($langIniPath) -and
                        (Test-Path -LiteralPath $langIniPath)) {

                        $currentSection    = ''
                        $explicitDefault   = $null
                        $availableLanguages = New-Object System.Collections.Generic.List[object]
                        $order = 0

                        foreach ($rawLine in (Get-Content -LiteralPath $langIniPath -ErrorAction Stop)) {
                            $line = ($rawLine -split '[;#]', 2)[0].Trim()
                            if ([string]::IsNullOrWhiteSpace($line)) { continue }

                            if ($line -match '^\[(?<section>[^\]]+)\]$') {
                                $currentSection = $matches['section'].Trim()
                                continue
                            }

                            if ($currentSection -ieq 'Default UI Language' -and
                                $line -match '^(?:[^=]+?\s*=\s*)?(?<lang>[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)\s*$') {
                                $explicitDefault = $matches['lang']
                                break
                            }

                            if ($currentSection -ieq 'Available UI Languages' -and
                                $line -match '^\s*(?<lang>[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)\s*=\s*(?<rank>\d+)\s*$') {
                                $availableLanguages.Add([pscustomobject]@{
                                    Language = $matches['lang']
                                    Rank     = [int]$matches['rank']
                                    Order    = $order
                                })
                                $order++
                            }
                        }

                        if (-not [string]::IsNullOrWhiteSpace($explicitDefault)) {
                            $langStr    = $explicitDefault
                            $langSource = 'sources\lang.ini [Default UI Language]'
                        } elseif ($availableLanguages.Count -gt 0) {
                            $preferred = $availableLanguages |
                                Sort-Object -Property @{ Expression = 'Rank'; Descending = $true },
                                                      @{ Expression = 'Order'; Descending = $false } |
                                Select-Object -First 1
                            if ($null -ne $preferred) {
                                $langStr    = [string]$preferred.Language
                                $langSource = 'sources\lang.ini [Available UI Languages]'
                            }
                        }
                    }

                    # 2) Algunas versiones del modulo DISM exponen DefaultLanguage.
                    if ([string]::IsNullOrWhiteSpace($langStr)) {
                        $defaultLanguageProperty = $detailedImage.PSObject.Properties['DefaultLanguage']
                        if ($null -ne $defaultLanguageProperty -and
                            -not [string]::IsNullOrWhiteSpace([string]$defaultLanguageProperty.Value)) {
                            $langStr    = [string]$defaultLanguageProperty.Value
                            $langSource = 'Get-WindowsImage.DefaultLanguage'
                        }
                    }

                    # 3) La propiedad singular Language representa el idioma principal
                    # de la imagen y tiene prioridad sobre la lista Languages.
                    if ([string]::IsNullOrWhiteSpace($langStr)) {
                        $languageProperty = $detailedImage.PSObject.Properties['Language']
                        if ($null -ne $languageProperty -and
                            -not [string]::IsNullOrWhiteSpace([string]$languageProperty.Value)) {
                            $langStr    = [string]$languageProperty.Value
                            $langSource = 'Get-WindowsImage.Language'
                        }
                    }

                    # 4) Ultimo recurso: primer idioma instalado informado por DISM.
                    if ([string]::IsNullOrWhiteSpace($langStr) -and $result.InstalledLanguages.Count -gt 0) {
                        $langStr    = [string]$result.InstalledLanguages[0]
                        $langSource = 'Get-WindowsImage.Languages[0] (respaldo)'
                    }

                    # 5) No inventar EN-US cuando el medio no contiene metadatos.
                    # MULTI comunica de forma honesta que no se pudo identificar un idioma unico.
                    if ([string]::IsNullOrWhiteSpace($langStr)) {
                        $langStr    = 'MULTI'
                        $langSource = 'sin metadatos concluyentes'
                    }

                    $langStr = $langStr.Trim().ToUpperInvariant()
                    $result.Architecture      = $archStr
                    $result.DefaultLanguage   = $langStr
                    $result.LanguageSource    = $langSource
                    $archLabel = if ($archStr -eq 'DESCONOCIDA') { 'UNK' } else { $archStr }
                    $result.Label             = "${prefix}_${archLabel}FRE_${langStr}_DV9"
                } catch {
                    $result.Error = $_.Exception.Message
                }
                $dismQueue.Enqueue($result)
            })
            $script:IsoMaker_dismHandle = $script:IsoMaker_dismPS.BeginInvoke()

            $script:IsoMaker_dismTimer          = New-Object System.Windows.Forms.Timer
            $script:IsoMaker_dismTimer.Interval = 100
            $script:IsoMaker_dismTimer.Add_Tick({
                if ($null -eq $script:IsoMaker_dismQueue) { return }
                $res = $null
                if (-not $script:IsoMaker_dismQueue.TryDequeue([ref]$res)) { return }

                $script:IsoMaker_dismTimer.Stop()
                $script:IsoMaker_dismTimer.Dispose()
                $script:IsoMaker_dismTimer = $null
                try { $script:IsoMaker_dismPS.EndInvoke($script:IsoMaker_dismHandle) } catch {}
                try { $script:IsoMaker_dismPS.Dispose()                     } catch {}
                try { $script:IsoMaker_dismRS.Close(); $script:IsoMaker_dismRS.Dispose() } catch {}
                $script:IsoMaker_dismPS = $null; $script:IsoMaker_dismRS = $null
                $script:IsoMaker_dismHandle = $null; $script:IsoMaker_dismQueue = $null
                $btnSrc.Enabled  = $true
                $btnMake.Enabled = $true

                # [F2] Restaurar barra al modo continuo al terminar el analisis DISM.
                $pbMain.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $pbMain.Value = 0

                if ($null -ne $res.Error) {
                    if (-not $script:IsoMaker_labelUserEdited) {
                        $txtLabel.Text = "WINDOWS_CUSTOM"
                        $script:IsoMaker_labelUserEdited = $false
                    }
                    $lblValLang.Text      = "• Idioma predeterminado: No detectado"
                    $lblValLang.ForeColor = [System.Drawing.Color]::Orange
                    Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: Fallo al extraer metadatos DISM: $($res.Error). Etiqueta por defecto aplicada."
                    & $script:IsoMaker_SetPhase "Error leyendo metadatos. Etiqueta por defecto aplicada." ([System.Drawing.Color]::Orange)
                } else {
                    $resolvedArchitecture = & $script:IsoMaker_ResolveArchitecture ([string]$res.Architecture) ([string]$script:IsoMaker_analyzedSource)
                    $res.Architecture = $resolvedArchitecture
                    if ($resolvedArchitecture -ne 'DESCONOCIDA' -and $res.Label -match '_UNKFRE_') {
                        $res.Label = $res.Label -replace '_UNKFRE_', "_${resolvedArchitecture}FRE_"
                    }
                    $script:IsoMaker_detectedArchitecture = [string]$resolvedArchitecture
                    $lblValLang.Text = "• Idioma predeterminado: $($res.DefaultLanguage) | Arquitectura: $resolvedArchitecture"
                    $lblValLang.ForeColor = if ($res.DefaultLanguage -eq 'MULTI') {
                        [System.Drawing.Color]::Orange
                    } else {
                        $uiGreen
                    }
                    Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Arquitectura: $resolvedArchitecture | Idioma predeterminado: $($res.DefaultLanguage) | Fuente: $($res.LanguageSource) | Instalados: $($res.InstalledLanguages -join ', ')."

                    if (-not $script:IsoMaker_labelUserEdited) {
                        $txtLabel.Text          = $res.Label
                        $script:IsoMaker_labelUserEdited = $false   # reset: fue escritura automatica, no del usuario
                        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Etiqueta generada dinamicamente: $($txtLabel.Text)"
                        & $script:IsoMaker_SetPhase "Idioma: $($res.DefaultLanguage) | Etiqueta: $($txtLabel.Text)" ($uiGreen)
                    } else {
                        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Etiqueta DISM ignorada (usuario edito manualmente): '$($txtLabel.Text)'."
                        & $script:IsoMaker_SetPhase "Idioma: $($res.DefaultLanguage) | Etiqueta personalizada conservada" ([System.Drawing.Color]::FromArgb(255, 200, 40))
                    }
                }
            })
            $script:IsoMaker_dismTimer.Start()

        } else {
            $btnMake.Enabled        = $true
            $txtLabel.Text          = "WINDOWS_CUSTOM"
            $script:IsoMaker_labelUserEdited = $false
            $lblValLang.Text        = "• Idioma predeterminado: No disponible"
            $lblValLang.ForeColor   = [System.Drawing.Color]::Orange
            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se detecto una imagen de metadatos compatible (install.wim/esd o boot.wim para SWM). Aplicando etiqueta base."
            & $script:IsoMaker_SetPhase "Imagen de metadatos no encontrada. Etiqueta base aplicada." ([System.Drawing.Color]::Orange)
        }
    }

    # ------------------------------------------------------------------
    # Inyeccion de autounattend.xml
    # ------------------------------------------------------------------
    # Conserva una copia temporal cuando autounattend.xml ya existe y elimina
    # solamente el archivo nuevo cuando fue agregado por ISO Maker.
    $script:IsoMaker_InitializeInjectionState = {
        & $script:IsoMaker_CleanupInjectedFiles
        $script:IsoMaker_injectedFiles      = [System.Collections.Generic.List[string]]::new()
        $script:IsoMaker_injectionBackups   = [System.Collections.Generic.List[object]]::new()
        $script:IsoMaker_injectionBackupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("IsoMaker_Backup_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:IsoMaker_injectionBackupRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $script:IsoMaker_PrepareInjectionTarget = {
        param([Parameter(Mandatory=$true)][string]$TargetPath)

        if (Test-Path -LiteralPath $TargetPath -PathType Container) {
            throw "No se puede reemplazar una carpeta con un archivo: $TargetPath"
        }

        if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
            $alreadyBackedUp = $false
            foreach ($entry in $script:IsoMaker_injectionBackups) {
                if ([string]::Equals($entry.Original, $TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $alreadyBackedUp = $true
                    break
                }
            }
            if (-not $alreadyBackedUp) {
                $backupPath = Join-Path $script:IsoMaker_injectionBackupRoot ([guid]::NewGuid().ToString('N'))
                Copy-Item -LiteralPath $TargetPath -Destination $backupPath -Force -ErrorAction Stop
                $script:IsoMaker_injectionBackups.Add([pscustomobject]@{
                    Original = $TargetPath
                    Backup   = $backupPath
                })
            }
        } else {
            if (-not $script:IsoMaker_injectedFiles.Contains($TargetPath)) {
                $script:IsoMaker_injectedFiles.Add($TargetPath)
            }
        }
    }


    $script:IsoMaker_CleanupInjectedFiles = {
        # BootOrder se crea fuera de la fuente y debe retirarse en exito, error,
        # cancelacion o cierre forzado.
        & $script:IsoMaker_RemoveBootOrderFile

        # Primero eliminar archivos y carpetas creados por ISO Maker, de mayor a menor profundidad.
        if ($null -ne $script:IsoMaker_injectedFiles) {
            $paths = $script:IsoMaker_injectedFiles |
                Select-Object -Unique |
                Sort-Object { $_.Split([IO.Path]::DirectorySeparatorChar).Count } -Descending

            foreach ($path in $paths) {
                try {
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                    } elseif (Test-Path -LiteralPath $path -PathType Container) {
                        if (-not (Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
                            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                        }
                    }
                } catch {
                    Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo eliminar el elemento temporal '$path': $($_.Exception.Message)"
                }
            }
        }

        # Despues restaurar exactamente los archivos que ya existian antes de la inyeccion.
        if ($null -ne $script:IsoMaker_injectionBackups) {
            foreach ($entry in $script:IsoMaker_injectionBackups) {
                try {
                    $parent = Split-Path -Parent $entry.Original
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -Path $parent -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $entry.Backup -Destination $entry.Original -Force -ErrorAction Stop
                } catch {
                    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo restaurar '$($entry.Original)': $($_.Exception.Message)"
                }
            }
        }

        if ($script:IsoMaker_injectionBackupRoot -and (Test-Path -LiteralPath $script:IsoMaker_injectionBackupRoot)) {
            try { Remove-Item -LiteralPath $script:IsoMaker_injectionBackupRoot -Recurse -Force -ErrorAction Stop } catch {}
        }

        $script:IsoMaker_injectedFiles       = $null
        $script:IsoMaker_injectionBackups    = $null
        $script:IsoMaker_injectionBackupRoot = $null
    }

    # ------------------------------------------------------------------
    # 5. Eventos de controles
    # ------------------------------------------------------------------

    $txtSrc.Add_TextChanged({ & $script:IsoMaker_UpdateValidation $txtSrc.Text; & $script:IsoMaker_UpdateDiskSpace $txtSrc.Text $txtDst.Text })

    # [FIX F5] TextChanged solo realiza comprobaciones rápidas. Al abandonar el
    # campo, analizar también rutas escritas o pegadas para actualizar tamaño,
    # idioma y arquitectura, sin repetir el análisis de la misma ruta.
    $txtSrc.Add_Leave({
        $typedSource = ([string]$txtSrc.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($typedSource)) { return }

        # Aceptar rutas copiadas con comillas externas.
        if ($typedSource.Length -ge 2 -and
            $typedSource.StartsWith('"') -and $typedSource.EndsWith('"')) {
            $typedSource = $typedSource.Substring(1, $typedSource.Length - 2).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($typedSource)) { return }

        try {
            $sourceItem = Get-Item -LiteralPath $typedSource -Force -ErrorAction Stop
            if (-not $sourceItem.PSIsContainer) { return }
            $fullPath = [System.IO.Path]::GetFullPath([string]$sourceItem.FullName)
        } catch {
            return
        }

        # Canonicalizar el contenido para que el preflight reciba una ruta limpia.
        if (-not [string]::Equals($txtSrc.Text, $fullPath, [StringComparison]::OrdinalIgnoreCase)) {
            $txtSrc.Text = $fullPath
        }

        $normalizedTyped = $fullPath.TrimEnd([char[]]@('\','/'))
        $normalizedAnalyzed = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$script:IsoMaker_analyzedSource)) {
            try {
                $normalizedAnalyzed = ([System.IO.Path]::GetFullPath([string]$script:IsoMaker_analyzedSource)).TrimEnd([char[]]@('\','/'))
            } catch {
                $normalizedAnalyzed = ([string]$script:IsoMaker_analyzedSource).TrimEnd([char[]]@('\','/'))
            }
        }

        if ([string]::Equals($normalizedTyped, $normalizedAnalyzed, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }

        & $script:IsoMaker_AnalyzeSrc $fullPath
    })
    $txtDst.Add_TextChanged({ & $script:IsoMaker_UpdateDiskSpace $txtSrc.Text $txtDst.Text })


    # [FIX D2] Rastrear si el usuario ha editado manualmente la etiqueta, para que el resultado
    # del analisis DISM asincronico no sobreescriba un valor introducido intencionalmente.
    $script:IsoMaker_labelUserEdited = $false

    # [F3] Validacion en tiempo real de la etiqueta de volumen.
    # ISO 9660 / UDF solo admiten A-Z, 0-9, guion y guion_bajo, maximo 32 chars.
    # [FIX E3] Se fuerza uppercase en el handler para que la conversion posterior de
    # la sanitizacion (ToUpper) no sorprenda al usuario. La posicion del cursor se
    # preserva para que escribir en mitad del texto siga funcionando con naturalidad.
    $txtLabel.Add_TextChanged({
        $pos = $txtLabel.SelectionStart
        $up  = $txtLabel.Text.ToUpper()
        if ($txtLabel.Text -cne $up) {
            $txtLabel.Text           = $up
            $txtLabel.SelectionStart = [Math]::Min($pos, $up.Length)
        }
        $script:IsoMaker_labelUserEdited = $true
        $raw     = $txtLabel.Text
        $invalid = $raw -match '[^A-Z0-9_\-]'
        $tooLong = $raw.Length -gt 32
        if ($invalid -or $tooLong) {
            $txtLabel.BackColor = [System.Drawing.Color]::FromArgb(60, 20, 20)
            $txtLabel.ForeColor = [System.Drawing.Color]::Tomato
        } else {
            $txtLabel.BackColor = [System.Drawing.Color]::White
            $txtLabel.ForeColor = [System.Drawing.Color]::Black
        }
    })

    $btnSrc.Add_Click({
        $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Selecciona carpeta raiz de Windows (donde estan setup.exe, boot, efi...)"
        if ($fbd.ShowDialog() -eq 'OK') { & $script:IsoMaker_AnalyzeSrc $fbd.SelectedPath }
    })

    $btnDst.Add_Click({
        $sfd        = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Imagen ISO (*.iso)|*.iso"
        if ($sfd.ShowDialog() -eq 'OK') {
            $txtDst.Text = $sfd.FileName
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Archivo de destino configurado: $($txtDst.Text)"
            & $script:IsoMaker_UpdateDiskSpace $txtSrc.Text $txtDst.Text
        }
    })

    $btnUnattend.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "XML Files (*.xml)|*.xml"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtUnattend.Text = $ofd.FileName
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Archivo Unattend.xml configurado: $($txtUnattend.Text)"
        }
    })

    $lnkWeb.Add_Click({
        $lnkWeb.LinkVisited = $true   # [FIX C6] Actualizar estado visual del enlace
        Start-Process "https://schneegans.de/windows/unattend-generator/"
    })

    # [F5] Tooltips en controles clave.
    # ShowAlways = $true para que funcionen aunque el form no tenga foco.
    $tip                  = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay     = 8000
    $tip.InitialDelay     = 400
    $tip.ReshowDelay      = 200
    $tip.ShowAlways       = $true
    $tip.SetToolTip($txtSrc,      "Carpeta raiz de la fuente de instalacion de Windows (debe contener boot\, efi\, sources\).")
    $tip.SetToolTip($btnSrc,      "Abrir explorador para seleccionar la carpeta origen.")
    $tip.SetToolTip($txtDst,      "Ruta completa del archivo ISO que se generara (p. ej. C:\Output\Windows11.iso).")
    $tip.SetToolTip($btnDst,      "Elegir ruta y nombre del archivo ISO de salida.")
    $tip.SetToolTip($txtLabel,    "Maximo 32 caracteres. Solo A-Z, 0-9, guion y guion_bajo. Se genera con arquitectura e idioma predeterminado detectados.")
    $tip.SetToolTip($lblValLang,  "Prioridad: DefaultLanguage/Language de DISM, lang.ini y, como respaldo, el primer idioma instalado.")
    $tip.SetToolTip($txtUnattend, "Archivo XML de respuesta desatendida. Se copiara como autounattend.xml en la raiz de la ISO.")
    $tip.SetToolTip($btnUnattend, "Seleccionar archivo autounattend.xml.")
    $tip.SetToolTip($lnkWeb,      "Abre schneegans.de — generador online de archivos autounattend.xml para automatizacion OOBE.")
    $tip.SetToolTip($btnExportLog,"Guarda el log completo de la ultima compilacion como archivo .txt.")
    $tip.SetToolTip($btnMake,     "Inicia la compilacion de la imagen ISO booteable con los parametros configurados.")
    $tip.SetToolTip($btnCancel,   "Interrumpe la compilacion en curso, elimina la salida parcial y restaura la ISO anterior si existia.")

    # ------------------------------------------------------------------
    # [F1] Boton Cancelar
    # Cancela el proceso oscdimg en curso, limpia todos los recursos y
    # restaura la UI al estado de reposo sin necesidad de cerrar el form.
    # ------------------------------------------------------------------
    $btnCancel.Add_Click({
        if ($null -eq $script:IsoMaker_isoProc -or $script:IsoMaker_isoProc.HasExited) { return }

        $res = [System.Windows.Forms.MessageBox]::Show(
            "Se cancelara la compilacion en curso.`nLa ISO parcial se eliminara automaticamente y, si existia una version anterior, se restaurara.`n`n¿Confirmas la cancelacion?",
            "Cancelar Compilacion",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($res -eq 'No') { return }

        Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: Compilacion cancelada por el usuario desde el boton Cancelar."

        # Detener timer de progreso y liberar wait handle
        if ($null -ne $script:IsoMaker_pollTimer) {
            try { $script:IsoMaker_pollTimer.Stop(); $script:IsoMaker_pollTimer.Dispose() } catch {}
            $script:IsoMaker_pollTimer = $null
        }
        if ($null -ne $script:IsoMaker_buildDone) {
            try { $script:IsoMaker_buildDone.Dispose() } catch {}
            $script:IsoMaker_buildDone = $null
        }

        # Terminar oscdimg, esperar callbacks y conservar el log parcial antes
        # de descartar las colas. Esto evita exportar accidentalmente un log viejo.
        & $script:IsoMaker_DisposeIsoProcess $true
        [void](& $script:IsoMaker_CaptureInterruptedBuildLog 'CANCELADO POR EL USUARIO' 'ISO_Build_CANCELLED')
        $script:IsoMaker_outQueue = $null
        $script:IsoMaker_errQueue = $null

        # Limpiar archivos inyectados y restaurar una ISO anterior, si existia.
        & $script:IsoMaker_CleanupInjectedFiles
        & $script:IsoMaker_FinalizeIsoOutput $false

        # Actualizar HUD
        & $script:IsoMaker_SetPhase "Compilacion cancelada por el usuario." ([System.Drawing.Color]::Orange)
        $pbMain.Value         = 0
        $lblPercent.Text      = "Cancelado"
        $lblPercent.ForeColor = [System.Drawing.Color]::Orange
        $btnExportLog.Enabled = -not [string]::IsNullOrWhiteSpace($script:IsoMaker_lastBuildLog)

        Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: Recursos liberados correctamente tras la cancelacion. Listo para nueva compilacion."
        & $script:IsoMaker_RestoreCompileUI
    })

    # ------------------------------------------------------------------
    # 6. Logica principal — CREAR ISO BOOTEABLE
    # ------------------------------------------------------------------
    $btnMake.Add_Click({
        $src        = $txtSrc.Text
        $script:IsoMaker_iso = $txtDst.Text
        $xmlPath    = $txtUnattend.Text
        $iso        = $script:IsoMaker_iso

        if (-not $src -or -not $iso) {
            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: El usuario intento compilar sin definir rutas de origen o destino."
            [System.Windows.Forms.MessageBox]::Show("Faltan rutas.", "Error", 'OK', 'Error')
            return
        }

        if (-not (Test-Path -LiteralPath $src -PathType Container)) {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: La carpeta origen no existe: $src"
            [System.Windows.Forms.MessageBox]::Show("La carpeta origen no existe.", "Error", 'OK', 'Error')
            return
        }

        try {
            $src = [System.IO.Path]::GetFullPath($src)
            $iso = [System.IO.Path]::GetFullPath($iso)
            if ([System.IO.Path]::GetExtension($iso) -ine '.iso') {
                $iso = [System.IO.Path]::ChangeExtension($iso, '.iso')
            }
            $script:IsoMaker_iso = $iso
            $txtDst.Text = $iso
            $replaceExistingIso = $false

            $srcCompare = $src.TrimEnd([char[]]@('\','/'))
            $srcPrefix  = $srcCompare + [System.IO.Path]::DirectorySeparatorChar
            if ($iso.StartsWith($srcPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "El archivo ISO de destino no puede guardarse dentro de la carpeta origen."
            }

            $dstParent = Split-Path -Parent $iso
            if ([string]::IsNullOrWhiteSpace($dstParent)) {
                throw "No se pudo determinar la carpeta de destino."
            }
            if (-not (Test-Path -LiteralPath $dstParent)) {
                New-Item -Path $dstParent -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            if (Test-Path -LiteralPath $iso) {
                $overwrite = [System.Windows.Forms.MessageBox]::Show(
                    "El archivo de destino ya existe:`n$iso`n`n¿Deseas reemplazarlo?",
                    "Reemplazar ISO existente",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($overwrite -eq [System.Windows.Forms.DialogResult]::No) { return }
                $replaceExistingIso = $true
            }
        } catch {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Ruta de origen/destino no valida: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Ruta no valida", 'OK', 'Error') | Out-Null
            return
        }

        # Resolver imagenes El Torito disponibles. Se acepta BIOS-only,
        # UEFI-only o arranque dual. ARM64 se fuerza a UEFI-only.
        $biosBoot          = Join-Path $src "boot\etfsboot.com"
        $uefiBootStandard  = Join-Path $src "efi\microsoft\boot\efisys.bin"
        $uefiBootNoPrompt  = Join-Path $src "efi\microsoft\boot\efisys_noprompt.bin"

        $biosDisponible = (Test-Path -LiteralPath $biosBoot -PathType Leaf) -and
                          ((Get-Item -LiteralPath $biosBoot -ErrorAction SilentlyContinue).Length -gt 0)
        $uefiStandardDisponible = (Test-Path -LiteralPath $uefiBootStandard -PathType Leaf) -and
                                  ((Get-Item -LiteralPath $uefiBootStandard -ErrorAction SilentlyContinue).Length -gt 0)
        $uefiNoPromptDisponible = (Test-Path -LiteralPath $uefiBootNoPrompt -PathType Leaf) -and
                                  ((Get-Item -LiteralPath $uefiBootNoPrompt -ErrorAction SilentlyContinue).Length -gt 0)

        # Mantener efisys.bin como predeterminado para evitar ciclos de arranque
        # automatico despues del primer reinicio. noprompt se usa como respaldo.
        $uefiBoot = if ($uefiStandardDisponible) { $uefiBootStandard }
                    elseif ($uefiNoPromptDisponible) { $uefiBootNoPrompt }
                    else { $null }
        $uefiDisponible = -not [string]::IsNullOrWhiteSpace($uefiBoot)

        $sourceMatchesAnalysis = $false
        try {
            $sourceMatchesAnalysis = [string]::Equals(
                (& $script:IsoMaker_NormalizeDirectoryPath $src),
                (& $script:IsoMaker_NormalizeDirectoryPath ([string]$script:IsoMaker_analyzedSource)),
                [StringComparison]::OrdinalIgnoreCase
            )
        } catch {}

        $detectedArch = if ($sourceMatchesAnalysis) { [string]$script:IsoMaker_detectedArchitecture } else { $null }
        $detectedArch = & $script:IsoMaker_ResolveArchitecture $detectedArch $src
        if ($detectedArch -eq 'DESCONOCIDA') {
            & Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No fue posible determinar con certeza la arquitectura. No se asumira X64."
        }

        # Revalidacion sincronica: el preflight nunca confia ciegamente en un
        # analisis anterior. La huella completa detecta archivos agregados, eliminados
        # o modificados incluso si el usuario no abandono el campo de ruta.
        try {
            & $script:IsoMaker_SetPhase "Revalidando contenido de la fuente..." ($uiCyan)
            $currentSnapshot = & $script:IsoMaker_GetSourceSnapshot $src
            $previousSnapshot = $script:IsoMaker_sourceSnapshot
            $hasDeepFingerprint = ($null -ne $previousSnapshot) -and
                                  ($null -ne $previousSnapshot.PSObject.Properties['MetadataFingerprint']) -and
                                  (-not [string]::IsNullOrWhiteSpace([string]$previousSnapshot.MetadataFingerprint))
            $snapshotChanged = (-not $hasDeepFingerprint) -or
                               ($previousSnapshot.FullFingerprint -ne $currentSnapshot.FullFingerprint)
            if ($snapshotChanged) {
                $quickChanged = ($null -eq $previousSnapshot) -or
                                ($previousSnapshot.QuickFingerprint -ne $currentSnapshot.QuickFingerprint)
                if ($hasDeepFingerprint) {
                    & Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: La fuente cambio desde el ultimo preflight; se actualizaron tamano, conteos y puntos de reanalisis."
                } else {
                    & Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Huella profunda inicial completada durante preflight."
                }
                $script:IsoMaker_sourceSnapshot = $currentSnapshot
                $script:IsoMaker_sourceBytes = [long]$currentSnapshot.Bytes
                $script:IsoMaker_reparsePointCount = [int]$currentSnapshot.ReparsePointCount
                $detectedArch = if ($quickChanged) {
                    & $script:IsoMaker_ResolveArchitecture $null $src
                } else {
                    & $script:IsoMaker_ResolveArchitecture $detectedArch $src
                }
                $script:IsoMaker_detectedArchitecture = $detectedArch
                & $script:IsoMaker_UpdateValidation $src
                & $script:IsoMaker_UpdateDiskSpace $src $iso
            } else {
                & Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Huella profunda de la fuente sin cambios desde el ultimo preflight."
            }
            $currentSourceBytes = [long]$currentSnapshot.Bytes
        } catch {
            & Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo revalidar la fuente durante preflight: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                "No se pudo completar la revalidacion de la carpeta origen.`n`nDetalle:`n$($_.Exception.Message)",
                'Preflight incompleto', 'OK', 'Error'
            ) | Out-Null
            return
        }

        $bootProfile = $null
        if ($detectedArch -eq 'ARM64') {
            if (-not $uefiDisponible) {
                Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Fuente ARM64 sin efisys.bin ni efisys_noprompt.bin; no es posible crear una ISO arrancable."
                [System.Windows.Forms.MessageBox]::Show(
                    "La fuente fue identificada como ARM64, pero no contiene una imagen de arranque UEFI válida:`n`nefi\microsoft\boot\efisys.bin`no`nefi\microsoft\boot\efisys_noprompt.bin",
                    "Arranque UEFI ARM64 ausente",
                    'OK',
                    'Error'
                ) | Out-Null
                return
            }
            $bootProfile = 'UEFI'
        } elseif ($biosDisponible -and $uefiDisponible) {
            $bootProfile = 'DUAL'
        } elseif ($biosDisponible) {
            $bootProfile = 'BIOS'
        } elseif ($uefiDisponible) {
            $bootProfile = 'UEFI'
        } else {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se encontro ninguna imagen El Torito valida para BIOS o UEFI."
            [System.Windows.Forms.MessageBox]::Show(
                "No se encontró ninguna imagen de arranque válida.`n`nSe requiere al menos uno de estos archivos:`n• boot\etfsboot.com`n• efi\microsoft\boot\efisys.bin`n• efi\microsoft\boot\efisys_noprompt.bin",
                "Fuente no arrancable",
                'OK',
                'Error'
            ) | Out-Null
            return
        }

        if ($detectedArch -eq 'DESCONOCIDA') {
            $unknownChoice = [System.Windows.Forms.MessageBox]::Show(
                "No fue posible determinar con certeza la arquitectura de Windows. No se asumira X64.`n`nPerfil de arranque detectado: $bootProfile`n`nLa ISO se construira exclusivamente con los archivos de arranque realmente presentes. ¿Deseas continuar?",
                'Arquitectura no determinada',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($unknownChoice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        if ($bootProfile -eq 'BIOS') {
            $confirmBoot = [System.Windows.Forms.MessageBox]::Show(
                "La fuente solo contiene arranque BIOS/Legacy.`nLa ISO no arrancará en equipos configurados exclusivamente para UEFI.`n`n¿Deseas continuar?",
                "Perfil BIOS-only",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmBoot -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        } elseif ($bootProfile -eq 'UEFI' -and $detectedArch -ne 'ARM64') {
            $confirmBoot = [System.Windows.Forms.MessageBox]::Show(
                "La fuente solo contiene arranque UEFI.`nLa ISO no arrancará en equipos configurados exclusivamente para BIOS/Legacy.`n`n¿Deseas continuar?",
                "Perfil UEFI-only",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmBoot -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        if ($uefiNoPromptDisponible -and -not $uefiStandardDisponible) {
            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: Se usara efisys_noprompt.bin porque efisys.bin no esta disponible. El arranque UEFI sera automatico."
        }
        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Perfil de arranque resuelto: $bootProfile | Arquitectura: $detectedArch | BIOS: $biosDisponible | UEFI: $uefiDisponible | Imagen UEFI: $uefiBoot"

        # -r solo se activa con consentimiento explicito. Resolver junctions o
        # enlaces simbolicos puede incorporar archivos ubicados fuera de la fuente.
        $resolveReparsePoints = $false
        if ($sourceMatchesAnalysis -and [int]$script:IsoMaker_reparsePointCount -gt 0) {
            $linkChoice = [System.Windows.Forms.MessageBox]::Show(
                "Se detectaron $($script:IsoMaker_reparsePointCount) enlaces simbólicos o junctions en la fuente.`n`nSí: resolver sus destinos mediante -r.`nNo: conservar el comportamiento normal de oscdimg.`nCancelar: detener la compilación.`n`nAdvertencia: -r puede incorporar contenido ubicado fuera de la carpeta seleccionada.",
                "Enlaces detectados en la fuente",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($linkChoice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
            $resolveReparsePoints = ($linkChoice -eq [System.Windows.Forms.DialogResult]::Yes)
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Enlaces detectados: $($script:IsoMaker_reparsePointCount) | Resolver con -r: $resolveReparsePoints"
        }

        $bootWim = Join-Path $src "sources\boot.wim"
        if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf) -or
            ((Get-Item -LiteralPath $bootWim -ErrorAction SilentlyContinue).Length -le 0)) {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Falta sources\boot.wim o el archivo está vacío; la fuente no puede iniciar Windows Setup/WinPE."
            [System.Windows.Forms.MessageBox]::Show(
                "No se encontró un archivo válido en sources\boot.wim.`n`nLa ISO podría tener catálogo El Torito, pero no podría iniciar Windows Setup o WinPE.",
                "boot.wim ausente",
                'OK',
                'Error'
            ) | Out-Null
            return
        }

        $srcWim = Join-Path $src "sources\install.wim"
        $srcEsd = Join-Path $src "sources\install.esd"
        $swmInfoPreflight = & $script:IsoMaker_GetSwmSetInfo $src $true
        if ($swmInfoPreflight.Exists -and -not $swmInfoPreflight.Valid) {
            & Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Conjunto SWM no valido: $($swmInfoPreflight.Errors -join ' | ')"
            [System.Windows.Forms.MessageBox]::Show(
                "El conjunto install*.swm no es valido.`n`n$($swmInfoPreflight.Errors -join "`n")",
                'Conjunto SWM no valido', 'OK', 'Error'
            ) | Out-Null
            return
        }
        $hasInstallImage = (Test-Path -LiteralPath $srcWim -PathType Leaf) -or
                           (Test-Path -LiteralPath $srcEsd -PathType Leaf) -or
                           ($swmInfoPreflight.Exists -and $swmInfoPreflight.Valid)
        if (-not $hasInstallImage) {
            & Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se encontro sources\install.wim, install.esd ni un conjunto SWM valido."
            $resWim = [System.Windows.Forms.MessageBox]::Show(
                "No se encontro 'sources\install.wim', 'sources\install.esd' ni un conjunto SWM valido en la carpeta origen.`n`nEsto puede indicar una fuente incompleta o un medio WinPE sin imagen de instalacion.`n`n¿Deseas continuar de todas formas?",
                "Imagen de Instalacion Ausente",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($resWim -eq 'No') { return }
            & Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Usuario acepto continuar sin imagen de instalacion."
        } elseif ($swmInfoPreflight.Exists) {
            & Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: $($swmInfoPreflight.Summary) | Tamano: $($swmInfoPreflight.TotalBytes) bytes."
        }
        $script:IsoMaker_requireInstallImage = [bool]$hasInstallImage

        try {
            $dstQ = Split-Path -Qualifier $iso -ErrorAction SilentlyContinue
            if ($dstQ) {
                $drive = Get-PSDrive -Name $dstQ.TrimEnd(':') -ErrorAction SilentlyContinue
                if ($drive) {
                    $requiredBytes = 5GB
                    if ([long]$currentSourceBytes -gt 0) {
                        $requiredBytes = [long][math]::Ceiling(([double]$currentSourceBytes * 1.08) + 256MB)
                    }
                    $driveFormat = $null
                    try {
                        $driveRoot = [System.IO.Path]::GetPathRoot($iso)
                        if (-not [string]::IsNullOrWhiteSpace($driveRoot)) {
                            $driveInfo   = New-Object System.IO.DriveInfo($driveRoot)
                            $driveFormat = $driveInfo.DriveFormat
                        }
                    } catch {}

                    if ($driveFormat -eq 'FAT32' -and [long]$currentSourceBytes -ge 4GB) {
                        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: El destino usa FAT32 y la ISO estimada supera el limite de 4 GB por archivo."
                        [System.Windows.Forms.MessageBox]::Show(
                            "La unidad de destino usa FAT32, que no admite archivos de 4 GB o mas.`n`nSelecciona una unidad NTFS, exFAT o ReFS para guardar esta ISO.",
                            "Destino FAT32 no compatible",
                            'OK',
                            'Error'
                        ) | Out-Null
                        return
                    }
                    if (-not [string]::IsNullOrWhiteSpace($driveFormat)) {
                        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Sistema de archivos del destino: $driveFormat."
                    }

                    if ($drive.Free -lt $requiredBytes) {
                        $freeGB     = [math]::Round($drive.Free / 1GB, 1)
                        $requiredGB = [math]::Round($requiredBytes / 1GB, 1)
                        $proceed = [System.Windows.Forms.MessageBox]::Show(
                            "Espacio libre en el destino: $freeGB GB`nEstimado requerido: $requiredGB GB`n`nLa compilacion puede fallar o dejar una salida parcial.`n`n¿Deseas continuar de todas formas?",
                            "Espacio en Disco Insuficiente",
                            [System.Windows.Forms.MessageBoxButtons]::YesNo,
                            [System.Windows.Forms.MessageBoxIcon]::Warning
                        )
                        if ($proceed -eq [System.Windows.Forms.DialogResult]::No) {
                            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: El usuario cancelo la compilacion por espacio insuficiente ($freeGB GB libres; $requiredGB GB estimados)."
                            return
                        }
                        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Usuario acepto continuar con espacio limitado ($freeGB GB libres; $requiredGB GB estimados)."
                    }
                }
            }
        } catch {
            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo validar el espacio del destino: $($_.Exception.Message)"
        }

        $btnOpenFolder.Visible = $false
        $lblHashInfo.Text      = ""
        $lblHashInfo.ForeColor = $uiGreen

        try {
            & $script:IsoMaker_InitializeInjectionState
        } catch {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: No se pudo preparar el respaldo temporal de inyeccion: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("No se pudo preparar la inyeccion:`n$($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($xmlPath)) {
            if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
                [System.Windows.Forms.MessageBox]::Show("El archivo XML seleccionado ya no existe:`n$xmlPath", "Archivo no encontrado", 'OK', 'Error') | Out-Null
                & $script:IsoMaker_CleanupInjectedFiles
                return
            }
            try {
                [xml]$unattendDocument = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
                if ($null -eq $unattendDocument.DocumentElement -or
                    $unattendDocument.DocumentElement.LocalName -ine 'unattend') {
                    throw "El elemento raiz del XML debe ser 'unattend'."
                }
            } catch {
                Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: autounattend.xml no es valido: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show(
                    "El archivo XML seleccionado no es un autounattend.xml valido.`n`nDetalle:`n$($_.Exception.Message)",
                    "XML no valido",
                    'OK',
                    'Error'
                ) | Out-Null
                & $script:IsoMaker_CleanupInjectedFiles
                return
            }

            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Archivo Unattend.xml valido detectado. Inyectando en la raiz de la ISO."
            try {
                $xmlDest = Join-Path $src "autounattend.xml"
                $xmlFullPath  = [System.IO.Path]::GetFullPath($xmlPath)
                $destFullPath = [System.IO.Path]::GetFullPath($xmlDest)
                if ([string]::Equals($xmlFullPath, $destFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: El autounattend.xml seleccionado ya se encuentra en la raiz del medio; no se requiere copiarlo."
                } else {
                    & $script:IsoMaker_PrepareInjectionTarget $xmlDest
                    Copy-Item -LiteralPath $xmlPath -Destination $xmlDest -Force -ErrorAction Stop
                    Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: autounattend.xml inyectado correctamente en: $xmlDest"
                }
            } catch {
                Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Fallo al copiar el archivo XML a la raiz - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error copiando XML: $($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
                & $script:IsoMaker_CleanupInjectedFiles
                return
            }
        }

        # Ajustar el tamano efectivo despues de inyectar archivos opcionales.
        # Esto evita omitir BootOrder cuando autounattend/MRP hacen que la fuente
        # supere el umbral de 4.5 GB despues del preflight.
        $injectionDeltaBytes = 0L
        foreach ($createdPath in @($script:IsoMaker_injectedFiles)) {
            if ($createdPath -and (Test-Path -LiteralPath $createdPath -PathType Leaf)) {
                $injectionDeltaBytes += [long](Get-Item -LiteralPath $createdPath -Force).Length
            }
        }
        foreach ($backupEntry in @($script:IsoMaker_injectionBackups)) {
            if ($backupEntry -and $backupEntry.Original -and $backupEntry.Backup -and
                (Test-Path -LiteralPath $backupEntry.Original -PathType Leaf) -and
                (Test-Path -LiteralPath $backupEntry.Backup -PathType Leaf)) {
                $newLength = [long](Get-Item -LiteralPath $backupEntry.Original -Force).Length
                $oldLength = [long](Get-Item -LiteralPath $backupEntry.Backup -Force).Length
                $injectionDeltaBytes += ($newLength - $oldLength)
            }
        }
        if ($injectionDeltaBytes -ne 0) {
            $currentSourceBytes = [long][math]::Max(0, ([long]$currentSourceBytes + $injectionDeltaBytes))
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Ajuste de tamano por inyecciones: $injectionDeltaBytes bytes | Tamano efectivo: $currentSourceBytes bytes."
        }

        # Bloquear controles y mostrar indicadores de actividad
        $btnMake.Enabled      = $false
        $grpCfg.Enabled       = $false
        $grpAuto.Enabled      = $false
        $form.Cursor          = [System.Windows.Forms.Cursors]::WaitCursor
        $pbMain.Value         = 0
        $lblPercent.Text      = "0 % completado"
        $lblPercent.ForeColor = $uiGreen
        $lblFileInfo.Text     = ""
        $lblSizeInfo.Text     = ""

        & $script:IsoMaker_SetPhase "Iniciando compilacion..." ($uiCyan)
        $picCD.Visible = $true
        $cdTimer.Start()

        # [F1] Mostrar boton Cancelar y ajustar ancho de btnMake para hacerle espacio
        $btnMake.Size      = "430, 40"
        $btnCancel.Visible = $true


        # [FIX B8] Sanitizacion estricta ISO 9660 / UDF.
        # Solo A-Z, 0-9, guion y guion_bajo. UDF no admite minusculas.
        $label = ($txtLabel.Text -replace '[^A-Za-z0-9_\-]', '_').ToUpper().Trim('_')
        if ($label.Length -eq 0)  { $label = "WINDOWS_CUSTOM" }
        if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
        if ($label -ne $txtLabel.Text.ToUpper()) {
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Etiqueta sanitizada (ISO 9660/UDF): '$($txtLabel.Text)' -> '$label'."
        } else {
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Etiqueta de volumen: '$label'."
        }

        $script:IsoMaker_lastPct = 0

        # [FIX B5] Interpolacion de strings en lugar del operador -f.
        # -f interpreta { } como especificadores de formato y lanza FormatException
        # si las rutas contienen esos caracteres.
        # [FIX E2] TrimEnd('\') en $srcNorm: FolderBrowserDialog puede devolver rutas
        # de unidad raiz con backslash final (ej. "C:\"). Al embeber en "$srcNorm",
        # CommandLineToArgvW interpreta \" como comilla escapada, dejando el argumento
        # abierto y absorbiendo los parametros siguientes. TrimEnd garantiza que el
        # argumento cierre correctamente en todos los casos.
        $srcNorm = [System.IO.Path]::GetFullPath($src)
        $srcArg  = & $script:IsoMaker_QuoteWindowsArgument $srcNorm
        $isoArg  = & $script:IsoMaker_QuoteWindowsArgument $iso
        $biosArg = if ($biosDisponible) { & $script:IsoMaker_QuoteWindowsArgument $biosBoot } else { $null }
        $uefiArg = if ($uefiDisponible) { & $script:IsoMaker_QuoteWindowsArgument $uefiBoot } else { $null }

        $bootArg = switch ($bootProfile) {
            'DUAL' { "-bootdata:2#p0,e,b$biosArg#pEF,e,b$uefiArg"; break }
            'BIOS' { "-b$biosArg -p0 -e"; break }
            'UEFI' { "-b$uefiArg -pEF -e"; break }
            default { throw "Perfil de arranque no reconocido: $bootProfile" }
        }

        # BootOrder solo se aplica a fuentes mayores de 4.5 GB. Se intenta en el
        # primer perfil y, si la compilacion antigua de oscdimg lo rechaza, ISO Maker
        # reintenta automaticamente con argumentos conservadores.
        $largeSource = ([long]$currentSourceBytes -gt [long](4.5 * 1GB))
        $bootOrderPath = $null
        $bootOrderSwitch = $null
        if ($largeSource) {
            try {
                $bootOrderPath   = & $script:IsoMaker_NewBootOrderFile $srcNorm
                $bootOrderSwitch = "-yo$bootOrderPath"
                Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: BootOrder generado (fuente mayor de 4.5 GB): $bootOrderPath"
            } catch {
                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo preparar BootOrder; se continuara con perfil compatible. Detalle: $($_.Exception.Message)"
                $bootOrderPath = $null
                $bootOrderSwitch = $null
            }
        } else {
            & $script:IsoMaker_RemoveBootOrderFile
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: BootOrder no requerido (fuente de 4.5 GB o menor)."
        }

        $script:IsoMaker_buildBootProfile = $bootProfile
        $script:IsoMaker_expectedIsoFiles = @()
        $sourcePrefixForExpected = $src.TrimEnd('\') + '\'
        $expectedSourcePaths = New-Object System.Collections.Generic.List[string]
        foreach ($injectedPath in @($script:IsoMaker_injectedFiles)) {
            if ($injectedPath -and (Test-Path -LiteralPath $injectedPath -PathType Leaf)) { $expectedSourcePaths.Add([string]$injectedPath) }
        }
        foreach ($backupEntry in @($script:IsoMaker_injectionBackups)) {
            if ($backupEntry -and $backupEntry.Original -and (Test-Path -LiteralPath $backupEntry.Original -PathType Leaf)) {
                $expectedSourcePaths.Add([string]$backupEntry.Original)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($xmlPath)) {
            $expectedSourcePaths.Add((Join-Path $src 'autounattend.xml'))
        }
        foreach ($expectedSourcePath in @($expectedSourcePaths | Select-Object -Unique)) {
            if ($expectedSourcePath.StartsWith($sourcePrefixForExpected, [StringComparison]::OrdinalIgnoreCase)) {
                $script:IsoMaker_expectedIsoFiles += $expectedSourcePath.Substring($sourcePrefixForExpected.Length)
            }
        }

        $reparseArg = if ($resolveReparsePoints) { ' -r' } else { '' }

        # Perfiles escalonados. Con UDF puro (-u1/-u2), oscdimg 2.56 rechaza
        # expresamente -a y -s; por eso ningun perfil UDF los incorpora. El ultimo
        # reproduce el comando minimo verificado: -m -o -u2 -udfver102 + etiqueta + arranque.
        $attempts = New-Object System.Collections.ArrayList
        if ($bootOrderSwitch) {
            [void]$attempts.Add([pscustomobject]@{
                Name = 'OPTIMIZADO'
                # oscdimg 2.56 no permite -a ni -s junto con -u1/-u2.
                # Se conserva BootOrder y -h, pero se elimina el modificador incompatible.
                Description = 'BootOrder + archivos ocultos (UDF 1.02 compatible)'
                Args = "-m -o -h -u2 -udfver102 -l$label $bootOrderSwitch$reparseArg $bootArg $srcArg $isoArg"
            })
        }
        [void]$attempts.Add([pscustomobject]@{
            Name = 'ESTANDAR'
            Description = 'Incluye archivos ocultos; sin BootOrder ni diagnosticos'
            Args = "-m -o -h -u2 -udfver102 -l$label$reparseArg $bootArg $srcArg $isoArg"
        })
        [void]$attempts.Add([pscustomobject]@{
            Name = 'COMPATIBILIDAD'
            Description = 'Conjunto esencial compatible con oscdimg 2.56'
            Args = "-m -o -u2 -udfver102 -l$label$reparseArg $bootArg $srcArg $isoArg"
        })

        $script:IsoMaker_buildAttempts = @($attempts)
        $script:IsoMaker_attemptIndex  = 0
        $script:IsoMaker_oscdimgExe    = $oscdimgExe

        Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: Iniciando compilacion de ISO..."
        & $script:IsoMaker_SetPhase "Analizando arbol de directorios y calculando estructura..." ($uiCyan)

        $script:IsoMaker_cleanLogBuilder = New-Object System.Text.StringBuilder
        $script:IsoMaker_cleanLogBuilder.AppendLine("PERFIL DE ARRANQUE: $bootProfile | ARQUITECTURA: $detectedArch") | Out-Null
        $script:IsoMaker_cleanLogBuilder.AppendLine("UEFI: $(if ($uefiDisponible) { Split-Path -Leaf $uefiBoot } else { 'No' }) | BIOS: $biosDisponible") | Out-Null

        $rxOptsC = [System.Text.RegularExpressions.RegexOptions]::Compiled
        $script:IsoMaker_rxPercent = [regex]::new('(\d+)%\s+complete', $rxOptsC)

        $script:IsoMaker_StartOscdimgAttempt = {
            param([Parameter(Mandatory=$true)][int]$AttemptIndex)

            $attempt = $script:IsoMaker_buildAttempts[$AttemptIndex]
            $script:IsoMaker_attemptIndex = $AttemptIndex
            $script:IsoMaker_lastPct = 0
            $pbMain.Value = 0
            $lblPercent.Text = "0 % completado"
            $lblPercent.Refresh()

            $script:IsoMaker_outQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $script:IsoMaker_errQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $script:IsoMaker_errLogBuilder = New-Object System.Text.StringBuilder
            $script:IsoMaker_attemptOutLogBuilder = New-Object System.Text.StringBuilder
            $script:IsoMaker_buildDone = [System.Threading.ManualResetEventSlim]::new($false)

            $script:IsoMaker_cleanLogBuilder.AppendLine("") | Out-Null
            $script:IsoMaker_cleanLogBuilder.AppendLine("INTENTO $($AttemptIndex + 1)/$($script:IsoMaker_buildAttempts.Count): $($attempt.Name)") | Out-Null
            $script:IsoMaker_cleanLogBuilder.AppendLine("DESCRIPCION: $($attempt.Description)") | Out-Null
            $script:IsoMaker_cleanLogBuilder.AppendLine("COMANDO:") | Out-Null
            $script:IsoMaker_cleanLogBuilder.AppendLine("oscdimg.exe $($attempt.Args)") | Out-Null
            $script:IsoMaker_cleanLogBuilder.AppendLine("----------------") | Out-Null

            $pInfo = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName               = $script:IsoMaker_oscdimgExe
            $pInfo.Arguments              = $attempt.Args
            $pInfo.RedirectStandardOutput = $true
            $pInfo.RedirectStandardError  = $true
            $pInfo.UseShellExecute        = $false
            $pInfo.CreateNoWindow         = $true

            $script:IsoMaker_isoProc           = New-Object System.Diagnostics.Process
            $script:IsoMaker_isoProc.StartInfo = $pInfo
            $script:IsoMaker_stdoutHandler     = [IsoMaker.ProcessOutputPump]::CreateHandler($script:IsoMaker_outQueue)
            $script:IsoMaker_stderrHandler     = [IsoMaker.ProcessOutputPump]::CreateHandler($script:IsoMaker_errQueue)
            $script:IsoMaker_isoProc.add_OutputDataReceived($script:IsoMaker_stdoutHandler)
            $script:IsoMaker_isoProc.add_ErrorDataReceived($script:IsoMaker_stderrHandler)

            if (-not $script:IsoMaker_isoProc.Start()) { throw "No inicio oscdimg" }
            $script:IsoMaker_isoProc.BeginOutputReadLine()
            $script:IsoMaker_isoProc.BeginErrorReadLine()

            Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: Intento $($AttemptIndex + 1)/$($script:IsoMaker_buildAttempts.Count) [$($attempt.Name)] lanzado (PID: $($script:IsoMaker_isoProc.Id)). Argumentos: oscdimg.exe $($attempt.Args)"
            & $script:IsoMaker_SetPhase "Compilando con perfil $($attempt.Name)..." ($uiCyan)
        }

        try {
            $script:IsoMaker_previousIsoBackup        = $null
            $script:IsoMaker_previousHashBackup       = $null
            $script:IsoMaker_outputTransactionStarted = $false
            $oldHashPath = [System.IO.Path]::ChangeExtension($iso, '.sha256')

            if ($replaceExistingIso -and (Test-Path -LiteralPath $iso)) {
                $script:IsoMaker_previousIsoBackup = "$iso.isomaker.$([guid]::NewGuid().ToString('N')).bak"
                Move-Item -LiteralPath $iso -Destination $script:IsoMaker_previousIsoBackup -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $oldHashPath) {
                $script:IsoMaker_previousHashBackup = "$oldHashPath.isomaker.$([guid]::NewGuid().ToString('N')).bak"
                Move-Item -LiteralPath $oldHashPath -Destination $script:IsoMaker_previousHashBackup -Force -ErrorAction Stop
            }

            $script:IsoMaker_outputTransactionStarted = $true
            & $script:IsoMaker_StartOscdimgAttempt 0

            # ============================================================
            # TEMPORIZADOR DE PROGRESO
            # ============================================================
            $script:IsoMaker_pollTimer          = New-Object System.Windows.Forms.Timer
            $script:IsoMaker_pollTimer.Interval = 50

            $pollTickScript = {
                if ($null -eq $script:IsoMaker_pollTimer) { return }

                try {
                    $line = $null

                    if ($null -ne $script:IsoMaker_outQueue) {
                        while ($script:IsoMaker_outQueue.TryDequeue([ref]$line)) {
                            # Preservar todas las lineas, incluidas las en blanco, para
                            # que el log refleje el espaciado original de la salida de oscdimg.
                            $script:IsoMaker_attemptOutLogBuilder.AppendLine($line) | Out-Null
                            if (-not [string]::IsNullOrWhiteSpace($line) -and
                                $line -match '(\d+) files in (\d+) directories') {
                                $lblFileInfo.Text = "$($matches[1]) archivos | $($matches[2]) directorios"
                                $lblFileInfo.Refresh()
                            }
                        }
                    }

                    if ($null -ne $script:IsoMaker_errQueue) {
                        while ($script:IsoMaker_errQueue.TryDequeue([ref]$line)) {
                            if ([string]::IsNullOrWhiteSpace($line)) { continue }
                            $script:IsoMaker_errLogBuilder.AppendLine($line) | Out-Null

                            $m = $script:IsoMaker_rxPercent.Match($line)
                            if ($m.Success) {
                                $pct = [int]$m.Groups[1].Value
                                $script:IsoMaker_lastPct = $pct
                                if ($pct -gt $pbMain.Value) {
                                    if ($pbMain.Value -eq 0 -and $pct -gt 0) {
                                        & $script:IsoMaker_SetPhase "Escribiendo imagen ISO en disco..." ($uiCyan)
                                    }
                                    # [FIX B1] Clampar al maximo para evitar ArgumentOutOfRangeException
                                    $pbMain.Value    = [Math]::Min($pct, $pbMain.Maximum)
                                    $lblPercent.Text = "$pct % completado"
                                    $lblPercent.Refresh()
                                    if ($pct -eq 100) {
                                        & $script:IsoMaker_SetPhase "Optimizando almacenamiento y finalizando..." ([System.Drawing.Color]::Orange)
                                    }
                                }
                            }
                        }
                    }

                    if ($null -ne $script:IsoMaker_isoProc -and $script:IsoMaker_isoProc.HasExited -and
                        $null -ne $script:IsoMaker_buildDone -and -not $script:IsoMaker_buildDone.IsSet) {
                        # WaitForExit despues de HasExited garantiza que los callbacks
                        # asincronicos de stdout/stderr hayan terminado de entregar datos.
                        try { $script:IsoMaker_isoProc.WaitForExit() } catch {}
                        $script:IsoMaker_buildDone.Set()
                    }

                    if ($null -eq $script:IsoMaker_buildDone -or -not $script:IsoMaker_buildDone.IsSet) { return }

                    # ============================================================
                    # VACIADO FINAL Y CIERRE DE HILOS
                    # ============================================================
                    while ($script:IsoMaker_outQueue.TryDequeue([ref]$line)) {
                        # Sin filtro: preservar blancos del stdout de oscdimg
                        $script:IsoMaker_attemptOutLogBuilder.AppendLine($line) | Out-Null
                    }
                    while ($script:IsoMaker_errQueue.TryDequeue([ref]$line)) {
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $script:IsoMaker_errLogBuilder.AppendLine($line) | Out-Null
                            $m2 = $script:IsoMaker_rxPercent.Match($line)
                            if ($m2.Success) { $script:IsoMaker_lastPct = [int]$m2.Groups[1].Value }
                        }
                    }

                    # Incorporar exclusivamente la salida del intento actual. Asi un
                    # reintento no vuelve a modificar las secciones de perfiles anteriores.
                    $attemptLogText = $script:IsoMaker_attemptOutLogBuilder.ToString()
                    if ($script:IsoMaker_lastPct -gt 0) {
                        $pctLine = "$($script:IsoMaker_lastPct)% complete"
                        $writingRegex = [regex]::new(
                            '(?im)(Writing \d+ files in \d+ directories[^\r\n]*)',
                            [System.Text.RegularExpressions.RegexOptions]::Compiled
                        )
                        if ($writingRegex.IsMatch($attemptLogText)) {
                            $attemptLogText = $writingRegex.Replace($attemptLogText, "`$1`r`n`r`n$pctLine", 1)
                        } else {
                            $attemptLogText += "`r`n$pctLine`r`n"
                        }
                    }
                    if (-not [string]::IsNullOrEmpty($attemptLogText)) {
                        [void]$script:IsoMaker_cleanLogBuilder.Append($attemptLogText)
                    }

                    # El evento pertenece al intento actual. El pollTimer se conserva
                    # mientras existan perfiles de compatibilidad por probar.
                    try { $script:IsoMaker_buildDone.Dispose() } catch {}
                    $script:IsoMaker_buildDone = $null

                    $exitCode = 0
                    if ($null -ne $script:IsoMaker_isoProc) {
                        try { $exitCode = $script:IsoMaker_isoProc.ExitCode } catch { $exitCode = -1 }
                    }

                    if ($exitCode -ne 0 -and
                        $script:IsoMaker_attemptIndex -lt ($script:IsoMaker_buildAttempts.Count - 1)) {

                        $failedAttempt = $script:IsoMaker_buildAttempts[$script:IsoMaker_attemptIndex]
                        $stderrAttempt = $script:IsoMaker_errLogBuilder.ToString().Trim()
                        $stdoutAttempt = $script:IsoMaker_attemptOutLogBuilder.ToString().Trim()
                        $diagnosticAttempt = if (-not [string]::IsNullOrWhiteSpace($stderrAttempt)) { $stderrAttempt } else { $stdoutAttempt }
                        $script:IsoMaker_cleanLogBuilder.AppendLine("") | Out-Null
                        $script:IsoMaker_cleanLogBuilder.AppendLine("RESULTADO: ERROR $exitCode EN PERFIL $($failedAttempt.Name)") | Out-Null
                        if (-not [string]::IsNullOrWhiteSpace($stderrAttempt)) {
                            $script:IsoMaker_cleanLogBuilder.AppendLine("SALIDA STDERR:") | Out-Null
                            $script:IsoMaker_cleanLogBuilder.AppendLine($stderrAttempt) | Out-Null
                        }

                        $nextIndex = $script:IsoMaker_attemptIndex + 1
                        $nextAttempt = $script:IsoMaker_buildAttempts[$nextIndex]
                        $detail = if ($diagnosticAttempt) {
                            ($diagnosticAttempt -split "`r?`n" |
                                Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\d+%\s+complete$' } |
                                Select-Object -First 1)
                        } else {
                            'sin detalle devuelto por oscdimg'
                        }
                        Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: Perfil $($failedAttempt.Name) fallo con codigo $exitCode ($detail). Reintentando automaticamente con $($nextAttempt.Name)."
                        & $script:IsoMaker_SetPhase "Perfil $($failedAttempt.Name) incompatible; reintentando con $($nextAttempt.Name)..." ($uiOrange)

                        & $script:IsoMaker_DisposeIsoProcess $false
                        if (Test-Path -LiteralPath $script:IsoMaker_iso) {
                            try { Remove-Item -LiteralPath $script:IsoMaker_iso -Force -ErrorAction Stop } catch {
                                throw "No se pudo eliminar la ISO parcial antes del reintento: $($_.Exception.Message)"
                            }
                        }

                        try {
                            & $script:IsoMaker_StartOscdimgAttempt $nextIndex
                            return
                        } catch {
                            $exitCode = -3
                            $script:IsoMaker_errLogBuilder.AppendLine("ISO_Maker: No se pudo iniciar el perfil de reintento: $($_.Exception.Message)") | Out-Null
                        }
                    }

                    if ($null -ne $script:IsoMaker_pollTimer) {
                        try { $script:IsoMaker_pollTimer.Stop() } catch {}
                        try { $script:IsoMaker_pollTimer.Dispose() } catch {}
                        $script:IsoMaker_pollTimer = $null
                    }

                    if ($exitCode -eq 0) {
                        try {
                            $isoItem = Get-Item -LiteralPath $script:IsoMaker_iso -ErrorAction Stop
                            if ($isoItem.Length -le 0) { throw "El archivo ISO generado esta vacio." }
                        } catch {
                            $exitCode = -2
                            $script:IsoMaker_errLogBuilder.AppendLine("ISO_Maker: oscdimg finalizo sin producir una ISO valida: $($_.Exception.Message)") | Out-Null
                        }
                    }

                    # ==================== PATH EXITO ====================
                    if ($exitCode -eq 0) {
                        $successfulAttempt = $script:IsoMaker_buildAttempts[$script:IsoMaker_attemptIndex]
                        $script:IsoMaker_cleanLogBuilder.AppendLine("") | Out-Null
                        $script:IsoMaker_cleanLogBuilder.AppendLine("RESULTADO: CORRECTO EN PERFIL $($successfulAttempt.Name)") | Out-Null
                        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Compilacion completada correctamente con el perfil $($successfulAttempt.Name)."

                        & $script:IsoMaker_FinalizeIsoOutput $true
                        & $script:IsoMaker_CleanupInjectedFiles
                        $btnCancel.Visible = $false
                        $btnMake.Size      = "590, 40"
                        & $script:IsoMaker_SetPhase "Calculando Hash SHA256 (esto puede tomar unos minutos)..." ([System.Drawing.Color]::Orange)

                        $script:IsoMaker_hashRS = [runspacefactory]::CreateRunspace()
                        $script:IsoMaker_hashRS.Open()
                        # [FIX C1] Inyectar la ruta via SessionStateProxy en lugar de AddArgument.
                        # AddArgument pasa el valor como elemento de pipeline ($input), no como
                        # argumento del param() declarado en el script-block -> $isoPath era $null.
                        $script:IsoMaker_hashRS.SessionStateProxy.SetVariable('isoPath', $script:IsoMaker_iso)
                        $script:IsoMaker_hashPS = [powershell]::Create()
                        $script:IsoMaker_hashPS.Runspace = $script:IsoMaker_hashRS
                        [void]$script:IsoMaker_hashPS.AddScript({
                            try {
                                $sha256   = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash
                                $hashFile = [System.IO.Path]::ChangeExtension($isoPath, '.sha256')
                                $hashLine = "$sha256  $([System.IO.Path]::GetFileName($isoPath))`r`n"
                                [System.IO.File]::WriteAllText($hashFile, $hashLine, [System.Text.Encoding]::ASCII)
                                return $sha256
                            } catch {
                                return "ERROR: $($_.Exception.Message)"
                            }
                        })
                        $script:IsoMaker_hashHandle = $script:IsoMaker_hashPS.BeginInvoke()

                        $script:IsoMaker_hashTimer          = New-Object System.Windows.Forms.Timer
                        $script:IsoMaker_hashTimer.Interval = 200
                        $script:IsoMaker_hashTimer.Add_Tick({
                            if ($null -eq $script:IsoMaker_hashHandle -or $null -eq $script:IsoMaker_hashPS) { return }
                            if (-not $script:IsoMaker_hashHandle.IsCompleted) { return }

                            try {
                                if ($null -ne $script:IsoMaker_hashTimer) {
                                    $script:IsoMaker_hashTimer.Stop()
                                    $script:IsoMaker_hashTimer.Dispose()
                                    $script:IsoMaker_hashTimer = $null
                                }

                                # EndInvoke puede fallar si el formulario se cierra o el runspace se interrumpe.
                                # Convertir cualquier excepcion en un resultado visible y continuar con el resumen.
                                $script:IsoMaker_lastBuildHash = [string]($script:IsoMaker_hashPS.EndInvoke($script:IsoMaker_hashHandle) | Select-Object -First 1)
                                if ([string]::IsNullOrWhiteSpace($script:IsoMaker_lastBuildHash)) {
                                    $script:IsoMaker_lastBuildHash = 'ERROR: El calculo SHA-256 no devolvio ningun resultado.'
                                }
                            } catch {
                                $script:IsoMaker_lastBuildHash = "ERROR: $($_.Exception.Message)"
                            } finally {
                                if ($null -ne $script:IsoMaker_hashPS) { try { $script:IsoMaker_hashPS.Dispose() } catch {} }
                                if ($null -ne $script:IsoMaker_hashRS) { try { $script:IsoMaker_hashRS.Close(); $script:IsoMaker_hashRS.Dispose() } catch {} }
                                $script:IsoMaker_hashPS = $null; $script:IsoMaker_hashRS = $null; $script:IsoMaker_hashHandle = $null
                            }

                            if ($script:IsoMaker_lastBuildHash -and $script:IsoMaker_lastBuildHash -notmatch '^ERROR') {
                                Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: SHA-256 calculado: $script:IsoMaker_lastBuildHash"
                            } else {
                                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: Fallo el calculo del hash SHA-256: $script:IsoMaker_lastBuildHash"
                            }

& $script:IsoMaker_SetPhase 'Verificando estructura de la ISO generada...' ($uiCyan)
$script:IsoMaker_verificationResult = & $script:IsoMaker_TestIsoImage `
    -IsoPath $script:IsoMaker_iso `
    -BootProfile $script:IsoMaker_buildBootProfile `
    -RequireInstallImage ([bool]$script:IsoMaker_requireInstallImage) `
    -ExpectedFiles @($script:IsoMaker_expectedIsoFiles) `
    -ExpectedVolumeLabel $label
$script:IsoMaker_cleanLogBuilder.AppendLine('') | Out-Null
$script:IsoMaker_cleanLogBuilder.AppendLine('VALIDACION POST-BUILD:') | Out-Null
foreach($check in @($script:IsoMaker_verificationResult.Checks)) {
    $script:IsoMaker_cleanLogBuilder.AppendLine(" - $($check.Item): $(if($check.Present){'CORRECTO'}else{'FALTA'})") | Out-Null
}
if ($script:IsoMaker_verificationResult.Errors.Count -gt 0) {
    foreach($verifyError in $script:IsoMaker_verificationResult.Errors) { $script:IsoMaker_cleanLogBuilder.AppendLine(" - ERROR: $verifyError") | Out-Null }
}
if ($script:IsoMaker_verificationResult.Warnings.Count -gt 0) {
    foreach($verifyWarning in $script:IsoMaker_verificationResult.Warnings) { $script:IsoMaker_cleanLogBuilder.AppendLine(" - ADVERTENCIA: $verifyWarning") | Out-Null }
}
if (-not $script:IsoMaker_verificationResult.Valid) {
    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: La ISO se creo, pero fallo la validacion post-build: $($script:IsoMaker_verificationResult.Errors -join ' | ')"
    & $script:IsoMaker_SetPhase 'ISO creada con advertencias: fallo la validacion post-build.' ([System.Drawing.Color]::Orange)
} else {
    Write-IsoMakerLog -LogLevel ACTION -Message 'ISO_Maker: Validacion post-build completada correctamente.'
}

                            $fullLogText = $script:IsoMaker_cleanLogBuilder.ToString()

                            # ==============================================================================
                            # LIMPIEZA DE LOG (OSCDIMG)
                            # ==============================================================================
                            # 1. Agrupar la cabecera: Unir "Premastering Utility" con "Copyright"
                            $fullLogText = $fullLogText -replace "(?im)(Premastering Utility)\s+(Copyright)", "`$1`r`n`$2"

                            # 2. Agrupar las líneas de "Scanning source tree" (absorbiendo espacios invisibles finales)
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)(Scanning source tree[^\r\n]*)\r?\n\s*(Scanning source tree complete)', "`$1`r`n`$2")

                            # 3. Agrupar las líneas de "Computing directory information"
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)(Computing directory information[^\r\n]*)\r?\n\s*(Computing directory information complete)', "`$1`r`n`$2")
							
                            # 4. Fijar estrictamente el espaciado alrededor del porcentaje.
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)\s*(100% complete)\s+', "`r`n`r`n`$1`r`n`r`n")

                            # 5. Reducir cualquier exceso de saltos de línea (3 o más) a exactamente una línea en blanco (\r\n\r\n) en el resto del documento
                            $fullLogText = [regex]::Replace($fullLogText, '(\r?\n){3,}', "`r`n`r`n")

                            # 6. (Opcional) Restaurar un salto doble para separar el comando de la cabecera oscdimg
                            $fullLogText = $fullLogText -replace "----------------\r?\nOSCDIMG", "----------------`r`n`r`nOSCDIMG"

                            $script:IsoMaker_lastBuildLog = $fullLogText

                            try {
                                $timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
                                $logFileName = "ISO_Build_$timestamp.log"
                                if ($null -ne $script:IsoMaker_logDir) {
                                    $logPath = Join-Path $script:IsoMaker_logDir $logFileName
                                    $fullLogText | Out-File -FilePath $logPath -Encoding utf8 -Force
                                    Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: Log de compilacion guardado en: $logPath"
                                }
                            } catch {}

                            $rxOptsCI  = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
                                         [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                            $mScanFull = [regex]::Match($fullLogText, 'Scanning source tree complete \((\d+) files in (\d+) directories\)', $rxOptsCI)
                            $mImgBefor = [regex]::Match($fullLogText, 'Image file is (\d+) bytes',                                          $rxOptsCI)
                            $mOptSaved = [regex]::Match($fullLogText, '(Storage optimization saved [^\r\n]+)',                               $rxOptsCI)
                            $mImgAfter = [regex]::Match($fullLogText, 'After optimization, image file is (\d+) bytes',                      $rxOptsCI)
                            $mSpcSaved = [regex]::Match($fullLogText, 'Space saved.*?=\s*(\d+)',                                             $rxOptsCI)

                            $cFiles  = if ($mScanFull.Success) { $mScanFull.Groups[1].Value } else { "0" }
                            $cDirs   = if ($mScanFull.Success) { $mScanFull.Groups[2].Value } else { "0" }
                            $bBefore = if ($mImgBefor.Success) { [long]$mImgBefor.Groups[1].Value } else { 0 }
                            $bAfter  = if ($mImgAfter.Success) { [long]$mImgAfter.Groups[1].Value } else { 0 }
                            $bSaved  = if ($mSpcSaved.Success) { [long]$mSpcSaved.Groups[1].Value } else { 0 }

                            $fmt = { param($b) if ($b -ge 1GB) { "$([math]::Round($b/1GB,2)) GB" } elseif ($b -ge 1MB) { "$([math]::Round($b/1MB,2)) MB" } else { "$b bytes" } }
                            $strBefore = & $fmt $bBefore
                            $strAfter  = & $fmt $bAfter
                            $strSaved  = & $fmt $bSaved

                            $btnExportLog.Enabled   = $true
                            $btnExportLog.ForeColor = [System.Drawing.Color]::Silver
                            if ($script:IsoMaker_verificationResult.Valid) {
                                & $script:IsoMaker_SetPhase "ISO creada y verificada correctamente en: $script:IsoMaker_iso" ($uiGreen)
                            } else {
                                & $script:IsoMaker_SetPhase "ISO creada, pero con errores de verificacion: $script:IsoMaker_iso" ([System.Drawing.Color]::Orange)
                            }
                            $btnOpenFolder.Visible = $true

                            $lblFileInfo.Text = if ($mOptSaved.Success) {
                                "$cFiles archivos | $cDirs directorios | Optimizacion: $($mOptSaved.Groups[1].Value.Replace('Storage optimization saved ',''))"
                            } else {
                                "$cFiles archivos | $cDirs directorios"
                            }
                            if ($bAfter -gt 0) { $lblSizeInfo.Text = "Tamaño final: $strAfter ($bAfter bytes)" }

                            if ($script:IsoMaker_lastBuildHash -and $script:IsoMaker_lastBuildHash -notmatch '^ERROR') {
                                $lblHashInfo.Text      = "SHA-256:`n$script:IsoMaker_lastBuildHash"
                                $lblHashInfo.ForeColor = $uiGreen
                            } else {
                                $lblHashInfo.Text      = "SHA-256: Error al calcular"
                                $lblHashInfo.ForeColor = [System.Drawing.Color]::Orange
                            }

                            $form.Refresh()

                            if ($script:IsoMaker_verificationResult.Valid) {
                                Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: ISO generada y verificada correctamente. Archivos: $cFiles | Tamaño final: $strAfter | Espacio ahorrado: $strSaved | Destino: $script:IsoMaker_iso"
                                $msgSummary = "La imagen ISO se ha compilado y verificado correctamente.`n`n"
                            } else {
                                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: ISO generada, pero con errores de verificacion. Destino: $script:IsoMaker_iso"
                                $msgSummary = "La imagen ISO se compilo, pero la validacion posterior encontro errores.`n`n"
                            }
                            $msgSummary += "ESTADISTICAS DE COMPILACION:`n"
                            $msgSummary += "-------------------------------------------------------------`n"
                            $msgSummary += " Archivos inyectados  : $cFiles (en $cDirs carpetas)`n"
                            $msgSummary += " Tamaño original      : $strBefore`n"
                            $msgSummary += " Tamaño optimizado    : $strAfter`n"
                            $msgSummary += " Espacio ahorrado     : $strSaved`n"
                            $msgSummary += "-------------------------------------------------------------`n`n"
                            $msgSummary += "Ruta de la imagen:`n$script:IsoMaker_iso"
                            $msgSummary += "`n`nValidacion post-build: $(if($script:IsoMaker_verificationResult.Valid){'CORRECTA'}else{'CON ERRORES'})"
                            if (-not $script:IsoMaker_verificationResult.Valid) {
                                $msgSummary += "`n" + (($script:IsoMaker_verificationResult.Errors | ForEach-Object { " - $_" }) -join "`n")
                            }
                            if ($script:IsoMaker_verificationResult.Warnings.Count -gt 0) {
                                $msgSummary += "`nAdvertencias:`n" + (($script:IsoMaker_verificationResult.Warnings | ForEach-Object { " - $_" }) -join "`n")
                            }
                            if ($script:IsoMaker_lastBuildHash -and $script:IsoMaker_lastBuildHash -notmatch '^ERROR') {
                                $msgSummary += "`n`nSHA-256:`n$script:IsoMaker_lastBuildHash"
                            }
                            $summaryTitle = if ($script:IsoMaker_verificationResult.Valid) { 'ISO Creada con Exito' } else { 'ISO Creada con Advertencias' }
                            $summaryIcon  = if ($script:IsoMaker_verificationResult.Valid) { 'Information' } else { 'Warning' }
                            [System.Windows.Forms.MessageBox]::Show($msgSummary, $summaryTitle, 'OK', $summaryIcon)

                            # [FIX B3] Cleanup con orden correcto por profundidad
                            & $script:IsoMaker_CleanupInjectedFiles

                            & $script:IsoMaker_DisposeIsoProcess $false

                            & $script:IsoMaker_RestoreCompileUI
                        })
                        $script:IsoMaker_hashTimer.Start()

                    # ==================== PATH ERROR ====================
                    } else {
                        $script:IsoMaker_cleanLogBuilder.AppendLine("`r`n=== ERRORES REPORTADOS ===") | Out-Null
                        $script:IsoMaker_cleanLogBuilder.AppendLine($script:IsoMaker_errLogBuilder.ToString()) | Out-Null
                        $script:IsoMaker_lastBuildLog = $script:IsoMaker_cleanLogBuilder.ToString()

                        $finalDiagnosticText = $script:IsoMaker_errLogBuilder.ToString().Trim()
                        if ([string]::IsNullOrWhiteSpace($finalDiagnosticText)) {
                            $finalDiagnosticText = $script:IsoMaker_attemptOutLogBuilder.ToString().Trim()
                        }
                        $errorLines = @(
                            $finalDiagnosticText -split "`r?`n" |
                            Where-Object {
                                -not [string]::IsNullOrWhiteSpace($_) -and
                                $_.Trim() -notmatch '^\d+%\s+complete$'
                            } |
                            Select-Object -First 8
                        )
                        $errorSummary = if ($errorLines.Count -gt 0) { $errorLines -join ' | ' } else { 'oscdimg no devolvio texto de error.' }
                        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Fallo la compilacion. Codigo de salida $exitCode. Detalle: $errorSummary"

                        try {
                            if ($script:IsoMaker_logDir) {
                                $failureStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                                $failureLog = Join-Path $script:IsoMaker_logDir "ISO_Build_ERROR_$failureStamp.log"
                                [System.IO.File]::WriteAllText($failureLog, $script:IsoMaker_lastBuildLog, ([System.Text.UTF8Encoding]::new($true)))
                                Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Log detallado del fallo guardado automaticamente en: $failureLog"
                            }
                        } catch {
                            Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: No se pudo guardar automaticamente el log detallado del fallo: $($_.Exception.Message)"
                        }
                        $pbMain.Value    = 0
                        $lblPercent.Text = "Error (Codigo: $exitCode)"
                        $lblPercent.Refresh()
                        & $script:IsoMaker_SetPhase "Fallo la compilacion. Codigo: $exitCode" ([System.Drawing.Color]::Crimson)
                        [System.Windows.Forms.MessageBox]::Show(
                            "Fallo la creacion de la ISO despues de probar todos los perfiles compatibles.`n`nCodigo de salida: $exitCode`nDetalle: $errorSummary`n`nEl log detallado se guardo automaticamente en la carpeta Logs.",
                            "Error de compilacion",
                            'OK',
                            'Error'
                        )

                        & $script:IsoMaker_CleanupInjectedFiles
                        & $script:IsoMaker_FinalizeIsoOutput $false
                        & $script:IsoMaker_DisposeIsoProcess $true
                        $btnExportLog.Enabled = $true

                        & $script:IsoMaker_RestoreCompileUI
                    }

                } catch {
                    Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Error critico en el bucle de actualizacion de progreso: $($_.Exception.Message)"
                    # [FIX B2] Garantizar liberacion en el path de excepcion del propio tick
                    if ($null -ne $script:IsoMaker_pollTimer) {
                        try { $script:IsoMaker_pollTimer.Stop(); $script:IsoMaker_pollTimer.Dispose() } catch {}
                        $script:IsoMaker_pollTimer = $null
                    }
                    if ($null -ne $script:IsoMaker_buildDone) {
                        try { $script:IsoMaker_buildDone.Dispose() } catch {}
                        $script:IsoMaker_buildDone = $null
                    }
                    & $script:IsoMaker_DisposeIsoProcess $true
                    & $script:IsoMaker_CleanupInjectedFiles
                    & $script:IsoMaker_FinalizeIsoOutput $false
                    Write-Warning "pollTimer encontro un error critico: $($_.Exception.Message)`nStack: $($_.Exception.StackTrace)"
                    & $script:IsoMaker_RestoreCompileUI
                }
            }

            $script:IsoMaker_pollTimer.Add_Tick($pollTickScript)
            $script:IsoMaker_pollTimer.Start()

        } catch {
            Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Excepcion no controlada en el motor de compilacion: $($_.Exception.Message)"
            & $script:IsoMaker_SetPhase "Excepcion: $($_.Exception.Message)" ([System.Drawing.Color]::Crimson)
            [System.Windows.Forms.MessageBox]::Show("Excepcion: $_", "Crash", 'OK', 'Error')

            # [FIX B2] Liberar timer y buildDone en el catch exterior del btnMake
            if ($null -ne $script:IsoMaker_pollTimer) {
                try { $script:IsoMaker_pollTimer.Stop(); $script:IsoMaker_pollTimer.Dispose() } catch {}
                $script:IsoMaker_pollTimer = $null
            }
            if ($null -ne $script:IsoMaker_buildDone) {
                try { $script:IsoMaker_buildDone.Dispose() } catch {}
                $script:IsoMaker_buildDone = $null
            }
            & $script:IsoMaker_DisposeIsoProcess $true
            & $script:IsoMaker_CleanupInjectedFiles
            & $script:IsoMaker_FinalizeIsoOutput $false
            & $script:IsoMaker_RestoreCompileUI
        }
    })

    # ------------------------------------------------------------------
    # 7. Botones de accion post-build
    # ------------------------------------------------------------------
    $btnExportLog.Add_Click({
        if (-not $script:IsoMaker_lastBuildLog) {
            [System.Windows.Forms.MessageBox]::Show("No hay ningun log de compilacion disponible aun.`nRealiza una compilacion primero.", "Sin Log", 'OK', 'Information')
            return
        }
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = "Archivo de Log (*.txt)|*.txt|Todos los archivos (*.*)|*.*"
        $sfd.FileName = "ISO_Maker_Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        if ($sfd.ShowDialog() -eq 'OK') {
            try {
                $script:IsoMaker_lastBuildLog | Out-File -FilePath $sfd.FileName -Encoding utf8 -Force
                Write-IsoMakerLog -LogLevel ACTION -Message "ISO_Maker: Log exportado manualmente a: $($sfd.FileName)"
                [System.Windows.Forms.MessageBox]::Show("Log exportado correctamente en:`n$($sfd.FileName)", "Log Exportado", 'OK', 'Information')
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al exportar el log:`n$($_.Exception.Message)", "Error", 'OK', 'Error')
            }
        }
    })

    $btnOpenFolder.Add_Click({
        $target = if ($script:IsoMaker_iso) { Split-Path -Parent $script:IsoMaker_iso } else { $null }
        if ($target -and (Test-Path -LiteralPath $target)) {
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: El usuario abrio la carpeta de destino: $target"
            Invoke-Item -LiteralPath $target
        } else {
            [System.Windows.Forms.MessageBox]::Show("No se pudo determinar la carpeta de destino.", "Error", 'OK', 'Warning')
        }
    })

    # ------------------------------------------------------------------
    # 8. Evento FormClosing — [FIX B4]
    # Cleanup incondicional de runspaces DISM/Size al inicio, fuera de
    # cualquier condicional, para que se ejecute siempre independientemente
    # de si hay o no una compilacion activa.
    # ------------------------------------------------------------------
    $form.Add_FormClosing({
        param($sender, $e)

        # Cleanup incondicional: runspaces de analisis en background (DISM y Tamaño)
        foreach ($t in @($script:IsoMaker_sizeTimer, $script:IsoMaker_dismTimer)) {
            if ($null -ne $t) { try { $t.Stop(); $t.Dispose() } catch {} }
        }
        foreach ($p in @($script:IsoMaker_sizePS, $script:IsoMaker_dismPS)) {
            if ($null -ne $p) { try { $p.Stop(); $p.Dispose() } catch {} }
        }
        foreach ($r in @($script:IsoMaker_sizeRS, $script:IsoMaker_dismRS)) {
            if ($null -ne $r) { try { $r.Close(); $r.Dispose() } catch {} }
        }
        $script:IsoMaker_sizeTimer = $null; $script:IsoMaker_dismTimer = $null
        $script:IsoMaker_sizePS    = $null; $script:IsoMaker_dismPS    = $null
        $script:IsoMaker_sizeRS    = $null; $script:IsoMaker_dismRS    = $null

        # Si hay compilacion activa, pedir confirmacion antes de abortar
        if ($null -ne $script:IsoMaker_isoProc -and -not $script:IsoMaker_isoProc.HasExited) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "La ISO se esta compilando en este momento.`nSi sales ahora, la operacion se cancelara, se eliminara la salida parcial y se restaurara la version anterior cuando corresponda.`n`n¿Deseas forzar la salida?",
                "Advertencia de Interrupcion",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($res -eq 'No') {
                $e.Cancel = $true
            } else {
                Write-IsoMakerLog -LogLevel WARN -Message "ISO_Maker: El usuario forzo el cierre de la aplicacion durante la compilacion."

                if ($null -ne $script:IsoMaker_pollTimer) {
                    try { $script:IsoMaker_pollTimer.Stop(); $script:IsoMaker_pollTimer.Dispose() } catch {}
                    $script:IsoMaker_pollTimer = $null
                }
                if ($null -ne $script:IsoMaker_hashTimer) {
                    try { $script:IsoMaker_hashTimer.Stop(); $script:IsoMaker_hashTimer.Dispose() } catch {}
                    $script:IsoMaker_hashTimer = $null
                }
                if ($null -ne $script:IsoMaker_buildDone) {
                    try { $script:IsoMaker_buildDone.Dispose() } catch {}
                    $script:IsoMaker_buildDone = $null
                }
                if ($null -ne $script:IsoMaker_hashPS) { try { $script:IsoMaker_hashPS.Stop(); $script:IsoMaker_hashPS.Dispose() } catch {}; $script:IsoMaker_hashPS = $null }
                if ($null -ne $script:IsoMaker_hashRS) { try { $script:IsoMaker_hashRS.Close(); $script:IsoMaker_hashRS.Dispose() } catch {}; $script:IsoMaker_hashRS = $null }

                & $script:IsoMaker_DisposeIsoProcess $true
                [void](& $script:IsoMaker_CaptureInterruptedBuildLog 'INTERRUMPIDO POR CIERRE FORZADO' 'ISO_Build_INTERRUPTED')
                $script:IsoMaker_outQueue = $null
                $script:IsoMaker_errQueue = $null
                & $script:IsoMaker_CleanupInjectedFiles
                & $script:IsoMaker_FinalizeIsoOutput $false
            }
        }
        if (-not $e.Cancel) {
            # El hash se ejecuta despues de que oscdimg termina; por eso debe limpiarse
            # incluso cuando ya no existe un proceso de compilacion activo.
            if ($null -ne $script:IsoMaker_hashTimer) {
                try { $script:IsoMaker_hashTimer.Stop(); $script:IsoMaker_hashTimer.Dispose() } catch {}
                $script:IsoMaker_hashTimer = $null
            }
            if ($null -ne $script:IsoMaker_hashPS) { try { $script:IsoMaker_hashPS.Stop(); $script:IsoMaker_hashPS.Dispose() } catch {}; $script:IsoMaker_hashPS = $null }
            if ($null -ne $script:IsoMaker_hashRS) { try { $script:IsoMaker_hashRS.Close(); $script:IsoMaker_hashRS.Dispose() } catch {}; $script:IsoMaker_hashRS = $null }
            $script:IsoMaker_hashHandle = $null

            if ($null -ne $script:IsoMaker_pollTimer) {
                try { $script:IsoMaker_pollTimer.Stop(); $script:IsoMaker_pollTimer.Dispose() } catch {}
                $script:IsoMaker_pollTimer = $null
            }
            if ($null -ne $script:IsoMaker_buildDone) {
                try { $script:IsoMaker_buildDone.Dispose() } catch {}
                $script:IsoMaker_buildDone = $null
            }

            & $script:IsoMaker_DisposeIsoProcess $false
            & $script:IsoMaker_CleanupInjectedFiles
            & $script:IsoMaker_FinalizeIsoOutput $false

            # Liberar ToolTip solo cuando el cierre realmente continuara.
            if ($null -ne $tip -and -not $tip.IsDisposed) { try { $tip.Dispose() } catch {} }
            Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Sesion finalizada. Formulario cerrado por el usuario."
        }
    })

    # ------------------------------------------------------------------
    # 9. Mostrar y limpiar
    # ------------------------------------------------------------------
        $form.ShowDialog() | Out-Null
        $form.Dispose()
        [GC]::Collect()
    } catch {
        $startupError = $_.Exception.Message
        Write-IsoMakerLog -LogLevel ERROR -Message "ISO_Maker: Error fatal durante el inicio o ejecucion de la interfaz: $startupError | $($_.ScriptStackTrace)"
        try {
            if ($null -ne $form -and -not $form.IsDisposed) { $form.Dispose() }
        } catch {}
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "El Generador de ISO no pudo continuar.`n`nDetalle:`n$startupError`n`nRevisa el directorio de Logs para obtener mas informacion.",
                "ISO Maker - Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } catch {
            Write-Warning "ISO_Maker no pudo continuar: $startupError"
        }
    } finally {
        Write-IsoMakerLog -LogLevel INFO -Message "ISO_Maker: Control devuelto al menu principal."
    }
}