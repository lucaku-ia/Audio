"""
OnboardingState — not part of System Contracts v0.1; introduced here per the
Onboarding PRD (Andrés, Draft v4), engineering notes §5: "onboarding_step and
saved requests persist server-side per account. Resume works across devices."

Everything AI-dependent is deliberately deferred until the AI Platform and
Episode Generator epics exist:

- structure_request / preview_answer (per-request structuring + one-line
  preview): blocked on the AI Platform's call wrapper. Requests created
  during onboarding go through Request Management as-is, with
  `structured = {}`, same as any other request today.
- "Suggest for me": the PRD explicitly allows a curated seed list (config,
  not code) for the pilot, not AI — that part IS buildable now and lives in
  app/data/onboarding_seeds.json.
- Day-zero sample matching to shared inventory: needs Episode/InventoryItem
  rows that don't exist yet (Episode Generator hasn't produced any). Not
  implemented.
- First-episode generation itself (scheduled or on-demand): Episode
  Generator epic. Onboarding only computes and returns the T-60 scheduling
  message described in PRD §5 — it does not create a GenerationJob.
"""
import enum
import uuid
from datetime import datetime
from sqlalchemy import Boolean, DateTime, JSON, String, ForeignKey, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class OnboardingStep(str, enum.Enum):
    interests = "interests"
    requests = "requests"
    delivery = "delivery"
    sound = "sound"
    confirm = "confirm"
    notifications = "notifications"
    tour = "tour"
    done = "done"


class OnboardingState(Base):
    __tablename__ = "onboarding_states"

    customer_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id"), primary_key=True)
    step: Mapped[OnboardingStep] = mapped_column(SAEnum(OnboardingStep, name="onboarding_step"), default=OnboardingStep.interests)
    selected_interests: Mapped[list] = mapped_column(JSON, default=lambda: [])
    consent_accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)  # Ley 1581 de 2012 — PRD §6
    notifications_enabled: Mapped[bool | None] = mapped_column(Boolean, nullable=True)  # null = not asked yet
    tour_completed: Mapped[bool] = mapped_column(Boolean, default=False)
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
