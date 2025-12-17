#!/bin/bash
###############################################################################
# OpenStack AIO 안정화 설치 스크립트
# NHN Cloud m2.c4m8 (8vCPU, 16GB RAM) + Ubuntu 22.04
# 단일 호스트 환경 최적화 - 에러 없이 안정적 설치
###############################################################################

set -euo pipefail  # 에러 발생 시 즉시 중단
trap 'echo "❌ 오류 발생: Line $LINENO"; exit 1' ERR

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

###############################################################################
# 0. 사전 검증
###############################################################################
if [ "$EUID" -ne 0 ]; then
    log_error "root 권한 필요 (sudo -i 실행 후 사용)"
    exit 1
fi

if [ -z "${1:-}" ]; then
    log_error "외부 IP를 입력해주세요."
    echo "사용법: $0 <외부_IP>"
    exit 1
fi

EXTERNAL_IP="$1"

# IP 형식 검증
if ! [[ $EXTERNAL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_error "올바른 IP 형식이 아닙니다: $EXTERNAL_IP"
    exit 1
fi

# 메모리 확인 (최소 14GB 필요)
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -lt 14 ]; then
    log_error "메모리 부족: 최소 14GB 필요 (현재: ${TOTAL_MEM}GB)"
    exit 1
fi

# 디스크 공간 확인 (최소 50GB 필요)
AVAIL_DISK=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [ "$AVAIL_DISK" -lt 50 ]; then
    log_error "디스크 공간 부족: 최소 50GB 필요 (현재: ${AVAIL_DISK}GB)"
    exit 1
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

apt-get update -qq
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
    > /dev/null 2>&1

# 시간 동기화 (중요: 인증서 검증)
systemctl enable chrony > /dev/null 2>&1
systemctl restart chrony > /dev/null 2>&1
sleep 2
chronyc makestep > /dev/null 2>&1 || true

log_success "기초 패키지 설치 완료"

###############################################################################
# 2. 안전한 클린업
###############################################################################
log_warn "Step 1: 기존 환경 정리 중..."

set +e  # 클린업 중에는 에러 무시

# Kolla 정리
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    log_info "기존 Kolla 환경 제거 중..."
    source ~/kolla-venv/bin/activate
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it > /dev/null 2>&1
    deactivate > /dev/null 2>&1
fi

# Docker 컨테이너 정리
if command -v docker &> /dev/null; then
    log_info "Docker 컨테이너 정리 중..."
    docker stop $(docker ps -aq) > /dev/null 2>&1
    docker rm -f $(docker ps -aq) > /dev/null 2>&1
    docker network prune -f > /dev/null 2>&1
    docker volume prune -f > /dev/null 2>&1
    docker system prune -af > /dev/null 2>&1
fi

# Cinder LVM 정리
log_info "Cinder LVM 정리 중..."
vgchange -an cinder > /dev/null 2>&1
vgremove -f cinder > /dev/null 2>&1
pvremove -f /dev/loop2 > /dev/null 2>&1
losetup -d /dev/loop2 > /dev/null 2>&1
rm -f /var/lib/cinder_data.img

# 포트 정리
for PORT in 3306 80 443 5000 8774 9292 9696 3260 6080; do
    fuser -k ${PORT}/tcp > /dev/null 2>&1
done

# 디렉토리 정리
rm -rf /etc/kolla
rm -rf ~/kolla-venv
rm -rf ~/.ansible

# systemd 서비스 정리
systemctl disable cinder-loop.service > /dev/null 2>&1
rm -f /etc/systemd/system/cinder-loop.service
systemctl daemon-reload

set -e  # 다시 에러 체크 활성화

log_success "클린업 완료"

###############################################################################
# 3. 스왑 메모리 설정 (16GB)
###############################################################################
log_info "Step 2: 스왑 메모리 설정 (16GB)..."

# 기존 스왑 제거
swapoff -a > /dev/null 2>&1 || true
sed -i '/swapfile/d' /etc/fstab
rm -f /swapfile

# 새로운 스왑 생성
log_info "16GB 스왑 파일 생성 중... (약 30초 소요)"
dd if=/dev/zero of=/swapfile bs=1M count=16384 status=progress
chmod 600 /swapfile
mkswap /swapfile > /dev/null
swapon /swapfile

# 영구 설정
if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 스왑 사용률 최적화
sysctl -w vm.swappiness=10 > /dev/null
sysctl -w vm.vfs_cache_pressure=50 > /dev/null
echo "vm.swappiness=10" >> /etc/sysctl.conf
echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf

SWAP_SIZE=$(free -h | awk '/^Swap:/{print $2}')
log_success "스왑 메모리 설정 완료 (크기: $SWAP_SIZE)"

###############################################################################
# 4. 시스템 설정
###############################################################################
log_info "Step 3: 시스템 설정..."

# 호스트명 설정
hostnamectl set-hostname openstack
sed -i '/openstack/d' /etc/hosts
echo "127.0.0.1 localhost openstack" >> /etc/hosts
echo "::1 localhost openstack" >> /etc/hosts

# Cinder용 가상 디스크 생성 (20GB)
if ! vgs cinder &>/dev/null; then
    log_info "Cinder 볼륨 그룹 생성 중... (약 1분 소요)"
    
    # 20GB 파일 생성
    dd if=/dev/zero of=/var/lib/cinder_data.img bs=1M count=20480 status=progress
    
    # 루프백 디바이스 연결
    LOOP_DEV=$(losetup -f)
    losetup $LOOP_DEV /var/lib/cinder_data.img
    
    # PV 및 VG 생성
    pvcreate $LOOP_DEV
    vgcreate cinder $LOOP_DEV
    
    # 재부팅 시 자동 마운트 서비스
    cat > /etc/systemd/system/cinder-loop.service <<'EOF'
[Unit]
Description=Setup Cinder Loopback Device
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'LOOP=$(/sbin/losetup -f); /sbin/losetup $LOOP /var/lib/cinder_data.img; /sbin/pvscan; /sbin/vgscan; /sbin/vgchange -ay cinder'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable cinder-loop.service > /dev/null 2>&1
    
    log_success "Cinder VG 생성 완료 (디바이스: $LOOP_DEV)"
fi

# 더미 네트워크 인터페이스 생성
if ! ip link show eth1 &>/dev/null; then
    log_info "외부망 더미 인터페이스 생성..."
    
    modprobe dummy > /dev/null 2>&1 || true
    ip link add eth1 type dummy
    ip link set eth1 up
    
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
    
    systemctl enable systemd-networkd > /dev/null 2>&1
    systemctl restart systemd-networkd > /dev/null 2>&1 || true
    
    log_success "더미 인터페이스 생성 완료"
fi

###############################################################################
# 5. Docker 설치
###############################################################################
if ! command -v docker &>/dev/null; then
    log_info "Step 4: Docker 설치 중..."
    
    # Docker 공식 GPG 키 및 저장소 추가
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
    
    # Docker 최적화
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "storage-driver": "overlay2"
}
EOF
    
    systemctl enable docker
    systemctl restart docker
    
    log_success "Docker 설치 완료"
else
    log_info "Docker 이미 설치됨 (버전: $(docker --version | awk '{print $3}'))"
fi

###############################################################################
# 6. Kolla-Ansible 설치
###############################################################################
log_info "Step 5: Kolla-Ansible 설치 중..."

# Python 가상환경 생성
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate

# pip 업그레이드
pip install --upgrade pip setuptools wheel > /dev/null

# Kolla-Ansible 설치 (2024.2 Dalmatian)
log_info "Kolla-Ansible 패키지 설치 중... (약 2분 소요)"
pip install 'ansible-core>=2.16,<2.18' > /dev/null
pip install 'kolla-ansible==19.1.0' > /dev/null

# 설정 파일 복사
mkdir -p /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

log_success "Kolla-Ansible 설치 완료"

###############################################################################
# 7. Kolla 설정
###############################################################################
log_info "Step 6: OpenStack 설정 구성 중..."

# 가상화 타입 확인
if grep -E 'vmx|svm' /proc/cpuinfo > /dev/null; then
    NOVA_VIRT_TYPE='kvm'
    log_info "KVM 가상화 지원 감지"
else
    NOVA_VIRT_TYPE='qemu'
    log_warn "KVM 미지원: QEMU 모드 사용"
fi

# 메인 네트워크 인터페이스 감지
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$MAIN_INTERFACE" ]; then
    log_error "네트워크 인터페이스를 찾을 수 없습니다"
    exit 1
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
kolla-genpwd

# Admin 패스워드 저장
ADMIN_PASSWORD=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
cat > ~/openstack-credentials.txt <<EOF
# OpenStack 관리자 계정 정보
URL: http://$EXTERNAL_IP
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
kolla-ansible install-deps > /dev/null 2>&1

# Bootstrap
log_info "[2/4] Bootstrap 실행 중... (약 5분)"
if ! kolla-ansible bootstrap-servers -i ~/all-in-one; then
    log_error "Bootstrap 실패"
    exit 1
fi

# Prechecks
log_info "[3/4] Prechecks 실행 중... (약 3분)"
if ! kolla-ansible prechecks -i ~/all-in-one; then
    log_error "Prechecks 실패 - 시스템 요구사항을 확인하세요"
    exit 1
fi

# Deploy
log_info "[4/4] Deploy 실행 중... (약 25분, Cinder 포함)"
log_warn "이 단계는 시간이 오래 걸립니다. 기다려 주세요..."
if ! kolla-ansible deploy -i ~/all-in-one; then
    log_error "배포 실패"
    log_info "로그 확인: journalctl -xe"
    exit 1
fi

# Post-deploy
log_info "Post-deploy 설정 중..."
kolla-ansible post-deploy -i ~/all-in-one

# OpenStack 클라이언트 설치
pip install python-openstackclient python-cinderclient python-novaclient python-glanceclient > /dev/null

log_success "OpenStack 배포 완료!"

###############################################################################
# 10. 환경 검증
###############################################################################
log_info "Step 8: 환경 검증 중..."

source /etc/kolla/admin-openrc.sh

# 서비스 상태 확인
sleep 10

set +e
log_info "OpenStack 서비스 확인 중..."
openstack endpoint list > /dev/null 2>&1
if [ $? -eq 0 ]; then
    log_success "Keystone 서비스 정상"
else
    log_warn "Keystone 초기화 중... 잠시 후 다시 시도하세요"
fi
set -e

###############################################################################
# 11. 완료 메시지
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    🎉 OpenStack AIO 설치 완료! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}📌 접속 정보${NC}"
echo -e "   Horizon URL: ${YELLOW}http://$EXTERNAL_IP${NC}"
echo -e "   Username: ${YELLOW}admin${NC}"
echo -e "   Password: ${YELLOW}$ADMIN_PASSWORD${NC}"
echo ""
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
echo ""
echo -e "${BLUE}📌 자격증명 파일${NC}"
echo -e "   ${YELLOW}~/openstack-credentials.txt${NC}"
echo ""
echo -e "${GREEN}설치가 완료되었습니다!${NC}"
echo ""