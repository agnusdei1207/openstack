#!/bin/bash
###############################################################################
# OpenStack AIO 설치 스크립트 (Ref: CodingPenguin Blog Version)
# NHN Cloud m2.c4m8 (8vCPU, 16GB RAM) + Ubuntu 22.04
#
# [블로그 내용 반영 및 수정 사항]
# 1. LVM Cinder 구성: 실제 파티션 대신 'loopback file'을 사용하여 가상 LVM 구현
# 2. Network: NIC가 1개인 환경을 고려해 Dummy Interface 자동 생성
# 3. User: 'stack' 유저 생성 대신 현재 root 권한으로 일원화 (복잡도 감소)
###############################################################################

# 1. 권한 및 인자 체크
if [ "$EUID" -ne 0 ]; then
    echo "❌ 오류: root 권한 필요 (sudo -i 실행 후 사용)"
    exit 1
fi

if [ -z "$1" ]; then
    echo "❌ 오류: 외부 IP를 입력해주세요."
    echo "사용법: $0 <외부_IP>"
    exit 1
fi

EXTERNAL_IP="$1"

# 환경변수 설정
export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_FORKS=4
export PIP_DEFAULT_TIMEOUT=100

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

###############################################################################
# 0. 필수 패키지 및 시간 동기화
###############################################################################
log_info "기초 패키지 설치 및 시간 동기화..."

apt update -qq
apt install -y python3-pip python3-venv git net-tools psmisc curl chrony lvm2 thin-provisioning-tools > /dev/null 2>&1

systemctl enable chrony > /dev/null 2>&1
systemctl restart chrony > /dev/null 2>&1

###############################################################################
# 1. 스마트 클린업 (Clean-up)
###############################################################################
echo -e "${YELLOW}>>> 기존 데이터 정리 (Cinder LVM 포함)...${NC}"
set +e 

# Kolla destroy
if [ -f ~/kolla-venv/bin/kolla-ansible ]; then
    source ~/kolla-venv/bin/activate
    kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it > /dev/null 2>&1
    deactivate
fi

# Docker 정리
if command -v docker &> /dev/null; then
    docker stop $(docker ps -a -q) > /dev/null 2>&1
    docker rm $(docker ps -a -q) > /dev/null 2>&1
    docker volume prune -f > /dev/null 2>&1
fi

# Cinder LVM 정리 (기존 루프백 해제)
vgremove -f cinder > /dev/null 2>&1
pvremove /dev/loop2 > /dev/null 2>&1
losetup -d /dev/loop2 > /dev/null 2>&1
rm -f /var/lib/cinder_data.img > /dev/null 2>&1

# 포트 정리
fuser -k 3306/tcp > /dev/null 2>&1
fuser -k 80/tcp > /dev/null 2>&1 
fuser -k 5000/tcp > /dev/null 2>&1
fuser -k 3260/tcp > /dev/null 2>&1 # iSCSI port

rm -rf /etc/kolla/* 2>/dev/null
rm -rf ~/kolla-venv 2>/dev/null

log_success "클린업 완료."

###############################################################################
# 2. 시스템 설정 (LVM Cinder 구성 포함)
###############################################################################
set -e 

log_info "Step 1: 시스템 및 스토리지 설정..."

# 스왑 16GB (Cinder 사용 시 메모리 부족 방지 필수)
if [ ! -f /swapfile ]; then
    log_info "16GB 스왑 파일 생성..."
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
fi

# [블로그 Step 2 대응] Cinder용 가상 LVM 생성 (Loopback Device)
# 클라우드에는 여분 파티션이 없으므로 파일로 대체합니다.
if ! vgs cinder &>/dev/null; then
    log_info "Cinder용 가상 디스크(20GB) 생성 중..."
    # 20GB 파일 생성
    dd if=/dev/zero of=/var/lib/cinder_data.img bs=1G count=20 status=none
    
    # 루프백 디바이스 연결 (/dev/loop2 사용 강제)
    losetup /dev/loop2 /var/lib/cinder_data.img
    
    # PV 및 VG 생성
    pvcreate /dev/loop2
    vgcreate cinder /dev/loop2
    
    # 재부팅 시 자동 마운트를 위한 서비스 등록
    cat << EOF > /etc/systemd/system/cinder-loop.service
[Unit]
Description=Setup Cinder Loopback Device
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/losetup /dev/loop2 /var/lib/cinder_data.img
ExecStart=/sbin/vgscan
ExecStart=/sbin/vgchange -ay cinder
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable cinder-loop.service > /dev/null 2>&1
    log_success "Cinder VG(Volume Group) 생성 완료."
fi

# 호스트명 & Hosts 파일
hostnamectl set-hostname openstack
if ! grep -q "openstack" /etc/hosts; then
    echo "127.0.0.1 openstack" >> /etc/hosts
fi

# [블로그 Network 대응] 더미 인터페이스 (eth1)
if ! ip link show eth1 &>/dev/null; then
    log_info "외부망용 더미 인터페이스(eth1) 생성..."
    ip link add eth1 type dummy
    ip link set eth1 up
    # 영구 설정
    mkdir -p /etc/systemd/network
    echo -e "[NetDev]\nName=eth1\nKind=dummy" > /etc/systemd/network/10-dummy0.netdev
    echo -e "[Match]\nName=eth1\n[Network]" > /etc/systemd/network/20-dummy0.network
    systemctl restart systemd-networkd > /dev/null 2>&1 || true
fi

# Docker 설치
if ! command -v docker &>/dev/null; then
    log_info "Docker 설치 중..."
    curl -fsSL https://get.docker.com | sh
fi

###############################################################################
# 3. Kolla-Ansible 설치 및 설정
###############################################################################
log_info "Step 2: Kolla-Ansible 구성..."

python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip > /dev/null
pip install 'ansible-core>=2.16,<2.18' 'kolla-ansible>=19,<20' > /dev/null

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

# globals.yml 작성 (Cinder 활성화)
cat > /etc/kolla/globals.yml << EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"

network_interface: "$MAIN_INTERFACE"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "127.0.0.1"
kolla_external_vip_address: "$EXTERNAL_IP"

# Cinder(볼륨) 활성화
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder"

enable_haproxy: "no"
enable_proxysql: "no"
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

# 최적화 및 타임아웃 방지
mariadb_max_connections: "100"
rabbitmq_vm_memory_high_watermark: "0.4"
nova_max_concurrent_builds: "2"
mariadb_wsrep_slave_threads: "2"
ansible_ssh_timeout: 120
docker_client_timeout: 600
haproxy_client_timeout: "5m"
haproxy_server_timeout: "5m"
nova_rpc_response_timeout: 180

# 모니터링/미터링 서비스 OFF (RAM 절약)
enable_ceilometer: "no"
enable_gnocchi: "no"
enable_grafana: "no"
enable_prometheus: "no"
enable_prometheus_openstack_exporter: "no"
enable_alertmanager: "no"
EOF

kolla-genpwd
ADMIN_PASSWORD=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')
echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" > ~/openstack-credentials.txt

###############################################################################
# 4. 배포 실행
###############################################################################
log_info "Step 3: OpenStack 배포 시작 (Cinder 포함)..."

# Ansible 최적화
cat > ~/ansible.cfg <<EOF
[defaults]
host_key_checking = False
pipelining = True
forks = 4
timeout = 60
EOF
export ANSIBLE_CONFIG=~/ansible.cfg

kolla-ansible install-deps > /dev/null
log_info "1. Bootstrap..."
kolla-ansible bootstrap-servers -i ~/all-in-one
log_info "2. Prechecks..."
kolla-ansible prechecks -i ~/all-in-one
log_info "3. Deploy (Cinder 설치로 인해 시간이 더 소요됩니다)..."
kolla-ansible deploy -i ~/all-in-one
log_info "4. Post-deploy..."
kolla-ansible post-deploy -i ~/all-in-one

pip install python-openstackclient > /dev/null

###############################################################################
# 완료
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       🎉 OpenStack + Cinder 설치 완료! 🎉       ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "📌 Horizon: http://$EXTERNAL_IP"
echo -e "📌 Admin PW: $ADMIN_PASSWORD"
echo -e "📌 Cinder Volume Group: Created on /var/lib/cinder_data.img (20GB)"
echo ""