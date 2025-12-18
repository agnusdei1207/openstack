#!/bin/bash

# ==========================================================
# NHN Cloud OpenStack 2024.2 (Dalmatian) All-in-One Installer
# ==========================================================
# 사용법: ./install.sh <사설_IP> <플로팅_IP> [플로팅_대역] [외부_게이트웨이]
# 예시: ./install.sh 192.168.0.92 133.186.132.232 133.186.132.0/24 133.186.132.1
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
    error "사용법: $0 <사설_IP> <플로팅_IP> [플로팅_대역] [외부_게이트웨이]"
    exit 1
fi

MY_PRIVATE_IP="$1"
MY_FLOATING_IP="$2"
FLOATING_NETWORK="${3:-$2/24}"
EXTERNAL_GATEWAY="${4:-$(echo $2 | cut -d'.' -f1-3).1}"
INTERNAL_NETWORK="192.168.100.0/24"
INTERNAL_GATEWAY="192.168.100.1"

log "=========================================="
log "OpenStack 2024.2 (Dalmatian) 설치 시작"
log "=========================================="
log "Private IP     : ${MY_PRIVATE_IP}"
log "Floating IP    : ${MY_FLOATING_IP}"
log "Floating Range : ${FLOATING_NETWORK}"
log "External GW    : ${EXTERNAL_GATEWAY}"

# ===========================================
# Phase 1: 시스템 초기화
# ===========================================
log "1. 초기화: 기존 환경 및 LVM 정리..."
if command -v docker &>/dev/null; then
    docker ps -aq | xargs -r docker stop >/dev/null 2>&1 || true
    docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume rm $(docker volume ls -q) >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
fi
if vgs cinder >/dev/null 2>&1; then vgremove -y cinder >/dev/null 2>&1 || true; fi
if pvs | grep -q "/dev/loop"; then pvs --noheading -o pv_name | grep "/dev/loop" | xargs -r pvremove -y >/dev/null 2>&1 || true; fi
for loop in $(losetup -a | grep "cinder.img" | cut -d: -f1); do losetup -d "$loop" >/dev/null 2>&1 || true; done

rm -rf /etc/kolla /var/lib/kolla /var/log/kolla ~/kolla-venv /root/.ansible /var/lib/cinder.img
mkdir -p /etc/kolla

# ===========================================
# Phase 2: 시스템 패키지 설치
# ===========================================
log "2. 시스템: 필수 패키지 설치..."
apt update -qq
apt install -y python3-dev python3-pip python3-venv git curl libffi-dev gcc libssl-dev \
               lsof libdbus-1-dev pkg-config libglib2.0-dev libcairo2-dev \
               build-essential libgirepository-2.0-dev gir1.2-glib-2.0

hostnamectl set-hostname openstack
sed -i '/openstack/d' /etc/hosts
echo "${MY_PRIVATE_IP} openstack" >> /etc/hosts

if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa; fi
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "StrictHostKeyChecking no" > ~/.ssh/config

if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ===========================================
# Phase 3: Python 가상환경 및 Kolla-Ansible
# ===========================================
log "3. VENV: 가상 환경 및 Kolla-Ansible 설치..."
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip wheel setuptools
pip install PyGObject dbus-python 'ansible-core>=2.16' docker
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2024.2

cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one .

# ===========================================
# Phase 4: Ansible Galaxy 컬렉션
# ===========================================
log "4. Galaxy: Ansible 컬렉션 설치..."
while true; do
    if kolla-ansible install-deps; then break; fi
    sleep 2
done

# ===========================================
# Phase 5: globals.yml 설정
# ===========================================
log "5. 설정: globals.yml 작성..."
MAIN_INTERFACE=$(ip -o -4 addr show | grep "$MY_PRIVATE_IP" | awk '{print $2}' | head -1)
if ! ip link show eth1 >/dev/null 2>&1; then ip link add eth1 type dummy && ip link set eth1 up; fi

cat > /etc/kolla/globals.yml <<EOF
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"

enable_haproxy_precheck: "no"

kolla_internal_vip_address: "${MY_PRIVATE_IP}"
network_interface: "${MAIN_INTERFACE}"
neutron_external_interface: "eth1"
kolla_external_vip_address: "${MY_PRIVATE_IP}"

enable_proxysql: "no"
enable_haproxy: "yes"
database_port: "3306"
mariadb_port: "3307"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
enable_horizon: "yes"
enable_prometheus: "no"
enable_grafana: "no"
enable_fluentd: "no"
nova_compute_virt_type: "qemu"
EOF
kolla-genpwd

# ===========================================
# Phase 6: Cinder LVM 구성
# ===========================================
log "6. 스토리지: Cinder 볼륨 그룹 구성..."
if ! vgs cinder >/dev/null 2>&1; then
    dd if=/dev/zero of=/var/lib/cinder.img bs=1M count=20000 status=none
    LOOP_DEV=$(losetup -f --show /var/lib/cinder.img)
    pvcreate $LOOP_DEV && vgcreate cinder $LOOP_DEV
fi

# ===========================================
# Phase 7: Kolla-Ansible 배포
# ===========================================
log "7. 배포: Bootstrap Servers..."
kolla-ansible bootstrap-servers -i all-in-one

log "Docker 엔진 안정화 대기..."
sleep 15

log "8. 배포: Deploy (약 20-40분 소요)..."
kolla-ansible deploy -i all-in-one

log "9. 배포: Post-deploy..."
kolla-ansible post-deploy -i all-in-one
pip install python-openstackclient

# ===========================================
# Phase 8: OpenStack 초기 설정
# ===========================================
log "10. 초기 설정: OpenStack 리소스 생성..."
source /etc/kolla/admin-openrc.sh

# Flavor 생성
openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny 2>/dev/null || true
openstack flavor create --ram 1024 --disk 10 --vcpus 1 m1.small 2>/dev/null || true
openstack flavor create --ram 2048 --disk 20 --vcpus 2 m1.medium 2>/dev/null || true
openstack flavor create --ram 4096 --disk 40 --vcpus 2 m1.large 2>/dev/null || true

# 외부 네트워크 (Provider Network)
if ! openstack network show external &>/dev/null; then
    openstack network create --external --provider-network-type flat --provider-physical-network physnet1 external
    POOL_START=$(echo $FLOATING_NETWORK | cut -d'.' -f1-3).100
    POOL_END=$(echo $FLOATING_NETWORK | cut -d'.' -f1-3).200
    openstack subnet create --network external --subnet-range "$FLOATING_NETWORK" --gateway "$EXTERNAL_GATEWAY" \
        --allocation-pool start=$POOL_START,end=$POOL_END --no-dhcp external-subnet
fi

# 내부 네트워크 (Tenant Network)
if ! openstack network show internal &>/dev/null; then
    openstack network create internal
    openstack subnet create --network internal --subnet-range "$INTERNAL_NETWORK" --gateway "$INTERNAL_GATEWAY" \
        --dns-nameserver 8.8.8.8 --dns-nameserver 8.8.4.4 internal-subnet
fi

# 라우터 생성 및 연결
if ! openstack router show router &>/dev/null; then
    openstack router create router
    openstack router set --external-gateway external router
    openstack router add subnet router internal-subnet
fi

# 보안 그룹 규칙 추가
DEFAULT_SG=$(openstack security group list --project admin -f value -c ID | head -1)
openstack security group rule create --protocol icmp "$DEFAULT_SG" 2>/dev/null || true
openstack security group rule create --protocol tcp --dst-port 22 "$DEFAULT_SG" 2>/dev/null || true
openstack security group rule create --protocol tcp --dst-port 80 "$DEFAULT_SG" 2>/dev/null || true
openstack security group rule create --protocol tcp --dst-port 443 "$DEFAULT_SG" 2>/dev/null || true

# SSH 키페어 생성
openstack keypair show mykey &>/dev/null || openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey

# Cirros 테스트 이미지
if ! openstack image show cirros &>/dev/null; then
    wget -q "http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img" -O /tmp/cirros.img
    openstack image create --disk-format qcow2 --container-format bare --public --file /tmp/cirros.img cirros
    rm -f /tmp/cirros.img
fi

# ===========================================
# 완료
# ===========================================
PASS=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')

success "=========================================="
success "OpenStack 2024.2 설치 완료!"
success "=========================================="
echo ""
log "Horizon Dashboard : http://${MY_FLOATING_IP}"
log "Admin ID          : admin"
log "Admin Password    : ${PASS}"
echo ""
log "생성된 리소스:"
echo "  - Flavors: m1.tiny, m1.small, m1.medium, m1.large"
echo "  - 외부 네트워크: external ($FLOATING_NETWORK)"
echo "  - 내부 네트워크: internal ($INTERNAL_NETWORK)"
echo "  - 라우터: router"
echo "  - 테스트 이미지: cirros"
echo "  - SSH 키: mykey"
echo ""
log "테스트 VM 생성:"
echo "  openstack server create --flavor m1.tiny --image cirros --network internal --key-name mykey test-vm"
echo "  openstack floating ip create external"
echo "  openstack server add floating ip test-vm <FLOATING_IP>"