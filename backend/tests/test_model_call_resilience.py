"""
Guards the two things that turned one bad minute at the provider into
`Server error (500): Internal Server Error` in the onboarding chat.

1. A blocking SDK call must not be made on the event loop. `_client` is the
   synchronous Anthropic client; awaited naively it holds the loop for the
   whole round trip, so the process serves nobody else — not another customer,
   not /health, not the scheduler — for seconds at a time.
2. A transient provider failure must be retried, and a failure that survives
   retries must reach the customer as a 503 with a sentence, never as a 500
   with a stack trace's worth of nothing.
"""
import asyncio
import time
import types

import anthropic
import httpx
import pytest

from app.main import app
from app.services import ai_platform
from app.services.ai_platform import ModelUnavailable, _invoke


def _status_error(cls, status: int):
    request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    return cls("provider said no", response=httpx.Response(status, request=request), body=None)


def _connection_error():
    return anthropic.APIConnectionError(request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))


@pytest.fixture(autouse=True)
def _short_backoff(monkeypatch):
    """
    Shrinks the retry backoff so this suite stays fast.

    Deliberately NOT by patching asyncio.sleep: `ai_platform.asyncio` is the
    real asyncio module, so patching its sleep replaces it for everything on
    the loop, and the event-loop test below then spins without ever yielding.
    """
    monkeypatch.setattr(ai_platform, "_RETRY_BACKOFF_S", 0.001)


@pytest.mark.asyncio
async def test_a_blocking_call_does_not_hold_the_event_loop():
    """
    The load-bearing one. While a synchronous SDK call is in flight, other
    coroutines must keep running. Before _invoke, this is exactly what did not
    happen, and it is invisible in any single-request test — it only shows up
    as everyone else's request hanging.
    """
    def slow_sdk_call():
        time.sleep(0.3)        # a synchronous network round trip, in effect
        return "answer"

    ticks = 0

    async def someone_else_using_the_server():
        nonlocal ticks
        while True:
            ticks += 1
            await asyncio.sleep(0.01)

    other = asyncio.create_task(someone_else_using_the_server())
    result = await _invoke(slow_sdk_call)
    other.cancel()

    assert result == "answer"
    assert ticks > 5, f"the event loop was blocked for the whole call (only {ticks} ticks)"


@pytest.mark.asyncio
async def test_a_transient_failure_is_retried_and_can_succeed():
    attempts = []

    def flaky():
        attempts.append(1)
        if len(attempts) < 3:
            raise _status_error(anthropic.InternalServerError, 529)
        return "answer"

    assert await _invoke(flaky) == "answer"
    assert len(attempts) == 3, "gave up before the retries were used"


@pytest.mark.asyncio
@pytest.mark.parametrize("make_error", [
    lambda: _status_error(anthropic.RateLimitError, 429),
    lambda: _status_error(anthropic.InternalServerError, 500),
    _connection_error,
])
async def test_a_failure_that_outlives_the_retries_is_not_a_bare_exception(make_error):
    """
    What the customer saw. Whatever the provider did, the route must get
    something it can turn into a sentence — not an SDK exception escaping into
    FastAPI's 500 handler.
    """
    def always_fails():
        raise make_error()

    with pytest.raises(ModelUnavailable):
        await _invoke(always_fails)


@pytest.mark.asyncio
async def test_a_permanent_failure_is_not_retried():
    """A bad key or a bad request is our bug. Retrying it only makes the
    customer wait longer for the same answer."""
    attempts = []

    def bad_request():
        attempts.append(1)
        raise _status_error(anthropic.BadRequestError, 400)

    with pytest.raises(ModelUnavailable):
        await _invoke(bad_request)
    assert len(attempts) == 1, "retried a failure that cannot succeed"


@pytest.mark.asyncio
async def test_structure_request_surfaces_model_unavailable(monkeypatch):
    """The path the onboarding chat actually takes: POST /requests ->
    structure_request -> the model."""
    def always_fails(**kwargs):
        raise _status_error(anthropic.InternalServerError, 529)

    monkeypatch.setattr(
        ai_platform, "_client",
        types.SimpleNamespace(messages=types.SimpleNamespace(parse=always_fails)),
    )

    async def fake_get_active_prompt(db, name, fallback_version, fallback_system_prompt):
        return fallback_system_prompt, fallback_version

    monkeypatch.setattr(ai_platform, "get_active_prompt", fake_get_active_prompt)

    import uuid
    with pytest.raises(ModelUnavailable):
        await ai_platform.structure_request(None, "Top World stories", uuid.uuid4(), None)


@pytest.mark.asyncio
async def test_the_app_answers_503_with_something_a_person_can_read():
    handler = app.exception_handlers.get(ModelUnavailable)
    assert handler is not None, "nothing maps ModelUnavailable to a response — it would be a 500"

    response = await handler(None, ModelUnavailable("overloaded_error: Overloaded"))
    assert response.status_code == 503

    body = response.body.decode()
    assert "Overloaded" not in body, "leaked the provider's own error string to the customer"
    assert "try that again" in body.lower()
