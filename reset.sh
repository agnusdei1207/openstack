# 1. Kolla 환경 정리 (기존 배포 제거)
source ~/kolla-venv/bin/activate 2>/dev/null || true
kolla-ansible destroy -i ~/all-in-one --yes-i-really-really-mean-it 2>/dev/null || true
deactivate 2>/dev/null || true

# 2. Docker 컨테이너 및 이미지 정리
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker network prune -f 2>/dev/null || true
docker volume prune -f 2>/dev/null || true
docker system prune -af 2>/dev/null || true

# 3. Cinder LVM 정리
lvremove -f cinder 2>/dev/null || true
vgchange -an cinder 2>/dev/null || true
vgremove -f cinder 2>/dev/null || true
rm -f /var/lib/cinder_data.img 2>/dev/null || true

# 4. Kolla 관련 디렉토리 정리
rm -rf /etc/kolla 2>/dev/null || true
rm -rf ~/kolla-venv 2>/dev/null || true
rm -rf ~/.ansible 2>/dev/null || true

# 5. systemd 서비스 정리
systemctl stop cinder-loop.service 2>/dev/null || true
systemctl disable cinder-loop.service 2>/dev/null || true
rm -f /etc/systemd/system/cinder-loop.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# 6. 더미 네트워크 인터페이스 정리 (선택사항)
ip link delete eth1 2>/dev/null || true
rm -f /etc/systemd/network/10-dummy0.netdev 2>/dev/null || true
rm -f /etc/systemd/network/20-dummy0.network 2>/dev/null || true