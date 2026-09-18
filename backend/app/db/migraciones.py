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

The same gotcha applies to constraints and indexes: create_all() never adds
a UniqueConstraint (or any other index) to a table Postgres already has —
it only diffs for missing tables. INDICES_ESPERADOS below covers that case
the same way COLUMNAS_ESPERADAS does: check pg_indexes first, only issue
the CREATE if it's missing, so this is safe to rerun on every boot.

A UNIQUE index backfilled onto a table that already has rows can fail if
any of those rows violate the new uniqueness — e.g. generation_jobs had no
duplicate protection at all before this index was added, so any
(customer_id, fecha, path) collision created before this shipped would
make the plain CREATE UNIQUE INDEX below raise and — since ejecutar_migraciones
is awaited directly in app.main's lifespan with no try/except — crash app
startup entirely. Two safeguards against that: (1) a dedup pass specific to
generation_jobs, run before the index attempt, that deletes all but the
earliest row (by creado_en) per (customer_id, fecha, path); (2) each index
CREATE is still wrapped in its own try/except so a problem this dedup
didn't anticipate logs an error and lets the app boot with the index
missing, rather than crashing outright — an index that failed to apply is
recoverable on the next deploy; a boot loop is not.
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
INDICES_ESPERADOS: list[tuple[str, str, str]] = [
    (
        "generation_jobs",
        "uq_generation_jobs_customer_fecha_path",
        "CREATE UNIQUE INDEX uq_generation_jobs_customer_fecha_path "
        "ON generation_jobs (customer_id, fecha, path)",
    ),
]

# Dedup statements to run before their matching index, keyed by index name —
# only needed for indexes backfilled onto a table that could already hold
# violating rows. Deletes every row except the earliest (by creado_en) per
# the index's key columns.
DEDUP_ANTES_DE_INDICE: dict[str, str] = {
    "uq_generation_jobs_customer_fecha_path": """
        DELETE FROM generation_jobs a USING generation_jobs b
        WHERE a.customer_id = b.customer_id
          AND a.fecha = b.fecha
          AND a.path = b.path
          AND (a.creado_en, a.id) > (b.creado_en, b.id)
    """,
}


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
            dedup_sql = DEDUP_ANTES_DE_INDICE.get(indice)
            try:
                # A SAVEPOINT (begin_nested), not the outer transaction directly — if
                # this specific index fails, only its own work rolls back; the outer
                # `async with engine.begin()` transaction (and anything COLUMNAS_ESPERADAS
                # already did in it) stays intact and still commits normally on exit.
                async with conn.begin_nested():
                    if dedup_sql:
                        result = await conn.execute(text(dedup_sql))
                        if result.rowcount:
                            logger.warning(
                                "Deleted %d duplicate row(s) from %s before adding unique index %s",
                                result.rowcount, tabla, indice,
                            )
                    logger.info("Adding index %s on %s", indice, tabla)
                    await conn.execute(text(sql_create))
            except Exception:
                # Don't let one unexpected index failure crash startup — see module
                # docstring. The app runs without this index's guarantee until the
                # next successful deploy retries it.
                logger.exception("Failed to add index %s on %s — continuing without it", indice, tabla)
