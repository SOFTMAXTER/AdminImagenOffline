# AdminImagenOffline by SOFTMAXTER V1.1

[cite_start]`AdminImagenOffline` es un script de batch para la línea de comandos de Windows que facilita la administración y el mantenimiento de imágenes de Windows (archivos `.wim`). [cite_start]La herramienta permite a los usuarios montar, desmontar, editar, limpiar y realizar otras operaciones avanzadas en imágenes de Windows de forma offline, todo desde un menú interactivo y fácil de usar.

## Características Principales

* [cite_start]**Gestión de Imágenes WIM:** Monta y desmonta imágenes de Windows (`install.wim`, `winre.wim`, etc.) en un directorio temporal (`C:\TEMP`).
* [cite_start]**Edición de Índices:** Exporta y elimina índices específicos de un archivo WIM, permitiendo reducir su tamaño o aislar versiones.
* [cite_start]**Cambio de Edición de Windows:** Muestra las ediciones de Windows a las que se puede actualizar la imagen montada y permite realizar el cambio (por ejemplo, de Home a Pro).
* [cite_start]**Herramientas de Limpieza y Reparación:** Integra `DISM` y `SFC` para realizar tareas de mantenimiento:
    * [cite_start]Verificar la salud de la imagen.
    * [cite_start]Escanear en busca de componentes corruptos.
    * [cite_start]Reparar la imagen.
    * [cite_start]Analizar y limpiar el almacén de componentes (`WinSxS`).
* [cite_start]**Detección Automática:** Verifica si una imagen ya está montada en el directorio de trabajo para evitar conflictos.
* [cite_start]**Ejecución como Administrador:** El script solicita automáticamente la elevación de privilegios si no se ejecuta como administrador.

## Prerrequisitos

* [cite_start]**Sistema Operativo:** Windows 7, 8.1, 10, 11 o sus correspondientes versiones de Windows Server.
* [cite_start]**Permisos:** Se requieren privilegios de administrador para ejecutar el script, ya que utiliza `dism`, `sfc` y comandos de montaje.

## ¿Cómo Usar?

1.  Descarga el archivo `AdminImagenOffline.bat`.
2.  [cite_start]Haz clic derecho sobre el archivo y selecciona **"Ejecutar como administrador"**.
3.  [cite_start]Se abrirá una ventana de Símbolo del sistema (CMD) con el menú principal.
4.  [cite_start]Navega por las opciones usando los números correspondientes.

## Opciones del Menú

### Menú Principal

* **1. [cite_start]Gestionar Imagen (Montar/Desmontar/Guardar):** Accede a las funciones básicas de manejo de la imagen.
* **2. [cite_start]Cambiar Edición de Windows:** Permite cambiar la edición de la imagen montada.
* **3. [cite_start]Herramientas de Limpieza:** Accede a las utilidades de mantenimiento y reparación.
* **0. [cite_start]Salir:** Cierra la aplicación.

### [cite_start]1. Gestión de Imagen 

* [cite_start]**Montar/Desmontar Imagen**:
    * **Montar Imagen:** Pide la ruta del archivo `.wim` y el número de índice a montar.
    * [cite_start]**Desmontar Imagen:** Desmonta la imagen actual, descartando los cambios.
* [cite_start]**Guardar Cambios**:
    * Permite guardar los cambios realizados en la imagen montada, ya sea en el mismo índice o creando uno nuevo (`/append`).
* [cite_start]**Editar Índices**:
    * [cite_start]**Exportar un Índice:** Crea un nuevo archivo WIM a partir de un índice seleccionado.
    * **Eliminar un Índice:** Borra permanentemente un índice del archivo WIM.

### 2. Cambiar Edición de Windows 

* [cite_start]Muestra la edición actual de Windows de la imagen montada.
* [cite_start]Lista todas las ediciones a las que se puede actualizar.
* Permite seleccionar una nueva edición y aplica el cambio con `dism /Set-Edition`.

### 3. Herramientas de Limpieza 

* Ofrece una serie de comandos para el mantenimiento de la imagen montada:
    * `CheckHealth`: Verifica si hay corrupción.
    * [cite_start]`ScanHealth`: Realiza un escaneo más profundo.
    * [cite_start]`RestoreHealth`: Intenta reparar la imagen.
    * `SFC /scannow /offbootdir`: Repara archivos del sistema.
    * [cite_start]`AnalyzeComponentStore`: Analiza el almacén de componentes.
    * [cite_start]`StartComponentCleanup`: Limpia componentes obsoletos.
* La opción **"Ejecutar Todas las Opciones"** realiza una secuencia de limpieza y reparación automática.

## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir en tus archivos WIM.

**Se recomienda encarecidamente crear una copia de seguridad de tus archivos `.wim` antes de utilizar esta herramienta.**
