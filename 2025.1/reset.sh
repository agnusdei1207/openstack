#!/bin/bash

# ==========================================================
# OpenStack & Kolla Clean Reset Script (Factory Reset)
# ==========================================================
# 경고: 이 스크립트는 시스템의 Docker, OpenStack 데이터,
# 가상환경, 네트워크 설정 등을 모두 삭제합니다.
# ==========================================================

# 에러 무시하고 계속 진행 (삭제 목적이므로)
set +e

# 색상 정의
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${YELLOW}[RESET]${NC} $1"; }
done_msg() { echo -e "${GREEN}[DONE]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] root 권한으로 실행해주세요. (sudo -i)${NC}"
    exit 1
fi

echo -e "${RED}====================================================${NC}"
echo -e "${RED} [경고] 시스템을 OpenStack 설치 이전으로 되돌립니다.${NC}"
echo -e "${RED} Docker, 가상환경, Cinder 볼륨 데이터가 모두 삭제됩니다.${NC}"
echo -e "${RED}====================================================${NC}"
read -p "정말 진행하시겠습니까? (y/N): " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# 1. Kolla-Ansible Destroy (정석적인 삭제 시도)
log "1. Kolla Destroy 시도 (가상환경 이용)..."
if [ -d ~/kolla-venv ]; then
    source ~/kolla-venv/bin/activate
    kolla-ansible -i all-in-one destroy --yes-i-really-really-mean-it
    deactivate
else
    log "가상환경이 없어 건너뜁니다."
fi

# 2. 컨테이너 및 Docker 강제 정리
log "2. Docker 컨테이너 및 볼륨 강제 삭제..."
if command -v docker &>/dev/null; then
    # 모든 컨테이너 중지 및 삭제
    docker stop $(docker ps -aq) 2>/dev/null
    docker rm -f $(docker ps -aq) 2>/dev/null
    
    # 볼륨, 네트워크, 이미지 삭제
    docker volume prune -f
    docker network prune -f
    
    # MariaDB 관련 볼륨 확실히 제거
    rm -rf /var/lib/docker/volumes/mariadb
fi

# 3. Docker 패키지 삭제 (요청하신 대로 설치 이전 상태로)
log "3. Docker 패키지 및 데이터 완전 삭제..."
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
apt-get autoremove -y
rm -rf /var/lib/docker
rm -rf /etc/docker
rm -rf /var/run/docker.sock

# 4. Cinder LVM 및 Loop Device 정리
log "4. Cinder 볼륨 및 Loop Device 정리..."
# LVM 제거
vgremove -f cinder 2>/dev/null
pvremove -f /dev/loop* 2>/dev/null

# Loop Device 해제 (cinder.img와 연결된 것 찾아서 해제)
losetup -a | grep "cinder.img" | awk -F: '{print $1}' | while read loopdev; do
    log "Loop Device 해제: $loopdev"
    losetup -d $loopdev
done

# 이미지 파일 삭제
rm -f /var/lib/cinder.img

# 5. 네트워크 설정 복구
log "5. 네트워크 인터페이스(eth1, ovs) 정리..."
# 더미 인터페이스 삭제
ip link delete eth1 2>/dev/null

# Open vSwitch 잔여물 정리
if pidof ovs-vswitchd >/dev/null; then
    ovs-vsctl del-br br-ex 2>/dev/null
    ovs-vsctl del-br br-int 2>/dev/null
    ovs-vsctl del-br br-tun 2>/dev/null
fi
apt-get purge -y openvswitch-switch openvswitch-common
rm -rf /etc/openvswitch

# 6. 프로세스 강제 종료 (좀비 사살)
log "6. 좀비 프로세스 및 포트 점유 프로세스 사살..."
PKILL_LIST="qemu-system-x86_64 mysqld mariadbd proxysql beam.smp epmd nova- neutron- glance- cinder- keystone- heat- horizon"
for proc in $PKILL_LIST; do
    pkill -9 -f $proc 2>/dev/null
done

# 3306, 80, 443, 5000 등 주요 포트 강제 회수
kill -9 $(lsof -t -i:3306) 2>/dev/null
kill -9 $(lsof -t -i:80) 2>/dev/null
kill -9 $(lsof -t -i:443) 2>/dev/null

# 7. 파일 및 디렉토리 정리
log "7. 잔여 설정 파일 및 가상환경 삭제..."
rm -rf ~/kolla-venv
rm -rf /etc/kolla
rm -rf /var/lib/kolla
rm -rf /var/log/kolla
rm -rf /var/log/openstack
rm -rf /etc/ansible
rm -f ~/openstack-credentials.txt
rm -f ~/admin-openrc.sh
rm -f ./all-in-one

# 8. 스왑 파일 삭제 (선택사항 - 완전 초기화를 위해 삭제)
log "8. 스왑 메모리 해제 및 파일 삭제..."
if grep -q "/swapfile" /etc/fstab; then
    swapoff /swapfile 2>/dev/null
    sed -i '/\/swapfile/d' /etc/fstab
    rm -f /swapfile
fi

# 9. 호스트 hosts 파일 복구
log "9. /etc/hosts 정리..."
sed -i '/kolla/d' /etc/hosts
sed -i '/openstack/d' /etc/hosts

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN} 초기화 완료! 시스템이 깨끗해졌습니다.${NC}"
echo -e "${GREEN} 이제 install_nhn.sh 를 다시 실행하시면 됩니다.${NC}"
echo -e "${GREEN}========================================================${NC}"