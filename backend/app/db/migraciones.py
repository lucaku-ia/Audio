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


async def ejecutar_migraciones(engine: AsyncEngine):
    async with engine.begin() as conn:
        for tabla, columna, tipo in COLUMNAS_ESPERADAS:
            if not await _tabla_existe(conn, tabla):
                continue  # new table — create_all() already created it with this column
            if not await _columna_existe(conn, tabla, columna):
                logger.info("Adding column %s to %s", columna, tabla)
                await conn.execute(text(f"ALTER TABLE {tabla} ADD COLUMN {columna} {tipo}"))
