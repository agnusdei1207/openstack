#!/bin/bash

# ==========================================================
# NHN Cloud OpenStack 2025.1 (Epoxy) Installer
# ==========================================================
# 특징: Docker SDK(Software Development Kit) 해결 + Galaxy 무제한 재시도
# OS: Ubuntu 24.04 LTS (All-in-One, 올인원)
# ==========================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
exit_error() { error "$1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
    exit_error "root 권한으로 실행해주세요. (sudo -i)"
fi

if [ -z "$1" ] || [ -z "$2" ]; then
    error "사용법: $0 <사설_IP> <플로팅_IP>"
    exit 1
fi

# IP (Internet Protocol, 인터넷 프로토콜) 설정
MY_PRIVATE_IP="$1"
MY_FLOATING_IP="$2"

log "Target Version: OpenStack 2025.1 (Epoxy)"
log "Private IP    : ${MY_PRIVATE_IP}"

# [Step 0] 기존 환경 정리
log "기존 환경 정리 시작..."
if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
    docker volume rm $(docker volume ls -q) >/dev/null 2>&1 || true
fi
rm -rf /etc/kolla/* /var/lib/kolla ~/kolla-venv /root/.ansible
mkdir -p /etc/kolla

# [Step 1] 시스템 기본 설정
hostnamectl set-hostname openstack
sed -i '/openstack/d' /etc/hosts
echo "${MY_PRIVATE_IP} openstack" >> /etc/hosts

# SSH (Secure Shell, 보안 셸) 키 설정
if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa; fi
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "StrictHostKeyChecking no" > ~/.ssh/config

# 스왑(Swap) 메모리 설정
if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# [Step 2] 패키지 및 Python 가상 환경(VENV, Virtual Environment) 설치
log "시스템 패키지 및 가상 환경 구성..."
apt update -qq && apt install -y python3-dev python3-pip python3-venv git curl libffi-dev gcc libssl-dev lsof
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip wheel

# Docker SDK (Software Development Kit, 소프트웨어 개발 키트) 명시적 설치
pip install 'ansible-core>=2.16' docker
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1

cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one .

# ==========================================================
# [Step 3] 의존성 설치 (성공할 때까지 무한 재시도)
# ==========================================================
log "Ansible Galaxy(앤서블 갤럭시) 의존성 설치 시작 (무제한 시도)..."
RETRY_COUNT=0

while true; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    # 앤서블 갤럭시에서 컬렉션을 설치합니다.
    if kolla-ansible install-deps; then
        success "의존성 설치 완료! (총 $RETRY_COUNT 번째 시도에서 성공)"
        break
    else
        error "의존성 설치 실패 (시도 횟수: $RETRY_COUNT). 2초 후 다시 시도합니다..."
        sleep 2
    fi
done

# [Step 4] globals.yml (Global Configuration, 글로벌 설정 파일) 생성
MAIN_INTERFACE=$(ip -4 addr show | grep "$MY_PRIVATE_IP" | awk '{print $NF}' | head -1)
if ! ip link show eth1 >/dev/null 2>&1; then ip link add eth1 type dummy; ip link set eth1 up; fi

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

# [Step 5] Cinder (Block Storage Service, 블록 스토리지 서비스) 볼륨 구성
if ! vgs cinder >/dev/null 2>&1; then
    dd if=/dev/zero of=/var/lib/cinder.img bs=1M count=20000 status=none
    LOOP_DEV=$(losetup -f --show /var/lib/cinder.img)
    pvcreate $LOOP_DEV && vgcreate cinder $LOOP_DEV
fi

# [Step 6] 배포(Deploy) 실행
log "Bootstrap Servers (부트스트랩 서버) 진행..."
kolla-ansible bootstrap-servers -i all-in-one

log "Prechecks (사전 점검) 진행..."
kolla-ansible prechecks -i all-in-one

log "Deploy (배포) 진행..."
kolla-ansible deploy -i all-in-one

log "Post-deploy (배포 후 설정) 진행..."
kolla-ansible post-deploy -i all-in-one
pip install python-openstackclient

# 결과 출력
PASS=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
success "========================================================"
success " 설치 완료! (OpenStack 2025.1 Epoxy)"
success "========================================================"
echo -e " 웹 대시보드 : http://${MY_FLOATING_IP}"
echo -e " 아이디       : admin"
echo -e " 비밀번호     : ${PASS}"
success "========================================================"