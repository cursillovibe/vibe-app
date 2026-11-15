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
- **Invitación por correo**: la oficina carga el correo del alumno y le llega un mail para crear su contraseña.

En los dos casos, cuando completa la ficha le llega un correo a informacion@ y la oficina le asigna el grupo. Cerrar un link (desmarcar "activo") corta la inscripción por ese link.

## Dónde está
- App: https://cursillovibe.github.io/vibe-app/
- Código: https://github.com/cursillovibe/vibe-app
- Base de datos: Supabase, proyecto **VIBE App** (São Paulo), organización Cursillo VIBE.

## Horario y pago a profes

Reemplaza a la app vibe-horarios (sus datos se importaron con `supabase/importar-horarios.sql`). Todo está en **Horario**:

- **Disponibilidad**: cada profe marca sus turnos libres de la semana siguiente desde el miércoles hasta el sábado 17:00. La dirección puede reabrir la carga y avisar por WhatsApp a los que faltan.
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

- Cada persona de oficina carga su disponibilidad de la semana siguiente (mismo plazo que los profes) desde **Mis turnos**.
- La dirección arma la semana tocando nombres (en verde, los que pueden) o con "Completar con disponibles", y manda el mensaje al grupo por WhatsApp. En "Horario de la oficina" se eligen los turnos que abre cada día (por defecto lunes a viernes mañana, tarde y noche; sábado y domingo mañana y tarde).
- Cada persona **marca su turno** el día que trabaja (desde Inicio o Mis turnos). Si trabaja un turno que no tenía, lo pide y la dirección lo aprueba.
- **Pago por turno**: por mes, cuenta cada turno asignado (o pedido y aprobado) que la persona marcó el mismo día. El monto por turno solo lo ve la dirección.
- **Imagen para el grupo** (Turnos oficina): una columna por día y una fila por turno (mañana, tarde, noche) con quiénes trabajan, y "SIN NADIE" donde falta cubrir. Mismo estilo que la imagen del horario de los profes.

## Archivos

```
index.html              la app completa
config.js               URL y anon key de Supabase (lo único que se edita)
manifest.webmanifest    para instalarla en el celular
img/                    logo oficial (y versión para modo oscuro)
icons/                  íconos de la app con el √iβε
supabase/schema.sql     base de datos y permisos (se puede volver a correr)
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
3. **Authentication → Sign In / Providers**: dejar activado "Allow new users to sign up" (lo usa el link de inscripción) y activado **"Confirm email"**. Una cuenta creada sin un link válido no ve nada: no tiene ficha.
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
- **Oficina**: a la noche "Mañana te toca la oficina: turno de la tarde" y a la mañana "Hoy te toca la oficina… marcá tu turno" (solo turnos asignados por la dirección); disponibilidad los mismos días que los profes; y desde **Turnos oficina → Avisar al celular** la dirección le manda a cada uno sus turnos de la semana (si lo vuelve a mandar, dice "Se actualizaron").
- Horas y qué se manda a quién: **Ajustes → Avisos al celular** (también muestra quiénes ya los activaron y arma un mensaje de WhatsApp para pedirles que los activen).
- Cómo funciona: el cron llama a la función `push` cada 15 minutos; la función mira la hora de Paraguay y lo que dice Ajustes, y cada aviso sale una sola vez por día (`push_log`). Los textos se arman en la base (`push_mensajes`). Si un celular desinstaló la app, se borra solo.

