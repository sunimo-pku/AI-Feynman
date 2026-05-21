from __future__ import annotations

import os
from typing import Iterator

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(scope="session")
def client() -> Iterator[TestClient]:
    real_db = os.path.join(os.path.dirname(__file__), "..", "data", "app.db")
    backup_path = real_db + ".test_backup"
    if os.path.exists(real_db):
        os.replace(real_db, backup_path)
    try:
        from app.db import engine, init_db  # noqa: WPS433

        engine.dispose()
        init_db()
        from app.main import app  # noqa: WPS433
        from app.middleware.rate_limit import reset_limiter  # noqa: WPS433

        reset_limiter()
        with TestClient(app) as c:
            yield c
        reset_limiter()
        engine.dispose()
    finally:
        if os.path.exists(real_db):
            os.remove(real_db)
        if os.path.exists(backup_path):
            os.replace(backup_path, real_db)
