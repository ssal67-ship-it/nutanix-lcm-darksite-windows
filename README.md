# Nutanix LCM Dark Site Web Server (Windows / IIS) Setup

Nutanix LCM 다크사이트(인터넷이 안 되는 환경) 업데이트용 **IIS 웹 서버를 한 번에 구성**하는 PowerShell 스크립트입니다.
Windows Server 만 설치된 상태에서 실행하면 됩니다.

Nutanix 문서 [LCM Guide v3.0 – Setting Up a Local Web Server (Windows)](https://portal.nutanix.com/page/documents/details?targetId=Life-Cycle-Manager-Guide-v3_0:top-lcm-darksite-web-server-windows-t.html) 의 절차를 자동화했습니다.

## 하는 일

| 단계 | 내용 |
|---|---|
| 1 | IIS 설치 (정적 콘텐츠, 디렉터리 검색, 요청 필터링, IIS 관리자) |
| 2 | `C:\LCM\release` 폴더 + `Default Web Site/release` 가상 디렉터리 생성 |
| 3 | `release` 에 Directory Browsing 활성화 |
| 4 | MIME 타입 설정<br>• `.sign .json .iso .xz` → `text/plain`<br>• `.BD .bin .csv .exe .frm .ftd .gz .jed .lod .md .qcow2 .std .tgz .vib` → 없으면 `application/x-iso9660-image` 추가 |
| 5 | 요청 필터링이 위 확장자를 막고 있으면 허용 예외 추가 |
| 6 | NTFS 권한: IUSR, IIS_IUSRS 읽기/실행 |
| 7 | (선택) 다크사이트 번들 `.tar.gz / .tgz / .zip` 압축 해제 |
| 8 | 파일/폴더 이름 소문자 변환 (LCM 은 대문자 파일을 무시) |
| 9 | 방화벽 TCP 80 허용, W3SVC 자동 시작, 접속 확인 및 LCM Source URL 출력 |

설정은 번들 폴더의 web.config 가 아니라 `applicationHost.config` 에 저장되므로, 번들을 지우고 새로 풀어도 유지됩니다.
여러 번 실행해도 안전합니다.

## 사용법

관리자 권한 PowerShell 에서:

```powershell
# 인터넷에서 받은 파일이면 차단 해제
Unblock-File .\Setup-LcmDarkSite.ps1

# IIS 구성만
powershell -ExecutionPolicy Bypass -File .\Setup-LcmDarkSite.ps1

# 구성 + 번들 압축 해제
powershell -ExecutionPolicy Bypass -File .\Setup-LcmDarkSite.ps1 -BundlePath D:\down\lcm_darksite_bundle.tar.gz
```

완료 후 Prism 의 **LCM > Settings** 에서 Source 를 Local web server 로 바꾸고, 출력된 `http://<서버IP>/release` 를 입력합니다.

### 옵션

| 파라미터 | 기본값 | 설명 |
|---|---|---|
| `-PhysicalPath` | `C:\LCM\release` | 번들을 둘 실제 폴더 |
| `-SiteName` | `Default Web Site` | 가상 디렉터리를 만들 IIS 사이트 |
| `-VDirName` | `release` | 가상 디렉터리 이름 |
| `-BundlePath` | (없음) | 압축 해제할 번들 파일(여러 개 가능) |
| `-SkipLowercase` | off | 소문자 변환 건너뛰기 |
| `-OverrideExistingMime` | off | `.bin .exe .gz .tgz` 등 IIS 기본 MIME 값도 `application/x-iso9660-image` 로 변경 (문서상 필수 아님) |

## 참고

- `master_manifest.tgz.sign` 이 `release` 폴더 **바로 아래**에 있어야 합니다 (`http://<IP>/release/master_manifest.tgz.sign`).
- 프록시 환경이면 웹 서버 IP 를 Prism 프록시 allow-list 에 추가하세요.
- HTTPS 사용 시 공인 CA 인증서만 허용됩니다 (사설 CA 는 Nutanix KB 5090 참고). 이 스크립트는 HTTP(80)만 구성합니다.
- Nutanix CVM 을 웹 서버로 쓰지 마세요.
- 스크립트는 UTF-8 (BOM) 로 저장되어 있습니다. 편집 후에도 같은 인코딩으로 저장해야 PowerShell 5.1 에서 한글이 깨지지 않습니다.

## 면책

Nutanix 와 무관한 개인 스크립트입니다. 운영 환경 적용 전 테스트 서버에서 먼저 확인하세요.

## License

[MIT](LICENSE)
