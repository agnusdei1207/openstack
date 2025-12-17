# Step 2: Kolla-Ansible 설치

> **Ubuntu 22.04 (Jammy)** + **Kolla-Ansible 19.x** + **OpenStack 2024.2 (Dalmatian)**

---

## 버전 호환성 참고

| Kolla-Ansible | Ubuntu            | OpenStack              | Ansible Core    |
| ------------- | ----------------- | ---------------------- | --------------- |
| 20.x          | 24.04 (Noble)     | 2025.1 (Epoxy)         | 2.16 ~ 2.17     |
| **19.x**      | **22.04 (Jammy)** | **2024.2 (Dalmatian)** | **2.16 ~ 2.17** |
| 18.x          | 22.04 (Jammy)     | 2024.1 (Caracal)       | unmaintained    |

---

## 목차

1. [Python 가상환경 생성](#1-python-가상환경-생성)
2. [Kolla-Ansible 설치](#2-kolla-ansible-설치)
3. [설정 파일 준비](#3-설정-파일-준비)
4. [네트워크 인터페이스 확인](#4-네트워크-인터페이스-확인)
5. [globals.yml 설정](#5-globalsyml-설정)
6. [패스워드 생성](#6-패스워드-생성)
7. [롤백 & 삭제](#롤백--삭제)

---

## 1. Python 가상환경 생성

```bash
# 시스템 Python과 분리된 독립적인 가상환경 생성
# (의존성 충돌 방지 및 깔끔한 관리를 위해)
python3 -m venv ~/kolla-venv

# 가상환경 활성화 (프롬프트에 (kolla-venv) 표시됨)
source ~/kolla-venv/bin/activate

# pip 최신 버전으로 업그레이드 (호환성 및 보안)
pip install -U pip
```

---

## 2. Kolla-Ansible 설치

```bash
# Kolla-Ansible 19.x와 호환되는 Ansible 버전 설치 (2.16 ~ 2.17)
pip install 'ansible-core>=2.16,<2.18'

# Kolla-Ansible 19.x 설치 (Ubuntu 22.04 + OpenStack 2024.2 Dalmatian)
pip install 'kolla-ansible>=19,<20'

# 설치 확인
kolla-ansible --version
ansible --version
```

---

## 3. 설정 파일 준비

```bash
# Kolla 설정 디렉토리 생성 (-p: 상위 디렉토리도 함께 생성)
sudo mkdir -p /etc/kolla

# 현재 사용자가 설정 파일을 수정할 수 있도록 소유권 변경
sudo chown $USER:$USER /etc/kolla

# 기본 설정 템플릿 복사 (globals.yml, passwords.yml 등)
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/

# 단일 노드용 인벤토리 파일 복사 (배포 대상 서버 목록)
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/
```

---

## 4. 네트워크 인터페이스 확인

```bash
# 네트워크 인터페이스 이름 확인 (eth0, ens3, enp0s3 등)
# globals.yml에서 이 값을 사용해야 함
ip a
```

**출력 예시:**

```
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc ...
    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0
```

위 예시에서는 `eth0`를 사용합니다.

---

## 5. globals.yml 설정

```bash
cat > /etc/kolla/globals.yml << 'EOF'
---
# 기본 설정 (Ubuntu 22.04 + Kolla-Ansible 19.x)
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2024.2"

# 네트워크 인터페이스 (ip a로 확인한 이름 입력) eth0, ens3, enp0s3 등
# Management + API 통신
network_interface: "eth0"

# 외부 네트워크 인터페이스 (Floating IP용 - Step 1에서 생성한 더미 인터페이스)
# Neutron이 이 인터페이스를 브릿지에 연결하여 외부 네트워크 제공
# 외부 네트워크, Floating IP
neutron_external_interface: "eth1"

# 내부 VIP 주소 (단일 노드는 localhost)
kolla_internal_vip_address: "127.0.0.1"

# 단일 노드 설정
enable_haproxy: "no"

# 핵심 서비스만 활성화 (메모리 절약)
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"

# Nova 가상화 타입 설정
# Step 1에서 egrep -c '(vmx|svm)' /proc/cpuinfo 결과에 따라 설정:
# - 1 이상 출력: KVM 지원 → 주석 유지 (자동 감지로 KVM 사용)
# - 0 출력: KVM 미지원 → 아래 주석 해제하여 QEMU 사용
# nova_compute_virt_type: "qemu"  # KVM 미지원 시에만 주석 해제!

# Neutron 설정
neutron_plugin_agent: "openvswitch"

# OVS 브릿지 매핑 (외부 네트워크용)
# physnet1: 외부 네트워크 생성 시 사용하는 물리 네트워크 이름
# br-ex: OVS 외부 브릿지 (eth1과 연결됨)
neutron_bridge_name: "br-ex"
neutron_external_flat_networks: "physnet1"

# 메모리 최적화 (8GB RAM 환경용)
mariadb_max_connections: "100"
rabbitmq_vm_memory_high_watermark: "0.4"
nova_max_concurrent_builds: "2"

# Docker 설정 (안정성)
docker_client_timeout: 300

# 불필요한 서비스 비활성화 (8GB RAM용)
enable_cinder: "no"
enable_swift: "no"
enable_heat: "no"
enable_ceilometer: "no"
enable_aodh: "no"
enable_barbican: "no"
enable_blazar: "no"
enable_cloudkitty: "no"
enable_designate: "no"
enable_freezer: "no"
enable_gnocchi: "no"
enable_grafana: "no"
enable_ironic: "no"
enable_magnum: "no"
enable_manila: "no"
enable_masakari: "no"
enable_mistral: "no"
enable_monasca: "no"
enable_murano: "no"
enable_octavia: "no"
enable_panko: "no"
enable_prometheus: "no"
enable_rally: "no"
enable_sahara: "no"
enable_searchlight: "no"
enable_senlin: "no"
enable_solum: "no"
enable_tacker: "no"
enable_tempest: "no"
enable_trove: "no"
enable_vitrage: "no"
enable_watcher: "no"
enable_zun: "no"
EOF
```

> ⚠️ **중요**: `network_interface` 값을 `ip a` 명령으로 확인한 실제 인터페이스 이름으로 변경하세요!

---

## 6. 패스워드 생성

```bash
# 모든 OpenStack 서비스용 랜덤 패스워드 자동 생성
# (passwords.yml 파일에 저장됨)
kolla-genpwd

# Horizon 웹 대시보드 로그인용 admin 패스워드 확인
grep keystone_admin_password /etc/kolla/passwords.yml
# 출력 예: keystone_admin_password: 000mm8zFveQtxRoiN4NBZUrRfw3mA56MgKQTbAhn
```

> 💡 **Tip**: 이 패스워드를 따로 메모해두세요! Horizon 로그인 시 필요합니다.

---

## 롤백 & 삭제

> 이 단계에서 문제가 발생했거나 초기화가 필요한 경우 아래 명령어를 사용하세요.

### Kolla 설정 파일 제거

```bash
# Kolla 설정 디렉토리 삭제
sudo rm -rf /etc/kolla

# 인벤토리 파일 삭제
rm -f ~/all-in-one
```

### Python 가상환경 완전 삭제

```bash
# 가상환경 비활성화 (현재 활성화된 경우)
deactivate

# 가상환경 디렉토리 삭제
rm -rf ~/kolla-venv

# bashrc에서 가상환경 활성화 명령어 제거 (추가한 경우)
sed -i '/kolla-venv/d' ~/.bashrc
sed -i '/admin-openrc/d' ~/.bashrc
```

### 패스워드 초기화

```bash
# 패스워드 파일만 재생성 (기존 패스워드 덮어쓰기)
kolla-genpwd

# 또는 특정 패스워드만 변경
# vi /etc/kolla/passwords.yml
```

### 처음부터 다시 설치

```bash
# 1. 가상환경 재생성
python3 -m venv ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip

# 2. Kolla-Ansible 재설치
pip install 'ansible-core>=2.16,<2.18'
pip install 'kolla-ansible>=19,<20'

# 3. 설정 파일 재복사
sudo mkdir -p /etc/kolla
sudo chown $USER:$USER /etc/kolla
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv/share/kolla-ansible/ansible/inventory/all-in-one ~/
```

---

**이전 단계**: [Step 1: OS 기본 설정](step1-os-setup.md)  
**다음 단계**: [Step 3: OpenStack 배포](step3-openstack-deploy.md)
