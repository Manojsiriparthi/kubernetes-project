"""Draws docs/images/architecture.png (the AWS-native architecture picture used in README.md).

The layout is fixed by hand (not auto-generated) so every label stays readable.
To regenerate, from the repository root:
    python3 -m venv /tmp/dg && /tmp/dg/bin/pip install diagrams pillow    # 'diagrams' only supplies the icon files
    /tmp/dg/bin/python docs/images/draw_architecture.py
Needs the DejaVu fonts (sudo apt install fonts-dejavu-core).
"""
import glob
import math
import os

from PIL import Image, ImageDraw, ImageFont

S = 2                      # drawing scale: everything below is written in 1x units, the PNG is 2x
W, H = 1700, 1285
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "architecture.png")
ICONS = glob.glob("/tmp/dg*/lib/python*/site-packages/resources")[0]
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

WHITE, MUTED, DARK = "#f1f5f9", "#9fb0c7", "#0f172a"
C_USER, C_TEAM, C_CI, C_DEPLOY = "#38bdf8", "#c084fc", "#4ade80", "#fb923c"
C_AWS, C_VPC, C_PUBLIC, C_EKS, C_APP, C_DB = "#ff9900", "#8c4fff", "#7aa116", "#ed7100", "#00a4a6", "#e7157b"


def X(v):
    return int(round(v * S))


def font(size, bold=False):
    return ImageFont.truetype(FONT_B if bold else FONT, X(size))


# ---------------------------------------------------------------- canvas with a dark blue to dark red gradient
base = Image.linear_gradient("L").resize((X(W), X(H)))
top = Image.new("RGB", (X(W), X(H)), "#0a1124")
bottom = Image.new("RGB", (X(W), X(H)), "#24101b")
img = Image.composite(bottom, top, base).convert("RGBA")
d = ImageDraw.Draw(img)


def box(x0, y0, x1, y1, color, title=None, fill="#0e1729", dashed=False, title_color=None, sub=None, title_x=None):
    d.rounded_rectangle((X(x0), X(y0), X(x1), X(y1)), radius=X(14), fill=fill)
    if dashed:
        dash_rect(x0, y0, x1, y1, color)
    else:
        d.rounded_rectangle((X(x0), X(y0), X(x1), X(y1)), radius=X(14), outline=color, width=X(2.2))
    tx = title_x if title_x is not None else x0 + 14
    if title:
        d.text((X(tx), X(y0 + 10)), title, font=font(15, True), fill=title_color or color)
    if sub:
        d.text((X(tx), X(y0 + 31)), sub, font=font(11.5), fill=MUTED)


def dashed_line(p0, p1, color, width, dash=12, gap=9):
    (x0, y0), (x1, y1) = p0, p1
    length = math.hypot(x1 - x0, y1 - y0)
    if length == 0:
        return
    ux, uy = (x1 - x0) / length, (y1 - y0) / length
    pos = 0
    while pos < length:
        end = min(pos + dash, length)
        d.line((X(x0 + ux * pos), X(y0 + uy * pos), X(x0 + ux * end), X(y0 + uy * end)), fill=color, width=X(width))
        pos += dash + gap


def dash_rect(x0, y0, x1, y1, color):
    for a, b in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        dashed_line(a, b, color, 2.2)


def arrow(points, color, label=None, width=3, dashed=False, label_pos=None, label_anchor="mm"):
    for a, b in zip(points, points[1:]):
        if dashed:
            dashed_line(a, b, color, width)
        else:
            d.line((X(a[0]), X(a[1]), X(b[0]), X(b[1])), fill=color, width=X(width))
    (x0, y0), (x1, y1) = points[-2], points[-1]
    ang = math.atan2(y1 - y0, x1 - x0)
    size = 13
    left = (x1 - size * math.cos(ang - 0.45), y1 - size * math.sin(ang - 0.45))
    right = (x1 - size * math.cos(ang + 0.45), y1 - size * math.sin(ang + 0.45))
    d.polygon([(X(x1), X(y1)), (X(left[0]), X(left[1])), (X(right[0]), X(right[1]))], fill=color)
    if label:
        lx, ly = label_pos or ((x0 + x1) / 2, (y0 + y1) / 2 - 12)
        tw = d.textlength(label, font=font(11.5, True)) / S
        d.rounded_rectangle((X(lx - tw / 2 - 6), X(ly - 10), X(lx + tw / 2 + 6), X(ly + 10)), radius=X(6), fill="#0a1124")
        d.text((X(lx), X(ly)), label, font=font(11.5, True), fill=color, anchor="mm")


def tile(cx, cy, icon, label=None, size=52, label_color=WHITE):
    """A white rounded square with the icon on it and a caption below."""
    pad = 9
    half = size / 2 + pad
    d.rounded_rectangle((X(cx - half), X(cy - half), X(cx + half), X(cy + half)), radius=X(12), fill="#f8fafc")
    ic = Image.open(os.path.join(ICONS, icon + ".png")).convert("RGBA").resize((X(size), X(size)), Image.LANCZOS)
    img.paste(ic, (X(cx - size / 2), X(cy - size / 2)), ic)
    if label:
        d.multiline_text((X(cx), X(cy + half + 6)), label, font=font(12), fill=label_color, anchor="ma", align="center", spacing=X(2))


def text(x, y, s, size=12, color=MUTED, bold=False, anchor="la"):
    d.multiline_text((X(x), X(y)), s, font=font(size, bold), fill=color, anchor=anchor, align="center" if anchor[0] == "m" else "left", spacing=X(3))


# ---------------------------------------------------------------- title
text(W / 2, 22, "School Demo on Amazon EKS", 32, WHITE, True, "ma")
text(W / 2, 64, "AWS-native architecture  -  Terraform  +  Jenkins CI  +  Argo CD GitOps  +  Prometheus / Grafana monitoring", 14, MUTED, False, "ma")

# ---------------------------------------------------------------- top: provisioning and the CI pipeline
tile(100, 175, "onprem/iac/terraform", "Terraform\ninfrastructure as code")
tile(265, 175, "onprem/client/user", "Developer")
tile(410, 175, "onprem/vcs/github", "GitHub\nrelease branches")
tile(555, 175, "onprem/ci/jenkins", "Jenkins\nCI server")
arrow([(305, 175), (366, 175)], C_CI, "push", label_pos=(335, 152))
arrow([(450, 175), (511, 175)], C_CI, "build", label_pos=(480, 152))
arrow([(597, 175), (668, 175)], C_CI)

box(670, 100, 1675, 478, C_CI, "CONTINUOUS INTEGRATION  -  JENKINS PIPELINE (19 stages, any failure stops the release)", dashed=True)
cols = [790, 1030, 1270, 1510]
rows = [200, 305, 410]
steps = {
    (0, 0): ("programming/language/python", "Unit tests\npytest + node:test"),
    (0, 1): ("generic/compute/rack", "SonarQube\ncode quality (SAST)"),
    (0, 2): ("generic/compute/rack", "Dependency check\npip-audit, npm audit, OWASP"),
    (0, 3): ("onprem/container/docker", "Build Docker images\nfrontend + backend"),
    (1, 3): ("onprem/security/trivy", "Trivy image scan\nfail on CRITICAL"),
    (1, 2): ("aws/compute/ec2-container-registry", "Push to Amazon ECR\nimmutable tags"),
    (1, 1): ("aws/compute/ec2-container-registry", "ECR image scan\nfail on CRITICAL"),
    (1, 0): ("onprem/container/docker", "docker compose run\nPostgreSQL tables created"),
    (2, 0): ("programming/language/python", "Smoke +\nintegration tests"),
    (2, 1): ("generic/compute/rack", "OWASP ZAP\nDAST attack scan"),
    (2, 2): ("generic/compute/rack", "JMeter\nload test"),
    (2, 3): ("onprem/vcs/github", "Update image names,\nreports to S3, pull request"),
}
for (r, c), (icon, label) in steps.items():
    tile(cols[c], rows[r], icon, label, size=46)
for c in range(3):
    arrow([(cols[c] + 42, rows[0]), (cols[c + 1] - 42, rows[0])], C_CI, width=2.5)
arrow([(cols[3] + 42, rows[0]), (cols[3] + 95, rows[0]), (cols[3] + 95, rows[1]), (cols[3] + 42, rows[1])], C_CI, width=2.5)
for c in (3, 2, 1):
    arrow([(cols[c] - 42, rows[1]), (cols[c - 1] + 42, rows[1])], C_CI, width=2.5)
arrow([(cols[0] - 42, rows[1]), (cols[0] - 95, rows[1]), (cols[0] - 95, rows[2]), (cols[0] - 42, rows[2])], C_CI, width=2.5)
for c in range(3):
    arrow([(cols[c] + 42, rows[2]), (cols[c + 1] - 42, rows[2])], C_CI, width=2.5)

# ---------------------------------------------------------------- release row: PR, Argo CD, Slack
tile(1505, 545, "onprem/vcs/github", "GitHub  main\n(pull request merged)")
tile(1170, 545, "onprem/gitops/argocd", "Argo CD\nwatches main")
tile(1640, 545, "saas/chat/slack", "Slack\nmessage")
arrow([(1505, 478), (1505, 506)], C_CI, "pull request", label_pos=(1440, 492))
arrow([(1640, 478), (1640, 506)], C_CI)
arrow([(1462, 545), (1213, 545)], C_DEPLOY, "Argo CD pulls", label_pos=(1338, 522))

# ---------------------------------------------------------------- users
tile(327, 545, "onprem/client/users", "Team\n(allowed IPs only)")
tile(525, 545, "onprem/client/users", "Users\n(customers)")

# ---------------------------------------------------------------- the AWS account
box(30, 628, 1670, 1245, C_AWS, "AWS ACCOUNT", sub="region us-east-1")
arrow([(100, 250), (100, 626)], C_DEPLOY, None, dashed=True)
text(114, 330, "Terraform creates\nall AWS resources\nbelow (one apply)", 12, C_DEPLOY)

# shared services column
text(160, 692, "Shared AWS services", 12.5, C_AWS, True, "ma")
tile(160, 750, "aws/compute/ec2-container-registry", "Amazon ECR\nimages, scan on push", size=44)
tile(160, 850, "aws/storage/simple-storage-service-s3", "Amazon S3\nTF state + CI reports", size=44)
tile(160, 950, "aws/management/cloudwatch", "CloudWatch\nlogs + Container Insights", size=44)
tile(160, 1050, "aws/security/identity-and-access-management-iam", "IAM roles + IRSA\nleast privilege", size=44)
tile(160, 1150, "aws/security/key-management-service", "KMS\nencrypts K8s Secrets", size=44)

# VPC
box(305, 655, 1655, 1232, C_VPC, "VPC 10.0.0.0/16  -  3 Availability Zones", fill="#0c1426", title_x=650)

# public subnets
box(350, 698, 620, 1220, C_PUBLIC, "Public subnets", fill="#0e1b1c")
tile(525, 845, "aws/network/elb-application-load-balancer", "ALB - website\nport 80, open", size=44)
tile(525, 950, "aws/network/nat-gateway", "NAT gateway\noutbound only", size=44)
tile(525, 1055, "aws/compute/ec2", "Public node (EC2)", size=44)
tile(525, 1150, "aws/network/elb-application-load-balancer", None, size=44)
text(525, 1190, "ALB team tools (team IPs)", 11.5, WHITE, False, "ma")

# EKS cluster
box(640, 698, 1640, 1220, C_EKS, "Amazon EKS cluster", fill="#101827")
text(850, 709, "control plane managed by AWS; nodes in 3 managed node groups", 11.5, MUTED)
tile(1590, 728, "aws/compute/elastic-kubernetes-service", None, size=22)

tiers = [
    (655, 945, "FRONTEND TIER", "Deployment, 3 pods, app nodes", C_APP, "k8s/network/svc", "onprem/network/nginx", "nginx\n3 pods",
     "nginx serves the web page\nand forwards /api to the backend\nHPA 3-6, PDB min 2, spread over 3 AZs"),
    (960, 1250, "BACKEND TIER", "Deployment, 3 pods, app nodes", C_APP, "k8s/network/svc", "programming/framework/flask", "Flask API\n3 pods",
     "Flask API (gunicorn)\nvalidates input, reads/writes the DB\nreadiness = database reachable"),
    (1265, 1625, "DATABASE TIER", "StatefulSet, 1 pod, database node", C_DB, "k8s/network/svc", "onprem/database/postgresql", "PostgreSQL\n1 pod",
     "PostgreSQL, tables created from a ConfigMap\nSecret + ConfigMap hold the credentials\nPVC -> gp3 StorageClass -> encrypted EBS"),
]
for x0, x1, title, sub, color, svc_icon, pod_icon, pod_label, desc in tiers:
    box(x0, 765, x1, 1005, color, title, fill="#0c1424", sub=sub)
    cx = x0 + 70
    tile(cx, 845, svc_icon, "Service", size=34)
    tile(cx + 145, 845, pod_icon, pod_label, size=44)
    arrow([(cx + 36, 845), (cx + 145 - 36, 845)], MUTED, width=2, label=None)
    text(x0 + 14, 940, desc, 11, MUTED)
tile(1265 + 70 + 145 + 100, 845, "aws/storage/elastic-block-store-ebs", "EBS gp3", size=40)
arrow([(1265 + 70 + 145 + 36, 845), (1265 + 70 + 145 + 100 - 34, 845)], MUTED, width=2)

# team tools strip
box(655, 1022, 1625, 1205, C_TEAM, "TEAM TOOLS  -  only team_access_cidrs can reach them", fill="#14142a", sub="run on the application nodes")
tile(760, 1115, "onprem/gitops/argocd", "Argo CD\nport 8080", size=40)
tile(930, 1115, "onprem/monitoring/prometheus", "Prometheus\n+ Alertmanager", size=40)
tile(1100, 1115, "onprem/monitoring/grafana", "Grafana\ndashboards", size=40)
arrow([(966, 1115), (1062, 1115)], MUTED, width=2)
text(1175, 1088, "also scraped: node-exporter on every node,\nkube-state-metrics, kubelet / cAdvisor,\nmetrics-server (HPA), VPA", 11, MUTED)
text(1175, 1150, "alerts: CPU > 30 %, memory > 40 %, disk > 40 %,\nvolume > 40 %, pod crash loop  ->  Slack", 11, MUTED)

# ---------------------------------------------------------------- traffic arrows
arrow([(525, 626), (525, 808)], C_USER, "HTTP", label_pos=(560, 700))
arrow([(562, 845), (684, 845)], C_USER, None)
arrow([(327, 622), (327, 1150), (484, 1150)], C_TEAM, "HTTP", label_pos=(327, 760))
arrow([(566, 1150), (630, 1150), (630, 1115), (716, 1115)], C_TEAM, None)
arrow([(1170, 622), (1170, 696)], C_DEPLOY, "sync = deploy", label_pos=(1170, 660))
arrow([(655 + 70 + 145 + 38, 845 + 0), (960 + 70 - 38, 845)], C_USER, "/api", label_pos=(935, 818))
arrow([(960 + 70 + 145 + 38, 845), (1265 + 70 - 38, 845)], C_USER, "SQL", label_pos=(1257, 818))

# ---------------------------------------------------------------- legend
text(40, 1257, "Legend:", 12, WHITE, True)
legend = [(C_USER, "customer traffic"), (C_TEAM, "team traffic"), (C_CI, "CI pipeline"), (C_DEPLOY, "deployment (Argo CD / Terraform)")]
lx = 120
for color, name in legend:
    d.line((X(lx), X(1264), X(lx + 34), X(1264)), fill=color, width=X(3))
    text(lx + 42, 1256, name, 12, MUTED)
    lx += 42 + int(d.textlength(name, font=font(12)) / S) + 34

img.convert("RGB").save(OUT, optimize=True)
print("saved", OUT, img.size)
