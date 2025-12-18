#!/bin/bash

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

# 에러 핸들러
error_exit() {
    log_error "$1"
    log_error "스크립트 실행 실패: Line ${BASH_LINENO[0]}"
    exit 1
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
    echo ""
    exit 1
fi

EXTERNAL_IP="$1"
DOMAIN_NAME="${2:-}"

# IP 형식 검증
if ! [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error_exit "올바른 IP 형식이 아닙니다: $EXTERNAL_IP"
fi

# 도메인 검증
if [ -n "$DOMAIN_NAME" ]; then
    log_info "HTTPS 설정 활성화 (도메인: $DOMAIN_NAME)"
fi

# 환경변수 설정
export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_FORKS=4
export PIP_DEFAULT_TIMEOUT=100

###############################################################################
# 1. 필수 패키지 설치
###############################################################################
log_info "Step 0: 기초 패키지 설치 및 시간 동기화..."

for i in {1..3}; do
    if apt update -qq 2>/dev/null; then break; fi
    log_warn "APT 업데이트 재시도 ($i/3)..."
    sleep 5
done

# 패키지 설치 (실패해도 계속)
apt install -y \
    python3-pip python3-venv python3-dev git net-tools psmisc curl chrony lvm2 \
    thin-provisioning-tools apt-transport-https ca-certificates gnupg lsb-release \
    software-properties-common pkg-config libdbus-1-dev libglib2.0-dev certbot \
    2>/dev/null || log_warn "일부 패키지 설치 실패 (계속 진행)"

# 시간 동기화
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony >/dev/null 2>&1 || true
chronyc makestep >/dev/null 2>&1 || true

###############################################################################
# 2. 안전한 클린업
###############################################################################
log_warn "Step 1: 기존 환경 정리 (Kolla, Docker, Cinder, Loopback)..."

# Kolla 정리
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it >/dev/null 2>&1 || true
    deactivate >/dev/null 2>&1 || true
fi

# Docker 컨테이너 정리
if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker volume prune -f >/dev/null 2>&1 || true
fi

# Cinder LVM 및 Loop device 정리
lvremove -f cinder >/dev/null 2>&1 || true
vgchange -an cinder >/dev/null 2>&1 || true
vgremove -f cinder >/dev/null 2>&1 || true

for loop in /dev/loop*; do
    if losetup "$loop" 2>/dev/null | grep -q cinder_data; then
        pvremove -f "$loop" >/dev/null 2>&1 || true
        losetup -d "$loop" >/dev/null 2>&1 || true
    fi
done
rm -f /var/lib/cinder_data.img 2>/dev/null || true

# 포트 정리
for PORT in 3306 80 443 5000 8774 9292 9696 3260 6080; do
    fuser -k ${PORT}/tcp >/dev/null 2>&1 || true
done

# 디렉토리 정리
rm -rf /etc/kolla ~/kolla-venv ~/.ansible 2>/dev/null || true

###############################################################################
# 3. 스왑 메모리 설정 (16GB) - 간소화됨
###############################################################################
log_info "Step 2: 스왑 메모리 설정..."

if ! grep -q '/swapfile' /etc/fstab; then
    log_info "16GB 스왑 파일 생성 중..."
    swapoff -a >/dev/null 2>&1 || true
    rm -f /swapfile
    
    # 16GB 생성
    if fallocate -l 16G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=16384; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        
        # 커널 파라미터 튜닝
        sysctl -w vm.swappiness=10 >/dev/null
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
        
        log_success "스왑 설정 완료 (16GB)"
    else
        log_warn "스왑 생성 실패"
    fi
else
    log_info "스왑이 이미 설정되어 있습니다."
fi

###############################################################################
# 4. 시스템 설정
###############################################################################
log_info "Step 3: 시스템 설정 (Hostname, Cinder VG, Dummy Interface)..."

# 호스트명 설정
hostnamectl set-hostname openstack 2>/dev/null || true
sed -i '/openstack/d' /etc/hosts
echo "127.0.0.1 localhost openstack" >> /etc/hosts

# Cinder용 가상 디스크 생성 (20GB)
if ! vgs cinder &>/dev/null; then
    log_info "Cinder VG 생성 중..."
    dd if=/dev/zero of=/var/lib/cinder_data.img bs=1M count=20480 2>/dev/null
    LOOP_DEV=$(losetup -f)
    if [ -n "$LOOP_DEV" ]; then
        losetup $LOOP_DEV /var/lib/cinder_data.img
        pvcreate $LOOP_DEV >/dev/null && vgcreate cinder $LOOP_DEV >/dev/null
        log_success "Cinder VG 생성 완료"
    else
        error_exit "루프백 디바이스 부족"
    fi
fi

# Cinder 자동 마운트 서비스
cat > /etc/systemd/system/cinder-loop.service <<'EOF'
[Unit]
Description=Setup Cinder Loopback Device
After=local-fs.target
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -f /var/lib/cinder_data.img ]; then LOOP=$(/sbin/losetup -f); /sbin/losetup $LOOP /var/lib/cinder_data.img 2>/dev/null || true; /sbin/pvscan 2>/dev/null || true; /sbin/vgscan 2>/dev/null || true; /sbin/vgchange -ay cinder 2>/dev/null || true; fi'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable cinder-loop.service >/dev/null 2>&1 || true

# 더미 네트워크 인터페이스
if ! ip link show eth1 &>/dev/null; then
    log_info "eth1 더미 인터페이스 생성..."
    modprobe dummy
    ip link add eth1 type dummy
    ip link set eth1 up
    
    mkdir -p /etc/systemd/network
    echo -e "[NetDev]\nName=eth1\nKind=dummy" > /etc/systemd/network/10-dummy0.netdev
    echo -e "[Match]\nName=eth1\n\n[Network]" > /etc/systemd/network/20-dummy0.network
    systemctl restart systemd-networkd >/dev/null 2>&1 || true
fi

###############################################################################
# 5. Docker 설치 (DNS 설정 추가)
###############################################################################
log_info "Step 4: Docker 설치 및 DNS 설정..."

if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt update -qq
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# Docker 설정 (DNS 8.8.8.8 추가) - 중요!!
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "dns": ["8.8.8.8", "8.8.4.4"]
}
EOF

systemctl enable docker >/dev/null 2>&1
systemctl restart docker

###############################################################################
# 6. Kolla-Ansible 설치 (의존성 엄격 관리)
###############################################################################
log_info "Step 5: Kolla-Ansible 설치..."

python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate

# Pip 업그레이드
pip install 'pip>=23.0,<25.0' 'setuptools>=65.0,<70.0' 'wheel>=0.40,<0.45'

# 의존성 고정 설치
log_info "Python 의존성 설치..."
pip install 'resolvelib==1.0.1' 'Jinja2==3.1.2' 'MarkupSafe==2.1.3' 'PyYAML==6.0.1' 'dbus-python>=1.3.2'
pip install 'docker==6.1.3' 'requests==2.31.0' 'urllib3==2.0.7' 'paramiko==3.4.0' 'cryptography==41.0.7'

# Ansible & Kolla
log_info "Kolla-Ansible 설치..."
pip install 'ansible-core==2.16.12' 'kolla-ansible==19.1.0'

# 설정 복사
mkdir -p /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

###############################################################################
# 7. Kolla 설정 (DNS 설정 추가)
###############################################################################
log_info "Step 6: OpenStack 설정 구성..."

# 메인 인터페이스 확인
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

# globals.yml 생성 (DNS 설정 포함)
cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"

# 네트워크
network_interface: "$MAIN_INTERFACE"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "127.0.0.1"
kolla_external_vip_address: "$EXTERNAL_IP"

# DNS 설정 (중요: 컨테이너 및 VM 연결성 확보)
neutron_dns_nameservers: ["8.8.8.8", "8.8.4.4"]
dns_nameservers: ["8.8.8.8", "8.8.4.4"]

# 서비스 활성화
enable_haproxy: "no"
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder"

# 가상화 (KVM 확인)
nova_compute_virt_type: "$(grep -E 'vmx|svm' /proc/cpuinfo >/dev/null && echo 'kvm' || echo 'qemu')"

# Neutron
neutron_plugin_agent: "openvswitch"
neutron_bridge_name: "br-ex"
neutron_external_flat_networks: "physnet1"

# 최적화
enable_proxysql: "no"
enable_mariadb_sharding: "no"
mariadb_max_connections: "150"
rabbitmq_vm_memory_high_watermark: "0.4"
nova_max_concurrent_builds: "2"
mariadb_wsrep_slave_threads: "2"

# 타임아웃 설정 (MariaDB VIP 연결 문제 해결)
ansible_ssh_timeout: 180
docker_client_timeout: 900
haproxy_client_timeout: "10m"
haproxy_server_timeout: "10m"
nova_rpc_response_timeout: 300

# MariaDB 추가 설정 (VIP 연결 문제 해결)
mariadb_interface: "$MAIN_INTERFACE"
mariadb_backups_cleanup: "2"

# 모니터링 비활성화
enable_ceilometer: "no"
enable_gnocchi: "no"
enable_grafana: "no"
enable_prometheus: "no"
enable_prometheus_openstack_exporter: "no"
enable_alertmanager: "no"
enable_cloudkitty: "no"
enable_heat: "no"

openstack_logging_debug: "False"
EOF

# 패스워드 생성
kolla-genpwd

# 관리자 계정 정보 저장
ADMIN_PASSWORD=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
cat > ~/openstack-credentials.txt <<EOF
URL: http://$EXTERNAL_IP
Username: admin
Password: $ADMIN_PASSWORD
EOF
chmod 600 ~/openstack-credentials.txt

###############################################################################
# 8. Ansible 최적화
###############################################################################
cat > ~/ansible.cfg <<EOF
[defaults]
host_key_checking = False
pipelining = True
forks = 4
timeout = 120
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600
retry_files_enabled = False
[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True
EOF
export ANSIBLE_CONFIG=~/ansible.cfg

###############################################################################
# 9. OpenStack 배포 (강력한 의존성 관리)
###############################################################################
log_info "Step 7: OpenStack 배포 시작 (약 30~40분)..."

# Ansible Galaxy 컬렉션 설치 (모든 필수 컬렉션 명시적 설치)
log_info "Ansible Galaxy 컬렉션 설치..."

# Kolla-Ansible requirements.yml 먼저 설치
if [ -f ~/kolla-venv/share/kolla-ansible/requirements.yml ]; then
    ansible-galaxy collection install -r ~/kolla-venv/share/kolla-ansible/requirements.yml --force || true
fi

# 모든 필수 컬렉션 명시적 설치 (누락 방지)
log_info "필수 Ansible 컬렉션 설치 중..."
COLLECTIONS=(
    # Ansible 공식 컬렉션
    "ansible.posix"           # mount, sysctl, synchronize, authorized_key 등
    "ansible.utils"           # ipaddr 필터, validate 등
    "ansible.netcommon"       # 네트워크 공통 모듈
    
    # Community 컬렉션
    "community.general"       # ufw, modprobe, timezone, pip 등 필수!
    "community.docker"        # docker_container, docker_image 등
    "community.crypto"        # openssl 인증서 관련
    "community.mysql"         # MariaDB/MySQL 관련
    "community.rabbitmq"      # RabbitMQ 관련
    
    # OpenStack Kolla 컬렉션
    "openstack.kolla"         # Kolla 전용 모듈
)

for collection in "${COLLECTIONS[@]}"; do
    log_info "  Installing $collection..."
    MAX_RETRIES=10
    RETRY_COUNT=0
    while true; do
        if ansible-galaxy collection install "$collection" --force --pre 2>/dev/null; then
            log_success "  $collection 설치 완료"
            break
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
                log_error "  $collection 설치 실패 (${MAX_RETRIES}회 시도) - 스크립트 종료"
                exit 1
            fi
            log_warn "  $collection 설치 실패 - 재시도 중... (${RETRY_COUNT}/${MAX_RETRIES})"
            sleep 5
        fi
    done
done

log_success "Ansible 컬렉션 설치 완료"

###############################################################################
# 디버깅 함수 정의
###############################################################################
debug_docker_status() {
    log_info "=== Docker 컨테이너 상태 ==="
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20
    echo ""
}

debug_mariadb_status() {
    log_info "=== MariaDB 디버깅 ==="
    
    # MariaDB 컨테이너 확인
    if docker ps | grep -q mariadb; then
        log_success "MariaDB 컨테이너 실행 중"
        
        # MariaDB 로그 확인
        log_info "MariaDB 최근 로그:"
        docker logs mariadb --tail 20 2>&1 | tail -10
        echo ""
        
        # MariaDB 포트 확인
        log_info "MariaDB 포트 바인딩:"
        docker port mariadb 2>/dev/null || echo "포트 정보 없음"
        echo ""
        
        # MariaDB 내부 연결 테스트
        log_info "MariaDB 내부 연결 테스트:"
        docker exec mariadb mysql -h 127.0.0.1 -P 3306 -u root -e "SELECT 1;" 2>&1 || log_warn "내부 연결 실패"
        echo ""
        
        # MariaDB 소켓 확인
        log_info "MariaDB 리스닝 상태:"
        docker exec mariadb ss -tlnp 2>/dev/null | grep 3306 || echo "3306 포트 리스닝 안됨"
        echo ""
    else
        log_warn "MariaDB 컨테이너가 실행되고 있지 않음"
    fi
}

debug_network_status() {
    log_info "=== 네트워크 상태 ==="
    
    # 호스트 127.0.0.1:3306 확인
    log_info "호스트 127.0.0.1:3306 확인:"
    ss -tlnp | grep 3306 || echo "3306 리스닝 없음"
    echo ""
    
    # Docker 네트워크 확인
    log_info "Docker 네트워크:"
    docker network ls
    echo ""
    
    # kolla 네트워크 상세
    log_info "Kolla 네트워크 상세:"
    docker network inspect kolla_net 2>/dev/null | grep -A5 "IPAM" || echo "kolla_net 없음"
    echo ""
}

debug_all() {
    echo ""
    echo "============================================================"
    log_warn "디버깅 정보 수집 중..."
    echo "============================================================"
    debug_docker_status
    debug_mariadb_status
    debug_network_status
    echo "============================================================"
    echo ""
}

# Bootstrap
log_info "Bootstrap 실행..."
if ! kolla-ansible bootstrap-servers -i ~/all-in-one -vvv 2>&1 | tee /tmp/kolla-bootstrap.log; then
    log_error "Bootstrap 실패"
    debug_all
    log_error "로그 파일: /tmp/kolla-bootstrap.log"
    exit 1
fi
log_success "Bootstrap 완료"

# Prechecks
log_info "Prechecks 실행..."
if ! kolla-ansible prechecks -i ~/all-in-one -vv 2>&1 | tee /tmp/kolla-prechecks.log; then
    log_error "Prechecks 실패"
    debug_all
    log_error "로그 파일: /tmp/kolla-prechecks.log"
    exit 1
fi
log_success "Prechecks 완료"

# Deploy
log_info "Deploy 실행... (오래 걸림)"
log_info "상세 로그: /tmp/kolla-deploy.log"
if ! kolla-ansible deploy -i ~/all-in-one -vv 2>&1 | tee /tmp/kolla-deploy.log; then
    log_error "Deploy 실패"
    echo ""
    debug_all
    
    # 추가 MariaDB 디버깅
    log_info "=== MariaDB 상세 진단 ==="
    log_info "MariaDB 전체 로그:"
    docker logs mariadb 2>&1 | tail -50
    echo ""
    
    log_info "MariaDB 설정 확인:"
    docker exec mariadb cat /etc/mysql/mariadb.cnf 2>/dev/null | head -30 || echo "설정 파일 접근 불가"
    echo ""
    
    log_info "MariaDB 프로세스 확인:"
    docker exec mariadb ps aux 2>/dev/null || echo "프로세스 확인 불가"
    echo ""
    
    log_error "로그 파일: /tmp/kolla-deploy.log"
    log_info "MariaDB 로그 확인: docker logs mariadb"
    log_info "전체 로그 확인: tail -100 /tmp/kolla-deploy.log"
    exit 1
fi
log_success "Deploy 완료"

# Post-deploy
log_info "Post-deploy 실행..."
kolla-ansible post-deploy -i ~/all-in-one

# OpenStack 클라이언트 설치
pip install 'python-openstackclient==7.1.0' 'python-neutronclient==11.3.0' 'python-novaclient==18.6.0' 'python-glanceclient==4.6.0' 'python-cinderclient==9.5.0'

###############################################################################
# 10. SSL 설정 (Let's Encrypt)
###############################################################################
if [ -n "$DOMAIN_NAME" ]; then
    log_info "Step 9: SSL/HTTPS 설정..."
    apt install -y nginx
    
    # 임시 설정
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$server_name\$request_uri; }
}
EOF
    systemctl restart nginx
    
    # 인증서 발급
    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email; then
        log_success "SSL 인증서 발급 성공"
        
        # HTTPS 설정
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
        systemctl restart nginx
        
        # 자동 갱신
        echo "0 0 * * * root certbot renew --quiet --deploy-hook 'systemctl reload nginx'" > /etc/cron.d/certbot-renew
    else
        log_warn "SSL 발급 실패"
    fi
fi

log_success "설치 완료! 자격증명: ~/openstack-credentials.txt"
