# =================================================================
#  Modulo-Metadata
#
#  CONTENIDO   : Show-WimMetadata-GUI
#  DEPENDENCIAS: Write-Log (provista por el nucleo via dot-source)
#  CARGA       : . "$PSScriptRoot\Modulo-Metadata.ps1"
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

function Show-WimMetadata-GUI {

    # 1. Cargar dependencias
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Xml
    Add-Type -AssemblyName System.Xml.Linq

    # 2. Motor C# — P/Invoke sobre wimgapi.dll
    $wimEngineSource = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Xml.Linq;
using System.Linq;
using System.IO;

public class WimMasterEngine
{
    private const uint WIM_GENERIC_READ  = 0x80000000;
    private const uint WIM_GENERIC_WRITE = 0x40000000;
    private const uint WIM_OPEN_EXISTING = 3;

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr WIMCreateFile(string pszWimPath, uint dwDesiredAccess, uint dwCreationDisposition, uint dwFlagsAndAttributes, uint dwCompressionType, out uint pdwCreationResult);

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WIMSetTemporaryPath(IntPtr hWim, string pszPath);

    [DllImport("wimgapi.dll", SetLastError = true)]
    private static extern IntPtr WIMLoadImage(IntPtr hWim, uint dwImageIndex);

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WIMGetImageInformation(IntPtr hImage, out IntPtr pInfoHdr, out uint dwcbInfoHdr);

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WIMSetImageInformation(IntPtr hImage, IntPtr pInfoHdr, uint cbInfoHdr);

    [DllImport("wimgapi.dll", SetLastError = true)]
    private static extern bool WIMCloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    private static void SetElementValue(XElement parent, string elementName, string value)
    {
        XElement el = parent.Element(elementName);
        if (el == null) {
            if (!string.IsNullOrEmpty(value)) parent.Add(new XElement(elementName, value));
        } else {
            el.Value = value ?? "";
        }
    }

    private static void ForceSafeTempPath(IntPtr hWim)
    {
        try {
            string sysTemp = Path.GetTempPath();
            WIMSetTemporaryPath(hWim, sysTemp);
        } catch { }
    }

    public static string GetImageXml(string wimPath, int index)
    {
        GC.Collect(); GC.WaitForPendingFinalizers();
        IntPtr hWim = IntPtr.Zero; IntPtr hImg = IntPtr.Zero; IntPtr pInfo = IntPtr.Zero;

        try {
            uint res;
            hWim = WIMCreateFile(wimPath, WIM_GENERIC_READ, WIM_OPEN_EXISTING, 0, 0, out res);
            if (hWim == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ForceSafeTempPath(hWim);

            hImg = WIMLoadImage(hWim, (uint)index);
            if (hImg == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

            uint size;
            if (!WIMGetImageInformation(hImg, out pInfo, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            string xmlRaw = Marshal.PtrToStringUni(pInfo);
            if (xmlRaw.StartsWith("\uFEFF")) xmlRaw = xmlRaw.Substring(1);
            return xmlRaw;
        }
        finally {
            if (pInfo != IntPtr.Zero) LocalFree(pInfo);
            if (hImg != IntPtr.Zero) WIMCloseHandle(hImg);
            if (hWim != IntPtr.Zero) WIMCloseHandle(hWim);
        }
    }

    public static void WriteImageMetadata(string wimPath, int index, string name, string desc, string dispName, string dispDesc, string editionId)
    {
        GC.Collect(); GC.WaitForPendingFinalizers();
        IntPtr hWim = IntPtr.Zero; IntPtr hImg = IntPtr.Zero; IntPtr pXmlBuffer = IntPtr.Zero;

        try {
            uint res;
            hWim = WIMCreateFile(wimPath, WIM_GENERIC_WRITE | WIM_GENERIC_READ, WIM_OPEN_EXISTING, 0, 0, out res);
            if (hWim == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ForceSafeTempPath(hWim);

            hImg = WIMLoadImage(hWim, (uint)index);
            if (hImg == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

            // 1. Leer XML actual
            IntPtr pInfo; uint size;
            if (!WIMGetImageInformation(hImg, out pInfo, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            string currentXml = Marshal.PtrToStringUni(pInfo);
            LocalFree(pInfo);
            if (currentXml.StartsWith("\uFEFF")) currentXml = currentXml.Substring(1);

            // 2. Modificar XML en memoria
            XDocument doc = XDocument.Parse(currentXml);
            XElement root = doc.Root;
            SetElementValue(root, "NAME", name);
            SetElementValue(root, "DESCRIPTION", desc);
            SetElementValue(root, "DISPLAYNAME", dispName);
            SetElementValue(root, "DISPLAYDESCRIPTION", dispDesc);

            XElement windowsNode = root.Element("WINDOWS");
            if (windowsNode == null) { windowsNode = new XElement("WINDOWS"); root.Add(windowsNode); }
            SetElementValue(windowsNode, "EDITIONID", editionId);

            StringBuilder sb = new StringBuilder();
            using (StringWriter writer = new StringWriter(sb)) { doc.Save(writer, SaveOptions.None); }
            string newXmlString = sb.ToString();

            // 3. Escribir XML nuevo (commit inmediato en el header del WIM)
            pXmlBuffer = Marshal.StringToHGlobalUni(newXmlString);
            if (!WIMSetImageInformation(hImg, pXmlBuffer, (uint)(newXmlString.Length * 2)))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally {
            if (pXmlBuffer != IntPtr.Zero) Marshal.FreeHGlobal(pXmlBuffer);
            if (hImg != IntPtr.Zero) WIMCloseHandle(hImg);
            if (hWim != IntPtr.Zero) WIMCloseHandle(hWim);
            GC.Collect();
        }
    }

    public static int GetImageCount(string wimPath)
    {
        GC.Collect(); IntPtr hWim = IntPtr.Zero;
        try {
            uint res;
            hWim = WIMCreateFile(wimPath, WIM_GENERIC_READ, WIM_OPEN_EXISTING, 0, 0, out res);
            if (hWim == IntPtr.Zero) return 0;
            ForceSafeTempPath(hWim);
            return GetImageCountNative(hWim);
        }
        catch { return 0; }
        finally { if (hWim != IntPtr.Zero) WIMCloseHandle(hWim); }
    }

    [DllImport("wimgapi.dll", EntryPoint="WIMGetImageCount")]
    private static extern int GetImageCountNative(IntPtr hWim);
}
"@

    # 3. Compilacion — guarda en el tipo solo una vez por sesion de PS
    try {
        if (-not ([System.Management.Automation.PSTypeName]'WimMasterEngine').Type) {
            $refs = @("System.Xml", "System.Xml.Linq", "System.Core")
            Add-Type -TypeDefinition $wimEngineSource -Language CSharp -ReferencedAssemblies $refs
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error compilacion C#:`n$($_.Exception.Message)",
            "Error Critico", 'OK', 'Error'
        )
        return
    }

    # 4. Construccion del formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Editor Metadatos WIM"
    $form.Size            = New-Object System.Drawing.Size(850, 600)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # -- Selector de archivo --
    $lblFile          = New-Object System.Windows.Forms.Label
    $lblFile.Text     = "WIM:"
    $lblFile.Location = "20, 20"
    $lblFile.AutoSize = $true
    $form.Controls.Add($lblFile)

    $txtPath           = New-Object System.Windows.Forms.TextBox
    $txtPath.Location  = "80, 18"
    $txtPath.Size      = "600, 23"
    $txtPath.ReadOnly  = $true
    $txtPath.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtPath.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtPath)

    $btnBrowse           = New-Object System.Windows.Forms.Button
    $btnBrowse.Text      = "..."
    $btnBrowse.Location  = "690, 17"
    $btnBrowse.Size      = "40, 25"
    $btnBrowse.BackColor = [System.Drawing.Color]::Gray
    $btnBrowse.FlatStyle = "Flat"
    $form.Controls.Add($btnBrowse)

    # -- Selector de indice --
    $lblIdx          = New-Object System.Windows.Forms.Label
    $lblIdx.Text     = "Index:"
    $lblIdx.Location = "20, 60"
    $lblIdx.AutoSize = $true
    $form.Controls.Add($lblIdx)

    $cmbIndex               = New-Object System.Windows.Forms.ComboBox
    $cmbIndex.Location      = "80, 58"
    $cmbIndex.Size          = "600, 25"
    $cmbIndex.DropDownStyle = "DropDownList"
    $cmbIndex.BackColor     = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cmbIndex.ForeColor     = [System.Drawing.Color]::White
    $form.Controls.Add($cmbIndex)

    # -- Grid de metadatos --
    $dgv                             = New-Object System.Windows.Forms.DataGridView
    $dgv.Location                    = "20, 100"
    $dgv.Size                        = "790, 380"
    $dgv.AllowUserToAddRows          = $false
    $dgv.AllowUserToDeleteRows       = $false
    $dgv.RowHeadersVisible           = $false
    $dgv.AutoSizeColumnsMode         = "Fill"
    $dgv.BackgroundColor             = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $dgv.GridColor                   = [System.Drawing.Color]::Gray
    $dgv.DefaultCellStyle.BackColor  = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $dgv.DefaultCellStyle.ForeColor  = [System.Drawing.Color]::White
    $dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::SteelBlue
    $dgv.Columns.Add("Prop", "Propiedad") | Out-Null
    $dgv.Columns.Add("Val",  "Valor")     | Out-Null
    $dgv.Columns[0].ReadOnly   = $true
    $dgv.Columns[0].FillWeight = 30
    $form.Controls.Add($dgv)

    # -- Boton guardar y etiqueta de estado --
    $btnSave           = New-Object System.Windows.Forms.Button
    $btnSave.Text      = "GUARDAR (Commit)"
    $btnSave.Location  = "550, 500"
    $btnSave.Size      = "260, 40"
    $btnSave.BackColor = [System.Drawing.Color]::SeaGreen
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = "Flat"
    $btnSave.Enabled   = $false
    $form.Controls.Add($btnSave)

    $lblStatus          = New-Object System.Windows.Forms.Label
    $lblStatus.Location = "20, 510"
    $lblStatus.Size     = "500, 25"
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $lblStatus.Text     = "Listo."
    $form.Controls.Add($lblStatus)

    # ---------------------------------------------------------------
    # EVENTO: Boton "..." — abrir archivo WIM y poblar el ComboBox
    # ---------------------------------------------------------------
    $btnBrowse.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "WIM|*.wim"

        if ($ofd.ShowDialog() -eq 'OK') {
            $txtPath.Text = $ofd.FileName
            $cmbIndex.Items.Clear()
            $dgv.Rows.Clear()
            $btnSave.Enabled  = $false
            $lblStatus.Text   = "Escaneando nombres..."
            $form.Refresh()

            try {
                $count = [WimMasterEngine]::GetImageCount($ofd.FileName)
                if ($count -gt 0) {
                    for ($i = 1; $i -le $count; $i++) {
                        $name = "Desconocido"
                        try {
                            $xmlRaw = [WimMasterEngine]::GetImageXml($ofd.FileName, $i)
                            $xml    = [System.Xml.Linq.XDocument]::Parse($xmlRaw)
                            $nameEl = $xml.Root.Element("NAME")
                            if ($null -ne $nameEl) { $name = $nameEl.Value }
                        } catch {}
                        $cmbIndex.Items.Add("[$i] $name")
                    }
                    $cmbIndex.SelectedIndex = 0
                    $lblStatus.Text = "WIM Cargado."
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error: $_")
            }
        }
    })

    # ---------------------------------------------------------------
    # EVENTO: Cambio de indice — mostrar metadatos del indice elegido
    # ---------------------------------------------------------------
    $cmbIndex.Add_SelectedIndexChanged({
        if ($txtPath.Text) {
            $idx = $cmbIndex.SelectedIndex + 1
            $dgv.Rows.Clear()
            try {
                $xml = [System.Xml.Linq.XDocument]::Parse(
                    [WimMasterEngine]::GetImageXml($txtPath.Text, $idx)
                )
                $img = $xml.Root

                # Helper inline para leer nodos de forma segura
                function Get-NodeVal($el, $name) {
                    $x = $el.Element($name)
                    if ($null -ne $x) { return $x.Value } else { return "" }
                }

                # Filas editables
                $dgv.Rows.Add("Nombre",               (Get-NodeVal $img "NAME"))              | Out-Null
                $dgv.Rows.Add("Descripcion",          (Get-NodeVal $img "DESCRIPTION"))        | Out-Null
                $dgv.Rows.Add("Nombre Mostrado",      (Get-NodeVal $img "DISPLAYNAME"))        | Out-Null
                $dgv.Rows.Add("Descripcion Mostrada", (Get-NodeVal $img "DISPLAYDESCRIPTION")) | Out-Null

                $winNode  = $img.Element("WINDOWS")
                $editionId = ""
                if ($null -ne $winNode) { $editionId = Get-NodeVal $winNode "EDITIONID" }
                $dgv.Rows.Add("ID de Edicion", $editionId) | Out-Null

                # Filas de solo lectura
                # A) Arquitectura
                $archVal = if ($null -ne $winNode) { Get-NodeVal $winNode "ARCH" } else { "" }
                $archStr = switch ($archVal) { "0" {"x86"} "9" {"x64"} "12" {"ARM64"} default {$archVal} }
                $rowArch = $dgv.Rows.Add("Arquitectura", $archStr)

                # B) Version
                $verStr = ""
                if ($null -ne $winNode) {
                    $vNode = $winNode.Element("VERSION")
                    if ($null -ne $vNode) {
                        $verStr = "$(Get-NodeVal $vNode 'MAJOR').$(Get-NodeVal $vNode 'MINOR').$(Get-NodeVal $vNode 'BUILD').$(Get-NodeVal $vNode 'SPBUILD')"
                    }
                }
                $rowVer = $dgv.Rows.Add("Version", $verStr)

                # C) Tamaño en GB
                $bytesStr    = Get-NodeVal $img "TOTALBYTES"
                $sizeDisplay = ""
                if ($bytesStr -match "^\d+$") {
                    $sizeDisplay = "$([math]::Round([long]$bytesStr / 1GB, 2)) GB"
                }
                $rowSize = $dgv.Rows.Add("Size", $sizeDisplay)

                # D) Fecha de creacion
                $dateStr = ""
                $cTime   = $img.Element("CREATIONTIME")
                if ($null -ne $cTime) {
                    try {
                        $high     = [long](Get-NodeVal $cTime "HIGHPART")
                        $low      = [long](Get-NodeVal $cTime "LOWPART")
                        $combined = ($high -shl 32) -bor ($low -band 0xFFFFFFFFL)
                        $dateStr  = [DateTime]::FromFileTime($combined).ToString("yyyy-MM-dd HH:mm")
                    } catch { $dateStr = "Desconocida" }
                }
                $rowDate = $dgv.Rows.Add("Fecha de Creacion", $dateStr)

                # E) Idiomas
                $langStr = "Desconocido"
                if ($null -ne $winNode) {
                    $langsNode = $winNode.Element("LANGUAGES")
                    if ($null -ne $langsNode) {
                        $langList = @()
                        foreach ($lNode in $langsNode.Elements("LANGUAGE")) { $langList += $lNode.Value }
                        $defaultLang = Get-NodeVal $langsNode "DEFAULT"
                        if ($langList.Count -gt 0) {
                            $langStr = $langList -join ", "
                            if (-not [string]::IsNullOrWhiteSpace($defaultLang)) {
                                $langStr += " (Predeterminado: $defaultLang)"
                            }
                        }
                    }
                }
                $rowLang = $dgv.Rows.Add("Idioma(s)", $langStr)

                # Aplicar estilo de solo lectura
                foreach ($rIndex in @($rowArch, $rowVer, $rowSize, $rowDate, $rowLang)) {
                    $dgv.Rows[$rIndex].ReadOnly = $true
                    $dgv.Rows[$rIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
                    $dgv.Rows[$rIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Silver
                }

                $btnSave.Enabled = $true

            } catch {
                $lblStatus.Text = "Error Lectura."
                [System.Windows.Forms.MessageBox]::Show("Error: $_")
            }
        }
    })

    # ---------------------------------------------------------------
    # EVENTO: Boton GUARDAR — commit de metadatos via WimMasterEngine
    # ---------------------------------------------------------------
    $btnSave.Add_Click({
        $path = $txtPath.Text
        $idx  = $cmbIndex.SelectedIndex + 1

        $d = @{}
        foreach ($r in $dgv.Rows) { $d[$r.Cells[0].Value] = $r.Cells[1].Value }

        Write-Log -LogLevel ACTION -Message "WimMetadataManager: Iniciando reescritura de metadatos XML para el WIM [$path] (Indice: $idx)."
        Write-Log -LogLevel INFO   -Message "WimMetadataManager: Valores a inyectar -> Nombre: [$($d['Nombre'])] | Edicion: [$($d['ID de Edicion'])]"

        $form.Cursor     = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text  = "Guardando..."
        $form.Refresh()
        $btnSave.Enabled = $false
        $success         = $false

        try {
            [WimMasterEngine]::WriteImageMetadata(
                $path,
                $idx,
                $d["Nombre"],
                $d["Descripcion"],
                $d["Nombre Mostrado"],
                $d["Descripcion Mostrada"],
                $d["ID de Edicion"]
            )

            $success        = $true
            $lblStatus.Text = "OK"
            Write-Log -LogLevel INFO -Message "WimMetadataManager: Metadatos guardados exitosamente. El archivo WIM ha sido actualizado."
            [System.Windows.Forms.MessageBox]::Show("Guardado Exitoso", "OK", 'OK', 'Information')

        } catch {
            if (-not $success) {
                $lblStatus.Text = "Error"
                $errMsg = $_.Exception.Message
                Write-Log -LogLevel ERROR -Message "WimMetadataManager: Falla critica al escribir metadatos usando la API .NET - $errMsg"
                [System.Windows.Forms.MessageBox]::Show("Error al guardar: $errMsg", "Error", 'OK', 'Error')
            }
        } finally {
            $form.Cursor     = [System.Windows.Forms.Cursors]::Default
            $btnSave.Enabled = $true
            if ($success) {
                $cmbIndex.Items[$idx - 1] = "[$idx] " + $d["Nombre"]
                Write-Log -LogLevel INFO -Message "WimMetadataManager: UI y lista de indices actualizados con el nuevo nombre."
            }
        }
    })

    # 5. Mostrar y limpiar
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $form = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500
}