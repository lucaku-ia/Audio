# Lucaku Audio

Un servicio de investigación personal entregado en audio: el cliente dice qué quiere
saber, Lucaku investiga, y lo entrega hablado — hoy la primera vez, y cada día después
a la hora que el cliente eligió.

**Este repo reemplaza el enfoque anterior de Lucaku** (plataforma de ventas/compras/
producción para manufactura, ahora archivada en `lucaku-ia/LUCAKU`). Es un producto
nuevo desde cero.

## Estado actual (fundación técnica v0.1)

Solo backend + modelos de datos, sin UI todavía. Implementa los objetos definidos en
`Lucaku_System_Contracts.docx` (v0.1):

| Objeto | Archivo | PRD de origen |
|---|---|---|
| `Request`, `RequestVersion` | `app/models/request.py` | Request Management |
| `Profile` | `app/models/profile.py` | Request Management / Onboarding |
| `Episode`, `Block` | `app/models/episode.py` | Episode Generator |
| `GenerationJob`, `InventoryItem` | `app/models/generation_job.py` | Episode Generator |
| `Event`, `AICall` | `app/models/instrumentation.py` | Instrumentation & Cost / AI Platform |
| `Cliente` (placeholder) | `app/models/cliente.py` | **Login PRD — no existe todavía, ver abajo** |

## Pendiente conocido

Tres PRDs están referenciados por los demás documentos pero **no existen** en la
carpeta de Drive fuente:

- **Login PRD** — cuenta, autenticación, biometría. `Cliente` en este repo es un
  placeholder mínimo hasta que aparezca.
- **Home PRD** — pantalla principal, banners, sugerencias.
- **Player PRD** — reproductor de audio, eventos de escucha, refinamiento.

Escribirlos (o encontrarlos) antes de construir Onboarding, Notifications o
Search & AI a fondo, porque esos PRDs ya asumen decisiones que deberían vivir ahí.

## Stack

FastAPI + SQLAlchemy 2.0 async + PostgreSQL — mismo stack que el proyecto de
manufactura, reutilizado por familiaridad del equipo. Ningún cliente (mobile/web)
se ha decidido todavía; varios PRDs (Notifications, Login) asumen una app móvil
(iOS con APNs, biometría, deep links `lucaku://play/{episode_id}`) — esa decisión
de plataforma de cliente sigue abierta.

## Levantar localmente

```bash
cd backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt

# copiar .env.example a .env y completar DATABASE_URL

uvicorn app.main:app --reload --port 8000
```
