import secrets
import uuid
from fastapi import Depends, Header, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.config import settings
from app.core.security import decode_token
from app.db.session import get_db
from app.models.cliente import Cliente

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")


async def get_current_cliente(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> Cliente:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Not authenticated",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_token(token)
        cliente_id: str = payload.get("sub")
        token_version: int = payload.get("tv")
        if cliente_id is None or token_version is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    result = await db.execute(select(Cliente).where(Cliente.id == uuid.UUID(cliente_id)))
    cliente = result.scalar_one_or_none()
    if cliente is None:
        raise credentials_exception
    if cliente.token_version != token_version:
        # the token was issued before the last logout — Login PRD: "logout revokes it"
        raise credentials_exception
    return cliente


async def require_internal_dashboard_key(x_internal_dashboard_key: str | None = Header(default=None)) -> None:
    """
    Gate for the founder/ops-only Instrumentation dashboard routes (see
    app/api/routes/instrumentation.py's module docstring for the full
    security posture). There is no admin role on Cliente yet, so this is a
    plain shared-secret header check, same "read from env, fail closed if
    missing" shape as app/services/ai_platform.elevenlabs_configured() —
    if INTERNAL_DASHBOARD_KEY isn't set, the routes are unreachable rather
    than silently open.
    """
    if not settings.INTERNAL_DASHBOARD_KEY:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Instrumentation dashboard is not configured")
    # compare_digest, not `!=` — this gate is meant to behave like real auth,
    # and a plain string comparison leaks per-byte timing information.
    if not secrets.compare_digest(x_internal_dashboard_key or "", settings.INTERNAL_DASHBOARD_KEY):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or missing X-Internal-Dashboard-Key")
