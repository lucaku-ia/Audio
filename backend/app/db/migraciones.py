"""
Migración idempotente de columnas — se ejecuta en el lifespan tras create_all().

create_all() crea TABLAS nuevas pero nunca altera columnas de tablas que ya
existen (lección aprendida en el proyecto de manufactura, dos veces: con
Workspace.modulos_activos y con Cliente.intentos_fallidos/token_version).
Esta lista declarativa evita tener que correr ALTER TABLE a mano cada vez
que un modelo gana un campo nuevo.

Agregar una fila aquí cuando se agregue una columna a un modelo existente.
No hace falta nada si la columna nace en una tabla nueva (create_all ya la crea).
"""
import logging
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

logger = logging.getLogger(__name__)

# (tabla, columna, tipo SQL + default)
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
                continue  # tabla nueva — create_all() ya la creo con esta columna
            if not await _columna_existe(conn, tabla, columna):
                logger.info("Agregando columna %s a %s", columna, tabla)
                await conn.execute(text(f"ALTER TABLE {tabla} ADD COLUMN {columna} {tipo}"))
