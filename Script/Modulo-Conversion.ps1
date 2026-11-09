# =================================================================
#  Modulo-Conversion
#
#  CONTENIDO   : Convert-VHD, Convert-ImageFormat (WIM/ESD/SWM), Convert-WIMToESD
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base (se actualiza al convertir)
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Select-PathDialog      : ui para seleccion de rutas de lectura
#    - Select-SavePathDialog  : ui para guardar nuevos archivos WIM/ESD/SWM
#    - Get-UnusedDriveLetter  : deteccion de unidades libres para VHD
#    - Find-AIOUpdateWimlib, Invoke-AIOUpdateWimlibRead, Get-AIOUpdateWimFileSha256,
#      ConvertTo-AIOUpdateNativeArgument : (Modulo-Actualizaciones.ps1) verificacion
#      e incorporacion de WinRE con wimlib, sin montar el WIM
#  CARGA       : . "$PSScriptRoot\Modulo-Conversion.ps1"
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

# =============================================
#  FUNCIONES DE ACCION (Conversion de Imagen)
# =============================================
function Convert-VHD {
    Clear-Host
    Write-AIOConversionSection -Title 'CONVERSION | VHD / VHDX -> WIM' -Color Yellow
    Write-Host '  Captura Windows e incluye WinRE cuando esta disponible en el VHD.' -ForegroundColor Gray
    
    Write-Log -LogLevel INFO -Message "ConvertVHD: Iniciando modulo de conversion inteligente de VHD/VHDX a WIM."

    # 1. Verificar modulo Hyper-V
    if (-not (Get-Command "Mount-Vhd" -ErrorAction SilentlyContinue)) {
        Write-Log -LogLevel ERROR -Message "ConvertVHD: Faltan dependencias. El cmdlet 'Mount-Vhd' no esta disponible."
        Write-AIOConversionSection -Title 'DEPENDENCIA NO DISPONIBLE' -Color Red
        Write-Host "  El cmdlet 'Mount-Vhd' no esta disponible en el sistema actual." -ForegroundColor Red
        Write-Host "Necesitas habilitar las herramientas de gestion de discos virtuales de Hyper-V." -ForegroundColor Gray
        Write-Host ""
        Write-Host "Para solucionarlo, abre una consola PowerShell como Administrador y ejecuta:" -ForegroundColor Yellow
        Write-Host "Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell" -ForegroundColor Cyan
        Write-Host ""
        Pause; return
    }

    # 2. Seleccion de Archivo
    Write-AIOConversionSection -Title 'ORIGEN Y DESTINO' -Step 1
    Write-Host '  Selecciona el disco virtual y la ruta del nuevo archivo WIM.' -ForegroundColor Gray
    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo VHD o VHDX a convertir" -Filter "Archivos VHD (*.vhd, *.vhdx)|*.vhd;*.vhdx|Todos (*.*)|*.*"
    if (-not $path) { 
        Write-Log -LogLevel INFO -Message "ConvertVHD: El usuario cancelo la seleccion del archivo de origen."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    $VHD_FILE_PATH = $path
    Write-Log -LogLevel INFO -Message "ConvertVHD: Archivo origen seleccionado -> $VHD_FILE_PATH"

    # 3. Seleccion de Destino
    $vhdFileObject = Get-Item -Path $VHD_FILE_PATH
    Write-AIOConversionField -Label 'Origen' -Value $VHD_FILE_PATH
    Write-AIOConversionField -Label 'Tamano origen' -Value (Format-AIOConversionSize -Bytes $vhdFileObject.Length)
    $DEFAULT_DEST_PATH = Join-Path $vhdFileObject.DirectoryName "$($vhdFileObject.BaseName).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Capturar VHD como WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { 
        Write-Log -LogLevel INFO -Message "ConvertVHD: El usuario cancelo la seleccion del archivo de destino."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    Write-Log -LogLevel INFO -Message "ConvertVHD: Archivo destino establecido -> $DEST_WIM_PATH"
    Write-AIOConversionField -Label 'Destino' -Value $DEST_WIM_PATH
    Write-AIOConversionField -Label 'Compresion' -Value 'Maxima (LZX / Compress:Max)'

    # 4. Proceso de Montaje y Captura
    Write-AIOConversionSection -Title 'WINDOWS Y RECUPERACION' -Step 2
    Write-Host '  Montando el disco virtual y buscando la instalacion de Windows...' -ForegroundColor Gray
    Write-Log -LogLevel ACTION -Message "ConvertVHD: Iniciando proceso de montaje y analisis de particiones."

    $DRIVE_LETTER = $null
    $mountedDisk = $null
    $temporaryAccessPaths = New-Object 'System.Collections.Generic.List[object]'
    $workRoot = $null
    $pendingWim = $null
    $cleanupSafe = $true
    $winreSource = $null
    $winreHash = $null
    $injectWinRE = $false
    $conversionCompleted = $false
    $timer = $null

    try {
        # Publicar el resultado solo cuando la captura y WinRE esten verificados.
        if ([IO.Path]::GetFullPath($DEST_WIM_PATH) -eq [IO.Path]::GetFullPath($VHD_FILE_PATH)) {
            throw "El archivo de destino debe ser diferente del VHD de origen."
        }
        if ((Get-VHD -Path $VHD_FILE_PATH -ErrorAction Stop).Attached) {
            throw "El VHD ya esta conectado. Desconectalo antes de iniciar la conversion."
        }
        $sessionId = [guid]::NewGuid().ToString('N')
        $workRoot = Join-Path $Script:Scratch_DIR "ConvertVHD_$sessionId"
        New-Item -Path $workRoot -ItemType Directory -ErrorAction Stop | Out-Null
        $pendingWim = Join-Path (Split-Path -Path $DEST_WIM_PATH -Parent) "ConvertVHD_$sessionId.partial.wim"

        # A. Montar VHD
        $mountedDisk = Mount-Vhd -Path $VHD_FILE_PATH -NoDriveLetter -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2

        # B. Obtener particiones y encontrar Windows
        $vhdDisk = $mountedDisk | Get-Disk -ErrorAction Stop
        $allPartitions = @(Get-Partition -DiskNumber $vhdDisk.Number -ErrorAction Stop)
        $partitions = $allPartitions | Where-Object { 
            $_.Type -notin @('System', 'Reserved', 'Recovery') -and 
            $_.IsHidden -eq $false -and
            $_.Size -gt 500MB 
        }

        foreach ($part in $partitions) {
            $currentLet = $part.DriveLetter
            $assignedTemp = $false
            
            if (-not $currentLet) {
                try {
                    $freeLet = Get-UnusedDriveLetter
                    Write-Host "  Inspeccionando particion $($part.PartitionNumber) con letra temporal $freeLet`:..." -ForegroundColor Gray
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction Stop
                    $currentLet = $freeLet
                    $assignedTemp = $true
                    $temporaryAccessPaths.Add([pscustomobject]@{
                        Partition = $part
                        AccessPath = "$($freeLet):\"
                    })
                    
                    $timeout = 50
                    while (-not (Test-Path -LiteralPath "$($freeLet):\") -and $timeout -gt 0) { Start-Sleep -Milliseconds 100; $timeout-- }
                } catch { continue }
            }

            if ($currentLet) {
                $winPath = "$currentLet`:\Windows\System32\config\SYSTEM"
                if (Test-Path -LiteralPath $winPath) {
                    $DRIVE_LETTER = $currentLet
                    Write-AIOConversionField -Label 'Windows' -Value "$DRIVE_LETTER`:\Windows" -Color Green
                    Write-AIOConversionField -Label 'Particion' -Value ("{0} | {1}" -f $part.PartitionNumber, (Format-AIOConversionSize -Bytes $part.Size))
                    break 
                } else {
                    Write-Host "  Particion $currentLet`: sin instalacion de Windows; se omite." -ForegroundColor Gray
                    if ($assignedTemp) {
                        Remove-PartitionAccessPath -InputObject $part -AccessPath "$($currentLet):\" -ErrorAction Stop
                        $temporaryAccessPaths.RemoveAt($temporaryAccessPaths.Count - 1)
                    }
                }
            }
        }

        if (-not $DRIVE_LETTER) {
            throw "No se encontro ninguna instalacion de Windows valida en el VHD. Asegurese de que la imagen no esta cifrada con BitLocker."
        }

        # C. Buscar WinRE dentro de Windows y en las particiones del mismo VHD.
        Write-Host ''
        Write-Host '  Buscando WinRE en Windows y en las particiones de recuperacion...' -ForegroundColor Gray
        $windowsRoot = "$($DRIVE_LETTER):\"
        $embeddedWinRE = Join-Path $windowsRoot 'Windows\System32\Recovery\winre.wim'
        if (Test-Path -LiteralPath $embeddedWinRE -PathType Leaf -ErrorAction Stop) {
            $winreSource = $embeddedWinRE
            Write-AIOConversionField -Label 'WinRE' -Value 'Ya incluido en Windows' -Color Green
        } else {
            $candidates = New-Object 'System.Collections.Generic.List[object]'
            $localRecovery = Join-Path $windowsRoot 'Recovery\WindowsRE\winre.wim'
            if (Test-Path -LiteralPath $localRecovery -PathType Leaf -ErrorAction Stop) {
                $candidates.Add([pscustomobject]@{ Path = $localRecovery; PartitionNumber = $part.PartitionNumber })
            }
            $recoveryPartitions = @($allPartitions | Where-Object {
                $_.Type -eq 'Recovery' -or
                ([string]$_.GptType).Trim('{}') -eq 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' -or
                $_.MbrType -eq 0x27
            })
            foreach ($recoveryPart in $recoveryPartitions) {
                if ($recoveryPart.DriveLetter) {
                    $recoveryRoot = "$($recoveryPart.DriveLetter):\"
                } else {
                    $recoveryRoot = Join-Path $workRoot "Recovery_$($recoveryPart.PartitionNumber)"
                    New-Item -Path $recoveryRoot -ItemType Directory -ErrorAction Stop | Out-Null
                    Add-PartitionAccessPath -InputObject $recoveryPart -AccessPath $recoveryRoot -ErrorAction Stop
                    $temporaryAccessPaths.Add([pscustomobject]@{
                        Partition = $recoveryPart
                        AccessPath = $recoveryRoot
                    })
                }
                $recoveryFile = Join-Path $recoveryRoot 'Recovery\WindowsRE\winre.wim'
                if (Test-Path -LiteralPath $recoveryFile -PathType Leaf -ErrorAction Stop) {
                    $candidates.Add([pscustomobject]@{
                        Path = $recoveryFile
                        PartitionNumber = $recoveryPart.PartitionNumber
                    })
                }
            }
            if ($candidates.Count -eq 1) {
                $winreSource = $candidates[0].Path
            } elseif ($candidates.Count -gt 1) {
                Write-Host ''
                Write-Host '  Hay varias copias de WinRE. Selecciona la que se incluira en el WIM.' -ForegroundColor Yellow
                Write-Host ('  {0,-8} {1,-11} {2}' -f 'COPIA', 'PARTICION', 'ARCHIVO') -ForegroundColor Gray
                for ($i = 0; $i -lt $candidates.Count; $i++) {
                    Write-Host ('  {0,-8} {1,-11} {2}' -f ('[' + ($i + 1) + ']'), $candidates[$i].PartitionNumber, $candidates[$i].Path) -ForegroundColor White
                }
                Write-Host ''
                $choice = 0
                do {
                    $answer = Read-Host 'Numero de copia de WinRE (Enter cancela la conversion)'
                    if ([string]::IsNullOrWhiteSpace($answer)) { throw 'Conversion cancelada al seleccionar WinRE.' }
                } until ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $candidates.Count)
                $winreSource = $candidates[$choice - 1].Path
            }
            $injectWinRE = -not [string]::IsNullOrEmpty($winreSource)
        }

        if ($winreSource) {
            if ((Get-Item -LiteralPath $winreSource -Force -ErrorAction Stop).Length -eq 0) {
                throw "El WinRE encontrado esta vacio: '$winreSource'."
            }
            Write-Log -LogLevel INFO -Message "ConvertVHD: WinRE seleccionado -> $winreSource"
            Write-AIOConversionField -Label 'Origen WinRE' -Value $winreSource
            # Falla rapido, antes de la captura larga: wimlib verify + dependencias de incorporacion.
            Assert-AIOConversionWinREIntegrity -WinREPath $winreSource
            $winreHash = (Get-FileHash -LiteralPath $winreSource -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($injectWinRE) {
                Write-AIOConversionField -Label 'WinRE' -Value 'Se incorporara a Windows\System32\Recovery' -Color Cyan
            }
        } else {
            Write-Warning 'No se encontro winre.wim en Windows ni en las particiones de recuperacion del VHD. El WIM se capturara sin WinRE.'
            Write-Log -LogLevel WARN -Message 'ConvertVHD: Captura sin WinRE; archivo ausente en el VHD.'
        }

        # =========================================================
        #  Auto-Detección de Edición y Petición de Metadatos (ACTUALIZADO CON CATÁLOGO)
        # =========================================================
        Write-AIOConversionSection -Title 'DATOS DE LA IMAGEN' -Step 3
        Write-Host '  Detectando la edicion de Windows...' -ForegroundColor Gray
        $defaultName = "Captured VHD"
        $defaultDesc = "Imagen capturada desde VHD el $(Get-Date -Format 'yyyy-MM-dd')"
        $softwareHive = "$DRIVE_LETTER`:\Windows\System32\config\SOFTWARE"

        if (Test-Path -LiteralPath $softwareHive) {
            $tempHive = "HKLM\TempVhdSoft_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                reg load $tempHive $softwareHive 2>$null | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    $regData = Get-ItemProperty -Path "Registry::$tempHive\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue

                    if ($regData) {
                        if ($regData.EditionID -and (Get-Command Get-WindowsEditionMetadata -ErrorAction SilentlyContinue)) {
                            $metadata = Get-WindowsEditionMetadata -QueryString $regData.EditionID
                            $defaultName = $metadata.Name
                            $defaultDesc = $metadata.Description
                            if ($regData.CurrentBuildNumber -ge 22000) {
                                $defaultName = $defaultName -replace "Windows ", "Windows 11 "
                            } else {
                                $defaultName = $defaultName -replace "Windows ", "Windows 10 "
                            }
                        } elseif ($regData.ProductName) {
                            $defaultName = $regData.ProductName
                            if ($regData.CurrentBuildNumber -ge 22000) {
                                $defaultName = $defaultName -replace "Windows 10", "Windows 11"
                            }
                        }
                    }
                }
            } catch {
                Write-Log -LogLevel WARN -Message "ConvertVHD: No se pudo auto-detectar la edicion en el registro offline."
            } finally {
                reg unload $tempHive 2>$null | Out-Null
                [GC]::Collect()
            }
        }

        Write-Host ''
        Write-AIOConversionField -Label 'Nombre' -Value $defaultName
        Write-AIOConversionField -Label 'Descripcion' -Value $defaultDesc
        Write-Host ''
        Write-Host '  Presiona Enter para conservar valor por defecto o escribe uno nuevo.' -ForegroundColor Gray
        $inputName = Read-Host '  Nombre de la imagen'
        $inputDesc = Read-Host '  Descripcion de la imagen'
        
        if ([string]::IsNullOrWhiteSpace($inputName)) { $IMAGE_NAME = $defaultName } else { $IMAGE_NAME = $inputName }
        if ([string]::IsNullOrWhiteSpace($inputDesc)) { $IMAGE_DESC = $defaultDesc } else { $IMAGE_DESC = $inputDesc }

        Write-Log -LogLevel INFO -Message "ConvertVHD: Metadatos -> Nombre: [$IMAGE_NAME] | Desc: [$IMAGE_DESC]"

        Write-AIOConversionSection -Title 'CAPTURA DE WINDOWS' -Step 4
        Write-AIOConversionField -Label 'Volumen' -Value "$DRIVE_LETTER`:\"
        Write-AIOConversionField -Label 'Destino' -Value $DEST_WIM_PATH
        Write-AIOConversionField -Label 'Nombre' -Value $IMAGE_NAME
        Write-AIOConversionField -Label 'Descripcion' -Value $IMAGE_DESC
        Write-AIOConversionField -Label 'Compresion' -Value 'Maxima (LZX / Compress:Max)'
        Write-Host ''
        Write-Host '  El tiempo mostrado al finalizar incluye captura, WinRE y desmontaje.' -ForegroundColor Gray
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Write-Host '  Preparando el volumen para la captura (TRIM)...' -ForegroundColor Gray
        try { Optimize-Volume -DriveLetter $DRIVE_LETTER -ReTrim -ErrorAction Stop | Out-Null } catch {}
        
        # 5. Captura (DISM)
        Write-Host '  Capturando la imagen. DISM mostrara su progreso a continuacion.' -ForegroundColor Cyan
        Write-Host ''
        
        dism /capture-image /imagefile:"$pendingWim" /capturedir:"$DRIVE_LETTER`:\" /name:"$IMAGE_NAME" /description:"$IMAGE_DESC" /compress:max /checkintegrity /ScratchDir:"$Script:Scratch_DIR"

        if ($LASTEXITCODE -ne 0) { throw "Fallo DISM durante la captura (Codigo: $LASTEXITCODE)." }

        Write-AIOConversionSection -Title 'WINRE Y FINALIZACION' -Step 5
        if ($winreSource) {
            if ($injectWinRE) {
                Write-Host '  Incorporando winre.wim a Windows\System32\Recovery (wimlib, sin montar el WIM)...' -ForegroundColor Cyan
                Add-AIOConversionWinREToWim -WimPath $pendingWim -WinREPath $winreSource -Index 1
            }

            # Comprobacion final por lectura binaria directa desde el WIM guardado, sin montaje ni copia temporal.
            Write-Host '  Verificando WinRE en el WIM guardado (lectura directa, sin montaje)...' -ForegroundColor Gray
            $embeddedHash = Get-AIOUpdateWimFileSha256 -WimPath $pendingWim -Index 1 -ImagePath 'Windows/System32/Recovery/winre.wim'
            if ($embeddedHash -ne $winreHash) {
                throw 'WinRE no coincide con el origen tras guardar el WIM.'
            }
            Write-Log -LogLevel INFO -Message "ConvertVHD: WinRE verificado dentro del WIM. SHA256=$winreHash"
            Write-AIOConversionField -Label 'WinRE' -Value 'Incluido y verificado (wimlib + SHA-256)' -Color Green
        } else {
            Write-AIOConversionField -Label 'WinRE' -Value 'No incluido: no se encontro en el VHD' -Color Yellow
        }

        Write-Host '  Guardando el archivo WIM en el destino seleccionado...' -ForegroundColor Gray
        # El temporal esta junto al destino para publicar en el mismo volumen.
        if (Test-Path -LiteralPath $DEST_WIM_PATH) {
            [IO.File]::Replace($pendingWim, $DEST_WIM_PATH, [NullString]::Value)
        } else {
            [IO.File]::Move($pendingWim, $DEST_WIM_PATH)
        }
        $pendingWim = $null
        $Script:WIM_FILE_PATH = $DEST_WIM_PATH
        $conversionCompleted = $true
        Write-Log -LogLevel INFO -Message "ConvertVHD: WIM publicado -> $DEST_WIM_PATH"

    } catch {
        Write-AIOConversionSection -Title 'CONVERSION NO COMPLETADA' -Color Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "ConvertVHD: Excepcion critica durante la conversion - $($_.Exception.Message)"
    } finally {
        # Retirar solo los accesos temporales creados por esta operacion.
        foreach ($access in $temporaryAccessPaths) {
            try {
                Remove-PartitionAccessPath -InputObject $access.Partition -AccessPath $access.AccessPath -ErrorAction Stop
            } catch {
                $cleanupSafe = $false
                Write-Warning "No se pudo retirar el acceso temporal '$($access.AccessPath)': $($_.Exception.Message)"
            }
        }
        if ($mountedDisk) {
            try {
                Write-Host '  Desmontando el disco virtual...' -ForegroundColor Gray
                Dismount-Vhd -Path $VHD_FILE_PATH -ErrorAction Stop
            } catch {
                $cleanupSafe = $false
                Write-Warning "No se pudo desmontar el VHD: $($_.Exception.Message)"
            }
        }
        if ($pendingWim -and (Test-Path -LiteralPath $pendingWim)) {
            Remove-Item -LiteralPath $pendingWim -Force -ErrorAction SilentlyContinue
        }
        # Nunca recorrer recursivamente una carpeta que pueda seguir montada.
        if ($cleanupSafe -and $workRoot -and (Test-Path -LiteralPath $workRoot)) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($timer) { $timer.Stop() }
        if ($conversionCompleted) {
            if ($cleanupSafe) {
                Write-AIOConversionSection -Title 'CONVERSION COMPLETADA' -Color Green
            } else {
                Write-AIOConversionSection -Title 'WIM CREADO; REVISAR LIMPIEZA' -Color Yellow
            }
            Write-AIOConversionField -Label 'Archivo WIM' -Value $DEST_WIM_PATH
            Write-AIOConversionField -Label 'Nombre' -Value $IMAGE_NAME
            Write-AIOConversionField -Label 'Compresion' -Value 'Maxima (LZX)'
            $resultFile = Get-Item -LiteralPath $DEST_WIM_PATH -ErrorAction SilentlyContinue
            if ($resultFile) {
                Write-AIOConversionField -Label 'Tamano final' -Value (Format-AIOConversionSize -Bytes $resultFile.Length)
            }
            if ($timer) {
                Write-AIOConversionField -Label 'Tiempo' -Value $timer.Elapsed.ToString('hh\:mm\:ss')
            }
            if ($winreSource) {
                Write-AIOConversionField -Label 'WinRE' -Value 'Windows\System32\Recovery\winre.wim' -Color Green
                Write-AIOConversionField -Label 'Verificacion' -Value 'wimlib verify + SHA-256 coincide con el origen' -Color Green
            } else {
                Write-AIOConversionField -Label 'WinRE' -Value 'No incluido (ausente en el VHD)' -Color Yellow
            }
            if ($cleanupSafe) {
                Write-AIOConversionField -Label 'Montajes' -Value 'Cerrados' -Color Green
            } else {
                Write-AIOConversionField -Label 'Montajes' -Value 'Revisa los avisos de limpieza anteriores' -Color Yellow
            }
            Write-Host ''
        }
        Pause
    }
}

# Conversion SWM: no montar/aplicar imagenes ni modificar archivos de origen.
function Get-AIOWimContainerInfo {
    param([string]$Path)
    if (-not ('AIOWimContainerV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AIOWimContainerV1 {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct Info {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string WimPath;
        public Guid Guid;
        public uint ImageCount, CompressionType;
        public ushort PartNumber, TotalParts;
        public uint BootIndex, WimAttributes, WimFlagsAndAttr;
    }
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr WIMCreateFile(string path, uint access, uint disposition, uint flags, uint compression, out uint result);
    [DllImport("wimgapi.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WIMGetAttributes(IntPtr handle, out Info info, uint size);
    [DllImport("wimgapi.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WIMCloseHandle(IntPtr handle);
    public static Info Read(string path) {
        uint result;
        // Acceso de consulta, WIM_OPEN_EXISTING; no se modifica la imagen.
        IntPtr handle = WIMCreateFile(path, 0, 3, 0, 0, out result);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            Info info;
            if (!WIMGetAttributes(handle, out info, (uint)Marshal.SizeOf(typeof(Info)))) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        } finally { WIMCloseHandle(handle); }
    }
}
'@
    }
    [AIOWimContainerV1]::Read([IO.Path]::GetFullPath($Path))
}

function Get-AIOSwmSet {
    param([string]$FirstPart)
    $first = Get-Item -LiteralPath $FirstPart -Force -ErrorAction Stop
    if ($first.Extension -ine '.swm') { throw 'Selecciona un archivo .swm.' }
    $info = Get-AIOWimContainerInfo -Path $first.FullName
    if ($info.PartNumber -ne 1) { throw 'Selecciona la primera parte del conjunto (por ejemplo, install.swm, no install2.swm).' }
    if ($info.TotalParts -lt 1 -or $info.ImageCount -lt 1) { throw 'La primera parte SWM no contiene una cabecera valida.' }
    # El patron que se pasara a DISM debe contener exclusivamente este conjunto.
    $files = @(Get-ChildItem -LiteralPath $first.DirectoryName -File -Force -ErrorAction Stop | Where-Object {
        $_.Extension -ieq '.swm' -and $_.BaseName.StartsWith($first.BaseName, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($files.Count -ne $info.TotalParts) {
        throw "Conjunto incompleto o ambiguo: se esperaban $($info.TotalParts) partes y se encontraron $($files.Count). Coloca todas sus partes en una carpeta separada."
    }
    $parts = @{}
    foreach ($file in $files) {
        $part = Get-AIOWimContainerInfo -Path $file.FullName
        $number = [int]$part.PartNumber
        if ($part.Guid -ne $info.Guid -or $part.TotalParts -ne $info.TotalParts -or
            $number -lt 1 -or $number -gt $info.TotalParts -or $parts.ContainsKey($number)) {
            throw "Parte de otro conjunto, duplicada o invalida: $($file.Name)"
        }
        $expectedName = $first.BaseName + $(if ($number -eq 1) { '' } else { [string]$number }) + '.swm'
        if ($file.Name -ine $expectedName) { throw "Nombre de parte inesperado: $($file.Name). Se esperaba $expectedName." }
        $parts[$number] = $file
    }
    [pscustomobject]@{
        First = $first.FullName; Pattern = (Join-Path $first.DirectoryName ($first.BaseName + '*.swm'))
        Info = $info; Files = @(1..([int]$info.TotalParts) | ForEach-Object { $parts[$_] })
    }
}

function Invoke-AIOSwmDism {
    param([string[]]$Arguments)

    & dism.exe @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "DISM fallo en $($Arguments[0]) (codigo $LASTEXITCODE)."
    }
}

# Presentacion compartida: Write-Host no agrega datos al resultado de las funciones.
function Write-AIOConversionSection {
    param([string]$Title, [int]$Step = 0, [ConsoleColor]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('  ' + ('-' * 64)) -ForegroundColor DarkCyan
    if ($Step -gt 0) {
        Write-Host ('  [{0}/5] {1}' -f $Step, $Title) -ForegroundColor $Color
    } else {
        Write-Host ('  ' + $Title) -ForegroundColor $Color
    }
    Write-Host ('  ' + ('-' * 64)) -ForegroundColor DarkCyan
}

function Write-AIOConversionField {
    param([string]$Label, [string]$Value, [ConsoleColor]$Color = 'White')
    Write-Host ('  {0,-14} ' -f ($Label + ':')) -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $Color
}

# Verificacion de WinRE equivalente a Modulo-Actualizaciones: wimlib verify sin montaje.
# No usa Assert-AIOUpdateWinREIntegrity porque esta registra en el estado de sesion de Actualizaciones.
# Tambien comprueba aqui (antes de la captura) todas las dependencias de Modulo-Actualizaciones
# que se usaran despues, para no fallar al final de una captura larga.
function Assert-AIOConversionWinREIntegrity {
    param([Parameter(Mandatory = $true)] [string]$WinREPath)

    foreach ($nombre in 'Find-AIOUpdateWimlib', 'Invoke-AIOUpdateWimlibRead', 'Get-AIOUpdateWimFileSha256', 'ConvertTo-AIOUpdateNativeArgument') {
        if (-not (Get-Command $nombre -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Falta '$nombre' de Modulo-Actualizaciones.ps1; no se puede verificar WinRE."
        }
    }
    if (-not (Test-Path -LiteralPath $WinREPath -PathType Leaf)) {
        throw "No existe el archivo WinRE que se debe verificar: '$WinREPath'."
    }
    if (-not (Find-AIOUpdateWimlib)) {
        throw 'Se requiere wimlib-imagex.exe en Tools\wimlib o en PATH para verificar WinRE.'
    }

    Write-Host '  Verificando la integridad de winre.wim con wimlib (sin montaje)...' -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "ConvertVHD: wimlib-imagex verify '$WinREPath'."
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # Solo lectura; sin --nocheck para que se verifiquen todos los datos.
    $result = Invoke-AIOUpdateWimlibRead -Arguments @('verify', $WinREPath)
    $timer.Stop()
    foreach ($line in @($result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log -LogLevel INFO -Message "ConvertVHD wimlib verify: $line"
        }
    }
    if (-not $result.Success -or $result.ExitCode -ne 0) {
        $detail = (@($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | ')
        throw "wimlib verify fallo para '$WinREPath' (codigo $($result.ExitCode)). $detail"
    }
    Write-Log -LogLevel INFO -Message ("ConvertVHD: WinRE verificado con wimlib en {0:N2} s." -f $timer.Elapsed.TotalSeconds)
    Write-Host '  [VERIFICADO] Integridad de winre.wim correcta.' -ForegroundColor Green
}

# Incorpora winre.wim al WIM capturado sin montarlo (wimlib update, append en sitio).
# --include-integrity conserva la tabla de integridad sin verificar antes todo el WIM.
# --no-acls: el archivo hereda permisos del directorio destino, igual que con Copy-Item en el montaje.
function Add-AIOConversionWinREToWim {
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$WinREPath,
        [ValidateRange(1, 2147483647)] [int]$Index = 1
    )

    foreach ($nombre in 'Find-AIOUpdateWimlib', 'ConvertTo-AIOUpdateNativeArgument') {
        if (-not (Get-Command $nombre -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Falta '$nombre' de Modulo-Actualizaciones.ps1; no se puede incorporar WinRE."
        }
    }
    $wimlib = Find-AIOUpdateWimlib
    if (-not $wimlib) { throw 'Se requiere wimlib-imagex.exe en Tools\wimlib o en PATH para incorporar WinRE.' }
    if (-not (Test-Path -LiteralPath $WinREPath -PathType Leaf)) { throw "No existe el archivo WinRE: '$WinREPath'." }

    # wimupdate interpreta las comillas internas por si mismo; las rutas de Windows no pueden contener comillas dobles.
    $quote = if ($WinREPath.Contains("'")) { '"' } else { "'" }
    $command = "add $quote$WinREPath$quote '/Windows/System32/Recovery/winre.wim'"
    $arguments = @('update', $WimPath, [string]$Index, '--no-acls', '--include-integrity', "--command=$command")

    Write-Log -LogLevel INFO -Message "ConvertVHD: wimlib-imagex update (add WinRE) sobre '$WimPath'."
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $wimlib
    $start.Arguments = (@($arguments | ForEach-Object { ConvertTo-AIOUpdateNativeArgument -Argument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'No se pudo iniciar wimlib-imagex.' }
        # Drenar stderr en paralelo evita bloquear la tuberia de salida.
        $errorsTask = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $stderr = $errorsTask.GetAwaiter().GetResult()
        $lines = @(($stdout + "`n" + $stderr) -split "[\r\n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($line in $lines) { Write-Log -LogLevel INFO -Message "ConvertVHD wimlib update: $line" }
        if ($process.ExitCode -ne 0) {
            $detail = (@($lines | Select-Object -Last 8) -join ' | ')
            throw "wimlib update fallo al incorporar WinRE (codigo $($process.ExitCode)). $detail"
        }
        Write-Log -LogLevel INFO -Message ("ConvertVHD: WinRE incorporado con wimlib en {0:N2} s." -f $timer.Elapsed.TotalSeconds)
    }
    finally {
        $timer.Stop()
        if (-not $process.HasExited) { try { $process.Kill(); [void]$process.WaitForExit(5000) } catch {} }
        $process.Dispose()
    }
}

function Format-AIOConversionSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

function Read-AIOConversionIndices {
    param([object[]]$Images)
    Write-Host ''
    Write-Host ('  {0,-9} {1}' -f 'INDICE', 'EDICION') -ForegroundColor Gray
    foreach ($image in $Images) {
        Write-Host ('  {0,-9} {1}' -f ('[' + $image.ImageIndex + ']'), $image.ImageName) -ForegroundColor White
    }
    Write-Host ''
    Write-Host '  T = Todas    1,3 = Seleccion multiple    0 = Cancelar' -ForegroundColor Yellow
    $available = @($Images | ForEach-Object { [int]$_.ImageIndex })
    while ($true) {
		Write-Host ""
        $answer = ([string](Read-Host '  Indices a convertir')).Trim()
        if ($answer -eq '0') { return }
        if ($answer -match '^(T|TODO|TODOS|ALL|\*)$') { return $available }
        if ($answer -notmatch '^\d+(\s*,\s*\d+)*$') { Write-Warning 'Seleccion no valida.'; continue }
        $chosen = New-Object 'System.Collections.Generic.List[int]'
        $valid = $true
        foreach ($token in ($answer -split ',')) {
            $index = 0
            if (-not [int]::TryParse($token.Trim(), [ref]$index) -or $available -notcontains $index) { $valid = $false; break }
            if (-not $chosen.Contains($index)) { $chosen.Add($index) }
        }
        if ($valid) { return $chosen.ToArray() }
        Write-Warning 'Uno o varios indices no estan disponibles.'
    }
}

function Export-AIOConversionIndices {
    param([string]$Source, [string]$Destination, [int[]]$Indices, [string]$Compression,
        [string]$SwmPattern, [int]$BootIndex, [string]$Scratch)
    $position = 0
    foreach ($index in $Indices) {
        $position++
        Write-Host ''
        Write-Host ('  Exportando imagen {0} de {1} | Indice de origen: {2}' -f $position, $Indices.Count, $index) -ForegroundColor Cyan
        $argsDism = @('/Export-Image', "/SourceImageFile:$Source", "/SourceIndex:$index",
            "/DestinationImageFile:$Destination", '/CheckIntegrity', "/ScratchDir:$Scratch")
        if (-not (Test-Path -LiteralPath $Destination)) { $argsDism += "/Compress:$Compression" }
        if ($SwmPattern) { $argsDism += "/SWMFile:$SwmPattern" }
        if ($BootIndex -gt 0 -and $index -eq $BootIndex) { $argsDism += '/Bootable' }
        Invoke-AIOSwmDism -Arguments $argsDism
    }
}

function Assert-AIOConversionImages {
    param([string]$Path, [object[]]$Expected, [int]$BootIndex)
    $actual = @(Get-WindowsImage -ImagePath $Path -ErrorAction Stop)
    if ($actual.Count -ne $Expected.Count) { throw 'La salida no contiene todos los indices seleccionados.' }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($actual[$i].ImageIndex -ne ($i + 1) -or $actual[$i].ImageName -cne $Expected[$i].ImageName) {
            throw 'El orden o los nombres de las imagenes de salida no coinciden.'
        }
    }
    $info = Get-AIOWimContainerInfo -Path $Path
    if ($info.BootIndex -ne $BootIndex) { throw 'El indice de arranque de la salida no coincide con el esperado.' }
}

function Publish-AIOConversionFiles {
    param([object[]]$Files, [string]$DestinationDirectory, [string]$Journal, [string]$FirstSwmName)
    $entries = @($Files | ForEach-Object {
        [pscustomobject]@{ Source = $_.FullName; Destination = (Join-Path $DestinationDirectory $_.Name)
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
    })
    foreach ($entry in $entries) {
        if (Test-Path -LiteralPath $entry.Destination) { throw "El destino ya existe: $($entry.Destination). No se sobrescribira." }
    }
    $entries | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Journal -Encoding UTF8 -ErrorAction Stop
    $moved = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($entry in $entries) {
            # Trabajo y destino en el mismo volumen; Move nunca sobrescribe.
            [IO.File]::Move($entry.Source, $entry.Destination)
            $moved.Add($entry)
            if ((Get-FileHash -LiteralPath $entry.Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry.Hash) {
                throw "Fallo de verificacion de $($entry.Destination)."
            }
        }
        if ($FirstSwmName) { Get-AIOSwmSet -FirstPart (Join-Path $DestinationDirectory $FirstSwmName) | Out-Null }
    } catch {
        $failure = $_.Exception.Message
        foreach ($entry in $moved) {
            try {
                if ((Get-FileHash -LiteralPath $entry.Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry.Hash) {
                    throw 'El archivo cambio; se conserva para revision.'
                }
                [IO.File]::Move($entry.Destination, $entry.Source)
            } catch { Write-Warning "Salida parcial pendiente: $($entry.Destination). $($_.Exception.Message)" }
        }
        throw "Publicacion incompleta: $failure. Consulta $Journal."
    }
}

function Convert-ImageFormat {
    param([ValidateSet('ToSWM', 'ToWIM', 'ToESD', 'WIMToESD', 'ESDToWIM')][string]$Mode = 'ToSWM')
    Clear-Host
    $title = switch ($Mode) { 'ToSWM' { 'WIM/ESD a SWM' }; 'ToWIM' { 'SWM a WIM' }; 'ToESD' { 'SWM a ESD' }; 'WIMToESD' { 'WIM a ESD' }; 'ESDToWIM' { 'ESD a WIM' } }
    $description = switch ($Mode) {
        'ToSWM'    { 'Divide una imagen en partes del tamano que elijas.' }
        'ToWIM'    { 'Reune un conjunto SWM y genera un archivo WIM.' }
        'ToESD'    { 'Reune un conjunto SWM y genera un archivo ESD.' }
        'WIMToESD' { 'Exporta las ediciones seleccionadas con compresion ESD.' }
        'ESDToWIM' { 'Exporta las ediciones seleccionadas a un nuevo WIM.' }
    }
    Write-AIOConversionSection -Title 'CONVERSION DE IMAGENES'
    Write-Host ('  ' + $title) -ForegroundColor White
    Write-Host ('  ' + $description) -ForegroundColor Gray
    $timer = $null
    $workRoot = $null
    $scratch = $null
    $success = $false
    try {
        Write-AIOConversionSection -Title 'IMAGEN DE ORIGEN' -Step 1
        Write-Host '  Selecciona el archivo en la ventana de exploracion.' -ForegroundColor Gray
        $filter = switch ($Mode) { 'ToSWM' { 'Imagenes WIM/ESD|*.wim;*.esd' }; 'WIMToESD' { 'Imagen WIM|*.wim' }; 'ESDToWIM' { 'Imagen ESD|*.esd' }; default { 'Primera parte SWM|*.swm' } }
        $sourceTitle = switch ($Mode) { 'WIMToESD' { 'Selecciona el WIM que se convertira a ESD' }; 'ESDToWIM' { 'Selecciona el ESD que se convertira a WIM' }; default { 'Selecciona la imagen de origen (SWM: primera parte)' } }
        $source = Select-PathDialog -DialogType File -Title $sourceTitle -Filter $filter
        if (-not $source) { Write-Host '  Operacion cancelada.' -ForegroundColor Yellow; return }
        $source = [IO.Path]::GetFullPath($source)
        $sourceFile = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        $swmPattern = $null
        if ($Mode -in @('ToSWM', 'WIMToESD', 'ESDToWIM')) {
            if ($Mode -eq 'WIMToESD' -and $sourceFile.Extension -ine '.wim') { throw 'El origen debe ser un archivo WIM.' }
            if ($Mode -eq 'ESDToWIM' -and $sourceFile.Extension -ine '.esd') { throw 'El origen debe ser un archivo ESD.' }
            if ($sourceFile.Extension -notin @('.wim', '.esd')) { throw 'El origen debe ser WIM o ESD.' }
            $sourceInfo = Get-AIOWimContainerInfo -Path $source
            if ($sourceInfo.TotalParts -ne 1) { throw 'El origen ya esta dividido. Selecciona un WIM/ESD completo.' }
        } else {
            $set = Get-AIOSwmSet -FirstPart $source
            $swmPattern = $set.Pattern
            $sourceInfo = $set.Info
            Write-AIOConversionField -Label 'Conjunto SWM' -Value ("{0} partes verificadas" -f $set.Files.Count) -Color Green
        }
        Write-AIOConversionField -Label 'Archivo' -Value $source
        Write-AIOConversionField -Label 'Formato' -Value $sourceFile.Extension.TrimStart('.').ToUpperInvariant()
        $images = @(Get-WindowsImage -ImagePath $source -ErrorAction Stop)
        if ($images.Count -eq 0) { throw 'No se encontraron indices de imagen.' }
        Write-AIOConversionField -Label 'Ediciones' -Value ([string]$images.Count)
        Write-AIOConversionSection -Title 'EDICIONES A CONVERTIR' -Step 2
        $indices = @(Read-AIOConversionIndices -Images $images)
        if ($indices.Count -eq 0) { Write-Host '  Operacion cancelada.' -ForegroundColor Yellow; return }
        $expected = @($indices | ForEach-Object { $n = $_; $images | Where-Object ImageIndex -eq $n })
        $expectedBoot = 0
        for ($i = 0; $i -lt $indices.Count; $i++) {
            if ($indices[$i] -eq $sourceInfo.BootIndex) { $expectedBoot = $i + 1 }
        }
        Write-AIOConversionSection -Title 'DESTINO Y OPCIONES' -Step 3
        $extension = switch ($Mode) { 'ToSWM' { '.swm' }; 'ToWIM' { '.wim' }; 'ToESD' { '.esd' }; 'WIMToESD' { '.esd' }; 'ESDToWIM' { '.wim' } }
        $defaultPath = Join-Path $sourceFile.DirectoryName ($sourceFile.BaseName + $extension)
        $destination = Select-SavePathDialog -Title 'Guardar conversion (elige un nombre nuevo)' -Filter "Imagen $extension|*$extension" -DefaultFileName $defaultPath
        if (-not $destination) { Write-Host '  Operacion cancelada.' -ForegroundColor Yellow; return }
        $destination = [IO.Path]::GetFullPath($destination)
        if ([IO.Path]::GetExtension($destination) -ine $extension) { throw "El destino debe terminar en $extension." }
        $destinationDirectory = Split-Path -Path $destination -Parent
        $baseName = [IO.Path]::GetFileNameWithoutExtension($destination)
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { throw 'La carpeta de destino no existe.' }
        if (Test-Path -LiteralPath $destination) { throw 'El destino ya existe. Elige otro nombre para conservarlo.' }
        Write-AIOConversionField -Label 'Destino' -Value $destination
        $sizeMB = 3800
        if ($Mode -eq 'ToSWM') {
            $conflicts = @(Get-ChildItem -LiteralPath $destinationDirectory -File -Force | Where-Object {
                $_.Extension -ieq '.swm' -and $_.BaseName.StartsWith($baseName, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($conflicts.Count) { throw 'Ya hay partes SWM con ese nombre/prefijo. Elige otra carpeta o nombre.' }
            do {
                $answer = ([string](Read-Host '  Tamano por parte en MB [Enter=3800; 0=cancelar]')).Trim()
                if ($answer -eq '0') { Write-Host '  Operacion cancelada.' -ForegroundColor Yellow; return }
                if ($answer -eq '') { $sizeMB = 3800; break }
            } until ([int]::TryParse($answer, [ref]$sizeMB) -and $sizeMB -ge 1 -and $sizeMB -le 32768)
            Write-Host '  Un archivo indivisible puede superar el tamano elegido.' -ForegroundColor Gray
            if ($sizeMB -le 4095) { Write-Host '  Se comprobara el limite de 4 GB por archivo para FAT32.' -ForegroundColor Gray }
        }
        $allInOrder = ($indices.Count -eq $images.Count -and ($indices -join ',') -eq (($images | ForEach-Object ImageIndex) -join ','))
        $useIntermediateWim = ($Mode -eq 'ToSWM' -and ($sourceFile.Extension -ieq '.esd' -or -not $allInOrder -or $sourceInfo.CompressionType -eq 3))
        $compressionLabel = if ($Mode -in @('ToESD', 'WIMToESD')) {
            'RECOVERY (ESD)'
        } elseif ($Mode -eq 'ToSWM' -and -not $useIntermediateWim) {
            switch ([int]$sourceInfo.CompressionType) {
                0 { 'Sin compresion (heredada del WIM)' }
                1 { 'FAST (heredada del WIM)' }
                2 { 'MAX (heredada del WIM)' }
                default { 'Se conserva la compresion del WIM' }
            }
        } else { 'MAX (WIM)' }
        Write-Host ''
        Write-AIOConversionField -Label 'Seleccion' -Value (([string]$indices.Count) + ' edicion(es): ' + ($indices -join ', '))
        Write-AIOConversionField -Label 'Compresion' -Value $compressionLabel
        if ($Mode -eq 'ToSWM') { Write-AIOConversionField -Label 'Tamano/parte' -Value ("{0} MB (objetivo)" -f $sizeMB) }
        Write-AIOConversionSection -Title 'CONVERSION EN CURSO' -Step 4
        Write-Host '  El porcentaje inferior corresponde a la operacion de DISM.' -ForegroundColor Gray
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $workRoot = Join-Path $destinationDirectory ('AIOConversion_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $workRoot -ItemType Directory -ErrorAction Stop | Out-Null
        $stage = Join-Path $workRoot 'Salida'
        New-Item -Path $stage -ItemType Directory -ErrorAction Stop | Out-Null
        $scratch = Join-Path $Script:Scratch_DIR ('SWM_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $scratch -ItemType Directory -ErrorAction Stop | Out-Null
        Write-Log -LogLevel INFO -Message "ConvertSWM: $Mode; origen=$source; destino=$destination; indices=$($indices -join ','); trabajo=$workRoot"
        $stagedOutput = Join-Path $stage ([IO.Path]::GetFileName($destination))
        if ($Mode -eq 'ToSWM') {
            # Split-Image acepta WIM no solido. ESD y selecciones parciales pasan por un WIM temporal.
            $splitSource = $source
            if ($useIntermediateWim) {
                Write-Host '  Preparando el WIM intermedio para generar las partes SWM...' -ForegroundColor Yellow
                # El intermedio puede superar 4 GB: usar Scratch, no el USB FAT32 de salida.
                $splitSource = Join-Path $scratch 'intermedio.wim'
                Export-AIOConversionIndices -Source $source -Destination $splitSource -Indices $indices -Compression max -BootIndex $sourceInfo.BootIndex -Scratch $scratch
                Assert-AIOConversionImages -Path $splitSource -Expected $expected -BootIndex $expectedBoot
            }
            Write-Host ''
            Write-Host '  Dividiendo la imagen en archivos SWM...' -ForegroundColor Cyan
            Invoke-AIOSwmDism -Arguments @('/Split-Image', "/ImageFile:$splitSource", "/SWMFile:$stagedOutput", "/FileSize:$sizeMB", '/CheckIntegrity', "/ScratchDir:$scratch")
            Write-AIOConversionSection -Title 'VERIFICACION Y GUARDADO' -Step 5
            Write-Host '  Comprobando las partes, ediciones y archivo de salida...' -ForegroundColor Gray
            $resultSet = Get-AIOSwmSet -FirstPart $stagedOutput
            if ($sizeMB -le 4095 -and @($resultSet.Files | Where-Object Length -gt 4294967295).Count) {
                throw 'DISM genero una parte que supera el limite de FAT32 por un recurso indivisible. No se publicara el conjunto como compatible con FAT32.'
            }
            Assert-AIOConversionImages -Path $stagedOutput -Expected $expected -BootIndex $expectedBoot
            $filesToPublish = $resultSet.Files
        } else {
            $compression = if ($Mode -in @('ToESD', 'WIMToESD')) { 'recovery' } else { 'max' }
            Export-AIOConversionIndices -Source $source -Destination $stagedOutput -Indices $indices -Compression $compression -SwmPattern $swmPattern -BootIndex $sourceInfo.BootIndex -Scratch $scratch
            Write-AIOConversionSection -Title 'VERIFICACION Y GUARDADO' -Step 5
            Write-Host '  Comprobando las ediciones y el archivo de salida...' -ForegroundColor Gray
            Assert-AIOConversionImages -Path $stagedOutput -Expected $expected -BootIndex $expectedBoot
            $filesToPublish = @(Get-Item -LiteralPath $stagedOutput -ErrorAction Stop)
        }
        $firstSwmName = if ($Mode -eq 'ToSWM') { [IO.Path]::GetFileName($destination) } else { $null }
        $outputDetails = @($filesToPublish | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Length = $_.Length } })
        Write-Host '  Guardando el resultado y verificando su integridad...' -ForegroundColor Gray
        Publish-AIOConversionFiles -Files $filesToPublish -DestinationDirectory $destinationDirectory -Journal (Join-Path $workRoot 'publicacion.json') -FirstSwmName $firstSwmName
        $success = $true
        $timer.Stop()
        Write-AIOConversionSection -Title 'CONVERSION COMPLETADA' -Color Green
        Write-AIOConversionField -Label 'Destino' -Value $destination
        Write-AIOConversionField -Label 'Ediciones' -Value ([string]$indices.Count)
        Write-AIOConversionField -Label 'Archivos' -Value ([string]$filesToPublish.Count)
        Write-AIOConversionField -Label 'Tamano total' -Value (Format-AIOConversionSize -Bytes (($outputDetails | Measure-Object Length -Sum).Sum))
        Write-AIOConversionField -Label 'Tiempo' -Value $timer.Elapsed.ToString('hh\:mm\:ss')
        if ($Mode -eq 'ToSWM') {
            Write-Host ''
            foreach ($file in @($outputDetails | Select-Object -First 5)) {
                Write-Host ('    {0}  ({1})' -f $file.Name, (Format-AIOConversionSize -Bytes $file.Length)) -ForegroundColor White
            }
            if ($outputDetails.Count -gt 5) { Write-Host ('    ... y {0} archivos mas.' -f ($outputDetails.Count - 5)) -ForegroundColor Gray }
            Write-Host '  Conserva todas las partes juntas en la misma carpeta.' -ForegroundColor Yellow
        } elseif ($Script:IMAGE_MOUNTED -eq 0) { $Script:WIM_FILE_PATH = $destination }
        Write-Log -LogLevel INFO -Message "ConvertSWM: $Mode completado; $($filesToPublish.Count) archivo(s) verificados."
    } catch {
        Write-AIOConversionSection -Title 'NO SE COMPLETO LA CONVERSION' -Color Red
        Write-Host ('  Motivo: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "ConvertSWM: $($_.Exception.Message)"
    } finally {
        if ($timer -and $timer.IsRunning) { $timer.Stop() }
        if ($workRoot) {
            if ($success) {
                foreach ($folder in @($workRoot, $scratch)) {
                    if ($folder -and (Test-Path -LiteralPath $folder)) {
                        try { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop }
                        catch { Write-Warning "Temporal pendiente: $folder" }
                    }
                }
            } else {
                Write-Warning "Conversion incompleta; se conserva el trabajo en $workRoot"
                if ($scratch) { Write-Warning "Temporal de conversion: $scratch" }
            }
        }
    }
    Pause
}

# Reutiliza la seleccion, exportacion y publicacion verificadas del motor de conversion.
function Convert-WIMToESD {
    Convert-ImageFormat -Mode WIMToESD
}
