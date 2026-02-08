# AdminImagenOffline V1.4.6 by SOFTMAXTER

**AdminImagenOffline** es un completo script en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM`, manipulación del Registro y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Híbrida (Consola + GUI)**: Combina la rapidez de la consola para operaciones básicas con interfaces gráficas (Windows Forms) modernas para la gestión de drivers, servicios, bloatware, despliegue, metadatos y registro.
* **Auto-Actualizador**: El script busca automáticamente nuevas versiones en GitHub al iniciar y ofrece al usuario la posibilidad de actualizarse mediante un módulo externo seguro.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que las preferencias del usuario sean permanentes.
* **Robustez y Seguridad**:
    * **Protección de Hives**: Implementa limpieza de memoria (`GC`) y pausas de seguridad para evitar la corrupción del registro al desmontar.
    * **Logging Detallado**: Sistema de reporte de errores con "Stack Trace" completo para facilitar el diagnóstico de fallos críticos en la carpeta `Logs`.
    * **Saneamiento Automático**: Limpieza proactiva del directorio temporal (`Scratch`) al inicio para evitar errores de espacio o archivos corruptos.
    * **Tablero de Estado (Dashboard)**: Muestra en tiempo real la información de la imagen montada (Nombre, Versión, Arquitectura, Directorio) en el menú principal.
* **Detección Automática**: Verifica al inicio si ya existe una imagen montada en el sistema (WIM o VHD) y carga su información dinámicamente.
* **Gestión de Imágenes**: Montaje, desmontaje (con descartes), guardado de cambios (commit/append/guardar como nuevo WIM) y recarga rápida. Soporte completo para montar y editar archivos **VHD/VHDX** directamente.
* **Editor de Metadatos WIM**: Interfaz gráfica dedicada para editar el Nombre, Descripción y Nombre Mostrado de los índices de una imagen WIM.
* **Creación de Medios**:
    * **Despliegue a VHD**: Herramienta para crear discos virtuales arrancables desde un WIM, configurando particiones (GPT/UEFI o MBR/BIOS) automáticamente.
    * **Generador de ISO**: Crea imágenes ISO arrancables (Legacy/UEFI) utilizando `oscdimg`, con soporte para inyección automática de archivos desatendidos.
* **Conversión de Formatos**: ESD a WIM y VHD/VHDX a WIM.
* **Cambio de Edición de Windows**: Detección y cambio de edición (ej. Home a Pro) offline con advertencias de seguridad para VHDs.
* **Gestión Avanzada de Drivers**:
    * **Inyector Flexible**: Interfaz que permite cargar carpetas recursivamente o agregar archivos `.inf` individuales. Incluye detección precisa por **Versión** y **Clase** para evitar duplicados.
    * **Desinstalador de Drivers**: Lista los drivers de terceros (OEM) instalados en la imagen y permite su eliminación selectiva.
* **Personalización Completa**:
    * **Eliminación de Bloatware**: Interfaz gráfica con clasificación por colores para eliminar aplicaciones preinstaladas (Appx).
    * **Gestor de Características (Features)**: Habilita o deshabilita componentes de Windows (IIS, .NET, Hyper-V, etc.) con una interfaz visual.
    * **Optimización de Servicios**: Permite deshabilitar servicios del sistema innecesarios organizados por categorías. Incluye función para **Restaurar** valores originales.
    * **Tweaks y Registro Offline**: Gestor nativo para aplicar ajustes de rendimiento y privacidad. Incluye un **Importador .REG Inteligente** con traducción automática de rutas y vista previa.
    * **Automatización OOBE (Unattend.xml)**: Generador avanzado que crea archivos de respuesta para configurar usuario, saltar EULA y aplicar hacks para instalar Windows 11 en hardware no soportado (BypassTPM/SecureBoot/RAM) y permitir instalación sin internet (BypassNRO).
* **Suite de Limpieza y Reparación**: `CheckHealth`, `ScanHealth`, `RestoreHealth` (con soporte para fuente WIM alternativa), `SFC` offline y limpieza de componentes (`ResetBase`).

---

## Requisitos

* Sistema Operativo Windows (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador para ejecutar el script.
* Módulo de Hyper-V habilitado (Recomendado para operaciones con VHD).
* Kit de implementación (ADK) instalado o `oscdimg.exe` disponible en la carpeta `Tools` (para la creación de ISOs).
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
4.  Si es la primera ejecución, ve al menú **[8] Configuración** para definir tus directorios de trabajo.

---

## Explicación Detallada de los Menús

### Menú Principal

* **1. Gestión de Imagen**: Operaciones base de WIM (Montar, Guardar, Editar Metadatos, Editar Índices).
* **2. Convertir Formatos**: Conversión de ESD a WIM y VHD a WIM.
* **3. Crear Medio de Instalación**: Submenú para desplegar a VHD o crear ISO booteable.
* **4. Drivers (Inyectar/Eliminar)**: Herramientas GUI para gestión de controladores.
* **5. Personalización**: Centro de ajustes (Apps, Features, Servicios, Tweaks, Unattend).
* **6. Limpieza y Reparación**: Utilidades de mantenimiento (DISM/SFC).
* **7. Cambiar Edición**: Actualización de edición (ej. Home -> Pro).
* **8. Configuración**: Configuración de directorios de montaje y temporales.

### 1. Gestión de Imagen

Incluye las operaciones fundamentales y herramientas avanzadas como:
* **Editar Info/Metadatos**: Una GUI exclusiva para renombrar las imágenes internas del WIM y cambiar sus descripciones.
* **Editar Índices**: Exportar un índice específico a un nuevo archivo o eliminar índices para ahorrar espacio.

### 5. Personalización (Submenú)

Este es el núcleo de la optimización:
* **Eliminar Bloatware (Apps)**: Gestor visual para borrar aplicaciones Appx con código de colores (Verde=Seguro, Naranja=Recomendado).
* **Características de Windows (Features)**: Nueva interfaz para activar/desactivar características opcionales del sistema (como SMB1, .NET Framework 3.5, etc.) offline.
* **Servicios del Sistema**: Interfaz por pestañas para deshabilitar servicios masivamente o restaurarlos.
* **Tweaks y Registro**: Aplica parches de registro predefinidos o importa tus propios archivos `.reg` con traducción automática de rutas (HKEY_LOCAL_MACHINE -> HKLM\OfflineSystem).
* **Automatización OOBE (Unattend)**: Generador avanzado que inyecta un archivo `unattend.xml` en la imagen.
    * **Hacks Win11**: Permite activar BypassTPM, BypassSecureBoot y BypassRAM.
    * **Sin Internet**: Opción para permitir instalación sin red (BypassNRO).
    * **Usuario**: Creación automática de admin o modo interactivo.

### 3. Crear Medio de Instalación (ISO / VHD)

* **1. Despliegue a VHD**: Herramienta para crear discos virtuales arrancables desde un WIM. Configura automáticamente particiones GPT/UEFI o MBR/BIOS y aplica la imagen.
* **2. Crear ISO Booteable**: Utilidad gráfica que usa `oscdimg` para empaquetar tu carpeta de distribución de Windows en una ISO válida (BIOS/UEFI). Genera logs detallados de la creación.

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

