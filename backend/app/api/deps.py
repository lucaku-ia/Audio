import uuid
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

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
        detail="No autenticado",
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
        # el token fue emitido antes del ultimo logout — Login PRD: "logout revokes it"
        raise credentials_exception
    return cliente
