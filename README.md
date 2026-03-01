# AdminImagenOffline V1.5.0 by SOFTMAXTER

**AdminImagenOffline** es un completo script en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM`, manipulación del Registro y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Híbrida (Consola + GUI)**: Combina la rapidez de la consola para operaciones básicas con interfaces gráficas (Windows Forms) modernas para la gestión de drivers, servicios, bloatware, despliegue, metadatos y registro.
* **Auto-Actualizador**: El script busca automáticamente nuevas versiones en GitHub al iniciar y ofrece al usuario la posibilidad de actualizarse mediante un módulo externo seguro.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que las preferencias del usuario sean permanentes.
* **Robustez y Seguridad**:
    * **Protección de Hives**: Implementa limpieza de memoria (`GC`) y pausas de seguridad para evitar la corrupción del registro al desmontar. Se mantiene la herencia (SDDL) de forma quirúrgica.
    * **Logging Detallado**: Sistema de reporte de errores con "Stack Trace" completo para facilitar el diagnóstico de fallos críticos en la carpeta `Logs`.
    * **Saneamiento Automático**: Limpieza proactiva del directorio temporal (`Scratch`) al inicio para evitar errores de espacio o archivos corruptos.
    * **Tablero de Estado (Dashboard)**: Muestra en tiempo real la información de la imagen montada (Nombre, Versión, Arquitectura, Directorio) en el menú principal.
* **Detección Automática**: Verifica al inicio si ya existe una imagen montada en el sistema (WIM o VHD) y carga su información dinámicamente.
* **Gestión de Imágenes**: Montaje, desmontaje (con descartes), guardado de cambios (commit/append/guardar como nuevo WIM) y recarga rápida. Soporte completo para montar y editar archivos **VHD/VHDX** directamente.
* **Editor de Metadatos WIM**: Interfaz gráfica dedicada para editar el Nombre, Descripción y Nombre Mostrado de los índices de una imagen WIM (usando motor nativo C#).
* **Gestión de Idiomas (OSD Offline)**: Asistente automatizado para inyectar paquetes de idioma (LP), características bajo demanda (FOD) y paquetes de experiencia local (LXP) procesando en secuencia WinRE, el sistema operativo (Install.wim) y el instalador (Boot.wim), regenerando `lang.ini`.
* **Herramientas de Arranque y Medios**:
    * **Editar boot.wim**: Herramienta dedicada para montar el instalador o el entorno de rescate (WinPE) para inyectar paquetes (DaRT) y drivers de forma aislada.
    * **Despliegue a VHD**: Herramienta para crear discos virtuales arrancables desde un WIM, configurando particiones (GPT/UEFI o MBR/BIOS) automáticamente.
    * **Generador de ISO**: Crea imágenes ISO arrancables (Legacy/UEFI) utilizando `oscdimg`, con soporte para inyección automática de archivos desatendidos.
* **Conversión de Formatos**: ESD a WIM y VHD/VHDX a WIM (con auto-detección de la partición del sistema).
* **Cambio de Edición de Windows**: Detección y cambio de edición (ej. Home a Pro) offline con advertencias de seguridad para VHDs.
* **Gestión Avanzada de Drivers**:
    * **Inyector Flexible**: Interfaz que permite cargar carpetas recursivamente o agregar archivos `.inf` individuales. Incluye detección precisa por **Versión** y **Clase** para evitar duplicados.
    * **Desinstalador de Drivers**: Lista los drivers de terceros (OEM) instalados en la imagen y permite su eliminación selectiva.
* **Personalización Completa**:
    * **Eliminación de Bloatware**: Interfaz gráfica con clasificación por colores para eliminar aplicaciones preinstaladas (Appx).
    * **Gestor de Características (Features)**: Habilita o deshabilita componentes de Windows. Incluye botón dedicado para la **integración offline de .NET 3.5** mediante la carpeta `sxs`.
    * **Optimización de Servicios**: Permite deshabilitar servicios del sistema innecesarios organizados por categorías. Incluye función para **Restaurar** valores originales.
    * **Tweaks y Registro Offline**: Gestor nativo para aplicar ajustes de rendimiento y privacidad. Incluye un **Importador .REG Inteligente** con traducción automática de rutas, vista previa y un **Gestor de Cola** para aplicar lotes y guardar/cargar perfiles de usuario.
    * **Inyector de Apps Modernas**: Aprovisionamiento de aplicaciones UWP (Appx/MSIX) con soporte de detección inteligente de dependencias y licencias.
    * **Automatización OOBE (Unattend.xml)**: Generador avanzado que crea archivos de respuesta para configurar usuario, saltar EULA, configurar opciones de Idioma y Teclado interactivo/automático, aplicar hacks para instalar Windows 11 en hardware no soportado (BypassTPM/SecureBoot/RAM) y permitir instalación sin internet (BypassNRO).
    * **Inyector de Addons**: Sistema para integrar paquetes de terceros (.wim, .tpk, .bpk) en el sistema.
    * **Gestión de WinRE**: Módulo avanzado para extraer, montar, inyectar drivers/addons y optimizar (comprimir) de nuevo el entorno de recuperación nativo.
    * **OEM Branding**: Permite aplicar fondos de pantalla (GPO o Theme Override), pantallas de bloqueo y metadatos de fabricante y logotipo.
* **Suite de Limpieza y Reparación**: `CheckHealth`, `ScanHealth`, `RestoreHealth` (con soporte para fuente WIM alternativa), `SFC` offline y limpieza de componentes (`ResetBase`).

---

## Requisitos

* Sistema Operativo Windows (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador para ejecutar el script.
* Módulo de Hyper-V habilitado (Recomendado para operaciones con VHD).
* **[Windows Assessment and Deployment Kit (ADK)](https://learn.microsoft.com/es-es/windows-hardware/get-started/adk-install) (CRÍTICO):** Instalado en el sistema, o al menos contar con el ejecutable `oscdimg.exe` en la carpeta `Tools`. **Esta dependencia es estrictamente necesaria** no solo para la creación de ISOs booteables, sino que sus complementos estructurales (como los complementos WinPE_OCs) son vitales para otros módulos avanzados del script, como la inyección automatizada de idiomas en el entorno de preinstalación y rescate.
* Conexión a internet (opcional, para el auto-actualizador).

---

## Modo de Uso

1.  Descarga el repositorio como un archivo `.zip` y extráelo.
2.  Asegúrate de que la estructura de carpetas sea la siguiente:
    ```
    TuCarpetaPrincipal/
    │
    ├── Run.bat
    ├── Tools/
    └── Script/
        │
        └── AdminImagenOffline.ps1
        └── Catalogos/
            ├── Ajustes.ps1
            ├── Servicios.ps1
            └── Bloatware.ps1
    ```
3.  Haz doble clic en **`Run.bat`**. El script validará los permisos y se iniciará.
4.  Si es la primera ejecución, ve al menú **[9] Configuración** para definir tus directorios de trabajo.

---

## Explicación Detallada de los Menús

### Menú Principal

* **1. Gestión de Imagen**: Operaciones base de WIM (Montar, Guardar, Editar Metadatos, Editar Índices).
* **2. Convertir Formatos**: Conversión de ESD a WIM y VHD a WIM.
* **3. Herramientas de Arranque y Medios**: Submenú para el `boot.wim`, desplegar a VHD o crear ISO booteable.
* **4. Drivers (Inyectar/Eliminar)**: Herramientas GUI para gestión de controladores.
* **5. Personalización**: Centro avanzado de ajustes (Apps, Features, Servicios, Tweaks, Addons, WinRE, Branding).
* **6. Limpieza y Reparación**: Utilidades de mantenimiento (DISM/SFC).
* **7. Cambiar Edición**: Actualización de edición (ej. Home -> Pro).
* **8. Gestión de Idiomas**: Inyección estructurada de idiomas base, WinPE y boot.
* **9. Configuración**: Configuración de directorios de montaje y temporales.

### 1. Gestión de Imagen

Incluye las operaciones fundamentales y herramientas avanzadas como:
* **Editar Info/Metadatos**: Una GUI exclusiva para renombrar las imágenes internas del WIM y cambiar sus descripciones.
* **Editar Índices**: Exportar un índice específico a un nuevo archivo o eliminar índices para ahorrar espacio.

### 5. Personalización (Submenú)

Este es el núcleo de la optimización:
* **Eliminar Bloatware (Apps)**: Gestor visual para borrar aplicaciones Appx con código de colores (Verde=Seguro, Naranja=Recomendado).
* **Características de Windows (Features)**: Nueva interfaz para activar/desactivar características opcionales del sistema offline. Soporte directo para integrar .NET 3.5 desde una carpeta `sxs`.
* **Servicios del Sistema**: Interfaz por pestañas para deshabilitar servicios masivamente o restaurarlos a sus valores por defecto.
* **Tweaks y Registro**: Aplica parches de registro o importa archivos `.reg` externos. Cuenta con un sistema de cola, vista previa de cambios y perfiles de usuario.
* **Inyector de Apps Modernas**: Carga archivos `.appx` o `.msix` comprobando dependencias requeridas y aplicando licencias.
* **Automatización OOBE (Unattend)**: Generador avanzado que inyecta `unattend.xml`. Incluye:
    * **Hacks Win11**: Permite activar BypassTPM, BypassSecureBoot y BypassRAM.
    * **Sin Internet y WiFi**: Permite instalación sin red (BypassNRO) y omite configuración WiFi.
    * **Regionalización**: Define idioma y distribución de teclado.
* **Inyector de Addons**: Utilidad gráfica para aplicar paquetes adicionales.
* **Gestionar WinRE**: Monta de manera temporal el entorno de recuperación, permitiendo integrarle complementos y recomprimir el entorno de vuelta al sistema.
* **OEM Branding**: Modifica los metadatos visuales como fondo de escritorio, pantalla de bloqueo y logotipo de fabricante en las propiedades de sistema.

### 3. Herramientas de Arranque y Medios

* **1. Editar boot.wim**: Aísla el montaje del archivo de preinstalación para integrar utilidades exclusivas o drivers de almacenamiento pre-arranque.
* **2. Crear ISO Booteable**: Utilidad gráfica que usa `oscdimg` para empaquetar tu carpeta de distribución de Windows en una ISO válida (BIOS/UEFI).
* **3. Despliegue a VHD**: Herramienta para crear discos virtuales arrancables desde un WIM. Configura automáticamente particiones GPT/UEFI o MBR/BIOS y aplica la imagen.

### 6. Herramientas de Limpieza

Requiere una imagen montada. Ofrece:
* **Diagnóstico**: `CheckHealth` y `ScanHealth`.
* **Reparación**: `RestoreHealth` (con lógica de fallback que solicita un WIM fuente si falla la reparación automática) y `SFC` offline.
* **Optimización**: Análisis y limpieza del almacén de componentes (`ResetBase`) para reducir el tamaño de la imagen.
* **Ejecutar TODO**: Secuencia automática de mantenimiento completo con comprobación inteligente de estado ("Healthy", "Repairable", "NonRepairable").

## Notas Importantes

* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad de tu imagen de Windows antes de utilizar las funciones de cambio de edición o reparación.
* **COMPATIBILIDAD:** El script traduce automáticamente las claves de registro para edición offline, protegiendo el sistema operativo del técnico.
* **IDIOMA:** El script y sus mensajes en consola están en español.

## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows y el registro del sistema. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir.

**Se recomienda encarecidamente crear una copia de seguridad de tus archivos `.wim` antes de utilizar esta herramienta.**

## Autor y Colaboradores

* **Autor Principal**: SOFTMAXTER
* **Análisis y refinamiento de código**: Realizado en colaboración con **Gemini**, para garantizar calidad, seguridad, optimización de algoritmos y transición a interfaces gráficas.

---
### Cómo Contribuir

Si deseas contribuir al desarrollo de este script:

1.  Haz un Fork del repositorio.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Realiza tus cambios y haz commit (`git commit -am 'Añade nueva funcionalidad'`).
4.  Haz Push a la rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request.

---
## 📝 Licencia y Modelo de Negocio (Dual Licensing)

Este proyecto está protegido bajo derechos de autor y utiliza un modelo de **Doble Licencia (Dual Licensing)**:

### 1. Licencia Comunitaria (Open Source)
Distribuido bajo la **Licencia GNU GPLv3**. Eres libre de usar, modificar y compartir este software. Bajo esta licencia (*Copyleft*), cualquier herramienta derivada o script que integre código de AdminImagenOffline **debe ser de código abierto** bajo la misma licencia.

### 2. Licencia Comercial Corporativa
Si deseas integrar el motor de DeltaPack en un producto comercial propietario (closed-source), o requieres Acuerdos de Nivel de Servicio (SLA) para tu corporación, **debes adquirir una Licencia Comercial**. 

Para licenciamiento corporativo, contactar a: `(softmaxter@hotmail.com)`
