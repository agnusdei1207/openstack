# Step 5: 관리 명령어

> OpenStack 서비스 관리 및 운영 명령어 모음

---

## 목차

1. [서비스 상태 확인](#서비스-상태-확인)
2. [OpenStack 서비스 상태](#openstack-서비스-상태)
3. [재시작 및 재설정](#재시작-및-재설정)
4. [전체 서비스 재시작](#전체-서비스-재시작)
5. [완전 삭제 (초기화)](#완전-삭제-초기화)

---

## 서비스 상태 확인

### Docker 컨테이너 상태

```bash
# 실행 중인 OpenStack 컨테이너 목록 확인
docker ps

# 컨테이너별 상태 한눈에 보기
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 모든 컨테이너 (중지된 것 포함)
docker ps -a
```

### 컨테이너 로그 확인

```bash
# 특정 서비스 컨테이너 로그 확인 (문제 발생 시 디버깅용)
docker logs mariadb
docker logs rabbitmq
docker logs keystone
docker logs nova_compute
docker logs neutron_server
docker logs horizon

# 실시간 로그 확인 (Ctrl+C로 종료)
docker logs -f nova_compute

# 최근 100줄만 확인
docker logs --tail 100 keystone
```

### 리소스 사용량 모니터링

```bash
# 컨테이너별 리소스 사용량 확인
docker stats --no-stream

# 실시간 리소스 모니터링
docker stats
```

---

## OpenStack 서비스 상태

```bash
# 환경변수 로드
source /etc/kolla/admin-openrc.sh

# 전체 서비스 상태
openstack service list

# Compute 서비스 상태
openstack compute service list

# Network 에이전트 상태
openstack network agent list

# Hypervisor 상태
openstack hypervisor list
```

---

## 재시작 및 재설정

### 설정 변경 후 적용

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# globals.yml 수정 후 변경사항 적용 (전체 재배포 없이)
kolla-ansible -i ~/all-in-one reconfigure
```

### 특정 서비스 재배포

```bash
# 특정 서비스만 재배포 (--tags로 서비스 지정)
kolla-ansible -i ~/all-in-one deploy --tags nova
kolla-ansible -i ~/all-in-one deploy --tags neutron
kolla-ansible -i ~/all-in-one deploy --tags horizon
```

### 개별 컨테이너 재시작

```bash
# 특정 컨테이너만 재시작
docker restart keystone
docker restart nova_compute
docker restart horizon
```

---

## 전체 서비스 재시작

### Docker 명령 사용

```bash
# 모든 OpenStack 컨테이너 중지
docker stop $(docker ps -q)

# 모든 OpenStack 컨테이너 시작
docker start $(docker ps -aq)
```

### Kolla-Ansible 명령 사용 (권장)

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

kolla-ansible -i ~/all-in-one stop
kolla-ansible -i ~/all-in-one deploy
```

---

## 완전 삭제 (초기화)

> ⚠️ **주의**: 모든 OpenStack 컨테이너와 데이터 완전 삭제!  
> 복구 불가능하니 신중히 사용하세요!

```bash
# 가상환경 활성화
source ~/kolla-venv/bin/activate

# 완전 삭제 실행
kolla-ansible -i ~/all-in-one destroy --yes-i-really-really-mean-it
```

### Docker 레벨 정리 (선택사항)

```bash
# Docker 이미지 삭제
docker image prune -a

# Docker 볼륨 삭제
docker volume prune

# Docker 네트워크 삭제
docker network prune
```

---

**이전 단계**: [Step 4: 사용 방법](step4-usage.md)  
**다음 단계**: [Step 6: 트러블슈팅](step6-troubleshooting.md)
