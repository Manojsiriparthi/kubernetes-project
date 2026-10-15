"""Unit tests for the Flask API. They run without a database: only routes that fail before any query are exercised."""
import os
import sys

# app.py reads DATABASE_URL at import time; a dummy value is enough because these tests never connect.
os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

import app as school_app  # noqa: E402


@pytest.fixture()
def client():
    school_app.app.config["TESTING"] = True
    return school_app.app.test_client()


def test_liveness_returns_ok(client):
    response = client.get("/api/health/live")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_unknown_route_returns_json_404(client):
    response = client.get("/api/does-not-exist")
    assert response.status_code == 404
    assert "error" in response.get_json()


def test_lookup_requires_all_fields(client):
    response = client.get("/api/students?first_name=Ananya")
    assert response.status_code == 400
    assert "first name, last name, and class" in response.get_json()["error"]


def test_register_rejects_non_json_body(client):
    response = client.post("/api/students", data="not json", content_type="text/plain")
    assert response.status_code == 400


def test_register_rejects_missing_fields(client):
    response = client.post("/api/students", json={"first_name": "Only"})
    assert response.status_code == 400
    assert "Complete every registration field" in response.get_json()["error"]


def test_register_rejects_too_long_values(client):
    payload = {
        "first_name": "A" * 81,
        "last_name": "Rao",
        "class_name": "10",
        "address": "12 Lake View Road",
        "phone": "9000000101",
        "father_phone": "9000000201",
    }
    response = client.post("/api/students", json=payload)
    assert response.status_code == 400
    assert "too long" in response.get_json()["error"]


def test_student_record_adds_total():
    row = {
        "first_name": "Ananya",
        "last_name": "Rao",
        "class_name": "10",
        "address": "12 Lake View Road",
        "phone": "9000000101",
        "father_phone": "9000000201",
        "hall_ticket": "SCI-2026-00101",
        "recent_exam": "Term 1",
        "marks": {"Telugu": 90, "English": 80, "Maths": 70, "Science": 60, "Social": 50},
    }
    assert school_app.student_record(row)["total"] == 350
