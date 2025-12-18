#!/bin/bash

# ==========================================================
# NHN Cloud OpenStack AIO Installer (Variable Input Version)
# ==========================================================

# 에러 발생 시 중단
set -e

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Root 체크
if [ "$EUID" -ne 0 ]; then
    error "root 권한으로 실행해주세요. (sudo -i)"
    exit 1
fi

# 2. 입력값(인자) 확인 및 변수 할당
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "========================================================"
    error "IP 주소가 입력되지 않았습니다."
    echo "사용법: $0 <사설_IP> <플로팅_IP>"
    echo "예시  : $0 192.168.0.102 133.186.132.232"
    echo "========================================================"
    exit 1
fi

MY_PRIVATE_IP="$1"
MY_FLOATING_IP="$2"

log "설정된 사설 IP  : ${MY_PRIVATE_IP}"
log "설정된 플로팅 IP: ${MY_FLOATING_IP}"
log "설치 프로세스를 시작합니다..."
sleep 2

# 3. 스왑 메모리 설정 (8GB 램에서는 필수)
log "RAM 부족 방지를 위한 스왑(16GB) 설정 중..."
if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
    success "스왑 16GB 생성 완료"
else
    log "스왑 파일이 이미 존재합니다. 패스."
fi

# 4. 시스템 클린업 (재설치 시 충돌 방지)
log "기존 설치 및 포트 충돌 정리 중..."
# Kolla 제거
if [ -d ~/kolla-venv ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    kolla-ansible -i all-in-one destroy --yes-i-really-really-mean-it >/dev/null 2>&1 || true
    deactivate 2>/dev/null || true
    rm -rf ~/kolla-venv
fi
# Docker 정리
if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker volume prune -f >/dev/null 2>&1 || true
fi
# 3306 포트 좀비 프로세스 사살
kill -9 $(lsof -t -i:3306) 2>/dev/null || true
rm -rf /etc/kolla /var/lib/kolla /var/lib/docker/volumes/mariadb

# 5. 필수 패키지 설치
log "필수 패키지 설치..."
apt update -qq
apt install -y python3-dev python3-pip python3-venv git curl libffi-dev gcc libssl-dev lsof

# 6. Kolla 설치 (Bobcat)
log "Kolla-Ansible (Bobcat 2023.2) 설치..."
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip wheel
pip install 'ansible-core>=2.15,<2.16'
pip install 'kolla-ansible==17.2.0'

# 설정 복사
mkdir -p /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one .

# 의존성 설치
kolla-ansible install-deps

# 7. globals.yml 작성 (NHN Cloud 맞춤 설정)
log "globals.yml 설정 생성..."

# 입력받은 사설 IP를 가진 인터페이스 자동 감지
MAIN_INTERFACE=$(ip -4 addr show | grep "$MY_PRIVATE_IP" | awk '{print $NF}' | head -1)

if [ -z "$MAIN_INTERFACE" ]; then
    error "입력하신 사설 IP ($MY_PRIVATE_IP)를 사용하는 네트워크 인터페이스를 찾을 수 없습니다."
    error "ifconfig 또는 ip addr 명령어로 IP를 다시 확인해주세요."
    exit 1
fi
log "감지된 인터페이스: $MAIN_INTERFACE"

# Neutron용 더미 인터페이스 생성 (NIC가 1개뿐이라 필수)
if ! ip link show eth1 >/dev/null 2>&1; then
    ip link add eth1 type dummy
    ip link set eth1 up
fi

cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2023.2"

# [네트워크 핵심] 변수로 받은 사설 IP 사용
kolla_internal_vip_address: "${MY_PRIVATE_IP}"
network_interface: "${MAIN_INTERFACE}"
neutron_external_interface: "eth1"

# [옵션] 내부 통신용으로 사설 IP 유지
kolla_external_vip_address: "${MY_PRIVATE_IP}"

# [서비스] ProxySQL 사용 (표준)
enable_proxysql: "yes"
enable_haproxy: "yes"

# [서비스] 기본 구성
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
enable_horizon: "yes"

# [최적화] 8GB 램 보호를 위해 무거운 모니터링 끄기
enable_prometheus: "no"
enable_grafana: "no"
enable_fluentd: "no"
enable_ceilometer: "no"
enable_gnocchi: "no"

# 가상화 타입 (VM 위에서 돌리므로 qemu 강제)
nova_compute_virt_type: "qemu"
EOF

kolla-genpwd

# 8. Cinder 볼륨 (파일 기반)
log "Cinder용 볼륨 이미지 생성 (20GB)..."
if ! vgs cinder >/dev/null 2>&1; then
    dd if=/dev/zero of=/var/lib/cinder.img bs=1M count=20000 status=none
    losetup -f /var/lib/cinder.img
    LOOP_DEV=$(losetup -j /var/lib/cinder.img | cut -d: -f1)
    pvcreate $LOOP_DEV
    vgcreate cinder $LOOP_DEV
fi

# 9. 배포 시작
log ">>> 1. Bootstrap Servers..."
kolla-ansible -i all-in-one bootstrap-servers

log ">>> 2. Prechecks..."
if ! kolla-ansible -i all-in-one prechecks; then
    error "Precheck 실패! 로그를 확인하세요."
    exit 1
fi

log ">>> 3. Deploy (약 15~20분 소요)..."
if ! kolla-ansible -i all-in-one deploy; then
    error "Deploy 실패. 재시도 전에 'docker logs mariadb' 등을 확인하세요."
    exit 1
fi

log ">>> 4. Post-deploy..."
kolla-ansible -i all-in-one post-deploy

# 클라이언트 설치
pip install python-openstackclient

# 완료 메시지
PASS=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
success "========================================================"
success " 설치 성공! (NHN Cloud Setup)"
success "========================================================"
echo -e " 1. 웹 접속 주소 (브라우저): http://${MY_FLOATING_IP}"
echo -e " 2. 도메인 (Domain): default"
echo -e " 3. 아이디 (User)  : admin"
echo -e " 4. 암호 (Password): ${PASS}"
success "========================================================"