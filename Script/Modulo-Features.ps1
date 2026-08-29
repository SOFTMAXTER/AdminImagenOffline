# =================================================================
#  Modulo-Features
#
#  CONTENIDO   : Show-Features-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:Scratch_DIR    : directorio temporal para staging NetFx3
#  CARGA       : . "$PSScriptRoot\Modulo-Features.ps1"
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

function Show-Features-GUI {
    param()

    # ------------------------------------------------------------------
    # 1. Validacion de imagen montada
    # ------------------------------------------------------------------
    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Caracteristicas de Windows (Features) - $Script:MOUNT_DIR"
    $form.Size            = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # Tooltip para descripciones largas de cada feature
    $toolTip              = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 10000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay  = 500

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Gestor de Caracteristicas"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 10"
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Barra de busqueda
    $lblSearch          = New-Object System.Windows.Forms.Label
    $lblSearch.Text     = "Buscar:"
    $lblSearch.Location = "20, 45"
    $lblSearch.AutoSize = $true
    $form.Controls.Add($lblSearch)

    $txtSearch           = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location  = "70, 42"
    $txtSearch.Size      = "600, 23"
    $txtSearch.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtSearch.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtSearch)

    # ListView principal
    $lv                  = New-Object System.Windows.Forms.ListView
    $lv.Location         = "20, 80"
    $lv.Size             = "840, 480"
    $lv.View             = "Details"
    $lv.CheckBoxes       = $true
    $lv.FullRowSelect    = $true
    $lv.GridLines        = $true
    $lv.BackColor        = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lv.ForeColor        = [System.Drawing.Color]::White
    $lv.ShowItemToolTips = $true
    $lv.Columns.Add("Caracteristica",  350) | Out-Null
    $lv.Columns.Add("Estado",          150) | Out-Null
    $lv.Columns.Add("Nombre Interno",  300) | Out-Null
    $form.Controls.Add($lv)

    # Etiqueta de estado
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Cargando datos... (La interfaz puede congelarse unos segundos)"
    $lblStatus.Location  = "20, 570"
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # Boton .NET 3.5 SXS
    $btnNetFx3           = New-Object System.Windows.Forms.Button
    $btnNetFx3.Text      = "INTEGRAR .NET 3.5 (SXS)"
    $btnNetFx3.Location  = "400, 600"
    $btnNetFx3.Size      = "220, 40"
    $btnNetFx3.BackColor = [System.Drawing.Color]::DodgerBlue
    $btnNetFx3.ForeColor = [System.Drawing.Color]::White
    $btnNetFx3.FlatStyle = "Flat"
    $btnNetFx3.Enabled   = $false
    $toolTip.SetToolTip($btnNetFx3, "Instala .NET Framework 3.5 buscando la carpeta 'sxs' localmente.")
    $form.Controls.Add($btnNetFx3)

    # Boton aplicar cambios
    $btnApply           = New-Object System.Windows.Forms.Button
    $btnApply.Text      = "APLICAR CAMBIOS"
    $btnApply.Location  = "640, 600"
    $btnApply.Size      = "220, 40"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = "Flat"
    $btnApply.Enabled   = $false
    $form.Controls.Add($btnApply)

    # ------------------------------------------------------------------
    # 3. Catalogo de nombres amigables y descripciones
    #    Fuente: documentacion oficial Microsoft + descripcion funcional
    #    Estructura: FeatureName -> @{ N = Nombre amigable; D = Descripcion }
    # ------------------------------------------------------------------
    $featureCatalog = @{

        # ── .NET y Frameworks ────────────────────────────────────────────────
        "NetFx3"                          = @{ N = ".NET Framework 3.5 (incluye 2.0 y 3.0)";               D = "Entorno de ejecucion para apps antiguas basadas en .NET 2.0/3.0/3.5. Requerido por muchos instaladores clasicos y herramientas empresariales." }
        "NetFx4-AdvSrvs"                  = @{ N = ".NET Framework 4.x - Servicios Avanzados";             D = "Servicios avanzados del framework .NET 4.x, incluyendo WCF y WF (Windows Workflow Foundation)." }
        "NetFx4Extended-ASPNET45"         = @{ N = "ASP.NET 4.5";                                           D = "Extension de ASP.NET 4.5 para IIS. Necesario para alojar aplicaciones web clasicas en servidor IIS local." }
        "WCF-Services45"                  = @{ N = "WCF - Servicios de Comunicacion (4.5)";                 D = "Windows Communication Foundation: marco para crear servicios orientados a mensajes (SOAP, REST, named pipes, MSMQ)." }
        "WCF-TCP-PortSharing45"           = @{ N = "WCF - Comparticion de Puerto TCP (4.5)";                D = "Permite que multiples servicios WCF compartan el mismo puerto TCP sin conflictos de binding." }
        "WCF-HTTP-Activation45"           = @{ N = "WCF - Activacion HTTP (4.5)";                           D = "Activa servicios WCF a traves de solicitudes HTTP/HTTPS sin necesidad de que el servicio este pre-iniciado." }
        "WCF-TCP-Activation45"            = @{ N = "WCF - Activacion TCP (4.5)";                            D = "Activa servicios WCF a traves de conexiones TCP puras (sin HTTP), util en redes de intranet de alta velocidad." }
        "WCF-MSMQ-Activation45"           = @{ N = "WCF - Activacion por Cola de Mensajes";                 D = "Activa servicios WCF cuando llega un mensaje a una cola MSMQ. Necesario para mensajeria empresarial asincrona." }
        "WCF-Pipe-Activation45"           = @{ N = "WCF - Activacion Named Pipes";                          D = "Activa servicios WCF a traves de named pipes, protocolo de comunicacion local de muy baja latencia." }
        "Windows-Identity-Foundation"     = @{ N = "Windows Identity Foundation 3.5";                       D = "SDK para aplicaciones .NET con autenticacion basada en reclamaciones (Claims-based identity), OAuth y SAML." }

        # ── Internet Information Services (IIS) ──────────────────────────────
        "IIS-WebServerRole"               = @{ N = "IIS - Servidor Web (Rol Completo)";                     D = "Instala el servidor web IIS con todos sus componentes principales. Permite alojar sitios web y aplicaciones localmente." }
        "IIS-WebServer"                   = @{ N = "IIS - Servidor Web";                                    D = "Nucleo del servidor web IIS: soporte para contenido estatico, directorios virtuales y paginas de error personalizadas." }
        "IIS-CommonHttpFeatures"          = @{ N = "IIS - Funciones HTTP Comunes";                          D = "Componentes HTTP basicos de IIS: documento predeterminado, exploracion de directorios, contenido estatico y redireccion." }
        "IIS-HttpErrors"                  = @{ N = "IIS - Errores HTTP Personalizados";                     D = "Permite configurar paginas de error personalizadas para distintos codigos HTTP (404, 500, etc.)." }
        "IIS-HttpRedirect"                = @{ N = "IIS - Redirecciones HTTP";                              D = "Habilita reglas de redireccion permanente (301) y temporal (302) a nivel de servidor o directorio." }
        "IIS-DefaultDocument"             = @{ N = "IIS - Documento Predeterminado";                        D = "Sirve automaticamente archivos index.html, default.asp, etc. cuando se accede a un directorio sin especificar archivo." }
        "IIS-DirectoryBrowsing"           = @{ N = "IIS - Exploracion de Directorios";                      D = "Genera una lista HTML navegable de los archivos de un directorio cuando no hay documento predeterminado." }
        "IIS-StaticContent"               = @{ N = "IIS - Contenido Estatico";                              D = "Sirve archivos estaticos: HTML, CSS, JS, imagenes, PDFs. Componente basico de cualquier servidor web." }
        "IIS-WebSockets"                  = @{ N = "IIS - WebSockets";                                      D = "Soporte para protocolo WebSocket en IIS, necesario para aplicaciones en tiempo real (chat, dashboards, gaming)." }
        "IIS-ApplicationInit"             = @{ N = "IIS - Inicializacion de Aplicaciones";                  D = "Pre-calienta las aplicaciones web al arrancar IIS, eliminando el retraso en la primera solicitud (cold start)." }
        "IIS-ISAPIExtensions"             = @{ N = "IIS - Extensiones ISAPI";                               D = "Soporte para modulos ISAPI nativos (.dll), usados por tecnologias clasicas como WebDAV y algunas apps de terceros." }
        "IIS-ISAPIFilter"                 = @{ N = "IIS - Filtros ISAPI";                                   D = "Permite que filtros ISAPI intercepten y modifiquen solicitudes/respuestas HTTP a nivel bajo del servidor." }
        "IIS-ASPNET"                      = @{ N = "IIS - ASP.NET 3.5";                                     D = "Motor de ejecucion de aplicaciones web ASP.NET clasicas sobre .NET Framework 3.5 en IIS." }
        "IIS-ASPNET45"                    = @{ N = "IIS - ASP.NET 4.5+";                                    D = "Motor de ejecucion de aplicaciones web ASP.NET sobre .NET Framework 4.5 y versiones posteriores en IIS." }
        "IIS-ASP"                         = @{ N = "IIS - ASP Clasico";                                     D = "Soporte para paginas ASP clasicas (VBScript/JScript). Tecnologia legacy necesaria solo para apps muy antiguas." }
        "IIS-CGI"                         = @{ N = "IIS - CGI (Gateway de Interfaz Comun)";                 D = "Permite ejecutar scripts externos (Python, Perl, PHP) via el protocolo CGI estandar en IIS." }
        "IIS-ServerSideIncludes"          = @{ N = "IIS - SSI (Includes del Lado Servidor)";                D = "Habilita directivas SSI en archivos .shtml para incrustar contenido dinamico sin necesidad de scripting completo." }
        "IIS-FTP"                         = @{ N = "IIS - Servidor FTP";                                    D = "Convierte IIS en servidor FTP, permitiendo transferencia de archivos por protocolo FTP/FTPS." }
        "IIS-ManagementConsole"           = @{ N = "IIS - Consola de Administracion";                       D = "Herramienta grafica MMC para administrar sitios, grupos de aplicaciones, modulos y configuracion de IIS." }
        "IIS-ManagementService"           = @{ N = "IIS - Servicio de Administracion Remota";               D = "Permite administrar IIS de forma remota desde otras maquinas usando el Administrador de IIS o WebDeploy." }
        "IIS-HealthAndDiagnostics"        = @{ N = "IIS - Diagnostico y Salud";                             D = "Herramientas de monitoreo de IIS: registro HTTP, rastreo de solicitudes fallidas, supervision del proceso." }
        "IIS-HttpLogging"                 = @{ N = "IIS - Registro de Solicitudes HTTP";                    D = "Registra todas las solicitudes entrantes en logs W3C para analisis de trafico, errores y accesos." }
        "IIS-RequestMonitor"              = @{ N = "IIS - Monitor de Solicitudes";                          D = "Muestra en tiempo real las solicitudes HTTP activas en el servidor, util para diagnosticar cuellos de botella." }
        "IIS-HttpTracing"                 = @{ N = "IIS - Rastreo de Solicitudes Fallidas";                 D = "Registra informacion detallada sobre solicitudes que fallan, con codigo de estado, modulo y notificacion del error." }
        "IIS-Security"                    = @{ N = "IIS - Seguridad Web";                                   D = "Modulos de seguridad de IIS: autenticacion basica, de Windows, digest, de certificados cliente y filtrado de IPs." }
        "IIS-BasicAuthentication"         = @{ N = "IIS - Autenticacion Basica";                            D = "Autenticacion HTTP simple con usuario/contrasena. Usar siempre con HTTPS ya que las credenciales van en claro." }
        "IIS-WindowsAuthentication"       = @{ N = "IIS - Autenticacion de Windows (Kerberos/NTLM)";        D = "Autenticacion integrada de Windows usando Kerberos o NTLM. Ideal para intranets y aplicaciones corporativas." }
        "IIS-DigestAuthentication"        = @{ N = "IIS - Autenticacion Digest";                            D = "Autenticacion HTTP que envia contrasenas hasheadas (MD5) en lugar de texto plano. Alternativa a Basic Auth." }
        "IIS-ClientCertificateMappingAuthentication" = @{ N = "IIS - Autenticacion por Certificado de Cliente"; D = "Autentica usuarios mediante certificados X.509 de cliente. Nivel de seguridad muy alto, usado en entornos PKI." }
        "IIS-IISCertificateMappingAuthentication"    = @{ N = "IIS - Mapeo de Certificados (IIS)";          D = "Mapeo de certificados de cliente gestionado por IIS directamente, independiente del directorio activo." }
        "IIS-URLAuthorization"            = @{ N = "IIS - Autorizacion por URL";                            D = "Controla el acceso a URLs especificas mediante reglas de autorizacion basadas en usuarios y roles." }
        "IIS-RequestFiltering"            = @{ N = "IIS - Filtrado de Solicitudes";                         D = "Primera linea de defensa de IIS: bloquea URLs, verbos HTTP, extensiones de archivo y tamanos de solicitud peligrosos." }
        "IIS-IPSecurity"                  = @{ N = "IIS - Seguridad por IP y Dominio";                      D = "Permite o deniega el acceso al servidor segun la direccion IP o nombre de dominio del cliente." }
        "IIS-Performance"                 = @{ N = "IIS - Optimizacion de Rendimiento";                     D = "Modulos de rendimiento de IIS: compresion HTTP estatica y dinamica para reducir el ancho de banda transferido." }
        "IIS-HttpCompressionStatic"       = @{ N = "IIS - Compresion de Contenido Estatico";                D = "Comprime automaticamente archivos estaticos (HTML, CSS, JS) con gzip/deflate antes de enviarlos al navegador." }
        "IIS-HttpCompressionDynamic"      = @{ N = "IIS - Compresion de Contenido Dinamico";                D = "Comprime respuestas generadas dinamicamente (ASP.NET, PHP) en tiempo real. Reduce la latencia en apps web." }

        # ── Hyper-V y Virtualizacion ─────────────────────────────────────────
        "Microsoft-Hyper-V-All"           = @{ N = "Hyper-V Completo";                                      D = "Plataforma de virtualizacion de Microsoft. Permite crear y gestionar maquinas virtuales con hardware dedicado." }
        "Microsoft-Hyper-V"               = @{ N = "Hyper-V - Servicios de Hipervisor";                     D = "Nucleo del hipervisor Hyper-V: motor de virtualizacion que gestiona el aislamiento y los recursos de cada VM." }
        "Microsoft-Hyper-V-Tools-All"     = @{ N = "Hyper-V - Herramientas de Administracion";              D = "Consola de gestion de Hyper-V, modulo PowerShell y herramientas de integracion para administrar VMs." }
        "Microsoft-Hyper-V-Management-Clients"       = @{ N = "Hyper-V - Cliente de Administracion Remota"; D = "Permite administrar servidores Hyper-V remotos desde este equipo sin necesitar Hyper-V instalado localmente." }
        "Microsoft-Hyper-V-Management-PowerShell"    = @{ N = "Hyper-V - Modulo PowerShell";                D = "Cmdlets de PowerShell para automatizar la creacion, configuracion y gestion de maquinas virtuales Hyper-V." }
        "HypervisorPlatform"              = @{ N = "Plataforma de Hipervisor de Windows";                    D = "API de hipervisor de Windows (WHvP): permite a hipervisores de terceros (VMware, QEMU) coexistir con Hyper-V." }
        "VirtualMachinePlatform"          = @{ N = "Plataforma de Maquina Virtual";                          D = "Componente base requerido por WSL 2 y Android Subsystem. Proporciona la capa de virtualizacion ligera para contenedores." }
        "Containers-DisposableClientVM"   = @{ N = "Windows Sandbox";                                        D = "Entorno de escritorio desechable: ejecuta apps no confiables en aislamiento total. Al cerrar, todo desaparece." }
        "Containers"                      = @{ N = "Contenedores de Windows";                                D = "Infraestructura de contenedores nativos de Windows, base para Docker Desktop y Kubernetes en Windows." }
        "HostGuardian"                    = @{ N = "Host Guardian (VMs Blindadas)";                          D = "Componente para ejecutar maquinas virtuales blindadas protegidas criptograficamente, usado en datacenters seguros." }
        "IsolatedUserMode"                = @{ N = "Modo de Usuario Aislado (VBS)";                          D = "Habilita Virtualization Based Security (VBS): Credential Guard y otras protecciones avanzadas de seguridad del kernel." }

        # ── WSL ──────────────────────────────────────────────────────────────
        "Microsoft-Windows-Subsystem-Linux" = @{ N = "Subsistema de Windows para Linux (WSL)";              D = "Permite ejecutar distribuciones Linux nativamente en Windows sin maquina virtual completa. Requerido para WSL 1." }

        # ── Red y Comunicaciones ─────────────────────────────────────────────
        "SMB1Protocol"                    = @{ N = "[PELIGROSO] SMB 1.0 / CIFS (Comparticion Legacy)";      D = "Protocolo de red obsoleto con vulnerabilidades criticas (EternalBlue/WannaCry). Deshabilitar salvo equipos XP/2003." }
        "SMB1Protocol-Server"             = @{ N = "[PELIGROSO] SMB 1.0 - Servidor";                        D = "Componente servidor de SMB 1.0. Deshabilitar salvo que la red contenga clientes Windows XP o Server 2003." }
        "SMB1Protocol-Client"             = @{ N = "[PELIGROSO] SMB 1.0 - Cliente";                         D = "Componente cliente de SMB 1.0. Deshabilitar salvo que se necesite acceder a servidores de red muy antiguos." }
        "SMBDirect"                       = @{ N = "SMB Direct (RDMA)";                                      D = "SMB sobre adaptadores RDMA: transferencia de archivos a velocidad de memoria, sin carga de CPU. Para redes de datacenter." }
        "TelnetClient"                    = @{ N = "Cliente Telnet";                                          D = "Herramienta de linea de comandos para conectar a servidores Telnet. Util para diagnostico de conectividad TCP." }
        "TelnetServer"                    = @{ N = "[INSEGURO] Servidor Telnet";                              D = "Permite conexiones remotas en texto plano sin cifrado. Usar SSH en su lugar. Solo en redes completamente aisladas." }
        "TFTP"                            = @{ N = "Cliente TFTP";                                            D = "Protocolo de transferencia de archivos trivial sin autenticacion. Usado para arranque PXE y dispositivos de red." }
        "SimpleTCP"                       = @{ N = "Servicios TCP/IP Simples (Echo, Daytime, Chargen...)";   D = "Servicios de red de diagnostico muy antiguos. Solo para entornos de prueba; no instalar en produccion." }
        "RIP"                             = @{ N = "Escucha RIP (Protocolo de Enrutamiento)";                D = "Escucha actualizaciones RIPv1 de routers para actualizar la tabla de enrutamiento local." }
        "SNMP"                            = @{ N = "Protocolo SNMP";                                         D = "Simple Network Management Protocol: permite monitorear y gestionar dispositivos de red remotamente." }
        "DataCenterBridging"              = @{ N = "Data Center Bridging (DCB)";                              D = "Extensiones de Ethernet para datacenters: control de flujo por prioridad, esencial para redes convergentes iSCSI/FCoE." }
        "MultiPath-IO"                    = @{ N = "E/S de Rutas Multiples (MPIO)";                          D = "Gestiona multiples rutas fisicas a dispositivos de almacenamiento para redundancia y equilibrio de carga SAN/iSCSI." }

        # ── Almacenamiento y NFS ─────────────────────────────────────────────
        "ServicesForNFS-ClientOnly"       = @{ N = "Servicios NFS - Cliente";                                D = "Permite montar recursos compartidos NFS de servidores Linux/Unix como unidades de red en Windows." }
        "ClientForNFS-Infrastructure"     = @{ N = "Infraestructura Cliente NFS";                            D = "Componente base del cliente NFS de Windows. Necesario para acceder a exports NFS de servidores Unix/Linux." }
        "NFS-Administration"              = @{ N = "Administracion NFS";                                      D = "Herramientas de linea de comandos para configurar y gestionar los servicios cliente y servidor NFS de Windows." }
        "ServicesForNFS-ServerAndClient"  = @{ N = "Servicios NFS - Servidor y Cliente";                     D = "Instalacion completa de servicios NFS: comparte carpetas con sistemas Unix/Linux y accede a ellos." }
        "WindowsStorageManagementService" = @{ N = "Servicio de Gestion de Almacenamiento de Windows";       D = "API WMI para gestionar discos, particiones, volumenes y espacios de almacenamiento mediante scripting." }
        "EnhancedStorage"                 = @{ N = "Almacenamiento Mejorado (Enhanced Storage)";             D = "Soporte para dispositivos con capacidades de seguridad mejoradas: cifrado hardware IEEE 1667, autenticacion en disco." }

        # ── Impresion y documentos ───────────────────────────────────────────
        "Printing-PrintToPDFServices-Features"    = @{ N = "Microsoft Imprimir a PDF";                      D = "Impresora virtual que convierte cualquier documento imprimible en un archivo PDF sin software adicional." }
        "Printing-XPSServices-Features"           = @{ N = "Microsoft Escritor de Documentos XPS";          D = "Impresora virtual que genera documentos XPS (alternativa de Microsoft a PDF). Incluye visor XPS basico." }
        "Printing-Foundation-Features"            = @{ N = "Base del Subsistema de Impresion";               D = "Componentes fundamentales del sistema de impresion de Windows: spooler, drivers base y APIs de impresion." }
        "Printing-Foundation-InternetPrinting-Client" = @{ N = "Impresion por Internet (IPP)";              D = "Permite conectar e imprimir en impresoras compartidas via HTTP/HTTPS usando el protocolo IPP estandar." }
        "FaxServicesClientPackage"                = @{ N = "Fax y Escaneo de Windows";                       D = "Aplicacion para enviar y recibir faxes via modem, y escanear documentos mediante TWAIN/WIA." }
        "Xps-Foundation-Xps-Viewer"               = @{ N = "Visor XPS";                                     D = "Aplicacion para abrir y ver documentos en formato XPS (XML Paper Specification), alternativa a PDF de Microsoft." }
        "TIFFIFilter"                             = @{ N = "Filtro IFilter para TIFF";                       D = "Permite que Windows Search indexe el contenido de archivos TIFF para incluirlos en busquedas del sistema." }
        "ScanManagementConsole"                   = @{ N = "Consola de Gestion de Escaner";                  D = "Snap-in MMC para administrar escaneres de red compartidos en el entorno corporativo." }

        # ── Multimedia ───────────────────────────────────────────────────────
        "WindowsMediaPlayer"              = @{ N = "Reproductor de Windows Media";                            D = "Reproductor multimedia clasico para audio y video. Compatible con WMA, WMV, MP3, MP4 y otros formatos." }
        "MediaPlayback"                   = @{ N = "Reproduccion Multimedia (Decodificadores del Sistema)";   D = "Componentes de reproduccion multimedia del sistema: decodificadores de audio/video para aplicaciones UWP y nativas." }
        "LegacyComponents"                = @{ N = "Componentes Heredados (DirectPlay)";                      D = "DirectPlay: API de red para juegos antiguos de DirectX. Solo necesario para juegos clasicos de los anos 90-2000." }
        "DirectPlay"                      = @{ N = "DirectPlay (Juegos Clasicos en Red)";                    D = "Componente de red para juegos retro multijugador que usan la API DirectPlay de DirectX. Raramente necesario." }

        # ── Seguridad y cifrado ──────────────────────────────────────────────
        "BitLocker"                       = @{ N = "Cifrado de Unidad BitLocker";                            D = "Cifrado de disco completo integrado en Windows. Protege los datos del disco ante perdida o robo del equipo." }
        "BitLockerNetworkUnlock"          = @{ N = "Desbloqueo de Red BitLocker";                            D = "Desbloquea automaticamente unidades BitLocker al arrancar en una red corporativa confiable, sin PIN manual." }

        # ── Escritorio Remoto y Acceso Remoto ────────────────────────────────
        "MSRDC-Infrastructure"            = @{ N = "Infraestructura de Conexion a Escritorio Remoto";        D = "Componentes cliente de Escritorio Remoto (RDP): permite conectarse remotamente a otros equipos Windows." }
        "RasCMAK"                         = @{ N = "Kit de Administracion de Connection Manager (CMAK)";     D = "Herramienta para crear paquetes de perfil VPN/acceso remoto personalizados para distribuir a usuarios." }
        "WorkFolders-Client"              = @{ N = "Carpetas de Trabajo (Work Folders)";                     D = "Sincroniza automaticamente carpetas de trabajo desde un servidor corporativo al PC, similar a OneDrive empresarial." }
        "MultiPoint-Connector"            = @{ N = "Conector MultiPoint";                                    D = "Permite que este equipo sea gestionado por Windows MultiPoint Server para entornos educativos con multiples usuarios." }

        # ── Cola de mensajes (MSMQ) ──────────────────────────────────────────
        "MSMQ-Server"                     = @{ N = "Cola de Mensajes (MSMQ) - Servidor";                     D = "Microsoft Message Queuing: cola de mensajes para comunicacion asincrona y confiable entre aplicaciones distribuidas." }
        "MSMQ-Services"                   = @{ N = "Servicios de Cola de Mensajes (MSMQ)";                   D = "Servicios base de MSMQ para entrega garantizada de mensajes, incluso si el receptor esta temporalmente desconectado." }
        "MSMQ-Triggers"                   = @{ N = "MSMQ - Disparadores";                                    D = "Activa automaticamente aplicaciones o componentes COM cuando llegan mensajes a una cola MSMQ especificada." }
        "MSMQ-ADIntegration"              = @{ N = "MSMQ - Integracion con Active Directory";                D = "Registra colas MSMQ en Active Directory para que puedan ser descubiertas y aseguradas con Kerberos." }
        "MSMQ-HTTP"                       = @{ N = "MSMQ - Soporte HTTP";                                    D = "Permite enviar y recibir mensajes MSMQ a traves de HTTP/HTTPS, cruzando firewalls sin abrir puertos MSMQ." }
        "MSMQ-Multicast"                  = @{ N = "MSMQ - Multicast";                                       D = "Soporte para envio de mensajes MSMQ a multiples destinatarios simultaneamente via multicast IP." }

        # ── PowerShell ───────────────────────────────────────────────────────
        "MicrosoftWindowsPowerShellV2Root" = @{ N = "Motor de PowerShell 2.0 (Legacy)";                     D = "Motor de compatibilidad de PowerShell 2.0 para scripts que usan -Version 2. Se puede deshabilitar en sistemas modernos." }
        "MicrosoftWindowsPowerShellV2"    = @{ N = "PowerShell 2.0 - Nucleo (Legacy)";                      D = "Nucleo del motor de ejecucion de PowerShell 2.0. Raramente necesario con PowerShell 5.1 o superior instalado." }

        # ── Busqueda ─────────────────────────────────────────────────────────
        "SearchEngine-Client-Package"     = @{ N = "Windows Search (Motor de Busqueda e Indexacion)";       D = "Servicio de indexacion y busqueda rapida del sistema. Habilita busquedas instantaneas en menu inicio y Explorer." }

        # ── Administracion Remota (RSAT) ─────────────────────────────────────
        "RSAT"                            = @{ N = "Herramientas de Administracion Remota del Servidor";     D = "Suite completa de herramientas para administrar servidores Windows Server remotamente desde un PC cliente." }
        "RSAT-Role-Tools"                 = @{ N = "RSAT - Herramientas de Roles";                          D = "Herramientas graficas y PowerShell para administrar los distintos roles de Windows Server de forma remota." }

        # ── WAS (Windows Activation Services) ────────────────────────────────
        "WAS-ProcessModel"                = @{ N = "WAS - Modelo de Proceso";                                D = "Windows Process Activation Service: gestiona el inicio y reciclaje de procesos de trabajo para IIS y WCF." }
        "WAS-NetFxEnvironment"            = @{ N = "WAS - Soporte .NET";                                     D = "Extension de WAS para activar aplicaciones .NET Framework (WCF) sin necesidad de que IIS este instalado." }
        "WAS-ConfigurationAPI"            = @{ N = "WAS - API de Configuracion";                             D = "APIs de configuracion del servicio WAS. Necesario para configurar WAS programaticamente desde otras aplicaciones." }
    }

    # Cache de features para filtrado rapido sin volver a llamar a DISM
    $script:cachedFeatures = @()

    # ------------------------------------------------------------------
    # 4. Helper: poblar el ListView aplicando el filtro de busqueda
    # ------------------------------------------------------------------
    $PopulateList = {
        param($FilterText)
        $lv.BeginUpdate()
        $lv.Items.Clear()

        foreach ($feat in $script:cachedFeatures) {

            # Buscar en catalogo local primero; si no, usar DisplayName de DISM; si vacio, FeatureName
            $catalog     = $featureCatalog[$feat.FeatureName]
            $displayName = if ($catalog) {
                $catalog.N
            } elseif (-not [string]::IsNullOrWhiteSpace($feat.DisplayName)) {
                $feat.DisplayName
            } else {
                $feat.FeatureName
            }

            # Aplicar filtro — omitir si no coincide en nombre visible ni en nombre interno
            if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
                if ($displayName -notmatch $FilterText -and $feat.FeatureName -notmatch $FilterText) {
                    continue
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($displayName)

            # Forzar a string para evitar errores con el enum de DISM en WinForms
            $stateString  = $feat.State.ToString()
            $stateDisplay = $stateString
            $color        = [System.Drawing.Color]::White

            switch ($stateString) {
                "Enabled" {
                    $stateDisplay  = "Habilitado"
                    $color         = [System.Drawing.Color]::Cyan
                    $item.Checked  = $true
                }
                "Disabled" {
                    $stateDisplay  = "Deshabilitado"
                    $item.Checked  = $false
                }
                "DisabledWithPayloadRemoved" {
                    $stateDisplay  = "Removido (Requiere Source)"
                    $color         = [System.Drawing.Color]::Salmon
                    $item.Checked  = $false
                }
                "EnablePending" {
                    $stateDisplay  = "Pendiente (Habilitar)"
                    $color         = [System.Drawing.Color]::Yellow
                    $item.Checked  = $true
                }
                "DisablePending" {
                    $stateDisplay  = "Pendiente (Deshabilitar)"
                    $color         = [System.Drawing.Color]::Orange
                    $item.Checked  = $false
                }
                Default {
                    $stateDisplay = $stateString
                }
            }

            $item.SubItems.Add([string]$stateDisplay)     | Out-Null
            $item.SubItems.Add([string]$feat.FeatureName) | Out-Null
            $item.ForeColor   = $color

            # Tooltip: catalogo local > descripcion de DISM > aviso de ausencia
            $item.ToolTipText = if ($catalog -and $catalog.D) {
                $catalog.D
            } elseif (-not [string]::IsNullOrWhiteSpace($feat.Description)) {
                $feat.Description
            } else {
                "(Sin descripcion disponible)"
            }

            $item.Tag = $feat
            $lv.Items.Add($item) | Out-Null
        }
        $lv.EndUpdate()
    }

    # ------------------------------------------------------------------
    # 5. Eventos
    # ------------------------------------------------------------------

    # Carga inicial: obtener lista de features del WIM montado
    $form.Add_Shown({
        $form.Refresh()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
            & $PopulateList -FilterText ""

            $lblStatus.Text      = "Total: $($script:cachedFeatures.Count). Listo para filtrar o aplicar."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            $btnApply.Enabled    = $true
            $btnNetFx3.Enabled   = $true
        } catch {
            $lblStatus.Text      = "Error critico al leer features: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            Write-Log -LogLevel ERROR -Message "FEATURES_GUI: Error carga inicial: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Filtro de busqueda en tiempo real
    $txtSearch.Add_TextChanged({ & $PopulateList -FilterText $txtSearch.Text })

    # Boton INTEGRAR .NET 3.5 (SXS) con staging inteligente por arquitectura
    $btnNetFx3.Add_Click({
        $sxsPath = $null

        # 1. Busqueda automatica en la carpeta del script
        $pathLocal = Join-Path $PSScriptRoot "sxs"
        if (Test-Path $pathLocal) {
            $sxsPath = $pathLocal
        } else {
            # 2. Busqueda interactiva si no se encontro automaticamente
            $res = [System.Windows.Forms.MessageBox]::Show(
                "No se detecto la carpeta 'sxs' en la raiz del script automaticamente.`n`nDeseas seleccionarla manualmente?",
                "Buscar Origen (.NET 3.5)",
                'YesNo',
                'Question'
            )
            if ($res -eq 'Yes') {
                $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
                $fbd.Description = "Selecciona la carpeta 'sxs' (Puede ser la original del ISO de Windows)"
                if ($fbd.ShowDialog() -eq 'OK') { $sxsPath = $fbd.SelectedPath } else { return }
            } else { return }
        }

        if ($sxsPath) {
            # 3. Filtro inteligente de paquetes CAB
            $cabFiles = Get-ChildItem -Path $sxsPath -Filter "*netfx3*.cab" -ErrorAction SilentlyContinue

            if (-not $cabFiles -or $cabFiles.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    "No se encontro ningun paquete de .NET 3.5 (*netfx3*.cab) en la ruta seleccionada.`n`nPor favor verifica la carpeta.",
                    "Origen Invalido", 'OK', 'Warning')
                return
            }

            $form.Cursor       = [System.Windows.Forms.Cursors]::WaitCursor
            $btnNetFx3.Enabled = $false
            $btnApply.Enabled  = $false
            $lblStatus.Text      = "Aislando paquetes NetFx3 para instalacion rapida..."
            $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
            $form.Refresh()

            try {
                # Auto-deteccion de arquitectura de la imagen montada
                $imgArch = "amd64"
                if     (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32"))  { $imgArch = "arm64" }
                elseif (-not (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64"))) { $imgArch = "x86" }

                # A. Entorno esteril de staging en Scratch_DIR
                $isolatedSxs = Join-Path $Script:Scratch_DIR "NetFx3_Staging"
                if (Test-Path $isolatedSxs) { Remove-Item $isolatedSxs -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -Path $isolatedSxs -ItemType Directory -Force | Out-Null

                # B. Copiar solo los paquetes compatibles con la arquitectura destino
                $neutralCount = 0
                $langCount    = 0
                $skippedCount = 0

                foreach ($cab in $cabFiles) {
                    $cabName = $cab.Name.ToLower()
                    $include = $true

                    if ($cabName -match "~amd64~|~x86~|~arm64~") {
                        switch ($imgArch) {
                            "amd64" {
                                if ($cabName -notmatch "~amd64~|~x86~") { $include = $false }
                            }
                            "x86" {
                                if ($cabName -notmatch "~x86~") { $include = $false }
                            }
                            "arm64" { }
                        }
                    }

                    if (-not $include) {
                        $skippedCount++
                    } else {
                        Copy-Item -Path $cab.FullName -Destination $isolatedSxs -Force
                        if ($cab.Name -match "~~\.cab$") { $neutralCount++ } else { $langCount++ }
                    }
                }

                if ($neutralCount -eq 0) {
                    throw "Se filtraron los paquetes y no quedo ningun paquete base de .NET 3.5 compatible con la arquitectura de la imagen ($imgArch)."
                }

                Write-Log -LogLevel ACTION -Message "Smart SXS: Aislados $neutralCount neutros, $langCount idioma. Omitidos $skippedCount incompatibles."

                # C. Ejecutar DISM apuntando solo al directorio de staging
                $lblStatus.Text      = "Instalando .NET 3.5 ($imgArch)..."
                $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
                $form.Refresh()

                dism /Image:"$Script:MOUNT_DIR" /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:"$isolatedSxs" | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    $lblStatus.Text      = "Instalacion de .NET 3.5 exitosa."
                    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen

                    $msg = ".NET Framework 3.5 se integro correctamente.`n`nSe inyectaron:`n- $neutralCount Paquete(s) Base (Neutral)`n- $langCount Paquete(s) de Idioma (Satelite)"
                    [System.Windows.Forms.MessageBox]::Show($msg, "Exito", 'OK', 'Information')

                    $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
                    & $PopulateList -FilterText $txtSearch.Text
                } else {
                    $lblStatus.Text      = "Error al instalar .NET 3.5 (Codigo $LASTEXITCODE)."
                    $lblStatus.ForeColor = [System.Drawing.Color]::Red
                    [System.Windows.Forms.MessageBox]::Show("Fallo la instalacion.`nCodigo DISM: $LASTEXITCODE", "Error", 'OK', 'Error')
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Excepcion inesperada: $_", "Error", 'OK', 'Error')
            } finally {
                # D. Limpiar siempre el entorno de staging
                if (Test-Path $isolatedSxs) { Remove-Item $isolatedSxs -Recurse -Force -ErrorAction SilentlyContinue }
                $form.Cursor       = [System.Windows.Forms.Cursors]::Default
                $btnNetFx3.Enabled = $true
                $btnApply.Enabled  = $true
            }
        }
    })

    # Boton APLICAR CAMBIOS
    $btnApply.Add_Click({
        if ($txtSearch.Text.Length -gt 0) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "Filtro activo. Solo se procesaran elementos visibles.`nContinuar?",
                "Advertencia", 'YesNo', 'Warning')
            if ($res -ne 'Yes') { return }
        }

        $changes = 0
        $errors  = 0

        $form.Cursor       = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled  = $false
        $btnNetFx3.Enabled = $false

        foreach ($item in $lv.Items) {
            [System.Windows.Forms.Application]::DoEvents()

            $feat          = $item.Tag
            $originalState = $feat.State
            $isNowChecked  = $item.Checked

            $shouldEnable  = ($originalState -ne "Enabled" -and $isNowChecked)
            $shouldDisable = ($originalState -eq "Enabled" -and -not $isNowChecked)

            if ($shouldEnable -or $shouldDisable) {

                # GUARDIA: Prevenir Error 0x800f081f para features sin payload
                if ($shouldEnable -and $originalState -eq "DisabledWithPayloadRemoved") {
                    if ($feat.FeatureName -eq "NetFx3") {
                        [System.Windows.Forms.MessageBox]::Show(
                            "Para habilitar .NET Framework 3.5, por favor usa el boton azul dedicado 'INTEGRAR .NET 3.5 (SXS)'.",
                            "Aviso", 'OK', 'Information')
                    } else {
                        [System.Windows.Forms.MessageBox]::Show(
                            "La caracteristica '$($feat.FeatureName)' no se puede habilitar porque sus archivos fuente fueron eliminados de esta imagen (Payload Removed).`n`nOperacion omitida.",
                            "Archivos Faltantes", 'OK', 'Warning')
                    }
                    $item.Checked = $false
                    continue
                }

                $action = if ($shouldEnable) { "Enable" } else { "Disable" }

                $lblStatus.Text        = "Procesando ($action): $($feat.FeatureName). La ventana puede no responder..."
                $item.SubItems[1].Text = "PROCESANDO..."
                $item.ForeColor        = [System.Drawing.Color]::Yellow
                $item.EnsureVisible()
                $form.Refresh()
                [System.Windows.Forms.Application]::DoEvents()

                try {
                    Write-Log -LogLevel ACTION -Message "FEATURES: $action $($feat.FeatureName)"

                    if ($shouldEnable) {
                        Enable-WindowsOptionalFeature -Path $Script:MOUNT_DIR -FeatureName $feat.FeatureName -All -NoRestart -ErrorAction Stop | Out-Null
                        $item.SubItems[1].Text = "Habilitado"
                        $item.ForeColor        = [System.Drawing.Color]::Cyan
                        $feat.State            = "Enabled"
                    } else {
                        Disable-WindowsOptionalFeature -Path $Script:MOUNT_DIR -FeatureName $feat.FeatureName -NoRestart -ErrorAction Stop | Out-Null
                        $item.SubItems[1].Text = "Deshabilitado"
                        $item.ForeColor        = [System.Drawing.Color]::White
                        $feat.State            = "Disabled"
                    }
                    $changes++
                } catch {
                    $errors++
                    Write-Log -LogLevel ERROR -Message "Fallo $action feature $($feat.FeatureName): $($_.Exception.Message)"
                    $item.ForeColor        = [System.Drawing.Color]::Red
                    $item.SubItems[1].Text = "ERROR"
                }
            }
        }

        # Sincronizar cache si hubo cambios (flag -All puede haber habilitado dependencias)
        if ($changes -gt 0) {
            $lblStatus.Text = "Sincronizando estados dependientes desde la imagen..."
            $form.Refresh()
            try {
                $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
                & $PopulateList -FilterText $txtSearch.Text
            } catch {
                Write-Log -LogLevel WARN -Message "FEATURES: Fallo al recargar la cache post-aplicacion."
            }
        }

        $form.Cursor       = [System.Windows.Forms.Cursors]::Default
        $btnApply.Enabled  = $true
        $btnNetFx3.Enabled = $true
        $lblStatus.Text    = "Proceso finalizado."

        [System.Windows.Forms.MessageBox]::Show(
            "Operacion completada.`nCambios: $changes`nErrores: $errors",
            "Informe", 'OK', 'Information')
    })

	$form.Add_FormClosing({ 
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
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $script:cachedFeatures = $null
    [GC]::Collect()
}