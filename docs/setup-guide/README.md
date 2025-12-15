# Kolla-Ansible 단일 노드 OpenStack 설치 가이드

> NHN Cloud m2.c4m8 (4vCPU, 8GB RAM) 환경  
> Docker 컨테이너 기반으로 OS 레벨 설정 최소화  
> Ubuntu 22.04

---

## 📚 단계별 가이드

| 단계 | 제목                                                 | 설명                                  | 소요 시간 |
| :--: | ---------------------------------------------------- | ------------------------------------- | :-------: |
|  1   | [OS 기본 설정](step1-os-setup.md)                    | 스왑, 업데이트, 호스트명, Docker 설치 |   ~10분   |
|  2   | [Kolla-Ansible 설치](step2-kolla-ansible-install.md) | 가상환경, 패키지, 설정 파일 준비      |   ~10분   |
|  3   | [OpenStack 배포](step3-openstack-deploy.md)          | Bootstrap, Prechecks, Deploy          |   ~40분   |
|  4   | [사용 방법](step4-usage.md)                          | CLI 설치, Horizon 접속, 테스트 VM     |   ~15분   |
|  5   | [관리 명령어](step5-management.md)                   | 서비스 관리, 재시작, 삭제             |  참고용   |
|  6   | [트러블슈팅](step6-troubleshooting.md)               | 포트 목록, 일반적인 오류 해결         |  참고용   |

---

## ⚡ 빠른 시작

모든 단계를 한번에 실행하려면:

```bash
# Step 1: OS 설정
# 스왑 메모리 (16GB)
sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p

# 시스템 업데이트 & 필수 패키지
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-pip python3-venv git

# 호스트명 설정
sudo hostnamectl set-hostname openstack
echo "127.0.0.1 openstack" | sudo tee -a /etc/hosts

# 더미 인터페이스 생성 (eth1 - 외부 네트워크용)
sudo tee /etc/systemd/network/10-dummy0.netdev << 'EOF'
[NetDev]
Name=eth1
Kind=dummy
EOF

sudo tee /etc/systemd/network/20-dummy0.network << 'EOF'
[Match]
Name=eth1
[Network]
LinkLocalAddressing=no
EOF

sudo systemctl enable systemd-networkd && sudo systemctl restart systemd-networkd

# Docker 설치
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER && newgrp docker

# Step 2: Kolla-Ansible 설치
python3 -m venv ~/kolla-venv && source ~/kolla-venv/bin/activate
pip install -U pip 'ansible-core>=2.16,<2.18' 'kolla-ansible>=19,<20'
sudo mkdir -p /etc/kolla && sudo chown $USER:$USER /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/

# globals.yml 설정 (⚠️ network_interface는 ip a로 확인 후 수정!)
cat > /etc/kolla/globals.yml << 'EOF'
---
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"
network_interface: "eth0"
neutron_external_interface: "eth1"
kolla_internal_vip_address: "127.0.0.1"
enable_haproxy: "no"
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"
neutron_plugin_agent: "openvswitch"
neutron_bridge_name: "br-ex"
neutron_external_flat_networks: "physnet1"
EOF

kolla-genpwd

# Step 3: 배포 (20-40분 소요)
kolla-ansible install-deps
kolla-ansible bootstrap-servers -i ~/all-in-one
kolla-ansible prechecks -i ~/all-in-one
kolla-ansible deploy -i ~/all-in-one
kolla-ansible post-deploy -i ~/all-in-one
```

---

## 🔧 완전 삭제 (초기화)

> ⚠️ **주의**: 모든 OpenStack 컨테이너와 데이터 완전 삭제! 복구 불가능!

```bash
source ~/kolla-venv/bin/activate
kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it
```

---

## 📋 필수 포트 (NHN Cloud 보안 그룹)

```
TCP: 22, 80, 5000, 6080, 8774, 8775, 9292, 9696
```

자세한 포트 목록은 [트러블슈팅](step6-troubleshooting.md#필수-포트-목록) 참조.

---

## 📖 전체 문서

단일 파일 버전: [single-node-private-cloud-setup.md](../single-node-private-cloud-setup.md)
