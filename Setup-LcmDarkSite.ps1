<#
.SYNOPSIS
    Nutanix LCM 다크사이트(Dark Site)용 IIS 웹 서버 자동 구성 스크립트

.DESCRIPTION
    Nutanix LCM Guide v3.0 "Setting Up a Local Web Server (Windows)" 절차를 자동화합니다.

      1. IIS 및 필요한 기능 설치 (정적 콘텐츠, 디렉터리 검색, 요청 필터링, 관리 도구)
      2. 물리 폴더 생성 + Default Web Site 아래 'release' 가상 디렉터리 생성
      3. 'release' 에 Directory Browsing 활성화          (안 하면 LCM 인벤토리에 업그레이드가 안 보임)
      4. MIME 타입 설정
           - .sign .json .iso .xz                        -> text/plain (기존 값이 있어도 덮어씀)
           - .BD .bin .csv .exe .frm .ftd .gz .jed .lod
             .md .qcow2 .std .tgz .vib                   -> 없으면 application/x-iso9660-image 로 추가
      5. 요청 필터링(Request Filtering)이 위 확장자를 막지 않도록 예외(allow) 추가
      6. 폴더 NTFS 권한 (IUSR, IIS_IUSRS 읽기/실행)
      7. (선택) 다크사이트 번들(.tar.gz / .tgz / .zip) 을 release 폴더에 압축 해제
      8. release 폴더 안의 파일/폴더 이름을 모두 소문자로 변환 (LCM은 대문자 파일을 무시함)
      9. 방화벽 HTTP(80) 허용 및 동작 확인

    설정은 web.config(번들 폴더 안)가 아니라 applicationHost.config 의 <location> 에 저장되므로
    번들을 지우고 다시 풀어도 설정이 유지됩니다.

.PARAMETER PhysicalPath
    번들이 들어갈 실제 폴더. 기본값 C:\LCM\release

.PARAMETER SiteName
    가상 디렉터리를 만들 IIS 사이트. 기본값 "Default Web Site"

.PARAMETER BundlePath
    압축 해제할 다크사이트 번들 파일 경로(여러 개 가능). 생략하면 압축 해제 생략.

.PARAMETER SkipLowercase
    파일명 소문자 변환을 건너뜀.

.PARAMETER OverrideExistingMime
    .bin .exe .gz .tgz 처럼 IIS 에 기본으로 있는 MIME 값도 application/x-iso9660-image 로 변경.
    (문서상 필수는 아님 - 기본 동작은 기존 값 유지)

.EXAMPLE
    # 관리자 PowerShell 에서 IIS만 구성
    powershell -ExecutionPolicy Bypass -File .\Setup-LcmDarkSite.ps1

.EXAMPLE
    # 구성 + 번들 압축 해제까지
    powershell -ExecutionPolicy Bypass -File .\Setup-LcmDarkSite.ps1 -BundlePath D:\down\lcm_darksite_bundle_3.2.tar.gz,D:\down\lcm_nx_fw.tar.gz
#>

[CmdletBinding()]
param(
    [string]   $PhysicalPath = 'C:\LCM\release',
    [string]   $SiteName     = 'Default Web Site',
    [string]   $VDirName     = 'release',
    [string[]] $BundlePath   = @(),
    [switch]   $SkipLowercase,
    [switch]   $OverrideExistingMime   # .bin .exe .gz .tgz 등 기존 값도 application/x-iso9660-image 로 변경
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "    [INFO] $msg" -ForegroundColor Gray }
function Write-Warn2($msg){ Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 0. 관리자 권한 확인
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error '관리자 권한으로 PowerShell 을 실행한 뒤 다시 시도하세요.'
    exit 1
}

# ---------------------------------------------------------------------------
# 1. IIS 설치
# ---------------------------------------------------------------------------
Write-Step 'IIS 및 필요한 기능 설치'
$features = @(
    'Web-Server',          # IIS
    'Web-Common-Http',
    'Web-Static-Content',  # 정적 파일 제공
    'Web-Default-Doc',
    'Web-Dir-Browsing',    # 디렉터리 검색 (필수)
    'Web-Http-Errors',
    'Web-Http-Logging',
    'Web-Filtering',       # 요청 필터링 (설정 섹션 사용을 위해)
    'Web-Mgmt-Console',    # IIS 관리자 GUI
    'Web-Scripting-Tools'  # WebAdministration 모듈
)

if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    Write-Ok "설치 완료 (재부팅 필요: $($result.RestartNeeded))"
} else {
    # Windows 10/11 클라이언트에서 테스트할 경우
    $clientFeatures = 'IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-StaticContent',
                      'IIS-DefaultDocument','IIS-DirectoryBrowsing','IIS-HttpErrors','IIS-HttpLogging',
                      'IIS-RequestFiltering','IIS-ManagementConsole','IIS-ManagementScriptingTools'
    Enable-WindowsOptionalFeature -Online -FeatureName $clientFeatures -All -NoRestart | Out-Null
    Write-Ok '설치 완료 (Windows 클라이언트 OS)'
}

Import-Module WebAdministration
$apphost  = 'MACHINE/WEBROOT/APPHOST'
$location = "$SiteName/$VDirName"

if (-not (Get-Website -Name $SiteName)) {
    throw "IIS 사이트 '$SiteName' 를 찾을 수 없습니다. -SiteName 을 확인하세요."
}

# ---------------------------------------------------------------------------
# 2. 폴더 + 가상 디렉터리
# ---------------------------------------------------------------------------
Write-Step "물리 폴더 및 가상 디렉터리 '$VDirName' 생성"
if (-not (Test-Path $PhysicalPath)) {
    New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null
    Write-Ok "폴더 생성: $PhysicalPath"
} else {
    Write-Info "폴더가 이미 있음: $PhysicalPath"
}

$vdir = Get-WebVirtualDirectory -Site $SiteName -Name $VDirName
if ($vdir) {
    Set-ItemProperty "IIS:\Sites\$SiteName\$VDirName" -Name physicalPath -Value $PhysicalPath
    Write-Info "가상 디렉터리가 이미 있어 경로만 갱신: $PhysicalPath"
} else {
    New-WebVirtualDirectory -Site $SiteName -Name $VDirName -PhysicalPath $PhysicalPath | Out-Null
    Write-Ok "가상 디렉터리 생성: /$VDirName -> $PhysicalPath"
}
# Connect As: 기본값(Application user / pass-through) 유지

# ---------------------------------------------------------------------------
# 3. 디렉터리 검색 활성화
# ---------------------------------------------------------------------------
Write-Step 'Directory Browsing 활성화'
Set-WebConfigurationProperty -PSPath $apphost -Location $location `
    -Filter 'system.webServer/directoryBrowse' -Name enabled -Value $true
Write-Ok "Directory Browsing = True ($location)"

# ---------------------------------------------------------------------------
# 4. MIME 타입
# ---------------------------------------------------------------------------
Write-Step 'MIME 타입 설정'
$smFilter = 'system.webServer/staticContent'

function Get-MimeEntry([string]$ext) {
    Get-WebConfiguration -PSPath $apphost -Location $location -Filter "$smFilter/mimeMap" |
        Where-Object { $_.fileExtension -ieq $ext }
}

function Set-Mime([string]$ext, [string]$type, [switch]$OnlyIfMissing) {
    $cur = Get-MimeEntry $ext
    if ($cur) {
        if ($OnlyIfMissing) {
            Write-Info ("{0,-7} 이미 존재 ({1}) - 유지" -f $ext, $cur.mimeType)
            return
        }
        if ($cur.mimeType -eq $type) {
            Write-Info ("{0,-7} 이미 {1}" -f $ext, $type)
            return
        }
        # 상속된 항목이면 <remove> 로, 로컬 항목이면 삭제
        Remove-WebConfigurationProperty -PSPath $apphost -Location $location -Filter $smFilter `
            -Name '.' -AtElement @{ fileExtension = $cur.fileExtension }
    }
    Add-WebConfigurationProperty -PSPath $apphost -Location $location -Filter $smFilter `
        -Name '.' -Value @{ fileExtension = $ext; mimeType = $type }
    Write-Ok ("{0,-7} -> {1}" -f $ext, $type)
}

# 4-1. 반드시 text/plain 으로 지정
foreach ($ext in '.sign', '.json', '.iso', '.xz') {
    Set-Mime $ext 'text/plain'
}

# 4-2. 존재해야 하는 확장자 (없으면 application/x-iso9660-image 로 추가)
$requiredExt = '.BD', '.bin', '.csv', '.exe', '.frm', '.ftd', '.gz', '.jed',
               '.lod', '.md', '.qcow2', '.std', '.tgz', '.vib'
#      문서 기준: 기존 항목은 유지. -OverrideExistingMime 지정 시 기존 값도 변경.
foreach ($ext in $requiredExt) {
    Set-Mime $ext 'application/x-iso9660-image' -OnlyIfMissing:(-not $OverrideExistingMime)
}

# ---------------------------------------------------------------------------
# 5. 요청 필터링 예외
# ---------------------------------------------------------------------------
Write-Step '요청 필터링(Request Filtering) 예외 확인'
$rfFilter = 'system.webServer/security/requestFiltering/fileExtensions'
$allExt   = @('.sign', '.json', '.iso', '.xz') + $requiredExt
$allowUnlisted = (Get-WebConfigurationProperty -PSPath $apphost -Location $location `
                    -Filter $rfFilter -Name allowUnlisted).Value

foreach ($ext in $allExt) {
    $entry = Get-WebConfiguration -PSPath $apphost -Location $location -Filter "$rfFilter/add" |
             Where-Object { $_.fileExtension -ieq $ext }
    if ($entry -and $entry.allowed) { continue }
    if ($entry -and -not $entry.allowed) {
        Remove-WebConfigurationProperty -PSPath $apphost -Location $location -Filter $rfFilter `
            -Name '.' -AtElement @{ fileExtension = $entry.fileExtension }
    }
    if ($entry -or -not $allowUnlisted) {
        Add-WebConfigurationProperty -PSPath $apphost -Location $location -Filter $rfFilter `
            -Name '.' -Value @{ fileExtension = $ext; allowed = $true }
        Write-Ok "$ext 허용 추가"
    }
}
Write-Ok "요청 필터링 점검 완료 (allowUnlisted=$allowUnlisted)"

# ---------------------------------------------------------------------------
# 6. NTFS 권한
# ---------------------------------------------------------------------------
Write-Step '폴더 권한 설정 (IUSR / IIS_IUSRS 읽기)'
& icacls $PhysicalPath /grant 'IUSR:(OI)(CI)RX' 'IIS_IUSRS:(OI)(CI)RX' /T /C /Q | Out-Null
Write-Ok "IUSR, IIS_IUSRS -> Read & Execute ($PhysicalPath)"

# ---------------------------------------------------------------------------
# 7. 번들 압축 해제 (선택)
# ---------------------------------------------------------------------------
if ($BundlePath.Count -gt 0) {
    Write-Step '다크사이트 번들 압축 해제'
    foreach ($b in $BundlePath) {
        if (-not (Test-Path $b)) { Write-Warn2 "파일 없음: $b"; continue }
        Write-Info "해제 중: $b"
        if ($b -match '\.zip$') {
            Expand-Archive -Path $b -DestinationPath $PhysicalPath -Force
        } else {
            # Windows Server 2019 이상 기본 내장 tar.exe 사용 (.tar.gz / .tgz / .tar)
            if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
                throw 'tar.exe 가 없습니다. 7-Zip 등으로 직접 release 폴더에 풀어주세요.'
            }
            & tar.exe -xf $b -C $PhysicalPath
            if ($LASTEXITCODE -ne 0) { throw "압축 해제 실패: $b" }
        }
        Write-Ok "완료: $b"
    }
    # 새로 생긴 파일에도 권한 상속 재적용
    & icacls $PhysicalPath /grant 'IUSR:(OI)(CI)RX' 'IIS_IUSRS:(OI)(CI)RX' /T /C /Q | Out-Null
}

# ---------------------------------------------------------------------------
# 8. 파일/폴더 이름 소문자 변환
# ---------------------------------------------------------------------------
if (-not $SkipLowercase) {
    Write-Step '파일/폴더 이름 소문자 변환 (LCM 은 대문자 파일을 무시함)'
    $renamed = 0
    # 깊은 경로부터 처리해야 상위 폴더 이름 변경이 하위 경로를 깨뜨리지 않음
    $items = Get-ChildItem -LiteralPath $PhysicalPath -Recurse -Force |
             Sort-Object { $_.FullName.Length } -Descending
    foreach ($i in $items) {
        $lower = $i.Name.ToLowerInvariant()
        if ($i.Name -cne $lower) {
            # 대소문자만 다른 이름은 바로 변경이 안 되므로 임시 이름을 거침
            $tmp = "$lower.__tmp__$([guid]::NewGuid().ToString('N').Substring(0,6))"
            $parent = Split-Path -LiteralPath $i.FullName -Parent
            Rename-Item -LiteralPath $i.FullName -NewName $tmp
            Rename-Item -LiteralPath (Join-Path $parent $tmp) -NewName $lower
            $renamed++
        }
    }
    Write-Ok "$renamed 개 항목 이름 변경"
}

# ---------------------------------------------------------------------------
# 9. 방화벽 / 서비스 / 확인
# ---------------------------------------------------------------------------
Write-Step '방화벽 및 서비스 확인'
$fw = Get-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP' -ErrorAction SilentlyContinue
if ($fw) {
    Enable-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP'
} elseif (-not (Get-NetFirewallRule -DisplayName 'LCM Dark Site HTTP 80' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'LCM Dark Site HTTP 80' -Direction Inbound -Protocol TCP `
        -LocalPort 80 -Action Allow | Out-Null
}
Write-Ok '인바운드 TCP 80 허용'

Set-Service W3SVC -StartupType Automatic
Start-Service W3SVC
if ((Get-Website -Name $SiteName).State -ne 'Started') { Start-Website -Name $SiteName }
Write-Ok "W3SVC 실행 중, 사이트 '$SiteName' 시작됨"

Write-Step '동작 확인'
try {
    $r = Invoke-WebRequest -Uri "http://localhost/$VDirName/" -UseBasicParsing -TimeoutSec 10
    Write-Ok "http://localhost/$VDirName/ 응답 $($r.StatusCode) (디렉터리 목록 정상)"
} catch {
    Write-Warn2 "http://localhost/$VDirName/ 접근 실패: $($_.Exception.Message)"
}

$manifest = Join-Path $PhysicalPath 'master_manifest.tgz.sign'
if (Test-Path $manifest) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost/$VDirName/master_manifest.tgz.sign" -UseBasicParsing -TimeoutSec 10
        Write-Ok "master_manifest.tgz.sign 다운로드 확인 ($($r.StatusCode))"
    } catch {
        Write-Warn2 "master_manifest.tgz.sign 다운로드 실패: $($_.Exception.Message)"
    }
} else {
    Write-Warn2 "release 폴더 바로 아래에 master_manifest.tgz.sign 이 없습니다."
    Write-Warn2 "번들을 풀었을 때 하위 폴더가 하나 더 생겼다면 그 안의 내용을 $PhysicalPath 로 옮기세요."
}

$ips = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress
Write-Host "`n완료!  Prism 의 LCM > Settings > Source 에 아래 URL 중 하나를 입력하세요." -ForegroundColor Green
foreach ($ip in $ips) { Write-Host "    http://$ip/$VDirName" -ForegroundColor White }
Write-Host "  * 프록시를 쓰는 환경이면 이 서버 IP 를 Prism 프록시 allow-list 에 추가하세요." -ForegroundColor Gray
Write-Host "  * HTTPS 를 쓸 경우 공인 CA 인증서만 허용됩니다 (사설 CA 는 KB 5090 참조)." -ForegroundColor Gray
