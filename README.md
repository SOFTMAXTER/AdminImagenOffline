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

## 🚀 Configuración Inicial

Al iniciar el script por primera vez, se te pedirá configurar dos directorios críticos (estas rutas se guardan en `config.json`):
1. **Directorio de Montaje (`MOUNT_DIR`):** Carpeta vacía (ej. `C:\TEMP`) donde se desempaquetará la imagen de Windows para su edición.
2. **Directorio Temporal (`Scratch_DIR`):** Espacio de trabajo para DISM (ej. `C:\Scratch`). Se recomienda usar rutas cortas para evitar el límite de 260 caracteres de Windows al extraer paquetes profundos.

---

## 📖 Guía Detallada del Menú Principal y Módulos

A continuación se desglosan las opciones del menú principal, explicando la lógica técnica y cómo utilizar cada módulo de la suite.

### [ 1 ] Gestión de Imagen
Este es el núcleo de la herramienta. Controla el ciclo de vida del montaje de la imagen.

* **Montar Imagen:** Te permite seleccionar un archivo `.wim`, `.esd` (solo lectura/exportación) o disco virtual (`.vhd`/`.vhdx`). 
  * *Novedad:* Puedes elegir **"Extraer desde una ISO"**. El script montará la ISO, vaciará de forma segura una carpeta de extracción temporal y volcará el contenido usando `Robocopy` a máxima velocidad.
  * *Discos Virtuales (VHD):* Si seleccionas un VHD, el script hace un escaneo inteligente saltándose las particiones EFI/Recovery, encuentra la partición de Windows, le asigna una letra de unidad dinámica y la monta. **Importante:** Los cambios en un VHD se guardan en tiempo real.
* **Desmontar / Guardar Cambios (Commit):** * Si usas WIM, la opción *Commit* re-comprimirá los cambios en el archivo.
  * Si hay bloqueos de registro, el script fuerza un `[GC]::Collect()` (Recolección de basura en .NET) para liberar *handles* huérfanos antes de desmontar, evitando corrupciones.
* **Editar Metadatos:** Cambia el nombre interno y la descripción de la imagen (ej. de "Windows 10 Pro" a "Mi Custom OS").
* **Editar Índices:** Permite Exportar un índice específico para crear una imagen más ligera o Eliminar índices que no necesitas permanentemente.

### [ 2 ] Convertir Formatos
Herramientas de conversión e ingesta de imágenes.

* **Convertir ESD a WIM:** Los archivos `.esd` tienen compresión sólida y no pueden ser modificados directamente. Esta opción extrae un índice del ESD y lo convierte a formato `.wim` estándar para su posterior montaje y edición.
* **Convertir VHD/VHDX a WIM:** Monta un disco virtual silenciosamente, detecta la partición del sistema operativo, le aplica un *Trim* (Optimización) si es posible, y captura todo el volumen hacia un archivo `.wim` usando compresión máxima.

### [ 3 ] Herramientas de Arranque y Medios (Boot Tools)
Para modificar el entorno de preinstalación y generar medios.

* **Editar boot.wim:** Monta el motor de instalación de Windows. El script detecta automáticamente el índice de *Windows PE* (para crear Live USB de rescate) y el índice de *Setup* (para el instalador). Es vital para inyectar *Drivers* de almacenamiento (VMD/Raid/Intel RST) para que el instalador reconozca discos duros modernos.
* **Crear ISO Booteable:** Toma tu carpeta de extracción y empaqueta una ISO lista para Rufus o Ventoy.
* **Despliegue a VHD:** Aplica tu WIM personalizado directamente a un disco físico (USB) o disco virtual.

### [ 4 ] Drivers (Inyectar / Eliminar)
Gestión completa de los controladores *offline*.

* **Inyectar Drivers:** Selecciona una carpeta con archivos `.inf`. El motor de DISM inyectará los controladores en el almacén del sistema. Ideal para integrar drivers de red o video antes de instalar.
* **Desinstalar Drivers:** Interfaz gráfica que lista todos los controladores de terceros (OEM) instalados en la imagen montada, permitiendo eliminarlos selectivamente.

### [ 5 ] Centro de Personalización y Ajustes (Ingeniería del Sistema)
El módulo más potente de la suite, estructurado en múltiples interfaces gráficas (GUI).

1. **Eliminar Bloatware (Apps):** * **Uso:** Abre una interfaz que escanea las `AppxProvisionedPackages`. 
   * **Lógica:** Compara las apps contra listas blancas y negras (`Bloatware.ps1`). Te permite marcar la "basura" (Xbox, Solitario, Bloatware OEM) y eliminarla en lote. Tiene un "Escudo" que oculta apps vitales (Calculadora, Store, VCLibs) a menos que actives el modo avanzado.
2. **Características y .NET 3.5:** Activa o desactiva funciones nativas (Hyper-V, SMB 1.0, WSL) o inyecta el paquete de compatibilidad de .NET 3.5 si proporcionas la carpeta `sxs`.
3. **Servicios del Sistema:**
   * **Uso:** Interfaz por pestañas que carga la colmena (`Hive`) del registro `SYSTEM` en memoria.
   * **Lógica:** Permite apagar servicios pesados (SysMain/Superfetch, Indexación, Xbox) de forma segura. Si modificas un servicio, el script realiza el cambio evadiendo restricciones, pero guarda el objeto original para permitirte usar el botón **"RESTAURAR ORIGINALES"** en cualquier momento.
4. **Tweaks y Registro:** * **Ajustes Nativos:** Aplica mejoras de rendimiento y privacidad (Desactivar Telemetría, Cortana, Optimizar NTFS) definidas en `Ajustes.ps1`. Utiliza inyección de datos `.NET` estricta (`BitConverter`) para evitar desbordamientos de datos DWORD en PowerShell.
   * **Importador .REG en Lote:** Permite encolar múltiples archivos `.reg`. El motor fusiona el texto, traduce dinámicamente las rutas (ej. convierte `HKCU` en `HKLM\OfflineUser`), respalda los permisos nativos (SDDL) de *TrustedInstaller*, inyecta los datos de forma silenciosa y luego restaura la herencia de permisos para no romper la seguridad de Windows.
5. **Inyector de Apps Modernas (Appx/MSIX):** Aprovisiona aplicaciones universales descargadas manualmente.
6. **Automatización OOBE (Unattend.xml):** Aplica archivos de respuestas para automatizar la instalación de Windows (saltar preguntas de privacidad, crear cuentas de usuario automático).
7. **Inyector de Addons (.wim, .tpk, .bpk, .reg):**
   * **Uso:** Integra paquetes de utilidades (7-Zip, Visual C++, etc.).
   * **Lógica Inteligente:** Si incluyes sufijos en el nombre del archivo (ej. `_x64`, `_x86`), el motor activa el **Escudo de Arquitectura** y omitirá los paquetes que no coincidan con la arquitectura de la imagen montada. Si usas `_main`, les dará prioridad de inyección en la cola. Extrae los empaquetados usando firma binaria para evitar fallos.
8. **Gestionar WinRE (Entorno de Recuperación):**
   * **Lógica:** Va a `Windows\System32\Recovery`, extrae el `winre.wim`, lo monta en el *Scratch*, permite inyectar DaRT o Drivers, y al guardar, utiliza `/Export-Image /Bootable` para destruir los diccionarios viejos y recomprimir el entorno, ahorrando cientos de megabytes de "peso muerto".
9. **OEM Branding:** Personaliza fondos de pantalla predeterminados, la pantalla de bloqueo y la información del fabricante (Logo, Soporte) en las propiedades del sistema.

### [ 6 ] Limpieza y Reparación (DISM/SFC)
Mantenimiento de la integridad de la imagen.

* **CheckHealth / ScanHealth:** Verifica daños en el almacén de componentes.
* **Reparar Imagen (RestoreHealth):** Si la imagen está corrupta, intenta repararla. Si falla, el script despliega un protocolo de emergencia (*Fallback*) que te pedirá un `install.wim` sano para usarlo como fuente de reparación (`/LimitAccess`).
* **SFC Offline:** Ejecuta el comprobador de archivos del sistema apuntando a la unidad montada.
* **Limpiar Componentes (StartComponentCleanup):** Pule el tamaño de la imagen borrando actualizaciones obsoletas. Te preguntará si deseas usar `/ResetBase` (mayor compresión, pero impide desinstalar actualizaciones previas).

### [ 7 ] Cambiar Edición
Permite actualizar la versión de Windows (ej. de `Home` a `Professional` o `Enterprise LTSC`).
* **Nota Técnica:** El script consulta las ediciones de destino viables (`Get-TargetEditions`). Esta operación en archivos WIM es reversible si no se guardan los cambios, pero en un **VHD** es un proceso destructivo e irreversible en tiempo real. El script mostrará una advertencia de seguridad roja si intentas hacer esto sobre un disco virtual.

### [ 8 ] Gestión de Idiomas
Permite inyectar *Language Packs* (LP), *Features on Demand* (FOD) y *Local Experience Packs* (LXP) para cambiar el idioma base del instalador y del sistema operativo.

---

## 🛡️ Notas Técnicas y Seguridad

* **Manejo de Hives (Colmenas de Registro):** AdminImagenOffline no usa comandos frágiles para modificar el registro. Levanta las colmenas físicas (`SYSTEM`, `SOFTWARE`, `NTUSER.DAT`) como variables virtuales, aplica permisos administrativos temporales, escribe y las descarga. Si fuerzas el cierre de la ventana, el evento `$OnExitScript` atrapará la señal de muerte e intentará desmontar el registro para evitar pantallas azules (BSOD) en tu imagen.
* **Recuperación de Sesión:** Si la PC se apaga bruscamente o un antivirus bloquea un montaje, la próxima vez que abras el script, detectará el montaje "Fantasma" o el estado "Needs Remount" y te ofrecerá una recuperación guiada o limpieza forzada del entorno.

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
