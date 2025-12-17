#!/bin/bash
###############################################################################
# OpenStack 한방 설치 스크립트 (Final Optimized Version)
# NHN Cloud m2.c4m8 (4vCPU, 8GB RAM) + Ubuntu 22.04 환경
# Feature: 포트 강제 클린업 + 대기 시간 제거 + 안정성 확보
###############################################################################

set -e  # 에러 발생 시 즉시 중단

# root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo "❌ 오류: root 권한 필요 (sudo -i 실행 후 사용)"
    exit 1
fi

# 외부 IP 체크
if [ -z "$1" ]; then
    echo "❌ 오류: 외부 IP를 입력해주세요."
    echo "사용법: $0 <외부_IP>"
    exit 1
fi

EXTERNAL_IP="$1"

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

###############################################################################
# 0. 강력한 클린업 (Clean-up & Port Kill)
###############################################################################
echo -e "${YELLOW}>>> 기존 데이터 및 점유 포트 강제 정리 시작...${NC}"

# 1. Kolla destroy 시도
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it > /dev/null 2>&1 || true
fi

# 2. Docker 컨테이너 및 볼륨 전멸 (비밀번호 꼬임 방지)
docker stop $(docker ps -a -q) > /dev/null 2>&1 || true
docker rm $(docker ps -a -q) > /dev/null 2>&1 || true
docker volume prune -f > /dev/null 2>&1 || true

# 3. [핵심] 포트 3306(MariaDB) 및 주요 포트 강제 사살
# 이 과정이 없으면 "Timeout waiting for stop" 에러 발생함
log_info "포트 3306(MariaDB) 점유 프로세스 확인 및 종료 중..."
systemctl stop mysql > /dev/null 2>&1 || true
systemctl stop mariadb > /dev/null 2>&1 || true
fuser -k 3306/tcp > /dev/null 2>&1 || true
fuser -k 80/tcp > /dev/null 2>&1 || true   # Horizon
fuser -k 5000/tcp > /dev/null 2>&1 || true # Keystone
fuser -k 5672/tcp > /dev/null 2>&1 || true # RabbitMQ

# 4. 잔여 설정 삭제
rm -rf /etc/kolla/* 2>/dev/null || true

log_success "클린업 완료. 포트 3306 확보됨."

###############################################################################
# 1. OS 및 네트워크 설정
###############################################################################
log_info "Step 1: 시스템 설정..."

# 스왑 16GB (필수)
if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
fi

# 필수 패키지
apt update -qq && apt install -y python3-pip python3-venv git net-tools psmisc

# 호스트명 & Hosts 파일
hostnamectl set-hostname openstack
if ! grep -q "openstack" /etc/hosts; then
    echo "127.0.0.1 openstack" >> /etc/hosts
fi

# 더미 인터페이스 (eth1)
if ! ip link show eth1 &>/dev/null; then
    ip link add eth1 type dummy
    ip link set eth1 up
    # 재부팅 후에도 유지되도록 설정 파일 생성
    cat << EOF > /etc/systemd/network/10-dummy0.netdev
[NetDev]
Name=eth1
Kind=dummy
EOF
    cat << EOF > /etc/systemd/network/20-dummy0.network
[Match]
Name=eth1
[Network]
EOF
    systemctl enable systemd-networkd > /dev/null 2>&1 || true
    systemctl restart systemd-networkd > /dev/null 2>&1 || true
fi

# Docker 설치
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

###############################################################################
# 2. Kolla-Ansible 설치 및 설정
###############################################################################
log_info "Step 2: Kolla-Ansible 설정..."

# venv 구성
if [ ! -d ~/kolla-venv ]; then
    python3 -m venv ~/kolla-venv
fi
source ~/kolla-venv/bin/activate
pip install -U pip > /dev/null
pip install 'ansible-core>=2.16,<2.18' 'kolla-ansible>=19,<20' > /dev/null

# 설정 파일 복사
mkdir -p /etc/kolla
chown $USER:$USER /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

# KVM 확인
if grep -E 'vmx|svm' /proc/cpuinfo > /dev/null; then
    NOVA_VIRT_TYPE='# nova_compute_virt_type: "qemu"'
else
    NOVA_VIRT_TYPE='nova_compute_virt_type: "qemu"'
fi

MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

# globals.yml 작성 (타임아웃 설정 추가)
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

# [8GB RAM 최적화]
mariadb_max_connections: "100"
rabbitmq_vm_memory_high_watermark: "0.4"
nova_max_concurrent_builds: "2"
mariadb_wsrep_slave_threads: "2"

# [타임아웃 방지]
ansible_ssh_timeout: 60
docker_client_timeout: 300
haproxy_client_timeout: "5m"
haproxy_server_timeout: "5m"

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
# 3. 배포 실행 (Fast Track)
###############################################################################
log_info "Step 3: OpenStack 배포 시작 (No Delay)"

# 의존성 설치
kolla-ansible install-deps > /dev/null

# Bootstrap
log_info "Bootstrap 실행 중..."
kolla-ansible bootstrap-servers -i ~/all-in-one

# Prechecks
log_info "사전 검증(Prechecks) 실행 중..."
kolla-ansible prechecks -i ~/all-in-one

# Deploy
log_info "최종 배포(Deploy) 시작..."
echo -e "${YELLOW}8GB 램 보호를 위해 '--forks 4'로 실행합니다.${NC}"
kolla-ansible deploy -i ~/all-in-one --forks 4

# Post-deploy
log_info "후처리 작업..."
kolla-ansible post-deploy -i ~/all-in-one

###############################################################################
# 완료
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       🎉 설치가 완료되었습니다!       ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "📌 Horizon: http://$EXTERNAL_IP"
echo -e "📌 Admin PW: $ADMIN_PASSWORD"
echo ""