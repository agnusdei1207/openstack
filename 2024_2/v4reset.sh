#!/bin/bash

# OpenStack 완전 삭제 스크립트 (Deep Clean)
# 작성해주신 코드 기반 + "좀비 프로세스/마운트 포인트/AppArmor" 정리 추가

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
log_warn "=========================================="
log_warn "  OpenStack 완전 초기화 (Nuclear Option)"
log_warn "=========================================="
echo ""

###############################################################################
# 1. Kolla-Ansible 환경 정리
###############################################################################
log_info "[1/12] Kolla-Ansible 환경 정리..."

if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    # 타임아웃 방지를 위해 yes 입력 자동화
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it 2>/dev/null || true
    deactivate 2>/dev/null || true
fi

###############################################################################
# 2. Docker 컨테이너, 이미지, 네트워크, 볼륨 완전 정리
###############################################################################
log_info "[2/12] Docker 완전 정리..."

if command -v docker &>/dev/null; then
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
    log_success "Docker 정리 완료"
else
    log_info "Docker가 설치되어 있지 않음 (스킵)"
fi

###############################################################################
# [추가] 3. 마운트 포인트 강제 해제 (매우 중요)
# Neutron/Nova가 남긴 마운트 때문에 폴더 삭제가 안 되는 경우 방지
###############################################################################
log_info "[3/12] 잔존 마운트 포인트 강제 해제..."
# /var/lib/kolla, /var/lib/docker 내부의 마운트 포인트 찾아서 해제
mount | grep -E "kolla|docker|neutron|nova" | awk '{print $3}' | while read -r mountpoint; do
    log_warn "마운트 해제 중: $mountpoint"
    umount -l "$mountpoint" 2>/dev/null || true
done

###############################################################################
# 4. Cinder LVM 및 Loop Device 정리
###############################################################################
log_info "[4/12] Cinder LVM 및 루프백 디바이스 정리..."

lvremove -f cinder 2>/dev/null || true
vgchange -an cinder 2>/dev/null || true
vgremove -f cinder 2>/dev/null || true

for loop in /dev/loop*; do
    if [ -b "$loop" ]; then
        LOOP_INFO=$(losetup "$loop" 2>/dev/null || true)
        if echo "$LOOP_INFO" | grep -q cinder_data; then
            pvremove -f "$loop" 2>/dev/null || true
            losetup -d "$loop" 2>/dev/null || true
            log_info "  Loop device 해제: $loop"
        fi
    fi
done
rm -f /var/lib/cinder_data.img 2>/dev/null || true

###############################################################################
# [보강] 5. 프로세스 및 포트 강제 사살 (Process Kill)
# 포트만 닫으면 좀비 프로세스가 살아남아 재설치를 방해함
###############################################################################
log_info "[5/12] OpenStack 관련 좀비 프로세스 사살..."

# 1. 포트 기준 종료 (작성하신 부분)
PORTS=(3306 80 443 5000 8774 8776 8778 9292 9696 3260 6080 6443 5672 15672 8004 8000 8080 35357)
for PORT in "${PORTS[@]}"; do
    fuser -k ${PORT}/tcp 2>/dev/null || true
done

# 2. [추가] 프로세스 이름 기준 강제 종료 (확인사살)
# qemu-kvm 프로세스까지 죽여야 Nova가 꼬이지 않음
PKILL_LIST="mysqld mariadbd rabbitmq beam.smp qemu-system-x86_64 libvirtd iscsid openvswitch"
for PROC in $PKILL_LIST; do
    pkill -9 -f "$PROC" 2>/dev/null || true
done
log_success "프로세스 정리 완료"

###############################################################################
# 6. Kolla 관련 디렉토리 및 설정 파일 정리
###############################################################################
log_info "[6/12] Kolla 관련 디렉토리 정리..."

rm -rf /etc/kolla 2>/dev/null || true
rm -rf /var/lib/kolla 2>/dev/null || true  # [추가] 데이터 디렉토리 삭제
rm -rf /var/lib/openstack 2>/dev/null || true
rm -rf ~/kolla-venv 2>/dev/null || true
rm -rf ~/.ansible 2>/dev/null || true
rm -rf /tmp/ansible_facts 2>/dev/null || true
rm -f ~/ansible.cfg 2>/dev/null || true
rm -f ~/all-in-one 2>/dev/null || true
rm -f ~/openstack-credentials.txt 2>/dev/null || true
rm -f /tmp/kolla-*.log 2>/dev/null || true
rm -f ~/admin-openrc.sh 2>/dev/null || true
rm -rf ~/.config/openstack 2>/dev/null || true

###############################################################################
# 7. systemd 서비스 정리
###############################################################################
log_info "[7/12] systemd 서비스 정리..."

systemctl stop cinder-loop.service 2>/dev/null || true
systemctl disable cinder-loop.service 2>/dev/null || true
rm -f /etc/systemd/system/cinder-loop.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

###############################################################################
# 8. 네트워크 인터페이스 및 OVS 정리
###############################################################################
log_info "[8/12] 네트워크 및 OVS 정리..."

ip link delete eth1 2>/dev/null || true
rm -f /etc/systemd/network/10-dummy0.netdev 2>/dev/null || true
rm -f /etc/systemd/network/20-dummy0.network 2>/dev/null || true

# OVS 초기화 (DB까지 정리해야 함)
if command -v ovs-vsctl &>/dev/null; then
    ovs-vsctl --if-exists del-br br-ex 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-tun 2>/dev/null || true
    # [추가] OVS DB 꼬임 방지
    systemctl restart openvswitch-switch 2>/dev/null || true
fi

###############################################################################
# 9. iptables/방화벽 규칙 초기화
###############################################################################
log_info "[9/12] iptables 규칙 정리..."

iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

###############################################################################
# [추가] 10. AppArmor 및 Libvirt 정리
# 재설치 시 VM 생성 실패(Permission Denied) 방지
###############################################################################
log_info "[10/12] AppArmor 및 Libvirt 잔재 정리..."
if command -v aa-teardown &>/dev/null; then
   aa-teardown 2>/dev/null || true
fi
rm -rf /etc/libvirt/qemu/* 2>/dev/null || true
rm -rf /var/lib/libvirt/* 2>/dev/null || true

###############################################################################
# 11. 호스트 설정 초기화
###############################################################################
log_info "[11/12] 호스트 설정 정리..."
sed -i '/openstack/d' /etc/hosts 2>/dev/null || true

###############################################################################
# 12. Nginx/SSL 정리
###############################################################################
log_info "[12/12] Nginx/SSL 설정 정리..."
if [ -f /etc/nginx/sites-available/default ]; then
    rm -f /etc/nginx/sites-available/default 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
fi
rm -f /etc/cron.d/certbot-renew 2>/dev/null || true

###############################################################################
# 완료
###############################################################################
echo ""
log_success "=========================================="
log_success "  OpenStack 완전 초기화 완료 (Clean)"
log_success "=========================================="
echo ""
log_info "이제 안정적인 v5 (Bobcat 2023.2) 스크립트를 실행하시면 됩니다."
log_info "스왑 메모리(/swapfile)와 Docker 패키지는 유지되었습니다."
echo ""