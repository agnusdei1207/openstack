#!/bin/bash

# v5.2 - OpenStack 2023.2 (Bobcat) + ProxySQL 완전 비활성화 버전
# 수정사항: enable_proxysql: "no" 추가로 포트 충돌 원천 차단

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

error_exit() {
    log_error "$1"
    log_error "스크립트 실행 실패: Line ${BASH_LINENO[0]}"
    exit 1
}

###############################################################################
# MariaDB 디버깅 함수
###############################################################################
debug_mariadb() {
    echo ""
    echo "============================================================"
    log_info "MariaDB 상세 디버깅 정보"
    echo "============================================================"
    log_info "[1] 컨테이너 상태:"
    docker ps -a --filter "name=mariadb" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    log_info "[2] 호스트 3306 포트 점유 상태:"
    netstat -tulpn 2>/dev/null | grep 3306 || ss -tulpn 2>/dev/null | grep 3306 || echo "3306 포트 사용 없음 (정상)"
    echo ""
    log_info "[3] MariaDB 로그 (최근 50줄):"
    docker logs --tail 50 mariadb 2>&1
    echo "============================================================"
}

###############################################################################
# 0. 사전 검증
###############################################################################
if [ "$EUID" -ne 0 ]; then
    error_exit "root 권한 필요 (sudo -i 실행 후 사용)"
fi

if [ -z "${1:-}" ]; then
    log_error "외부 IP를 입력해주세요."
    echo "사용법: $0 <외부_IP> [도메인명]"
    exit 1
fi

EXTERNAL_IP="$1"
DOMAIN_NAME="${2:-}"

if ! [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error_exit "올바른 IP 형식이 아닙니다: $EXTERNAL_IP"
fi

TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -lt 6 ]; then
    log_warn "메모리가 부족합니다 (${TOTAL_MEM}GB). 최소 8GB 권장"
    read -p "계속하시겠습니까? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
fi

export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_HOST_KEY_CHECKING=False
export PIP_DEFAULT_TIMEOUT=100
unset TMOUT
export TMOUT=0

###############################################################################
# 1. 필수 패키지 설치
###############################################################################
log_info "Step 1: 기초 패키지 설치..."
apt update -qq
apt install -y python3-pip python3-venv python3-dev git curl chrony lvm2 \
    thin-provisioning-tools apt-transport-https ca-certificates gnupg \
    software-properties-common certbot net-tools lsof \
    2>/dev/null || log_warn "패키지 설치 경고 (진행)"

###############################################################################
# 2. 강력한 클린업 (ProxySQL 및 MariaDB 완전 박멸)
###############################################################################
log_warn "Step 2: 기존 환경 및 좀비 프로세스 정리..."

# 1. Kolla 제거
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it >/dev/null 2>&1 || true
    deactivate >/dev/null 2>&1 || true
fi

# 2. Docker 정리
if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker volume rm $(docker volume ls -q) >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
fi

# 3. [핵심] 3306 포트 및 ProxySQL 강제 종료
log_info "ProxySQL 및 DB 관련 프로세스 사살 중..."
pkill -9 -f proxysql 2>/dev/null || true
pkill -9 -f mariadbd 2>/dev/null || true
pkill -9 -f mysqld 2>/dev/null || true
fuser -k -9 3306/tcp 2>/dev/null || true

# 4. 잔존 파일 삭제
rm -rf /etc/kolla ~/kolla-venv ~/.ansible /var/log/kolla 2>/dev/null || true
# 중요: MariaDB 데이터가 남아있으면 버전 충돌남
rm -rf /var/lib/docker/volumes/mariadb/_data 2>/dev/null || true

# 5. 포트 클린업 확인
sleep 3
if netstat -tulpn 2>/dev/null | grep -q ":3306"; then
    log_error "3306 포트를 비울 수 없습니다. 수동 확인 필요."
    netstat -tulpn | grep 3306
    exit 1
fi
log_success "3306 포트 정리 완료"

###############################################################################
# 3. 스왑 메모리 설정
###############################################################################
log_info "Step 3: 스왑 메모리 설정..."
if ! grep -q '/swapfile' /etc/fstab; then
    swapoff -a >/dev/null 2>&1 || true
    rm -f /swapfile
    if fallocate -l 16G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=16384 status=none; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl -w vm.swappiness=10 >/dev/null
    fi
fi

###############################################################################
# 4. 시스템 설정
###############################################################################
log_info "Step 4: 시스템 설정..."
hostnamectl set-hostname openstack 2>/dev/null || true
sed -i '/openstack/d' /etc/hosts
echo "127.0.0.1 localhost openstack" >> /etc/hosts

if ! vgs cinder &>/dev/null; then
    dd if=/dev/zero of=/var/lib/cinder_data.img bs=1M count=20480 status=none
    LOOP_DEV=$(losetup -f)
    losetup $LOOP_DEV /var/lib/cinder_data.img
    pvcreate $LOOP_DEV >/dev/null && vgcreate cinder $LOOP_DEV >/dev/null
fi

cat > /etc/systemd/system/cinder-loop.service <<'EOF'
[Unit]
Description=Setup Cinder Loopback Device
After=local-fs.target
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -f /var/lib/cinder_data.img ]; then LOOP=$(/sbin/losetup -f); /sbin/losetup $LOOP /var/lib/cinder_data.img 2>/dev/null || true; /sbin/vgchange -ay cinder 2>/dev/null || true; fi'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable cinder-loop.service >/dev/null 2>&1 || true

if ! ip link show eth1 &>/dev/null; then
    modprobe dummy
    ip link add eth1 type dummy
    ip link set eth1 up
    mkdir -p /etc/systemd/network
    echo -e "[NetDev]\nName=eth1\nKind=dummy" > /etc/systemd/network/10-dummy0.netdev
    echo -e "[Match]\nName=eth1\n\n[Network]" > /etc/systemd/network/20-dummy0.network
fi

###############################################################################
# 5. Docker 설치
###############################################################################
log_info "Step 5: Docker 설치..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt update -qq
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "50m", "max-file": "3"},
    "storage-driver": "overlay2",
    "live-restore": true,
    "dns": ["8.8.8.8", "8.8.4.4"]
}
EOF
systemctl enable docker >/dev/null 2>&1
systemctl restart docker
sleep 3

###############################################################################
# 6. Kolla-Ansible 설치 (Bobcat 2023.2)
###############################################################################
log_info "Step 6: Kolla-Ansible 설치 (OpenStack 2023.2 Bobcat)..."

python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install --upgrade pip setuptools wheel

log_info "Python 패키지 설치 (Bobcat 호환)..."
pip install 'ansible-core>=2.15,<2.16'
pip install 'kolla-ansible==17.2.0'

mkdir -p /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

###############################################################################
# 7. Ansible Galaxy 의존성
###############################################################################
log_info "Step 7: Ansible Galaxy 의존성 설치..."
kolla-ansible install-deps >/dev/null 2>&1 || \
    ansible-galaxy collection install ansible.posix community.general ansible.utils --force

###############################################################################
# 8. Kolla 설정 (globals.yml)
###############################################################################
log_info "Step 8: globals.yml 설정 생성 (ProxySQL OFF)..."

MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
HOST_INTERNAL_IP=$(ip -4 addr show "$MAIN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

VIRT_TYPE="qemu"
if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1 && [ -e /dev/kvm ]; then
    VIRT_TYPE="kvm"
fi

cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2023.2" 

# 네트워크
network_interface: "$MAIN_INTERFACE"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "$HOST_INTERNAL_IP"
kolla_external_vip_address: "$EXTERNAL_IP"
neutron_dns_nameservers: ["8.8.8.8", "8.8.4.4"]

# [중요] ProxySQL 비활성화 (포트 충돌 방지)
enable_proxysql: "no"
# HAProxy는 VIP 관리를 위해 유지 (표준 구성)
enable_haproxy: "yes"

# 서비스 활성화
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder"

# 가상화
nova_compute_virt_type: "$VIRT_TYPE"
neutron_plugin_agent: "openvswitch"

# MariaDB 설정
enable_mariadb_backup: "no"
mariadb_max_connections: "200"

# 로깅 최적화
openstack_logging_debug: "False"
enable_ceilometer: "no"
enable_heat: "no"
enable_aodh: "no"
enable_gnocchi: "no"
EOF

kolla-genpwd
ADMIN_PASSWORD=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')

cat > ~/openstack-credentials.txt <<EOF
URL: http://$EXTERNAL_IP
Username: admin
Password: $ADMIN_PASSWORD
EOF
chmod 600 ~/openstack-credentials.txt

###############################################################################
# 9. Ansible 최적화
###############################################################################
cat > ~/ansible.cfg <<EOF
[defaults]
host_key_checking = False
pipelining = True
forks = 4
timeout = 600
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600
retry_files_enabled = False
[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=60
pipelining = True
EOF
export ANSIBLE_CONFIG=~/ansible.cfg

###############################################################################
# 10. OpenStack 배포
###############################################################################
log_info "Step 9: OpenStack 배포 시작 (Bobcat)..."

if [ -z "${STY:-}" ] && [ -z "${TMUX:-}" ] && [ -n "$SSH_TTY" ]; then
    log_warn "SSH 연결 중입니다. 끊김에 주의하세요."
    sleep 5
fi

# 1. Bootstrap
log_info "Bootstrap 실행..."
if ! kolla-ansible bootstrap-servers -i ~/all-in-one 2>&1 | tee /tmp/kolla-bootstrap.log; then
    log_error "Bootstrap 실패. 로그 확인:"
    tail -20 /tmp/kolla-bootstrap.log
    exit 1
fi
log_success "Bootstrap 완료"

# 2. Prechecks
log_info "Prechecks 실행..."
if ! kolla-ansible prechecks -i ~/all-in-one 2>&1 | tee /tmp/kolla-prechecks.log; then
    log_error "Prechecks 실패"
    tail -20 /tmp/kolla-prechecks.log
    exit 1
fi
log_success "Prechecks 완료"

# 3. Deploy
log_info "Deploy 실행... (약 20~30분 소요)"

# 백그라운드 모니터링
(
    MONITOR_LOG="/tmp/mariadb-monitor.log"
    echo "START" > "$MONITOR_LOG"
    while true; do
        # 3306 포트 상태와 MariaDB 컨테이너 상태만 심플하게 기록
        echo "$(date) | Port 3306: $(netstat -tulpn 2>/dev/null | grep 3306 | awk '{print $7}') | DB: $(docker ps --filter name=mariadb --format '{{.Status}}')" >> "$MONITOR_LOG"
        sleep 30
    done
) &
MONITOR_PID=$!

if ! kolla-ansible deploy -i ~/all-in-one -vv 2>&1 | tee /tmp/kolla-deploy.log; then
    kill $MONITOR_PID 2>/dev/null
    log_error "Deploy 실패"
    debug_mariadb
    
    log_info "=== Deploy 에러 로그 (마지막 30줄) ==="
    grep -i "fatal\|failed\|error" /tmp/kolla-deploy.log | tail -30
    exit 1
fi

kill $MONITOR_PID 2>/dev/null
log_success "Deploy 완료"

###############################################################################
# 11. 검증 및 마무리
###############################################################################
log_info "Step 10: 배포 검증..."

# MariaDB Health Check
log_info "MariaDB 시작 대기 중..."
DB_PASS=$(grep database_password /etc/kolla/passwords.yml | awk '{print $2}')
for i in {1..60}; do
    if docker exec mariadb mysql -uroot -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
        log_success "MariaDB 정상 (Attempt $i)"
        break
    fi
    if [ $i -eq 60 ]; then
        log_error "MariaDB 연결 타임아웃"
        debug_mariadb
        exit 1
    fi
    sleep 3
done

kolla-ansible post-deploy -i ~/all-in-one

pip install 'python-openstackclient==6.5.0' 'python-neutronclient==11.0.0' \
    'python-novaclient==18.5.0' 'python-glanceclient==4.5.0' 'python-cinderclient==9.4.0' \
    >/dev/null 2>&1

source /etc/kolla/admin-openrc.sh
if openstack endpoint list >/dev/null 2>&1; then
    log_success "OpenStack API 호출 성공"
else
    log_warn "API 호출 실패 (서비스 기동 대기 중일 수 있음)"
fi

###############################################################################
# SSL 설정 (옵션)
###############################################################################
if [ -n "$DOMAIN_NAME" ]; then
    log_info "Step 11: SSL 설정..."
    apt install -y nginx >/dev/null
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$server_name\$request_uri; }
}
EOF
    systemctl restart nginx
    
    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email; then
        cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    location / { return 301 https://\$server_name\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN_NAME;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
        systemctl restart nginx
        log_success "SSL 적용 완료"
    fi
fi

echo ""
echo "============================================================"
log_success "OpenStack Bobcat (2023.2) 설치 완료!"
echo "============================================================"
echo "접속 정보: ~/openstack-credentials.txt"
cat ~/openstack-credentials.txt
echo "============================================================"