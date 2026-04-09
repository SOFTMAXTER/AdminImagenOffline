# =================================================================
#  Modulo-IsoMaker
#
#  CONTENIDO   : Show-IsoMaker-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log        : registro de eventos
#    - $script:logDir   : directorio donde se guarda el log individual
#                         de cada compilacion de oscdimg
#  CARGA       : . "$PSScriptRoot\Modulo-IsoMaker.ps1"
#
#  DEPENDENCIA EXTERNA:
#    - oscdimg.exe (Windows ADK - Deployment Tools)
#      Rutas buscadas: .\Tools\, ..\Tools\, ADK 11, ADK 10, PATH del sistema.
#      Si no se encuentra, se solicita ubicacion manual al usuario.
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

function Show-IsoMaker-GUI {

    # ------------------------------------------------------------------
    # 1. Busqueda de oscdimg.exe (ADK oficial, ruta local, PATH, manual)
    # ------------------------------------------------------------------
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

    $adkPaths = @(
        "$scriptPath\Tools\oscdimg.exe",
        "$scriptPath\..\Tools\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )

    $oscdimgExe = $null
    foreach ($path in $adkPaths) {
        if (Test-Path $path) { $oscdimgExe = $path; break }
    }

    # Fallback 1: PATH del sistema
    if (-not $oscdimgExe) {
        $cmd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
        if ($cmd) { $oscdimgExe = $cmd.Source }
    }

    # Fallback 2: Seleccion manual
    if (-not $oscdimgExe) {
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
            } else {
                return  # Usuario abrio el dialogo pero cancelo. Salida silenciosa.
            }
        } else {
            # Fallback 3: usuario rechazo la busqueda manual
            $msg = "Para utilizar el Generador de ISO, es un requisito estricto contar con 'oscdimg.exe'.`n`n" +
                   "Por favor, descarga e instala el Windows Assessment and Deployment Kit (ADK) " +
                   "(especificamente las 'Deployment Tools') desde la pagina oficial de Microsoft y vuelve a intentarlo."
            [System.Windows.Forms.MessageBox]::Show($msg, "Requisito Faltante: Windows ADK", 'OK', 'Error')
            return
        }
    }

    # ------------------------------------------------------------------
    # 2. Cargar assemblies GUI
    # ------------------------------------------------------------------
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ------------------------------------------------------------------
    # 3. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Generador de ISO (BIOS/UEFI)"
    $form.Size            = New-Object System.Drawing.Size(700, 720)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # --- Grupo 1: Configuracion de la Imagen ---
    $grpCfg          = New-Object System.Windows.Forms.GroupBox
    $grpCfg.Text     = " 1. Configuracion de la Imagen "
    $grpCfg.Location = "15, 10"
    $grpCfg.Size     = "650, 160"
    $grpCfg.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpCfg)

    $lblSrc           = New-Object System.Windows.Forms.Label
    $lblSrc.Text      = "Carpeta Origen (Debe contener boot, efi, sources...):"
    $lblSrc.Location  = "15, 25"
    $lblSrc.AutoSize  = $true
    $lblSrc.ForeColor = [System.Drawing.Color]::Silver
    $grpCfg.Controls.Add($lblSrc)

    $txtSrc          = New-Object System.Windows.Forms.TextBox
    $txtSrc.Location = "15, 45"
    $txtSrc.Size     = "530, 23"
    $grpCfg.Controls.Add($txtSrc)

    $btnSrc           = New-Object System.Windows.Forms.Button
    $btnSrc.Text      = "..."
    $btnSrc.Location  = "555, 43"
    $btnSrc.Size      = "80, 25"
    $btnSrc.BackColor = [System.Drawing.Color]::Silver
    $btnSrc.FlatStyle = "Flat"
    $grpCfg.Controls.Add($btnSrc)

    $lblDst           = New-Object System.Windows.Forms.Label
    $lblDst.Text      = "Archivo ISO Destino:"
    $lblDst.Location  = "15, 75"
    $lblDst.AutoSize  = $true
    $lblDst.ForeColor = [System.Drawing.Color]::Silver
    $grpCfg.Controls.Add($lblDst)

    $txtDst          = New-Object System.Windows.Forms.TextBox
    $txtDst.Location = "15, 95"
    $txtDst.Size     = "530, 23"
    $grpCfg.Controls.Add($txtDst)

    $btnDst           = New-Object System.Windows.Forms.Button
    $btnDst.Text      = "Guardar"
    $btnDst.Location  = "555, 93"
    $btnDst.Size      = "80, 25"
    $btnDst.BackColor = [System.Drawing.Color]::Silver
    $btnDst.FlatStyle = "Flat"
    $grpCfg.Controls.Add($btnDst)

    $lblLabel           = New-Object System.Windows.Forms.Label
    $lblLabel.Text      = "Etiqueta de Volumen (Label):"
    $lblLabel.Location  = "15, 130"
    $lblLabel.AutoSize  = $true
    $lblLabel.ForeColor = [System.Drawing.Color]::Silver
    $grpCfg.Controls.Add($lblLabel)

    $txtLabel          = New-Object System.Windows.Forms.TextBox
    $txtLabel.Location = "180, 127"
    $txtLabel.Size     = "200, 23"
    $txtLabel.Text     = "WINDOWS_CUSTOM"
    $grpCfg.Controls.Add($txtLabel)

    # --- Grupo 2: Automatizacion OOBE ---
    $grpAuto           = New-Object System.Windows.Forms.GroupBox
    $grpAuto.Text      = " 2. Automatizacion OOBE (Opcional) "
    $grpAuto.Location  = "15, 180"
    $grpAuto.Size      = "650, 100"
    $grpAuto.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpAuto)

    $lblAutoInfo           = New-Object System.Windows.Forms.Label
    $lblAutoInfo.Text      = "Inyectar 'autounattend.xml' en la raiz del medio:"
    $lblAutoInfo.Location  = "15, 25"
    $lblAutoInfo.AutoSize  = $true
    $lblAutoInfo.ForeColor = [System.Drawing.Color]::Silver
    $grpAuto.Controls.Add($lblAutoInfo)

    $txtUnattend          = New-Object System.Windows.Forms.TextBox
    $txtUnattend.Location = "15, 45"
    $txtUnattend.Size     = "430, 23"
    $grpAuto.Controls.Add($txtUnattend)

    $btnUnattend           = New-Object System.Windows.Forms.Button
    $btnUnattend.Text      = "Buscar XML"
    $btnUnattend.Location  = "455, 43"
    $btnUnattend.Size      = "80, 25"
    $btnUnattend.BackColor = [System.Drawing.Color]::Silver
    $btnUnattend.FlatStyle = "Flat"
    $btnUnattend.ForeColor = [System.Drawing.Color]::Black
    $grpAuto.Controls.Add($btnUnattend)

    $lnkWeb           = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text      = "Generador Online (schneegans.de)"
    $lnkWeb.Location  = "15, 75"
    $lnkWeb.AutoSize  = $true
    $lnkWeb.LinkColor = [System.Drawing.Color]::Yellow
    $grpAuto.Controls.Add($lnkWeb)

    # --- Log de progreso ---
    $txtLog              = New-Object System.Windows.Forms.TextBox
    $txtLog.Location     = "15, 290"
    $txtLog.Size         = "650, 300"
    $txtLog.Multiline    = $true
    $txtLog.ScrollBars   = "Vertical"
    $txtLog.ReadOnly     = $true
    $txtLog.BackColor    = [System.Drawing.Color]::Black
    $txtLog.ForeColor    = [System.Drawing.Color]::Lime
    $txtLog.Font         = New-Object System.Drawing.Font("Consolas", 10)
    $txtLog.Text         = "Esperando configuracion...`r`nMotor: $oscdimgExe"
    $form.Controls.Add($txtLog)

    # --- Boton principal ---
    $btnMake           = New-Object System.Windows.Forms.Button
    $btnMake.Text      = "CREAR ISO BOOTEABLE"
    $btnMake.Location  = "200, 615"
    $btnMake.Size      = "300, 40"
    $btnMake.BackColor = [System.Drawing.Color]::SeaGreen
    $btnMake.ForeColor = [System.Drawing.Color]::White
    $btnMake.FlatStyle = "Flat"
    $btnMake.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnMake)

    # ------------------------------------------------------------------
    # 4. Eventos de navegacion
    # ------------------------------------------------------------------

    # Boton "..." — seleccionar carpeta origen y auto-generar etiqueta
    $btnSrc.Add_Click({
        $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Selecciona carpeta raiz de Windows (donde estan setup.exe, boot, efi...)"

        if ($fbd.ShowDialog() -eq 'OK') {
            $txtSrc.Text = $fbd.SelectedPath

            # Auto-etiqueta oficial: lee metadatos del install.wim/esd via DISM nativo
            $installWim  = Join-Path $fbd.SelectedPath "sources\install.wim"
            $installEsd  = Join-Path $fbd.SelectedPath "sources\install.esd"
            $targetImage = $null

            if     (Test-Path -LiteralPath $installWim) { $targetImage = $installWim }
            elseif (Test-Path -LiteralPath $installEsd) { $targetImage = $installEsd }

            if ($targetImage) {
                $txtLog.AppendText("`r`n[INFO] Analizando metadatos (Motor DISM Nativo)...")
                $form.Refresh()

                try {
                    # 1. Determinar prefijo por familia de edicion
                    $prefix    = "CCCOMA"
                    $allImages = Get-WindowsImage -ImagePath $targetImage -ErrorAction Stop
                    $allNames  = $allImages.ImageName -join " "

                    if     ($allNames -match "Server")                          { $prefix = "SSS"   }
                    elseif ($allNames -match "Enterprise" -or $allNames -match "LTSC") { $prefix = "CCBOMA" }

                    # 2. Metadata profunda del indice 1
                    $detailedImage = Get-WindowsImage -ImagePath $targetImage -Index 1 -ErrorAction Stop

                    # 3. Arquitectura
                    $archStr = switch ($detailedImage.Architecture) {
                        0  { "X86"   }
                        9  { "X64"   }
                        12 { "ARM64" }
                        Default { "X64" }
                    }

                    # 4. Idioma (compatible con multiples versiones del modulo DISM)
                    $langStr = "EN-US"
                    if ($null -ne $detailedImage.Languages -and $detailedImage.Languages.Count -gt 0) {
                        $langStr = $detailedImage.Languages[0].ToString().ToUpper()
                    } elseif ($null -ne $detailedImage.Language) {
                        $langStr = $detailedImage.Language.ToString().ToUpper()
                    }

                    # 5. Ensamblar etiqueta oficial
                    $txtLabel.Text = "${prefix}_${archStr}FRE_${langStr}_DV9"

                    $txtLog.AppendText("`r`n[EXITO] Etiqueta Oficial Generada: $($txtLabel.Text)")
                    $txtLog.AppendText("`r`n[INFO] Familia: $prefix | Arch: $archStr | Idioma: $langStr")

                } catch {
                    $txtLog.AppendText("`r`n[WARN] Error leyendo metadatos profundos. Usando etiqueta estandar.")
                    $txtLabel.Text = "CCCOMA_X64FRE_ES-ES_DV9"
                }
            } else {
                $txtLog.AppendText("`r`n[WARN] No se encontro install.wim/esd. Usando etiqueta base.")
                $txtLabel.Text = "WINDOWS_CUSTOM"
            }
        }
    })

    # Boton "Guardar" — seleccionar ruta de salida ISO
    $btnDst.Add_Click({
        $sfd        = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Imagen ISO (*.iso)|*.iso"
        if ($sfd.ShowDialog() -eq 'OK') { $txtDst.Text = $sfd.FileName }
    })

    # Boton "Buscar XML" — seleccionar archivo autounattend.xml
    $btnUnattend.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "XML Files (*.xml)|*.xml"
        if ($ofd.ShowDialog() -eq 'OK') { $txtUnattend.Text = $ofd.FileName }
    })

    # Link al generador online
    $lnkWeb.Add_Click({ Start-Process "https://schneegans.de/windows/unattend-generator/" })

    # ------------------------------------------------------------------
    # 5. Logica principal — CREAR ISO BOOTEABLE (sincrono con DoEvents)
    # ------------------------------------------------------------------
    $btnMake.Add_Click({
        $src     = $txtSrc.Text
        $iso     = $txtDst.Text
        $label   = $txtLabel.Text
        $xmlPath = $txtUnattend.Text

        # Validacion de rutas obligatorias
        if (-not $src -or -not $iso) {
            Write-Log -LogLevel WARN -Message "ISO_Maker: El usuario intento compilar sin definir rutas de origen o destino."
            [System.Windows.Forms.MessageBox]::Show("Faltan rutas.", "Error", 'OK', 'Error')
            return
        }

        # Validacion de estructura BIOS boot
        $biosBoot = Join-Path $src "boot\etfsboot.com"
        $uefiBoot = Join-Path $src "efi\microsoft\boot\efisys.bin"

        if (-not (Test-Path $biosBoot)) {
            Write-Log -LogLevel ERROR -Message "ISO_Maker: Fallo estructural. Falta boot\etfsboot.com en la ruta de origen ($src)."
            [System.Windows.Forms.MessageBox]::Show("No se encuentra boot\etfsboot.com.", "Error Estructural", 'OK', 'Error')
            return
        }

        # Inyeccion opcional de autounattend.xml
        if (-not [string]::IsNullOrWhiteSpace($xmlPath) -and (Test-Path $xmlPath)) {
            Write-Log -LogLevel INFO -Message "ISO_Maker: Archivo Unattend.xml detectado. Inyectando en la raiz de la ISO."
            try {
                Copy-Item -Path $xmlPath -Destination (Join-Path $src "autounattend.xml") -Force -ErrorAction Stop
            } catch {
                Write-Log -LogLevel ERROR -Message "ISO_Maker: Fallo al copiar el archivo XML a la raiz - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error copiando XML: $_", "Error", 'OK', 'Error')
                return
            }
        }

        # Bloquear controles durante la compilacion
        $btnMake.Enabled  = $false
        $grpCfg.Enabled   = $false
        $grpAuto.Enabled  = $false
        $txtLog.Text      = "--- INICIO DEL LOG ---`r`n"
        $form.Cursor      = [System.Windows.Forms.Cursors]::WaitCursor

        # Construir argumentos para oscdimg.exe
        $bootArg = "-bootdata:2#p0,e,b`"{0}`"#pEF,e,b`"{1}`"" -f $biosBoot, $uefiBoot
        $allArgs = '-m -o -u2 -udfver102 -l"{0}" {1} "{2}" "{3}"' -f $label, $bootArg, $src, $iso

        Write-Log -LogLevel ACTION -Message "ISO_Maker: Iniciando compilacion de ISO..."
        Write-Log -LogLevel INFO   -Message "ISO_Maker: Etiqueta: [$label] | Origen: [$src] | Destino: [$iso]"
        Write-Log -LogLevel INFO   -Message "ISO_Maker: Argumentos CMD: oscdimg.exe $allArgs"

        $txtLog.AppendText("COMANDO:`r`noscdimg.exe $allArgs`r`n----------------`r`n")
        $form.Refresh()

        try {
            $pInfo                        = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName               = $oscdimgExe
            $pInfo.Arguments              = $allArgs
            $pInfo.RedirectStandardOutput = $true
            $pInfo.RedirectStandardError  = $true
            $pInfo.UseShellExecute        = $false
            $pInfo.CreateNoWindow         = $true

            # Almacenado en $script: para que FormClosing pueda verlo
            $script:isoProc           = New-Object System.Diagnostics.Process
            $script:isoProc.StartInfo = $pInfo

            if ($script:isoProc.Start()) {
                # Bucle de lectura sincrono con DoEvents — evita el deadlock de ReadToEnd()
                while (-not $script:isoProc.HasExited) {
                    while ($script:isoProc.StandardOutput.Peek() -gt -1) {
                        $line = $script:isoProc.StandardOutput.ReadLine()
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $txtLog.AppendText($line + "`r`n")
                            $txtLog.ScrollToCaret()
                        }
                    }
                    while ($script:isoProc.StandardError.Peek() -gt -1) {
                        $errLine = $script:isoProc.StandardError.ReadLine()
                        if ([string]::IsNullOrWhiteSpace($errLine)) {
                            $txtLog.AppendText($errLine + "`r`n")
                            continue
                        }
                        # Filtrar lineas de progreso vs errores reales
                        if ($errLine -match "% complete" -or $errLine -match "Scanning source") {
                            $txtLog.AppendText($errLine + "`r`n")
                        } else {
                            $txtLog.AppendText("[ERR] " + $errLine + "`r`n")
                        }
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 50
                }

                # Lectura remanente tras la salida del proceso
                $remOut = $script:isoProc.StandardOutput.ReadToEnd()
                $remErr = $script:isoProc.StandardError.ReadToEnd()
                if ($remOut) { $txtLog.AppendText($remOut) }
                if ($remErr) { $txtLog.AppendText($remErr) }

                $exitCode = $script:isoProc.ExitCode

                # Guardar log individual de esta compilacion
                try {
                    $timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
                    $logFileName = "ISO_Build_$timestamp.log"
                    $logPath     = Join-Path $script:logDir $logFileName   # $script:logDir provisto por el nucleo
                    $txtLog.Text | Out-File -FilePath $logPath -Encoding utf8 -Force
                    $txtLog.AppendText("`r`n[INFO] Log guardado en: $logFileName")
                    Write-Log -LogLevel INFO -Message "ISO_Maker: Archivo de volcado individual creado en: $logPath"
                } catch {
                    $txtLog.AppendText("`r`n[WARN] No se pudo guardar el archivo de log.")
                    Write-Log -LogLevel WARN -Message "ISO_Maker: No se pudo guardar el archivo .log individual de oscdimg."
                }

                if ($exitCode -eq 0) {
                    Write-Log -LogLevel INFO -Message "ISO_Maker: Compilacion de ISO completada con EXITO."
                    $txtLog.AppendText("`r`n[EXITO] ISO Creada.")
                    [System.Windows.Forms.MessageBox]::Show("ISO creada en:`n$iso", "Exito", 'OK', 'Information')
                } else {
                    Write-Log -LogLevel ERROR -Message "ISO_Maker: oscdimg fallo con codigo de salida: $exitCode"
                    $txtLog.AppendText("`r`n[ERROR] Codigo: $exitCode")
                    [System.Windows.Forms.MessageBox]::Show("Fallo la creacion. Revisa el Log para detalles.", "Error", 'OK', 'Error')
                }
            } else {
                Write-Log -LogLevel ERROR -Message "ISO_Maker: Fallo critico. El proceso oscdimg.exe no pudo iniciarse."
                throw "No inicio oscdimg"
            }

        } catch {
            Write-Log -LogLevel ERROR -Message "ISO_Maker: Excepcion controlada de aplicacion - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Excepcion: $_", "Crash", 'OK', 'Error')
            $txtLog.AppendText("`r`nEXCEPCION: $_")
        } finally {
            # Limpieza blindada — se ejecuta siempre, incluso si hubo excepcion
            if ($null -ne $script:isoProc) {
                if (-not $script:isoProc.HasExited) {
                    try { $script:isoProc.Kill() } catch {}
                }
                $script:isoProc.Dispose()
                $script:isoProc = $null
            }
            if (-not $form.IsDisposed) {
                $btnMake.Enabled = $true
                $grpCfg.Enabled  = $true
                $grpAuto.Enabled = $true
                $form.Cursor     = [System.Windows.Forms.Cursors]::Default
            }
        }
    })

    # ------------------------------------------------------------------
    # 6. Evento FormClosing — proteger contra cierre durante compilacion
    # ------------------------------------------------------------------
    $form.Add_FormClosing({
        if ($null -ne $script:isoProc -and -not $script:isoProc.HasExited) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "La ISO se esta compilando en este momento.`nSi sales ahora, la operacion se cancelara y el archivo ISO quedara corrupto.`n`n¿Deseas forzar la salida?",
                "Advertencia de Interrupcion",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($res -eq 'No') {
                $_.Cancel = $true
            } else {
                try { $script:isoProc.Kill() } catch {}
                # Dispose lo maneja el finally del boton cuando el proceso muere
            }
        }
    })

    # ------------------------------------------------------------------
    # 7. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    [GC]::Collect()
}