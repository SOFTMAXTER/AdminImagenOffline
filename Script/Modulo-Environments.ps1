# =================================================================
#  Modulo-Entornos
#
#  CONTENIDO   : Manage-WinRE-Menu, Manage-BootWim-Menu, Setup clasico reversible
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:MOUNTED_INDEX  : indice WIM montado
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Enable-Privileges      : habilitar privilegios de token
#    - Unlock-Single-File     : romper bloqueos de TrustedInstaller en archivos
#    - Restore-FileOwner      : restaurar SDDL original de archivos
#    - Select-PathDialog      : ui para seleccion de rutas
#    - Initialize-ScratchSpace: limpiar y preparar espacio temporal
#    - Unmount-Image          : logica base para desmontar imagenes
#    - Show-Addons-GUI        : invocacion del inyector de addons
#    - Show-Drivers-GUI       : invocacion del inyector de drivers
#  CARGA       : . "$PSScriptRoot\Modulo-Environments.ps1"
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
#  Modulo Avanzado: Gestor de Entorno de RecuperaciOn (WinRE)
# =================================================================
function Manage-WinRE-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "       Gestor Avanzado de Entorno de Recuperacion      " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    
    Write-Log -LogLevel INFO -Message "WinRE_Manager: Iniciando el modulo de gestion de Entorno de Recuperacion."

    # Acepta tanto WIM (1) como VHD/VHDX (2)
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Warning "Debes montar una imagen de sistema (install.wim o VHD/VHDX) primero."
        Write-Log -LogLevel WARN -Message "WinRE_Manager: Intento de acceso denegado. No hay imagen montada."
        Pause; return 
    }

    # Ruta estandar donde se esconde WinRE dentro del sistema (WIM o VHD)
    $winrePath = Join-Path $Script:MOUNT_DIR "Windows\System32\Recovery\winre.wim"
    
    if (-not (Test-Path -LiteralPath $winrePath)) {
        Write-Warning "No se encontro 'winre.wim' en la ruta habitual."
        Write-Host "Es posible que la imagen montada sea un boot.wim o que el WinRE ya haya sido eliminado." -ForegroundColor Gray
        Write-Log -LogLevel WARN -Message "WinRE_Manager: No se encontro winre.wim en la ruta esperada ($winrePath)."
        Pause; return
    }

    Write-Host "`n[1/5] Preparando entorno de trabajo temporal..." -ForegroundColor Yellow
    $winreStaging = Join-Path $Script:Scratch_DIR "WinRE_Staging"
    $winreMount = Join-Path $Script:Scratch_DIR "WinRE_Mount"

    Write-Log -LogLevel INFO -Message "WinRE_Manager: Limpiando y creando directorios temporales de trabajo (Staging/Mount)."
    # Limpieza previa por si quedo basura de un intento anterior
    if (Test-Path $winreMount) { dism /unmount-image /mountdir:"$winreMount" /discard 2>$null | Out-Null }
    if (Test-Path $winreStaging) { Remove-Item $winreStaging -Recurse -Force -ErrorAction SilentlyContinue }
    
    New-Item -Path $winreStaging -ItemType Directory -Force | Out-Null
    New-Item -Path $winreMount -ItemType Directory -Force | Out-Null

    Write-Host "[2/5] Extrayendo winre.wim de la imagen principal..." -ForegroundColor Yellow
    
    # --- CAPTURA DE SEGURIDAD Y DESBLOQUEO ARQUITECTÓNICO ---
    # Respaldamos atributos nativos (Hidden, System) antes del desbloqueo
    $winreFile = Get-Item -LiteralPath $winrePath -Force
    $originalAttributes = $winreFile.Attributes
    
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Rompiendo candados de TrustedInstaller vía Unlock-Single-File..."
    Unlock-Single-File -FilePath $winrePath

    # Copiamos a Staging ya desbloqueado
    $tempWinrePath = Join-Path $winreStaging "winre.wim"
    Copy-Item -LiteralPath $winrePath -Destination $tempWinrePath -Force

    Write-Host "[3/5] Montando winre.wim (Esto puede tardar unos segundos)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Montando winre.wim temporal via DISM..."
    dism /mount-image /imagefile:"$tempWinrePath" /index:1 /mountdir:"$winreMount"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo montar winre.wim. Abortando..." -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "WinRE_Manager: Fallo critico al montar winre.wim. Codigo DISM: $LASTEXITCODE"
        
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Ejecutando limpieza de emergencia (discard) especificamente en $winreMount."
        dism /unmount-image /mountdir:"$winreMount" /discard 2>$null | Out-Null
        Pause; return
    }

    Write-Host "[OK] WinRE Montado Exitosamente." -ForegroundColor Green
    Write-Log -LogLevel INFO -Message "WinRE_Manager: Montaje exitoso. Desviando variable global MOUNT_DIR hacia el entorno WinRE."
    Start-Sleep -Seconds 2

    Unmount-Hives | Out-Null

    $originalMountDir = $Script:MOUNT_DIR
    $Script:MOUNT_DIR = $winreMount

    try {
        # --- MINI-MENU DE EDICION WINRE ---
        $doneEditing = $false
        while (-not $doneEditing) {
            Clear-Host
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host "          MODO DE EDICION EN WINRE ACTIVO              " -ForegroundColor Magenta
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host "El entorno de recuperacion esta montado y listo."
            Write-Host "Puedes inyectar Addons (DaRT) y Drivers (VMD/RAID/Red)."
            Write-Host ""
            Write-Host "   [1] Inyectar Addons (.tpk, .bpk, .reg,)"
            Write-Host "   [2] Inyectar Drivers (.inf)" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   [T] Terminar edicion y proceder a Guardar" -ForegroundColor Green
            Write-Host ""
            
            $opcionRE = Read-Host " Elige una opcion"
            switch ($opcionRE.ToUpper()) {
                "1" { Write-Log -LogLevel INFO -Message "WinRE_Manager: Lanzando modulo de Addons."; Show-Addons-GUI }
                "2" { Write-Log -LogLevel INFO -Message "WinRE_Manager: Lanzando modulo de Drivers."; Show-Drivers-GUI }
                "T" { $doneEditing = $true; Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario termino la edicion interactiva." }
                default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
            }
        }

        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "              GUARDAR Y REINYECTAR WINRE               " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        $guardar = Read-Host "Deseas GUARDAR los cambios y devolver el winre.wim a la imagen principal? (S/N)"

        Write-Host "`n[4/5] Desmontando winre.wim..." -ForegroundColor Yellow
        if ($guardar.ToUpper() -eq 'S') {
            Write-Log -LogLevel ACTION -Message "WinRE_Manager: Iniciando proceso de guardado (Commit) de winre.wim..."
            dism /unmount-image /mountdir:"$winreMount" /commit

            if ($LASTEXITCODE -eq 0) {
                Write-Host "[5/5] Reinyectando winre.wim..." -ForegroundColor Yellow
                Enable-Privileges

                # GUARDIA DE TIMING: DISM puede mantener handle exclusivo sobre $tempWinrePath
                # varios segundos tras el commit. Export-Image o Copy-Item que lean el archivo
                # antes de la liberacion fallan silenciosamente -> winre.wim vacio o ausente.
                Write-Host " -> Esperando liberacion de handle de DISM..." -ForegroundColor DarkGray
                $lockLimit = 15; $lockWait = 0
                while ($lockWait -lt $lockLimit) {
                    try {
                        $fs = [System.IO.File]::Open($tempWinrePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                        $fs.Close(); $fs.Dispose()
                        break
                    } catch { Start-Sleep -Seconds 1; $lockWait++ }
                }
                if ($lockWait -eq $lockLimit) {
                    Write-Log -LogLevel WARN -Message "WinRE_Manager: Timeout esperando liberacion de $tempWinrePath. Continuando sin garantia."
                    Write-Host " -> [WARN] Timeout de handle. Continuando de todas formas." -ForegroundColor Yellow
                }

                # Reconstruccion de diccionario WIM con flag /Bootable
                Write-Host " -> Ejecutando reconstruccion de diccionario WIM (Tardara unos minutos)..." -ForegroundColor Cyan
                Write-Log -LogLevel ACTION -Message "WinRE_Manager: Ejecutando Export-Image con flag /Bootable para reconstruir el diccionario WIM."

                $optimizedWinrePath = Join-Path $winreStaging "winre_optimized.wim"
                $dismArgs = "/Export-Image /SourceImageFile:`"$tempWinrePath`" /SourceIndex:1 /DestinationImageFile:`"$optimizedWinrePath`" /Bootable"
                $proc = Start-Process "dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru

                # Fallback blindado: si Export falla, NO se deja winrePath vacio.
                # Se usa $tempWinrePath (commit exitoso) como fuente de rescate.
                $finalSource = if ($proc.ExitCode -eq 0 -and (Test-Path $optimizedWinrePath)) {
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Export-Image exitoso. Usando WIM optimizado como fuente final."
                    $optimizedWinrePath
                } else {
                    Write-Log -LogLevel WARN -Message "WinRE_Manager: Export-Image fallo (Code: $($proc.ExitCode)). Fallback a WIM de commit directo."
                    Write-Host " -> Export-Image fallo. Usando WIM de commit como fallback." -ForegroundColor Yellow
                    $tempWinrePath
                }

                Remove-Item -LiteralPath $winrePath -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $finalSource -Destination $winrePath -Force

                if (Test-Path -LiteralPath $winrePath) {
                    $sizeAfter = (Get-Item -LiteralPath $winrePath).Length
                    $finalMB = [math]::Round($sizeAfter / 1MB, 2)
                    Write-Host "[EXITO] WinRE guardado e integrado correctamente." -ForegroundColor Green
                    Write-Host "        Size final: $finalMB MB." -ForegroundColor DarkGreen
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Reinyeccion exitosa. Size final: $finalMB MB."
                } else {
                    Write-Host "[ERROR] winre.wim ausente tras reinyeccion. Revisa el log." -ForegroundColor Red
                    Write-Log -LogLevel ERROR -Message "WinRE_Manager: Copy-Item fallo o fuente invalida. winre.wim ausente en destino."
                }
            } else {
                Write-Host "[ERROR] Fallo al guardar winre.wim. La imagen principal no fue modificada." -ForegroundColor Red
                Write-Log -LogLevel ERROR -Message "WinRE_Manager: DISM fallo al hacer commit. Codigo de salida: $LASTEXITCODE"
            }
        } else {
            Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario eligio descartar los cambios (Discard)."
            dism /unmount-image /mountdir:"$winreMount" /discard
            Write-Host "Cambios descartados. La imagen principal no fue modificada." -ForegroundColor Gray
        }
    } finally {
        # --- RESTAURAR EL ESTADO GLOBAL (CRÍTICO) ---
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Restaurando variable global MOUNT_DIR, permisos y atributos..."
        $Script:MOUNT_DIR = $originalMountDir
        
        # FIX: Restaurar SIEMPRE el SDDL original y los atributos (Hidden, System), 
        # sin importar la ruta tomada (Éxito, Error, Cancelación o Excepción).
        if (Test-Path -LiteralPath $winrePath) {
            Restore-FileOwner -FilePath $winrePath
            
            $restoredFile = Get-Item -LiteralPath $winrePath -Force
            $restoredFile.Attributes = $originalAttributes
            Write-Log -LogLevel INFO -Message "WinRE_Manager: winre.wim devuelto a su estado nativo y protegido."
        }
        
        # Limpieza de basura temporal
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Limpiando directorios de Staging y Mount."
        Remove-Item $winreStaging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $winreMount -Recurse -Force -ErrorAction SilentlyContinue
    }
    Pause
}

# =================================================================
# Setup clasico de Windows 11 (WinPE de instalacion 24H2 o posterior).
# El respaldo vive en el mismo indice: sobrevive a Commit y desaparece
# junto con la modificacion si el usuario elige Discard.
# =================================================================
function Get-AIOBootSetupHash {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-AIOBootSetupFileState {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Base64 = ''; Hash = ''; Attributes = 0; Sddl = '' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Se esperaba un archivo: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sections = [Security.AccessControl.AccessControlSections]::Access -bor
                [Security.AccessControl.AccessControlSections]::Owner -bor
                [Security.AccessControl.AccessControlSections]::Group
    return [pscustomobject]@{
        Exists = $true
        Base64 = [Convert]::ToBase64String($bytes)
        Hash = Get-AIOBootSetupHash -Bytes $bytes
        Attributes = [int][IO.File]::GetAttributes($Path)
        Sddl = $acl.GetSecurityDescriptorSddlForm($sections)
    }
}

function Set-AIOBootSetupFileState {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$State)
    $before = Get-AIOBootSetupFileState -Path $Path
    $unlocked = $false
    # Preparar bytes antes de tocar permisos o contenido.
    $bytes = if ($State.Exists) { [Convert]::FromBase64String($State.Base64) } else { $null }
    try {
        try {
            if ($before.Exists) {
                [IO.File]::SetAttributes($Path, ([IO.FileAttributes]$before.Attributes -band
                    (-bnot [IO.FileAttributes]::ReadOnly)))
            }
            if ($State.Exists) { [IO.File]::WriteAllBytes($Path, [byte[]]$bytes) }
            elseif ($before.Exists) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        } catch [System.UnauthorizedAccessException] {
            if (-not $before.Exists) { throw }
            $unlocked = $true
            Unlock-Single-File -FilePath $Path | Out-Null
            if ($State.Exists) { [IO.File]::WriteAllBytes($Path, [byte[]]$bytes) }
            else { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        }
    } finally {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Restaurar descriptor exacto; no depender del fallback del nucleo.
            $metadata = if ($State.Exists -and $State.Sddl) { $State } else { $before }
            # Atributos antes del ACL: el descriptor original puede quitar
            # al administrador el permiso de volver a escribir atributos.
            if ($metadata.Exists) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]$metadata.Attributes) }
            if ($metadata.Sddl) {
                Enable-Privileges | Out-Null
                $acl = New-Object System.Security.AccessControl.FileSecurity
                $acl.SetSecurityDescriptorSddlForm($metadata.Sddl)
                Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
            }
        }
        if ($unlocked -and $null -ne $Script:FileSDDL_Backups) {
            [void]$Script:FileSDDL_Backups.Remove([IO.Path]::GetFullPath($Path).ToLowerInvariant())
        }
    }
    $after = Get-AIOBootSetupFileState -Path $Path
    if ($after.Exists -ne $State.Exists -or ($State.Exists -and $after.Hash -ne $State.Hash)) {
        throw "Fallo la verificacion de contenido de $Path."
    }
    if ($State.Exists -and $State.Sddl -and
        ($after.Sddl -ne $State.Sddl -or $after.Attributes -ne $State.Attributes)) {
        throw "Fallo la restauracion de permisos o atributos de $Path."
    }
}

function Assert-AIOBootClassicSetupAvailable {
    param([Parameter(Mandatory=$true)][string]$MountPath)
    # Un WinPE de herramientas o un install.wim no deben recibir este cambio.
    foreach ($relative in @('setup.exe', 'sources\setup.exe', 'Windows\System32\winpeshl.exe')) {
        $file = Join-Path $MountPath $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-Item -LiteralPath $file -Force -ErrorAction Stop).Length -eq 0) {
            throw "Este indice no contiene el entorno Setup requerido ($relative). Selecciona el indice de instalacion de boot.wim."
        }
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $MountPath 'setup.exe'))
    if ($version.FileMajorPart -ne 10 -or $version.FileBuildPart -lt 26100) {
        throw 'Esta opcion requiere Setup de Windows 11 24H2 o posterior (build 26100+). No se reconocio esa version en setup.exe.'
    }
}

function Test-AIOBootStandardShell {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    # Solo reemplazar un INI estandar de un unico lanzador, sin argumentos.
    # Conservar scripts/DaRT y otros arranques personalizados sin alterarlos.
    $lines = @([IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith(';') -and -not $_.StartsWith('#') })
    if ($lines.Count -ne 2) { return $false }
    $launcher = '(?:%SYSTEMDRIVE%|X:)\\(?:sources\\)?setup\.exe'
    if ($lines[0] -ieq '[LaunchApp]') { return $lines[1] -match ('(?i)^AppPath\s*=\s*"?' + $launcher + '"?\s*$') }
    if ($lines[0] -ieq '[LaunchApps]') { return $lines[1] -match ('(?i)^"?' + $launcher + '"?\s*$') }
    return $false
}

function Get-AIOBootSetupBackup {
    param([Parameter(Mandatory=$true)][string]$Path)
    $backup = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($backup.Schema -ne 1 -or $backup.Owner -cne 'AdminImagenOffline.SetupClassic' -or
        $null -eq $backup.Original -or $backup.Original.Exists -isnot [bool]) {
        throw 'Respaldo de Setup no reconocido. No se modificara la imagen.'
    }
    if ($backup.Original.Exists) {
        $bytes = [Convert]::FromBase64String($backup.Original.Base64)
        if ((Get-AIOBootSetupHash -Bytes $bytes) -cne $backup.Original.Hash -or
            [string]::IsNullOrWhiteSpace($backup.Original.Sddl) -or
            $null -eq $backup.Original.Attributes) {
            throw 'El respaldo original de winpeshl.ini esta incompleto o no coincide con su SHA-256.'
        }
    } elseif ($backup.Original.Base64 -ne '' -or $backup.Original.Hash -ne '' -or $backup.Original.Sddl -ne '') {
        throw 'El respaldo de la ausencia original de winpeshl.ini no es valido.'
    }
    return $backup
}

function Assert-AIOBootSetupConfiguration {
    param([Parameter(Mandatory=$true)][string]$MountPath, [Parameter(Mandatory=$true)]$Expected)
    $ini = Join-Path $MountPath 'Windows\System32\winpeshl.ini'
    $backupPath = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupClassic.json'
    $current = Get-AIOBootSetupFileState -Path $ini
    if ($current.Exists -ne $Expected.Ini.Exists -or
        ($current.Exists -and ($current.Hash -ne $Expected.Ini.Hash -or
            $current.Attributes -ne $Expected.Ini.Attributes -or $current.Sddl -ne $Expected.Ini.Sddl))) {
        throw 'winpeshl.ini cambio despues de configurar Setup. No se guardara automaticamente.'
    }
    if ($Expected.Mode -eq 'Classic') {
        Assert-AIOBootClassicSetupAvailable -MountPath $MountPath
        $backup = Get-AIOBootSetupBackup -Path $backupPath
        if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Expected.BackupHash) {
            throw 'El respaldo de Setup cambio durante la sesion.'
        }
    } elseif (Test-Path -LiteralPath $backupPath) {
        throw 'La restauracion no termino: todavia existe el respaldo de Setup.'
    }
}

function Set-AIOBootSetupMode {
    param(
        [Parameter(Mandatory=$true)][string]$MountPath,
        [Parameter(Mandatory=$true)][ValidateSet('Classic', 'Original')][string]$Mode
    )
    $ini = Join-Path $MountPath 'Windows\System32\winpeshl.ini'
    $backupPath = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupClassic.json'
    $classicBytes = [Text.Encoding]::ASCII.GetBytes("[LaunchApps]`r`n%SYSTEMDRIVE%\setup.exe, /legacy`r`n")
    $classicHash = Get-AIOBootSetupHash -Bytes $classicBytes
    $current = Get-AIOBootSetupFileState -Path $ini
    $backup = $null
    if (Test-Path -LiteralPath $backupPath) { $backup = Get-AIOBootSetupBackup -Path $backupPath }
    if ($Mode -eq 'Classic') {
        Assert-AIOBootClassicSetupAvailable -MountPath $MountPath
        if ($null -ne $backup) {
            if (-not $current.Exists -or $current.Hash -ne $classicHash) {
                throw 'Existe un respaldo, pero el inicio actual no coincide con el Setup clasico administrado. Restaura primero la configuracion original.'
            }
            Write-Host '[INFO] Setup clasico ya esta configurado. Se conserva el respaldo original.' -ForegroundColor Cyan
        } else {
            if (-not (Test-AIOBootStandardShell -Path $ini)) {
                throw 'winpeshl.ini contiene un inicio personalizado o no reconocido. Se conserva sin cambios para proteger sus scripts y herramientas.'
            }
            $backup = [pscustomobject]@{ Schema = 1; Owner = 'AdminImagenOffline.SetupClassic'; Original = $current }
            $jsonBytes = [Text.Encoding]::UTF8.GetBytes(($backup | ConvertTo-Json -Depth 4))
            # CreateNew evita sobrescribir un respaldo anterior, incluso ante carreras.
            $stream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($jsonBytes, 0, $jsonBytes.Length) } finally { $stream.Dispose() }
            try {
                $backup = Get-AIOBootSetupBackup -Path $backupPath
                $classic = [pscustomobject]@{
                    Exists = $true; Base64 = [Convert]::ToBase64String($classicBytes); Hash = $classicHash
                    Attributes = $current.Attributes; Sddl = $current.Sddl
                }
                Set-AIOBootSetupFileState -Path $ini -State $classic
            } catch {
                $failure = $_.Exception.Message
                try {
                    Set-AIOBootSetupFileState -Path $ini -State $current
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                } catch {
                    throw "Fallo la activacion ($failure) y la reversion ($($_.Exception.Message)). Descarta este montaje; se conserva el respaldo disponible."
                }
                throw "No se activo Setup clasico; se restauro el estado anterior. $failure"
            }
        }
    } else {
        if ($null -eq $backup) { throw 'No hay un respaldo creado por esta opcion. No se eliminara ni modificara winpeshl.ini.' }
        # Acepta el estado original para reintentar una limpieza interrumpida.
        $isOriginal = $current.Exists -eq $backup.Original.Exists -and
            (-not $current.Exists -or $current.Hash -eq $backup.Original.Hash)
        if (-not $isOriginal -and (-not $current.Exists -or $current.Hash -ne $classicHash)) {
            throw 'winpeshl.ini fue modificado por otra herramienta. Se conservan el archivo y el respaldo; no se sobrescribiran esos cambios.'
        }
        Set-AIOBootSetupFileState -Path $ini -State $backup.Original
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
    }
    $expected = [pscustomobject]@{
        Mode = $Mode; Ini = Get-AIOBootSetupFileState -Path $ini
        BackupHash = if ($Mode -eq 'Classic') { (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash } else { '' }
    }
    Assert-AIOBootSetupConfiguration -MountPath $MountPath -Expected $expected
    Write-Log -LogLevel INFO -Message "BootWimManager: Configuracion Setup verificada en el montaje. Modo: $Mode."
    Write-Host '[OK] Configuracion preparada y verificada. Elige T y luego S para guardarla en boot.wim.' -ForegroundColor Green
    return $expected
}

function Manage-BootWim-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "        Gestor Inteligente de Arranque (boot.wim)      " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Log -LogLevel INFO -Message "BootWimManager: Iniciando modulo de gestion de arranque (boot.wim)."

    # 1. Seguridad: Verificar que no haya nada montado
    if ($Script:IMAGE_MOUNTED -ne 0) {
        Write-Log -LogLevel WARN -Message "BootWimManager: Acceso bloqueado. Ya existe una imagen montada en $Script:MOUNT_DIR."
        Write-Warning "Ya tienes una imagen montada ($Script:MOUNT_DIR)."
        Write-Host "Debes desmontarla antes de editar el boot.wim para evitar conflictos." -ForegroundColor Gray
        Pause; return
    }

    # 2. Seleccionar archivo
    Write-Host "Selecciona tu archivo 'boot.wim'..." -ForegroundColor Yellow
    $bootPath = Select-PathDialog -DialogType File -Title "Selecciona boot.wim" -Filter "Archivos WIM|*.wim"
    if (-not $bootPath) { 
        Write-Log -LogLevel INFO -Message "BootWimManager: El usuario cancelo la seleccion del archivo boot.wim."
        return 
    }

    Write-Log -LogLevel INFO -Message "BootWimManager: Archivo seleccionado -> $bootPath"

    # 3. Analizar Indices
    Write-Host "Analizando estructura del boot.wim..." -ForegroundColor DarkGray
    try {
        $images = @(Get-WindowsImage -ImagePath $bootPath -ErrorAction Stop)
    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo al leer la estructura de indices del WIM. Probable corrupcion. - $($_.Exception.Message)"
        Write-Warning "Error leyendo el WIM. Esta corrupto?"
        Pause; return
    }

    Write-Host "`nIndices detectados:" -ForegroundColor Cyan
    $idxSetup = $null
    $idxPE = $null
    $setupNamePattern = "Setup|(?<!Pre)Installation|Instalar|Instalaci[oó]n"

    foreach ($img in $images) {
        $desc = "Generico"
        # Heuristica para identificar que es cada indice
        if ($img.ImageName -match $setupNamePattern) { 
            $desc = "Instalador de Windows (Setup)"; $idxSetup = $img.ImageIndex 
        }
        elseif ($img.ImageName -match "PE|Preinstallation") { 
            $desc = "Windows PE (Rescate/Live)"; $idxPE = $img.ImageIndex 
        }
        
        Write-Log -LogLevel INFO -Message "BootWimManager: Indice detectado [$($img.ImageIndex)] $($img.ImageName) -> $desc"
        Write-Host "   [$($img.ImageIndex)] $($img.ImageName)" -NoNewline
        Write-Host " --> $desc" -ForegroundColor Yellow
    }
    Write-Host ""

    # 4. Seleccion Inteligente
    Write-Host "======================================================="
    Write-Host "Que indice de boot.wim quieres editar?"
    Write-Host "   [1] En Windows PE (Indice $idxPE)" -ForegroundColor White
    Write-Host "       (Para crear un USB booteable exclusivo de diagnostico)" -ForegroundColor Gray
    Write-Host ""
	Write-Host "   [2] En el Instalador (Indice $idxSetup)" -ForegroundColor White
    Write-Host "       (Configurar Setup clasico, inyectar DaRT o controladores)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   [M] Seleccion Manual (Si la deteccion fallo)" -ForegroundColor DarkGray
    
    $sel = Read-Host "Selecciona una opcion"
    $targetIndex = $null

    switch (([string]$sel).Trim().ToUpperInvariant()) {
        "1" { $targetIndex = $idxPE }
        "2" { $targetIndex = $idxSetup }
        "M" { $targetIndex = Read-Host "Introduce el numero de Indice manualmente" }
    }

    $parsedIndex = 0
    if (-not [int]::TryParse([string]$targetIndex, [ref]$parsedIndex) -or
        $parsedIndex -lt 1 -or $parsedIndex -notin @($images | ForEach-Object { [int]$_.ImageIndex })) { 
        Write-Log -LogLevel WARN -Message "BootWimManager: Seleccion de indice invalida o vacia."
        Write-Warning "Seleccion invalida."; Pause; return 
    }

    $targetIndex = $parsedIndex
    # Clasificar el indice elegido, tambien cuando se selecciono manualmente.
    # No asumir que Windows Setup siempre ocupa el indice numerico 2.
    $selectedImage = $images | Where-Object { [int]$_.ImageIndex -eq $targetIndex } | Select-Object -First 1
    $isSetupIndex = ([string]$selectedImage.ImageName -match $setupNamePattern)

    Write-Log -LogLevel INFO -Message "BootWimManager: Indice objetivo fijado en -> [$targetIndex]"

    # 5. Proceso de Montaje y Edicion
    $bootMountActive = $false
    try {
        # Contexto compartido para los modulos de addons, drivers y desmontaje.
        $Script:WIM_FILE_PATH = $bootPath
        $Script:MOUNTED_INDEX = $targetIndex
        # Marcar como montada solo despues del exito real de DISM.
        
        # Limpieza previa
        Initialize-ScratchSpace

        # Montaje Real
        Write-Log -LogLevel ACTION -Message "BootWimManager: Iniciando montaje del boot.wim (Indice: $targetIndex)..."
        Write-Host "`n[+] Montando boot.wim (Indice $targetIndex)..." -ForegroundColor Yellow
        dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

        if ($LASTEXITCODE -eq 0) {
            $bootMountActive = $true
            $Script:IMAGE_MOUNTED = 1
            $setupExpected = $null
            $setupEditFailed = $false
            Write-Log -LogLevel INFO -Message "BootWimManager: Montaje exitoso. Desplegando menu de edicion en vivo."
            # --- MINI-MENU DE EDICION BOOT.WIM ---
            $doneEditingBoot = $false
            while (-not $doneEditingBoot) {
                Clear-Host
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host "             MODO EDICION BOOT.WIM ACTIVO              " -ForegroundColor Magenta
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host "Imagen montada en: $Script:MOUNT_DIR"
                Write-Host ""
                Write-Host "   [1] Inyectar Addons y Paquetes (Ej. DaRT)"
                Write-Host "   [2] Inyectar Drivers (.inf) -> Vital para detectar discos" -ForegroundColor Cyan
                if ($isSetupIndex) {
                    Write-Host "   [3] Establecer Setup clasico como predeterminado" -ForegroundColor Yellow
                    Write-Host "   [4] Restaurar la configuracion original de Setup" -ForegroundColor Yellow
                    Write-Host "       (Arranque desde USB/ISO)" -ForegroundColor Gray
                    if ($null -ne $setupExpected) {
                        $setupLabel = if ($setupExpected.Mode -eq 'Classic') { 'Clasico' } else { 'Original' }
                        Write-Host "       Setup preparado: $setupLabel (pendiente de guardar)" -ForegroundColor Cyan
                    }
                }
                Write-Host ""
                Write-Host "   [T] Terminar edicion y proceder a Guardar" -ForegroundColor Green
                Write-Host ""
                
                $opcionBoot = Read-Host " Elige una opcion"
                switch ($opcionBoot.ToUpper()) {
                    "1" { Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Addons."; Show-Addons-GUI }
                    "2" { Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Drivers."; Show-Drivers-GUI }
                    { $isSetupIndex -and $_ -in @('3', '4') } {
                        try {
                            $setupMode = if ($_ -eq '3') { 'Classic' } else { 'Original' }
                            $setupExpected = Set-AIOBootSetupMode -MountPath $Script:MOUNT_DIR -Mode $setupMode
                            $setupEditFailed = $false
                        } catch {
                            $setupEditFailed = $true
                            Write-Log -LogLevel ERROR -Message "BootWimManager: Setup: $($_.Exception.Message)"
                            Write-Warning $_.Exception.Message
                            Write-Host 'Corrige y repite la opcion, o termina con T y N para descartar.' -ForegroundColor Yellow
                        }
                        Pause
                    }
                    "T" {
                        $saveBoot = ([string](Read-Host "Deseas GUARDAR los cambios en el boot.wim? (S/N)")).Trim().ToUpperInvariant()
                        if ($saveBoot -notin @('S', 'N')) { Write-Warning 'Responde S o N.'; break }
                        try {
                            if ($saveBoot -eq 'S') {
                                if ($setupEditFailed) { throw 'Hay una operacion Setup fallida. Repite la opcion correctamente o elige N para descartar.' }
                                if ($null -ne $setupExpected) {
                                    Assert-AIOBootSetupConfiguration -MountPath $Script:MOUNT_DIR -Expected $setupExpected
                                }
                                Write-Log -LogLevel ACTION -Message 'BootWimManager: Guardando boot.wim; configuracion Setup comprobada antes del Commit.'
                                Unmount-Image -Commit
                            } else {
                                Write-Log -LogLevel INFO -Message 'BootWimManager: Descartando todos los cambios del montaje.'
                                Unmount-Image
                            }
                            if ($Script:IMAGE_MOUNTED -eq 0) {
                                $bootMountActive = $false
                                $doneEditingBoot = $true
                            }
                        } catch {
                            Write-Log -LogLevel ERROR -Message "BootWimManager: No se completo el cierre: $($_.Exception.Message)"
                            Write-Warning $_.Exception.Message
                            Pause
                        }
                    }
                    default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
                }
            }


        } else {
            Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo critico al montar el boot.wim. Codigo DISM: $LASTEXITCODE"
            Write-Error "Fallo al montar el boot.wim."
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            $Script:MOUNTED_INDEX = $null
            Pause
        }

    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Excepcion no controlada en el gestor de arranque - $($_.Exception.Message)"
        Write-Error "Error critico en el gestor de arranque: $_"
        # No perder el seguimiento de un montaje real si falla una operacion.
        if (-not $bootMountActive) {
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            $Script:MOUNTED_INDEX = $null
        } else {
            Write-Warning 'boot.wim sigue montado. Usa Gestion de Imagen para recuperarlo o descartar los cambios.'
        }
        Pause
    }
}
