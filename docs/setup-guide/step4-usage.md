# Step 4: 사용 방법

> OpenStack CLI 설치 및 기본 사용법

---

## 목차

1. [OpenStack CLI 설치](#openstack-cli-설치)
2. [환경변수 로드](#환경변수-로드)
3. [동작 확인](#동작-확인)
4. [Horizon 대시보드 접속](#horizon-대시보드-접속)
5. [테스트 VM 생성](#테스트-vm-생성)
6. [롤백 & 삭제](#롤백--삭제)

---

## OpenStack CLI 설치

```bash
# 가상환경이 활성화된 상태에서 실행
source ~/kolla-venv/bin/activate

# 명령어로 OpenStack 리소스 관리하기 위한 CLI 도구 설치
pip install python-openstackclient

# CLI 설치 확인
openstack --version
```

---

## 환경변수 로드

```bash
# OpenStack API 인증 정보 환경변수 로드
# (이후 openstack 명령어 사용 시 자동 인증)
source /etc/kolla/admin-openrc.sh
```

> 💡 **Tip**: 매번 실행하기 번거로우면 `~/.bashrc`에 추가하세요:
>
> ```bash
> echo "source ~/kolla-venv/bin/activate" >> ~/.bashrc
> echo "source /etc/kolla/admin-openrc.sh" >> ~/.bashrc
> ```

---

## 동작 확인

```bash
# 등록된 서비스 목록 확인 (Keystone, Glance, Nova 등)
openstack service list
```

**정상 출력:**

```
+----------------------------------+----------+----------------+
| ID                               | Name     | Type           |
+----------------------------------+----------+----------------+
| xxx                              | keystone | identity       |
| xxx                              | glance   | image          |
| xxx                              | nova     | compute        |
| xxx                              | neutron  | network        |
| xxx                              | placement| placement      |
+----------------------------------+----------+----------------+
```

```bash
# API 엔드포인트 URL 목록 확인
openstack endpoint list

# 가상화 호스트 상태 확인 (VM 실행 가능 여부)
openstack hypervisor list
```

**정상 출력:**

```
+----+---------------------+-----------------+-------+-------+
| ID | Hypervisor Hostname | Hypervisor Type | State | Status|
+----+---------------------+-----------------+-------+-------+
| 1  | openstack           | QEMU            | up    | enabled|
+----+---------------------+-----------------+-------+-------+
```

---

## Horizon 대시보드 접속

```
URL: http://<서버_Public_IP>:80
계정: admin
비밀번호: grep keystone_admin_password /etc/kolla/passwords.yml 결과값
```

**접속 확인:**

1. 브라우저에서 `http://<Public_IP>:80` 접속
2. Domain: `Default`
3. User Name: `admin`
4. Password: (위에서 확인한 패스워드)

> ⚠️ **접속 안될 때**: NHN Cloud 보안 그룹에서 포트 80이 열려있는지 확인하세요!

---

## 테스트 VM 생성

### 이미지 다운로드 및 등록

```bash
# 환경변수 로드 확인
source /etc/kolla/admin-openrc.sh

# 경량 테스트용 Linux 이미지 다운로드 (15MB)
wget http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img

# Glance에 이미지 등록 (모든 프로젝트에서 사용 가능하도록 public 설정)
openstack image create "cirros" \
  --file cirros-0.6.2-x86_64-disk.img \
  --disk-format qcow2 \
  --container-format bare \
  --public

# 이미지 등록 확인
openstack image list
```

### Flavor 생성

```bash
# VM 사양 정의 (RAM 512MB, 디스크 1GB, 1 vCPU)
openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny

# Flavor 확인
openstack flavor list
```

### 네트워크 생성

#### 외부 네트워크 생성 (Provider Network - eth1 사용)

```bash
# 외부 네트워크 생성 (eth1 더미 인터페이스와 연결됨)
# --provider-physical-network: physnet1은 OVS 브릿지에 연결된 물리 네트워크 이름
# --provider-network-type: flat 또는 vlan 사용 가능
openstack network create --external \
  --provider-physical-network physnet1 \
  --provider-network-type flat \
  external-net

# 외부 서브넷 생성 (Floating IP 할당 범위)
# 실제 환경에서는 할당 가능한 IP 범위로 변경하세요
openstack subnet create --network external-net \
  --subnet-range 10.0.0.0/24 \
  --gateway 10.0.0.1 \
  --allocation-pool start=10.0.0.100,end=10.0.0.200 \
  --no-dhcp \
  external-subnet
```

> 💡 **NHN Cloud 환경**: 실제 외부 IP 대역이 없으면 테스트용 사설 IP 대역 사용

#### 내부 네트워크 생성 (VM용 사설 네트워크)

```bash
# VM이 사용할 가상 네트워크 생성
openstack network create demo-net

# 서브넷 생성 (IP 대역, 게이트웨이, DNS 설정)
openstack subnet create --network demo-net \
  --subnet-range 192.168.100.0/24 \
  --gateway 192.168.100.1 \
  --dns-nameserver 8.8.8.8 \
  demo-subnet
```

#### 라우터 생성 (내부 ↔ 외부 연결)

```bash
# 라우터 생성
openstack router create demo-router

# 라우터에 외부 네트워크 게이트웨이 설정
openstack router set --external-gateway external-net demo-router

# 라우터에 내부 서브넷 연결
openstack router add subnet demo-router demo-subnet

# 라우터 상태 확인
openstack router show demo-router
```

#### 네트워크 확인

```bash
# 네트워크 확인
openstack network list
openstack subnet list
openstack router list
```

### VM 인스턴스 생성

```bash
# VM 인스턴스 생성
openstack server create --flavor m1.tiny \
  --image cirros \
  --network demo-net \
  test-vm

# VM 상태 확인 (ACTIVE면 정상)
openstack server list
```

**정상 출력:**

```
+--------------------------------------+---------+--------+----------------------+--------+---------+
| ID                                   | Name    | Status | Networks             | Image  | Flavor  |
+--------------------------------------+---------+--------+----------------------+--------+---------+
| xxx                                  | test-vm | ACTIVE | demo-net=192.168.100.X | cirros | m1.tiny |
+--------------------------------------+---------+--------+----------------------+--------+---------+
```

### VNC 콘솔 접속

```bash
# VM 콘솔 URL 확인 (VNC 접속용)
openstack console url show test-vm
```

**VNC 콘솔 접속:**

1. 위 명령어로 나온 URL을 브라우저에서 열기
2. 또는 Horizon 대시보드 → Compute → Instances → test-vm → Console 탭

**VM 로그인 정보 (CirrOS):**

```
Username: cirros
Password: gocubsgo
```

---

## 롤백 & 삭제

> 생성한 리소스를 삭제하거나 초기화하는 방법

### 테스트 VM 삭제

```bash
# 환경변수 로드
source /etc/kolla/admin-openrc.sh

# VM 삭제
openstack server delete test-vm

# 삭제 확인
openstack server list
```

### 네트워크 삭제

```bash
# 1. 라우터에서 서브넷 제거
openstack router remove subnet demo-router demo-subnet

# 2. 라우터 외부 게이트웨이 제거
openstack router unset --external-gateway demo-router

# 3. 라우터 삭제
openstack router delete demo-router

# 4. 내부 네트워크 삭제
openstack subnet delete demo-subnet
openstack network delete demo-net

# 5. 외부 네트워크 삭제 (선택사항 - 다른 프로젝트에서 사용 중일 수 있음)
openstack subnet delete external-subnet
openstack network delete external-net

# 삭제 확인
openstack network list
openstack router list
```

### Flavor 삭제

```bash
# Flavor 삭제
openstack flavor delete m1.tiny

# 삭제 확인
openstack flavor list
```

### 이미지 삭제

```bash
# 이미지 삭제
openstack image delete cirros

# 삭제 확인
openstack image list

# 다운로드한 이미지 파일 삭제
rm -f cirros-0.6.2-x86_64-disk.img
```

### 모든 테스트 리소스 한번에 삭제

```bash
# 환경변수 로드
source /etc/kolla/admin-openrc.sh

# 1. VM 삭제
openstack server delete test-vm 2>/dev/null || true

# 2. 네트워크 삭제
openstack subnet delete demo-subnet 2>/dev/null || true
openstack network delete demo-net 2>/dev/null || true

# 3. Flavor 삭제
openstack flavor delete m1.tiny 2>/dev/null || true

# 4. 이미지 삭제
openstack image delete cirros 2>/dev/null || true

# 5. 다운로드 파일 삭제
rm -f cirros-0.6.2-x86_64-disk.img

echo "모든 테스트 리소스가 삭제되었습니다."
```

---

**이전 단계**: [Step 3: OpenStack 배포](step3-openstack-deploy.md)  
**다음 단계**: [Step 5: 관리 명령어](step5-management.md)
