# 03 - The application explained

This document explains the website that runs on the cluster: what it does, what its parts are, and how they talk
to each other. No programming knowledge is needed to follow it.

---

## 1. What is the application?

A small **school portal** (Sree Chaitanya International School demo). A visitor can:

1. **Register a student** - enter first name, last name, class, address, phone, father's phone. The system creates a
   "hall ticket" number and five sample marks (Telugu, English, Maths, Science, Social).
2. **Look up a student** - enter first name, last name, class and see the hall ticket, contact details and marks.

Four demo students are already stored (for example Ananya Rao, class 10).

---

## 2. The three parts (tiers)

```
 Browser  --->  FRONTEND (nginx)  --->  BACKEND (Flask API)  --->  DATABASE (PostgreSQL)
  "the web       shows the page,         does the work:           stores the students
   page"         forwards /api calls     checks input, asks DB     permanently
```

| Part | Folder | Technology | Job |
|---|---|---|---|
| Frontend | `application/frontend/` | HTML, CSS, JavaScript, nginx web server | what the visitor sees |
| Backend | `application/backend/` | Python, Flask, gunicorn | the "brain": rules and database access |
| Database | (stock `postgres:16-alpine` image) | PostgreSQL | permanent storage |

**Why split into three?** Each part can be changed, scaled and protected on its own. For example we run 3 copies of
the frontend and backend, but only 1 database, and the database lives on its own protected server.

---

## 3. Frontend (`application/frontend/`)

| File | What it is |
|---|---|
| `index.html` | the page structure: header, hero banner, two cards (register and student info), footer |
| `styles.css` | colours, fonts, layout (version 2 uses indigo, version 1 teal) |
| `app.js` | the behaviour: when you press a button it sends the form to the backend and shows the answer |
| `nginx.conf` | web server rules for the site |
| `nginx-main.conf` | main web server settings |
| `Dockerfile` | the recipe to build the container image |
| `package.json`, `tests/app.test.js` | only for testing (see section 6) |

### What `app.js` does
- Finds the two forms and the two result boxes on the page.
- **Register form submit:** sends `POST /api/students` with the form data as JSON. If the answer is OK it shows
  "Student registered successfully", otherwise it shows the error.
- **Lookup form submit:** sends `GET /api/students?first_name=...&last_name=...&class_name=...`. If students come
  back, `renderStudent` draws a card with their details and marks (in version 2 also a bar per subject). If the
  list is empty it says "No matching student found".
- It never builds HTML from user text with `innerHTML`; it uses `textContent`. *Problem solved:* a visitor cannot
  inject a script into the page (this attack is called XSS).

### What `nginx.conf` does
```
listen 8080;                       # the container listens on port 8080
location /api/ {                   # every address starting with /api/ ...
    proxy_pass http://backend:5000/api/;   # ... is forwarded to the backend container
}
location / { try_files $uri $uri/ /index.html; }   # everything else is a normal page or file
```
`backend` is a **Service name** in Kubernetes (doc 04). Kubernetes DNS turns it into the backend's address. This is
why the browser only ever talks to one address (the frontend) and never to the backend directly.

### The frontend Dockerfile (line by line)
```dockerfile
FROM nginx:1.27-alpine                       # start from a small official nginx image
RUN rm /etc/nginx/conf.d/default.conf ...    # remove the default site, give our user ownership of needed folders
COPY nginx-main.conf /etc/nginx/nginx.conf   # our main settings
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css app.js /usr/share/nginx/html/   # the website files
USER nginx                                   # run as a normal user, not root (security)
EXPOSE 8080                                  # documents the port (ports below 1024 need root, so we use 8080)
```

---

## 4. Backend (`application/backend/`)

| File | What it is |
|---|---|
| `app.py` | the whole API (about 150 lines) |
| `requirements.txt` | Python libraries: Flask (web framework), gunicorn (production web server), psycopg (PostgreSQL driver) |
| `init.sql` | creates the table and the four demo students (used by docker-compose; Kubernetes uses a copy in a ConfigMap) |
| `Dockerfile` | the recipe to build the image |
| `tests/test_app.py` | unit tests |

### The API endpoints
| Address | Method | What it does |
|---|---|---|
| `/api/health/live` | GET | answers `{"status":"ok"}` as long as the program runs. Kubernetes uses it to decide if the pod is **alive** |
| `/api/health/ready` | GET | opens a database connection and runs `SELECT 1`. Answers 200 only if the database works. Kubernetes uses it to decide if the pod is **ready for traffic** (503 otherwise) |
| `/api/students` | GET | looks up students by `first_name`, `last_name`, `class_name` (case-insensitive). 400 if any is missing |
| `/api/students` | POST | registers a student. Checks every field is present and not too long, takes the next hall-ticket number from a database sequence (`SCI-2026-xxxxx`), makes random marks 55-98, saves and returns it (201) |

### Why two health endpoints?
- **live** = "is the program stuck?" If it fails, Kubernetes **restarts** the pod.
- **ready** = "can I serve users right now?" If it fails, Kubernetes **stops sending traffic** to this pod but does not
  restart it. Example: the database is briefly down, the backend stays up but is "not ready".

### Safe database access
All queries use `%s` placeholders (`WHERE lower(first_name) = lower(%s)`), never text glued into the query.
*Problem solved:* SQL injection (an attacker typing database commands into a form field).

### Settings the backend reads (environment variables)
Only one: `DATABASE_URL`, for example `postgresql://school_app:PASSWORD@postgres:5432/school`.
In Kubernetes this is built from the ConfigMap (user, database name) and the Secret (password), see doc 04.
*Problem solved:* the same image works on a laptop, in docker-compose and in the cluster, because the address is
not written in the code.

### Schema self-healing
`ensure_student_schema` adds the columns `class_name` and `father_phone` if an old table lacks them. It runs once per
process under a lock.

### The backend Dockerfile (line by line)
```dockerfile
FROM python:3.12-slim                         # small official Python image
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1   # no .pyc files; print logs immediately
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --create-home --uid 10001 appuser
COPY --chown=appuser:appuser app.py .         # our code
USER 10001                                    # run as a normal user (number, so Kubernetes can verify it is not root)
EXPOSE 5000
CMD ["gunicorn", "--bind=0.0.0.0:5000", "--workers=2", ..., "app:app"]   # start 2 worker processes
```

---

## 5. The database

PostgreSQL stores one table:

```sql
students ( id, first_name, last_name, class_name, address, phone, father_phone,
           hall_ticket (unique), recent_exam, marks (JSON), created_at )
```
and one counter `hall_ticket_seq` that hands out the next hall-ticket number.

We use the **stock** PostgreSQL image. The table is created automatically on the very first start from a ConfigMap
(`postgres-init`, doc 04). To look inside by hand:

```bash
kubectl exec -it postgres-0 -n school-demo -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
# then type:  \dt            (list tables)
#             SELECT * FROM students;
#             \q             (quit)
```

---

## 6. Tests (what checks that it works)

| Test | Where | What it checks | Needs the running app? |
|---|---|---|---|
| Backend unit tests | `application/backend/tests/test_app.py` (pytest) | health, input validation, 404 JSON, total marks | no |
| Frontend DOM tests | `application/frontend/tests/app.test.js` (node:test + jsdom) | loads the real page in a fake browser, submits forms, checks the result boxes and the mark bars | no |
| Smoke test | `tests/smoke/smoke_test.sh` | home page, API through the proxy, database reachable, seeded student found | yes |
| Integration tests | `tests/integration/test_api.py` | register then look up a student, case-insensitive lookup, errors | yes |
| Load test | `tests/jmeter/load-test.jmx` | 10 users x 20 loops on the page, health and lookup; fails on any error | yes |
| SAST (SonarQube) | `jenkins/Jenkinsfile.frontend.groovy`, `jenkins/Jenkinsfile.backend.groovy` | code quality and security smells | no |
| DAST (OWASP ZAP) | pipeline stage | attacks the running site from outside (passive scan) | yes |

The pipeline (doc 05) runs all of them in a good order.

---

## 7. Run it on your own machine (docker-compose)

```bash
docker compose up -d --build
# wait ~30 seconds, then open http://localhost:8080
BASE_URL=http://localhost:8080 ./tests/smoke/smoke_test.sh
docker compose down -v        # stop and delete the data
```

`docker-compose.yml` starts the same three parts (postgres, backend, frontend) and mounts `init.sql` so the table is
created. The compose file also has an `image:` line for each service: **the Jenkins pipeline rewrites those lines to
the ECR images it just pushed**, and `FRONTEND_PORT` lets the pipeline use port 18080 because Jenkins uses 8080.

> GitHub Codespaces note: Docker's normal container network can block traffic between containers there. If the
> backend never becomes healthy, start the three containers with host networking instead.

---

## 8. Version 1 and version 2

The two release branches contain the same application. The only differences:

| | `release/version1` | `release/version2` |
|---|---|---|
| Look | teal and gold, headline "A bright start..." | indigo and orange, "Version 2.0" badge, stats strip, marks bars |
| Files changed | | `index.html`, `styles.css`, `app.js`, `tests/app.test.js` |

This is on purpose: it makes a deployment and a rollback easy to see.
