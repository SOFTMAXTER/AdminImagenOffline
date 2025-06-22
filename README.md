# AdminImagenOffline by SOFTMAXTER V1.2

**AdminImagenOffline** es un completo y potente script para la línea de comandos de Windows (Batch) diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM` y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Guiada por Menús**: Todas las funciones están organizadas en menús y submenús claros y fáciles de navegar.
* **Detección Automática**: El script verifica al inicio si ya existe una imagen montada en el sistema y carga su información dinámicamente (ruta, índice).
* **Autoelevación de Privilegios**: Comprueba si se está ejecutando como Administrador y, de no ser así, intenta reiniciarse con los permisos necesarios.
* **Gestión de Imágenes**:
    * **Montaje/Desmontaje**: Permite montar un índice específico de un archivo WIM en un directorio local y desmontarlo.
    * **Guardado de Cambios**: Ofrece la opción de guardar los cambios en el índice actual o crear un nuevo índice con las modificaciones (append).
    * **Recarga de Imagen**: Descarta todos los cambios no guardados desmontando y volviendo a montar la imagen rápidamente.
* **Edición de Índices WIM**:
    * **Exportar Índice**: Permite guardar un índice específico de un archivo WIM en un nuevo archivo WIM de destino.
    * **Eliminar Índice**: Ofrece la capacidad de borrar de forma permanente un índice de un archivo WIM.
* **Conversión de Formatos de Imagen**:
    * **ESD a WIM**: Convierte un índice específico de un archivo `.esd` (Electronic Software Download) a un archivo `.wim` con compresión máxima.
    * **VHD/VHDX a WIM**: Monta automáticamente un disco duro virtual (`.vhd` o `.vhdx`), captura su contenido en un nuevo archivo `.wim` y lo desmonta al finalizar.
* **Cambio de Edición de Windows**:
    * Detecta automáticamente la versión del SO (Windows 7/8.1/10/11) y la edición actual de la imagen montada.
    * Muestra las ediciones de destino a las que se puede actualizar y realiza el cambio con un solo comando.
* **Suite de Limpieza y Reparación**:
    * Integra las funciones más importantes de `DISM /Cleanup-Image` y `SFC` para imágenes offline.
    * Permite ejecutar análisis, verificaciones, reparaciones y limpieza del almacén de componentes de forma individual o todas a la vez.

---

## Requisitos

* Sistema Operativo Windows.
* Privilegios de Administrador para ejecutar el script.

---

## Modo de Uso

1.  Descarga el archivo `AdminImagenOffline.bat`.
2.  Haz clic derecho sobre el script y selecciona **"Ejecutar como administrador"**. El script validará los permisos.
3.  Sigue las instrucciones en pantalla, seleccionando las opciones numéricas de los menús.

---

## Explicación Detallada de los Menús

### Menú Principal

Al iniciar, se muestra el estado actual (si hay una imagen montada o no) y las tres categorías principales de herramientas.

* **1. Gestionar Imagen (Montar/Desmontar/Guardar)**: Accede al submenú para operaciones de montaje, guardado y edición de la imagen WIM.
* **2. Cambiar Edicion de Windows**: Permite cambiar la edición de una imagen previamente montada.
* **3. Herramientas de Limpieza**: Accede a las utilidades de mantenimiento y reparación de la imagen.

### 1. Gestión de Imagen

#### → 1. Montar/Desmontar Imagen
* `1. Montar Imagen`: Solicita la ruta a un archivo `.wim` y el número de índice que se desea montar. Crea el directorio `C:\TEMP` si no existe para usarlo como punto de montaje.
* `2. Desmontar Imagen`: Ejecuta `dism /unmount-wim /discard` para desmontar la imagen, descartando cualquier cambio no guardado explícitamente.
* `3. Recargar Imagen (Descartar cambios)`: Una función útil para revertir cambios. Desmonta la imagen actual sin guardar (`/discard`) y la vuelve a montar usando la misma ruta e índice.

#### → 2. Guardar Cambios
* `1. Guardar cambios en el Indice actual`: Ejecuta `dism /commit-image` para guardar las modificaciones en el índice que está montado.
* `2. Guardar cambios en un nuevo Indice (Append)`: Usa la opción `/append` para crear un nuevo índice en el WIM con los cambios, preservando el índice original.

#### → 3. Editar Índices
* `1. Exportar un Indice`: Exporta un índice de un WIM existente a un nuevo archivo WIM. El script sugiere un nombre de archivo de destino para facilitar la operación.
* `2. Eliminar un Indice`: Solicita la confirmación del usuario y luego elimina permanentemente un índice del archivo WIM usando `dism /delete-image`.

#### → 4. Convertir Imagen a WIM
* `1. Convertir ESD a WIM`: Pide la ruta de un archivo `.esd` y el índice a convertir. Luego utiliza `dism /export-image` para convertirlo a un `.wim` con compresión máxima (`/Compress:max`) e integridad verificada (`/CheckIntegrity`).
* `2. Convertir VHD/VHDX a WIM`:
    1.  Solicita la ruta a un archivo `.vhd` o `.vhdx`.
    2.  Utiliza PowerShell para montar el VHD y obtener la letra de unidad asignada.
    3.  Captura el contenido de esa unidad en un nuevo archivo WIM usando `dism /capture-image`.
    4.  Finalmente, desmonta el VHD usando PowerShell.

### 2. Cambiar Edición de Windows

Esta opción solo está disponible si hay una imagen montada.

1.  **Obtención de Información**: Carga temporalmente el hive del registro de la imagen (`SOFTWARE`) para leer la versión y el build del sistema operativo. Esto le permite identificar si es Windows 10, 11, etc. También usa `dism /get-currentedition` para obtener la edición exacta.
2.  **Traducción de Nombres**: Convierte los nombres técnicos de las ediciones (ej. `CoreSingleLanguage`) a nombres amigables (ej. `Home Single Language`).
3.  **Listado de Ediciones de Destino**: Ejecuta `dism /Image:%MOUNT_DIR% /Get-TargetEditions` para obtener una lista de las ediciones a las que es posible actualizar.
4.  **Cambio de Edición**: Una vez que el usuario selecciona una nueva edición, el script ejecuta `dism /Image:%MOUNT_DIR% /Set-Edition` para aplicar el cambio.

### 3. Herramientas de Limpieza

Requiere una imagen montada para funcionar. Ofrece un menú con las siguientes herramientas de mantenimiento:

* **1. Verificar Salud de Imagen**: `DISM /Image:%MOUNT_DIR% /Cleanup-Image /CheckHealth`.
* **2. Escaneo Avanzado de Salud de Imagen**: `DISM /Image:%MOUNT_DIR% /Cleanup-Image /ScanHealth`.
* **3. Reparar Imagen**: `DISM /Image:%MOUNT_DIR% /Cleanup-Image /RestoreHealth`.
* **4. Escaneo y Reparacion SFC**: `SFC /scannow` apuntando a la imagen offline (`/offbootdir=%MOUNT_DIR% /offwindir=%MOUNT_DIR%\Windows`).
* **5. Analizar Almacen de Componentes**: `DISM /Image:%MOUNT_DIR% /Cleanup-Image /AnalyzeComponentStore`.
* **6. Limpieza de Componentes**: `DISM /Cleanup-Image /Image:%MOUNT_DIR% /StartComponentCleanup /ResetBase` para una limpieza profunda.
* **7. Ejecutar Todas las Opciones**: Un modo automatizado que ejecuta las verificaciones, reparaciones y, si `AnalyzeComponentStore` lo recomienda, la limpieza de componentes en una secuencia lógica.

## Notas Importantes

* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad de tu imagen de Windows antes de utilizar las funciones de cambio de edición o reparación.
* **CONOCIMIENTOS TÉCNICOS:** Se recomienda tener conocimientos básicos sobre DISM, SFC y la administración de imágenes de Windows.
* **IDIOMA:** El script y sus mensajes en consola están en español.


## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir en tus archivos WIM.

**Se recomienda encarecidamente crear una copia de seguridad de tus archivos `.wim` antes de utilizar esta herramienta.**

## Autor

* **SOFTMAXTER** [cite: 1, 2]

---
### Cómo Contribuir

Si deseas contribuir al desarrollo de este script:

1.  Haz un Fork del repositorio.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Realiza tus cambios y haz commit (`git commit -am 'Añade nueva funcionalidad'`).
4.  Haz Push a la rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request.

---
