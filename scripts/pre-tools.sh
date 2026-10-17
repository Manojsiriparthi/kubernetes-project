#!/usr/bin/env bash
# Prepares an Ubuntu/Debian (apt) or Amazon Linux (dnf/yum) CI host: Jenkins, Docker, SonarQube, Terraform, AWS CLI,
# kubectl, Helm, Argo CD CLI, Trivy, Node.js, Python, JMeter and a Prometheus + Grafana stack.
# Run with: sudo ./scripts/pre-tools.sh
set -euo pipefail

# Versions can be overridden from the environment, e.g. HELM_VERSION=v3.18.4 sudo -E ./scripts/pre-tools.sh
# kubectl may differ from the cluster version by one minor release.
KUBECTL_MINOR="${KUBECTL_MINOR:-v1.34}"
HELM_VERSION="${HELM_VERSION:-v3.18.4}"
# Where the Prometheus and Grafana config files are kept on the host.
MONITORING_DIR="${MONITORING_DIR:-/opt/monitoring}"
# JMeter has no apt package that is current, so it is downloaded as a release tarball.
JMETER_VERSION="${JMETER_VERSION:-5.6.3}"
# Shared Docker network so Grafana can reach Prometheus by container name.
DOCKER_NETWORK="tools-net"

# Prints a visible heading before each install step.
log() { printf '\n==> %s\n' "$*"; }

# Installing packages and starting services needs root.
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# Load OS details (ID, VERSION_CODENAME) used to pick the right apt repositories.
. /etc/os-release
# PKG selects the package manager: apt on Ubuntu/Debian, dnf (or yum on Amazon Linux 2) on Amazon Linux.
case "${ID}" in
  ubuntu | debian) PKG=apt ;;
  amzn) PKG=$(command -v dnf >/dev/null && echo dnf || echo yum) ;;
  *) echo "Unsupported OS '${ID}'; this script supports Ubuntu, Debian and Amazon Linux." >&2; exit 1 ;;
esac

# Package helpers so each tool below is installed the same way on both families.
pkg_refresh() { if [[ $PKG == apt ]]; then apt-get update -y; else "$PKG" makecache -y; fi; }
pkg_install() { if [[ $PKG == apt ]]; then apt-get install -y "$@"; else "$PKG" install -y "$@"; fi; }
# Writes a yum repo file: add_rpm_repo <name> <baseurl> <gpgkey-url>
add_rpm_repo() {
  printf '[%s]\nname=%s\nbaseurl=%s\nenabled=1\ngpgcheck=1\ngpgkey=%s\n' "$1" "$1" "$2" "$3" >"/etc/yum.repos.d/$1.repo"
}

# Map the CPU type to the names used in each vendor's download URLs.
case "$(uname -m)" in
  x86_64) ARCH="amd64"; AWS_ARCH="x86_64" ;;
  aarch64) ARCH="arm64"; AWS_ARCH="aarch64" ;;
  *) echo "Unsupported CPU architecture $(uname -m)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
# Downloads go to a temp folder that is removed when the script exits, even on failure.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# Folder for the signing keys of third-party apt repositories.
install -m 0755 -d /etc/apt/keyrings

log "Updating the system"
if [[ $PKG == apt ]]; then
  # A Jenkins repo left by an earlier run still points at the old key and would fail the update below.
  if [[ -f /etc/apt/sources.list.d/jenkins.list ]]; then
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
  fi
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y ca-certificates curl gnupg lsb-release unzip tar jq openssl apt-transport-https
else
  # curl is already present on Amazon Linux (curl-minimal); installing curl would conflict with it.
  "$PKG" upgrade -y
  pkg_install ca-certificates unzip tar jq openssl gzip
fi

# Each tool below is skipped if it is already installed, so the script is safe to re-run.
log "Installing Docker"
if ! command -v docker >/dev/null; then
  if [[ $PKG == apt ]]; then
    # Add Docker's official apt repository, verified with its signing key.
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    pkg_install docker
    # Amazon Linux's docker package has no compose plugin; install the release binary as a CLI plugin.
    install -d /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${AWS_ARCH}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose
  fi
fi
systemctl enable --now docker

# Jenkins needs a Java runtime; fontconfig is required for its web UI.
log "Installing Jenkins (Java 21 + Jenkins LTS)"
# Current Jenkins supports only Java 21 and 25; installed outside the guard below so re-runs fix hosts that have Java 17.
if [[ $PKG == apt ]]; then
  apt-get install -y fontconfig openjdk-21-jre-headless
  update-alternatives --set java "/usr/lib/jvm/java-21-openjdk-$(dpkg --print-architecture)/bin/java"
else
  pkg_install fontconfig java-21-amazon-corretto-headless
fi
if ! command -v jenkins >/dev/null && ! dpkg -s jenkins >/dev/null 2>&1; then
  # The 2023 signing key has expired; Jenkins repos are now signed with the 2026 key.
  if [[ $PKG == apt ]]; then
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
      >/etc/apt/sources.list.d/jenkins.list
  else
    add_rpm_repo jenkins https://pkg.jenkins.io/redhat-stable https://pkg.jenkins.io/redhat-stable/jenkins.io-2026.key
  fi
  pkg_refresh
  pkg_install jenkins
fi
# Lets Jenkins pipelines run docker commands; restart so the new group membership takes effect.
usermod -aG docker jenkins
systemctl enable jenkins
# Clears the "start request repeated too quickly" state left by earlier failed starts.
systemctl reset-failed jenkins || true
if ! systemctl restart jenkins; then
  echo "Jenkins failed to start. Java in use and the last log lines:" >&2
  java -version >&2 || true
  ss -ltnp 2>/dev/null | grep ':8080 ' >&2 || true
  journalctl -u jenkins --no-pager -n 40 >&2
  exit 1
fi

log "Installing Terraform"
if ! command -v terraform >/dev/null; then
  if [[ $PKG == apt ]]; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main" \
      >/etc/apt/sources.list.d/hashicorp.list
  else
    add_rpm_repo hashicorp https://rpm.releases.hashicorp.com/AmazonLinux/\$releasever/\$basearch/stable https://rpm.releases.hashicorp.com/gpg
  fi
  pkg_refresh
  pkg_install terraform
fi

# The AWS CLI is not in apt; download the official installer. --update makes re-runs safe.
log "Installing AWS CLI v2"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "${TMP_DIR}/awscliv2.zip"
unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}"
"${TMP_DIR}/aws/install" --update

log "Installing kubectl ${KUBECTL_MINOR}"
if ! command -v kubectl >/dev/null; then
  if [[ $PKG == apt ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/ /" \
      >/etc/apt/sources.list.d/kubernetes.list
  else
    add_rpm_repo kubernetes "https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/rpm/" "https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/rpm/repodata/repomd.xml.key"
  fi
  pkg_refresh
  pkg_install kubectl
fi

# Helm and the Argo CD CLI are single binaries; each download is checked against its published SHA-256.
log "Installing Helm ${HELM_VERSION}"
if ! command -v helm >/dev/null; then
  helm_tar="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSL "https://get.helm.sh/${helm_tar}" -o "${TMP_DIR}/${helm_tar}"
  curl -fsSL "https://get.helm.sh/${helm_tar}.sha256sum" -o "${TMP_DIR}/${helm_tar}.sha256sum"
  (cd "${TMP_DIR}" && sha256sum -c "${helm_tar}.sha256sum")
  tar -xzf "${TMP_DIR}/${helm_tar}" -C "${TMP_DIR}"
  install -m 0755 "${TMP_DIR}/linux-${ARCH}/helm" /usr/local/bin/helm
fi

log "Installing Argo CD CLI"
if ! command -v argocd >/dev/null; then
  argo_base="https://github.com/argoproj/argo-cd/releases/latest/download"
  curl -fsSL "${argo_base}/argocd-linux-${ARCH}" -o "${TMP_DIR}/argocd"
  curl -fsSL "${argo_base}/cli_checksums.txt" -o "${TMP_DIR}/cli_checksums.txt"
  expected="$(awk -v f="argocd-linux-${ARCH}" '$2 == f {print $1}' "${TMP_DIR}/cli_checksums.txt")"
  echo "${expected}  ${TMP_DIR}/argocd" | sha256sum -c -
  install -m 0755 "${TMP_DIR}/argocd" /usr/local/bin/argocd
fi

# Tools the Jenkins pipeline (jenkins/Jenkinsfile.*.groovy) runs on this host: Trivy, Node.js, Python, JMeter.
log "Installing Trivy (image and filesystem scanner)"
if ! command -v trivy >/dev/null; then
  if [[ $PKG == apt ]]; then
    curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /etc/apt/keyrings/trivy.gpg
    echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
      >/etc/apt/sources.list.d/trivy.list
  else
    # Trivy has no Amazon Linux repo path; its static binary works from the RHEL 9 one.
    add_rpm_repo trivy https://aquasecurity.github.io/trivy-repo/rpm/releases/9/\$basearch/ https://aquasecurity.github.io/trivy-repo/rpm/public.key
  fi
  pkg_refresh
  pkg_install trivy
fi

log "Installing Node.js 20 (npm install, npm audit, frontend tests)"
if ! command -v node >/dev/null; then
  if [[ $PKG == apt ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      >/etc/apt/sources.list.d/nodesource.list
  else
    add_rpm_repo nodesource https://rpm.nodesource.com/pub_20.x/nodistro/nodejs/\$basearch https://rpm.nodesource.com/gpgkey/ns-operations-public.key
  fi
  pkg_refresh
  pkg_install nodejs
fi

# The pipeline creates a virtualenv per build, so only python3, pip and venv are needed here.
log "Installing Python 3 (backend tests, pip-audit)"
if [[ $PKG == apt ]]; then
  apt-get install -y python3 python3-pip python3-venv
else
  pkg_install python3 python3-pip
fi

log "Installing JMeter ${JMETER_VERSION} (load tests; uses the Java installed for Jenkins)"
if [[ ! -x /opt/jmeter/bin/jmeter ]]; then
  jmeter_tgz="apache-jmeter-${JMETER_VERSION}.tgz"
  jmeter_url="https://archive.apache.org/dist/jmeter/binaries/${jmeter_tgz}"
  curl -fsSL "${jmeter_url}" -o "${TMP_DIR}/${jmeter_tgz}"
  curl -fsSL "${jmeter_url}.sha512" -o "${TMP_DIR}/${jmeter_tgz}.sha512"
  (cd "${TMP_DIR}" && sha512sum -c "${jmeter_tgz}.sha512")
  mkdir -p /opt/jmeter
  tar -xzf "${TMP_DIR}/${jmeter_tgz}" -C /opt/jmeter --strip-components=1
  ln -sf /opt/jmeter/bin/jmeter /usr/local/bin/jmeter
fi

log "Starting SonarQube (sonarqube:lts-community)"
# SonarQube's embedded Elasticsearch fails to start unless these kernel limits are raised.
cat >/etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system >/dev/null
# Create the shared network once, then start SonarQube with volumes so data survives container restarts.
docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1 || docker network create "${DOCKER_NETWORK}"
if ! docker inspect sonarqube >/dev/null 2>&1; then
  docker run -d --name sonarqube --restart unless-stopped --network "${DOCKER_NETWORK}" \
    -p 9000:9000 \
    -v sonarqube_data:/opt/sonarqube/data \
    -v sonarqube_extensions:/opt/sonarqube/extensions \
    -v sonarqube_logs:/opt/sonarqube/logs \
    sonarqube:lts-community
else
  docker start sonarqube >/dev/null
fi

log "Starting Prometheus and Grafana"
mkdir -p "${MONITORING_DIR}/grafana-provisioning/datasources"
# Prometheus config: it only scrapes itself for now; add more scrape_configs targets here later.
cat >"${MONITORING_DIR}/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
EOF
# Grafana provisioning: registers Prometheus as the default data source on startup.
cat >"${MONITORING_DIR}/grafana-provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

# Generate the Grafana admin password once; the file is readable by root only (umask 077).
GRAFANA_PASSWORD_FILE="${MONITORING_DIR}/grafana-admin-password"
if [[ ! -f "${GRAFANA_PASSWORD_FILE}" ]]; then
  (umask 077 && openssl rand -hex 16 >"${GRAFANA_PASSWORD_FILE}")
fi

# Start the containers on first run, or just start them if they already exist; --restart keeps them up after reboots.
if ! docker inspect prometheus >/dev/null 2>&1; then
  docker run -d --name prometheus --restart unless-stopped --network "${DOCKER_NETWORK}" \
    -p 9090:9090 \
    -v "${MONITORING_DIR}/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v prometheus_data:/prometheus \
    prom/prometheus:latest
else
  docker start prometheus >/dev/null
fi

if ! docker inspect grafana >/dev/null 2>&1; then
  docker run -d --name grafana --restart unless-stopped --network "${DOCKER_NETWORK}" \
    -p 3000:3000 \
    -e GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password \
    -v "${GRAFANA_PASSWORD_FILE}:/run/secrets/grafana_admin_password:ro" \
    -v "${MONITORING_DIR}/grafana-provisioning:/etc/grafana/provisioning:ro" \
    -v grafana_data:/var/lib/grafana \
    grafana/grafana-oss:latest
else
  docker start grafana >/dev/null
fi

# Pre-pull the images the pipeline runs in containers (SonarQube scanner, OWASP ZAP, Dependency-Check) so builds start faster.
log "Pulling CI scanner images"
docker pull sonarsource/sonar-scanner-cli:latest
docker pull zaproxy/zap-stable:latest
docker pull owasp/dependency-check:latest

# Final check: print each tool's version, then how to reach the services.
log "Installed versions"
docker --version
terraform version | head -n 1
aws --version
kubectl version --client
helm version --short
argocd version --client --short || true
trivy --version | head -n 1
node --version
npm --version
python3 --version

cat <<EOF

Done. Services (open the ports in your firewall/security group only to trusted IPs):
  Jenkins    http://<host>:8080   initial password: sudo cat /var/lib/jenkins/secrets/initialAdminPassword
  SonarQube  http://<host>:9000   default login admin/admin (you must change it on first login)
  Prometheus http://<host>:9090
  Grafana    http://<host>:3000   user admin, password: sudo cat ${GRAFANA_PASSWORD_FILE}

Log out and back in for docker group changes to apply to your own user (usermod -aG docker <user>).
EOF
