"""
Login PRD (Juan, Draft v2) — flujo de email+password.

Google y Apple quedan fuera de este primer corte: requieren credenciales OAuth
creadas en sus consolas respectivas (mismo patrón que Gmail en el proyecto de
manufactura). auth_provider ya soporta esos valores en el modelo; falta el
endpoint de callback de cada uno.
"""
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.core.security import create_access_token, get_password_hash, verify_password
from app.db.session import get_db
from app.models.cliente import AuthProvider, Cliente
from app.services.events import emitir

router = APIRouter(prefix="/auth", tags=["Login"])

MAX_INTENTOS = 5
BLOQUEO_SEGUNDOS = 60


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    onboarding_complete: bool  # el cliente rutea con esto: false -> Onboarding, true -> Home


class SignupRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)
    nombre: str = Field(min_length=1, max_length=255)
    idioma: str = Field(default="es", pattern="^(es|en)$")


class MeResponse(BaseModel):
    id: str
    email: str
    nombre: str
    idioma: str
    auth_provider: str
    onboarding_complete: bool


@router.post("/signup", response_model=TokenResponse, status_code=201)
async def signup(data: SignupRequest, db: AsyncSession = Depends(get_db)):
    existente = await db.execute(select(Cliente).where(Cliente.email == data.email))
    cliente_existente = existente.scalar_one_or_none()
    if cliente_existente:
        # PRD: "shows a message pointing to the right way in, instead of silently
        # creating a second account" — deliberadamente NO es un error generico aqui.
        raise HTTPException(
            status_code=400,
            detail=f"Este correo ya tiene una cuenta con el método '{cliente_existente.auth_provider.value}'. Inicia sesión con ese método.",
        )

    cliente = Cliente(
        email=data.email,
        auth_provider=AuthProvider.email,
        hashed_password=get_password_hash(data.password),
        nombre=data.nombre,
        idioma=data.idioma,
        onboarding_complete=False,
    )
    db.add(cliente)
    await db.flush()

    await emitir(db, "account_created", customer_id=cliente.id, method="email")
    await db.commit()

    token = create_access_token(cliente.id, cliente.token_version)
    return TokenResponse(access_token=token, onboarding_complete=cliente.onboarding_complete)


@router.post("/login", response_model=TokenResponse)
async def login(form: OAuth2PasswordRequestForm = Depends(), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Cliente).where(Cliente.email == form.username))
    cliente = result.scalar_one_or_none()

    # Error generico deliberado — "never reveals whether the email or the password was wrong"
    error_generico = HTTPException(status_code=401, detail="Credenciales incorrectas")

    if cliente is None:
        raise error_generico

    if cliente.auth_provider != AuthProvider.email:
        raise HTTPException(
            status_code=400,
            detail=f"Esta cuenta usa '{cliente.auth_provider.value}' para iniciar sesión, no email y contraseña.",
        )

    ahora = datetime.now(timezone.utc)
    if cliente.bloqueado_hasta and cliente.bloqueado_hasta > ahora:
        segundos_restantes = int((cliente.bloqueado_hasta - ahora).total_seconds())
        raise HTTPException(
            status_code=429,
            detail=f"Demasiados intentos. Intenta de nuevo en {segundos_restantes} segundos.",
        )

    if not cliente.hashed_password or not verify_password(form.password, cliente.hashed_password):
        cliente.intentos_fallidos += 1
        if cliente.intentos_fallidos >= MAX_INTENTOS:
            cliente.bloqueado_hasta = ahora + timedelta(seconds=BLOQUEO_SEGUNDOS)
            cliente.intentos_fallidos = 0
        await emitir(db, "login_failure", customer_id=cliente.id, method="email", reason="bad_credentials")
        await db.commit()
        raise error_generico

    cliente.intentos_fallidos = 0
    cliente.bloqueado_hasta = None
    await emitir(db, "login_success", customer_id=cliente.id, method="email")
    await db.commit()

    token = create_access_token(cliente.id, cliente.token_version)
    return TokenResponse(access_token=token, onboarding_complete=cliente.onboarding_complete)


@router.post("/logout")
async def logout(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    cliente.token_version += 1  # invalida de inmediato cualquier token emitido antes
    await emitir(db, "logout", customer_id=cliente.id)
    await db.commit()
    return {"mensaje": "Sesión cerrada"}


@router.get("/me", response_model=MeResponse)
async def me(cliente: Cliente = Depends(get_current_cliente)):
    return MeResponse(
        id=str(cliente.id),
        email=cliente.email,
        nombre=cliente.nombre,
        idioma=cliente.idioma,
        auth_provider=cliente.auth_provider.value,
        onboarding_complete=cliente.onboarding_complete,
    )
