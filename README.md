# OpenStack

1. NHN Cloud m2.c4m8 (8vCPU, 16GB) 환경에서 OpenStack을 설치합니다.
2. 설치 시 Kolla-Ansible을 사용합니다.

ssh -i openstack.pem ubuntu@133.186.146.47

========================================
� OpenStack AIO 설치 완료! �
========================================

� 접속 정보
Horizon URL: http://133.186.146.47
Username: admin
Password: mhO9vYPHJqjkozytbKeCc8z2qu5lABBLyBwBO7Pv

� Cinder 볼륨
Volume Group: cinder
크기: 20GB
위치: /var/lib/cinder_data.img

� 시스템 리소스
메모리: 15Gi (스왑: 15Gi)
디스크: 57G 사용 가능

�� 유용한 명령어
관리자 환경: source /etc/kolla/admin-openrc.sh
서비스 확인: openstack endpoint list
볼륨 확인: openstack volume service list
Cinder VG: vgs cinder
로그 확인: docker logs <container_name>

� 자격증명 파일
~/openstack-credentials.txt

� 문제 발생 시
Bootstrap 로그: /tmp/kolla-bootstrap.log
Prechecks 로그: /tmp/kolla-prechecks.log
Deploy 로그: /tmp/kolla-deploy.log

설치가 완료되었습니다!
