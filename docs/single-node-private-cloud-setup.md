# Kolla-Ansible 단일 노드 OpenStack 설치 가이드

> NHN Cloud m2.c4m8 (4vCPU, 8GB RAM) 환경  
> Docker 컨테이너 기반으로 OS 레벨 설정 최소화  
> **Ubuntu 24.04 (Noble)** + **Kolla-Ansible 20.x** + **OpenStack 2025.1 (Epoxy)**

---

## 목차

1. [필수 포트 목록](#필수-포트-목록)
2. [최소 OS 설정](#최소-os-설정)
3. [Kolla-Ansible 설치](#kolla-ansible-설치)
4. [OpenStack 배포](#openstack-배포)
5. [사용 방법](#사용-방법)
6. [관리 명령어](#관리-명령어)

---

## 필수 포트 목록

### NHN Cloud 보안 그룹에서 열어야 할 포트

| 포트      | 프로토콜 | 서비스          | 용도                | 필수 |
| --------- | -------- | --------------- | ------------------- | ---- |
| **22**    | TCP      | SSH             | 서버 접속           | ✅   |
| **80**    | TCP      | Horizon         | 웹 대시보드         | ✅   |
| **443**   | TCP      | Horizon (HTTPS) | 웹 대시보드 (SSL)   | ⬜   |
| **5000**  | TCP      | Keystone        | 인증 API            | ✅   |
| **5672**  | TCP      | RabbitMQ        | 메시지 큐 (내부)    | ⬜   |
| **6080**  | TCP      | Nova VNC        | VM 콘솔 접속        | ✅   |
| **6081**  | TCP      | Nova SPICE      | VM 콘솔 (대안)      | ⬜   |
| **8774**  | TCP      | Nova API        | 컴퓨트 서비스       | ✅   |
| **8775**  | TCP      | Nova Metadata   | 인스턴스 메타데이터 | ✅   |
| **8776**  | TCP      | Cinder          | 블록 스토리지       | ⬜   |
| **9292**  | TCP      | Glance          | 이미지 서비스       | ✅   |
| **9696**  | TCP      | Neutron         | 네트워크 서비스     | ✅   |
| **3306**  | TCP      | MariaDB         | 데이터베이스 (내부) | ⬜   |
| **11211** | TCP      | Memcached       | 캐시 (내부)         | ⬜   |

### 요약: 외부 접근 필수 포트

```
TCP: 22, 80, 5000, 6080, 8774, 8775, 9292, 9696
```

### NHN Cloud 보안 그룹 설정 예시

```
방향: 인바운드
프로토콜: TCP
포트: 22,80,5000,6080,8774,8775,9292,9696
원격: 0.0.0.0/0 (또는 특정 IP)
```

> ⚠️ **주의**: 프로덕션 환경에서는 `0.0.0.0/0` 대신 특정 IP 대역만 허용하세요.

---

## 최소 OS 설정

> OS 레벨 설정을 최소화하고 Kolla-Ansible이 나머지를 처리합니다.

### 1. 스왑 메모리 설정 (16GB)

> 8GB RAM 환경에서 OpenStack 컨테이너들이 메모리를 많이 사용하므로,  
> 스왑을 추가하여 OOM(Out of Memory) 방지

```bash
# 16GB 크기의 스왑 파일 생성 (RAM 부족 시 디스크를 메모리처럼 사용)
sudo fallocate -l 16G /swapfile

# 보안을 위해 root만 읽기/쓰기 가능하도록 권한 설정
sudo chmod 600 /swapfile

# 스왑 파일 포맷 (리눅스 스왑 영역으로 초기화)
sudo mkswap /swapfile

# 스왑 활성화 (현재 세션에서 즉시 사용 가능)
sudo swapon /swapfile

# 재부팅 후에도 스왑이 자동 마운트되도록 fstab에 등록
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Swappiness=10: RAM이 90% 이상 찼을 때만 스왑 사용 (성능 최적화)
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p  # 설정 즉시 적용

# 스왑 설정 확인
free -h
sudo swapon --show
```

### 2. 시스템 업데이트 & 필수 패키지

```bash
# 패키지 목록 갱신 및 보안 업데이트 적용
sudo apt update && sudo apt upgrade -y

# Kolla-Ansible 설치에 필요한 Python 도구 및 Git 설치
# - python3-pip: Python 패키지 설치용
# - python3-venv: 가상환경 생성용
# - git: Kolla-Ansible 의존성 설치 시 필요
sudo apt install -y python3-pip python3-venv git
```

### 3. 호스트명 설정

> OpenStack 서비스들은 호스트명을 사용하여 서로 통신합니다.  
> 호스트명이 제대로 설정되지 않으면 서비스 간 연결 오류가 발생합니다.

```bash
# 시스템 호스트명을 'openstack'으로 설정
# (각 서비스가 이 이름으로 자신을 식별)
sudo hostnamectl set-hostname openstack

# /etc/hosts에 호스트명 매핑 추가
# (호스트명 → IP 변환이 가능하도록 로컬 DNS 역할)
echo "127.0.0.1 openstack" | sudo tee -a /etc/hosts
```

**끝!** 나머지는 Kolla-Ansible이 처리합니다 (Docker 포함).

---

## Kolla-Ansible 설치

> ⚠️ **버전 호환성 주의**
>
> | Kolla-Ansible | Ubuntu            | OpenStack        |
> | ------------- | ----------------- | ---------------- |
> | **20.x**      | **24.04 (Noble)** | 2025.1 (Epoxy)   |
> | 18.x          | 22.04 (Jammy)     | 2024.1 (Caracal) |
>
> 이 가이드는 **Ubuntu 24.04 + Kolla-Ansible 20.x** 기준입니다.

### 1. Python 가상환경 생성

```bash
# 시스템 Python과 분리된 독립적인 가상환경 생성
# (의존성 충돌 방지 및 깔끔한 관리를 위해)
python3 -m venv ~/kolla-venv

# 가상환경 활성화 (프롬프트에 (kolla-venv) 표시됨)
source ~/kolla-venv/bin/activate

# pip 최신 버전으로 업그레이드 (호환성 및 보안)
pip install -U pip
```

### 2. Kolla-Ansible 설치

```bash
# Kolla-Ansible과 호환되는 Ansible 버전 설치 (2.16 이상 2.18 미만)
pip install 'ansible-core>=2.16,<2.18'

# Kolla-Ansible 최신 버전 설치 (Ubuntu 24.04 전용)
# Ubuntu 22.04를 사용한다면: pip install 'kolla-ansible>=18,<19'
pip install kolla-ansible
```

### 3. 설정 파일 준비

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

### 4. globals.yml 설정

```bash
# 네트워크 인터페이스 이름 확인 (eth0, ens3 등)
# globals.yml에서 이 값을 사용해야 함
ip a
```

```bash
cat > /etc/kolla/globals.yml << 'EOF'
---
# 기본 설정
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "2025.1"  # Ubuntu 24.04 + Kolla 20.x = 2025.1 (Epoxy)

# 네트워크 인터페이스 (ip a로 확인한 이름 입력, 예: eth0, ens3, enp0s3 등)
network_interface: "eth0"
neutron_external_interface: "eth0"
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

# Nova 설정 (중첩 가상화 불가 시 qemu 사용)
nova_compute_virt_type: "qemu"

# Neutron 설정
neutron_plugin_agent: "openvswitch"
EOF
```

### 5. 패스워드 생성

```bash
# 모든 OpenStack 서비스용 랜덤 패스워드 자동 생성
# (passwords.yml 파일에 저장됨)
kolla-genpwd

# Horizon 웹 대시보드 로그인용 admin 패스워드 확인
grep keystone_admin_password /etc/kolla/passwords.yml
# keystone_admin_password: dtxb5v22dpCb1OQtBFQ6iYQAHix3qmmdL3ou9W2h
```

---

## OpenStack 배포

### 1. Ansible 의존성 설치

```bash
# Kolla-Ansible 실행에 필요한 Ansible Galaxy 역할들 설치
kolla-ansible install-deps
# 에러 없는지 설치 리스트 확인
ansible-galaxy collection list
```

### 2. Bootstrap (Docker 자동 설치)

```bash
# 서버 초기 설정 (Docker 설치, 사용자 권한 설정 등)
# 명령어가 먼저, -i 옵션은 뒤에 (Kolla-Ansible 20.x 문법)
kolla-ansible bootstrap-servers -i ~/all-in-one
```

> ✅ 이 단계에서 Docker가 자동으로 설치됩니다!

### 3. 사전 검증

```bash
# 배포 전 시스템 요구사항 검증 (포트 충돌, 설정 오류 등 체크)
kolla-ansible prechecks -i ~/all-in-one
```

> 에러가 있으면 수정 후 다시 실행

### 4. 배포 (20-40분 소요)

```bash
# 실제 OpenStack 컨테이너들 배포 (모든 서비스 설치 및 실행)
kolla-ansible deploy -i ~/all-in-one
```

### 5. 후처리

```bash
# 배포 후 작업 (admin-openrc.sh 생성 등 환경 설정 파일 생성)
kolla-ansible post-deploy -i ~/all-in-one
```

---

## 사용 방법

### OpenStack CLI 설치

```bash
# 명령어로 OpenStack 리소스 관리하기 위한 CLI 도구 설치
pip install python-openstackclient
```

### 환경변수 로드

```bash
# OpenStack API 인증 정보 환경변수 로드
# (이후 openstack 명령어 사용 시 자동 인증)
source /etc/kolla/admin-openrc.sh
```

### 동작 확인

```bash
# 등록된 서비스 목록 확인 (Keystone, Glance, Nova 등)
openstack service list

# API 엔드포인트 URL 목록 확인
openstack endpoint list

# 가상화 호스트 상태 확인 (VM 실행 가능 여부)
openstack hypervisor list
```

### Horizon 대시보드 접속

```
URL: http://<서버_Public_IP>:80
계정: admin
비밀번호: grep keystone_admin_password /etc/kolla/passwords.yml 결과값
```

### 테스트 VM 생성

```bash
# 경량 테스트용 Linux 이미지 다운로드 (15MB)
wget http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img

# Glance에 이미지 등록 (모든 프로젝트에서 사용 가능하도록 public 설정)
openstack image create "cirros" \
  --file cirros-0.6.2-x86_64-disk.img \
  --disk-format qcow2 \
  --container-format bare \
  --public

# VM 사양 정의 (RAM 512MB, 디스크 1GB, 1 vCPU)
openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny

# VM이 사용할 가상 네트워크 생성
openstack network create demo-net

# 서브넷 생성 (IP 대역, 게이트웨이, DNS 설정)
openstack subnet create --network demo-net \
  --subnet-range 192.168.100.0/24 \
  --gateway 192.168.100.1 \
  --dns-nameserver 8.8.8.8 \
  demo-subnet

# VM 인스턴스 생성
openstack server create --flavor m1.tiny \
  --image cirros \
  --network demo-net \
  test-vm

# VM 상태 확인 (ACTIVE면 정상)
openstack server list
```

---

## 관리 명령어

### 서비스 상태 확인

```bash
# 실행 중인 OpenStack 컨테이너 목록 확인
docker ps

# 특정 서비스 컨테이너 로그 확인 (문제 발생 시 디버깅용)
docker logs nova_compute
docker logs neutron_server
docker logs horizon
```

### 재시작 및 재설정

```bash
# globals.yml 수정 후 변경사항 적용 (전체 재배포 없이)
kolla-ansible reconfigure -i ~/all-in-one

# 특정 서비스만 재배포 (--tags로 서비스 지정)
kolla-ansible deploy -i ~/all-in-one --tags nova
kolla-ansible deploy -i ~/all-in-one --tags horizon
```

### 완전 삭제 (초기화)

```bash
# ⚠️ 주의: 모든 OpenStack 컨테이너와 데이터 완전 삭제!
kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it
```

### 업그레이드

```bash
# Kolla-Ansible 최신 버전으로 업그레이드
pip install -U kolla-ansible

# OpenStack 서비스들 업그레이드 (다운타임 최소화)
kolla-ansible upgrade -i ~/all-in-one
```

---

## 트러블슈팅

### 배포 실패 시

```bash
# 핵심 서비스 컨테이너 로그 확인
docker logs mariadb      # 데이터베이스
docker logs rabbitmq     # 메시지 큐
docker logs keystone     # 인증 서비스

# 문제 있는 컨테이너 재시작
docker restart keystone
```

### 메모리 부족 시

```bash
# RAM 및 스왔 사용량 확인
free -h

# 컨테이너별 리소스 사용량 확인 (메모리 많이 쓰는 컨테이너 식별)
docker stats --no-stream
```

### VNC 콘솔 접속 안될 때

```bash
# VNC 프록시 포트가 열려있는지 확인
sudo netstat -tlnp | grep 6080

# VNC 프록시 컨테이너 로그 확인
docker logs nova_novncproxy
```

---

## 체크리스트

- [ ] NHN Cloud 보안 그룹 포트 오픈 (22, 80, 5000, 6080, 8774, 8775, 9292, 9696)
- [ ] 스왑 16GB 설정
- [ ] Kolla-Ansible 설치
- [ ] globals.yml 네트워크 인터페이스 확인
- [ ] 패스워드 생성 (kolla-genpwd)
- [ ] Bootstrap 실행
- [ ] Deploy 실행
- [ ] Horizon 대시보드 접속 확인

---

> 📅 문서 작성일: 2025-12-15  
> 🎯 대상 환경: NHN Cloud m2.c4m8 (4vCPU, 8GB RAM)
