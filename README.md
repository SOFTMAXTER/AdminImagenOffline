# AdminImagenOffline by SOFTMAXTER V1.1

AdminImagenOffline` es un script de batch para la línea de comandos de Windows que facilita la administración y el mantenimiento de imágenes de Windows (archivos `.wim`). La herramienta permite a los usuarios montar, desmontar, editar, limpiar y realizar otras operaciones avanzadas en imágenes de Windows de forma offline, todo desde un menú interactivo y fácil de usar.

## Características Principales

* **Gestión de Imágenes WIM:** Monta y desmonta imágenes de Windows (`install.wim`, `winre.wim`, etc.) en un directorio temporal (`C:\TEMP`).
* **Edición de Índices:** Exporta y elimina índices específicos de un archivo WIM, permitiendo reducir su tamaño o aislar versiones.
* **Cambio de Edición de Windows:** Muestra las ediciones de Windows a las que se puede actualizar la imagen montada y permite realizar el cambio (por ejemplo, de Home a Pro).
* **Herramientas de Limpieza y Reparación:** Integra `DISM` y `SFC` para realizar tareas de mantenimiento:
    * Verificar la salud de la imagen.
    * Escanear en busca de componentes corruptos.
    * Reparar la imagen.
    * Analizar y limpiar el almacén de componentes (`WinSxS`).
* **Detección Automática:** Verifica si una imagen ya está montada en el directorio de trabajo para evitar conflictos.
* **Ejecución como Administrador:** El script solicita automáticamente la elevación de privilegios si no se ejecuta como administrador.

## Prerrequisitos

* **Sistema Operativo:** Windows 7, 8.1, 10, 11 o sus correspondientes versiones de Windows Server.
* **Permisos:** Se requieren privilegios de administrador para ejecutar el script, ya que utiliza `dism`, `sfc` y comandos de montaje.

## ¿Cómo Usar?

1.  Descarga el archivo `AdminImagenOffline.bat`.
2.  Haz clic derecho sobre el archivo y selecciona **"Ejecutar como administrador"**.
3.  Navega por las opciones usando los números correspondientes.

## Opciones del Menú

### Menú Principal

* **1. Gestionar Imagen (Montar/Desmontar/Guardar):** Accede a las funciones básicas de manejo de la imagen.
* **2. Cambiar Edición de Windows:** Permite cambiar la edición de la imagen montada.
* **3. Herramientas de Limpieza:** Accede a las utilidades de mantenimiento y reparación.
* **0. Salir:** Cierra la aplicación.

### 1. Gestión de Imagen 

* **Montar/Desmontar Imagen**:
    * **Montar Imagen:** Pide la ruta del archivo `.wim` y el número de índice a montar.
    * **Desmontar Imagen:** Desmonta la imagen actual, descartando los cambios.
* **Guardar Cambios**:
    * Permite guardar los cambios realizados en la imagen montada, ya sea en el mismo índice o creando uno nuevo (`/append`).
* **Editar Índices**:
    * **Exportar un Índice:** Crea un nuevo archivo WIM a partir de un índice seleccionado.
    * **Eliminar un Índice:** Borra permanentemente un índice del archivo WIM.

### 2. Cambiar Edición de Windows 

* Muestra la edición actual de Windows de la imagen montada.
* Lista todas las ediciones a las que se puede actualizar.
* Permite seleccionar una nueva edición y aplica el cambio con `dism /Set-Edition`.

### 3. Herramientas de Limpieza 

* Ofrece una serie de comandos para el mantenimiento de la imagen montada:
    * `CheckHealth`: Verifica si hay corrupción.
    * `ScanHealth`: Realiza un escaneo más profundo.
    * `RestoreHealth`: Intenta reparar la imagen.
    * `SFC /scannow /offbootdir`: Repara archivos del sistema.
    * `AnalyzeComponentStore`: Analiza el almacén de componentes.
    * `StartComponentCleanup`: Limpia componentes obsoletos.
* La opción **"Ejecutar Todas las Opciones"** realiza una secuencia de limpieza y reparación automática.

## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir en tus archivos WIM.

**Se recomienda encarecidamente crear una copia de seguridad de tus archivos `.wim` antes de utilizar esta herramienta.**
