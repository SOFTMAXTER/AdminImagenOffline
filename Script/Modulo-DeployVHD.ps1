# =================================================================
#  Modulo-DeployVHD
#
#  CONTENIDO   : Show-Deploy-To-VHD-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log   : registro de eventos
#  CARGA       : . "$PSScriptRoot\Modulo-DeployVHD.ps1"
#
#  NOTA: Esta funcion NO requiere imagen montada ($Script:IMAGE_MOUNTED).
#  Opera directamente sobre imagenes WIM/ESD y conjuntos SWM y discos del
#  sistema host. Es autocontenida salvo por Write-Log.
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

# Lectura de cabeceras SWM en modo consulta; sin dependencia del modulo de conversion.
function Get-AIODeployWimContainerInfo {
    param([string]$Path)
    if (-not ('AIODeployWimContainerV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AIODeployWimContainerV1 {
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
    [AIODeployWimContainerV1]::Read([IO.Path]::GetFullPath($Path))
}

function Get-AIODeploySwmSet {
    param([string]$FirstPart)
    $first = Get-Item -LiteralPath $FirstPart -Force -ErrorAction Stop
    if ($first.Extension -ine '.swm') { throw 'Selecciona un archivo .swm.' }
    $info = Get-AIODeployWimContainerInfo -Path $first.FullName
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
        $part = Get-AIODeployWimContainerInfo -Path $file.FullName
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

function Format-AIODeployElapsedTime {
    param([TimeSpan]$Elapsed)
    # Horas acumuladas: no volver a 00 al superar un dia de despliegue.
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds)
}

function Assert-AIODeployNotCancelled {
    param([hashtable]$State)
    if ($State -and $State.CancelRequested) {
        throw [OperationCanceledException]::new('Despliegue cancelado por el usuario.')
    }
}

function Remove-AIODeployPartialVhd {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $vhd = Get-VHD -Path $Path -ErrorAction Stop
    if ($vhd.Attached) {
        Dismount-VHD -Path $Path -ErrorAction Stop
        $vhd = Get-VHD -Path $Path -ErrorAction Stop
    }
    if ($vhd.Attached) { throw "El VHD sigue montado; se conserva el archivo: $Path" }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Show-Deploy-To-VHD-GUI {

    # ------------------------------------------------------------------
    # 1. Verificacion de requisitos del modulo Storage
    # ------------------------------------------------------------------
    if (-not (Get-Command "Initialize-Disk" -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Este modulo requiere el modulo Storage de PowerShell.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:isDeploying = $false
    $deployState = @{ CancelRequested = $false }
    $CheckDeployCancellation = {
        # Atender el boton solo entre operaciones, nunca desmontar mientras
        # Storage, DISM o BCDBOOT sigan escribiendo en el destino.
        [System.Windows.Forms.Application]::DoEvents()
        Assert-AIODeployNotCancelled $deployState
    }

    # Los lectores nativos drenan ambos canales en segundo plano. Solo el hilo
    # de WinForms actualiza los controles; no se ejecutan scriptblocks en esos hilos.
    if (-not ('AIODeployNativeReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

public sealed class AIODeployNativeReader : IDisposable {
    private readonly Process process;
    public readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<string> Error = new ConcurrentQueue<string>();

    public AIODeployNativeReader(string fileName, string arguments) {
        process = new Process();
        process.StartInfo = new ProcessStartInfo {
            FileName = fileName, Arguments = arguments,
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        process.OutputDataReceived += (sender, args) => {
            if (args.Data != null) Output.Enqueue(args.Data);
        };
        process.ErrorDataReceived += (sender, args) => {
            if (args.Data != null) Error.Enqueue(args.Data);
        };
    }

    public void Start() {
        if (!process.Start()) throw new InvalidOperationException("No se pudo iniciar el proceso.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }
    public bool HasExited { get { return process.HasExited; } }
    public int ExitCode { get { return process.ExitCode; } }
    public void WaitForExit() { process.WaitForExit(); }
    public void Dispose() { process.Dispose(); }
}
'@
    }

    function Invoke-AIODeployNativeProcess {
        param([string]$FileName, [string]$Arguments, [scriptblock]$OnPercent)

        & $CheckDeployCancellation
        $reader = New-Object AIODeployNativeReader($FileName, $Arguments)
        $started = $false
        $lastPercent = -1.0
        $tail = New-Object System.Collections.Generic.List[string]
        try {
            $reader.Start()
            $started = $true
            do {
                $exited = $reader.HasExited
                # WaitForExit sin timeout tambien termina las entregas asincronas.
                if ($exited) { $reader.WaitForExit() }
                $line = $null
                while ($reader.Output.TryDequeue([ref]$line)) {
                    if ($OnPercent) {
                        foreach ($match in [regex]::Matches($line, '(?<![\d.,])(?<percent>\d{1,3}(?:[.,]\d+)?)\s*%')) {
                            $percent = [double]::Parse($match.Groups['percent'].Value.Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
                            if ($percent -ge 0 -and $percent -le 100 -and $percent -gt $lastPercent) {
                                $lastPercent = $percent
                                & $OnPercent $percent
                            }
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        [void]$tail.Add($line)
                        if ($tail.Count -gt 20) { $tail.RemoveAt(0) }
                    }
                }
                while ($reader.Error.TryDequeue([ref]$line)) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        [void]$tail.Add($line)
                        if ($tail.Count -gt 20) { $tail.RemoveAt(0) }
                    }
                }
                [System.Windows.Forms.Application]::DoEvents()
                if (-not $exited) { Start-Sleep -Milliseconds 100 }
            } while (-not $exited)

            $exitCode = [int]$reader.ExitCode
            if ($exitCode -ne 0 -and $tail.Count -gt 0) {
                Write-Log -LogLevel ERROR -Message ("DEPLOY: {0} devolvio {1}: {2}" -f $FileName, $exitCode, ($tail -join ' | '))
            }
            # Cancelacion cooperativa: esperar la salida real del proceso antes
            # de lanzar la excepcion que inicia la limpieza del destino.
            & $CheckDeployCancellation
            return $exitCode
        } finally {
            # Nunca entregar el control a la limpieza mientras DISM siga escribiendo.
            if ($started) { $reader.WaitForExit() }
            $reader.Dispose()
        }
    }

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Despliegue WIM/ESD/SWM a VHD/VHDX o Disco Fisico"
    $form.Size            = New-Object System.Drawing.Size(720, 680)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # --- Grupo 1: Imagen de Origen ---
    $grpSource           = New-Object System.Windows.Forms.GroupBox
    $grpSource.Text      = " 1. Imagen de Origen (WIM / ESD / SWM) "
    $grpSource.Location  = New-Object System.Drawing.Point(20, 15)
    $grpSource.Size      = New-Object System.Drawing.Size(660, 120)
    $grpSource.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpSource)

    $txtWim           = New-Object System.Windows.Forms.TextBox
    $txtWim.Location  = "20, 25"
    $txtWim.Size      = "540, 23"
    $txtWim.ReadOnly  = $true
    $txtWim.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtWim.ForeColor = [System.Drawing.Color]::White
    $grpSource.Controls.Add($txtWim)

    $btnBrowseWim           = New-Object System.Windows.Forms.Button
    $btnBrowseWim.Text      = "..."
    $btnBrowseWim.Location  = "570, 24"
    $btnBrowseWim.Size      = "70, 25"
    $btnBrowseWim.BackColor = [System.Drawing.Color]::Silver
    $btnBrowseWim.FlatStyle = "Flat"
    $grpSource.Controls.Add($btnBrowseWim)

    $lblIdx           = New-Object System.Windows.Forms.Label
    $lblIdx.Text      = "Indice:"
    $lblIdx.Location  = "20, 60"
    $lblIdx.AutoSize  = $true
    $lblIdx.ForeColor = [System.Drawing.Color]::Silver
    $grpSource.Controls.Add($lblIdx)

    $cmbIndex               = New-Object System.Windows.Forms.ComboBox
    $cmbIndex.Location      = "20, 80"
    $cmbIndex.Size          = "620, 25"
    $cmbIndex.DropDownStyle = "DropDownList"
    $cmbIndex.BackColor     = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cmbIndex.ForeColor     = [System.Drawing.Color]::White
    $grpSource.Controls.Add($cmbIndex)

    # --- Grupo 2: Tipo de Destino ---
    $grpTargetMode           = New-Object System.Windows.Forms.GroupBox
    $grpTargetMode.Text      = " 2. Tipo de Destino "
    $grpTargetMode.Location  = "20, 140"
    $grpTargetMode.Size      = "660, 55"
    $grpTargetMode.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($grpTargetMode)

    $radVhd           = New-Object System.Windows.Forms.RadioButton
    $radVhd.Text      = "Disco Virtual (VHD / VHDX)"
    $radVhd.Location  = "20, 22"
    $radVhd.AutoSize  = $true
    $radVhd.Checked   = $true
    $radVhd.ForeColor = [System.Drawing.Color]::White
    $grpTargetMode.Controls.Add($radVhd)

    $radPhysical           = New-Object System.Windows.Forms.RadioButton
    $radPhysical.Text      = "Disco Fisico (USB / Pendrive / HDD Externo)"
    $radPhysical.Location  = "250, 22"
    $radPhysical.AutoSize  = $true
    $radPhysical.ForeColor = [System.Drawing.Color]::White
    $grpTargetMode.Controls.Add($radPhysical)

    # --- Grupo 3: Configuracion de Disco y Particiones ---
    $grpDest           = New-Object System.Windows.Forms.GroupBox
    $grpDest.Text      = " 3. Configuracion de Disco y Particiones "
    $grpDest.Location  = "20, 205"
    $grpDest.Size      = "660, 220"
    $grpDest.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpDest)

    # Controles VHD
    $lblVhdPath           = New-Object System.Windows.Forms.Label
    $lblVhdPath.Text      = "Ruta VHDX:"
    $lblVhdPath.Location  = "20, 25"
    $lblVhdPath.AutoSize  = $true
    $lblVhdPath.ForeColor = [System.Drawing.Color]::Silver
    $grpDest.Controls.Add($lblVhdPath)

    $txtVhd           = New-Object System.Windows.Forms.TextBox
    $txtVhd.Location  = "20, 45"
    $txtVhd.Size      = "540, 23"
    $txtVhd.ReadOnly  = $true
    $txtVhd.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtVhd.ForeColor = [System.Drawing.Color]::White
    $grpDest.Controls.Add($txtVhd)

    $btnBrowseVhd           = New-Object System.Windows.Forms.Button
    $btnBrowseVhd.Text      = "Guardar"
    $btnBrowseVhd.Location  = "570, 44"
    $btnBrowseVhd.Size      = "70, 25"
    $btnBrowseVhd.BackColor = [System.Drawing.Color]::Silver
    $btnBrowseVhd.FlatStyle = "Flat"
    $grpDest.Controls.Add($btnBrowseVhd)

    $lblSize          = New-Object System.Windows.Forms.Label
    $lblSize.Text     = "Size Total (GB):"
    $lblSize.Location = "20, 85"
    $lblSize.AutoSize = $true
    $grpDest.Controls.Add($lblSize)

    $numSize          = New-Object System.Windows.Forms.NumericUpDown
    $numSize.Location = "140, 83"
    $numSize.Size     = "80, 25"
    $numSize.Minimum  = 40
    $numSize.Maximum  = 10000
    $numSize.Value    = 64
    $grpDest.Controls.Add($numSize)

    $chkDynamic          = New-Object System.Windows.Forms.CheckBox
    $chkDynamic.Text     = "Expansion Dinamica"
    $chkDynamic.Location = "250, 85"
    $chkDynamic.AutoSize = $true
    $chkDynamic.Checked  = $true
    $grpDest.Controls.Add($chkDynamic)

    # Controles Disco Fisico (ocultos por defecto)
    $lblPhysicalDisk           = New-Object System.Windows.Forms.Label
    $lblPhysicalDisk.Text      = "Seleccione el Disco Fisico Destino:"
    $lblPhysicalDisk.Location  = "20, 25"
    $lblPhysicalDisk.AutoSize  = $true
    $lblPhysicalDisk.ForeColor = [System.Drawing.Color]::Silver
    $lblPhysicalDisk.Visible   = $false
    $grpDest.Controls.Add($lblPhysicalDisk)

    $cmbDisks               = New-Object System.Windows.Forms.ComboBox
    $cmbDisks.Location      = "20, 45"
    $cmbDisks.Size          = "450, 25"
    $cmbDisks.DropDownStyle = "DropDownList"
    $cmbDisks.BackColor     = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cmbDisks.ForeColor     = [System.Drawing.Color]::White
    $cmbDisks.Visible       = $false
    $grpDest.Controls.Add($cmbDisks)

    $btnRefreshDisks           = New-Object System.Windows.Forms.Button
    $btnRefreshDisks.Text      = "Actualizar Lista"
    $btnRefreshDisks.Location  = "480, 44"
    $btnRefreshDisks.Size      = "160, 25"
    $btnRefreshDisks.BackColor = [System.Drawing.Color]::DodgerBlue
    $btnRefreshDisks.FlatStyle = "Flat"
    $btnRefreshDisks.Visible   = $false
    $grpDest.Controls.Add($btnRefreshDisks)

    # Controles comunes — tamaños de particiones
    $chkUEFI           = New-Object System.Windows.Forms.CheckBox
    $chkUEFI.Text      = "Esquema GPT (UEFI)"
    $chkUEFI.Location  = "420, 85"
    $chkUEFI.AutoSize  = $true
    $chkUEFI.Checked   = $true
    $chkUEFI.ForeColor = [System.Drawing.Color]::LightGreen
    $grpDest.Controls.Add($chkUEFI)

    $lblPartInfo           = New-Object System.Windows.Forms.Label
    $lblPartInfo.Text      = "--- Size de Particiones de Sistema ---"
    $lblPartInfo.Location  = "20, 125"
    $lblPartInfo.AutoSize  = $true
    $lblPartInfo.ForeColor = [System.Drawing.Color]::Silver
    $grpDest.Controls.Add($lblPartInfo)

    $lblEfiSize          = New-Object System.Windows.Forms.Label
    $lblEfiSize.Text     = "EFI (MB):"
    $lblEfiSize.Location = "20, 155"
    $lblEfiSize.AutoSize = $true
    $grpDest.Controls.Add($lblEfiSize)

    $numEfiSize          = New-Object System.Windows.Forms.NumericUpDown
    $numEfiSize.Location = "140, 153"
    $numEfiSize.Size     = "80, 25"
    $numEfiSize.Minimum  = 100
    $numEfiSize.Maximum  = 2000
    $numEfiSize.Value    = 260
    $grpDest.Controls.Add($numEfiSize)

    $lblMsrSize          = New-Object System.Windows.Forms.Label
    $lblMsrSize.Text     = "MSR (MB):"
    $lblMsrSize.Location = "250, 155"
    $lblMsrSize.AutoSize = $true
    $grpDest.Controls.Add($lblMsrSize)

    $numMsrSize          = New-Object System.Windows.Forms.NumericUpDown
    $numMsrSize.Location = "330, 153"
    $numMsrSize.Size     = "80, 25"
    $numMsrSize.Minimum  = 0
    $numMsrSize.Maximum  = 500
    $numMsrSize.Value    = 16
    $grpDest.Controls.Add($numMsrSize)

    $lblRecSize           = New-Object System.Windows.Forms.Label
    $lblRecSize.Text      = "Recovery (MB):"
    $lblRecSize.Location  = "430, 155"
    $lblRecSize.AutoSize  = $true
    $lblRecSize.ForeColor = [System.Drawing.Color]::White
    $grpDest.Controls.Add($lblRecSize)

    $numRecSize          = New-Object System.Windows.Forms.NumericUpDown
    $numRecSize.Location = "520, 153"
    $numRecSize.Size     = "80, 25"
    $numRecSize.Minimum  = 0
    $numRecSize.Maximum  = 5000
    $numRecSize.Value    = 1024
    $grpDest.Controls.Add($numRecSize)

    # Compact OS se aplica a Windows dentro del destino (VHD o disco fisico).
    $chkCompactOS           = New-Object System.Windows.Forms.CheckBox
    $chkCompactOS.Text      = "Compact OS (reducir espacio ocupado por Windows)"
    $chkCompactOS.Location  = "20, 187"
    $chkCompactOS.AutoSize  = $true
    $chkCompactOS.Checked   = $false
    $chkCompactOS.ForeColor = [System.Drawing.Color]::LightGreen
    $grpDest.Controls.Add($chkCompactOS)

    # Etiqueta de estado y boton principal
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Esperando configuracion..."
    $lblStatus.Location  = "20, 438"
    $lblStatus.Size      = "660, 36"
    $lblStatus.AutoSize  = $false
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    $btnDeploy           = New-Object System.Windows.Forms.Button
    $btnDeploy.Text      = "EJECUTAR DESPLIEGUE"
    $btnDeploy.Location  = "20, 586"
    $btnDeploy.Size      = "300, 40"
    $btnDeploy.BackColor = [System.Drawing.Color]::SeaGreen
    $btnDeploy.ForeColor = [System.Drawing.Color]::White
    $btnDeploy.FlatStyle = "Flat"
    $btnDeploy.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnDeploy)

    $btnCancel           = New-Object System.Windows.Forms.Button
    $btnCancel.Text      = "CANCELAR"
    $btnCancel.Location  = "500, 586"
    $btnCancel.Size      = "180, 40"
    $btnCancel.BackColor = [System.Drawing.Color]::Firebrick
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = "Flat"
    $btnCancel.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnCancel.Enabled   = $false
    $form.Controls.Add($btnCancel)

    $lblDeployProgress           = New-Object System.Windows.Forms.Label
    $lblDeployProgress.Text      = "Progreso general: 0% | Tiempo: 00:00:00"
    $lblDeployProgress.Location  = "20, 478"
    $lblDeployProgress.Size      = "660, 20"
    $lblDeployProgress.ForeColor = [System.Drawing.Color]::Silver
    $form.Controls.Add($lblDeployProgress)

    # La barra general representa etapas discretas. Un Panel evita la animacion
    # del ProgressBar nativo, que puede seguir avanzando durante la etapa siguiente.
    $progressDeploy          = New-Object System.Windows.Forms.Panel
    $progressDeploy.Location = "20, 502"
    $progressDeploy.Size     = "660, 18"
    $progressDeploy.BorderStyle = "FixedSingle"
    $progressDeploy.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $form.Controls.Add($progressDeploy)

    $progressDeployFill = New-Object System.Windows.Forms.Panel
    $progressDeployFill.Location = "0, 0"
    $progressDeployFill.Size = New-Object System.Drawing.Size(0, $progressDeploy.ClientSize.Height)
    $progressDeployFill.BackColor = [System.Drawing.Color]::LightGreen
    $progressDeploy.Controls.Add($progressDeployFill)

    $lblImageProgress           = New-Object System.Windows.Forms.Label
    $lblImageProgress.Text      = "Aplicacion de imagen: en espera."
    $lblImageProgress.Location  = "20, 530"
    $lblImageProgress.Size      = "660, 20"
    $lblImageProgress.ForeColor = [System.Drawing.Color]::Silver
    $form.Controls.Add($lblImageProgress)

    $progressImage          = New-Object System.Windows.Forms.ProgressBar
    $progressImage.Location = "20, 554"
    $progressImage.Size     = "660, 14"
    $progressImage.Style    = "Continuous"
    $progressImage.Minimum  = 0
    $progressImage.Maximum  = 1000
    $progressImage.Value    = 0
    $form.Controls.Add($progressImage)

    # Stopwatch conserva el tiempo real aunque Storage bloquee temporalmente
    # la GUI. El Timer solo refresca porcentaje y tiempo en el hilo WinForms.
    $deployWatch = New-Object System.Diagnostics.Stopwatch
    $deployProgress = @{ Completed = 0; Total = 6; Caption = 'Progreso general' }
    $RefreshDeployProgress = {
        $percent = [int][math]::Floor(100.0 * $deployProgress.Completed / $deployProgress.Total)
        $progressDeployFill.Width = [int][math]::Floor(
            $progressDeploy.ClientSize.Width * $deployProgress.Completed / $deployProgress.Total)
        $elapsedText = Format-AIODeployElapsedTime $deployWatch.Elapsed
        $lblDeployProgress.Text = "$($deployProgress.Caption): $($deployProgress.Completed) de $($deployProgress.Total) etapas ($percent%) | Tiempo: $elapsedText"
        $progressDeploy.Refresh()
        $lblDeployProgress.Refresh()
    }
    $deployTimer = New-Object System.Windows.Forms.Timer
    $deployTimer.Interval = 500
    $deployTimer.Add_Tick({ & $RefreshDeployProgress })
    $StopDeployTime = {
        $deployWatch.Stop()
        $deployTimer.Stop()
        & $RefreshDeployProgress
    }
    $CompleteDeployStage = {
        param([int]$Stage)
        # Solo se llama despues de terminar la etapa. El numero explicito impide
        # contabilizar dos veces una etapa o saltar una que no se haya completado.
        if ($Stage -ne ($deployProgress.Completed + 1) -or $Stage -gt $deployProgress.Total) {
            throw "Cierre de etapa fuera de orden: $Stage. Completadas: $($deployProgress.Completed)."
        }
        $deployProgress.Completed = $Stage
        & $RefreshDeployProgress
        $form.Refresh()
        & $CheckDeployCancellation
    }

    $ReportImagePercent = {
        param([double]$Percent)
        # DISM puede imprimir 100% antes de devolver un error final. Solo su salida
        # exitosa permite completar esta barra y contabilizar la etapa de imagen.
        $progressImage.Value = [int][math]::Floor([math]::Min(99.9, $Percent) * 10)
        if ($Percent -ge 100) {
            $lblImageProgress.Text = "Aplicacion de imagen: finalizando y comprobando resultado..."
        } else {
            $lblImageProgress.Text = "Aplicacion de imagen: $($Percent.ToString('0.#'))%."
        }
        $form.Refresh()
    }

    # ------------------------------------------------------------------
    # 3. Eventos de interfaz
    # ------------------------------------------------------------------

    # Alternar visibilidad de controles VHD / Disco Fisico
    $radVhd.Add_CheckedChanged({
        $isVhd = $radVhd.Checked
        $lblVhdPath.Visible    = $isVhd
        $txtVhd.Visible        = $isVhd
        $btnBrowseVhd.Visible  = $isVhd
        $lblSize.Visible       = $isVhd
        $numSize.Visible       = $isVhd
        $chkDynamic.Visible    = $isVhd
        $lblPhysicalDisk.Visible = -not $isVhd
        $cmbDisks.Visible        = -not $isVhd
        $btnRefreshDisks.Visible = -not $isVhd
    })

    # Ajustar etiqueta EFI y visibilidad MSR segun esquema
    $chkUEFI.Add_CheckedChanged({
        if ($chkUEFI.Checked) {
            $numEfiSize.Value      = 260
            $lblMsrSize.Visible    = $true
            $numMsrSize.Visible    = $true
            $lblEfiSize.Text       = "EFI (MB):"
        } else {
            $numEfiSize.Value      = 500
            $lblMsrSize.Visible    = $false
            $numMsrSize.Visible    = $false
            $lblEfiSize.Text       = "Sys. Rsvd (MB):"
        }
    })

    # Poblar lista de discos fisicos seguros (excluye sistema y boot)
    $PopulateDisks = {
        $cmbDisks.Items.Clear()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $sysDriveLetter = (Get-Item $env:SystemRoot).Root.Name.Replace("\", "")
            $sysPart = Get-Partition -DriveLetter $sysDriveLetter[0] -ErrorAction SilentlyContinue
            
            $sysDiskNum = -1
            if ($sysPart -and $sysPart.DiskNumber -ne $null) {
                $sysDiskNum = $sysPart.DiskNumber
            }

            # BLOQUEO EXTREMO: Solo permitimos buses extraíbles (USB, SD, 1394)
            # Esto ignora automáticamente cualquier disco SATA, NVMe, RAID o SAS interno.
            $safeDisks = Get-Disk | Where-Object {
                $_.IsSystem  -eq $false -and
                $_.IsBoot    -eq $false -and
                $_.IsOffline -eq $false -and
                $_.Number    -ne $sysDiskNum -and
                $_.BusType   -match '(?i)^(USB|SD|1394)$'
            }

            foreach ($d in $safeDisks) {
                $sizeGB = [math]::Round($d.Size / 1GB, 2)
                $cmbDisks.Items.Add("Disco $($d.Number) - $($d.FriendlyName) ($sizeGB GB) [$($d.BusType)]")
            }
        } catch {
            Write-Log -LogLevel ERROR -Message "Error enumerando discos fisicos: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }

        if ($cmbDisks.Items.Count -eq 0) {
            $cmbDisks.Items.Add("No se detectaron discos externos (USB).")
        }
        $cmbDisks.SelectedIndex = 0
    }

    $btnRefreshDisks.Add_Click($PopulateDisks)

    # Carga inicial: poblar la lista de discos
    $form.Add_Shown({ & $PopulateDisks })

    # SWM: seleccionar la primera parte y mantener el conjunto en una sola carpeta.
    $btnBrowseWim.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes WIM/ESD/SWM|*.wim;*.esd;*.swm|WIM (*.wim)|*.wim|ESD (*.esd)|*.esd|SWM (primera parte)|*.swm"
        $ofd.Title  = "Selecciona WIM, ESD o la primera parte SWM (ej. install.swm)"
        try {
            if ($ofd.ShowDialog() -ne 'OK') { return }
            $txtWim.Text = ''
            $cmbIndex.Items.Clear()
            $lblStatus.Text = "Leyendo imagen..."
            $form.Refresh()
            try {
                $swmSet = $null
                if ([IO.Path]::GetExtension($ofd.FileName) -ieq '.swm') {
                    $swmSet = Get-AIODeploySwmSet -FirstPart $ofd.FileName
                }
                $info = @(Get-WindowsImage -ImagePath $ofd.FileName -ErrorAction Stop)
                if ($info.Count -eq 0) { throw 'No se encontraron indices en la imagen.' }
                foreach ($img in $info) {
                    [void]$cmbIndex.Items.Add("[$($img.ImageIndex)] $($img.ImageName)")
                }
                $cmbIndex.SelectedIndex = 0
                $txtWim.Text = $ofd.FileName
                $lblStatus.Text = if ($swmSet) { "SWM cargado ($($swmSet.Files.Count) partes)." } else { "Imagen cargada." }
            } catch {
                $txtWim.Text = ''
                $cmbIndex.Items.Clear()
                $lblStatus.Text = "Error leyendo imagen."
                Write-Log -LogLevel ERROR -Message "DEPLOY: Origen no valido: $($_.Exception.Message)"
                [void][System.Windows.Forms.MessageBox]::Show(
                    "No se pudo cargar la imagen:`n`n$($_.Exception.Message)", "Imagen de origen", 'OK', 'Error')
            }
        } finally { $ofd.Dispose() }
    })

    # Guardar ruta del VHDX destino
    $btnBrowseVhd.Add_Click({
        $sfd        = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "VHDX (*.vhdx)|*.vhdx|VHD (*.vhd)|*.vhd"
        if ($sfd.ShowDialog() -eq 'OK') { $txtVhd.Text = $sfd.FileName }
    })

    # ------------------------------------------------------------------
    # 4. Motor de despliegue
    # ------------------------------------------------------------------
    $btnCancel.Add_Click({
        if (-not $script:isDeploying -or $deployState.CancelRequested) { return }
        $deployState.CancelRequested = $true
        $btnCancel.Text = 'CANCELANDO...'
        $btnCancel.Enabled = $false
        $deployProgress.Caption = 'Cancelando'
        $lblStatus.Text = 'Cancelacion solicitada. Esperando a que termine la operacion activa para limpiar el destino...'
        $lblStatus.ForeColor = [System.Drawing.Color]::Gold
        & $RefreshDeployProgress
        $form.Refresh()
    })

    $btnDeploy.Add_Click({
        if ($script:isDeploying) { return }

        # Validaciones previas
        if (-not $txtWim.Text) {
            [System.Windows.Forms.MessageBox]::Show("Falta la imagen origen.", "Error", 'OK', 'Error')
            return
        }

        # validacion estricta del ComboBox ANTES de tocar discos
        if ($cmbIndex.Items.Count -eq 0 -or $cmbIndex.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Selecciona un indice de imagen valido.", "Error", 'OK', 'Error')
            return
        }

        $isVhdMode  = $radVhd.Checked
        $vhdPath    = $txtVhd.Text
        $wimPath    = $txtWim.Text
        
        # --- FIX: Extraccion segura del indice real usando Regex ---
        # Busca un numero entre corchetes al inicio del texto seleccionado
        if ($cmbIndex.Text -match '^\[(\d+)\]') {
            $idx = [int]$Matches[1]
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "No se pudo determinar el indice exacto de la imagen seleccionada.`nEl formato esperado es '[Indice] Nombre'.", 
                "Error de Indice", 'OK', 'Error')
            return
        }

        # Revalidar SWM al pulsar Desplegar, ANTES de borrar/crear/formatear el destino.
        $swmPattern = $null
        $swmImage = $null
        if ([IO.Path]::GetExtension($wimPath) -ieq '.swm') {
            try {
                $swmSet = Get-AIODeploySwmSet -FirstPart $wimPath
                $wimPath = $swmSet.First
                $swmPattern = $swmSet.Pattern
                $swmImage = Get-WindowsImage -ImagePath $wimPath -Index $idx -ErrorAction Stop
                if (-not $swmImage -or $swmImage.ImageIndex -ne $idx) {
                    throw 'El indice seleccionado ya no esta disponible en el conjunto SWM.'
                }
                Write-Log -LogLevel INFO -Message "DEPLOY: SWM validado; $($swmSet.Files.Count) partes; indice $idx; origen=$wimPath"
            } catch {
                Write-Log -LogLevel ERROR -Message "DEPLOY: Conjunto SWM no valido: $($_.Exception.Message)"
                [void][System.Windows.Forms.MessageBox]::Show(
                    "No se puede desplegar el conjunto SWM:`n`n$($_.Exception.Message)", "Origen SWM", 'OK', 'Error')
                return
            }
        }

        # Leer una sola vez la opcion. El grupo queda bloqueado durante el trabajo.
        $useCompactOS = [bool]$chkCompactOS.Checked
        if ($useCompactOS) {
            # Comprobar la imagen ANTES de borrar un VHD o formatear un disco.
            try {
                $compactImage = if ($swmImage) { $swmImage } else { Get-WindowsImage -ImagePath $wimPath -Index $idx -ErrorAction Stop }
                $compactVersion = [version]$compactImage.Version
                if ($null -eq $compactVersion -or $compactVersion.Major -lt 10 -or
                    ([string]$compactImage.InstallationType).Trim() -ne 'Client') {
                    throw 'Compact OS requiere una imagen cliente de Windows 10/11. Desmarca la opcion para desplegar otra imagen.'
                }
            } catch {
                Write-Log -LogLevel ERROR -Message "DEPLOY: No se pudo validar Compact OS: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show(
                    "No se puede desplegar con Compact OS:`n`n$($_.Exception.Message)",
                    "Compact OS", 'OK', 'Error')
                return
            }
        }

        $isGPT      = $chkUEFI.Checked
        $sizeBootMB = [int]$numEfiSize.Value
        $sizeMsrMB  = [int]$numMsrSize.Value
        $sizeRecMB  = [int]$numRecSize.Value

        $diskNum             = $null
        $driveLetterSystem   = $null
        $driveLetterBoot     = $null
        $driveLetterRecovery = $null

        if ($isVhdMode) {
            if (-not $vhdPath) {
                [System.Windows.Forms.MessageBox]::Show("Ruta VHDX vacia.", "Error", 'OK', 'Error')
                return
            }
            if (Test-Path $vhdPath) {
                if ([System.Windows.Forms.MessageBox]::Show(
                        "El VHD existe. Se borrara todo su contenido.`nContinuar?",
                        "Confirmar", 'YesNo', 'Warning') -eq 'No') { return }
                try {
                    Remove-Item $vhdPath -Force -ErrorAction Stop
                } catch {
                    [System.Windows.Forms.MessageBox]::Show(
                        "No se pudo borrar el archivo. Esta en uso?", "Error", 'OK', 'Error')
                    return
                }
            }
        } else {
            if ($cmbDisks.Items.Count -eq 0 -or $cmbDisks.Text -match "No se detectaron") {
                [System.Windows.Forms.MessageBox]::Show(
                    "Seleccione un disco fisico valido.", "Error", 'OK', 'Error')
                return
            }
            if ($cmbDisks.Text -match "^Disco (\d+)") {
                $diskNum = [int]$Matches[1]
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "No se pudo determinar el numero de disco de forma segura. Seleccione un disco valido.",
                    "Error Critico", 'OK', 'Error')
                return
            }
            $msg = "¡ADVERTENCIA EXTREMA!`n`nEl Disco Fisico $diskNum sera FORMATEADO Y BORRADO COMPLETAMENTE.`nTodos los datos y particiones actuales se perderan de forma irreversible.`n`n¿Esta ABSOLUTAMENTE SEGURO de continuar?"
            if ([System.Windows.Forms.MessageBox]::Show($msg, "Destruccion de Datos", 'YesNo', 'Warning') -eq 'No') { return }
        }

        $deployState.CancelRequested = $false
        $vhdCreationStarted   = $false
        $script:isDeploying   = $true
        $btnDeploy.Enabled    = $false
        $btnCancel.Text       = 'CANCELAR'
        $btnCancel.Enabled    = $true
        $grpSource.Enabled    = $false
        $grpTargetMode.Enabled = $false
        $grpDest.Enabled      = $false
        $form.Cursor          = [System.Windows.Forms.Cursors]::WaitCursor

        $deployProgress.Completed = 0
        $deployProgress.Total = if ($isVhdMode) { 6 } else { 5 }
        $deployProgress.Caption = 'Progreso general'
        $deployWatch.Reset()
        $lblDeployProgress.ForeColor = [System.Drawing.Color]::Silver
        & $RefreshDeployProgress
        $progressImage.Value = 0
        $lblImageProgress.Text = "Aplicacion de imagen: en espera."
        $lblImageProgress.ForeColor = [System.Drawing.Color]::Silver
        $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()

        try {
            # Excluir configuracion y confirmaciones; reiniciar por cada despliegue.
            $deployWatch.Restart()
            & $RefreshDeployProgress
            $deployTimer.Start()
            & $CheckDeployCancellation

            # Bug 1 corregido: acumulador en memoria para evitar colisiones de letras por latencia VDS
            $reservedLetters = @()

            # ── Fase 1: Preparacion del disco ─────────────────────────
            if ($isVhdMode) {
                $lblStatus.Text = "Creando disco virtual..."
                $form.Refresh()

                $totalSize = [long]$numSize.Value * 1GB
                $vhdCreationStarted = $true
                if ($chkDynamic.Checked) {
                    New-VHD -Path $vhdPath -SizeBytes $totalSize -Dynamic -ErrorAction Stop | Out-Null
                } else {
                    New-VHD -Path $vhdPath -SizeBytes $totalSize -Fixed   -ErrorAction Stop | Out-Null
                }

                & $CheckDeployCancellation
                Mount-VHD -Path $vhdPath -ErrorAction Stop | Out-Null
                
                $diskNum = $null
                $maxRetries = 15
                $retryCount = 0

                # Bucle de espera activa: evalúa cada 500ms si el disco ya está expuesto
                while ($null -eq $diskNum -and $retryCount -lt $maxRetries) {
                    Start-Sleep -Milliseconds 500
                    & $CheckDeployCancellation
                    $vhdInfo = Get-VHD -Path $vhdPath -ErrorAction SilentlyContinue
                    if ($vhdInfo -and $vhdInfo.DiskNumber -ge 0) {
                        $diskNum = $vhdInfo.DiskNumber
                    }
                    $retryCount++
                }

                if ($null -eq $diskNum -or $diskNum -lt 0) {
                    throw "Timeout: El VDS tardó demasiado en exponer el número de disco del VHD. Abortando para evitar daños en el host."
                }
            } else {
                $lblStatus.Text = "Forzando desmontaje y limpiando disco fisico $diskNum..."
                $form.Refresh()
                
                # Desconexión forzada para soltar el bloqueo de Windows Explorer o Antivirus
                Set-Disk -Number $diskNum -IsOffline $true -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
                & $CheckDeployCancellation
                
                # Limpieza con atributo RemoveOEM para destruir particiones protegidas antiguas
                Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            }

            & $CompleteDeployStage -Stage 1

            # ── Fase 2: Inicializacion y particionado ─────────────────
            $lblStatus.Text = "Inicializando disco y preparando particiones..."
            $form.Refresh()
            $partStyle = if ($isGPT) { "GPT" } else { "MBR" }
            Initialize-Disk -Number $diskNum -PartitionStyle $partStyle -ErrorAction Stop
            & $CheckDeployCancellation

            # Prevencion de anomalias: Purga proactiva de particiones automaticas 
            # (Ej. particion MSR fantasma de 16MB inyectada por el motor de Initialize-Disk en GPT)
            Get-Partition -DiskNumber $diskNum | Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue
            & $CheckDeployCancellation

            Write-Log -LogLevel INFO -Message "DEPLOY: Formateando y asignando particiones en Disco $diskNum con esquema $partStyle..."

            if ($isGPT) {
                $lblStatus.Text = "Particionando GPT (UEFI)..."
                $form.Refresh()

                # 1. EFI (Arranque del Sistema)
                $pEFI = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) `
                    -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -ErrorAction Stop
                Format-Volume -Partition $pEFI -FileSystem FAT32 -Confirm:$false | Out-Null
                & $CheckDeployCancellation
                $freeLetBoot      = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetBoot.ToString()
                Set-Partition -InputObject $pEFI -NewDriveLetter $freeLetBoot -ErrorAction Stop
                $driveLetterBoot  = "$($freeLetBoot):"
                & $CheckDeployCancellation

                # 2. MSR (Microsoft Reserved)
                if ($sizeMsrMB -gt 0) {
                    New-Partition -DiskNumber $diskNum -Size ($sizeMsrMB * 1MB) `
                        -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" -ErrorAction Stop | Out-Null
                    & $CheckDeployCancellation
                }

                # 3. Windows (Volumen principal del SO)
                $diskObj   = Get-Disk -Number $diskNum
                $freeSpace = $diskObj.LargestFreeExtent

                if ($sizeRecMB -gt 0) {
                    $winSize = $freeSpace - ($sizeRecMB * 1MB) - 10MB
                    $pWin = New-Partition -DiskNumber $diskNum -Size $winSize -ErrorAction Stop
                } else {
                    $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                }
                Format-Volume -Partition $pWin -FileSystem NTFS -Confirm:$false | Out-Null
                & $CheckDeployCancellation
                $freeLetSys       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetSys.ToString()
                Set-Partition -InputObject $pWin -NewDriveLetter $freeLetSys -ErrorAction Stop
                $driveLetterSystem = "$($freeLetSys):"
                & $CheckDeployCancellation

                # 4. Recovery (Entorno de Recuperacion)
                if ($sizeRecMB -gt 0) {
                    $pRec = New-Partition -DiskNumber $diskNum -UseMaximumSize `
                        -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -ErrorAction Stop
                    Format-Volume -Partition $pRec -FileSystem NTFS -Confirm:$false | Out-Null
                    & $CheckDeployCancellation
                    $freeLetRec       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                    $reservedLetters += $freeLetRec.ToString()
                    Set-Partition -InputObject $pRec -NewDriveLetter $freeLetRec -ErrorAction Stop
                    $driveLetterRecovery = "$($freeLetRec):"
                }

            } else {
                $lblStatus.Text = "Particionando MBR (Legacy)..."
                $form.Refresh()

                # 1. System Reserved (Arranque Activo)
                $pBoot = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) -IsActive -ErrorAction Stop
                Format-Volume -Partition $pBoot -FileSystem NTFS -Confirm:$false | Out-Null
                & $CheckDeployCancellation
                $freeLetBoot      = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetBoot.ToString()
                Set-Partition -InputObject $pBoot -NewDriveLetter $freeLetBoot -ErrorAction Stop
                $driveLetterBoot  = "$($freeLetBoot):"
                & $CheckDeployCancellation

                # 2. Windows (Volumen principal del SO)
                $diskObj   = Get-Disk -Number $diskNum
                $freeSpace = $diskObj.LargestFreeExtent

                if ($sizeRecMB -gt 0) {
                    $winSize = $freeSpace - ($sizeRecMB * 1MB) - 10MB
                    $pWin = New-Partition -DiskNumber $diskNum -Size $winSize -ErrorAction Stop
                } else {
                    $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                }
                Format-Volume -Partition $pWin -FileSystem NTFS -Confirm:$false | Out-Null
                & $CheckDeployCancellation
                $freeLetSys       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetSys.ToString()
                Set-Partition -InputObject $pWin -NewDriveLetter $freeLetSys -ErrorAction Stop
                $driveLetterSystem = "$($freeLetSys):"
                & $CheckDeployCancellation

                # 3. Recovery (Proteccion Legacy Oculta)
                if ($sizeRecMB -gt 0) {
                    $pRec = New-Partition -DiskNumber $diskNum -UseMaximumSize -MbrType 0x27 -ErrorAction Stop
                    Format-Volume -Partition $pRec -FileSystem NTFS -Confirm:$false | Out-Null
                    & $CheckDeployCancellation
                    $freeLetRec       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                    $reservedLetters += $freeLetRec.ToString()
                    Set-Partition -InputObject $pRec -NewDriveLetter $freeLetRec -ErrorAction Stop
                    $driveLetterRecovery = "$($freeLetRec):"
                }
            }

            & $CompleteDeployStage -Stage 2

            # ── Fase 3: Aplicacion de la imagen principal ─────────────────
            $lblStatus.Text = if ($useCompactOS) {
                "Desplegando Windows con Compact OS (Esto puede tardar mas)..."
            } else { "Desplegando imagen (Esto tardara varios minutos)..." }
            $lblImageProgress.Text = "Aplicacion de imagen: 0%."
            $form.Refresh()

            Write-Log -LogLevel ACTION -Message "DEPLOY: Ejecutando DISM nativo hacia $driveLetterSystem\. Compact OS solicitado: $useCompactOS."
            $dismArgs = "/English /Apply-Image /ImageFile:`"$wimPath`" /Index:$idx /ApplyDir:$driveLetterSystem\"
            if ($swmPattern) {
                $dismArgs += " /SWMFile:`"$swmPattern`" /CheckIntegrity /Verify"
            }
            $compactScratch = $null
            try {
                if ($useCompactOS) {
                    $targetVolume = Get-Volume -DriveLetter $freeLetSys[0] -ErrorAction Stop
                    if ($targetVolume.FileSystem -ne 'NTFS') {
                        throw 'El destino de Compact OS debe estar formateado en NTFS.'
                    }
                    # Scratch en el volumen NTFS de Windows; nunca en la particion EFI FAT32.
                    $compactScratch = Join-Path "$driveLetterSystem\" ("AIODeployScratch_" + [guid]::NewGuid().ToString('N'))
                    New-Item -Path $compactScratch -ItemType Directory -ErrorAction Stop | Out-Null
                    $dismArgs += " /Compact /ScratchDir:`"$compactScratch`""
                }
                $dismExitCode = Invoke-AIODeployNativeProcess -FileName "dism.exe" -Arguments $dismArgs -OnPercent $ReportImagePercent
            } finally {
                # El ejecutor espera a que DISM termine antes de llegar a esta limpieza.
                if ($compactScratch -and (Test-Path -LiteralPath $compactScratch)) {
                    try { Remove-Item -LiteralPath $compactScratch -Recurse -Force -ErrorAction Stop }
                    catch { Write-Log -LogLevel WARN -Message "DEPLOY: Temporal de Compact OS pendiente en '$compactScratch': $($_.Exception.Message)" }
                }
            }

            if ($dismExitCode -ne 0) {
                $lblImageProgress.Text = "Aplicacion de imagen: error (codigo $dismExitCode)."
                $lblImageProgress.ForeColor = [System.Drawing.Color]::Red
                throw "Fallo DISM al aplicar la imagen. Codigo: $dismExitCode"
            }
            $progressImage.Value = $progressImage.Maximum
            $lblImageProgress.Text = "Aplicacion de imagen: 100%, completada."
            $lblImageProgress.ForeColor = [System.Drawing.Color]::LightGreen
            & $CompleteDeployStage -Stage 3

            # ── Fase 4: Escritura del sector de arranque ───────────────
            $lblStatus.Text = "Escribiendo sectores de arranque..."
            $form.Refresh()

            $fw       = if ($isGPT) { "UEFI" } else { "BIOS" }
            Write-Log -LogLevel ACTION -Message "DEPLOY: Escribiendo BCD ($fw)..."

            $bcdExitCode = Invoke-AIODeployNativeProcess -FileName "bcdboot.exe" `
                -Arguments "$driveLetterSystem\Windows /s $driveLetterBoot /f $fw"
            if ($bcdExitCode -ne 0) {
                throw "Fallo la creacion de archivos de arranque (BCDBOOT)."
            }
            & $CompleteDeployStage -Stage 4

            # ── Fase 5: Ocultar y proteger particiones de sistema ─────────
            if ($sizeRecMB -gt 0 -and $driveLetterRecovery) {
                $lblStatus.Text = "Protegiendo particion WinRE..."
                $form.Refresh()
                
                # Aplicar Atributos GPT requeridos por Microsoft si estamos en UEFI
                if ($isGPT) {
                    Write-Log -LogLevel INFO -Message "DEPLOY: Inyectando atributos GPT protectivos a la particion Recovery."
                    try {
                        # Corrección: Especificar el Namespace de Storage y filtrar en origen
                        $cimNamespace = "Root\Microsoft\Windows\Storage"
                        $cimPart = Get-CimInstance -Namespace $cimNamespace -ClassName MSFT_Partition -Filter "DriveLetter = '$($freeLetRec[0])'"
                        
                        if ($cimPart) {
                            $cimPart | Set-CimInstance -Property @{ 
                                GptType = "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}"; 
                                IsHidden = $true; 
                                NoDefaultDriveLetter = $true 
                            } -ErrorAction SilentlyContinue
                        }
                    } catch { 
                        Write-Log -LogLevel WARN -Message "DEPLOY: No se pudieron establecer los atributos CIM de la particion Recovery. Error: $($_.Exception.Message)" 
                    }
                }

                Remove-PartitionAccessPath -InputObject $pRec -AccessPath $driveLetterRecovery -ErrorAction SilentlyContinue
                $driveLetterRecovery = $null
            }

            & $CheckDeployCancellation
            $lblStatus.Text = "Ocultando particiones de arranque..."
            $form.Refresh()
            
            $bootPart = Get-Partition -DriveLetter $freeLetBoot[0] -ErrorAction SilentlyContinue
            if ($bootPart) {
                if ($isGPT) {
                    try { 
                        # bootPart ya es un objeto CIM, pero aseguramos la escritura silenciosa
                        $bootPart | Set-CimInstance -Property @{ IsHidden = $true; NoDefaultDriveLetter = $true } -ErrorAction SilentlyContinue 
                    } catch {}
                }
                Remove-PartitionAccessPath -InputObject $bootPart -AccessPath $driveLetterBoot -ErrorAction SilentlyContinue
                $driveLetterBoot = $null
            }

            & $CompleteDeployStage -Stage 5

            # ── Fase 6: Desmontar VHD si aplica ───────────────────────
            if ($isVhdMode) {
                $lblStatus.Text = "Desmontando disco virtual..."
                $form.Refresh()
                Dismount-VHD -Path $vhdPath -ErrorAction Stop
                & $CompleteDeployStage -Stage 6
            }

            $lblStatus.Text      = if ($useCompactOS) { "Completado con Compact OS." } else { "Completado." }
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            $btnCancel.Enabled = $false
            # Detener antes del dialogo: leer el resultado no suma tiempo de trabajo.
            & $StopDeployTime
            $lblDeployProgress.ForeColor = [System.Drawing.Color]::LightGreen
            $elapsedText = Format-AIODeployElapsedTime $deployWatch.Elapsed
            Write-Log -LogLevel INFO -Message "DEPLOY: Despliegue finalizado con exito. Compact OS solicitado: $useCompactOS. Tiempo total: $elapsedText."
            $successMessage = "El disco booteable ha sido creado exitosamente."
            if ($useCompactOS) { $successMessage += "`n`nWindows se desplego con Compact OS." }
            $successMessage += "`n`nTiempo total: $elapsedText"
            [System.Windows.Forms.MessageBox]::Show(
                $successMessage,
                "Despliegue Finalizado", 'OK', 'Information')

        } catch {
            $failureMessage = $_.Exception.Message
            $cancelled = $_.Exception -is [OperationCanceledException]
            $btnCancel.Enabled = $false
            $deployProgress.Caption = if ($cancelled) { 'Cancelando' } else { 'Detenido' }
            $resultColor = if ($cancelled) { [System.Drawing.Color]::Gold } else { [System.Drawing.Color]::Red }
            $lblStatus.Text = if ($cancelled) { 'Cancelando: limpiando el destino...' } else { 'Error en el despliegue. Limpiando el destino...' }
            $lblStatus.ForeColor = $resultColor
            $lblDeployProgress.ForeColor = $resultColor
            if ($deployProgress.Completed -eq 2 -and $progressImage.Value -lt $progressImage.Maximum) {
                $lblImageProgress.Text = if ($cancelled) { 'Aplicacion de imagen: detenida por cancelacion.' } else { 'Aplicacion de imagen: no completada.' }
                $lblImageProgress.ForeColor = $resultColor
            }
            & $RefreshDeployProgress
            $form.Refresh()
            $resultLevel = if ($cancelled) { 'INFO' } else { 'ERROR' }
            Write-Log -LogLevel $resultLevel -Message "DEPLOY: $failureMessage"
            $cleanupWarnings = New-Object 'System.Collections.Generic.List[string]'

            # DISM/BCDBOOT ya han terminado. Retirar solo accesos del disco destino.
            foreach ($letter in @($driveLetterSystem, $driveLetterBoot, $driveLetterRecovery)) {
                try {
                    if ($letter -and (Test-Path "$letter\")) {
                        $part = Get-Partition -DriveLetter $letter[0] -ErrorAction Stop
                        if ($part -and $part.DiskNumber -eq $diskNum) {
                            Remove-PartitionAccessPath `
                                -DiskNumber $diskNum `
                                -PartitionNumber $part.PartitionNumber `
                                -AccessPath $letter `
                                -ErrorAction Stop
                        }
                    }
                } catch {
                    [void]$cleanupWarnings.Add("No se pudo retirar el acceso ${letter}: $($_.Exception.Message)")
                }
                [System.Windows.Forms.Application]::DoEvents()
            }

            # Solo retirar el VHD de esta ejecucion, y nunca si sigue montado.
            if ($isVhdMode -and $vhdCreationStarted -and $vhdPath) {
                try {
                    Remove-AIODeployPartialVhd -Path $vhdPath
                } catch {
                    [void]$cleanupWarnings.Add("Revisa el VHD conservado en '$vhdPath': $($_.Exception.Message)")
                }
            }

            $deployProgress.Caption = if ($cancelled) { 'Cancelado' } else { 'Detenido' }
            $lblStatus.Text = if ($cancelled) { 'Despliegue cancelado.' } else { 'Error en el despliegue.' }
            if ($cleanupWarnings.Count) { $lblStatus.Text += ' Hay tareas de limpieza pendientes.' }
            & $StopDeployTime
            $elapsedText = Format-AIODeployElapsedTime $deployWatch.Elapsed
            Write-Log -LogLevel $resultLevel -Message "DEPLOY: $($deployProgress.Caption). Tiempo total: $elapsedText."
            $resultMessage = if ($cancelled) {
                "Despliegue cancelado. No se continuara con las etapas restantes."
            } else { "Ocurrio un error durante el despliegue:`n`n$failureMessage" }
            if (-not $isVhdMode) {
                $resultMessage += "`n`nLos cambios ya realizados en el disco fisico no se revierten; el destino puede quedar incompleto."
            } elseif ($cancelled -and $vhdCreationStarted -and -not $cleanupWarnings.Count) {
                $resultMessage += "`n`nEl VHD de esta ejecucion se ha retirado."
            }
            foreach ($warning in $cleanupWarnings) { Write-Log -LogLevel WARN -Message "DEPLOY: $warning" }
            if ($cleanupWarnings.Count) { $resultMessage += "`n`nLimpieza pendiente:`n" + ($cleanupWarnings -join "`n") }
            $resultMessage += "`n`nTiempo total: $elapsedText"
            $resultTitle = if ($cancelled) { 'Despliegue cancelado' } else { 'Error de Despliegue' }
            $resultIcon = if ($cancelled) { 'Information' } else { 'Error' }
            if ($cleanupWarnings.Count) { $resultIcon = 'Warning' }
            [System.Windows.Forms.MessageBox]::Show(
                $resultMessage, $resultTitle, 'OK', $resultIcon)

        } finally {
            & $StopDeployTime
            $script:isDeploying = $false
            $btnCancel.Enabled = $false
            $btnCancel.Text = 'CANCELAR'
            $btnDeploy.Enabled  = $true
            $grpSource.Enabled = $true
            $grpTargetMode.Enabled = $true
            $grpDest.Enabled = $true
            $form.Cursor        = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Cierre seguro — bloquear si el despliegue esta en curso
    $form.Add_FormClosing({
        if ($script:isDeploying) {
            [System.Windows.Forms.MessageBox]::Show(
                "El despliegue esta en curso. Usa Cancelar y espera a que termine la operacion activa y su limpieza antes de cerrar.",
                "Operacion en curso", 'OK', 'Warning')
            $_.Cancel = $true
        }
    })

    # ------------------------------------------------------------------
    # 5. Tooltips descriptivos para todos los controles
    # ------------------------------------------------------------------
    $toolTip              = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 8000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay  = 500
    $toolTip.ShowAlways   = $true
    $toolTip.IsBalloon    = $false

    $toolTip.SetToolTip($btnBrowseWim,    "Selecciona WIM, ESD o la primera parte SWM (ej. install.swm).`nPara SWM, todas las partes deben estar juntas en la misma carpeta.")
    $toolTip.SetToolTip($cmbIndex,        "Selecciona la edicion de Windows a instalar.")
    $toolTip.SetToolTip($btnBrowseVhd,    "Define donde se guardara el nuevo archivo de disco virtual (.vhdx o .vhd).")
    $toolTip.SetToolTip($btnRefreshDisks, "Actualiza la lista de discos fisicos extraibles detectados.")
    $toolTip.SetToolTip($numSize,         "Size maximo que podra tener el disco virtual (en Gigabytes).")
    $toolTip.SetToolTip($chkDynamic,      "Marcado: El archivo crece segun guardes datos.`nDesmarcado: Ocupa todo el Size inmediatamente.")
    $toolTip.SetToolTip($chkUEFI,         "Marcado (GPT): Para PCs modernos con UEFI.`nDesmarcado (MBR): Para PCs antiguos con BIOS Legacy.")
    $toolTip.SetToolTip($chkCompactOS,    "Instala Windows 10/11 con sus archivos del sistema comprimidos para ahorrar espacio.`nPuede aumentar el tiempo de despliegue y el uso de CPU. Disponible para VHD/VHDX y disco fisico.")
    $toolTip.SetToolTip($numEfiSize,      "Size de la particion de arranque (EFI o System Reserved).")
    $toolTip.SetToolTip($numMsrSize,      "Size de la particion MSR. Solo aplica en GPT/UEFI.")
    $toolTip.SetToolTip($numRecSize,      "Size de la particion de Recuperacion (WinRE). Se recomienda 1024 MB.")
    $toolTip.SetToolTip($btnDeploy,       "ADVERTENCIA: Iniciara el proceso de creacion/formateo y aplicacion de imagen.")
    $toolTip.SetToolTip($btnCancel,       "Solicita cancelar. Espera a que termine la operacion activa (incluido DISM) y despues limpia el destino. Los cambios ya realizados en un disco fisico no se revierten.")
    $toolTip.SetToolTip($progressDeploy,  "Cuenta las etapas terminadas. El porcentaje no representa el tiempo restante.")
    $toolTip.SetToolTip($progressDeployFill, "Avanza inmediatamente al terminar cada etapa; permanece fijo durante la etapa en curso.")
    $toolTip.SetToolTip($progressImage,   "Muestra el avance informado al aplicar la imagen. Solo llega a 100% cuando la aplicacion termina correctamente.")
    $toolTip.SetToolTip($lblDeployProgress, "Porcentaje de etapas completadas y tiempo transcurrido (horas:minutos:segundos). El reloj se reinicia en cada ejecucion y se detiene al finalizar, cancelar o fallar.")

    $form.Add_FormClosing({
        if ($script:isDeploying -or $_.Cancel) { return }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Estas seguro de que deseas salir?", 
            "Confirmar Salida", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        } else {
        }
    })

    # ------------------------------------------------------------------
    # 6. Mostrar y limpiar
    # ------------------------------------------------------------------
    try {
        $form.ShowDialog() | Out-Null
    } finally {
        $deployWatch.Stop()
        $deployTimer.Stop()
        $deployTimer.Dispose()
        $toolTip.Dispose()
        $form.Dispose()
    }
}
