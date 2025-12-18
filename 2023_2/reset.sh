#!/bin/bash

# OpenStack 2023.2 (Bobcat) 초기화 스크립트 v5.2
# 강화된 좀비 프로세스 제거 (ProxySQL, MariaDB, 3306 Port) 포함

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
log_warn "  ⚠️  [강력 초기화] OpenStack 환경을 삭제합니다."
log_warn "  모든 컨테이너, 볼륨, 좀비 프로세스가 강제 종료됩니다."
log_warn "========================================================"
echo ""
read -p "정말 진행하시겠습니까? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "취소되었습니다."
    exit 1
fi

###############################################################################
# 1. Kolla-Ansible Destroy
###############################################################################
log_info "[1/10] Kolla-Ansible Destroy 실행..."

if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it 2>/dev/null || true
    deactivate 2>/dev/null || true
else
    log_warn "가상환경을 찾을 수 없어 수동 삭제로 진행합니다."
fi

###############################################################################
# 2. Docker 대청소 (컨테이너/볼륨/네트워크)
###############################################################################
log_info "[2/10] Docker 컨테이너 및 볼륨 강제 정리..."

if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    log_success "Docker 정리 완료"
fi

###############################################################################
# 3. 마운트 포인트 강제 해제
###############################################################################
log_info "[3/10] 잔존 마운트 포인트 해제..."

mount | grep -E "kolla|docker|neutron|nova|cinder" | awk '{print $3}' | while read -r mountpoint; do
    log_warn "마운트 강제 해제: $mountpoint"
    umount -l "$mountpoint" 2>/dev/null || true
done

###############################################################################
# 4. Cinder (블록 스토리지) 정리
###############################################################################
log_info "[4/10] Cinder LVM 및 Loop Device 정리..."

lvremove -f cinder 2>/dev/null || true
vgchange -an cinder 2>/dev/null || true
vgremove -f cinder 2>/dev/null || true

for loop in /dev/loop*; do
    if [ -b "$loop" ]; then
        LOOP_INFO=$(losetup "$loop" 2>/dev/null || true)
        if echo "$LOOP_INFO" | grep -q cinder_data; then
            pvremove -f "$loop" 2>/dev/null || true
            losetup -d "$loop" 2>/dev/null || true
        fi
    fi
done

rm -f /var/lib/cinder_data.img 2>/dev/null || true
systemctl stop cinder-loop.service 2>/dev/null || true
rm -f /etc/systemd/system/cinder-loop.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

###############################################################################
# [강화됨] 5. 좀비 프로세스 확인 사살 (Zombie Killer)
###############################################################################
log_info "[5/10] 좀비 프로세스 및 포트 강제 사살 (강화됨)..."

# 1. 3306 포트 점유 프로세스 우선 사살 (lsof 사용)
if command -v lsof &>/dev/null; then
    PIDS=$(lsof -t -i:3306)
    if [ -n "$PIDS" ]; then
        log_warn "포트 3306 점유 프로세스 발견 ($PIDS). 강제 종료합니다."
        echo "$PIDS" | xargs -r kill -9 2>/dev/null || true
    fi
fi

# 2. 주요 포트 정리
PORTS=(3306 80 443 5000 8774 8776 8778 9292 9696 6080 5672 15672)
for PORT in "${PORTS[@]}"; do
    fuser -k -9 ${PORT}/tcp 2>/dev/null || true
done

# 3. 프로세스 이름 기반 사살 (ProxySQL, HAProxy 포함)
# Proxysql이 가장 큰 문제였으므로 명시적으로 포함
PKILL_LIST="proxysql haproxy keepalived mysqld mariadbd rabbitmq-server beam.smp qemu-system-x86_64 libvirtd iscsid openvswitch neutron- nova- glance- cinder-"

log_info "OpenStack 관련 프로세스 검색 및 종료 중..."
for PROC in $PKILL_LIST; do
    pkill -9 -f "$PROC" 2>/dev/null || true
done

# 4. 최후의 수단: 'kolla'가 포함된 모든 프로세스 종료 (설치 스크립트 제외)
# 주의: 현재 스크립트 이름이 kolla를 포함하면 안 됨
ps aux | grep "kolla" | grep -v "grep" | grep -v "$0" | awk '{print $2}' | xargs -r kill -9 2>/dev/null || true

log_success "프로세스 정리 완료"

###############################################################################
# 6. 파일 및 디렉토리 삭제
###############################################################################
log_info "[6/10] 설정 파일 및 디렉토리 삭제..."

rm -rf /etc/kolla 2>/dev/null || true
rm -rf /var/lib/kolla 2>/dev/null || true
rm -rf /var/lib/openstack 2>/dev/null || true
rm -rf ~/kolla-venv 2>/dev/null || true
rm -rf ~/.ansible 2>/dev/null || true
rm -rf /tmp/ansible_facts 2>/dev/null || true
rm -f ~/ansible.cfg 2>/dev/null || true
rm -f ~/all-in-one 2>/dev/null || true
rm -f ~/openstack-credentials.txt 2>/dev/null || true
rm -f ~/admin-openrc.sh 2>/dev/null || true
rm -f /tmp/kolla-*.log 2>/dev/null || true
rm -rf /var/lib/docker/volumes/mariadb 2>/dev/null || true

###############################################################################
# 7. 네트워크 인터페이스 정리
###############################################################################
log_info "[7/10] 네트워크 인터페이스 정리..."

ip link delete eth1 2>/dev/null || true
rm -f /etc/systemd/network/10-dummy0.netdev 2>/dev/null || true
rm -f /etc/systemd/network/20-dummy0.network 2>/dev/null || true

if command -v ovs-vsctl &>/dev/null; then
    ovs-vsctl --if-exists del-br br-ex 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-tun 2>/dev/null || true
fi

###############################################################################
# 8. 방화벽 초기화
###############################################################################
log_info "[8/10] iptables 초기화..."
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -X 2>/dev/null || true

###############################################################################
# 9. AppArmor 및 Libvirt 정리 (VM 생성 에러 방지)
###############################################################################
log_info "[9/10] AppArmor 및 Libvirt 정리..."
if command -v aa-teardown &>/dev/null; then
   aa-teardown 2>/dev/null || true
fi
rm -rf /etc/libvirt/qemu/* 2>/dev/null || true
rm -rf /var/lib/libvirt/* 2>/dev/null || true

###############################################################################
# 10. 호스트 설정 복구 및 검증
###############################################################################
log_info "[10/10] 마무리 및 검증..."
sed -i '/openstack/d' /etc/hosts 2>/dev/null || true

# 최종 포트 확인
if netstat -tulpn 2>/dev/null | grep -q ":3306"; then
    log_error "경고: 3306 포트가 아직도 사용 중입니다!"
    netstat -tulpn | grep 3306
else
    log_success "3306 포트가 깨끗합니다."
fi

echo ""
log_success "=================================================="
log_success "  초기화 완료! (Zombie Processes Killed)"
log_success "=================================================="
log_info "이제 v5.2 설치 스크립트(ProxySQL OFF 버전)를 실행하세요."
echo ""