# Step 6: 트러블슈팅

> 자주 발생하는 문제와 해결 방법

---

## 목차

1. [필수 포트 목록](#필수-포트-목록)
2. [배포 단계별 오류](#배포-단계별-오류)
3. [서비스 연결 오류](#서비스-연결-오류)
4. [VM 생성 오류](#vm-생성-오류)
5. [메모리 부족 문제](#메모리-부족-문제)

---

## 필수 포트 목록

### NHN Cloud 보안 그룹에서 열어야 할 포트

| 포트      | 프로토콜 | 서비스          | 용도                | 외부 접근 필요 |
| --------- | -------- | --------------- | ------------------- | -------------- |
| **22**    | TCP      | SSH             | 서버 접속           | ✅             |
| **80**    | TCP      | Horizon         | 웹 대시보드         | ✅             |
| **443**   | TCP      | Horizon (HTTPS) | 웹 대시보드 (SSL)   | ⬜             |
| **5000**  | TCP      | Keystone        | 인증 API            | ✅             |
| **5672**  | TCP      | RabbitMQ        | 메시지 큐 (내부)    | ❌ (내부 전용) |
| **6080**  | TCP      | Nova VNC        | VM 콘솔 접속        | ✅             |
| **6081**  | TCP      | Nova SPICE      | VM 콘솔 (대안)      | ⬜             |
| **8774**  | TCP      | Nova API        | 컴퓨트 서비스       | ✅             |
| **8775**  | TCP      | Nova Metadata   | 인스턴스 메타데이터 | ✅             |
| **8776**  | TCP      | Cinder          | 블록 스토리지       | ⬜             |
| **9292**  | TCP      | Glance          | 이미지 서비스       | ✅             |
| **9696**  | TCP      | Neutron         | 네트워크 서비스     | ✅             |
| **3306**  | TCP      | MariaDB         | 데이터베이스 (내부) | ❌ (내부 전용) |
| **11211** | TCP      | Memcached       | 캐시 (내부)         | ❌ (내부 전용) |

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

## 배포 단계별 오류

### Bootstrap 오류

| 오류                | 원인                  | 해결 방법                                        |
| ------------------- | --------------------- | ------------------------------------------------ |
| `Docker not found`  | Docker 미설치         | Step 1의 Docker 설치 진행                        |
| `Permission denied` | docker 그룹 권한 없음 | `sudo usermod -aG docker $USER && newgrp docker` |

```bash
# Docker 상태 확인
sudo systemctl status docker

# Docker 서비스 시작
sudo systemctl start docker
sudo systemctl enable docker
```

### Prechecks 오류

| 오류                          | 원인                   | 해결 방법                         |
| ----------------------------- | ---------------------- | --------------------------------- |
| `network_interface not found` | 잘못된 인터페이스 이름 | `ip a`로 확인 후 globals.yml 수정 |
| `Port 80 already in use`      | Apache/Nginx 실행 중   | 해당 서비스 중지                  |
| `Kernel module not loaded`    | 필요한 커널 모듈 없음  | 모듈 로드                         |

```bash
# 인터페이스 이름 확인
ip a | grep -E "^[0-9]+:"

# Apache 중지
sudo systemctl stop apache2

# Nginx 중지
sudo systemctl stop nginx

# 커널 모듈 로드
sudo modprobe br_netfilter
sudo modprobe overlay
```

### Deploy 오류

| 오류                        | 원인          | 해결 방법        |
| --------------------------- | ------------- | ---------------- |
| `Failed to pull image`      | 네트워크 문제 | DNS 확인, 재시도 |
| `Container failed to start` | 설정 오류     | 로그 확인        |
| `Timeout`                   | 느린 네트워크 | timeout 값 증가  |

```bash
# 컨테이너 로그 확인
docker logs <container_name>

# 실패한 단계부터 재시도
kolla-ansible deploy -i ~/all-in-one
```

---

## 서비스 연결 오류

### Horizon 접속 불가

```bash
# 1. 컨테이너 상태 확인
docker ps | grep horizon

# 2. 컨테이너 재시작
docker restart horizon

# 3. 로그 확인
docker logs horizon --tail 50

# 4. 포트 확인
sudo netstat -tlnp | grep 80
```

### API 연결 오류

```bash
# 환경변수 확인
env | grep OS_

# 환경변수 재로드
source /etc/kolla/admin-openrc.sh

# Keystone 서비스 확인
docker logs keystone --tail 50
```

---

## VM 생성 오류

### "No valid host was found" 오류

```bash
# 1. Hypervisor 상태 확인
openstack hypervisor list

# 2. Nova Compute 로그 확인
docker logs nova_compute --tail 100

# 3. Neutron 상태 확인
openstack network agent list

# 4. 서비스 재시작
docker restart nova_compute
docker restart nova_scheduler
```

### 네트워크 연결 오류

```bash
# 네트워크 상태 확인
openstack network list
openstack subnet list

# Neutron 에이전트 확인
openstack network agent list

# OVS 상태 확인
docker exec openvswitch_vswitchd ovs-vsctl show
```

---

## 메모리 부족 문제

### 증상

- 컨테이너 자동 종료
- OOM (Out of Memory) 에러
- 느린 응답 속도

### 확인

```bash
# 메모리 사용량 확인
free -h

# 스왑 사용량 확인
sudo swapon --show

# 컨테이너별 메모리 사용량
docker stats --no-stream
```

### 해결

```bash
# 스왑 추가 (이미 설정되지 않은 경우)
sudo fallocate -l 8G /swapfile2
sudo chmod 600 /swapfile2
sudo mkswap /swapfile2
sudo swapon /swapfile2

# 불필요한 서비스 비활성화 (globals.yml 수정 후)
kolla-ansible reconfigure -i ~/all-in-one
```

---

**이전 단계**: [Step 5: 관리 명령어](step5-management.md)  
**처음으로**: [Step 1: OS 기본 설정](step1-os-setup.md)
