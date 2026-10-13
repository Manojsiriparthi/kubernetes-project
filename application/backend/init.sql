CREATE SEQUENCE hall_ticket_seq START WITH 2001;

CREATE TABLE students (
    id BIGSERIAL PRIMARY KEY,
    first_name VARCHAR(80) NOT NULL,
    last_name VARCHAR(80) NOT NULL,
    address VARCHAR(300) NOT NULL,
    phone VARCHAR(32) NOT NULL,
    hall_ticket VARCHAR(32) NOT NULL UNIQUE,
    recent_exam VARCHAR(120) NOT NULL,
    marks JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO students (first_name, last_name, address, phone, hall_ticket, recent_exam, marks)
VALUES
    ('Ananya', 'Rao', '12 Lake View Road, Hyderabad', '9000000101', 'SCI-2026-00101', 'Term 1 Assessment - 2026',
     '{"Telugu": 91, "English": 88, "Maths": 96, "Science": 93, "Social": 89}'),
    ('Arjun', 'Kumar', '8 Green Park, Hyderabad', '9000000102', 'SCI-2026-00102', 'Term 1 Assessment - 2026',
     '{"Telugu": 84, "English": 90, "Maths": 92, "Science": 87, "Social": 85}'),
    ('Meera', 'Reddy', '21 School Street, Secunderabad', '9000000103', 'SCI-2026-00103', 'Term 1 Assessment - 2026',
     '{"Telugu": 95, "English": 94, "Maths": 89, "Science": 91, "Social": 97}'),
    ('Rahul', 'Sharma', '4 Sunrise Colony, Hyderabad', '9000000104', 'SCI-2026-00104', 'Term 1 Assessment - 2026',
     '{"Telugu": 78, "English": 82, "Maths": 86, "Science": 80, "Social": 84}');
