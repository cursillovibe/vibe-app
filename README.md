# VIBE App

App web del Cursillo VIBE para dirección, oficina, profes y alumnos. Se instala en el celular como una app ("Agregar a pantalla de inicio").

| Rol | Qué hace |
|---|---|
| **Dirección** (informacion@vibe.com.py) | Todo: grupos, alumnos, cobros, asistencia, notas, equipo y ajustes. Es la única que puede anular pagos, borrar y cambiar roles. |
| **Oficina** | Invita alumnos, asigna grupos, cobra y emite recibos, toma lista y carga notas. |
| **Profe** | Solo sus grupos: toma lista, carga notas, ve contactos, historial y su horario. No ve cuotas. |
| **Alumno** | Completa su ficha, ve sus cuotas y recibos, sus notas (con promedio del grupo y puesto), su asistencia y edita sus datos. |

**Cómo entra un alumno (dos caminos):**
- **Link de inscripción** (el principal): la oficina crea en **Inscripciones** un link por curso o por grupo y se lo pasa por WhatsApp al alumno que pagó la matrícula → el alumno crea su cuenta con su correo → completa la ficha.
- **Invitación por correo**: la oficina carga el correo del alumno y le llega un mail para crear su contraseña.

En los dos casos, cuando completa la ficha le llega un correo a informacion@ y la oficina le asigna el grupo. Cerrar un link (desmarcar "activo") corta la inscripción por ese link.

## Dónde está
- App: https://cursillovibe.github.io/vibe-app/
- Código: https://github.com/cursillovibe/vibe-app
- Base de datos: Supabase, proyecto **VIBE App** (São Paulo), organización Cursillo VIBE.

## Archivos

```
index.html              la app completa
config.js               URL y anon key de Supabase (lo único que se edita)
manifest.webmanifest    para instalarla en el celular
img/                    logo oficial (y versión para modo oscuro)
icons/                  íconos de la app con el √iβε
supabase/schema.sql     base de datos y permisos (se corre una vez)
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
