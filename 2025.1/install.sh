#!/bin/bash

# ==========================================================
# NHN Cloud OpenStack 2025.1 (Epoxy) Installer
# ==========================================================
# 특징: 최신 Ansible Core(앤서블 코어) 사용 + Docker SDK 의존성 해결
# OS: Ubuntu 24.04 LTS
# 대상: 단일 인스턴스 호스트 (All-in-One)용
# ==========================================================

set -e

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
exit_error() { error "$1"; exit 1; }

# 1. Root(루트) 권한 체크
if [ "$EUID" -ne 0 ]; then
    exit_error "root 권한으로 실행해주세요. (sudo -i)"
fi

# 2. IP(Internet Protocol) 입력 확인
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

log "Target Version: OpenStack 2025.1 (Epoxy)"
log "Private IP    : ${MY_PRIVATE_IP}"
sleep 1

# ==========================================================
# [Step 0] 기존 환경 완전 삭제 (Clean Install)
# ==========================================================
log "기존 환경 정리 시작..."

if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker volume rm $(docker volume ls -q) >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
fi

rm -rf /etc/kolla/*
rm -rf /var/lib/kolla
rm -rf ~/kolla-venv
rm -rf /root/.ansible
mkdir -p /etc/kolla

# ==========================================================
# [Step 1] 필수 시스템 설정
# ==========================================================
log "호스트네임 및 SSH 설정 중..."

hostnamectl set-hostname openstack
sed -i '/openstack/d' /etc/hosts
echo "${MY_PRIVATE_IP} openstack" >> /etc/hosts

# SSH 키 설정
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "StrictHostKeyChecking no" > ~/.ssh/config

# 스왑 메모리 설정 (16GB)
if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ==========================================================
# [Step 2] 패키지 및 Kolla-Ansible 설치 (에러 수정됨)
# ==========================================================
log "시스템 패키지 및 Python 가상환경 구성..."
apt update -qq
apt install -y python3-dev python3-pip python3-venv git curl libffi-dev gcc libssl-dev lsof

python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip wheel

log "Kolla-Ansible 및 Docker SDK 설치 중..."
# [수정 사항] Docker SDK를 명시적으로 설치하여 Precheck 에러를 방지합니다.
pip install 'ansible-core>=2.16'
pip install docker
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1

# 설정 파일 복사
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one .

# ==========================================================
# [Step 3] 의존성 설치
# ==========================================================
log "Ansible Galaxy(앤서블 갤럭시) 의존성 설치..."
kolla-ansible install-deps
success "의존성 설치 완료"

# ==========================================================
# [Step 4] globals.yml 설정
# ==========================================================
log "오픈스택 환경 설정(globals.yml) 생성..."
MAIN_INTERFACE=$(ip -4 addr show | grep "$MY_PRIVATE_IP" | awk '{print $NF}' | head -1)

if ! ip link show eth1 >/dev/null 2>&1; then
    ip link add eth1 type dummy
    ip link set eth1 up
fi

cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "epoxy"
kolla_internal_vip_address: "${MY_PRIVATE_IP}"
network_interface: "${MAIN_INTERFACE}"
neutron_external_interface: "eth1"
kolla_external_vip_address: "${MY_PRIVATE_IP}"
enable_proxysql: "yes"
enable_haproxy: "yes"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
enable_horizon: "yes"
enable_prometheus: "no"
enable_grafana: "no"
enable_fluentd: "no"
nova_compute_virt_type: "qemu"
EOF

kolla-genpwd

# ==========================================================
# [Step 5] Cinder(신더) LVM 볼륨 구성
# ==========================================================
log "Cinder 볼륨 준비 중..."
if ! vgs cinder >/dev/null 2>&1; then
    dd if=/dev/zero of=/var/lib/cinder.img bs=1M count=20000 status=none
    LOOP_DEV=$(losetup -f --show /var/lib/cinder.img)
    pvcreate $LOOP_DEV
    vgcreate cinder $LOOP_DEV
fi

# ==========================================================
# [Step 6] 배포 실행
# ==========================================================
log ">>> 배포 시작: 1. Bootstrap Servers"
kolla-ansible bootstrap-servers -i all-in-one

log ">>> 배포 시작: 2. Prechecks"
kolla-ansible prechecks -i all-in-one

log ">>> 배포 시작: 3. Deploy"
kolla-ansible deploy -i all-in-one

log ">>> 배포 시작: 4. Post-deploy"
kolla-ansible post-deploy -i all-in-one

# 클라이언트 설치
pip install python-openstackclient

# 완료 정보 출력
PASS=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
success "========================================================"
success " 설치 완료! (OpenStack 2025.1 Epoxy)"
success "========================================================"
echo -e " 웹 대시보드 : http://${MY_FLOATING_IP}"
echo -e " 아이디       : admin"
echo -e " 비밀번호     : ${PASS}"
success "========================================================"