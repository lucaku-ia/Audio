"""
Idempotent column migration — runs in the lifespan after create_all().

create_all() creates new TABLES but never alters columns on tables that
already exist (a lesson learned twice in the manufacturing project: with
Workspace.modulos_activos and with Cliente.intentos_fallidos/token_version).
This declarative list avoids having to run ALTER TABLE by hand every time
a model gains a new field.

Add a row here whenever a column is added to an existing model. Nothing
needed if the column is born on a brand-new table (create_all already
creates it).

The same gotcha applies to indexes: create_all() never adds an index to a
table Postgres already has — it only diffs for missing tables. INDICES_ESPERADOS
below covers that case the same way COLUMNAS_ESPERADAS does: check pg_indexes
first, only issue the CREATE if it's missing, so this is safe to rerun on
every boot. Each CREATE runs in its own SAVEPOINT (conn.begin_nested()) and
is wrapped in its own try/except — one index failing to apply (e.g. a
transient lock) logs an error and lets the app boot without it, rather than
crashing startup and boot-looping the whole service. Search & AI's keyword
search (app/api/routes/search.py) relies on the GIN indexes below.
"""
import logging
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

logger = logging.getLogger(__name__)

# (table, column, SQL type + default)
COLUMNAS_ESPERADAS: list[tuple[str, str, str]] = [
    ("clientes", "intentos_fallidos", "INTEGER DEFAULT 0"),
    ("clientes", "bloqueado_hasta", "TIMESTAMPTZ"),
    ("clientes", "token_version", "INTEGER DEFAULT 0"),
]

# (table, index name, "CREATE [UNIQUE] INDEX ... ON ..." statement, without "IF NOT EXISTS")
# GIN indexes over the exact `to_tsvector('simple', ...)` expression the search
# queries use in app/api/routes/search.py — the expression must match verbatim
# for Postgres to use the index instead of a sequential scan.
INDICES_ESPERADOS: list[tuple[str, str, str]] = [
    (
        "episodes",
        "ix_episodes_headline_fts",
        "CREATE INDEX ix_episodes_headline_fts ON episodes "
        "USING GIN (to_tsvector('simple', coalesce(headline, '')))",
    ),
    (
        "blocks",
        "ix_blocks_summary_fts",
        "CREATE INDEX ix_blocks_summary_fts ON blocks "
        "USING GIN (to_tsvector('simple', coalesce(summary, '')))",
    ),
    (
        "requests",
        "ix_requests_raw_text_fts",
        "CREATE INDEX ix_requests_raw_text_fts ON requests "
        "USING GIN (to_tsvector('simple', raw_text))",
    ),
]


async def _tabla_existe(conn, tabla: str) -> bool:
    result = await conn.execute(text(
        "SELECT 1 FROM information_schema.tables WHERE table_name = :tabla"
    ), {"tabla": tabla})
    return result.scalar() is not None


async def _columna_existe(conn, tabla: str, columna: str) -> bool:
    result = await conn.execute(text(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_name = :tabla AND column_name = :columna"
    ), {"tabla": tabla, "columna": columna})
    return result.scalar() is not None


async def _indice_existe(conn, tabla: str, indice: str) -> bool:
    result = await conn.execute(text(
        "SELECT 1 FROM pg_indexes WHERE tablename = :tabla AND indexname = :indice"
    ), {"tabla": tabla, "indice": indice})
    return result.scalar() is not None


async def ejecutar_migraciones(engine: AsyncEngine):
    async with engine.begin() as conn:
        for tabla, columna, tipo in COLUMNAS_ESPERADAS:
            if not await _tabla_existe(conn, tabla):
                continue  # new table — create_all() already created it with this column
            if not await _columna_existe(conn, tabla, columna):
                logger.info("Adding column %s to %s", columna, tabla)
                await conn.execute(text(f"ALTER TABLE {tabla} ADD COLUMN {columna} {tipo}"))

        for tabla, indice, sql_create in INDICES_ESPERADOS:
            if not await _tabla_existe(conn, tabla):
                continue  # new table — create_all() already created it with this index
            if await _indice_existe(conn, tabla, indice):
                continue
            try:
                # A SAVEPOINT (begin_nested), not the outer transaction directly — if
                # this specific index fails, only its own work rolls back; the outer
                # `async with engine.begin()` transaction (and anything COLUMNAS_ESPERADAS
                # already did in it) stays intact and still commits normally on exit.
                async with conn.begin_nested():
                    logger.info("Adding index %s on %s", indice, tabla)
                    await conn.execute(text(sql_create))
            except Exception:
                # Don't let one unexpected index failure crash startup — see module
                # docstring. The app runs without this index's guarantee until the
                # next successful deploy retries it.
                logger.exception("Failed to add index %s on %s — continuing without it", indice, tabla)
