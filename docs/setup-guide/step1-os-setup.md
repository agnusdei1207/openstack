# Step 1: OS 기본 설정

> NHN Cloud m2.c4m8 (4vCPU, 8GB RAM) 환경  
> **Ubuntu 22.04 (Jammy)** 기준

---

## 목차

1. [스왑 메모리 설정](#1-스왑-메모리-설정-16gb)
2. [시스템 업데이트 & 필수 패키지](#2-시스템-업데이트--필수-패키지)
3. [호스트명 설정](#3-호스트명-설정)
4. [더미 인터페이스 설정](#4-더미-인터페이스-설정-eth1---외부-네트워크용)
5. [Docker 설치](#5-docker-설치)
6. [롤백 & 삭제](#롤백--삭제)

---

## 1. 스왑 메모리 설정 (16GB)

> ⚠️ **중요**: Bootstrap 실행 전에 스왑 설정 완료 필수!  
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

---

## 2. 시스템 업데이트 & 필수 패키지

```bash
# 패키지 목록 갱신 및 보안 업데이트 적용
sudo apt update && sudo apt upgrade -y

# Kolla-Ansible 설치에 필요한 Python 도구 및 Git 설치
# - python3-pip: Python 패키지 설치용
# - python3-venv: 가상환경 생성용
# - git: Kolla-Ansible 의존성 설치 시 필요
sudo apt install -y python3-pip python3-venv git
```

---

## 3. 호스트명 설정

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

---

## 4. 더미 인터페이스 설정 (eth1 - 외부 네트워크용)

> ⚠️ **확장성을 위한 설정**: Floating IP 및 외부 네트워크를 사용하려면 별도의 네트워크 인터페이스가 필요합니다.  
> NHN Cloud 단일 NIC 환경에서는 더미 인터페이스로 이를 대체합니다.

```bash
# systemd-networkd 기반 더미 인터페이스 설정 (재부팅 후에도 유지)

# 1. 더미 디바이스 생성 설정
sudo tee /etc/systemd/network/10-dummy0.netdev << 'EOF'
[NetDev]
Name=eth1
Kind=dummy
EOF

# 2. 더미 인터페이스 네트워크 설정 (IP 없이 UP 상태만 유지)
sudo tee /etc/systemd/network/20-dummy0.network << 'EOF'
[Match]
Name=eth1

[Network]
# IP 할당 없음 - OpenStack Neutron이 브릿지로 사용
LinkLocalAddressing=no
LLDP=no
EmitLLDP=no
IPv6AcceptRA=no
IPv6SendRA=no
EOF

# 3. systemd-networkd 활성화 및 시작
sudo systemctl enable systemd-networkd
sudo systemctl restart systemd-networkd

# 4. 인터페이스 확인 (eth1이 UP 상태인지 확인)
ip link show eth1
```

**확인 결과 예시:**

```
3: eth1: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff
```

> 💡 **왜 systemd-networkd인가?**
>
> - `ip link add` 명령어는 재부팅 시 사라짐
> - `/etc/rc.local`은 Ubuntu 22.04에서 비권장
> - systemd-networkd는 부팅 시 자동 생성되어 **가장 안정적**

---

## 5. Docker 설치

> Bootstrap이 Docker를 자동 설치하지만, 수동 설치가 더 안정적입니다.

```bash
# Docker 공식 GPG 키 추가
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Docker 저장소 추가
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker 설치
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# 현재 사용자를 docker 그룹에 추가 (sudo 없이 docker 명령 사용)
sudo usermod -aG docker $USER
newgrp docker

# 나갔다 다시 들어오기
exit

# Docker 설치 확인
docker --version
docker ps
```

---

## 롤백 & 삭제

> 이 단계에서 문제가 발생했거나 초기화가 필요한 경우 아래 명령어를 사용하세요.

### 스왑 제거

```bash
# 스왑 비활성화
sudo swapoff /swapfile

# 스왑 파일 삭제
sudo rm /swapfile

# fstab에서 스왑 항목 제거
sudo sed -i '/\/swapfile/d' /etc/fstab

# sysctl.conf에서 swappiness 설정 제거
sudo sed -i '/vm.swappiness/d' /etc/sysctl.conf
```

### 호스트명 초기화

```bash
# 호스트명을 원래 값으로 복원 (예: ubuntu)
sudo hostnamectl set-hostname ubuntu

# /etc/hosts에서 openstack 항목 제거
sudo sed -i '/openstack/d' /etc/hosts
```

### Docker 완전 제거

```bash
# Docker 서비스 중지
sudo systemctl stop docker
sudo systemctl stop containerd

# Docker 패키지 제거
sudo apt purge -y docker-ce docker-ce-cli containerd.io

# Docker 관련 데이터 완전 삭제 (이미지, 컨테이너, 볼륨 등)
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd

# Docker 저장소 제거
sudo rm /etc/apt/sources.list.d/docker.list
sudo rm /usr/share/keyrings/docker-archive-keyring.gpg

# docker 그룹에서 사용자 제거
sudo gpasswd -d $USER docker
```

### 더미 인터페이스 제거

```bash
# systemd-networkd 설정 파일 삭제
sudo rm -f /etc/systemd/network/10-dummy0.netdev
sudo rm -f /etc/systemd/network/20-dummy0.network

# 현재 세션에서 인터페이스 제거
sudo ip link delete eth1 2>/dev/null || true

# systemd-networkd 재시작
sudo systemctl restart systemd-networkd
```

### Python 패키지 제거

```bash
# 설치한 Python 패키지 제거 (시스템에 설치된 경우)
# 가상환경 사용 시 이 단계는 불필요
sudo apt purge -y python3-pip python3-venv git
sudo apt autoremove -y
```

---

**다음 단계**: [Step 2: Kolla-Ansible 설치](step2-kolla-ansible-install.md)
