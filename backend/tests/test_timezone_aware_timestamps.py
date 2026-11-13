"""
The timestamps this backend writes must mean the same instant on any host.

The bug these tests exist for is documented in the README ("The findings
store, and the two bugs found building it") and in app/core/clock.py. The
one-line version: asyncpg encodes a NAIVE datetime bound to a timestamptz
parameter by assuming the PROCESS's local timezone. Nothing about that is
loud. No error, no warning — just every stored "now" silently displaced by
the host's offset, every age computed against it inverted, and a findings
cache that would have gone on serving yesterday's news forever while
looking like it worked.

So these tests do the only thing that can catch it: they move the process
off UTC and round-trip through real Postgres. A test that writes a value and
reads it back from SQLAlchemy's identity map proves nothing — the identity
map hands back what Python assigned, not what Postgres stored, which is
precisely how this bug survived its first test (README, "Bug 2"). Every read
below is forced through an expire_all().

America/Bogota is not an arbitrary choice: it is UTC-5 with no DST, it is
where this product's customers are, and it shifts a naive write five hours
into the FUTURE — the same direction and the same silence as the original.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_timezone_aware_timestamps.py
"""
import ast
import os
import pathlib
import time as time_module
import uuid
from contextlib import contextmanager
from datetime import timedelta

import pytest
from sqlalchemy import select

from app.core import clock
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import EpisodePath
from app.models.findings_cache import FindingsCache
from app.models.generation_job import GenerationJob, JobStatus
from app.models.profile import Profile
from app.services.episode_generator import _compute_eta, check_late_jobs

# UTC-5, no DST, and the zone the founder and the customers actually live in.
_NOT_UTC = "America/Bogota"

_needs_tzset = pytest.mark.skipif(
    not hasattr(time_module, "tzset"),
    reason="time.tzset() is Unix-only; on Windows the process timezone cannot be "
           "changed in-flight, which is itself part of why pinning it was never the fix",
)


@contextmanager
def _process_timezone(name: str):
    """Run a block with the process on a non-UTC timezone, and put it back.

    app/db/session.py pins TZ=UTC at import, deliberately and as belt and
    braces. That pin is exactly what would hide this bug, so these tests lift
    it for the duration — which is also a fair simulation of the thing the pin
    cannot protect: any other process touching the same database.
    """
    previous = os.environ.get("TZ")
    os.environ["TZ"] = name
    time_module.tzset()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time_module.tzset()


async def _customer(db) -> Cliente:
    c = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                hashed_password=None, nombre="T", idioma="es")
    db.add(c)
    await db.flush()
    return c


@_needs_tzset
@pytest.mark.asyncio
async def test_a_stored_timestamp_means_the_same_instant_off_utc(full_db_session):
    """The writers. A row stamped by a column default, on a host five hours
    behind UTC, must come back as the moment it was actually written.

    This fails by five hours the moment any model default goes back to naive
    utcnow() — which is how every timestamp in this codebase used to be
    written, and why the cache's age arithmetic came out negative.
    """
    with _process_timezone(_NOT_UTC):
        before = clock.utcnow()
        full_db_session.add(FindingsCache(
            topic_key="aware-probe", scope_key="", geography_key="",
            payload={"findings": [], "sources": [], "no_news": False}, no_news=False,
        ))
        await full_db_session.flush()
        full_db_session.expire_all()  # the identity map would just echo Python back

        row = (await full_db_session.execute(
            select(FindingsCache).where(FindingsCache.topic_key == "aware-probe")
        )).scalar_one()
        after = clock.utcnow()

    stored = clock.as_utc(row.creado_en)
    assert before - timedelta(seconds=2) <= stored <= after + timedelta(seconds=2), (
        f"a row written at {before.isoformat()} came back as {stored.isoformat()} — "
        f"off by {stored - before}, which is this host's offset from UTC leaking "
        "into a naive datetime on its way through asyncpg"
    )


@_needs_tzset
@pytest.mark.asyncio
async def test_the_late_job_watchdog_still_fires_off_utc(full_db_session):
    """The readers. A job an hour past its delivery promise is late, whatever
    timezone the watchdog happens to be running in.

    This is the failure that matters most, because it is the one nobody would
    notice: a naive eta lands five hours in the future, the deadline never
    passes, and the watchdog simply stops relabelling jobs. Home keeps showing
    "making your episode" for a run that died hours ago, and no test that
    avoids Postgres can tell.
    """
    with _process_timezone(_NOT_UTC):
        cliente = await _customer(full_db_session)
        # A delivery moment one hour ago, expressed the way a real profile
        # expresses it: a local wall-clock time plus a zone.
        promised = clock.utcnow() - timedelta(hours=1)
        full_db_session.add(Profile(
            customer_id=cliente.id, delivery_time=promised.time(), delivery_timezone="UTC",
        ))
        await full_db_session.flush()

        eta = await _compute_eta(
            full_db_session, cliente, EpisodePath.scheduled, promised.date(), clock.utcnow(),
        )
        full_db_session.add(GenerationJob(
            customer_id=cliente.id, fecha=promised.date(), path=EpisodePath.scheduled,
            status=JobStatus.voicing, eta=eta, stages=[],
        ))
        await full_db_session.flush()
        full_db_session.expire_all()  # force the watchdog to read Postgres, not Python

        newly_late = await check_late_jobs(full_db_session)

    assert len(newly_late) == 1, (
        "a job an hour past its eta was not marked late. Its stored eta is in the "
        "future as far as the database is concerned, so the deadline never passes "
        "and the watchdog goes quiet without failing"
    )
    assert newly_late[0].status == JobStatus.late


def test_no_naive_utc_clock_calls_remain_in_the_backend():
    """The guard that keeps this fixed.

    The sweep is worth little if the next hand reaches for datetime.utcnow()
    out of habit — it is still the obvious-looking way to say "now in UTC",
    and it is still wrong here, and it still fails silently. This reads the
    source rather than the behaviour because the behaviour is invisible until
    something round-trips through Postgres on a non-UTC host, which in
    practice meant nobody saw it for months.

    No Postgres needed: this one runs anywhere, including on a laptop with no
    database, which is the point of putting the rule in a test at all.
    """
    app_dir = pathlib.Path(__file__).resolve().parent.parent / "app"
    offenders = []

    for path in sorted(app_dir.rglob("*.py")):
        tree = ast.parse(path.read_text(), filename=str(path))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Attribute):
                continue
            # datetime.utcnow — naive, always. Caught whether it is called or
            # passed by name as a SQLAlchemy column default.
            if node.attr == "utcnow" and getattr(node.value, "id", None) == "datetime":
                offenders.append(f"{path.relative_to(app_dir.parent)}:{node.lineno}: datetime.utcnow")

    for path in sorted(app_dir.rglob("*.py")):
        tree = ast.parse(path.read_text(), filename=str(path))
        for node in ast.walk(tree):
            # datetime.now() with no argument — the local clock, wearing the
            # same clothes. datetime.now(tz) is fine and is used deliberately
            # for the customer's own wall clock in scheduler and profile.
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "now"
                    and getattr(node.func.value, "id", None) == "datetime"
                    and not node.args and not node.keywords):
                offenders.append(f"{path.relative_to(app_dir.parent)}:{node.lineno}: datetime.now()")

    assert not offenders, (
        "naive clock calls are back in the backend:\n  " + "\n  ".join(offenders) +
        "\n\nUse app.core.clock.utcnow() instead. A naive datetime bound to a "
        "timestamptz column is encoded by asyncpg in the process's local timezone, "
        "which displaces the stored instant by the host's offset without raising."
    )
