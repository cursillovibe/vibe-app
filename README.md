# VIBE App

App web del Cursillo VIBE para dirección, oficina, profes y alumnos. Se instala en el celular como una app ("Agregar a pantalla de inicio").

| Rol | Qué hace |
|---|---|
| **Dirección** (informacion@vibe.com.py) | Todo: grupos, alumnos, cobros, asistencia, notas, horario, plantel, pago a profes, equipo y ajustes. Es la única que puede anular pagos, borrar, cambiar roles y ver puntajes y pagos de profes. |
| **Oficina** | Invita alumnos, asigna grupos, cobra y emite recibos, toma lista, carga notas y ve el horario de la semana. Carga su disponibilidad y marca sus turnos. No borra ni anula nada. Se suma desde **Equipo → Sumar persona de oficina**. |
| **Profe** | Ve los grupos donde le toca clase según el horario publicado, carga su disponibilidad, llama lista (solo el día de la clase y en sus clases: queda como su firma), carga notas y ve contactos. Si da una clase que no es suya, pide el cambio. No ve cuotas ni puntajes. |
| **Alumno** | Completa su ficha, ve su horario (materia y tema de cada día, sin el nombre del profe), sus cuotas y recibos, sus notas, su asistencia y edita sus datos. |

**Cómo entra un alumno (dos caminos):**
- **Link de inscripción** (el principal): la oficina crea en **Inscripciones** un link por curso o por grupo y se lo pasa por WhatsApp al alumno que pagó la matrícula → el alumno crea su cuenta con su correo → completa la ficha.
- **Pedir acceso sin invitación** (desde la pantalla de entrada, sin link): "Soy alumno y no tengo cuenta" → nombre, apellido, cédula, celular, grupo en el que está o se quiere inscribir, correo y contraseña → confirma el correo. Nunca entra solo a un grupo (el pedido queda en `grupo_pedido`).
  - Si su cédula coincide con un alumno que la oficina ya había cargado sin cuenta, ve "¡Ya casi!" y en **Inscripciones → Ya estaban cargados** la oficina toca **Unir** (la cuenta pasa a su ficha, con sus pagos, notas y asistencia) o **No es** (sigue como alumno nuevo). Antes de unir, conviene comparar los celulares.
  - Si no, ve "Tu cuenta está lista": **no completa la ficha todavía** (cambia según el curso). La oficina le asigna el grupo con los datos básicos en **Inscripciones → Pedidos de acceso** (viene elegido el que pidió); al asignar, su curso pasa a ser el del grupo y al entrar le aparece la ficha de ese curso. Abajo de esa tarjeta quedan los que ya tienen grupo y todavía no completaron la ficha.
- **Invitación por correo**: la oficina carga el correo del alumno y le llega un mail para crear su contraseña.

En los dos casos, cuando completa la ficha le llega un correo a informacion@ y la oficina le asigna el grupo. Cerrar un link (desmarcar "activo") corta la inscripción por ese link.

## Dónde está
- App: https://cursillovibe.github.io/vibe-app/
- Código: https://github.com/cursillovibe/vibe-app
- Base de datos: Supabase, proyecto **VIBE App** (São Paulo), organización Cursillo VIBE.

## Horario y pago a profes

Reemplaza a la app vibe-horarios (sus datos se importaron con `supabase/importar-horarios.sql`). Todo está en **Horario**:

- **Disponibilidad**: cada profe marca sus turnos libres de la semana siguiente desde el miércoles hasta el sábado 17:00. La dirección puede reabrir la carga y avisar por WhatsApp a los que faltan. También puede **corregir** lo que marcó cualquier profe (botón **Editar** en Horario → Disponibilidad), aunque la carga esté cerrada: al guardar queda como enviada; si el horario ya estaba armado, hay que volver a armar para que la use (lo fijado a mano se respeta).
- **¿Quién está libre?** (dirección, Horario → Semana): durante la semana, por cada día y turno de hoy en adelante, quién marcó libre (en verde si además no da clase a esa hora) y quién no cargó disponibilidad. Al tocar una clase, "Libres en ese turno" muestra esos profes con su puntaje en la materia; tocando un nombre se lo pone como profe del horario. Para cubrir a alguien que avisa que no puede.
- **Armar horario**: se cargan las materias de la semana por grupo (sin día) y el armado elige el día según los profes libres, con las mismas reglas de siempre (los grupos con prioridad reciben a los mejores profes, Geometría en dos días seguidos con profes distintos, nivel mínimo, clases encadenadas, día fijo, examen sin profe, equidad mínima). Se puede cambiar cualquier bloque a mano y después **publicar**.
  - Lo que se cambia a mano (profe, materia, mover de día, dejar vacío) queda **fijado** (📌). También se puede fijar o soltar cualquier bloque con su pin. Al **volver a armar**, la app pregunta: *armar respetando mis cambios* (lo fijado queda tal cual y el resto se arma alrededor; un profe fijado no se usa en otro grupo a esa hora; si se fijó solo la materia y el día, el profe lo elige el armado) o *borrar mis cambios y armar de cero*. En borradores de antes de los pines, los cambios a mano se detectan comparando con el último armado automático.
  - **Retirar publicación**: si se publicó por error, la dirección lo retira (en Armar horario → Publicar, en Semana, o al volver a armar marcando "Retirar ya el horario publicado"). Profes y alumnos dejan de verlo hasta que se publique de nuevo; las clases que ya tienen lista, observaciones o evaluaciones quedan. El borrador no se toca.
  - En la semana, el borrador y la imagen para el grupo, cada día es una columna: la mañana arriba y la tarde abajo.
- **Semana**: las clases publicadas, con quién llamó lista en cada una.
- **Cambios**: cuando un profe va a dar una clase de **hoy** que no está a su nombre (reemplazo, cambio a último momento), la elige de la lista de clases publicadas de hoy y la pide desde la app (no se pueden pedir otros días ni clases que no están en el horario). Con el pedido ya puede llamar lista; la dirección lo aprueba antes o después de la clase y recién ahí la clase pasa a su nombre y le cuenta para el pago.
- **Plantel**: profes, puntajes y pago por clase (solo la dirección).
- **Pago a profes**: por mes, cuenta cada clase en la que el profe del horario (o con el cambio aprobado) llamó lista. Mañana y tarde cuentan por separado. Los exámenes que cuidó se ven pero no suman. Las clases sin lista se pueden marcar a mano (si firmó en papel).

Cuando un profe llama lista, la clase queda registrada a su nombre con la hora. Solo puede llamar lista el mismo día y en sus clases (o con un pedido de cambio); la oficina corrige listas viejas.

## Turnos de oficina

En **Turnos oficina** (solo la dirección): turnos Mañana, Tarde y Noche.

- Cada persona de oficina carga su disponibilidad de la semana siguiente (mismo plazo que los profes) desde **Mis turnos**. La dirección la corrige con **Editar** en Turnos oficina → Disponibilidad.
- La dirección arma la semana tocando nombres (en verde, los que pueden) o con "Completar con disponibles", y manda el mensaje al grupo por WhatsApp. En "Horario de la oficina" se eligen los turnos que abre cada día (por defecto lunes a viernes mañana, tarde y noche; sábado y domingo mañana y tarde).
- Cada persona **marca su entrada y su salida** el día que trabaja (desde Inicio o Mis turnos; ver "Entrada y salida"). Si trabaja un turno que no tenía, lo pide y la dirección lo aprueba.
- **Pago por turno**: por mes, cuenta cada turno asignado (o pedido y aprobado) con la entrada marcada (o cargada después: la dirección lo ve). El monto por turno solo lo ve la dirección.
- **Imagen para el grupo** (Turnos oficina): una columna por día y una fila por turno (mañana, tarde, noche) con quiénes trabajan, y "SIN NADIE" donde falta cubrir. Mismo estilo que la imagen del horario de los profes.

## Entrada y salida (oficina y profes)

- **Oficina**: en Inicio ("Tu turno de hoy") y en Mis turnos, botón **Marcar entrada** al llegar y **Marcar salida** al irse, por cada turno del día. Marcar la entrada también marca el turno para el pago.
- **Profes**: en Inicio ("Tu entrada y salida") por cada turno en que tienen clase (horario o cambio pedido). No cambia el pago por clase (sigue contando la lista).
- **Si se olvidan o marcan mal**: en "Tus entradas y salidas" (Mis turnos / Horario) corrigen o cargan la hora de los **últimos 7 días**, con un motivo. Queda guardada la hora que marcaron con el botón, la corrección, quién y cuándo. Para algo más viejo, la dirección.
- **Dirección**: en Inicio, "Entradas y salidas de hoy" (quién marcó y quién no). En **Entradas y salidas** (menú): por mes, resumen por persona (turnos, horas, sin marcar, sin salida, corregidas), filtro "Solo para revisar" y exportar a Excel (CSV). Tocando una fila corrige o borra (borrar deja el turno de oficina como no trabajado). En el pago a profes se ve a qué hora entró y salió el que dio cada clase.
- Base: tabla `marcaciones` y funciones `marcar_hora`, `corregir_hora`, `borrar_marcacion` (`supabase/horas-caja.sql`, también al final de `schema.sql`). Nadie escribe directo en la tabla: todo pasa por esas funciones.

## Caja chica de la oficina

En **Caja chica** (dirección y oficina; resumen en el Inicio de las dos): la plata que se aparta de las cuotas para los gastos de la oficina.

- **Desde el cobro** (lo normal): al registrar un pago, el campo **"Para la caja de la oficina"** (botones 25.000 / 50.000 o cualquier monto) anota esa plata en la caja chica en el mismo momento. El recibo no cambia. Si se anula el pago, sale de la caja sola. Lo que viene de un cobro no se edita desde la caja.
- **Apartar de cuotas** (varios cobros juntos): cuántos alumnos × cuánto por alumno. La app sugiere cuántos alumnos pagaron desde el último apartado sin haber puesto nada para la caja. También "Otro ingreso" (p. ej. la dirección repone la caja).
- **Anotar gasto**: qué se pagó, monto y tipo (impresiones y hojas, pizarra, librería y útiles, limpieza, otros, retiro de la dirección). Muestra cuánto queda en la caja.
- **Contar la caja** (arqueo): se pone lo que hay en efectivo; si no coincide con la app queda anotado "faltaban / sobraban" y la caja sigue desde lo contado. Un conteo no se edita.
- Saldo, lo que entró y se gastó en el mes, gastos por tipo, el último conteo, cada movimiento con quién lo anotó y el saldo después. Exportar por mes.
- Cada una corrige lo que anotó el mismo día; solo la dirección borra. Todo queda en Actividad. Los profes no la ven.
- Base: tabla `caja_movs` (`supabase/horas-caja.sql`); `pagos.para_caja` y el trigger `pagos_a_caja` (`supabase/caja-cobros.sql`).

## Exámenes en varios grupos y lista completa

- Al crear un examen se eligen **todos los grupos que lo rinden** (chips). Cada grupo tiene su fila en `examenes` (con los permisos de siempre) y las del mismo examen comparten `comun`. Desde **Editar** se puede sumar otro grupo después; cambiar nombre, materia, fecha o puntaje cambia todos.
- Las notas se cargan grupo por grupo (chips "Mismo examen en:" para pasar de uno a otro).
- **Lista completa**: todos los que rindieron, de todos los grupos, con puesto 1, 2, 3… seguido del mayor puntaje al menor (con el mismo puntaje, por orden alfabético), nota, % y grupo; promedio, aprobados (60% o más), nota más alta y resumen por grupo. Orden por nota, nombre o grupo; opción de mostrar los que no rindieron. Un profe ve solo sus grupos.
- **Exportar**: **Excel** (.xlsx con título, cédula, grupo, nota, porcentaje y resultado; hoja "Por grupo") y **PDF con el logo** (A4, encabezado naranja, pie con página). Las librerías se cargan solo al exportar (SheetJS desde cdnjs; jsPDF y autotable desde jsdelivr).
- Archivo `supabase/examen-comun.sql`.

## Simulacros del ingreso

- En **Exámenes → Simulacros del ingreso**, la dirección o la oficina tocan **Iniciar simulacro**: nombre ("Simulacro 1"), grupos que lo rinden y los 5 exámenes con su fecha (**1 Álgebra y Aritmética · 2 Geometría · 3 Trigonometría · 4 Cálculo · 5 Física**; se pueden renombrar o dejar vacío el que no va). Cada examen vale **20 puntos** e **ingresa quien suma 60 de 100**.
- Cada examen del simulacro es un examen común a los grupos (una fila por grupo en `examenes`, mismo `comun`, más `simulacro` y `sim_n`), llamado "Simulacro 1 · Física". Las notas se cargan como en cualquier examen: a mano o **con la cámara** (hoja de Ingeniería de 20 preguntas). Tocando un examen en el simulacro se va a cargar sus notas y se vuelve al simulacro.
- La pantalla del simulacro va sumando a medida que se cargan los exámenes: **ranking** con puesto 1, 2, 3… (empates por orden alfabético), puntos de cada examen, total y resultado (**Ingresa** ≥ 60 · **No ingresa** · **En curso** con "le faltan N" mientras quedan exámenes sin notas; "—" = no rindió, 0 puntos); por examen: cargadas, promedio y **mayor puntaje** (quién). Filtro por grupo (el puesto sigue siendo entre todos), orden por puesto/nombre/grupo y "mostrar los que no rindieron".
- **Exportar**: **PDF con logo** (resumen, mayor puntaje de cada examen y la tabla con el resultado en verde/rojo; sin cédula, para mandar por WhatsApp) y **Excel** (con cédula; hojas "Por examen" y "Por grupo"). Exporta lo que se ve (grupo elegido y orden).
- **Editar** (dirección y oficina): cambiar el nombre (también el de sus exámenes) y **sumar grupos** (se les crean los mismos exámenes, con la clave de la cámara). La fecha o el puntaje de un examen se cambian en ese examen. **Borrar**: solo la dirección (borra sus exámenes y notas).
- Los profes ven los simulacros de sus grupos (solo sus alumnos) y cargan notas; no los inician. Funciones `crear_simulacro`, `simulacro_grupos`, `simulacro_renombrar`; tabla `simulacros`. Archivo `supabase/simulacros.sql`.

## Horario: grupos sin clases y días extra de una semana

- En **Armar horario**, un grupo **sin materias cargadas esa semana no entra** en el armado, el borrador, la imagen, los mensajes ni la publicación (por ejemplo, un grupo creado que todavía no empezó). Esos grupos quedan en la tarjeta compacta **"Sin clases esta semana"** con **Cargar materias**.
- **Días extra solo esa semana**: en cada grupo, la fila "Días de clase esta semana" muestra los días del grupo; tocando un día que no tiene (Sáb, Dom…) se suman clases extra: mañana → tarde → mañana y tarde → nada. En un día con un solo turno se puede sumar el otro. El grupo no cambia; se guarda en `materias_semana.extra` (`{"Sáb":"M","Dom":"MT"}`) y `publicar_horario` lo usa. Si a una materia se le fija un día que el grupo no tiene, ese día se suma solo como extra a la mañana. Las clases extra publicadas aparecen en la Semana, en Mi horario, en las listas de hoy de la oficina y en la toma de lista.
- Archivo `supabase/horario-extra.sql`.
- **Imagen para alumnos (sin profes)**: en la Semana publicada (dirección y oficina) y en el borrador de Armar horario, botón **Imagen para alumnos**. Arma la planilla de siempre: una fila por día (Lunes a Domingo con la fecha) y una columna por grupo y turno con las horas de ese grupo ("MAÑANA 8hs a 12hs", "TARDE 14hs a 18hs"), con "Materia-Tema" en cada celda y los colores de siempre (Álgebra negro, Aritmética gris oscuro, Trigonometría amarillo, Física rojo, Cálculo gris, Geometría verde), "EXAMEN …" en negrita, X donde no hay clase y FERIADO. Si el tema ya nombra la materia ("Repaso Cálculo") va solo el tema. Se eligen los grupos (chips) y se baja una imagen con todos o **una por grupo**. Los grupos salen en el orden del horario.
- **Orden de los grupos**: la dirección mueve cada grupo con las flechas **▲▼** de su bloque, en el borrador (Armar horario) y en la Semana publicada. Sube o baja entre los grupos que se ven en esa pantalla; el orden se guarda para todos (`grupos.orden`, con `ordenar_grupos()`), y lo siguen la imagen para el grupo, los mensajes y las listas. No cambia quién recibe los mejores profes (eso es "prioridad"). Reordenar no se anota en la Actividad. Archivo `supabase/orden-grupos.sql`.
- **Horas de clase de cada grupo**: en **Editar grupo → Horas de clase** se pone a qué hora empieza y termina la mañana y la tarde de ese grupo (sin cargar: 8:00 a 12:00 y 13:30 a 17:30). Se guardan en `grupos.horas` (`{"Mañana":{"ini":"08:00","fin":"12:00"},"Tarde":{"ini":"14:00","fin":"18:00"}}`; la base no acepta un fin antes del inicio). Salen en el título de cada grupo en el horario, en la imagen para alumnos y para profes, en el mensaje a cada profe, en Mi horario (alumno) y en las clases del profe; los avisos al celular de la noche y la mañana dicen esa hora, los de marcar entrada y salida llegan a esa hora, y la evaluación de la clase abre a esa hora. Archivo `supabase/horas-grupo.sql`.

## Recibo como imagen

- En el recibo (al cobrar o desde Cobros), **Enviar imagen por WhatsApp** manda la imagen del recibo (logo, N°, monto en números y letras, sello verde **PAGADO**, fecha, alumno y CI, concepto, grupo, forma de pago, saldo del curso —"Al día" en verde—, quién lo cobró). En el **celu** se abre el menú para compartir: se elige WhatsApp y el chat del encargado o del alumno (WhatsApp no deja elegir el chat desde un link). En la **compu** se copia la imagen y se abre el chat del encargado (o del alumno): se pega con Ctrl+V y se envía. Si el navegador no deja copiar, se descarga. Sin teléfono cargado, "Compartir imagen". La imagen se prepara al abrir el recibo. El envío solo de texto se reemplazó por esto ("Copiar texto" sigue). El alumno ve su recibo y lo descarga como imagen.

## Corrección con la cámara (hoja de respuestas VIBE)

- **Hoja para imprimir**: Exámenes → **Hoja de respuestas** (o desde la clave de un examen, con el nombre y la fecha ya puestos). Tres formatos: **Ingeniería 20** (a a e) y **Becas 40** (a a d) con el diseño de la matriz de siempre del cursillo (teléfono del cursillo y logo arriba, nombres, apellidos y ejemplo de llenado a la izquierda, cédula de 7 columnas y Fila 1–2 a la derecha), y **Medicina 60** (A a E) copiada de la hoja de la UNCA (cédula de 8 columnas, Fila 1 a 4, datos a la derecha). La cédula se llena desde la izquierda. Sin nombre de profe: solo Cursillo VIBE y su WhatsApp (0994 214 571, en `omr.js`). Las 4 marcas negras de las esquinas, la marca chica de arriba (dice dónde está "arriba") y el cuadradito del medio (dice qué formato es) son lo que lee la cámara: no se pueden tapar. Se puede fotocopiar.
- **Corregir**: en el examen, **Corregir con la cámara**. La primera vez pide la **clave**: se toca respuesta por respuesta o se **escanea una hoja llenada con la clave**. Una clave por fila (versión) del examen; si todos rinden lo mismo, solo la Fila 1. La clave se guarda en `examen_claves` (los alumnos no la pueden leer; se guarda con `guardar_clave()`, que la copia a todos los grupos del mismo examen y pone el puntaje máximo = cantidad de preguntas).
- Después se pasan las hojas frente a la cámara, una tras otra, **sin sacar fotos**: cuando dos cuadros seguidos leen lo mismo, suena, busca al alumno por la cédula entre los grupos del examen, corrige (correcta = 1, mal / en blanco / doble marca = 0) y **guarda la nota sola** con lo que marcó (`notas.respuestas`, `notas.fila`). La misma hoja no se lee dos veces aunque quede frente a la cámara.
- **Para resolver**: cédula que no está en el grupo, cédula mal marcada, fila sin clave o la misma cédula en dos hojas distintas quedan en la lista; se toca, se elige el alumno y se guarda. Las marcas dudosas (muy claras o a medias) salen en amarillo para mirarlas en la hoja; ahí mismo se puede cambiar cualquier respuesta.
- **Ver hoja**: en el examen, los alumnos corregidos con la cámara tienen "ver hoja" (lo que marcó contra la clave, editable). Si se corrige la clave después, las notas de las hojas ya leídas se **recalculan solas**. Si se cambia a mano una nota leída, pasa a ser nota a mano.
- **Subir fotos**: si la cámara no anda (permiso, navegador viejo), se pueden subir fotos de las hojas.
- El lector (`omr.js`) corre en el celu, sin internet para leer y sin costo: busca las marcas, endereza la hoja, se alinea con los círculos impresos (aguanta la hoja un poco doblada, sombras y luz despareja) y rechaza los cuadros borrosos en vez de adivinar. Probado con 190 fotos simuladas (0 respuestas mal leídas) y con una cámara simulada en Chrome.
- Archivos `omr.js` (diseño de la hoja y lector) y `supabase/correccion-omr.sql`.

## Tareas de la oficina y la librería

En **Tareas** (dirección y oficina; también en el Inicio de las dos):

- Cualquiera anota lo que hay que hacer: qué, detalle, tipo (Oficina, Librería, Compras, Recordar a Guido), para quién (una persona de la oficina o cualquiera), para cuándo y si es urgente.
- Se marca como hecha con el cuadradito (o desde el detalle, con una nota). Queda **quién la anotó, quién la editó y quién la hizo, con día y hora** (lo pone la base, no se puede falsear). Una tarea hecha se puede volver a abrir.
- Se actualizan en vivo para todas. Solo la dirección borra. Las hechas se ven 45 días.
- La dirección ve primero las de "Recordar a Guido". El menú muestra cuántas le tocan a cada una.

## Registro de actividad (solo dirección)

En **Actividad** queda anotado todo lo que cada persona hace con su cuenta: cobros y anulaciones, alumnos nuevos o editados (qué dato cambió, antes → después), listas, notas y exámenes, grupos, links de inscripción, turnos de oficina, entradas y salidas, caja chica, tareas, pedidos de cambio, disponibilidades, cuentas y roles, plantel y ajustes.

- Se filtra por día (o 7 días o el mes), persona (o toda la oficina / todos los profes), tipo, y se busca por texto. Tocando un movimiento se ve el detalle.
- Las listas y las notas se agrupan: una fila por lista o examen y persona ("Llamó lista de CPI 2 · 14/11 mañana: 25 alumnos (22 P · 2 A · 1 T)").
- En la ficha de cada alumno, pestaña **Movimientos**: quién le cargó o cambió algo (datos y pagos).
- Nadie lo puede editar ni borrar desde la app, ni la dirección. Los cambios hechos directo en la base (SQL) no se anotan.
- Base: tabla `actividad` + trigger `actividad_anotar` en las tablas principales (`supabase/tareas-actividad.sql`, también al final de `schema.sql`).

## Archivos

```
index.html              la app completa
config.js               URL y anon key de Supabase (lo único que se edita)
manifest.webmanifest    para instalarla en el celular
img/                    logo oficial (y versión para modo oscuro)
icons/                  íconos de la app con el √iβε
supabase/schema.sql     base de datos y permisos (se puede volver a correr)
supabase/tareas-actividad.sql  tareas de la oficina y registro de actividad (también está en schema.sql)
supabase/horas-caja.sql  entrada y salida (oficina y profes) y caja chica (también está en schema.sql)
supabase/caja-cobros.sql  parte del cobro para la caja chica (también está en schema.sql)
supabase/pedir-acceso.sql  alumnos que piden acceso sin invitación (también está en schema.sql)
supabase/examen-comun.sql  examen común a varios grupos (también está en schema.sql)
supabase/correccion-omr.sql  clave de respuestas y hojas leídas con la cámara (también está en schema.sql)
supabase/simulacros.sql  simulacros del ingreso (también está en schema.sql)
omr.js                  hoja de respuestas VIBE: el PDF para imprimir y el lector de la cámara
supabase/importar-horarios.sql  trae los datos de la app vibe-horarios
supabase/functions/     invitar (manda invitaciones), notificar (avisa fichas nuevas) y push (avisos al celular)
supabase/cron-push.sql  avisos programados: llama a la función push cada 15 minutos
sw.js                   service worker: muestra los avisos en el celular
supabase/plantillas/    correos en español: invitación y recuperar contraseña
```

## Puesta en marcha (una sola vez)

### 1. Supabase
1. Entrar a supabase.com con **informacion@vibe.com.py** y crear el proyecto `vibe-app` (región São Paulo).
2. **SQL Editor** → New query → pegar `supabase/schema.sql` → Run.
3. **Authentication → Sign In / Providers**: dejar activado "Allow new users to sign up" (lo usan el link de inscripción y "Pedir acceso") y activado **"Confirm email"**. Una cuenta creada sin link ni pedido no ve nada: no tiene ficha; la de un pedido no ve ningún grupo hasta que la oficina se lo asigna.
4. **Authentication → URL Configuration**: Site URL y Redirect URLs = la dirección de la app.
5. **Authentication → Emails → SMTP**: `smtp.gmail.com`, puerto `465`, usuario `informacion@vibe.com.py`, contraseña = *contraseña de aplicación* de Google (la crea la dirección en myaccount.google.com → Seguridad → Contraseñas de aplicaciones; requiere verificación en 2 pasos). Remitente: "Cursillo VIBE".
6. **Authentication → Emails → Templates**: pegar `plantillas/invitacion.html` en *Invite user* (asunto: "Tu acceso a la app de VIBE"), `plantillas/confirmar.html` en *Confirm signup* (asunto: "Confirmá tu correo para inscribirte en VIBE") y `plantillas/recuperar.html` en *Reset password* (asunto: "Cambiá tu contraseña de VIBE").
7. **Authentication → Rate Limits**: subir los correos por hora a 100.
8. **Edge Functions** → crear `invitar` y `notificar` con el código de `supabase/functions/`.
9. **Edge Functions → Secrets**: `APP_URL` (dirección de la app), `SMTP_USER` (informacion@vibe.com.py), `SMTP_PASS` (la contraseña de aplicación), `NOTIF_TO` (a quién avisar de fichas nuevas).
10. **Project Settings → API**: copiar la URL y la `anon public` key a `config.js`. La `service_role` no va nunca en la app.
11. **Avisos al celular**: Edge Functions → crear `push` con `supabase/functions/push/index.ts` y **apagar "Verify JWT"** (el código valida quién llama). Después, SQL Editor → correr `supabase/cron-push.sql`. No hay que cargar claves: la función genera sola sus claves VAPID la primera vez y las guarda en `config_privada`.

### 2. Publicar la app (GitHub Pages)
1. Repo nuevo `vibe-app` con estos archivos.
2. Settings → Pages → Deploy from branch → `main` / root.
3. La app queda en `https://USUARIO.github.io/vibe-app/`. Para `app.vibe.com.py`: agregar el dominio en Pages y un registro CNAME en el DNS de vibe.com.py.

### 3. Primer ingreso
Authentication → Users → **Invite user** → informacion@vibe.com.py. Entra como Dirección automáticamente (está en `config_privada.admins`). Desde ahí se suma al resto del equipo en **Equipo** y a los alumnos en **Inscripciones**.

Para agregar otro correo de dirección: `update config_privada set valor = valor || '["otro@correo.com"]' where clave = 'admins';` antes de invitarlo.

## La ficha de inscripción
Unifica los formularios de Google de VIBE (CPI Ingeniería, Bachilleres y Becas). Las preguntas comunes le salen a todos; algunas dependen del **curso** con el que la oficina invita al alumno:
- **Ingeniería:** si trabaja y a qué carrera quiere ingresar.
- **Ingeniería y Medicina:** con quién vive.
- **Ingreso a colegios:** a qué bachillerato y a qué colegio quiere entrar.
- **Ingeniería:** en qué parte del mes prefiere pagar (1–10, 11–20, 21–fin). Sus vencimientos se corren a esa fecha.

Turno (mañana/tarde) y modalidad (presencial/virtual) no se preguntan: los define el grupo que asigna la oficina.

Para cambiar preguntas: lista `FICHA` al principio del script de `index.html`. `col: true` = columna propia de `alumnos`; el resto va a `alumnos.ficha`. `solo: [...]` = cursos donde aparece; `reqSi` = obligatoria según otra respuesta.

Las respuestas viejas de los formularios de Google se pueden importar: en **Importar**, subís la planilla de respuestas y la app reconoce cada columna sola.

## Evaluación anónima de clases

- Cada día, desde **Inicio → Evaluación de las clases de hoy** (o desde la lista ya llamada), la oficina, la dirección o el profe de ese día sacan un **link por grupo** y lo mandan al WhatsApp del grupo.
- El alumno lo abre **sin cuenta** y califica cada clase del día: calificación (Muy mala → Excelente), puntualidad, si se entendió, si le aclararon las dudas, cómo terminó y un comentario. Se puede responder desde que empieza la clase hasta el día siguiente.
- **Anónimo:** la respuesta no guarda quién la mandó (ni cuenta, ni correo, ni celular, ni hora). La página usa una conexión aparte, sin la sesión del alumno aunque tenga la app abierta. Una respuesta por celular y **cupo por clase = presentes de la lista** (presente o tarde): la evaluación de una clase se habilita cuando se llama lista y recibe como máximo tantas respuestas como presentes hubo.
- Resultados solo para la dirección en **Horario → Evaluaciones**: por profe, por materia y comentarios.

## Actualización en vivo

La app se actualiza sola: cuando alguien guarda algo (lista, cobro, pedido de cambio, turno, horario), los demás lo ven en uno o dos segundos sin recargar (Supabase Realtime, que respeta los permisos de cada uno). Si alguien está escribiendo o tiene algo sin guardar, espera a que termine. De respaldo, cada 2 minutos refresca. Las evaluaciones anónimas no se publican en vivo.

## Avisos al celular (notificaciones)

Les llegan a quienes **instalaron la app y tocaron "Activar avisos"** (en Inicio o en Mi cuenta) en su celular. En Android funciona desde Chrome; en iPhone primero hay que agregar la app a la pantalla de inicio desde Safari (Compartir → Agregar a inicio) y abrirla desde el ícono. Es gratis (web push).

- **Al publicar el horario** (casilla al lado de Publicar): a cada profe "Salió el horario: tenés N clases" y a los alumnos de los grupos con clases "Ya está tu horario". Si se vuelve a publicar, dice "Se actualizó".
- **A la noche** (20:00 por defecto) las clases de mañana y **a la mañana** (6:30) las de hoy. Alumnos: materia, tema y hora, y que preparen sus cosas (si es examen, otro texto). Profes: materia, tema, grupo y hora, y que llamen lista.
- **Disponibilidad** a los profes que todavía no cargaron: miércoles 17:00, jueves y viernes 13:00, sábado 11:00 (último aviso).
- **Marcar la clase** (profes): a la hora de inicio de su grupo "Empieza tu clase: Álgebra en CPI2, 8:00. No te olvides de marcar tu entrada y de llamar lista" (solo si todavía no marcó la entrada; se manda hasta 1 hora después) y a la hora de fin "Terminó tu clase… marcá tu salida" (solo si no la marcó; si tampoco marcó la entrada: "Te faltó marcar tu clase… cargalas en Tus entradas y salidas"). Le llega a quien da la clase: el profe del horario o el que pidió el cambio (si no se lo rechazaron); los exámenes no. Se apagan en Ajustes (`prEntrada`, `prSalida`). Las horas son las de cada grupo (**Editar grupo → Horas de clase**). Textos en `push_marcar_ahora()` (`supabase/horas-grupo.sql`); sale una sola vez por profe, día, turno y tipo.
- **Oficina**: a la noche "Mañana te toca la oficina: turno de la tarde" y a la mañana "Hoy te toca la oficina… marcá tu turno" (solo turnos asignados por la dirección); disponibilidad los mismos días que los profes; y desde **Turnos oficina → Avisar al celular** la dirección le manda a cada uno sus turnos de la semana (si lo vuelve a mandar, dice "Se actualizaron").
- Horas y qué se manda a quién: **Ajustes → Avisos al celular** (también muestra quiénes ya los activaron y arma un mensaje de WhatsApp para pedirles que los activen).
- Cómo funciona: el cron llama a la función `push` cada 15 minutos; la función mira la hora de Paraguay y lo que dice Ajustes, y cada aviso sale una sola vez por día (`push_log`). Los textos se arman en la base (`push_mensajes`). Si un celular desinstaló la app, se borra solo.

