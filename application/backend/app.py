import os
import random
import psycopg
from flask import Flask, jsonify, request
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

app = Flask(__name__)

SUBJECTS = ("Telugu", "English", "Maths", "Science", "Social")
DATABASE_URL = os.environ["DATABASE_URL"]


def connect():
    return psycopg.connect(DATABASE_URL, connect_timeout=3, row_factory=dict_row)


def student_record(row):
    return {
        "first_name": row["first_name"],
        "last_name": row["last_name"],
        "address": row["address"],
        "phone": row["phone"],
        "hall_ticket": row["hall_ticket"],
        "recent_exam": row["recent_exam"],
        "marks": row["marks"],
        "total": sum(row["marks"].values()),
    }


@app.get("/api/health/live")
def live():
    return jsonify(status="ok")


@app.get("/api/health/ready")
def ready():
    try:
        with connect() as connection:
            connection.execute("SELECT 1")
        return jsonify(status="ready")
    except psycopg.Error:
        return jsonify(error="Database is not ready"), 503


@app.get("/api/students")
def find_students():
    first_name = request.args.get("first_name", "").strip()
    last_name = request.args.get("last_name", "").strip()
    if not first_name or not last_name:
        return jsonify(error="Enter both first and last name."), 400

    try:
        with connect() as connection:
            rows = connection.execute(
                """
                SELECT first_name, last_name, address, phone, hall_ticket, recent_exam, marks
                FROM students
                WHERE lower(first_name) = lower(%s) AND lower(last_name) = lower(%s)
                ORDER BY id
                """,
                (first_name, last_name),
            ).fetchall()
        return jsonify(students=[student_record(row) for row in rows])
    except psycopg.Error:
        app.logger.exception("Student lookup failed")
        return jsonify(error="Student records are temporarily unavailable."), 503


@app.post("/api/students")
def register_student():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="Submit registration details as JSON."), 400

    fields = ("first_name", "last_name", "address", "phone")
    values = {field: str(payload.get(field, "")).strip() for field in fields}
    if any(not values[field] for field in fields):
        return jsonify(error="Complete every registration field."), 400
    if any(len(values[field]) > limit for field, limit in (
        ("first_name", 80), ("last_name", 80), ("address", 300), ("phone", 32)
    )):
        return jsonify(error="One or more fields are too long."), 400

    try:
        with connect() as connection:
            ticket_number = connection.execute(
                "SELECT nextval('hall_ticket_seq')"
            ).fetchone()["nextval"]
            hall_ticket = f"SCI-2026-{ticket_number:05d}"
            marks = {subject: random.randint(55, 98) for subject in SUBJECTS}
            row = connection.execute(
                """
                INSERT INTO students
                    (first_name, last_name, address, phone, hall_ticket, recent_exam, marks)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING first_name, last_name, address, phone, hall_ticket, recent_exam, marks
                """,
                (
                    values["first_name"],
                    values["last_name"],
                    values["address"],
                    values["phone"],
                    hall_ticket,
                    "Demo Unit Test - 2026",
                    Jsonb(marks),
                ),
            ).fetchone()
        return jsonify(student=student_record(row)), 201
    except psycopg.Error:
        app.logger.exception("Student registration failed")
        return jsonify(error="Registration is temporarily unavailable."), 503


@app.errorhandler(404)
def not_found(_error):
    return jsonify(error="API endpoint not found."), 404
