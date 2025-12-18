#!/bin/bash

# OpenStack 2023.2 (Bobcat) 초기화 스크립트
# v5 설치 스크립트와 대응되는 리셋용입니다.

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

# Root 권한 확인
if [ "$EUID" -ne 0 ]; then
    log_error "root 권한 필요 (sudo -i 실행 후 사용)"
    exit 1
fi

echo ""
log_warn "========================================================"
log_warn "  ⚠️  경고: OpenStack (Bobcat) 환경을 초기화합니다."
log_warn "  모든 컨테이너, 볼륨, 데이터, 설정이 삭제됩니다."
log_warn "========================================================"
echo ""
read -p "정말 진행하시겠습니까? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "취소되었습니다."
    exit 1
fi

###############################################################################
# 1. Kolla-Ansible Destroy (정석적인 삭제 시도)
###############################################################################
log_info "[1/9] Kolla-Ansible Destroy 실행..."

if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    # venv가 살아있다면 destroy 명령어로 깔끔한 삭제 시도
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it 2>/dev/null || true
    deactivate 2>/dev/null || true
else
    log_warn "가상환경(~/kolla-venv)을 찾을 수 없어 강제 삭제로 넘어갑니다."
fi

###############################################################################
# 2. Docker 대청소 (컨테이너/볼륨/네트워크)
###############################################################################
log_info "[2/9] Docker 컨테이너 및 볼륨 강제 정리..."

if command -v docker &>/dev/null; then
    # 실행 중인 컨테이너 중지 및 삭제
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    
    # 볼륨 삭제 (DB 데이터 포함)
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    
    # 네트워크 삭제
    docker network prune -f 2>/dev/null || true
    
    log_success "Docker 정리 완료"
fi

###############################################################################
# 3. 마운트 포인트 강제 해제 (좀비 마운트 해결)
###############################################################################
log_info "[3/9] 잔존 마운트 포인트 해제..."

# Kolla/Docker 관련 마운트가 남아있으면 폴더 삭제가 안됨
mount | grep -E "kolla|docker|neutron|nova|cinder" | awk '{print $3}' | while read -r mountpoint; do
    log_warn "마운트 강제 해제: $mountpoint"
    umount -l "$mountpoint" 2>/dev/null || true
done

###############################################################################
# 4. Cinder (블록 스토리지) 정리
###############################################################################
log_info "[4/9] Cinder LVM 및 Loop Device 정리..."

# LVM 정리
lvremove -f cinder 2>/dev/null || true
vgchange -an cinder 2>/dev/null || true
vgremove -f cinder 2>/dev/null || true

# Loop Device 정리
for loop in /dev/loop*; do
    if [ -b "$loop" ]; then
        LOOP_INFO=$(losetup "$loop" 2>/dev/null || true)
        if echo "$LOOP_INFO" | grep -q cinder_data; then
            pvremove -f "$loop" 2>/dev/null || true
            losetup -d "$loop" 2>/dev/null || true
        fi
    fi
done

# 이미지 파일 삭제
rm -f /var/lib/cinder_data.img 2>/dev/null || true
# 서비스 제거
systemctl stop cinder-loop.service 2>/dev/null || true
rm -f /etc/systemd/system/cinder-loop.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

###############################################################################
# 5. 프로세스 및 포트 정리 (충돌 방지)
###############################################################################
log_info "[5/9] 잔존 프로세스 및 포트 정리..."

# 주요 포트 점유 해제
PORTS=(3306 80 443 5000 8774 8776 8778 9292 9696 6080 5672 15672)
for PORT in "${PORTS[@]}"; do
    fuser -k ${PORT}/tcp 2>/dev/null || true
done

# 좀비 프로세스 사살
PKILL_LIST="mysqld mariadbd rabbitmq-server beam.smp qemu-system-x86_64 libvirtd iscsid openvswitch"
for PROC in $PKILL_LIST; do
    pkill -9 -f "$PROC" 2>/dev/null || true
done

###############################################################################
# 6. 파일 및 디렉토리 삭제
###############################################################################
log_info "[6/9] 설정 파일 및 디렉토리 삭제..."

# Kolla 관련
rm -rf /etc/kolla 2>/dev/null || true
rm -rf /var/lib/kolla 2>/dev/null || true
rm -rf /var/lib/openstack 2>/dev/null || true

# 가상환경 (v5 스크립트가 만든 곳)
rm -rf ~/kolla-venv 2>/dev/null || true

# Ansible 관련
rm -rf ~/.ansible 2>/dev/null || true
rm -rf /tmp/ansible_facts 2>/dev/null || true
rm -f ~/ansible.cfg 2>/dev/null || true

# 생성된 파일들
rm -f ~/all-in-one 2>/dev/null || true
rm -f ~/openstack-credentials.txt 2>/dev/null || true
rm -f ~/admin-openrc.sh 2>/dev/null || true
rm -f /tmp/kolla-*.log 2>/dev/null || true

###############################################################################
# 7. 네트워크 인터페이스 정리
###############################################################################
log_info "[7/9] 네트워크 인터페이스 정리..."

# v5 스크립트에서 만든 eth1 더미 삭제
ip link delete eth1 2>/dev/null || true
rm -f /etc/systemd/network/10-dummy0.netdev 2>/dev/null || true
rm -f /etc/systemd/network/20-dummy0.network 2>/dev/null || true

# OVS 브릿지 삭제
if command -v ovs-vsctl &>/dev/null; then
    ovs-vsctl --if-exists del-br br-ex 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-tun 2>/dev/null || true
fi

###############################################################################
# 8. 방화벽 초기화
###############################################################################
log_info "[8/9] iptables 초기화..."
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -X 2>/dev/null || true

###############################################################################
# 9. 호스트 설정 복구
###############################################################################
log_info "[9/9] hosts 파일 정리..."
sed -i '/openstack/d' /etc/hosts 2>/dev/null || true

echo ""
log_success "=================================================="
log_success "  초기화 완료! (System Cleaned)"
log_success "=================================================="
log_info "이제 v5 설치 스크립트를 다시 실행할 수 있습니다."
echo ""