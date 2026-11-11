"""
One clock for the whole backend, and the reason it has to be shared.

`datetime.utcnow()` returns a naive datetime. Bound to a `timestamptz`
parameter, asyncpg encodes a naive value by assuming it is in the PROCESS's
local timezone — the conversion happens client-side, in Python, before
Postgres is ever consulted. On a machine running UTC-5 that stored every
"now" five hours in the future, every age came out negative, and the findings
cache would have gone on serving yesterday's news forever without raising a
single error. The full account is in the README, under "The findings store,
and the two bugs found building it".

So the hazard is not that a timestamp is in the wrong zone. It is that a
naive datetime does not carry the one fact that makes it unambiguous, and
every layer underneath it then guesses — asyncpg guesses the process zone,
Postgres guesses the session zone, and Python refuses to compare a guess to
an answer at all ("can't compare offset-naive and offset-aware datetimes").
An aware value removes the guess from all three.

`utcnow()` is what every writer in this codebase calls. It is deliberately
named after the function it replaces, so a reviewer reading a diff sees the
same word and a grep for the old one finds nothing.

`as_utc()` is for the reading side. Rows written before this existed are
naive in the database; asyncpg hands them back aware (a timestamptz column
always reads back aware), but anything that can also see an in-memory value
— SQLAlchemy's identity map returns exactly what Python assigned, not what
Postgres stored — can still meet a naive one. Coercing it to UTC is the
right reading of history: `utcnow()` always meant UTC, it just failed to
say so.
"""
from datetime import datetime, timezone


def utcnow() -> datetime:
    """The current instant, in UTC, saying so."""
    return datetime.now(timezone.utc)


def as_utc(value: datetime) -> datetime:
    """Read a possibly-naive stored timestamp as UTC.

    Naive in, UTC-aware out; already-aware values are converted rather than
    relabelled, so a value that genuinely carries another offset keeps its
    instant. Use this on anything loaded from the database before comparing
    or subtracting — see the module docstring for where a naive value can
    still come from.
    """
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)
