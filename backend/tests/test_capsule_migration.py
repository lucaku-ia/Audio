"""
Phase 1a adds columns to EXISTING tables (blocks, episodes). create_all() never
alters an existing table, so production only gets them through
app/db/migraciones.py. conftest only ever uses create_all, which would hide a
missing COLUMNAS_ESPERADAS row, so this test rebuilds the OLD shape in place:

  1. create a legacy episode + block through the ORM,
  2. DROP the new columns (the pre-capsule schema),
  3. run the app's own ejecutar_migraciones(),
  4. assert the columns are back, the old rows read as legacy with safe
     defaults, and a second run changes nothing.

Not done on a separate Postgres schema: _columna_existe looks columns up in
information_schema by table name only, so a copy in another schema would see
`public`'s columns and pass for the wrong reason.
"""
import logging
import uuid
from datetime import datetime, timezone

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import create_async_engine

from app.db.migraciones import COLUMNAS_ESPERADAS, ejecutar_migraciones
from app.db.session import DATABASE_URL, ENGINE_CONNECT_ARGS
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Block, Episode, EpisodePath
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import capsules, told_log

NEW_COLUMNS = [
    ("blocks", "audio_url"), ("blocks", "duration_s"), ("blocks", "audio_status"),
    ("blocks", "voice_attempts"), ("blocks", "sequence"), ("blocks", "voicing_started_at"),
    ("episodes", "playlist_version"),
]


async def _columns(engine, table: str) -> set[str]:
    async with engine.begin() as conn:
        rows = await conn.execute(text(
            "SELECT column_name FROM information_schema.columns WHERE table_name = :t"), {"t": table})
        return {r[0] for r in rows}


def test_every_new_column_is_registered():
    registered = {(t, c) for t, c, _ in COLUMNAS_ESPERADAS}
    assert set(NEW_COLUMNS) <= registered
    defaults = {(t, c): sql for t, c, sql in COLUMNAS_ESPERADAS}
    assert defaults[("episodes", "playlist_version")] == "INTEGER DEFAULT 1"  # old episodes = legacy


async def test_migration_adds_the_capsule_columns_to_an_old_schema(full_db_session, caplog):
    db = full_db_session
    c = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                hashed_password=None, nombre="Legacy", idioma="en")
    db.add(c)
    await db.flush()
    req = Request(customer_id=c.id, kind=RequestKind.standing, raw_text="legacy topic", structured={},
                  status=RequestStatus.active, created_from=CreatedFrom.onboarding)
    db.add(req)
    await db.flush()
    ep = Episode(customer_id=c.id, fecha=datetime.now(timezone.utc).date(), path=EpisodePath.scheduled,
                 audio_url="https://x/old.mp3", published_at=datetime.now(timezone.utc))
    db.add(ep)
    await db.flush()
    block = Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=40, summary="old block", script="x")
    db.add(block)
    await db.commit()
    ep_id, block_id, req_id, cust_id = ep.id, block.id, req.id, c.id
    db.expunge_all()

    engine = create_async_engine(DATABASE_URL, echo=False, connect_args=ENGINE_CONNECT_ARGS)
    try:
        async with engine.begin() as conn:
            for table, col in NEW_COLUMNS:
                await conn.execute(text(f"ALTER TABLE {table} DROP COLUMN {col}"))
        for table, col in NEW_COLUMNS:
            assert col not in await _columns(engine, table), "test setup failed to build the old schema"

        with caplog.at_level(logging.INFO, logger="app.db.migraciones"):
            await ejecutar_migraciones(engine)
        added = [r.getMessage() for r in caplog.records if r.getMessage().startswith("Adding column")]
        assert len(added) == len(NEW_COLUMNS)

        for table, col in NEW_COLUMNS:
            assert col in await _columns(engine, table)

        # Existing rows get safe values: legacy status, version 1, zero counters.
        async with engine.begin() as conn:
            row = (await conn.execute(text(
                "SELECT playlist_version FROM episodes WHERE id = :i"), {"i": ep_id})).one()
            blk = (await conn.execute(text(
                "SELECT audio_url, duration_s, audio_status, voice_attempts, sequence "
                "FROM blocks WHERE id = :i"), {"i": block_id})).one()
        assert row[0] == 1
        assert tuple(blk) == (None, None, None, 0, 0)

        # And the app reads the old row as a legacy block that counts as told.
        old = (await db.execute(select(Block).where(Block.id == block_id))).scalar_one()
        assert capsules.is_in_legacy_file(old) and capsules.counts_as_delivered(old)
        assert await told_log.recent_for_request(db, customer_id=cust_id, request_id=req_id) == ["old block"]

        # Second run: nothing left to add, nothing logged, nothing changed.
        caplog.clear()
        with caplog.at_level(logging.INFO, logger="app.db.migraciones"):
            await ejecutar_migraciones(engine)
        assert [r for r in caplog.records if r.getMessage().startswith("Adding column")] == []
    finally:
        await ejecutar_migraciones(engine)  # leave the shared test DB with the full schema
        await engine.dispose()
