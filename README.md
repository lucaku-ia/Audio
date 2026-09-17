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
| `Cliente` | `app/models/cliente.py` | Login PRD (Juan, Draft v2) |

## Estado de los PRDs

Los 3 PRDs que faltaban en la carpeta de Drive (Login, Home, Player) existían como
Google Docs separados y ya se incorporaron:

- **Login PRD** (Juan, Draft v2 — propuesto por Andrés) — login obligatorio, 3 métodos
  (Google/Apple/email), biometría por dispositivo, ruteo por `onboarding_complete`.
- **Home PRD** (Andrés, Draft v1) — banner con estados, últimos 3 episodios, sugerencias
  explicables, día vacío, re-entrada.
- **Player PRD** (Juan, Draft v1) — barra persistente + reproductor completo, navegación
  por bloque/request, refinamiento, modo offline, media session del OS.

Aún no construidos en este repo: Onboarding, Request Management (lógica), Episode
Generator, AI Platform, Search & AI, Notifications+Settings, Instrumentation dashboard.
Todos dependen de la fundación de datos que ya está aquí.

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
