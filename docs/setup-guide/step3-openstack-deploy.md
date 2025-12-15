# Step 3: OpenStack 배포

> Kolla-Ansible을 사용한 OpenStack 서비스 배포  
> 첫 배포는 Docker 이미지 다운로드로 인해 **20-40분** 소요

---

## 목차

1. [Ansible 의존성 설치](#1-ansible-의존성-설치)
2. [Bootstrap (서버 초기 설정)](#2-bootstrap-서버-초기-설정)
3. [사전 검증](#3-사전-검증)
4. [배포](#4-배포-20-40분-소요)
5. [후처리](#5-후처리)
6. [배포 완료 확인](#6-배포-완료-확인)
7. [롤백 & 삭제](#롤백--삭제)

---

## 1. Ansible 의존성 설치

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# Kolla-Ansible 실행에 필요한 Ansible Galaxy 역할들 설치
# 네트워크 이슈가 많아서 실패 시 재실행
kolla-ansible install-deps

# 설치 확인 (에러 없는지 확인)
ansible-galaxy collection list
```

## 2. Bootstrap (서버 초기 설정)

```bash
# 서버 초기 설정 (Docker 설정, 사용자 권한 등)
# Docker를 수동 설치했다면 이 단계는 주로 권한 설정만 수행
kolla-ansible bootstrap-servers -i ~/all-in-one
```

> ✅ Docker를 수동 설치하지 않았다면 이 단계에서 자동으로 설치됩니다!

**출력 끝부분:**

```
PLAY RECAP *********************************************************************
localhost                  : ok=XX   changed=XX   unreachable=0    failed=0
```

---

## 3. 사전 검증

```bash
# 배포 전 시스템 요구사항 검증 (포트 충돌, 설정 오류 등 체크)
kolla-ansible prechecks -i ~/all-in-one
```

**정상 출력:**

```
PLAY RECAP *********************************************************************
localhost                  : ok=XX   changed=0    unreachable=0    failed=0
```

> ❌ 에러가 있으면 수정 후 다시 실행하세요!

**자주 발생하는 에러:**

| 에러 메시지                   | 해결 방법                          |
| ----------------------------- | ---------------------------------- |
| `network_interface not found` | globals.yml의 인터페이스 이름 확인 |
| `Port 80 already in use`      | Apache/Nginx가 실행 중이면 중지    |
| `Docker not running`          | `sudo systemctl start docker`      |

---

## 4. 배포 (20-40분 소요)

```bash
# 실제 OpenStack 컨테이너들 배포 (모든 서비스 설치 및 실행)
kolla-ansible deploy -i ~/all-in-one
```

**진행 상황 예시:**

```
TASK [mariadb : Running MariaDB bootstrap container] ***************************
TASK [rabbitmq : Starting RabbitMQ container] **********************************
TASK [keystone : Starting Keystone container] **********************************
TASK [glance : Starting Glance API container] **********************************
TASK [nova : Starting Nova services] *******************************************
TASK [neutron : Starting Neutron services] *************************************
TASK [horizon : Starting Horizon container] ************************************
```

**정상 완료:**

```
PLAY RECAP *********************************************************************
localhost                  : ok=XXX  changed=XX   unreachable=0    failed=0
```

> ⏱️ **소요 시간**: 첫 배포는 Docker 이미지 다운로드로 인해 20-40분 소요됩니다.

### 배포 중 자주 발생하는 에러

#### MariaDB ProxySQL 인증 에러

```
ERROR 1045 (28000): ProxySQL Error: Access denied for user 'root_shard_0'@'127.0.0.1' (using password: YES)
```

이 에러는 MariaDB 배포 후 VIP 연결 확인 단계에서 발생합니다.

**원인**: ProxySQL 사용자 동기화 실패

**해결 방법 1: MariaDB 재설정 (권장)**

```bash
source ~/kolla-venv/bin/activate

# MariaDB만 재설정
kolla-ansible reconfigure -i ~/all-in-one -t mariadb

# 후처리 재실행
kolla-ansible post-deploy -i ~/all-in-one
```

**해결 방법 2: 완전 재배포**

```bash
source ~/kolla-venv/bin/activate

# MariaDB 정지 및 볼륨 삭제
docker stop mariadb
docker rm mariadb
docker volume rm mariadb

# MariaDB만 재배포
kolla-ansible deploy -i ~/all-in-one -t mariadb

# 후처리
kolla-ansible post-deploy -i ~/all-in-one
```

**해결 방법 3: 전체 재배포 (최후 수단)**

```bash
source ~/kolla-venv/bin/activate

# 전체 삭제 후 재배포
kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it
kolla-ansible deploy -i ~/all-in-one
kolla-ansible post-deploy -i ~/all-in-one
```

---

## 5. 후처리

```bash
# 배포 후 작업 (admin-openrc.sh 생성 등 환경 설정 파일 생성)
kolla-ansible post-deploy -i ~/all-in-one
```

**생성되는 파일:**

| 파일                         | 용도                    |
| ---------------------------- | ----------------------- |
| `/etc/kolla/admin-openrc.sh` | OpenStack CLI 인증 정보 |
| `/etc/kolla/clouds.yaml`     | OpenStack SDK 설정      |

---

## 6. 배포 완료 확인

```bash
# 실행 중인 OpenStack 컨테이너 확인
docker ps

# 모든 컨테이너가 "Up" 상태인지 확인
docker ps --format "table {{.Names}}\t{{.Status}}"
```

**정상 출력 예시:**

```
NAMES                    STATUS
horizon                  Up 2 minutes
neutron_server           Up 3 minutes
nova_compute             Up 3 minutes
nova_conductor           Up 3 minutes
nova_api                 Up 4 minutes
glance_api               Up 4 minutes
keystone                 Up 5 minutes
rabbitmq                 Up 6 minutes
mariadb                  Up 6 minutes
memcached                Up 6 minutes
```

---

## 롤백 & 삭제

> 이 단계에서 문제가 발생했거나 초기화가 필요한 경우 아래 명령어를 사용하세요.

### 배포 실패 시 재시도

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# 1. 현재 상태 정리
kolla-ansible stop -i ~/all-in-one

# 2. 사전 검증 다시 실행
kolla-ansible prechecks -i ~/all-in-one

# 3. 배포 재시도
kolla-ansible deploy -i ~/all-in-one
```

### 특정 서비스만 재배포

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# 특정 서비스만 재배포 (--tags로 서비스 지정)
kolla-ansible deploy -i ~/all-in-one --tags nova
kolla-ansible deploy -i ~/all-in-one --tags neutron
kolla-ansible deploy -i ~/all-in-one --tags horizon
kolla-ansible deploy -i ~/all-in-one --tags keystone
kolla-ansible deploy -i ~/all-in-one --tags glance
```

### 특정 컨테이너 재시작

```bash
# 개별 컨테이너 재시작
docker restart keystone
docker restart nova_compute
docker restart horizon
docker restart mariadb
docker restart rabbitmq

# 컨테이너 로그 확인 (문제 진단)
docker logs keystone
docker logs nova_compute --tail 100
```

### OpenStack 완전 삭제 (초기화)

> ⚠️ **주의**: 모든 OpenStack 컨테이너와 데이터가 완전 삭제됩니다!  
> 복구 불가능하니 신중히 사용하세요!

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# 완전 삭제 실행
kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it

# Docker 이미지도 삭제하려면 (선택사항)
docker image prune -a

# Docker 볼륨도 삭제하려면 (선택사항)
docker volume prune
```

### Docker 레벨에서 정리

```bash
# 모든 Kolla 컨테이너 중지
docker stop $(docker ps -q --filter "name=kolla")

# 모든 Kolla 컨테이너 삭제
docker rm $(docker ps -aq --filter "name=kolla")

# Kolla 관련 Docker 이미지 삭제
docker rmi $(docker images -q --filter "reference=*kolla*")

# Docker 볼륨 삭제 (데이터 삭제 주의!)
docker volume rm $(docker volume ls -q --filter "name=kolla")
```

### 처음부터 다시 배포

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# 1. 완전 삭제
kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it

# 2. 의존성 재설치
kolla-ansible install-deps

# 3. Bootstrap
kolla-ansible bootstrap-servers -i ~/all-in-one

# 4. 사전 검증
kolla-ansible prechecks -i ~/all-in-one

# 5. 배포
kolla-ansible deploy -i ~/all-in-one

# 6. 후처리
kolla-ansible post-deploy -i ~/all-in-one
```

---

**이전 단계**: [Step 2: Kolla-Ansible 설치](step2-kolla-ansible-install.md)  
**다음 단계**: [Step 4: 사용 방법](step4-usage.md)
