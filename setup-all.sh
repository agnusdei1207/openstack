#!/bin/bash
###############################################################################
# OpenStack 한방 설치 스크립트 (Perfect Bulletproof Version)
# NHN Cloud m2.c4m8 (4vCPU, 8GB RAM) + Ubuntu 22.04 환경
#
# [Update Log]
# 1. SSH Host Key Checking 비활성화 (멈춤 방지)
# 2. Time Sync(chrony) 추가 (인증 에러 방지)
# 3. /dev/kvm 권한 강제 수정 (Nova 에러 방지)
# 4. Ansible Forks 환경변수 처리 (Deploy 에러 방지)
# 5. 스마트 클린업 (재설치 완벽 호환)
###############################################################################

# 1. 권한 및 인자 체크
if [ "$EUID" -ne 0 ]; then
    echo "❌ 오류: root 권한 필요 (sudo -i 실행 후 사용)"
    exit 1
fi

if [ -z "$1" ]; then
    echo "❌ 오류: 외부 IP를 입력해주세요."
    echo "사용법: $0 <외부_IP>"
    exit 1
fi

EXTERNAL_IP="$1"

# 환경변수 설정 (중요: 대화형 질문 차단 & Ansible 설정)
export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_FORKS=4
export PIP_DEFAULT_TIMEOUT=100

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

###############################################################################
# 0. 필수 패키지 및 시간 동기화 (기초 공사)
###############################################################################
log_info "기초 패키지 설치 및 시간 동기화..."

# Apt 업데이트 및 필수 도구 (chrony 추가됨)
apt update -qq
apt install -y python3-pip python3-venv git net-tools psmisc curl chrony > /dev/null 2>&1

# 시간 동기화 (OpenStack 인증 에러 방지용 필수 단계)
systemctl enable chrony > /dev/null 2>&1
systemctl restart chrony > /dev/null 2>&1
log_success "시간 동기화 완료."

###############################################################################
# 1. 스마트 클린업 (Clean-up)
###############################################################################
echo -e "${YELLOW}>>> 환경 점검 및 클린업 시작 (에러 무시 모드)...${NC}"

set +e # 에러 무시 시작

# 1-1. Kolla destroy
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    log_info "기존 설치 제거(Destroy) 중..."
    source ~/kolla-venv/bin/activate
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it > /dev/null 2>&1
    deactivate
fi

# 1-2. Docker 정리
if command -v docker &> /dev/null; then
    log_info "Docker 컨테이너/볼륨 청소..."
    docker stop $(docker ps -a -q) > /dev/null 2>&1
    docker rm $(docker ps -a -q) > /dev/null 2>&1
    docker volume prune -f > /dev/null 2>&1
fi

# 1-3. 포트/프로세스 정리 (좀비 프로세스 사살)
log_info "포트 점유 프로세스 강제 종료..."
systemctl stop mysql > /dev/null 2>&1
systemctl stop mariadb > /dev/null 2>&1
fuser -k 3306/tcp > /dev/null 2>&1
fuser -k 80/tcp > /dev/null 2>&1 
fuser -k 5000/tcp > /dev/null 2>&1
fuser -k 5672/tcp > /dev/null 2>&1
fuser -k 11211/tcp > /dev/null 2>&1

# 1-4. 잔여 파일 삭제
rm -rf /etc/kolla/* 2>/dev/null
rm -rf ~/kolla-venv 2>/dev/null

log_success "클린업 완료."

###############################################################################
# 2. 시스템 설정 (안전장치 ON)
###############################################################################
set -e  # 에러 감지 모드 시작

log_info "Step 1: OS 설정 및 최적화..."

# 스왑 16GB
if [ ! -f /swapfile ]; then
    log_info "16GB 스왑 파일 생성..."
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
fi

# 호스트명 설정
hostnamectl set-hostname openstack
if ! grep -q "openstack" /etc/hosts; then
    echo "127.0.0.1 openstack" >> /etc/hosts
fi

# 더미 인터페이스 (eth1)
if ! ip link show eth1 &>/dev/null; then
    log_info "더미 인터페이스(eth1) 생성..."
    ip link add eth1 type dummy
    ip link set eth1 up
    mkdir -p /etc/systemd/network
    echo -e "[NetDev]\nName=eth1\nKind=dummy" > /etc/systemd/network/10-dummy0.netdev
    echo -e "[Match]\nName=eth1\n[Network]" > /etc/systemd/network/20-dummy0.network
    systemctl restart systemd-networkd > /dev/null 2>&1 || true
fi

# KVM 권한 수정 (Nova 에러 방지)
if [ -e /dev/kvm ]; then
    chmod 666 /dev/kvm
fi

# Docker 설치
if ! command -v docker &>/dev/null; then
    log_info "Docker 설치 중..."
    curl -fsSL https://get.docker.com | sh
fi

###############################################################################
# 3. Kolla-Ansible 설치
###############################################################################
log_info "Step 2: Kolla-Ansible 환경 구성..."

# venv 생성
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate

# Pip 업그레이드 및 설치 (타임아웃 방지 옵션)
pip install -U pip > /dev/null
log_info "Ansible 및 Kolla 패키지 설치..."
pip install 'ansible-core>=2.16,<2.18' 'kolla-ansible>=19,<20' > /dev/null

# 설정 파일 복사
mkdir -p /etc/kolla
chown $USER:$USER /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

# 가상화 타입 체크
if grep -E 'vmx|svm' /proc/cpuinfo > /dev/null; then
    NOVA_VIRT_TYPE='# nova_compute_virt_type: "qemu"'
else
    NOVA_VIRT_TYPE='nova_compute_virt_type: "qemu"'
    log_info "KVM 미지원 환경 -> QEMU 모드 설정"
fi

MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

# globals.yml 작성 (최적화 + 타임아웃 방지 풀세트)
cat > /etc/kolla/globals.yml << EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"

network_interface: "$MAIN_INTERFACE"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "127.0.0.1"
kolla_external_vip_address: "$EXTERNAL_IP"

enable_haproxy: "no"
enable_mariadb_sharding: "no"
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"

$NOVA_VIRT_TYPE
neutron_plugin_agent: "openvswitch"
neutron_bridge_name: "br-ex"
neutron_external_flat_networks: "physnet1"

# [리소스 최적화]
mariadb_max_connections: "100"
rabbitmq_vm_memory_high_watermark: "0.4"
nova_max_concurrent_builds: "2"
mariadb_wsrep_slave_threads: "2"

# [타임아웃 방지 대폭 강화]
ansible_ssh_timeout: 120
docker_client_timeout: 600
haproxy_client_timeout: "5m"
haproxy_server_timeout: "5m"
nova_rpc_response_timeout: 180
keystone_token_provider: 'fernet'

# 불필요 서비스 OFF
enable_cinder: "no"
enable_swift: "no"
enable_heat: "no"
enable_ceilometer: "no"
enable_aodh: "no"
enable_barbican: "no"
enable_gnocchi: "no"
enable_grafana: "no"
enable_ironic: "no"
enable_magnum: "no"
enable_manila: "no"
enable_masakari: "no"
enable_mistral: "no"
enable_monasca: "no"
enable_octavia: "no"
enable_prometheus: "no"
enable_sahara: "no"
enable_trove: "no"
enable_zun: "no"
EOF

# 패스워드 생성
kolla-genpwd
ADMIN_PASSWORD=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" > ~/openstack-credentials.txt

###############################################################################
# 4. 배포 실행 (Environment Variable 사용)
###############################################################################
log_info "Step 3: OpenStack 배포 시작..."

# Ansible 최적화 설정 파일 생성 (SSH 멈춤 방지)
cat > ~/ansible.cfg <<EOF
[defaults]
host_key_checking = False
pipelining = True
forks = 4
timeout = 60
EOF
export ANSIBLE_CONFIG=~/ansible.cfg

# 의존성 설치
kolla-ansible install-deps > /dev/null

# Bootstrap
log_info "1. Bootstrap 실행..."
kolla-ansible bootstrap-servers -i ~/all-in-one

# Prechecks
log_info "2. 사전 검증(Prechecks)..."
kolla-ansible prechecks -i ~/all-in-one

# Deploy
log_info "3. 최종 배포(Deploy) 시작..."
echo -e "${YELLOW}안정성을 위해 ANSIBLE_FORKS=4 적용 중...${NC}"
kolla-ansible deploy -i ~/all-in-one

# Post-deploy
log_info "4. 후처리(Post-deploy)..."
kolla-ansible post-deploy -i ~/all-in-one

# CLI 클라이언트 설치
log_info "CLI 클라이언트 설치..."
pip install python-openstackclient > /dev/null

###############################################################################
# 완료
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       🎉 OpenStack 설치 완료! 🎉       ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "📌 Horizon: http://$EXTERNAL_IP"
echo -e "📌 Admin ID: admin"
echo -e "📌 Admin PW: $ADMIN_PASSWORD"
echo -e "📌 Credential: ~/openstack-credentials.txt"
echo -e "📌 CLI 실행: source /etc/kolla/admin-openrc.sh"
echo ""