#!/bin/bash

# ==========================================================
# NHN Cloud OpenStack 2025.1 (Epoxy) Installer
# ==========================================================
# 특징: 최신 Ansible Core 사용 + 의존성 자동 해결 (Galaxy 에러 없음)
# 단일 인스턴스 호스트용

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

# 1. Root 체크
if [ "$EUID" -ne 0 ]; then
    exit_error "root 권한으로 실행해주세요. (sudo -i)"
fi

# 2. IP 입력 확인
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
log "기존 찌꺼기(venv, config) 제거 중..."
rm -rf ~/kolla-venv
rm -rf /etc/kolla/*
rm -rf /root/.ansible
mkdir -p /etc/kolla

# ==========================================================
# [Step 1] 필수 안전장치 (Hostname, AppArmor, SSH)
# ==========================================================
log "기본 안전장치 설정 중..."

# 1. 호스트네임 설정
hostnamectl set-hostname openstack
sed -i '/openstack/d' /etc/hosts
sed -i '/127.0.1.1/d' /etc/hosts
echo "${MY_PRIVATE_IP} openstack" >> /etc/hosts

# 2. AppArmor 해제
if systemctl is-active --quiet apparmor; then
    systemctl stop apparmor
    systemctl disable apparmor
fi

# 3. SSH 키 설정
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi
if ! grep -q "$(cat ~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys 2>/dev/null; then
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
echo "StrictHostKeyChecking no" > ~/.ssh/config

# 4. 스왑 메모리
if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
fi

# 5. Docker 정리
if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker volume prune -f >/dev/null 2>&1 || true
fi
rm -rf /var/lib/kolla /var/lib/docker/volumes/mariadb

# ==========================================================
# [Step 2] 패키지 설치 (2025.1 Epoxy용 최신 환경)
# ==========================================================
log "시스템 패키지 업데이트 및 설치..."
apt update -qq
apt install -y python3-dev python3-pip python3-venv git curl libffi-dev gcc libssl-dev lsof

log "Kolla-Ansible (Epoxy) 설치 중..."
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip wheel

# [핵심] 최신 버전은 최신 Ansible을 사용합니다.
# Epoxy는 Ansible Core 2.16 이상을 공식 지원합니다.
pip install 'ansible-core>=2.16'

# OpenStack 2025.1 (Epoxy) 설치
# 주의: 정식 릴리즈가 pip에 없다면 git에서 stable 브랜치를 가져옵니다.
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1

# 설정 파일 복사
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one .

# ==========================================================
# [Step 3] 의존성 설치 (Galaxy)
# ==========================================================
log "Ansible Galaxy 의존성 설치 (Standard)..."
# 최신 버전(Epoxy)은 requirements.yml이 최신 라이브러리에 맞춰져 있으므로
# 별도의 해킹 없이 순정 명령어가 잘 작동해야 정상입니다.
kolla-ansible install-deps
success "의존성 설치 완료"

# ==========================================================
# [Step 4] globals.yml 설정 (Epoxy)
# ==========================================================
log "설정 파일 생성..."
MAIN_INTERFACE=$(ip -4 addr show | grep "$MY_PRIVATE_IP" | awk '{print $NF}' | head -1)

if [ -z "$MAIN_INTERFACE" ]; then
    exit_error "인터페이스를 찾을 수 없습니다: $MY_PRIVATE_IP"
fi

if ! ip link show eth1 >/dev/null 2>&1; then
    ip link add eth1 type dummy
    ip link set eth1 up
fi

cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"

# [핵심] 2025.1 버전 명시 (Epoxy)
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

# 불필요한 리소스 off
enable_prometheus: "no"
enable_grafana: "no"
enable_fluentd: "no"
enable_ceilometer: "no"
enable_gnocchi: "no"

nova_compute_virt_type: "qemu"
EOF

kolla-genpwd

# ==========================================================
# [Step 5] Cinder 볼륨
# ==========================================================
log "Cinder 볼륨 준비..."
if ! vgs cinder >/dev/null 2>&1; then
    dd if=/dev/zero of=/var/lib/cinder.img bs=1M count=20000 status=none
    losetup -f /var/lib/cinder.img
    LOOP_DEV=$(losetup -j /var/lib/cinder.img | cut -d: -f1)
    pvcreate $LOOP_DEV
    vgcreate cinder $LOOP_DEV
fi

# ==========================================================
# [Step 6] 배포 (Deploy)
# ==========================================================
log ">>> 1. Bootstrap Servers..."
kolla-ansible bootstrap-servers -i all-in-one

log ">>> 2. Prechecks..."
if ! kolla-ansible prechecks -i all-in-one; then
    exit_error "Precheck 실패. 로그를 확인하세요."
fi

log ">>> 3. Deploy (Epoxy)..."
if ! kolla-ansible deploy -i all-in-one; then
    exit_error "Deploy 실패. 'docker logs mariadb' 등을 확인하세요."
fi

log ">>> 4. Post-deploy..."
kolla-ansible post-deploy -i all-in-one

# 클라이언트 설치
pip install python-openstackclient

# 완료
PASS=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
success "========================================================"
success " 설치 완료! (OpenStack 2025.1 Epoxy)"
success "========================================================"
echo -e " 웹 대시보드 : http://${MY_FLOATING_IP}"
echo -e " 도메인      : default"
echo -e " 아이디      : admin"
echo -e " 비밀번호    : ${PASS}"
success "========================================================"