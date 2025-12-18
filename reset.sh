#!/bin/bash

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
log_warn "  OpenStack 완전 초기화 (스왑 메모리 제외)"
log_warn "=========================================="
echo ""

###############################################################################
# 1. Kolla-Ansible 환경 정리
###############################################################################
log_info "[1/10] Kolla-Ansible 환경 정리..."

if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate 2>/dev/null || true
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it 2>/dev/null || true
    deactivate 2>/dev/null || true
fi

###############################################################################
# 2. Docker 컨테이너, 이미지, 네트워크, 볼륨 완전 정리
###############################################################################
log_info "[2/10] Docker 완전 정리..."

if command -v docker &>/dev/null; then
    # 모든 컨테이너 중지 및 삭제
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    
    # 네트워크 정리
    docker network prune -f 2>/dev/null || true
    
    # 볼륨 정리 
    docker volume prune -f 2>/dev/null || true
    
    # 이미지 정리 (모든 이미지 삭제)
    docker rmi -f $(docker images -aq) 2>/dev/null || true
    
    # 시스템 전체 정리 (캐시, 빌드 캐시 등)
    docker system prune -af --volumes 2>/dev/null || true
    
    # Docker 데이터 디렉토리 정리 (선택적 - 완전 초기화)
    # rm -rf /var/lib/docker/* 2>/dev/null || true
    
    log_success "Docker 정리 완료"
else
    log_info "Docker가 설치되어 있지 않음 (스킵)"
fi

###############################################################################
# 3. Cinder LVM 및 Loop Device 정리
###############################################################################
log_info "[3/10] Cinder LVM 및 루프백 디바이스 정리..."

# LVM 논리 볼륨 제거
lvremove -f cinder 2>/dev/null || true

# 볼륨 그룹 비활성화 및 삭제
vgchange -an cinder 2>/dev/null || true
vgremove -f cinder 2>/dev/null || true

# 모든 Cinder 관련 Loop Device 정리
for loop in /dev/loop*; do
    if [ -b "$loop" ]; then
        LOOP_INFO=$(losetup "$loop" 2>/dev/null || true)
        if echo "$LOOP_INFO" | grep -q cinder_data; then
            # PV 제거
            pvremove -f "$loop" 2>/dev/null || true
            # Loop device 해제
            losetup -d "$loop" 2>/dev/null || true
            log_info "  Loop device 해제: $loop"
        fi
    fi
done

# Cinder 이미지 파일 삭제
rm -f /var/lib/cinder_data.img 2>/dev/null || true

log_success "Cinder 정리 완료"

###############################################################################
# 4. 사용 중인 포트 정리
###############################################################################
log_info "[4/10] OpenStack 관련 포트 정리..."

PORTS=(
    3306    # MariaDB
    80      # HTTP
    443     # HTTPS
    5000    # Keystone
    8774    # Nova API
    8776    # Cinder API
    8778    # Placement
    9292    # Glance
    9696    # Neutron
    3260    # iSCSI
    6080    # NoVNC
    6443    # Kubernetes (if any)
    5672    # RabbitMQ AMQP
    15672   # RabbitMQ Management
    8004    # Heat API
    8000    # Heat CFN
    8080    # Swift/Horizon
    35357   # Keystone Admin (legacy)
)

for PORT in "${PORTS[@]}"; do
    fuser -k ${PORT}/tcp 2>/dev/null || true
done

log_success "포트 정리 완료"

###############################################################################
# 5. Kolla 관련 디렉토리 및 설정 파일 정리
###############################################################################
log_info "[5/10] Kolla 관련 디렉토리 정리..."

# Kolla 설정 디렉토리
rm -rf /etc/kolla 2>/dev/null || true

# Python 가상환경
rm -rf ~/kolla-venv 2>/dev/null || true

# Ansible 관련
rm -rf ~/.ansible 2>/dev/null || true
rm -rf /tmp/ansible_facts 2>/dev/null || true
rm -f ~/ansible.cfg 2>/dev/null || true

# Inventory 및 자격증명 파일
rm -f ~/all-in-one 2>/dev/null || true
rm -f ~/openstack-credentials.txt 2>/dev/null || true

# Kolla 로그 파일
rm -f /tmp/kolla-*.log 2>/dev/null || true

# OpenStack 클라이언트 설정
rm -f ~/admin-openrc.sh 2>/dev/null || true
rm -rf ~/.config/openstack 2>/dev/null || true

log_success "Kolla 디렉토리 정리 완료"

###############################################################################
# 6. systemd 서비스 정리
###############################################################################
log_info "[6/10] systemd 서비스 정리..."

# Cinder loop 서비스
systemctl stop cinder-loop.service 2>/dev/null || true
systemctl disable cinder-loop.service 2>/dev/null || true
rm -f /etc/systemd/system/cinder-loop.service 2>/dev/null || true

# Docker 서비스 재시작 (선택적)
# systemctl restart docker 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true

log_success "systemd 서비스 정리 완료"

###############################################################################
# 7. 네트워크 인터페이스 정리 (더미 인터페이스)
###############################################################################
log_info "[7/10] 더미 네트워크 인터페이스 정리..."

# eth1 더미 인터페이스 삭제
ip link delete eth1 2>/dev/null || true

# systemd-networkd 설정 파일 삭제
rm -f /etc/systemd/network/10-dummy0.netdev 2>/dev/null || true
rm -f /etc/systemd/network/20-dummy0.network 2>/dev/null || true

# OVS 브릿지 정리 (Open vSwitch)
if command -v ovs-vsctl &>/dev/null; then
    ovs-vsctl --if-exists del-br br-ex 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
    ovs-vsctl --if-exists del-br br-tun 2>/dev/null || true
fi

# systemd-networkd 재시작
systemctl restart systemd-networkd 2>/dev/null || true

log_success "네트워크 인터페이스 정리 완료"

###############################################################################
# 8. iptables/방화벽 규칙 초기화
###############################################################################
log_info "[8/10] iptables 규칙 정리..."

# iptables 규칙 초기화 (기본 정책 유지)
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true

# ip6tables 정리
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

log_success "iptables 정리 완료"

###############################################################################
# 9. 호스트 설정 초기화
###############################################################################
log_info "[9/10] 호스트 설정 정리..."

# /etc/hosts에서 openstack 관련 항목 제거
sed -i '/openstack/d' /etc/hosts 2>/dev/null || true

# 호스트명 초기화 (선택적)
# hostnamectl set-hostname localhost 2>/dev/null || true

log_success "호스트 설정 정리 완료"

###############################################################################
# 10. Nginx/SSL 정리 (도메인 설정했을 경우)
###############################################################################
log_info "[10/10] Nginx/SSL 설정 정리..."

# Nginx 기본 설정 복원
if [ -f /etc/nginx/sites-available/default ]; then
    rm -f /etc/nginx/sites-available/default 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
fi

# Let's Encrypt 인증서 정리 (선택적)
# rm -rf /etc/letsencrypt 2>/dev/null || true

# Certbot 크론잡 제거
rm -f /etc/cron.d/certbot-renew 2>/dev/null || true

log_success "Nginx/SSL 정리 완료"

###############################################################################
# 완료 메시지
###############################################################################
echo ""
log_success "=========================================="
log_success "  OpenStack 완전 초기화 완료!"
log_success "=========================================="
echo ""
log_info "제외된 항목:"
log_info "  - 스왑 메모리 (/swapfile)"
log_info "  - Docker 데몬 설치"
log_info "  - 기본 시스템 패키지"
echo ""
log_info "다음 명령으로 재설치할 수 있습니다:"
log_info "  ./v2.sh <외부_IP> [도메인명]"
echo ""

# 현재 스왑 상태 표시
log_info "현재 스왑 상태:"
free -h | grep -i swap
echo ""