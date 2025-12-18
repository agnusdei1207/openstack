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
    echo "예시: $0 133.186.146.47 openstack.example.com"
    echo ""
    echo "도메인을 입력하면 Let's Encrypt SSL 인증서가 자동으로 설정됩니다."
    exit 1
fi

EXTERNAL_IP="$1"
DOMAIN_NAME="${2:-}"

# 도메인 입력 시 유효성 검증
if [ -n "$DOMAIN_NAME" ]; then
    if ! [[ $DOMAIN_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        error_exit "올바른 도메인 형식이 아닙니다: $DOMAIN_NAME"
    fi
    log_info "HTTPS 설정 활성화 (도메인: $DOMAIN_NAME)"
fi

# IP 형식 검증
if ! [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error_exit "올바른 IP 형식이 아닙니다: $EXTERNAL_IP"
fi

# 메모리 확인
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -lt 14 ]; then
    error_exit "메모리 부족: 최소 14GB 필요 (현재: ${TOTAL_MEM}GB)"
fi

# 디스크 공간 확인
AVAIL_DISK=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [ "$AVAIL_DISK" -lt 50 ]; then
    error_exit "디스크 공간 부족: 최소 50GB 필요 (현재: ${AVAIL_DISK}GB)"
fi

log_success "사전 검증 완료 (메모리: ${TOTAL_MEM}GB, 디스크: ${AVAIL_DISK}GB)"

# 환경변수 설정
export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_FORKS=4
export PIP_DEFAULT_TIMEOUT=100

###############################################################################
# 1. 필수 패키지 설치
###############################################################################
log_info "Step 0: 기초 패키지 설치 및 시간 동기화..."

# APT 업데이트 (재시도 로직)
for i in {1..3}; do
    if apt-get update -qq 2>/dev/null; then
        break
    fi
    log_warn "APT 업데이트 재시도 ($i/3)..."
    sleep 5
done

# 패키지 설치 (실패해도 계속)
apt-get install -y \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    net-tools \
    psmisc \
    curl \
    chrony \
    lvm2 \
    thin-provisioning-tools \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    pkg-config \
    libdbus-1-dev \
    libglib2.0-dev \
    certbot \
    2>/dev/null || log_warn "일부 패키지 설치 실패 (계속 진행)"

# 시간 동기화
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony >/dev/null 2>&1 || true
sleep 2
chronyc makestep >/dev/null 2>&1 || true

log_success "기초 패키지 설치 완료"

###############################################################################
# 2. 안전한 클린업
###############################################################################
log_warn "Step 1: 기존 환경 정리 중..."

# Kolla 정리
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    log_info "기존 Kolla 환경 제거 중..."
    if [ -f ~/kolla-venv/bin/activate ]; then
        source ~/kolla-venv/bin/activate 2>/dev/null || true
        kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it >/dev/null 2>&1 || true
        deactivate >/dev/null 2>&1 || true
    fi
fi

# Docker 컨테이너 정리
if command -v docker &>/dev/null; then
    log_info "Docker 컨테이너 정리 중..."
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker volume prune -f >/dev/null 2>&1 || true
    docker system prune -af >/dev/null 2>&1 || true
fi

# Cinder LVM 정리
log_info "Cinder LVM 정리 중..."
lvremove -f cinder >/dev/null 2>&1 || true
vgchange -an cinder >/dev/null 2>&1 || true
vgremove -f cinder >/dev/null 2>&1 || true

# 모든 루프백 디바이스 확인 및 정리
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
rm -rf /etc/kolla 2>/dev/null || true
rm -rf ~/kolla-venv 2>/dev/null || true
rm -rf ~/.ansible 2>/dev/null || true

# systemd 서비스 정리
systemctl stop cinder-loop.service >/dev/null 2>&1 || true
systemctl disable cinder-loop.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/cinder-loop.service 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true

log_success "클린업 완료"

###############################################################################
# 3. 스왑 메모리 설정 (16GB)
###############################################################################
log_info "Step 2: 스왑 메모리 설정 (16GB)..."

# 기존 스왑 제거
swapoff -a >/dev/null 2>&1 || true
sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

# 새로운 스왑 생성
log_info "16GB 스왑 파일 생성 중... (약 30초 소요)"
if dd if=/dev/zero of=/swapfile bs=1M count=16384 2>/dev/null; then
    chmod 600 /swapfile
    if mkswap /swapfile >/dev/null 2>&1; then
        if swapon /swapfile 2>/dev/null; then
            # 영구 설정
            if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            
            # 스왑 사용률 최적화
            sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
            sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
            
            if ! grep -q 'vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
                echo "vm.swappiness=10" >> /etc/sysctl.conf
                echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
            fi
            
            SWAP_SIZE=$(free -h | awk '/^Swap:/{print $2}')
            log_success "스왑 메모리 설정 완료 (크기: $SWAP_SIZE)"
        else
            log_warn "스왑 활성화 실패 - 기존 스왑 사용"
        fi
    else
        log_warn "스왑 생성 실패 - 기존 스왑 사용"
    fi
else
    log_warn "스왑 파일 생성 실패 - 기존 스왑 사용"
fi

###############################################################################
# 4. 시스템 설정
###############################################################################
log_info "Step 3: 시스템 설정..."

# 호스트명 설정
hostnamectl set-hostname openstack 2>/dev/null || true
sed -i '/openstack/d' /etc/hosts 2>/dev/null || true
echo "127.0.0.1 localhost openstack" >> /etc/hosts
echo "::1 localhost openstack" >> /etc/hosts

# Cinder용 가상 디스크 생성 (20GB)
if ! vgs cinder &>/dev/null; then
    log_info "Cinder 볼륨 그룹 생성 중... (약 1분 소요)"
    
    # 20GB 파일 생성
    if dd if=/dev/zero of=/var/lib/cinder_data.img bs=1M count=20480 2>/dev/null; then
        # 사용 가능한 루프백 디바이스 찾기
        LOOP_DEV=$(losetup -f 2>/dev/null)
        
        if [ -z "$LOOP_DEV" ]; then
            error_exit "사용 가능한 루프백 디바이스가 없습니다"
        fi
        
        if losetup $LOOP_DEV /var/lib/cinder_data.img 2>/dev/null; then
            # PV 및 VG 생성
            if pvcreate $LOOP_DEV 2>/dev/null && vgcreate cinder $LOOP_DEV 2>/dev/null; then
                log_success "Cinder VG 생성 완료 (디바이스: $LOOP_DEV)"
            else
                error_exit "Cinder VG 생성 실패"
            fi
        else
            error_exit "루프백 디바이스 연결 실패"
        fi
    else
        error_exit "Cinder 데이터 파일 생성 실패"
    fi
else
    log_info "Cinder VG가 이미 존재합니다"
fi

# 재부팅 시 자동 마운트 서비스
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

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable cinder-loop.service >/dev/null 2>&1 || true

log_success "Cinder 자동 마운트 서비스 등록 완료"

# 더미 네트워크 인터페이스 생성
if ! ip link show eth1 &>/dev/null; then
    log_info "외부망 더미 인터페이스 생성..."
    
    modprobe dummy >/dev/null 2>&1 || true
    
    if ip link add eth1 type dummy 2>/dev/null && ip link set eth1 up 2>/dev/null; then
        # 영구 설정
        mkdir -p /etc/systemd/network
        
        cat > /etc/systemd/network/10-dummy0.netdev <<EOF
[NetDev]
Name=eth1
Kind=dummy
EOF
        
        cat > /etc/systemd/network/20-dummy0.network <<EOF
[Match]
Name=eth1

[Network]
EOF
        
        systemctl enable systemd-networkd >/dev/null 2>&1 || true
        systemctl restart systemd-networkd >/dev/null 2>&1 || true
        
        log_success "더미 인터페이스 생성 완료"
    else
        log_warn "더미 인터페이스 생성 실패 - 계속 진행"
    fi
else
    log_info "더미 인터페이스가 이미 존재합니다"
fi

###############################################################################
# 5. Docker 설치
###############################################################################
if ! command -v docker &>/dev/null; then
    log_info "Step 4: Docker 설치 중..."
    
    # Docker 공식 GPG 키 및 저장소 추가
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null || true
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq 2>/dev/null || true
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || error_exit "Docker 설치 실패"
    
    # Docker 최적화
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true
}
EOF
    
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl restart docker || error_exit "Docker 시작 실패"
    
    # Docker 정상 작동 확인
    sleep 3
    if docker ps >/dev/null 2>&1; then
        log_success "Docker 설치 완료"
    else
        error_exit "Docker가 정상 작동하지 않습니다"
    fi
else
    log_info "Docker 이미 설치됨 (버전: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))"
    # Docker 재시작
    systemctl restart docker >/dev/null 2>&1 || true
    sleep 3
fi

###############################################################################
# 6. Kolla-Ansible 설치
###############################################################################
log_info "Step 5: Kolla-Ansible 설치 중..."

# Python 가상환경 생성
if ! python3 -m venv ~/kolla-venv 2>/dev/null; then
    error_exit "Python 가상환경 생성 실패"
fi

source ~/kolla-venv/bin/activate || error_exit "가상환경 활성화 실패"

# pip 버전 고정 업그레이드
pip install 'pip>=23.0,<25.0' 'setuptools>=65.0,<70.0' 'wheel>=0.40,<0.45' >/dev/null 2>&1 || log_warn "pip 업그레이드 실패 - 계속 진행"

# ============================================================================
# 의존성 버전 고정 (OpenStack 2024.2 + Kolla-Ansible 19.1.0 호환)
# ============================================================================
log_info "Python 의존성 버전 고정 중..."

# Core 의존성 (순서 중요)
pip install 'resolvelib==1.0.1' >/dev/null 2>&1 || log_warn "resolvelib 설치 실패"
pip install 'Jinja2==3.1.2' >/dev/null 2>&1 || log_warn "Jinja2 설치 실패"
pip install 'MarkupSafe==2.1.3' >/dev/null 2>&1 || log_warn "MarkupSafe 설치 실패"
pip install 'PyYAML==6.0.1' >/dev/null 2>&1 || log_warn "PyYAML 설치 실패"
pip install 'dbus-python>=1.3.2' >/dev/null 2>&1 || log_warn "dbus-python 설치 실패"

# Ansible 관련 의존성
pip install 'packaging==23.2' >/dev/null 2>&1 || log_warn "packaging 설치 실패"
pip install 'cryptography==41.0.7' >/dev/null 2>&1 || log_warn "cryptography 설치 실패"
pip install 'cffi==1.16.0' >/dev/null 2>&1 || log_warn "cffi 설치 실패"
pip install 'paramiko==3.4.0' >/dev/null 2>&1 || log_warn "paramiko 설치 실패"

# Docker SDK
pip install 'docker==6.1.3' >/dev/null 2>&1 || log_warn "docker SDK 설치 실패"
pip install 'requests==2.31.0' >/dev/null 2>&1 || log_warn "requests 설치 실패"
pip install 'urllib3==2.0.7' >/dev/null 2>&1 || log_warn "urllib3 설치 실패"

# ============================================================================
# Ansible-Core 및 Kolla-Ansible 설치
# ============================================================================
log_info "Kolla-Ansible 패키지 설치 중... (약 2분 소요)"

# ansible-core 버전 고정 설치
for i in {1..3}; do
    if pip install 'ansible-core==2.16.12' >/dev/null 2>&1; then
        log_success "ansible-core 2.16.12 설치 완료"
        break
    fi
    log_warn "ansible-core 설치 재시도 ($i/3)..."
    sleep 5
done

# kolla-ansible 버전 고정 설치
for i in {1..3}; do
    if pip install 'kolla-ansible==19.1.0' >/dev/null 2>&1; then
        log_success "kolla-ansible 19.1.0 설치 완료"
        break
    fi
    log_warn "kolla-ansible 설치 재시도 ($i/3)..."
    sleep 5
done

# 의존성 무결성 확인
log_info "Python 의존성 무결성 확인 중..."
if pip check 2>&1 | head -10; then
    log_success "의존성 검증 완료"
else
    log_warn "일부 의존성 경고 발생 (무시 가능)"
fi

# 설치 확인
if ! command -v kolla-ansible &>/dev/null; then
    error_exit "Kolla-Ansible 설치 실패"
fi

# 설정 파일 복사
mkdir -p /etc/kolla
if [ -d ~/kolla-venv/share/kolla-ansible/etc_examples/kolla ]; then
    cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/ || error_exit "Kolla 설정 파일 복사 실패"
else
    error_exit "Kolla 설정 파일을 찾을 수 없습니다"
fi

if [ -f ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ]; then
    cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/ || error_exit "Inventory 파일 복사 실패"
else
    error_exit "Inventory 파일을 찾을 수 없습니다"
fi

log_success "Kolla-Ansible 설치 완료"

###############################################################################
# 7. Kolla 설정
###############################################################################
log_info "Step 6: OpenStack 설정 구성 중..."

# 가상화 타입 확인
if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1; then
    NOVA_VIRT_TYPE='kvm'
    log_info "KVM 가상화 지원 감지"
else
    NOVA_VIRT_TYPE='qemu'
    log_warn "KVM 미지원: QEMU 모드 사용"
fi

# 메인 네트워크 인터페이스 감지
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$MAIN_INTERFACE" ]; then
    error_exit "네트워크 인터페이스를 찾을 수 없습니다"
fi
log_info "메인 인터페이스: $MAIN_INTERFACE"

# globals.yml 생성
cat > /etc/kolla/globals.yml <<EOF
---
# 기본 설정
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"

# 네트워크 설정
network_interface: "$MAIN_INTERFACE"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "127.0.0.1"
kolla_external_vip_address: "$EXTERNAL_IP"

# HAProxy 비활성화 (단일 노드)
enable_haproxy: "no"

# 코어 서비스
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"

# Cinder 볼륨 서비스
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder"

# Nova 가상화 설정
nova_compute_virt_type: "$NOVA_VIRT_TYPE"

# Neutron 설정
neutron_plugin_agent: "openvswitch"
neutron_bridge_name: "br-ex"
neutron_external_flat_networks: "physnet1"

# 단일 노드 최적화
enable_proxysql: "no"
enable_mariadb_sharding: "no"
mariadb_max_connections: "150"
rabbitmq_vm_memory_high_watermark: "0.4"
nova_max_concurrent_builds: "2"
mariadb_wsrep_slave_threads: "2"

# 타임아웃 설정
ansible_ssh_timeout: 180
docker_client_timeout: 900
haproxy_client_timeout: "10m"
haproxy_server_timeout: "10m"
nova_rpc_response_timeout: 300

# 모니터링 서비스 비활성화 (리소스 절약)
enable_ceilometer: "no"
enable_gnocchi: "no"
enable_grafana: "no"
enable_prometheus: "no"
enable_prometheus_openstack_exporter: "no"
enable_alertmanager: "no"
enable_cloudkitty: "no"
enable_heat: "no"

# 로그 레벨
openstack_logging_debug: "False"
EOF

# 패스워드 생성
if ! kolla-genpwd 2>/dev/null; then
    error_exit "Kolla 패스워드 생성 실패"
fi

# Admin 패스워드 저장
ADMIN_PASSWORD=$(grep keystone_admin_password /etc/kolla/passwords.yml 2>/dev/null | awk '{print $2}')
if [ -z "$ADMIN_PASSWORD" ]; then
    error_exit "Admin 패스워드를 찾을 수 없습니다"
fi

cat > ~/openstack-credentials.txt <<EOF
# OpenStack 관리자 계정 정보
URL: http://$EXTERNAL_IP
$([ -n "$DOMAIN_NAME" ] && echo "HTTPS URL: https://$DOMAIN_NAME")
Username: admin
Password: $ADMIN_PASSWORD
Project: admin
Domain: default
EOF

chmod 600 ~/openstack-credentials.txt

log_success "OpenStack 설정 완료"

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
# 9. OpenStack 배포
###############################################################################
log_info "Step 7: OpenStack 배포 시작..."
echo "⏱️  예상 소요 시간: 30~40분"
echo ""

# 의존성 설치
log_info "[1/4] 의존성 설치 중..."
kolla-ansible install-deps >/dev/null 2>&1 || log_warn "의존성 설치 경고 무시"

# Ansible Galaxy 컬렉션 강제 재설치 (ansible.posix 등 누락 방지)
log_info "[1.5/4] Ansible Galaxy 컬렉션 강제 재설치 중..."
if [ -f ~/kolla-venv/share/kolla-ansible/requirements.yml ]; then
    for i in {1..3}; do
        if ansible-galaxy collection install -r ~/kolla-venv/share/kolla-ansible/requirements.yml --force 2>&1 | tee /tmp/ansible-galaxy.log | grep -v "^$"; then
            log_success "Ansible Galaxy 컬렉션 설치 완료"
            break
        fi
        log_warn "Ansible Galaxy 컬렉션 설치 재시도 ($i/3)..."
        sleep 5
    done
else
    log_warn "requirements.yml 파일을 찾을 수 없습니다 - 수동 설치 시도"
fi

# ansible.utils 컬렉션 필수 설치 (ipaddr 필터 필요)
log_info "필수 Ansible 컬렉션 추가 설치 중..."
ansible-galaxy collection install ansible.posix ansible.netcommon ansible.utils community.docker --force >/dev/null 2>&1 || log_warn "추가 컬렉션 설치 경고"

# Bootstrap
log_info "[2/4] Bootstrap 실행 중... (약 5분)"
if ! kolla-ansible bootstrap-servers -i ~/all-in-one 2>&1 | tee /tmp/kolla-bootstrap.log | grep -v "^$"; then
    log_error "Bootstrap 실패 - 로그 확인: /tmp/kolla-bootstrap.log"
    exit 1
fi

# Prechecks
log_info "[3/4] Prechecks 실행 중... (약 3분)"
if ! kolla-ansible prechecks -i ~/all-in-one 2>&1 | tee /tmp/kolla-prechecks.log | grep -v "^$"; then
    log_error "Prechecks 실패 - 로그 확인: /tmp/kolla-prechecks.log"
    exit 1
fi

# Deploy
log_info "[4/4] Deploy 실행 중... (약 25분, Cinder 포함)"
log_warn "이 단계는 시간이 오래 걸립니다. 기다려 주세요..."
if ! kolla-ansible deploy -i ~/all-in-one 2>&1 | tee /tmp/kolla-deploy.log | grep -v "^$"; then
    log_error "배포 실패 - 로그 확인: /tmp/kolla-deploy.log"
    log_info "Docker 컨테이너 상태: docker ps -a"
    exit 1
fi

# Post-deploy
log_info "Post-deploy 설정 중..."
if ! kolla-ansible post-deploy -i ~/all-in-one 2>&1 | tee /tmp/kolla-postdeploy.log | grep -v "^$"; then
    log_warn "Post-deploy 경고 발생 - 계속 진행"
fi

# OpenStack 클라이언트 설치 (버전 고정)
log_info "OpenStack 클라이언트 설치 중..."
pip install \
    'python-openstackclient==7.1.0' \
    'python-cinderclient==9.5.0' \
    'python-novaclient==18.6.0' \
    'python-glanceclient==4.6.0' \
    'python-neutronclient==11.3.0' \
    'python-keystoneclient==5.4.0' \
    'osc-lib==3.0.1' \
    'keystoneauth1==5.6.0' \
    >/dev/null 2>&1 || log_warn "클라이언트 설치 경고 무시"

log_success "OpenStack 배포 완료!"

###############################################################################
# 10. 환경 검증
###############################################################################
log_info "Step 8: 환경 검증 중..."

if [ -f /etc/kolla/admin-openrc.sh ]; then
    source /etc/kolla/admin-openrc.sh 2>/dev/null || true
    
    # 서비스 상태 확인
    sleep 10
    
    log_info "OpenStack 서비스 확인 중..."
    if openstack endpoint list >/dev/null 2>&1; then
        log_success "Keystone 서비스 정상"
    else
        log_warn "Keystone 초기화 중... 잠시 후 다시 시도하세요"
    fi
else
    log_warn "admin-openrc.sh 파일을 찾을 수 없습니다"
fi

###############################################################################
# 11. SSL/HTTPS 설정 (Let's Encrypt)
###############################################################################
if [ -n "$DOMAIN_NAME" ]; then
    log_info "Step 9: SSL/HTTPS 설정 중 (Let's Encrypt)..."
    
    # Nginx 설치 (리버스 프록시용)
    apt-get install -y nginx >/dev/null 2>&1 || log_warn "Nginx 설치 경고"
    
    # Nginx 기본 설정 백업
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi
    
    # 일시적으로 HTTP 서버 설정 (인증서 발급용)
    cat > /etc/nginx/sites-available/openstack-temp <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/openstack-temp /etc/nginx/sites-enabled/
    systemctl restart nginx >/dev/null 2>&1 || log_warn "Nginx 재시작 경고"
    
    # Let's Encrypt 인증서 발급
    log_info "Let's Encrypt SSL 인증서 발급 중..."
    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email 2>&1 | tee /tmp/certbot.log; then
        log_success "SSL 인증서 발급 완료"
        SSL_ENABLED=true
    else
        log_warn "SSL 인증서 발급 실패 - HTTP로 계속 진행"
        log_warn "수동으로 발급: certbot certonly --standalone -d $DOMAIN_NAME"
        SSL_ENABLED=false
    fi
    
    if [ "$SSL_ENABLED" = true ]; then
        # HTTPS Nginx 설정
        cat > /etc/nginx/sites-available/openstack <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN_NAME;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    
    # SSL 보안 설정
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # HSTS
    add_header Strict-Transport-Security "max-age=63072000" always;
    
    # Horizon (OpenStack Dashboard) 프록시
    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        
        # WebSocket 지원 (VNC 콘솔 등)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
        
        # 임시 설정 제거 및 새 설정 적용
        rm -f /etc/nginx/sites-enabled/openstack-temp
        ln -sf /etc/nginx/sites-available/openstack /etc/nginx/sites-enabled/
        
        # Nginx 설정 검증 및 재시작
        if nginx -t 2>/dev/null; then
            systemctl restart nginx
            log_success "Nginx HTTPS 프록시 설정 완료"
        else
            log_warn "Nginx 설정 오류 - 수동 확인 필요"
        fi
        
        # 매일 자정 인증서 갱신 cron 작업 설정
        log_info "인증서 자동 갱신 cron 작업 설정 중..."
        
        # 인증서 갱신 스크립트 생성
        cat > /etc/cron.daily/certbot-renew <<'RENEW_EOF'
#!/bin/bash
# Let's Encrypt 인증서 자동 갱신 스크립트
# 매일 자정에 실행

LOGFILE="/var/log/certbot-renew.log"
echo "$(date): 인증서 갱신 시도 시작" >> $LOGFILE

/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx" >> $LOGFILE 2>&1

if [ $? -eq 0 ]; then
    echo "$(date): 인증서 갱신 완료" >> $LOGFILE
else
    echo "$(date): 인증서 갱신 실패 또는 갱신 불필요" >> $LOGFILE
fi
RENEW_EOF
        
        chmod +x /etc/cron.daily/certbot-renew
        
        # 정확히 자정에 실행되도록 crontab 설정
        (crontab -l 2>/dev/null | grep -v certbot; echo "0 0 * * * /etc/cron.daily/certbot-renew") | crontab -
        
        log_success "인증서 자동 갱신 설정 완료 (매일 자정)"
        
        HORIZON_URL="https://$DOMAIN_NAME"
    else
        HORIZON_URL="http://$EXTERNAL_IP"
    fi
else
    HORIZON_URL="http://$EXTERNAL_IP"
fi

###############################################################################
# 12. 완료 메시지
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    🎉 OpenStack AIO 설치 완료! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}📌 접속 정보${NC}"
echo -e "   Horizon URL: ${YELLOW}$HORIZON_URL${NC}"
if [ -n "$DOMAIN_NAME" ] && [ "$SSL_ENABLED" = true ]; then
    echo -e "   (HTTP -> HTTPS 자동 리다이렉트)"
fi
echo -e "   Username: ${YELLOW}admin${NC}"
echo -e "   Password: ${YELLOW}$ADMIN_PASSWORD${NC}"
echo ""
if [ -n "$DOMAIN_NAME" ] && [ "$SSL_ENABLED" = true ]; then
    echo -e "${BLUE}📌 SSL 인증서 (Let's Encrypt)${NC}"
    echo -e "   도메인: ${YELLOW}$DOMAIN_NAME${NC}"
    echo -e "   인증서: ${YELLOW}/etc/letsencrypt/live/$DOMAIN_NAME/${NC}"
    echo -e "   자동 갱신: ${YELLOW}매일 자정 (0시 0분)${NC}"
    echo -e "   갱신 로그: ${YELLOW}/var/log/certbot-renew.log${NC}"
    echo -e "   수동 갱신: ${YELLOW}certbot renew${NC}"
    echo ""
fi
echo -e "${BLUE}📌 Cinder 볼륨${NC}"
echo -e "   Volume Group: ${YELLOW}cinder${NC}"
echo -e "   크기: ${YELLOW}20GB${NC}"
echo -e "   위치: ${YELLOW}/var/lib/cinder_data.img${NC}"
echo ""
echo -e "${BLUE}📌 시스템 리소스${NC}"
echo -e "   메모리: ${YELLOW}$(free -h | awk '/^Mem:/{print $2}')${NC} (스왑: ${YELLOW}$(free -h | awk '/^Swap:/{print $2}')${NC})"
echo -e "   디스크: ${YELLOW}$(df -h / | awk 'NR==2{print $4}')${NC} 사용 가능"
echo ""
echo -e "${BLUE}📌 유용한 명령어${NC}"
echo -e "   관리자 환경: ${YELLOW}source /etc/kolla/admin-openrc.sh${NC}"
echo -e "   서비스 확인: ${YELLOW}openstack endpoint list${NC}"
echo -e "   볼륨 확인: ${YELLOW}openstack volume service list${NC}"
echo -e "   Cinder VG: ${YELLOW}vgs cinder${NC}"
echo -e "   로그 확인: ${YELLOW}docker logs <container_name>${NC}"
echo ""
echo -e "${BLUE}📌 자격증명 파일${NC}"
echo -e "   ${YELLOW}~/openstack-credentials.txt${NC}"
echo ""
echo -e "${BLUE}📌 문제 발생 시${NC}"
echo -e "   Bootstrap 로그: ${YELLOW}/tmp/kolla-bootstrap.log${NC}"
echo -e "   Prechecks 로그: ${YELLOW}/tmp/kolla-prechecks.log${NC}"
echo -e "   Deploy 로그: ${YELLOW}/tmp/kolla-deploy.log${NC}"
if [ -n "$DOMAIN_NAME" ]; then
    echo -e "   Certbot 로그: ${YELLOW}/tmp/certbot.log${NC}"
fi
echo ""
echo -e "${GREEN}설치가 완료되었습니다!${NC}"
echo