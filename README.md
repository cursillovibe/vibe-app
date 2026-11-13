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
- **Semana**: las clases publicadas, con quién llamó lista en cada una.
- **Cambios**: cuando un profe va a dar una clase que no está a su nombre (reemplazo, cambio entre profes), la pide desde la app. Con el pedido ya puede llamar lista; la dirección lo aprueba antes o después de la clase y recién ahí la clase pasa a su nombre y le cuenta para el pago.
- **Plantel**: profes, puntajes y pago por clase (solo la dirección).
- **Pago a profes**: por mes, cuenta cada clase en la que el profe del horario (o con el cambio aprobado) llamó lista. Mañana y tarde cuentan por separado. Los exámenes que cuidó se ven pero no suman. Las clases sin lista se pueden marcar a mano (si firmó en papel).

Cuando un profe llama lista, la clase queda registrada a su nombre con la hora. Solo puede llamar lista el mismo día y en sus clases (o con un pedido de cambio); la oficina corrige listas viejas.

## Turnos de oficina

En **Turnos oficina** (solo la dirección): turnos Mañana, Tarde y Noche.

- Cada persona de oficina carga su disponibilidad de la semana siguiente (mismo plazo que los profes) desde **Mis turnos**.
- La dirección arma la semana tocando nombres (en verde, los que pueden) o con "Completar con disponibles", y manda el mensaje al grupo por WhatsApp. En "Horario de la oficina" se eligen los turnos que abre cada día.
- Cada persona **marca su turno** el día que trabaja (desde Inicio o Mis turnos). Si trabaja un turno que no tenía, lo pide y la dirección lo aprueba.
- **Pago por turno**: por mes, cuenta cada turno asignado (o pedido y aprobado) que la persona marcó el mismo día. El monto por turno solo lo ve la dirección.

## Archivos

```
index.html              la app completa
config.js               URL y anon key de Supabase (lo único que se edita)
manifest.webmanifest    para instalarla en el celular
img/                    logo oficial (y versión para modo oscuro)
icons/                  íconos de la app con el √iβε
supabase/schema.sql     base de datos y permisos (se puede volver a correr)
supabase/importar-horarios.sql  trae los datos de la app vibe-horarios
supabase/functions/     invitar (manda invitaciones) y notificar (avisa fichas nuevas)
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
