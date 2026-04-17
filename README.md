# AdminImagenOffline V1.5.2 by SOFTMAXTER

<p align="center">
  <img width="250" height="250" alt="AdminImagenOffline Logo" src="https://github.com/user-attachments/assets/806cdf93-5a4d-41f1-9d0d-372882c4afcc" />
</p>

**AdminImagenOffline** es un completo script orquestador en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd`, `.vhdx`). El script encapsula complejas operaciones de `DISM`, manipulación del Registro a bajo nivel y otras herramientas del sistema en una suite de menús interactivos y GUIs fáciles de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente, segura y sin conexión.

## Características Principales

* **Interfaz Híbrida (Consola + GUI)**: Combina la fluidez de la consola para operaciones de orquestación con interfaces gráficas (Windows Forms) modernas e intuitivas para la gestión de drivers, servicios, bloatware, despliegue, metadatos y registro.
* **Auto-Actualizador Inteligente**: El script busca automáticamente nuevas versiones en el repositorio de GitHub al iniciar y ofrece una actualización transparente (en caliente) mediante un módulo externo seguro.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que tus preferencias de entorno sean permanentes.
* **Robustez y Seguridad de Grado Empresarial**:
    * **Protección de Hives (Registro)**: Implementa limpieza profunda de memoria en .NET (`GC::Collect()`) y pausas de seguridad para evitar la corrupción de las colmenas del registro al desmontar. Se mantiene la herencia (SDDL) de forma quirúrgica.
    * **Motor de Arquitectura (Escudo)**: Previene la inyección accidental de paquetes o drivers incompatibles (ej. x86 en x64) analizando heurísticamente los nombres y manifiestos.
    * **Logging Detallado**: Sistema de reporte de errores rotativo con "Stack Trace" completo para facilitar el diagnóstico de fallos críticos, guardado en la carpeta `Logs`.
    * **Saneamiento Automático**: Limpieza proactiva del directorio temporal (`Scratch_DIR`) para evitar errores de espacio o archivos bloqueados/corruptos (Error C1420116).
    * **Tablero de Estado (Dashboard)**: Muestra en tiempo real la información de la imagen montada (Nombre, Versión, Build, Arquitectura, Directorio y Estado) en el menú principal.
* **Detección y Auto-Montaje Automático**: Verifica al iniciar si ya existe una imagen montada en el sistema (incluyendo discos virtuales VHD/VHDX) y carga su información dinámicamente, permitiendo recuperar sesiones tras cierres inesperados.
* **Gestión de Imágenes**: Montaje, desmontaje (con o sin descartes), guardado de cambios (commit/append/guardar como nuevo WIM) y recarga rápida. Soporte completo para montar y editar archivos **VHD/VHDX** con guardado en tiempo real (Live Edit).
* **Editor de Metadatos WIM**: Interfaz gráfica dedicada para editar el Nombre, Descripción, Nombre Mostrado y el ID de Edición de los índices de una imagen WIM (usando motor nativo C# vía P/Invoke sobre `wimgapi.dll`).
* **Gestión de Idiomas (OSD Offline)**: Asistente automatizado para inyectar paquetes de idioma (LP), características bajo demanda (FOD) y paquetes de experiencia local (LXP). Procesa secuencialmente WinRE, el sistema operativo (`install.wim`) y el instalador (`boot.wim`), regenerando `lang.ini` y optimizando el tamaño final.
* **Herramientas de Arranque y Medios**:
    * **Gestor Inteligente de boot.wim**: Herramienta dedicada para detectar y montar el instalador (Setup) o el entorno de rescate (WinPE) para inyectar utilidades extra (DaRT) y drivers de almacenamiento (VMD/RAID).
    * **Despliegue a VHD / Disco Físico**: Crea discos virtuales o unidades USB/HDD arrancables desde un WIM o ESD, configurando particiones de forma automatizada (GPT/UEFI o MBR/BIOS) y aplicando el sector de arranque.
    * **Generador de ISO**: Crea imágenes ISO arrancables (Legacy/UEFI) utilizando `oscdimg`, leyendo la etiqueta oficial de la imagen e inyectando opcionalmente archivos de respuesta desatendidos (`autounattend.xml`).
* **Conversión de Formatos**: Transformación de compresión sólida (ESD a WIM) y captura de volúmenes virtuales (VHD/VHDX a WIM) con auto-detección de la partición del sistema operativo.
* **Cambio de Edición de Windows**: Detección y escalado de edición (ej. Home a Pro, Pro a Workstation) offline con advertencias críticas de seguridad al operar sobre VHDs.
* **Gestión Avanzada de Drivers (GUI)**:
    * **Inyector Flexible**: Interfaz que permite cargar carpetas recursivamente o archivos `.inf` individuales. Compara la caché de la imagen para omitir drivers ya instalados (Amarillo = Ya instalado | Blanco = Nuevo).
    * **Desinstalador de Drivers**: Lista los controladores de terceros (OEM) instalados en la imagen base y permite su purga selectiva y segura.
* **Centro de Personalización Completa**:
    * **Eliminación de Bloatware**: Interfaz gráfica con clasificación por categorías (Verde=Sistema Vital, Naranja=Bloatware) para purgar aplicaciones Appx/MSIX preinstaladas.
    * **Gestor de Características (Features)**: Interfaz para activar/desactivar características opcionales de Windows (Hyper-V, SMB, WSL). Incluye motor de *Staging* inteligente para la **integración offline de .NET 3.5** filtrando paquetes `.cab` por arquitectura desde la carpeta `sxs`.
    * **Optimización de Servicios**: Interfaz por pestañas para deshabilitar servicios innecesarios (Telemetría, Xbox, Red) modificando directamente las colmenas. Incluye función de **Restauración** a valores de fábrica.
    * **Tweaks y Registro Offline**: 
        * Gestor visual para aplicar docenas de ajustes predefinidos de rendimiento y privacidad. 
        * **Importador .REG Inteligente**: Traducción al vuelo de rutas online (`HKCU`, `HKLM\Software`) a colmenas offline, con vista previa de cambios (`Modo Turbo .NET`), creación de perfiles y procesamiento en lote (Queue Manager).
    * **Inyector de Apps Modernas (Heurístico)**: Aprovisionamiento de aplicaciones UWP (`.appx`, `.appxbundle`) analizando el manifiesto XML en RAM para resolver dependencias y licencias automáticamente.
    * **Automatización OOBE (Unattend.xml)**: Generador avanzado para saltar las pantallas de configuración. Incluye:
        * Creación de cuenta de Administrador Local y AutoLogon.
        * **Hacks Win11**: Inyecta claves para eludir TPM, SecureBoot y RAM.
        * **Privacidad y Red**: Instalación sin internet (BypassNRO), omisión de WiFi, desactivación de telemetría y Cortana en el primer inicio.
        * Importación y validación de XML externos.
    * **Inyector de Addons**: Integración masiva de paquetes de terceros (`.wim`, `.tpk`, `.bpk`, `.reg`) con ordenamiento automático por prioridad y filtrado de arquitectura.
    * **Gestión de WinRE**: Entorno para extraer, montar, inyectar componentes y recomprimir agresivamente (`/Export-Image`) el entorno de recuperación para ahorrar espacio.
    * **OEM Branding**: Personaliza el fondo de escritorio (Wallpaper), la pantalla de bloqueo (Lockscreen), el Tema Visual (Claro/Oscuro vía RunOnce) e inyecta los datos de soporte del ensamblador (Fabricante, Modelo, Web).
* **Suite de Limpieza y Reparación**: Diagnóstico (`CheckHealth`, `ScanHealth`), Reparación (`RestoreHealth` con fallback a fuente WIM local), `SFC` offline y limpieza del almacén de componentes (`ResetBase`).

---

## Requisitos del Sistema

* Sistema Operativo Windows 10 / 11 Pro / Enterprise (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador (Elevación UAC).
* Módulo de Hyper-V habilitado (Obligatorio para operaciones de montaje de VHD/VHDX).
* **[Windows Assessment and Deployment Kit (ADK)](https://learn.microsoft.com/es-es/windows-hardware/get-started/adk-install) (CRÍTICO):** Instalado en el sistema, o en su defecto, contar con el ejecutable `oscdimg.exe` en la carpeta `Tools`. Esta dependencia es estrictamente necesaria para generar ISOs y sus complementos (`WinPE_OCs`) son indispensables para la inyección de idiomas en entornos de rescate.
* Conexión a internet (Opcional, exclusivamente para el auto-actualizador de GitHub).

---

## Modo de Uso y Estructura

1.  Descarga el repositorio como un archivo `.zip` y extráelo en una ruta corta (ej. `C:\AdminImagen`).
2.  Asegúrate de mantener la integridad de la estructura de directorios:
    ```text
    TuCarpetaPrincipal/
    │
    ├── AdminImagenOffline.exe    <-- Ejecutable Lanzador (Reemplaza al antiguo Run.bat)
    ├── Tools/
    └── Script/
        │
        ├── AdminImagenOffline.ps1
        ├── Modulo-Appx.ps1
        ├── Modulo-DeployVHD.ps1
        ├── Modulo-Drivers.ps1
        ├── Modulo-Features.ps1
        ├── Modulo-Idioma.ps1
        ├── Modulo-IsoMaker.ps1
        ├── Modulo-Metadata.ps1
        ├── Modulo-OEMBranding.ps1
        ├── Modulo-Unattend.ps1
        └── Catalogos/
            ├── Ajustes.ps1
            ├── Servicios.ps1
            └── Bloatware.ps1
    ```
3.  Haz doble clic en **`AdminImagenOffline.exe`**. El lanzador solicitará permisos de Administrador y preparará el entorno de PowerShell con las políticas de ejecución correctas.
4.  Si es la primera ejecución, ve al menú **[8] Configuración** para definir tus directorios de trabajo permanente (`MOUNT_DIR` y `Scratch_DIR`). Se recomienda usar rutas lo más cortas posibles (ej. `C:\Mount`) para evitar el límite de 260 caracteres de la API de Windows durante las extracciones.


---

## Arquitectura y Explicación Detallada de Funciones

A diferencia de scripts tradicionales, AdminImagenOffline opera mediante un motor central que carga dinámicamente submódulos y gestiona bloqueos de memoria (`Garbage Collection`) para evitar la corrupción de la imagen. A continuación, se detalla la lógica interna de cada componente principal:

### 1. Motor Central de Montaje y Estado Global
El núcleo del script maneja el ciclo de vida del montaje, protegiendo contra cierres inesperados y bloqueos de archivos.

* **`Check-And-Repair-Mounts`**: Función de seguridad forense. Detecta si un montaje previo quedó huérfano (ej. por un apagón) leyendo el estado `Needs Remount` o `Invalid` en DISM, ofreciendo recuperación interactiva o limpieza (`/Cleanup-Wim`).
* **`Select-WindowsMediaSource`**: Gestor de extracción de ISOs. Monta una ISO virtualmente, extrae el contenido usando `Robocopy` (para máxima velocidad y evasión de permisos) y normaliza los atributos de solo lectura.
* **`Mount-Image`**: Enrutador de montaje.
    * **Modo WIM/ESD:** Ejecuta el montaje estándar de DISM.
    * **Modo VHD/VHDX:** Utiliza el motor de Hyper-V (`Mount-VHD`). Implementa un escaneo heurístico de particiones asignando letras de unidad dinámicas (en el rango seguro Z: a F:) para localizar el árbol `\Windows\System32\config\SYSTEM`, garantizando que se monte la partición correcta del sistema operativo.
* **`Unmount-Image`**: Cierre blindado. Antes de llamar a DISM para hacer `/Commit` (guardar) o `/Discard`, fuerza un `Unmount-Hives` y dispara múltiples pases del Recolector de Basura (`[GC]::Collect()`) para liberar *handles* retenidos por la API COM de .NET, previniendo errores `C1420116` (Directorio en uso).

### 2. Conversión y Gestión de Índices
Herramientas para manipular la estructura interna de los contenedores de despliegue.

* **`Convert-ESD`**: Transforma compresión sólida (ESD) a estándar (WIM) extrayendo el índice seleccionado. Vital, ya que DISM prohíbe la edición directa sobre archivos `.esd`.
* **`Convert-VHD`**: Ingeniería de captura. Monta un disco virtual *sin* asignar letra automática (`-NoDriveLetter`) para evitar condiciones de carrera con el Plug & Play de Windows. Ubica la partición del SO, ejecuta `Optimize-Volume -ReTrim` para eliminar bloques vacíos, y captura el estado a un archivo `.wim` ultra-comprimido.
* **`Export-Index` / `Delete-Index`**: Wrappers seguros para extraer ediciones específicas (ej. aislar Windows 10 Pro) o purgar índices no deseados para reducir el tamaño del contenedor base.

### 3. Gestor Avanzado del Entorno de Recuperación y Arranque
Módulos críticos para manipular los entornos de preinstalación (`WinPE`).

* **`Manage-WinRE-Menu`**: 
    1.  Extrae físicamente `winre.wim` de la ruta `Windows\System32\Recovery`.
    2.  Respalda sus atributos y ACLs originales (propiedad de TrustedInstaller).
    3.  Despliega un entorno de montaje anidado (Staging) permitiendo inyectar drivers (ej. Intel VMD/RAID) o herramientas (DaRT).
    4.  Al guardar, ejecuta una *recompresión extrema* usando `/Export-Image /Bootable` para reconstruir el diccionario WIM, reduciendo significativamente el peso muerto antes de reinyectarlo en el SO base.
* **`Manage-BootWim-Menu`**: Analiza `boot.wim` separando heurísticamente el índice de Setup (Instalador) del índice WinPE (Rescate). Permite inyectar controladores de almacenamiento masivo vitales para que el instalador reconozca discos NVMe modernos.

### 4. Motor de Registro Offline (El Core Arquitectónico)
El componente técnico más avanzado. Evade las limitaciones de `Set-ItemProperty` que suelen corromper las colmenas.

* **`Mount-Hives` / `Unmount-Hives`**: Carga las colmenas físicas (`SYSTEM`, `SOFTWARE`, `COMPONENTS`, `NTUSER.DAT`) en ramales temporales (`HKLM\OfflineSystem`, etc.).
* **`Translate-OfflinePath`**: Traductor en tiempo real. Redirige automáticamente rutas estándar escritas por usuarios (ej. `HKCU\Software` o `HKCR`) a sus respectivas colmenas temporales físicas (`HKLM\OfflineUser`, `HKLM\OfflineSoftware\Classes`), detectando el `ControlSet` activo de manera dinámica.
* **`Unlock-Single-Key` / `Restore-KeyOwner`**: **Blindaje de Permisos (SDDL).** Toma posesión de claves protegidas por el sistema utilizando la API de bajo nivel de .NET (`[System.Security.AccessControl]`). Antes de modificar, respalda el descriptor de seguridad original (SDDL) en RAM (`$Script:SDDL_Backups`), y tras la inyección, restaura quirúrgicamente la propiedad a `TrustedInstaller` o `SYSTEM`, garantizando que el sistema operativo no se rompa al arrancar.
* **`Import-OfflineReg`**: Inyector *headless* de archivos `.reg`. Limpia cabeceras, traduce las rutas masivamente, evade Hives bloqueados (SAM, SECURITY) para prevenir corrupción, y aplica los cambios usando una instancia silenciosa de `reg.exe` conectada a un buffer asíncrono para captura de errores.

### 5. Inyector de Addons (Carga Útil)
* **`Show-Addons-GUI` / `Install-OfflineAddon`**: Motor de inyección de software de terceros.
    * **Ordenamiento Heurístico:** Clasifica la inyección leyendo sufijos (`_main.tpk` se instala antes que paquetes de idioma o parches de registro).
    * **Escudo de Arquitectura:** Detecta si la imagen destino es `x64` o `x86` y omite automáticamente paquetes marcados con el sufijo incorrecto (ej. `_x86.tpk` en un Windows de 64 bits), evitando BSODs.
    * **Inyección Robocopy:** Utiliza `robocopy /B` (Backup Mode) para inyectar archivos esquivando los bloqueos NTFS de Windows, fusionando directorios sin alterar ACLs.

### 6. Módulos de Personalización (Catálogos y GUIs)
Interfaces gráficas que cargan diccionarios de datos (`.ps1`) para manipular la imagen.

* **`Show-Bloatware-GUI`**: Lee los paquetes aprovisionados (Appx) y los cruza con listas blancas/negras predefinidas. Permite la purga masiva de telemetría y apps basura a nivel contenedor (impidiendo que se instalen en los nuevos usuarios).
* **`Show-Services-Offline-GUI`**: Mapea servicios del sistema clasificados por impacto. Modifica los estados de arranque (`Start = 4` para deshabilitar) directamente en la colmena offline, incluyendo un botón de "Restauración SDDL" para devolver los servicios a su estado de fábrica.
* **`Show-Tweaks-Offline-GUI`**: Aplica configuraciones avanzadas (rendimiento, privacidad, UI). Su motor de inyección realiza conversiones de tipo estrictas (ej. forzando arreglos de bytes nativos mediante `[BitConverter]`) evadiendo el desbordamiento aritmético natural de PowerShell al manejar `DWord` o `QWord` de gran tamaño.
* **`Show-RegQueue-GUI`**: Procesador por lotes (Batch) para archivos de registro. Fusiona múltiples `.reg` en un solo archivo maestro en memoria, aplica la traducción de rutas global y realiza una única transacción de desbloqueo e inyección para máximo rendimiento.

### 7. Mantenimiento y Limpieza de Imagen
Rutinas escalonadas para el saneamiento del contenedor.

* **`Limpieza-Menu`**: Orquesta comandos de salud de DISM (`CheckHealth`, `ScanHealth`).
    * **Fallback Inteligente:** Si `RestoreHealth` falla por falta de archivos (`Error 0x800f081f`), solicita una ISO/WIM de origen e intenta la reparación forzando el modo `/LimitAccess`.
    * **SFC Offline:** Ejecuta el Comprobador de Archivos de Sistema dirigiendo los parámetros `/offbootdir` y `/offwindir` al punto de montaje temporal.
    * **Component Store Cleanup:** Elimina actualizaciones superadas. Opcionalmente ejecuta `/ResetBase` para comprimir la imagen al máximo, rompiendo la retro-compatibilidad de desinstalación de parches antiguos.

---

## Notas de Seguridad y Mejores Prácticas

* **ANTIVIRUS / WINDOWS DEFENDER:** Durante las operaciones de guardado (`Commit`) o inyección masiva, los antivirus pueden bloquear temporalmente los archivos de la imagen, causando que DISM falle con errores de acceso (C1420116). Se recomienda pausar la protección en tiempo real o agregar exclusiones a tus carpetas de montaje temporal.
* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad física de tu archivo `.wim` / `.vhdx` antes de aplicar cambios de edición, limpieza profunda (`ResetBase`) o inyecciones masivas de registro.
* **DISCOS VIRTUALES (VHD):** Los cambios sobre VHD/VHDX montados a través del script **se aplican instantáneamente en el disco duro**. A diferencia de los WIM, no puedes "Descartar" los cambios simplemente desmontando.
* **IDIOMA:** El script, sus catálogos y sus mensajes de consola están íntegramente en español.

---

## ☕ Apoya el Proyecto

AdminImagenOffline es una herramienta de grado empresarial desarrollada y mantenida para facilitar la ingeniería de sistemas. Si esta suite te ha ahorrado horas de trabajo empaquetando software, depurando imágenes WIM o ha mejorado tus despliegues corporativos, considera apoyar su desarrollo para garantizar actualizaciones continuas frente a las nuevas iteraciones de Windows.

* [💳 Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=U65G2GXDTUGML)

## Descargo de Responsabilidad

Este software realiza operaciones avanzadas de bajo nivel que modifican archivos de imagen base de Windows, manipulan permisos SDDL y alteran las colmenas del registro del sistema. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos, corrupción de sistemas operativos host o daños que puedan ocurrir derivados del mal uso de esta herramienta. 

**Úsalo bajo tu propio riesgo y siempre en entornos de prueba antes de su paso a producción.**

## Autor y Colaboradores

* **Autor Principal**: SOFTMAXTER
* **Colaboradores**: [LatinserverEc](https://github.com/LatinserverEc) (Gracias por el Feedback y el testing continuo).
* **Análisis y refinamiento de código**: Realizado en colaboración con inteligencia artificial para garantizar máxima calidad, seguridad SDDL, optimización de algoritmos y transición integral a interfaces gráficas nativas de Windows Forms.

---

### Cómo Contribuir

Si deseas contribuir al código fuente de este proyecto:

1.  Haz un Fork del repositorio.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Realiza tus cambios asegurándote de no romper las llamadas a módulos en el orquestador principal (`git commit -am 'Añade nueva funcionalidad'`).
4.  Haz Push a la rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request.

---
## 📝 Licencia y Modelo de Negocio (Dual Licensing)

Este proyecto está protegido bajo derechos de autor y utiliza un modelo de **Doble Licencia (Dual Licensing)**:

### 1. Licencia Comunitaria (Open Source)
Distribuido bajo la **Licencia GNU GPLv3**. Eres libre de usar, modificar y compartir este software en entornos personales o académicos. Bajo esta licencia (*Copyleft*), cualquier herramienta derivada o script que integre código o módulos de AdminImagenOffline **debe ser obligatoriamente de código abierto** y distribuirse bajo la misma licencia.

### 2. Licencia Comercial Corporativa
Si deseas integrar el motor, las interfaces o los algoritmos de heurística de esta suite en un producto comercial propietario (closed-source), o requieres Acuerdos de Nivel de Servicio (SLA) y soporte dedicado para tu corporación, **debes adquirir una Licencia Comercial**. 

Para consultas sobre licenciamiento corporativo, por favor contactar a: `(softmaxter@hotmail.com)`
