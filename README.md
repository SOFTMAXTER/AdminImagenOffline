# Administrador de Imagen Offline by SOFTMAXTER

Este script de batch (`.bat`) para Windows facilita la administración de imágenes de Windows sin conexión (offline), permitiendo cambiar la edición del sistema operativo y ejecutar diversas tareas de limpieza y mantenimiento directamente sobre una imagen montada o aplicada en `C:\TEMP`.

## Características Principales

* **Cambio de Edición de Windows Offline:** [cite: 4]
    * Detecta automáticamente la versión de Windows (7, 8.1, 10, 11) y la edición actual de la imagen ubicada en `C:\TEMP`. [cite: 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 20]
    * Muestra las ediciones de destino a las que se puede actualizar la imagen actual. [cite: 21, 22]
    * Permite seleccionar y cambiar a una nueva edición de Windows usando DISM. [cite: 31, 32]
    * Traduce nombres de edición técnicos (ej. "Core") a nombres más amigables (ej. "Home") para facilitar su comprensión. [cite: 18, 19, 22, 23, 24]
* **Herramientas de Limpieza y Mantenimiento de Imagen Offline:** [cite: 5, 38, 39]
    * **Verificar Salud de Imagen (`DISM /CheckHealth`):** [cite: 40] Revisa el estado de la imagen sin modificarla.
    * **Escaneo Avanzado de Salud (`DISM /ScanHealth`):** [cite: 41] Realiza un escaneo exhaustivo para detectar corrupción en el almacén de componentes.
    * **Reparar Imagen (`DISM /RestoreHealth`):** [cite: 42, 48] Restaura la imagen a un estado saludable.
    * **Escaneo y Reparación SFC (`SFC /scannow /offbootdir /offwindir`):** [cite: 43] Verifica y repara archivos del sistema protegidos.
    * **Analizar Almacén de Componentes (`DISM /AnalyzeComponentStore`):** [cite: 44] Informa sobre el tamaño del almacén y si se recomienda limpieza.
    * **Limpieza de Componentes (`DISM /StartComponentCleanup /ResetBase`):** [cite: 45] Elimina componentes innecesarios para liberar espacio, utilizando `C:\TEMP1` como directorio temporal (`ScratchDir`). [cite: 49]
    * **Ejecutar Todas las Opciones:** [cite: 46] Realiza secuencialmente las tareas de CheckHealth, ScanHealth, RestoreHealth, SFC y StartComponentCleanup. [cite: 50]
* **Interfaz de Menú en Consola:** [cite: 2, 3] Navegación sencilla mediante opciones numéricas.
* **Verificación de Privilegios:** [cite: 1] Comprueba si el script se ejecuta como administrador y, de no ser así, intenta reiniciarse con permisos elevados usando PowerShell.

## Requisitos Previos

1.  **Sistema Operativo:** Windows (el script utiliza herramientas nativas como DISM, SFC, REG).
2.  **Ejecutar como Administrador:** El script intentará solicitarlo, pero es fundamental para su correcto funcionamiento. [cite: 1]
3.  **Imagen de Windows en `C:\TEMP`:**
    * Debes tener una imagen de Windows (por ejemplo, de un archivo WIM o ESD montado, o una instalación de Windows previamente aplicada) disponible en la ruta `C:\TEMP`.
    * El script **NO monta** la imagen por ti. El directorio `C:\TEMP` debe ser la raíz de la imagen de Windows offline (ej. `C:\TEMP\Windows`, `C:\TEMP\Users`, etc.).
4.  **Directorio Temporal `C:\TEMP1`:** La opción de limpieza de componentes (`StartComponentCleanup`) utiliza `C:\TEMP1` como `ScratchDir`. [cite: 49] Asegúrate de que este directorio exista o pueda ser creado por DISM, y que haya suficiente espacio libre en la unidad que lo contiene.

## Uso

1.  Descarga el archivo `AdminImagenOffline.bat` (o el nombre que le hayas dado al script proporcionado).
2.  Asegúrate de cumplir con todos los **Requisitos Previos**, especialmente tener la imagen de Windows correctamente configurada en `C:\TEMP`.
3.  Haz clic derecho sobre el archivo `.bat` y selecciona "**Ejecutar como administrador**".
4.  Sigue las instrucciones presentadas en el menú de la consola:
    * **Opción 1:** Para cambiar la edición de Windows. [cite: 4]
    * **Opción 2:** Para acceder a las herramientas de limpieza. [cite: 5]
    * **Opción 0:** Para salir del script. [cite: 6]

## Opciones del Menú Detalladas

### Menú Principal

* **`1. Cambiar Edicion de Windows`**: [cite: 4]
    * Muestra la información detectada de la imagen (Sistema Operativo y Edición Actual). [cite: 20]
    * Lista las ediciones a las que se puede cambiar. [cite: 21, 22, 23, 24, 25, 26, 27]
    * Permite seleccionar una nueva edición o volver al menú principal. [cite: 28]
* **`2. Herramientas de Limpieza`**: [cite: 5]
    * Accede a un submenú con varias herramientas para el mantenimiento de la imagen. [cite: 39]
* **`0. Salir`**: [cite: 6]
    * Cierra la aplicación.

### Submenú: Herramientas de Limpieza [cite: 38]

1.  **`Verificar Salud de Imagen`**: [cite: 40] `DISM /Image:C:\TEMP /Cleanup-Image /CheckHealth`
2.  **`Escaneo Avanzado de Salud de Imagen`**: [cite: 41] `DISM /Image:C:\TEMP /Cleanup-Image /ScanHealth`
3.  **`Reparar Imagen`**: [cite: 42, 48] `DISM /Image:C:\TEMP /Cleanup-Image /RestoreHealth`
4.  **`Escaneo y Reparacion SFC`**: [cite: 43] `SFC /scannow /offbootdir=C:\TEMP /offwindir=C:\TEMP\Windows`
5.  **`Analizar Almacen de Componentes de la Imagen`**: [cite: 44] `DISM /Image:C:\TEMP /Cleanup-Image /AnalyzeComponentStore`
6.  **`Limpieza de Componentes`**: [cite: 45] `DISM /Cleanup-Image /Image:C:\TEMP /StartComponentCleanup /ResetBase /ScratchDir:C:\TEMP1` [cite: 49]
7.  **`Ejecutar Todas las Opciones`**: [cite: 46] Ejecuta las opciones 1, 2, 3, 4 y 6 en secuencia. [cite: 50]
8.  **`Volver al Menu Principal`**: [cite: 47] Regresa al menú anterior.

## Estructura del Script

El script está organizado en secciones utilizando etiquetas (`:`):

* **`:menu`**: Pantalla principal del script. [cite: 1]
* **`:cambio_edicion`**: Lógica para detectar y cambiar la edición de Windows. [cite: 7]
    * Intenta cargar el hive del registro para obtener detalles de la versión. [cite: 8]
    * Usa `DISM /Get-CurrentEdition` y `DISM /Get-TargetEditions`.
* **`:limpieza`**: Submenú y lógica para las herramientas de limpieza y reparación. [cite: 37]
* **`:trim_leading_spaces`**: Subrutina para eliminar espacios al inicio de variables. [cite: 36, 51]
* Manejo de errores básicos y validación de entradas del usuario. [cite: 6, 29, 30, 33, 50]

## Notas Importantes

* **RESPONSABILIDAD:** Utiliza este script bajo tu propio riesgo. El autor (SOFTMAXTER) y cualquier contribuyente no se hacen responsables por posibles daños o pérdida de datos.
* **RUTA FIJA `C:\TEMP`:** El script está codificado para trabajar exclusivamente con una imagen de Windows ubicada en `C:\TEMP`. Si tu imagen está en otra ruta, deberás modificar el script manualmente en todas las ocurrencias de `C:\TEMP` (y `C:\TEMP1` para el ScratchDir).
* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad de tu imagen de Windows antes de utilizar las funciones de cambio de edición o reparación.
* **CONOCIMIENTOS TÉCNICOS:** Se recomienda tener conocimientos básicos sobre DISM, SFC y la administración de imágenes de Windows.
* **IDIOMA:** El script y sus mensajes en consola están en español. [cite: 2, 3]

## Autor

* **SOFTMAXTER** [cite: 1, 2]

## Licencia

(Opcional) Considera añadir un archivo `LICENSE` (por ejemplo, MIT, GPL) si deseas que tu proyecto sea de código abierto y definir cómo otros pueden usar, modificar y distribuir tu script. Si no se especifica, se aplican las leyes de copyright estándar.

---
### Cómo Contribuir (Opcional)

Si deseas contribuir al desarrollo de este script:

1.  Haz un Fork del repositorio.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Realiza tus cambios y haz commit (`git commit -am 'Añade nueva funcionalidad'`).
4.  Haz Push a la rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request.

---