# 트러블슈팅 보고서

## Caddy가 상태 확인 경로의 설정을 읽지 못함

배포 템플릿의 Caddy 설정을 추출해 로컬 Caddy에서 재현했습니다. EC2 배포 상태는 README의 외부 접속 증빙에서 확인합니다.

| 단계 | 확인 내용 |
| --- | --- |
| 증상 | 설정을 검증하자 Caddy가 `unrecognized directive: respondd`를 출력하고 실패했습니다. |
| 가설 | 설정을 읽는 단계의 오류 메시지이므로, `/health` 응답을 등록하는 지시어의 철자를 의심했습니다. |
| 검증 | 추출한 Caddyfile의 복사본에서 `respond` 뒤에 `d`를 한 글자 추가한 뒤 `caddy validate`를 실행했습니다. 오류에 나온 줄과 지시어가 변경 지점과 일치했습니다. |
| 조치 | 복사본의 지시어를 `respond /health "OK" 200`으로 고쳤습니다. |
| 결과 | `caddy validate`가 `Valid configuration`을 출력했습니다. 변환한 설정에서 80번 포트, 정확히 일치하는 `/health` 경로, 응답 코드 200과 본문 `OK`를 확인했습니다. |
| 재발 방지 | 배포 스크립트는 Caddy를 다시 읽기 전에 `caddy validate`를 실행하고, 다시 읽은 뒤 로컬 헬스체크를 실행합니다. |

현장에서 실패하면 `sudo cat /var/log/cloud-init-output.log`에서 설치·설정 오류를 확인하고, `sudo journalctl -u caddy --no-pager -n 30`에서 Caddy의 실행 및 접근 로그를 확인합니다.
