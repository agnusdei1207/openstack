#!/bin/bash

# v5 - OpenStack 2023.2 (Bobcat) 안정화 + MariaDB 충돌 해결 버전
# Ubuntu 22.04 + OpenStack Bobcat (가장 안정적인 조합)

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
# MariaDB 디버깅 함수 (유지)
###############################################################################
debug_mariadb() {
    echo ""
    echo "============================================================"
    log_info "MariaDB 상세 디버깅 정보"
    echo "============================================================"
    
    # 1. 컨테이너 상태
    log_info "[1] MariaDB 컨테이너 상태:"
    docker ps -a --filter "name=mariadb" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    
    # 2. 컨테이너 Inspect (네트워크/IP)
    if docker ps -a --format '{{.Names}}' | grep -q "^mariadb$"; then
        log_info "[2] 컨테이너 네트워크 정보:"
        docker inspect mariadb --format '{{range .NetworkSettings.Networks}}IP: {{.IPAddress}}, Gateway: {{.Gateway}}{{end}}' 2>/dev/null || echo "네트워크 정보 없음"
        echo ""
        
        # 3. 포트 바인딩 상세
        log_info "[3] 컨테이너 포트 바인딩:"
        docker inspect mariadb --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} -> {{(index $conf 0).HostPort}}{{"\n"}}{{end}}' 2>/dev/null || echo "포트 바인딩 정보 없음"
        echo ""
        
        # 4. 컨테이너 헬스체크
        log_info "[4] 컨테이너 Health 상태:"
        docker inspect mariadb --format '{{.State.Health.Status}}' 2>/dev/null || echo "헬스체크 미설정"
        echo ""
        
        # 5. 컨테이너 로그 (최근 100줄)
        log_info "[5] MariaDB 컨테이너 로그 (최근 100줄):"
        docker logs --tail 100 mariadb 2>&1
        echo ""
    else
        log_warn "MariaDB 컨테이너가 존재하지 않음"
    fi
    
    # 6. 호스트 포트 상태
    log_info "[6] 호스트 3306 포트 상태:"
    netstat -tulpn 2>/dev/null | grep -E "3306|mysql|mariadb" || ss -tulpn | grep -E "3306|mysql|mariadb" || echo "3306 포트 사용 없음"
    echo ""
    
    # 7. 관련 프로세스
    log_info "[7] MariaDB/MySQL 관련 프로세스:"
    ps aux | grep -E "mysql|mariadb" | grep -v grep || echo "관련 프로세스 없음"
    echo ""
    
    # 8. Kolla 설정 확인
    log_info "[8] Kolla MariaDB 설정:"
    grep -E "mariadb|database" /etc/kolla/globals.yml 2>/dev/null || echo "MariaDB 관련 설정 없음"
    echo ""
    
    # 9. Docker 네트워크 확인
    log_info "[9] Docker 네트워크:"
    docker network ls
    echo ""
    
    # 10. 디스크 공간
    log_info "[10] 디스크 공간:"
    df -h / /var/lib/docker 2>/dev/null | head -5
    echo ""
    
    # 11. 메모리 상태
    log_info "[11] 메모리 상태:"
    free -h
    echo ""
    
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
    echo "예시: $0 133.186.146.47"
    exit 1
fi

EXTERNAL_IP="$1"
DOMAIN_NAME="${2:-}"

# IP 형식 검증
if ! [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error_exit "올바른 IP 형식이 아닙니다: $EXTERNAL_IP"
fi

# 메모리 검증 (최소 8GB 권장)
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -lt 6 ]; then
    log_warn "메모리가 부족합니다 (${TOTAL_MEM}GB). 최소 8GB 권장"
    read -p "계속하시겠습니까? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 환경변수
export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_HOST_KEY_CHECKING=False
export PIP_DEFAULT_TIMEOUT=100

# SSH 세션 타임아웃 방지
unset TMOUT
export TMOUT=0
if [ -n "$SSH_TTY" ]; then
    log_info "SSH 세션 감지 - 타임아웃 방지 활성화"
    (while true; do sleep 300; echo -n ""; done) &
    KEEPALIVE_PID=$!
    trap "kill $KEEPALIVE_PID 2>/dev/null" EXIT
fi

###############################################################################
# 1. 필수 패키지 설치
###############################################################################
log_info "Step 1: 기초 패키지 설치 및 시간 동기화..."

for i in {1..3}; do
    if apt update -qq 2>/dev/null; then break; fi
    log_warn "APT 업데이트 재시도 ($i/3)..."
    sleep 5
done

apt install -y \
    python3-pip python3-venv python3-dev git curl chrony lvm2 \
    thin-provisioning-tools apt-transport-https ca-certificates gnupg \
    software-properties-common certbot net-tools lsof \
    2>/dev/null || log_warn "일부 패키지 설치 실패 (계속 진행)"

systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony >/dev/null 2>&1 || true

###############################################################################
# 2. 강화된 클린업 (포트 충돌 해결 - 유지)
###############################################################################
log_warn "Step 2: 기존 환경 완전 정리 (MariaDB 충돌 방지)..."

# Kolla 정리
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it >/dev/null 2>&1 || true
    deactivate >/dev/null 2>&1 || true
fi

# Docker 컨테이너 완전 정리
if command -v docker &>/dev/null; then
    log_info "Docker 컨테이너 정리 중..."
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker volume rm $(docker volume ls -q) >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker system prune -af --volumes >/dev/null 2>&1 || true
fi

# 3306 포트 강제 해제 (매우 중요)
log_info "MySQL/MariaDB 포트(3306) 정리 중..."
pkill -9 mysqld >/dev/null 2>&1 || true
pkill -9 mariadb >/dev/null 2>&1 || true
pkill -9 proxysql >/dev/null 2>&1 || true

# lsof로 3306 포트 점유 프로세스 강제 종료
if command -v lsof &>/dev/null; then
    PIDS=$(lsof -t -i:3306 2>/dev/null)
    if [ -n "$PIDS" ]; then
        log_warn "3306 포트 점유 프로세스 강제 종료: $PIDS"
        echo "$PIDS" | xargs -r kill -9
        sleep 2
    fi
fi

# 포트 해제 최종 확인
if netstat -tulpn 2>/dev/null | grep -q ":3306" || ss -tulpn 2>/dev/null | grep -q ":3306"; then
    log_error "3306 포트가 여전히 사용 중입니다."
    log_error "다음 명령어로 수동 확인이 필요합니다:"
    echo "  netstat -tulpn | grep 3306"
    echo "  lsof -i:3306"
    exit 1
fi
log_success "3306 포트 정리 완료"

# Cinder LVM 정리
lvremove -f cinder >/dev/null 2>&1 || true
vgremove -f cinder >/dev/null 2>&1 || true
for loop in /dev/loop*; do
    if losetup "$loop" 2>/dev/null | grep -q cinder_data; then
        pvremove -f "$loop" >/dev/null 2>&1 || true
        losetup -d "$loop" >/dev/null 2>&1 || true
    fi
done
rm -f /var/lib/cinder_data.img 2>/dev/null || true

# 디렉토리 정리
rm -rf /etc/kolla ~/kolla-venv ~/.ansible /var/log/kolla 2>/dev/null || true

###############################################################################
# 3. 스왑 메모리 설정 (16GB - 유지)
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
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
        log_success "스왑 설정 완료 (16GB)"
    fi
fi

###############################################################################
# 4. 시스템 설정 (유지)
###############################################################################
log_info "Step 4: 시스템 설정..."

# 호스트명
hostnamectl set-hostname openstack 2>/dev/null || true
sed -i '/openstack/d' /etc/hosts
echo "127.0.0.1 localhost openstack" >> /etc/hosts

# Cinder VG (20GB)
if ! vgs cinder &>/dev/null; then
    dd if=/dev/zero of=/var/lib/cinder_data.img bs=1M count=20480 status=none
    LOOP_DEV=$(losetup -f)
    losetup $LOOP_DEV /var/lib/cinder_data.img
    pvcreate $LOOP_DEV >/dev/null && vgcreate cinder $LOOP_DEV >/dev/null
    log_success "Cinder VG 생성 완료"
fi

# Cinder 자동 마운트
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

# 더미 네트워크
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

# Docker DNS 설정
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
log_success "Docker 설치 완료"

###############################################################################
# 6. Kolla-Ansible 설치 (2023.2 Bobcat 버전으로 변경)
###############################################################################
log_info "Step 6: Kolla-Ansible 설치 (OpenStack Bobcat 2023.2)..."

python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate

# Pip 업그레이드
pip install --upgrade pip setuptools wheel

# 기본 의존성 (Bobcat 호환 버전)
log_info "Python 의존성 설치 (Bobcat 호환)..."

# Ansible Core 2.15 사용 (2.16+ 보다 훨씬 안정적)
pip install 'ansible-core>=2.15,<2.16'

# Kolla-Ansible 17.x (Bobcat 릴리즈)
pip install 'kolla-ansible==17.2.0'

# 설정 복사
mkdir -p /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

###############################################################################
# 7. Ansible Galaxy 의존성 설치
###############################################################################
log_info "Step 7: Ansible Galaxy 의존성 설치..."

# 2023.2 Bobcat용 의존성 자동 설치
log_info "kolla-ansible install-deps 실행..."
if ! kolla-ansible install-deps 2>&1 | tee /tmp/kolla-install-deps.log; then
    log_warn "install-deps 실패, 필수 컬렉션 수동 설치 시도..."
    # Bobcat에서 주로 필요한 컬렉션
    ansible-galaxy collection install ansible.posix community.general ansible.utils --force
fi

###############################################################################
# 8. Kolla 설정 (2023.2 Bobcat 설정)
###############################################################################
log_info "Step 8: OpenStack 설정 구성 (Release: 2023.2)..."

MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
HOST_INTERNAL_IP=$(ip -4 addr show "$MAIN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

# 가상화 타입 확인
VIRT_TYPE="qemu"
if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1; then
    if [ -e /dev/kvm ]; then
        VIRT_TYPE="kvm"
        log_success "KVM 가상화 지원 확인"
    else
        log_warn "CPU는 가상화를 지원하나 /dev/kvm 없음 (QEMU 모드)"
    fi
else
    log_warn "하드웨어 가상화 미지원 (QEMU 모드)"
fi

cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"

# [변경] 안정적인 2023.2 (Bobcat) 릴리즈 사용
openstack_release: "2023.2"

# 네트워크
network_interface: "$MAIN_INTERFACE"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "$HOST_INTERNAL_IP"
kolla_external_vip_address: "$EXTERNAL_IP"

# DNS 설정
neutron_dns_nameservers: ["8.8.8.8", "8.8.4.4"]

# 서비스
enable_haproxy: "yes"
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

# Neutron
neutron_plugin_agent: "openvswitch"

# MariaDB 최적화
enable_mariadb_backup: "no"
mariadb_max_connections: "200"

# 로깅 최적화
openstack_logging_debug: "False"

# 불필요 서비스 비활성화
enable_ceilometer: "no"
enable_heat: "no"
enable_aodh: "no"
enable_gnocchi: "no"
EOF

# 패스워드 생성
kolla-genpwd

# 관리자 정보
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
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=60 -o ServerAliveCountMax=30
pipelining = True
EOF
export ANSIBLE_CONFIG=~/ansible.cfg

###############################################################################
# 10. OpenStack 배포
###############################################################################
log_info "Step 9: OpenStack 배포 시작 (OpenStack 2023.2 Bobcat)..."

# SSH 세션 보호 안내
if [ -z "${STY:-}" ] && [ -z "${TMUX:-}" ] && [ -n "$SSH_TTY" ]; then
    log_warn "SSH 세션입니다. 끊김 방지를 위해 screen 사용을 권장합니다."
    log_info "10초 후 자동 진행됩니다..."
    sleep 10
fi

# 배포 전 최종 포트 확인
if netstat -tulpn 2>/dev/null | grep -q ":3306" || ss -tulpn 2>/dev/null | grep -q ":3306"; then
    error_exit "배포 전 3306 포트가 사용 중입니다. 스크립트를 재실행해주세요."
fi

# Bootstrap
log_info "Bootstrap 실행..."
if ! kolla-ansible bootstrap-servers -i ~/all-in-one 2>&1 | tee /tmp/kolla-bootstrap.log; then
    log_error "Bootstrap 실패"
    tail -50 /tmp/kolla-bootstrap.log
    exit 1
fi
log_success "Bootstrap 완료"

# Prechecks
log_info "Prechecks 실행..."
if ! kolla-ansible prechecks -i ~/all-in-one 2>&1 | tee /tmp/kolla-prechecks.log; then
    log_error "Prechecks 실패"
    tail -50 /tmp/kolla-prechecks.log
    exit 1
fi
log_success "Prechecks 완료"

# Deploy (MariaDB 모니터링 포함)
log_info "Deploy 실행... (로그: /tmp/kolla-deploy.log)"
log_info "MariaDB 모니터링 시작..."

# MariaDB 모니터링 백그라운드 프로세스
(
    MONITOR_LOG="/tmp/mariadb-monitor.log"
    echo "=== MariaDB Monitor Start: $(date) ===" > "$MONITOR_LOG"
    while true; do
        echo "--- $(date) ---" >> "$MONITOR_LOG"
        docker ps -a --filter "name=mariadb" --format "{{.Names}}: {{.Status}}" >> "$MONITOR_LOG" 2>&1
        ss -tulpn 2>/dev/null | grep 3306 >> "$MONITOR_LOG" 2>&1 || echo "3306 Free" >> "$MONITOR_LOG"
        sleep 30
    done
) &
MARIADB_MONITOR_PID=$!

# Deploy 실행
if ! kolla-ansible deploy -i ~/all-in-one -vv 2>&1 | tee /tmp/kolla-deploy.log; then
    log_error "Deploy 실패"
    kill $MARIADB_MONITOR_PID 2>/dev/null || true
    echo ""
    
    # MariaDB 전체 디버깅 실행
    debug_mariadb
    
    log_info "=== 에러 로그 (최근 50줄) ==="
    grep -i "fatal\|failed\|error\|timeout" /tmp/kolla-deploy.log | tail -50
    exit 1
fi

# 모니터링 종료
kill $MARIADB_MONITOR_PID 2>/dev/null || true
log_success "Deploy 완료"

###############################################################################
# 11. 배포 검증
###############################################################################
log_info "Step 10: 배포 검증..."

# 컨테이너 시작 대기
sleep 15

# MariaDB 연결 대기
log_info "MariaDB 연결 확인..."
DB_PASSWORD=$(grep database_password /etc/kolla/passwords.yml | awk '{print $2}')
for i in {1..60}; do
    if docker exec mariadb mysql -uroot -p"$DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
        log_success "MariaDB 정상 작동 확인"
        break
    fi
    if [ $i -eq 60 ]; then
        log_error "MariaDB 연결 실패 (타임아웃)"
        debug_mariadb
        exit 1
    fi
    sleep 3
done

# Post-deploy
log_info "Post-deploy 실행..."
kolla-ansible post-deploy -i ~/all-in-one

# OpenStack 클라이언트 (Bobcat 호환 버전)
log_info "OpenStack 클라이언트 설치..."
pip install 'python-openstackclient==6.5.0' 'python-neutronclient==11.0.0' \
    'python-novaclient==18.5.0' 'python-glanceclient==4.5.0' 'python-cinderclient==9.4.0'

# OpenStack 연결 테스트
source /etc/kolla/admin-openrc.sh
if openstack endpoint list >/dev/null 2>&1; then
    log_success "OpenStack API 연결 성공"
else
    log_warn "OpenStack API 연결 실패 - 잠시 후 다시 시도하세요"
fi

###############################################################################
# 12. SSL 설정 (옵션)
###############################################################################
if [ -n "$DOMAIN_NAME" ]; then
    log_info "Step 11: SSL/HTTPS 설정..."
    apt install -y nginx
    
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
    location /.well-known/acme-challenge/ { root /var/www/html; }
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
        echo "0 0 * * * root certbot renew --quiet --deploy-hook 'systemctl reload nginx'" > /etc/cron.d/certbot-renew
        log_success "SSL 설정 완료"
    fi
fi

###############################################################################
# 완료 메시지
###############################################################################
echo ""
echo "============================================================"
log_success "OpenStack Bobcat (2023.2) 설치 완료!"
echo "============================================================"
echo ""
echo "접속 정보: ~/openstack-credentials.txt"
cat ~/openstack-credentials.txt
echo ""
[ -n "$DOMAIN_NAME" ] && echo "HTTPS URL: https://$DOMAIN_NAME"
echo ""
echo "실행 중인 컨테이너:"
docker ps --format "table {{.Names}}\t{{.Status}}" | head -20
echo ""
echo "유용한 명령어:"
echo "  - 전체 컨테이너 확인: docker ps"
echo "  - OpenStack 환경 로드: source /etc/kolla/admin-openrc.sh"
echo "============================================================"