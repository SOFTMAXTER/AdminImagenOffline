# =================================================================
#  Modulo-Addons
#
#  CONTENIDO   : Expand-AddonArchive, Install-OfflineAddon, Show-Addons-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Enable-Privileges      : habilitar privilegios de token
#    - Import-OfflineReg      : inyeccion de payloads de registro
#    - Restore-AllOfflineSDDL : restaurar SDDL diferido de archivos/claves
#  CARGA       : . "$PSScriptRoot\Modulo-Addons.ps1"
#
#  NO modificar las firmas de funcion; el nucleo las invoca por nombre.
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

# =================================================================
#  MODULO DE INYECCION DE ADDONS (.TPK, .BPK, .REG,)
# =================================================================
# --- HELPER: Extractor Inteligente por Analisis de Cabecera ---
function Expand-AddonArchive {
    param([string]$FilePath, [string]$DestPath, [int]$WimIndex = 1)
    
    # 1. Validar Firma Binaria
    $stream = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = New-Object byte[] 4
    $stream.Read($buffer, 0, 4) | Out-Null
    $stream.Close()
    $hexSignature = [BitConverter]::ToString($buffer) -replace '-'

    if (-not (Test-Path $DestPath)) { New-Item -Path $DestPath -ItemType Directory -Force | Out-Null }

    if ($hexSignature -match "^4D535749") { 
        $actualIndexToExtract = $WimIndex

        # 2. Contar índices usando DISM nativo (Ignora la extensión del archivo)
        $dismInfo = dism.exe /Get-WimInfo /WimFile:"$FilePath" /English | Select-String "Index :"
        $indexCount = @($dismInfo).Count

        # 3. Lógica de Fallback Estricta
        if ($indexCount -eq 1) {
            $actualIndexToExtract = 1
            Write-Log -LogLevel INFO -Message "Paquete de indice unico detectado ($indexCount). Forzando extraccion del Indice 1."
        } elseif ($indexCount -eq 0) {
            # Fallback por si la consola falla al leer
            $actualIndexToExtract = 1
            Write-Log -LogLevel WARN -Message "No se pudieron contar los indices. Forzando Indice 1 por seguridad."
        }

        Write-Log -LogLevel INFO -Message "Firma detectada: WIM (MSWI). Extrayendo payload (Indice $actualIndexToExtract)..."

        # 4. Extraer usando DISM nativo
        $proc = Start-Process "dism.exe" -ArgumentList "/Apply-Image /ImageFile:`"$FilePath`" /Index:$actualIndexToExtract /ApplyDir:`"$DestPath`"" -Wait -NoNewWindow -PassThru
        
        if ($proc.ExitCode -ne 0) {
            throw "DISM /Apply-Image fallo al extraer el paquete (Codigo de salida: $($proc.ExitCode))."
        }
    }
    else {
        throw "Formato no reconocido (Firma: $hexSignature). No es un empaquetado valido."
    }
}

# --- MOTOR PRINCIPAL: Inyector de Addons ---
function Install-OfflineAddon {
    param([string]$FilePath, [int]$WimIndex = 1)
    
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    
    if ($ext -eq '.reg') {
        Import-OfflineReg -FilePath $FilePath
        return "Registro inyectado exitosamente."
    }

    if ($ext -match '\.(wim|tpk|bpk)$') {
        $tempExtract = Join-Path $Script:Scratch_DIR "Addon_$baseName"

        try {
            # Extraemos el payload usando nuestro extractor blindado
            Expand-AddonArchive -FilePath $FilePath -DestPath $tempExtract -WimIndex $WimIndex

            # --- FASE A: Inyeccion de Archivos (Mapeo de Estructura Blindado) ---
            $hasFiles = $false
            
            # Verificamos si hay ALGO en la raiz extraida (Excluyendo los .reg)
            $payloadFiles = Get-ChildItem -Path $tempExtract -Force | Where-Object { $_.Extension -ne '.reg' }
            
            if ($payloadFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando estructura de archivos completa hacia $Script:MOUNT_DIR"
                
                # Activamos privilegios (SeBackup / SeRestore)
                Enable-Privileges

                $safeMountDir = $Script:MOUNT_DIR.TrimEnd('\', '/')

				# Usamos Robocopy en Modo Backup (/B) para ignorar permisos de TrustedInstaller
                # /E = Recursivo | /B = Backup Mode | /IS = Sobrescribir iguales | /IT = Sobrescribir modificados
                # /R:0 /W:0 = Sin reintentos | /NJH /NJS /NDL /NC /NS /NP = Totalmente silencioso
                $roboArgs = "`"$tempExtract`" `"$safeMountDir`" /E /B /IS /IT /R:0 /W:0 /NJH /NJS /NDL /NC /NS /NP"
                
                $proc = Start-Process robocopy.exe -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
                
                # Evaluamos el bitmask de Robocopy (8 o superior es fallo critico)
                if ($proc.ExitCode -ge 8) {
                    Write-Log -LogLevel ERROR -Message "Robocopy fallo al inyectar la carga util (Codigo: $($proc.ExitCode))"
                    throw "Robocopy fallo en $safeMountDir. Bug de sintaxis o bloqueo de archivos. (Codigo: $($proc.ExitCode))"
                }
                
                $hasFiles = $true
            }

            # --- FASE B: Inyección de Registro ---
            $regFiles = Get-ChildItem -Path $tempExtract -Filter "*.reg" -Recurse
            foreach ($reg in $regFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando registro adjunto: $($reg.Name)"
                Import-OfflineReg -FilePath $reg.FullName
            }

            $msg = "Inyectado: "
            if ($hasFiles) { $msg += "[Archivos] " }
            if ($regFiles) { $msg += "[Registro] " }
            return $msg.Trim()

        } finally {
            # Limpieza absoluta garantizada
            if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    throw "Formato no soportado para inyeccion automatica."
}

# ============================================================================
# --- COMPATIBILIDAD: Paquetes DeltaPack Dual-Engine (manifest_*.json) ------
# ============================================================================

function Get-DeltaPackManifest {
    param([Parameter(Mandatory=$true)][string]$PackagePath)

    $manifestFile = Get-ChildItem -Path $PackagePath -Filter "manifest_*.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $manifestFile) {
        throw "No se encontro 'manifest_*.json' en '$PackagePath'. No es un paquete DeltaPack Dual-Engine valido."
    }

    try {
        $manifest = Get-Content -Path $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "El manifest '$($manifestFile.Name)' no es un JSON valido: $($_.Exception.Message)"
    }

    if (-not $manifest.generatedBy -or $manifest.generatedBy -notmatch 'DeltaPack') {
        throw "El manifest '$($manifestFile.Name)' no fue generado por DeltaPack Dual-Engine."
    }
    if (-not $manifest.outputs) {
        throw "El manifest '$($manifestFile.Name)' no contiene la seccion 'outputs' esperada (esquema no soportado)."
    }

    Add-Member -InputObject $manifest -NotePropertyName '_ManifestPath' -NotePropertyValue $manifestFile.FullName -Force
    Add-Member -InputObject $manifest -NotePropertyName '_PackagePath'  -NotePropertyValue (Resolve-Path $PackagePath).Path -Force
    return $manifest
}

function Invoke-DeltaPackDeletions {
    param([Parameter(Mandatory=$true)][string]$DeletionsPath)

    $deletions = Get-Content -Path $DeletionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $applied = 0; $notFound = 0; $failed = 0

    foreach ($entry in @($deletions.entries)) {
        if ($entry.operation -ne 'delete') { continue }
        $targetPath = Join-Path $Script:MOUNT_DIR $entry.path
        try {
            if (Test-Path -LiteralPath $targetPath) {
                if ($entry.kind -eq 'directory') {
                    Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
                } else {
                    Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                }
                $applied++
                Write-Log -LogLevel INFO -Message "DeltaPackDeletions: Tombstone aplicado -> $($entry.path)"
            } else {
                $notFound++
                Write-Log -LogLevel INFO -Message "DeltaPackDeletions: Ruta ya inexistente (omitido) -> $($entry.path)"
            }
        } catch {
            $failed++
            Write-Log -LogLevel ERROR -Message "DeltaPackDeletions: Fallo al eliminar '$($entry.path)': $($_.Exception.Message)"
        }
    }

    Write-Log -LogLevel ACTION -Message "DeltaPackDeletions: Aplicadas=$applied Inexistentes=$notFound Fallidas=$failed (Total accionables: $($deletions.actionableEntryCount))"

    if ($failed -gt 0) {
        throw "$failed eliminacion(es) obligatorias del paquete (Deletions JSON) no se pudieron aplicar. Revisa el log."
    }
    return $applied
}

function Invoke-DeltaPackActions {
    param(
        [Parameter(Mandatory=$true)][string]$ActionsPath,
        [Parameter(Mandatory=$true)][ValidateSet('afterWimBeforeRegistry','afterRegistry')][string]$Phase
    )

    $actions = Get-Content -Path $ActionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $phaseData = $actions.phases.$Phase
    if (-not $phaseData) { return }

    if ($Phase -eq 'afterWimBeforeRegistry') {
        foreach ($drv in @($phaseData.driverPackages)) {
            $infFull = Join-Path $Script:MOUNT_DIR $drv.infPath
            if (Test-Path -LiteralPath $infFull) {
                Write-Log -LogLevel ACTION -Message "DeltaPackActions: Registrando driver offline -> $($drv.infPath)"
                $proc = Start-Process "dism.exe" -ArgumentList "/Image:`"$($Script:MOUNT_DIR.TrimEnd('\'))`" /Add-Driver /Driver:`"$infFull`" /ForceUnsigned" -Wait -NoNewWindow -PassThru
                if ($proc.ExitCode -ne 0) {
                    throw "DISM /Add-Driver fallo con codigo $($proc.ExitCode) para '$($drv.infPath)'."
                }
            } else {
                Write-Log -LogLevel WARN -Message "DeltaPackActions: INF de driver referenciado no encontrado tras aplicar el WIM: $($drv.infPath)"
            }
        }
        foreach ($cat in @($phaseData.protectedCatalogs)) {
            Write-Log -LogLevel WARN -Message "DeltaPackActions: Catalogo/controlador protegido requiere revision manual (no automatizable): $($cat.path)"
        }
    }
    else {
        foreach ($task in @($phaseData.scheduledTasks)) {
            Write-Log -LogLevel INFO -Message "DeltaPackActions: Tarea programada pendiente de validacion post-arranque: $($task.taskFile)"
        }
        foreach ($rp in @($phaseData.reparsePoints)) {
            Write-Log -LogLevel INFO -Message "DeltaPackActions: Punto de reanalisis reportado por el paquete: $rp"
        }
    }
}

# --- MOTOR PRINCIPAL: Inyector de Paquetes DeltaPack Dual-Engine (respeta manifest.deployment.order) ---
function Install-DeltaPackPackage {
    param(
        [Parameter(Mandatory=$true)][string]$PackagePath,
        [int]$WimIndex = 1
    )

    $manifest = Get-DeltaPackManifest -PackagePath $PackagePath
    $fullName = $manifest.package.fullName

    # --- Validacion de arquitectura contra la imagen montada (bloqueante) ---
    $imgArch =
        if     (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32")) { "ARM64" }
        elseif (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64")) { "x64" }
        else                                                                { "x86" }

    if ($manifest.compatibility.architecture -and $manifest.compatibility.architecture -ne $imgArch) {
        throw "Arquitectura del paquete '$fullName' ($($manifest.compatibility.architecture)) no coincide con la imagen montada ($imgArch)."
    }

    # --- Aviso no bloqueante de linea base de servicing (build de captura vs. imagen) ---
    $regData = Get-ItemProperty -Path "Registry::HKLM\OfflineSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    if ($regData -and $manifest.compatibility.buildNumber -and $regData.CurrentBuildNumber -and
        ([string]$regData.CurrentBuildNumber -ne [string]$manifest.compatibility.buildNumber)) {
        Write-Log -LogLevel WARN -Message "DeltaPack [$fullName]: Build de captura ($($manifest.compatibility.buildNumber)) difiere del build de la imagen montada ($($regData.CurrentBuildNumber)). Continuando (politica declarada: '$($manifest.compatibility.policy)')."
    }

    $hasWim = $false; $hasReg = $false; $hasDeletions = $false; $hasActions = $false

    # --- PASO 1 (deployment.order): Aplicar WIM ---
    $wimRel = $manifest.outputs.wimFile
    if ($wimRel) {
        $wimFull = Join-Path $PackagePath $wimRel
        if (Test-Path -LiteralPath $wimFull) {

            # 1a. Integridad del artefacto WIM contra Artifacts_*.sha256
            $artifactsRel = $manifest.outputs.artifactChecksumsFile
            if ($artifactsRel) {
                $artifactsFull = Join-Path $PackagePath $artifactsRel
                if (Test-Path -LiteralPath $artifactsFull) {
                    $line = Select-String -Path $artifactsFull -Pattern $wimRel -SimpleMatch | Select-Object -First 1
                    if ($line -and $line.Line -match '^([0-9a-fA-F]{64})\s{2}') {
                        $expectedHash = $Matches[1]
                        $actualHash = (Get-FileHash -Path $wimFull -Algorithm SHA256).Hash
                        if ($actualHash -ne $expectedHash) {
                            throw "El hash SHA256 de '$wimRel' no coincide con '$artifactsRel'. El paquete puede estar corrupto o manipulado."
                        }
                        Write-Log -LogLevel INFO -Message "DeltaPack [$fullName]: Integridad del WIM verificada contra $artifactsRel."
                    }
                }
            }

            # 1b. Extraccion del payload + 1c. Verificacion opcional contra Checksums_*.sha256 + 1d. Despliegue con seguridad NTFS completa
            $tempExtract = Join-Path $Script:Scratch_DIR "DeltaPack_$fullName`_$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
            try {
                $dismInfo = dism.exe /Get-WimInfo /WimFile:"$wimFull" /English | Select-String "Index :"
                $indexCount = @($dismInfo).Count
                $actualIndex = if ($indexCount -le 1) { 1 } else { $WimIndex }

                New-Item -Path $tempExtract -ItemType Directory -Force | Out-Null
                Write-Log -LogLevel ACTION -Message "DeltaPack [$fullName]: Extrayendo WIM (Indice $actualIndex)..."
                $proc = Start-Process "dism.exe" -ArgumentList "/Apply-Image /ImageFile:`"$wimFull`" /Index:$actualIndex /ApplyDir:`"$tempExtract`"" -Wait -NoNewWindow -PassThru
                if ($proc.ExitCode -ne 0) { throw "DISM /Apply-Image fallo al extraer '$wimRel' (Codigo: $($proc.ExitCode))." }

                $checksumsRel = $manifest.outputs.checksumsFile
                if ($checksumsRel) {
                    $checksumsFull = Join-Path $PackagePath $checksumsRel
                    if (Test-Path -LiteralPath $checksumsFull) {
                        $mismatch = 0; $verified = 0
                        Get-Content -Path $checksumsFull -Encoding UTF8 | ForEach-Object {
                            if ($_ -match '^([0-9a-fA-F]{64})\s{2}(.+)$') {
                                $expected = $Matches[1]; $relFile = $Matches[2].TrimEnd("`r")
                                $absFile = Join-Path $tempExtract $relFile
                                if (Test-Path -LiteralPath $absFile) {
                                    $actual = (Get-FileHash -Path $absFile -Algorithm SHA256).Hash
                                    if ($actual -eq $expected) { $verified++ } else { $mismatch++ }
                                } else { $mismatch++ }
                            }
                        }
                        Write-Log -LogLevel INFO -Message "DeltaPack [$fullName]: Checksums de payload verificados=$verified, discrepancias=$mismatch."
                        if ($mismatch -gt 0) {
                            Write-Log -LogLevel WARN -Message "DeltaPack [$fullName]: $mismatch archivo(s) no coinciden con $checksumsRel."
                        }
                    }
                }

                Enable-Privileges
                $safeMountDir = $Script:MOUNT_DIR.TrimEnd('\', '/')
                $roboArgs = "`"$tempExtract`" `"$safeMountDir`" /E /B /IS /IT $xdArg /R:0 /W:0 /NJH /NJS /NDL /NC /NS /NP"
                $proc = Start-Process robocopy.exe -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ge 8) {
                    throw "Robocopy fallo desplegando el WIM de '$fullName' en $safeMountDir (Codigo: $($proc.ExitCode))."
                }
                $hasWim = $true
            } finally {
                if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
            }
        } else {
            Write-Log -LogLevel WARN -Message "DeltaPack [$fullName]: outputs.wimFile ('$wimRel') no esta presente en el paquete (ej. omitido por tamaño). Se omite el despliegue de archivos."
        }
    }

    # --- PASO 2 (deployment.order): Actions afterWimBeforeRegistry, si existen ---
    $actionsRel = $manifest.outputs.actionsFile
    if ($actionsRel) {
        $actionsFull = Join-Path $PackagePath $actionsRel
        if (Test-Path -LiteralPath $actionsFull) {
            Invoke-DeltaPackActions -ActionsPath $actionsFull -Phase 'afterWimBeforeRegistry'
            $hasActions = $true
        }
    }

    # --- PASO 3 (deployment.order): Entries accionables de Deletions JSON, si existen ---
    $deletionsRel = $manifest.outputs.deletionsFile
    if ($deletionsRel) {
        $deletionsFull = Join-Path $PackagePath $deletionsRel
        if ((Test-Path -LiteralPath $deletionsFull) -and $manifest.deletions.actionableEntryCount -gt 0) {
            Invoke-DeltaPackDeletions -DeletionsPath $deletionsFull | Out-Null
            $hasDeletions = $true
        }
    }

    # --- PASO 4 (deployment.order): Importar REG ---
    $regRel = $manifest.outputs.regFile
    if ($regRel) {
        $regFull = Join-Path $PackagePath $regRel
        if (Test-Path -LiteralPath $regFull) {
            Import-OfflineReg -FilePath $regFull
            $hasReg = $true
        } else {
            Write-Log -LogLevel WARN -Message "DeltaPack [$fullName]: outputs.regFile ('$regRel') no encontrado en el paquete."
        }
    }

    # --- PASO 5 (deployment.order): Validar Actions afterRegistry ---
    if ($actionsRel) {
        $actionsFull = Join-Path $PackagePath $actionsRel
        if (Test-Path -LiteralPath $actionsFull) {
            Invoke-DeltaPackActions -ActionsPath $actionsFull -Phase 'afterRegistry'
        }
    }

    $msg = "DeltaPack '$fullName': "
    $msg += if ($hasWim) { "[WIM] " } else { "[WIM omitido] " }
    if ($hasActions)   { $msg += "[Actions] " }
    if ($hasDeletions) { $msg += "[Eliminaciones] " }
    if ($hasReg)       { $msg += "[Registro] " }
    return $msg.Trim()
}

# --- INTERFAZ GRÁFICA DEL GESTOR DE ADDONS ---
function Show-Addons-GUI {
    # Los ensamblados deben cargarse ANTES de cualquier MessageBox (incluido el guard de
    # imagen no montada); si esta es la primera GUI de la sesion, el tipo aun no existe.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    if (-not (Mount-Hives)) { return }

    # Flags a nivel de script (no de scriptblock) para que Add_Click y Add_FormClosing,
    # que corren como delegates independientes, vean y actualicen el mismo estado.
    $script:AddonBusy          = $false
    $script:AddonHivesUnmounted = $false

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Instalador de Addons y Paquetes Avanzados (.TPK, .BPK, .REG, DeltaPack)"
        $form.Size = New-Object System.Drawing.Size(950, 660)
        $form.StartPosition = "CenterScreen"
        $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $form.ForeColor = [System.Drawing.Color]::White
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false

        # --- TÍTULO Y BOTÓN DE CARGA ---
        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text = "Integracion de Paquetes de Terceros"
        $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $lblTitle.Location = "20, 15"; $lblTitle.AutoSize = $true
        $form.Controls.Add($lblTitle)

        # Botón de Información / Ayuda
        $btnHelp = New-Object System.Windows.Forms.Button
        $btnHelp.Text = "?"
        $btnHelp.Location = "630, 12"
        $btnHelp.Size = "30, 30"
        $btnHelp.BackColor = [System.Drawing.Color]::DarkOrange
        $btnHelp.FlatStyle = "Flat"
        $btnHelp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($btnHelp)

        $btnAddFiles = New-Object System.Windows.Forms.Button
        $btnAddFiles.Text = "+ Agregar Addons / Paquete DeltaPack..."
        $btnAddFiles.Location = "670, 12"
        $btnAddFiles.Size = "240, 30"
        $btnAddFiles.BackColor = [System.Drawing.Color]::RoyalBlue
        $btnAddFiles.FlatStyle = "Flat"
        $form.Controls.Add($btnAddFiles)

        # Label de advertencia de nomenclatura (Texto Rápido)
        $lblNomenclatura = New-Object System.Windows.Forms.Label
        $lblNomenclatura.Text = "Aviso: Usa los sufijos _x64, _x86, _arm64 en el nombre del archivo para activar el Escudo de Arquitectura.`nY para los Paquetes principales debe incluir _main al final del nombre es MUY IMPORTANTE"
        $lblNomenclatura.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
        $lblNomenclatura.ForeColor = [System.Drawing.Color]::White
        $lblNomenclatura.Location = "20, 42"
        $lblNomenclatura.AutoSize = $true
        $form.Controls.Add($lblNomenclatura)

        # --- DETECCIÓN INTELIGENTE DE ARQUITECTURA (INSTANTÁNEA) ---
        # Mismo criterio que la deteccion global del script (SysArm32 / SysWOW64).
        $defaultIdx = 1 # Asumimos x86 por defecto
        if     (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32")) { $defaultIdx = 3 } # ARM64
        elseif (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64")) { $defaultIdx = 2 } # x64

        # --- SELECTOR DE ARQUITECTURA (GRUPO) ---
        $grpArch = New-Object System.Windows.Forms.GroupBox
        $grpArch.Text = " Arquitectura del Addon (Solo aplica para desempaquetar .tpk/.bpk) "
        $grpArch.Location = "20, 65" 
        $grpArch.Size = "890, 55"
        $grpArch.ForeColor = [System.Drawing.Color]::Orange
        $form.Controls.Add($grpArch)

        $radX86 = New-Object System.Windows.Forms.RadioButton
        $radX86.Text = "x86 / 32-bits"
        $radX86.Location = "20, 22"
        $radX86.AutoSize = $true
        $radX86.ForeColor = [System.Drawing.Color]::White
        if ($defaultIdx -eq 1) { $radX86.Checked = $true }
        $grpArch.Controls.Add($radX86)

        $radX64 = New-Object System.Windows.Forms.RadioButton
        $radX64.Text = "x64 / 64-bits"
        $radX64.Location = "200, 22"
        $radX64.AutoSize = $true
        $radX64.ForeColor = [System.Drawing.Color]::White
        if ($defaultIdx -eq 2) { $radX64.Checked = $true }
        $grpArch.Controls.Add($radX64)

        $radArm64 = New-Object System.Windows.Forms.RadioButton
        $radArm64.Text = "ARM64"
        $radArm64.Location = "380, 22"
        $radArm64.AutoSize = $true
        $radArm64.ForeColor = [System.Drawing.Color]::White
        if ($defaultIdx -eq 3) { $radArm64.Checked = $true }
        $grpArch.Controls.Add($radArm64)

        # --- LISTVIEW (DESPLAZADO HACIA ABAJO) ---
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = "20, 135"
        $lv.Size = "890, 360"
        $lv.View = "Details"
        $lv.FullRowSelect = $true
        $lv.GridLines = $true
        $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $lv.ForeColor = [System.Drawing.Color]::White
        
        $lv.Columns.Add("Estado", 150) | Out-Null
        $lv.Columns.Add("Archivo", 250) | Out-Null
        $lv.Columns.Add("Tipo Detectado", 120) | Out-Null
        $lv.Columns.Add("Ruta Completa", 360) | Out-Null
        $form.Controls.Add($lv)

        # --- PALETA DE COLORES DE ESTADO (centralizada para mantenimiento) ---
        $ColorEspera     = [System.Drawing.Color]::Silver       # Neutral: en cola, sin actividad aun
        $ColorProcesando = [System.Drawing.Color]::Cyan         # Activo: se esta procesando AHORA MISMO
        $ColorCompletado = [System.Drawing.Color]::LimeGreen    # Exito
        $ColorError      = [System.Drawing.Color]::Tomato       # Fallo critico
        $ColorOmitido    = [System.Drawing.Color]::Goldenrod    # Omitido por arquitectura (advertencia, no error)

        # --- ESTADO Y BOTONES INFERIORES ---
        $lblStatus = New-Object System.Windows.Forms.Label
        $lblStatus.Text = "Agrega los archivos a la cola de inyeccion."
        $lblStatus.Location = "20, 505"
        $lblStatus.AutoSize = $true
        $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
        $form.Controls.Add($lblStatus)

        $btnRemoveItem = New-Object System.Windows.Forms.Button
        $btnRemoveItem.Text = "Quitar de la lista"
        $btnRemoveItem.Location = "20, 530"
        $btnRemoveItem.Size = "150, 30"
        $btnRemoveItem.BackColor = [System.Drawing.Color]::Crimson
        $btnRemoveItem.FlatStyle = "Flat"
        $form.Controls.Add($btnRemoveItem)

        $btnInstall = New-Object System.Windows.Forms.Button
        $btnInstall.Text = "INYECTAR TODOS LOS ADDONS"
        $btnInstall.Location = "640, 520"
        $btnInstall.Size = "270, 40"
        $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
        $btnInstall.FlatStyle = "Flat"
        $btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($btnInstall)

        $progressBar = New-Object System.Windows.Forms.ProgressBar
        $progressBar.Location = New-Object System.Drawing.Point(20, 580)
        $progressBar.Size = New-Object System.Drawing.Size(890, 15)
        $progressBar.Style = "Continuous"
        $progressBar.Visible = $false
        $form.Controls.Add($progressBar)

        # --- EVENTO DEL BOTÓN DE AYUDA ---
        $btnHelp.Add_Click({
            $helpMsg = "INSTRUCCIONES DE NOMENCLATURA PARA ADDONS`n`n"
            $helpMsg += "Para que el motor inteligente proteja tu imagen WIM de colapsos, "
            $helpMsg += "los archivos deben indicar su arquitectura en el nombre ANTES de la extension.`n`n"
            $helpMsg += "Ejemplos Correctos:`n"
            $helpMsg += "  >  MiPaqueteIdioma_x64_es-mx.tpk`n"
            $helpMsg += "  >  Herramienta_arm64_main.tpk`n"
            $helpMsg += "  >  Herramienta_main.bpk`n`n"
            $helpMsg += "Por que es importante?`n"
            $helpMsg += "Si agregas una carpeta entera de Addons, el script leera estos sufijos y "
            $helpMsg += "OMITIRA automaticamente los paquetes/Registro de una arquitectura distinta a la "
            $helpMsg += "seleccionada (x86, x64 o ARM64), evitando pantallas azules y corrupcion en la instalacion.`n`n"
            $helpMsg += "Paquetes DeltaPack Dual-Engine:`n"
            $helpMsg += "Selecciona el archivo 'manifest_*.json' dentro de la carpeta del paquete para agregarlo "
            $helpMsg += "como una unidad completa (WIM + REG + Eliminaciones + Acciones, en el orden que declare el manifest)."

            [System.Windows.Forms.MessageBox]::Show($helpMsg, "Reglas de Empaquetado", 'OK', 'Information')
        })

        # --- EVENTOS ---
        $btnAddFiles.Add_Click({
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Addons Windows (*.tpk;*.bpk;*.reg)|*.tpk;*.bpk;*.reg|Paquetes DeltaPack Dual-Engine (manifest_*.json)|manifest_*.json|Todos los archivos (*.*)|*.*"
            $ofd.Multiselect = $true
            if ($ofd.ShowDialog() -eq 'OK') {
                $lv.BeginUpdate()
                foreach ($file in $ofd.FileNames) {

                    # --- Paquete DeltaPack Dual-Engine: se agrega seleccionando su manifest_*.json ---
                    if ([System.IO.Path]::GetFileName($file) -match '^(?i)manifest_.*\.json$') {
                        $packageFolder = Split-Path $file -Parent
                        try {
                            $dpManifest = Get-DeltaPackManifest -PackagePath $packageFolder
                        } catch {
                            [System.Windows.Forms.MessageBox]::Show("No se pudo leer el paquete DeltaPack en `"$packageFolder`":`n`n$($_.Exception.Message)", "Paquete DeltaPack invalido", 'OK', 'Error')
                            continue
                        }

                        $yaAgregado = $lv.Items | Where-Object { $_.Tag -is [pscustomobject] -and $_.Tag.Kind -eq 'DeltaPack' -and $_.Tag.Path -eq $packageFolder }
                        if ($yaAgregado) { continue }

                        $displayName = if ($dpManifest.outputs.wimFile) { $dpManifest.outputs.wimFile } else { "$($dpManifest.package.fullName).wim" }

                        $item = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                        $item.SubItems.Add($displayName) | Out-Null
                        $item.SubItems.Add("DELTAPACK") | Out-Null
                        $item.SubItems.Add($packageFolder) | Out-Null
                        $item.ForeColor = $ColorEspera
                        $item.Tag = [pscustomobject]@{ Kind = 'DeltaPack'; Path = $packageFolder }
                        $lv.Items.Add($item) | Out-Null
                        continue
                    }

                    # --- Addon suelto (.wim / .tpk / .bpk / .reg) ---
                    $item = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                    $item.SubItems.Add([System.IO.Path]::GetFileName($file)) | Out-Null
                    $item.SubItems.Add([System.IO.Path]::GetExtension($file).ToUpper()) | Out-Null
                    $item.SubItems.Add($file) | Out-Null
                    $item.ForeColor = $ColorEspera
                    $item.Tag = $file
                    $lv.Items.Add($item) | Out-Null
                }
                $lv.EndUpdate()
            }
        })

        $btnRemoveItem.Add_Click({
            foreach ($item in $lv.SelectedItems) { $lv.Items.Remove($item) }
        })

        $btnInstall.Add_Click({
            if ($lv.Items.Count -eq 0) { 
                Write-Log -LogLevel WARN -Message "AddonInjector: Intento de ejecucion sin addons en la lista."
                return 
            }
            $confirm = [System.Windows.Forms.MessageBox]::Show("Iniciar la inyeccion en lote? Esto fusionara archivos y claves de registro en el orden correcto.", "Confirmar", 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { 
                Write-Log -LogLevel INFO -Message "AddonInjector: Operacion cancelada por el usuario en el cuadro de confirmacion."
                return 
            }

            # --- Limpiar caché SDDL residual de ejecuciones previas fallidas ---
            $Script:SDDL_Backups.Clear()

            Write-Log -LogLevel ACTION -Message "AddonInjector: Iniciando motor de inyeccion inteligente de Addons."

            $script:AddonBusy      = $true
            $btnInstall.Enabled    = $false
            $btnRemoveItem.Enabled = $false
            $btnAddFiles.Enabled   = $false
            $form.Cursor           = [System.Windows.Forms.Cursors]::WaitCursor
            $errors = 0; $success = 0; $skipped = 0

            try {
                # Capturamos la arquitectura de la UI (1=x86, 2=x64, 3=ARM64 dentro del .wim/.tpk/.bpk)
                $targetArch = if ($radX86.Checked) { "x86" } elseif ($radX64.Checked) { "x64" } else { "ARM64" }
                $selectedIndex = if ($radX86.Checked) { 1 } elseif ($radX64.Checked) { 2 } else { 3 }
                Write-Log -LogLevel INFO -Message "AddonInjector: Destino arquitectonico -> $targetArch | Indice WIM local: $selectedIndex"

                # --- 1. EXTRAER ELEMENTOS PENDIENTES ---
                $pendingItems = @()
                foreach ($item in $lv.Items) {
                    if ($item.Text -eq "EN ESPERA") {
                        $pendingItems += $item
                    }
                }

                if ($pendingItems.Count -eq 0) {
                    [System.Windows.Forms.MessageBox]::Show("No hay addons pendientes de procesar.", "Sin pendientes", 'OK', 'Information') | Out-Null
                    return
                }

                # --- 2. ORDENAMIENTO INTELIGENTE (Prioridad + Alfabeto) ---
                $lblStatus.Text = "Calculando orden de inyeccion..."
                $form.Refresh()

                $sortedItems = @($pendingItems | Sort-Object {
                    $fileName = $_.SubItems[1].Text.ToLower()
                    $priority = 5 # Prioridad por defecto (otros)
                    
                    # Asignacion de pesos (1 es lo primero que se instala)
                    if ($fileName -match "_main\.(tpk|bpk|wim)$") { $priority = 1 } # Paquetes Principales
                    elseif ($fileName -match "_main\.reg$")               { $priority = 2 } # Registro Principal
                    elseif ($fileName -match "\.(tpk|bpk|wim)$")   { $priority = 3 } # Paquetes de Idioma / Extras
                    elseif ($fileName -match "\.reg$")                     { $priority = 4 } # Registros de Idioma / Extras

                    # Al retornar "Prioridad-Nombre", PowerShell agrupa primero por fase y luego alfabeticamente
                    # Ej: "1-firefox_main.tpk" se procesara antes que "2-firefox_x64_main.reg"
                    "$priority-$fileName"
                })
                Write-Log -LogLevel INFO -Message "AddonInjector: Fase 2 - $($sortedItems.Count) elementos ordenados por algoritmo de prioridad."

                $progressBar.Value   = 0
                $progressBar.Maximum = $sortedItems.Count
                $progressBar.Visible = $true
                $count = 0

                # --- 3. PROCESAMIENTO E INYECCION ---
                foreach ($item in $sortedItems) {
                    try {
                        [System.Windows.Forms.Application]::DoEvents()

                        $fileName = $item.SubItems[1].Text.ToLower()

                        # --- CONDICION 1: FILTRO DE ARQUITECTURA (x86 / x64 / ARM64, mutuamente excluyentes) ---
                        $is64BitFile = $fileName -match "(\b|_|\.|-)(x64|64-?bit|amd64)(\b|_|\.|-)"
                        $is32BitFile = $fileName -match "(\b|_|\.|-)(x86|32-?bit)(\b|_|\.|-)"
                        $isArm64File = $fileName -match "(\b|_|\.|-)(arm64|aarch64)(\b|_|\.|-)"

                        $archMismatch = $false
                        $archReason   = ""
                        switch ($targetArch) {
                            "x86"   { if ($is64BitFile)  { $archMismatch = $true; $archReason = "Solo x64" }
                                      elseif ($isArm64File) { $archMismatch = $true; $archReason = "Solo ARM64" } }
                            "x64"   { if ($is32BitFile)  { $archMismatch = $true; $archReason = "Solo x86" }
                                      elseif ($isArm64File) { $archMismatch = $true; $archReason = "Solo ARM64" } }
                            "ARM64" { if ($is32BitFile)  { $archMismatch = $true; $archReason = "Solo x86" }
                                      elseif ($is64BitFile) { $archMismatch = $true; $archReason = "Solo x64" } }
                        }

                        if ($archMismatch) {
                            $item.Text = "OMITIDO (Arch)"
                            $item.SubItems[2].Text = "Ignorado ($archReason)"
                            $item.ForeColor = $ColorOmitido
                            $skipped++
                            Write-Log -LogLevel INFO -Message "AddonInjector: Omitiendo [$fileName] ($archReason, imagen destino $targetArch)."
                            continue
                        }

                        # --- CONDICION 2: INYECCION EN ORDEN ---
                        $lblStatus.Text = "Inyectando: $($item.SubItems[1].Text)..."
                        $item.Text = "PROCESANDO..."
                        $item.ForeColor = $ColorProcesando

                        # Hacemos auto-scroll en la UI para ver por donde va
                        $item.EnsureVisible()
                        $form.Refresh()

                        Write-Log -LogLevel INFO -Message "AddonInjector: Instalando -> [$fileName]"

                        try {
                            # Motor correspondiente segun el tipo de addon en cola (archivo suelto vs. paquete DeltaPack)
                            if ($item.Tag -is [pscustomobject] -and $item.Tag.Kind -eq 'DeltaPack') {
                                $resultado = Install-DeltaPackPackage -PackagePath $item.Tag.Path -WimIndex $selectedIndex
                            } else {
                                $resultado = Install-OfflineAddon -FilePath $item.Tag -WimIndex $selectedIndex
                            }

                            $item.Text = "COMPLETADO"
                            $item.SubItems[2].Text = $resultado
                            $item.ForeColor = $ColorCompletado
                            $success++
                            Write-Log -LogLevel INFO -Message "AddonInjector: Completado. Motor devolvio: $resultado"
                        } catch {
                            $item.Text = "ERROR"
                            $item.SubItems[2].Text = $_.Exception.Message
                            $item.ForeColor = $ColorError
                            $errors++
                            Write-Log -LogLevel ERROR -Message "AddonInjector: Fallo critico instalando addon [$fileName] - $($_.Exception.Message)"
                        }
                    } finally {
                        # Contar el objeto solo despues de terminar su procesamiento.
                        $count++
                        $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                        $form.Refresh()
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                }

                Write-Log -LogLevel ACTION -Message "AddonInjector: Ciclo de inyeccion finalizado. Exitos: $success | Errores: $errors | Omitidos (Arch): $skipped"

                try {
                    Restore-AllOfflineSDDL
                } catch {
                    Write-Log -LogLevel WARN -Message "AddonInjector: Fallo al restaurar SDDL tras la inyeccion - $($_.Exception.Message)"
                }

                [System.Windows.Forms.MessageBox]::Show("Inyeccion de Addons finalizada.`n`nExitos: $success`nErrores: $errors`nOmitidos (Arch): $skipped", "Reporte de Operacion", 'OK', 'Information')
            } catch {
                Write-Log -LogLevel ERROR -Message "AddonInjector: Error inesperado durante el ciclo de inyeccion - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Ocurrio un error inesperado durante la inyeccion:`n`n$($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
            } finally {
                $progressBar.Visible   = $false
                $form.Cursor           = [System.Windows.Forms.Cursors]::Default
                $btnInstall.Enabled    = $true
                $btnRemoveItem.Enabled = $true
                $btnAddFiles.Enabled   = $true
                $lblStatus.Text        = "Proceso terminado."
                $script:AddonBusy      = $false
            }
        })

        # Cierre seguro (Desmontar Hives de registro)
        $form.Add_FormClosing({ 
            if ($script:AddonBusy) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Hay una inyeccion de addons en curso. Espera a que termine antes de cerrar esta ventana.",
                    "Operacion en curso", 'OK', 'Warning') | Out-Null
                $_.Cancel = $true
                return
            }

            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Estas seguro de que deseas salir?", 
                "Confirmar Salida", 
                [System.Windows.Forms.MessageBoxButtons]::YesNo, 
                [System.Windows.Forms.MessageBoxIcon]::Question
            )

            if ($confirm -eq 'No') {
                $_.Cancel = $true
            } else {
                $lblStatus.Text = "Desmontando Hives..."
                $form.Refresh()
                Start-Sleep -Milliseconds 500
                if (-not $script:AddonHivesUnmounted) {
                    Unmount-Hives
                    $script:AddonHivesUnmounted = $true
                }
            }
        })
        
        $form.ShowDialog() | Out-Null
        $form.Dispose()
    } catch {
        Write-Log -LogLevel ERROR -Message "AddonInjector: Error inesperado construyendo la GUI - $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Ocurrio un error inesperado al abrir el instalador de addons:`n`n$($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
    } finally {
        if (-not $script:AddonHivesUnmounted) {
            Unmount-Hives
            $script:AddonHivesUnmounted = $true
        }
        [GC]::Collect()
    }
}