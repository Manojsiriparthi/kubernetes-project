"""Integration tests: talk to the running stack (frontend nginx -> backend -> PostgreSQL) over HTTP.
Usage: BASE_URL=http://localhost:8080 pytest tests/integration
"""
import os
import uuid

import pytest
import requests

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")


@pytest.fixture(scope="session")
def session():
    with requests.Session() as http:
        http.headers.update({"Accept": "application/json"})
        yield http


def test_frontend_page_loads(session):
    response = session.get(f"{BASE_URL}/", timeout=10)
    assert response.status_code == 200
    assert "<form" in response.text


def test_backend_ready_reports_database_ok(session):
    response = session.get(f"{BASE_URL}/api/health/ready", timeout=10)
    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_seeded_student_is_returned_with_marks(session):
    response = session.get(
        f"{BASE_URL}/api/students",
        params={"first_name": "Ananya", "last_name": "Rao", "class_name": "10"},
        timeout=10,
    )
    assert response.status_code == 200
    students = response.json()["students"]
    assert len(students) == 1
    assert students[0]["hall_ticket"] == "SCI-2026-00101"
    assert set(students[0]["marks"]) == {"Telugu", "English", "Maths", "Science", "Social"}


def test_lookup_is_case_insensitive(session):
    response = session.get(
        f"{BASE_URL}/api/students",
        params={"first_name": "ananya", "last_name": "RAO", "class_name": "10"},
        timeout=10,
    )
    assert len(response.json()["students"]) == 1


def test_unknown_student_returns_empty_list(session):
    response = session.get(
        f"{BASE_URL}/api/students",
        params={"first_name": "Nobody", "last_name": "Here", "class_name": "1"},
        timeout=10,
    )
    assert response.status_code == 200
    assert response.json()["students"] == []


def test_register_then_lookup_round_trip(session):
    # A random last name keeps repeated runs from colliding with earlier registrations.
    last_name = f"Test{uuid.uuid4().hex[:8]}"
    payload = {
        "first_name": "Integration",
        "last_name": last_name,
        "class_name": "7",
        "address": "1 Test Street, Hyderabad",
        "phone": "9000000999",
        "father_phone": "9000000998",
    }
    created = session.post(f"{BASE_URL}/api/students", json=payload, timeout=10)
    assert created.status_code == 201
    student = created.json()["student"]
    assert student["hall_ticket"].startswith("SCI-2026-")
    assert student["total"] == sum(student["marks"].values())

    found = session.get(
        f"{BASE_URL}/api/students",
        params={"first_name": "Integration", "last_name": last_name, "class_name": "7"},
        timeout=10,
    )
    assert found.status_code == 200
    assert found.json()["students"][0]["hall_ticket"] == student["hall_ticket"]


def test_registration_with_missing_fields_is_rejected(session):
    response = session.post(f"{BASE_URL}/api/students", json={"first_name": "Only"}, timeout=10)
    assert response.status_code == 400
