# AWS 웹 서비스 배포 실습

서울 리전의 퍼블릭 서브넷에 EC2 한 대를 두고 Caddy로 웹 페이지를 제공합니다. 외부 접속 검증은 **방식 B**를 사용합니다. EC2의 퍼블릭 IPv4에 `GET /health`를 보내 HTTP 200과 본문 `OK`를 확인합니다.

| 평가 자료 | 확인할 내용 |
| --- | --- |
| [아키텍처](docs/architecture.png) | 인터넷에서 EC2까지의 경로와 보안 그룹 |
| [외부 접속 증빙](#접속-검증) | 배포 대기. 실제 접속 URL과 스크린샷은 외부 검증 후 기록 |
| [트러블슈팅](docs/troubleshooting.md) | Caddy 설정 오류 재현, 원인 확인, 수정 및 재검증 |
| [정리 체크리스트](docs/cleanup-checklist.md) | 과금 리소스와 네트워크의 삭제 확인 방법 |
| [배포 코드](infra/web.yml) · [실습 명령](infra/lab.sh) · [IAM 정책](infra/iam-policy.json) | 구성, 실행 순서, 권한 범위 |

## 배포

실습 전용 IAM 사용자 또는 역할에 [실습 정책](infra/iam-policy.json)을 적용합니다. AWS CLI v2에 해당 자격 증명을 연결하고, Billing의 프리 티어·크레딧 화면에서 적용 범위를 확인합니다. 배포 스크립트는 서울 리전에서 프리 티어 대상 `t3.micro`와 Canonical Ubuntu 24.04 AMI를 확인한 뒤 진행합니다.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/cds-publish-web -C cds-publish-web
./infra/lab.sh deploy ~/.ssh/cds-publish-web.pub "$(curl -fsS https://checkip.amazonaws.com)"
```

개인키는 `~/.ssh`에 보관합니다. 배포 명령은 공개키를 EC2 키 페어로 등록하고 스택을 생성합니다. 부팅 중 `web.yml`의 `UserData`가 Caddy를 설치하고 사이트와 `/health`를 설정합니다.

## 접속 검증

`./infra/lab.sh status`에서 `HealthUrl`과 `PublicIp`를 확인합니다. 아래의 `<퍼블릭_IP>`는 실습 인스턴스에 할당된 주소로 바꿉니다.

```bash
ssh -i ~/.ssh/cds-publish-web ubuntu@<퍼블릭_IP>
sudo cloud-init status --wait
systemctl is-active caddy
curl -i http://localhost/
curl -i http://localhost/health
curl -fsS -o /dev/null -w '%{http_code}\n' https://example.com
```

SSH에서 나와 **EC2 외부의 터미널**로 아래 요청을 보냅니다. 실제 URL, HTTP 상태 줄, `OK`가 보이는 화면을 캡처하고 이 섹션에 첨부합니다.

```bash
curl -i http://<퍼블릭_IP>/health
```

## 평가에서 설명할 내용

- VPC는 독립된 네트워크 주소 영역입니다. 퍼블릭 서브넷에는 인터넷 게이트웨이로 향하는 기본 경로가 있고, EC2에 실제 퍼블릭 IPv4가 있어야 인터넷에서 접속할 수 있습니다.
- 보안 그룹은 EC2의 트래픽을 제어합니다. HTTP는 모두에게, SSH는 개인 IPv4 한 개에 허용합니다. SSH를 전체에 열면 로그인 시도에 노출되며, DB가 필요해지면 프라이빗 서브넷에 두고 애플리케이션 보안 그룹에서 오는 해당 포트만 허용합니다. IAM은 AWS API 호출 권한을 제어합니다.
- 외부에서 응답이 없으면 서브넷 라우팅 → 보안 그룹 → 퍼블릭 IP → `systemctl`, `curl localhost`, `journalctl -u caddy` 순서로 확인합니다. AWS API가 `AccessDenied`를 반환하면 스택 이벤트에서 실패한 API와 리소스를 찾아 필요한 권한을 그 범위에만 추가합니다.
- 한 인스턴스가 트래픽과 장애를 모두 감당합니다. 실서비스에서 두 대로 늘린다면, 두 가용 영역의 서브넷과 ALB를 사용해 요청을 분산하고 헬스체크로 장애 인스턴스를 제외할 수 있습니다.

## 비용과 정리

온디맨드 기준 서울 `t3.micro` 약 **$0.013/시간**, 퍼블릭 IPv4 **$0.005/시간**, gp3 8 GiB 약 **$0.001/시간**으로, 고정 리소스 비용은 합계 **시간당 약 $0.019**입니다. 세금과 데이터 전송료는 별도입니다. 증빙을 수집한 직후 삭제합니다. 실습이 중단될 때를 대비해 첫 부팅 스크립트에서 60분 뒤의 종료를 예약합니다. 종료 시 EC2와 루트 볼륨이 함께 삭제되며 스택은 별도로 정리합니다. [EC2 요금](https://aws.amazon.com/ec2/pricing/on-demand/) · [퍼블릭 IPv4 요금](https://aws.amazon.com/vpc/pricing/) · [EBS 요금](https://aws.amazon.com/ebs/pricing/)

```bash
./infra/lab.sh cleanup
```

`Project=cds-publish-web` 태그와 `cds-publish-web` 스택 이름을 사용합니다. 삭제 명령은 스택이 삭제될 때까지 대기하고, 별도로 등록한 실습용 키 페어를 삭제한 뒤 같은 태그의 잔여 리소스를 조회합니다. [정리 체크리스트](docs/cleanup-checklist.md)에 실제 결과를 기록합니다.
