# Y-MATH 실적관리 - 로컬 서버
# 이 창을 닫으면 프로그램이 꺼져요.
param([switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'Y-MATH 실적관리 (이 창을 닫으면 프로그램이 꺼져요)'

$AppVersion = '1.0.1'
$RepoRaw    = 'https://raw.githubusercontent.com/ymath0408/ymath-silj/main'
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = $MyInvocation.MyCommand.Path
# 프로그램이 NAS(네트워크 폴더)에 있으면 'NAS 모드': GitHub 대신 NAS 파일이 바뀌면 자동 적용
$IsNetwork = $false
try {
  if ($Root.StartsWith('\\')) { $IsNetwork = $true }
  else { $IsNetwork = ((New-Object System.IO.DriveInfo([IO.Path]::GetPathRoot($Root))).DriveType -eq 'Network') }
} catch {}
$VersionFile = Join-Path $Root 'version.json'
$PcName     = ($env:COMPUTERNAME -replace '[^\w-]', '')
$LocalDir   = Join-Path (Join-Path $Root 'local') $PcName   # 이 PC 전용 (에듀OK 비밀번호, 설정, 코드 백업) - 프로그램을 NAS에 둬도 PC끼리 안 섞임
$ConfigFile = Join-Path $LocalDir 'config.json'
$CredFile   = Join-Path $LocalDir 'eok.cred'
$LogFile    = Join-Path $LocalDir 'server.log'
$NoteFile   = Join-Path $LocalDir 'update_note.json'
$AppFile    = Join-Path $Root 'app.html'
$Port       = 47615
$EokBase    = 'https://newpremium.edu-ok.co.kr:403'
$UA         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Euc        = [System.Text.Encoding]::GetEncoding(949)
$script:EokSession = $null
$script:LastAutoBackup = [DateTime]::MinValue
$script:Restart = $false

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
# v1.0.0은 local\ 바로 아래에 저장했음 → 이 PC 폴더로 옮김
foreach ($n in @('config.json', 'eok.cred', 'update_note.json')) {
  $old = Join-Path (Join-Path $Root 'local') $n
  $new = Join-Path $LocalDir $n
  if ((Test-Path $old) -and -not (Test-Path $new)) { try { Move-Item $old $new -Force } catch {} }
}

function Load-Config {
  if (Test-Path $ConfigFile) { try { return ([IO.File]::ReadAllText($ConfigFile, $Utf8) | ConvertFrom-Json) } catch {} }
  return New-Object PSObject
}
function Save-Config($cfg) { [IO.File]::WriteAllText($ConfigFile, ($cfg | ConvertTo-Json -Compress), $Utf8) }
# 실적 데이터 폴더 (4대가 같이 쓰려면 OneDrive 공유 폴더로 지정)
function Set-DataDir([string]$dir) {
  $script:DataDir   = $dir
  $script:BackupDir = Join-Path $dir 'backup'
  $script:DataFile  = Join-Path $dir 'silj.json'
  New-Item -ItemType Directory -Force -Path $script:DataDir, $script:BackupDir | Out-Null
}
$cfg0 = Load-Config
$script:DataOffline = $null
if ($cfg0.dataDir) {
  # 지정한 공유 폴더(NAS)가 안 열리면 이 PC 폴더로 몰래 바꾸지 않고 오류로 알림 (데이터가 갈라지는 것 방지)
  if (Test-Path -LiteralPath $cfg0.dataDir) { Set-DataDir $cfg0.dataDir } else { $script:DataOffline = [string]$cfg0.dataDir; $script:DataDir = $script:DataOffline; $script:DataFile = Join-Path $script:DataOffline 'silj.json'; $script:BackupDir = Join-Path $script:DataOffline 'backup' }
} else { Set-DataDir (Join-Path $Root 'data') }
function Test-DataOnline {
  if ($script:DataOffline -eq $null) { return $true }
  if (Test-Path -LiteralPath $script:DataOffline) { Set-DataDir $script:DataOffline; $script:DataOffline = $null; Write-Log ('데이터 폴더 다시 연결됨: ' + $script:DataDir); return $true }
  return $false
}

function Write-Log([string]$msg) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $msg
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
  Write-Host $line
}

# ---------------- HTTP ----------------
function Read-Request($stream) {
  $buf = New-Object byte[] 65536
  $ms = New-Object System.IO.MemoryStream
  $headerEnd = -1
  while ($headerEnd -lt 0) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { return $null }
    $ms.Write($buf, 0, $n)
    $ascii = [Text.Encoding]::ASCII.GetString($ms.ToArray())
    $headerEnd = $ascii.IndexOf("`r`n`r`n")
    if ($ms.Length -gt 1MB -and $headerEnd -lt 0) { return $null }
  }
  $head = $ascii.Substring(0, $headerEnd)
  $lines = $head -split "`r`n"
  $first = $lines[0] -split ' '
  $headers = @{}
  foreach ($l in $lines[1..($lines.Length - 1)]) {
    $i = $l.IndexOf(':')
    if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim() }
  }
  $len = 0
  if ($headers.ContainsKey('content-length')) { $len = [int]$headers['content-length'] }
  $need = $headerEnd + 4 + $len
  while ($ms.Length -lt $need) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $ms.Write($buf, 0, $n)
  }
  $all = $ms.ToArray()
  $body = ''
  if ($len -gt 0) { $body = $Utf8.GetString($all, $headerEnd + 4, [Math]::Min($len, $all.Length - $headerEnd - 4)) }
  $path = $first[1]; $query = ''
  $q = $path.IndexOf('?')
  if ($q -ge 0) { $query = $path.Substring($q + 1); $path = $path.Substring(0, $q) }
  return @{ Method = $first[0]; Path = [Uri]::UnescapeDataString($path); Query = $query; Headers = $headers; Body = $body }
}

function Send-Bytes($stream, [int]$code, [string]$ctype, [byte[]]$bytes) {
  $status = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 409 = 'Conflict'; 500 = 'Internal Server Error'; 503 = 'Service Unavailable' }[$code]
  $h = "HTTP/1.1 $code $status`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($h)
  $stream.Write($hb, 0, $hb.Length)
  if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
  $stream.Flush()
}
function Send-Text($stream, [int]$code, [string]$ctype, [string]$text) { Send-Bytes $stream $code $ctype ($Utf8.GetBytes($text)) }
function Send-Json($stream, [int]$code, $obj) { Send-Text $stream $code 'application/json; charset=utf-8' ($obj | ConvertTo-Json -Compress -Depth 5) }

function Get-QueryParam([string]$query, [string]$name) {
  foreach ($p in ($query -split '&')) {
    $kv = $p -split '=', 2
    if ($kv[0] -eq $name -and $kv.Length -eq 2) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
  }
  return ''
}

# ---------------- 데이터 / 백업 ----------------
function Get-FileRev {
  if (-not (Test-Path $DataFile)) { return 0 }
  $fs = [IO.File]::OpenRead($DataFile)
  try { $b = New-Object byte[] 200; $n = $fs.Read($b, 0, 200); $s = $Utf8.GetString($b, 0, $n) } finally { $fs.Close() }
  $m = [regex]::Match($s, '"rev"\s*:\s*(\d+)')
  if ($m.Success) { return [long]$m.Groups[1].Value }
  return 0
}

function Backup-Data([string]$reason) {
  if (-not (Test-Path $DataFile)) { return '' }
  $safe = ($reason -replace '[^\w가-힣-]', '')
  if ($safe -eq '') { $safe = 'auto' }
  $name = 'silj_' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '_' + $safe + '_' + ($env:COMPUTERNAME -replace '[^\w-]', '') + '.json'
  Copy-Item $DataFile (Join-Path $BackupDir $name) -Force
  # 오래된 백업 정리 (최근 300개만 보관)
  $files = Get-ChildItem $BackupDir -Filter 'silj_*.json' | Sort-Object LastWriteTime -Descending
  if ($files.Count -gt 300) { $files | Select-Object -Skip 300 | Remove-Item -Force }
  return $name
}

# ---------------- 에듀OK 비밀번호 (이 컴퓨터의 Windows 계정으로 암호화) ----------------
function Save-Cred([string]$id, [string]$pw) {
  $sec = ConvertTo-SecureString $pw -AsPlainText -Force
  $enc = ConvertFrom-SecureString $sec
  $obj = @{ id = $id; pwEnc = $enc; at = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
  [IO.File]::WriteAllText($CredFile, ($obj | ConvertTo-Json -Compress), $Utf8)
}
function Load-Cred {
  if (-not (Test-Path $CredFile)) { return $null }
  $o = [IO.File]::ReadAllText($CredFile, $Utf8) | ConvertFrom-Json
  try {
    $sec = ConvertTo-SecureString $o.pwEnc
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  } catch { return @{ id = $o.id; pw = $null; at = $o.at } }
  return @{ id = $o.id; pw = $pw; at = $o.at }
}

# ---------------- 에듀OK ----------------
function Decode-Euc($resp) {
  $ms = $resp.RawContentStream
  $ms.Position = 0
  return $Euc.GetString($ms.ToArray())
}
function Form-Body([object[]]$pairs) {
  $parts = @()
  for ($i = 0; $i -lt $pairs.Length; $i += 2) { $parts += ([Uri]::EscapeDataString([string]$pairs[$i]) + '=' + [Uri]::EscapeDataString([string]$pairs[$i + 1])) }
  return ($parts -join '&')
}
function Eok-Request([string]$url, [string]$method = 'GET', [string]$body = $null, [string]$referer = $null) {
  $p = @{ Uri = $url; Method = $method; WebSession = $script:EokSession; UseBasicParsing = $true; UserAgent = $UA; TimeoutSec = 60 }
  $h = @{}
  if ($referer) { $h['Referer'] = $referer }
  $p['Headers'] = $h
  if ($body -ne $null -and $method -eq 'POST') { $p['Body'] = $body; $p['ContentType'] = 'application/x-www-form-urlencoded' }
  return Invoke-WebRequest @p
}
function Eok-Login {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $cred = Load-Cred
  if ($cred -eq $null) { throw '에듀OK 아이디와 비밀번호가 아직 저장되지 않았어요. [설정]에서 먼저 저장해 주세요.' }
  if ($cred.pw -eq $null) { throw '이 컴퓨터에서는 저장된 비밀번호를 읽을 수 없어요. [설정]에서 비밀번호를 다시 저장해 주세요.' }
  $script:EokSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $null = Eok-Request "$EokBase/center_login_new.asp"
  $body = Form-Body @('GoUrl', '', 'Phone', '', 'PopupYN', 'N', 'pass_rule_err', '0', 'j_username', $cred.id, 'j_password', $cred.pw)
  $null = Eok-Request "$EokBase/logon_check.asp" 'POST' $body "$EokBase/center_login_new.asp"
  $r = Eok-Request "$EokBase/content/stud/in.asp"
  $t = Decode-Euc $r
  if ($t -notmatch '로그아웃' -or $t -match 'j_password') {
    $script:EokSession = $null
    throw '에듀OK 로그인에 실패했어요. 아이디/비밀번호를 확인해 주세요. (에듀OK 비밀번호를 바꿨다면 [설정]에서 다시 저장)'
  }
  Write-Log ('에듀OK 로그인 성공: ' + $cred.id)
}
function Eok-Students {
  $null = Eok-Request "$EokBase/content/stud/in.asp"
  $null = Eok-Request "$EokBase/content/stud/inlist_ifrm.asp"
  $body = Form-Body @('ViewStudentSearch', '1', 'GotoPage', '1', 'DetailInfo_key', '1', 'Search_class', '', 'student_list', '', 'mode', '', 'gubun', '',
    'Order', 'StudentName', 'Direction', 'asc', 'Search_value_temp', '', 'ListCount', '20', 'operateState', '', 'classGubun', '',
    'Search_mainteacher', '', 'Search_teacher', '', 'Search_key', '1', 'Search_value', '', 'StudentChk', 'on', 'ParentChk', 'on', 'ParentChk2', 'on',
    'chk_dm_gubun', '0', 'chk_dm_gubun', '1')
  $r = Eok-Request "$EokBase/content/stud/inlist_ifrm_excel_03.asp" 'POST' $body "$EokBase/content/stud/inlist_ifrm.asp"
  $t = Decode-Euc $r
  if ($t -notmatch '재학생명부') { throw '에듀OK에서 재학생명부를 받지 못했어요.' }
  Write-Log ('재학생명부 받음 ' + $t.Length + '자')
  return $t
}
function Eok-Outs {
  $list = "$EokBase/content/stud/student_list.asp?menu1=101&menu2=10104&StateCode=0103&AspUrl=student_list.asp"
  $null = Eok-Request $list
  $body = Form-Body @('new_max_number', '', 'new_basicPrice', '', 'listgubun', '1', 'GotoPage', '1', 'menu1', '101', 'menu2', '10104', 'StateCode', '0103',
    'student_list', '', 'mode', '', 'gubun', '', 'Order', 'StateDayStart', 'Direction', 'desc', 'Search_value_temp', '', 'DayGubun', '4', 'ListCount', '10',
    'Search_key', '1', 'DayGubun', '1', 'fromdate', '', 'todate', '', 'StudentChk', 'on', 'ParentChk', 'on', 'ParentChk2', 'on')
  $r = Eok-Request "$EokBase/content/stud/student_list_excel.asp" 'POST' $body $list
  $t = Decode-Euc $r
  if ($t -notmatch '퇴원생명부') { throw '에듀OK에서 퇴원생명부를 받지 못했어요.' }
  Write-Log ('퇴원생명부 받음 ' + $t.Length + '자')
  return $t
}

# ---------------- 자동 업데이트 (GitHub) ----------------
function Get-RemoteVersion {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $r = Invoke-WebRequest ("$RepoRaw/version.json?t=" + [DateTime]::Now.Ticks) -UseBasicParsing -TimeoutSec 8 -Headers @{ 'Cache-Control' = 'no-cache' }
  $ms = $r.RawContentStream; $ms.Position = 0
  return ($Utf8.GetString($ms.ToArray()) | ConvertFrom-Json)
}
function Get-LocalVersionInfo {
  if (-not (Test-Path -LiteralPath $VersionFile)) { return $null }
  try { return ([IO.File]::ReadAllText($VersionFile, $Utf8) | ConvertFrom-Json) } catch { return $null }
}
function Is-Newer([string]$remote, [string]$local) { try { return ([version]$remote -gt [version]$local) } catch { return $false } }
function Install-Update($info) {
  $tmp = Join-Path $LocalDir 'update_tmp'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  foreach ($f in $info.files) {
    if ($f.name -notmatch '^[A-Za-z0-9_.-]+$') { throw ('잘못된 파일 이름: ' + $f.name) }
    $dest = Join-Path $tmp $f.name
    Invoke-WebRequest ("$RepoRaw/" + $f.name + '?t=' + [DateTime]::Now.Ticks) -OutFile $dest -UseBasicParsing -TimeoutSec 60
    $h = (Get-FileHash $dest -Algorithm SHA256).Hash
    if ($h -ne ([string]$f.sha256).ToUpper()) { throw ('받은 파일이 올바르지 않아요: ' + $f.name + ' (잠시 뒤 다시 시도)') }
  }
  $bk = Join-Path $LocalDir ('code_backup\v' + $AppVersion)
  New-Item -ItemType Directory -Force -Path $bk | Out-Null
  foreach ($f in $info.files) {
    $cur = Join-Path $Root $f.name
    if (Test-Path $cur) { Copy-Item $cur (Join-Path $bk $f.name) -Force }
  }
  foreach ($f in $info.files) { Copy-Item (Join-Path $tmp $f.name) (Join-Path $Root $f.name) -Force }
  Remove-Item $tmp -Recurse -Force
  $note = @{ from = $AppVersion; to = [string]$info.version; notes = @($info.notes); at = (Get-Date -Format 'yyyy-MM-dd HH:mm'); seen = $false }
  [IO.File]::WriteAllText($NoteFile, ($note | ConvertTo-Json -Compress -Depth 4), $Utf8)
  Write-Log ('업데이트 설치: v' + $AppVersion + ' -> v' + $info.version)
}
function Start-Self([bool]$openBrowser) {
  $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-File', ('"' + $ScriptPath + '"'))
  if (-not $openBrowser) { $args2 += '-NoBrowser' }
  Start-Process powershell.exe -ArgumentList $args2
}
function Get-CodeBackups {
  $d = Join-Path $LocalDir 'code_backup'
  if (-not (Test-Path $d)) { return @() }
  return @(Get-ChildItem $d -Directory | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.Name })
}

# ---------------- 라우팅 ----------------
function Handle-Client($client) {
  $client.ReceiveTimeout = 10000
  $stream = $client.GetStream()
  $req = Read-Request $stream
  if ($req -eq $null) { return }

  # 다른 사이트에서 이 프로그램을 건드리지 못하게 막음
  $hostH = [string]$req.Headers['host']
  if ($hostH -ne "localhost:$Port" -and $hostH -ne "127.0.0.1:$Port") { Send-Text $stream 403 'text/plain; charset=utf-8' 'forbidden'; return }
  if ($req.Path.StartsWith('/api/') -and $req.Headers['x-silj'] -ne '1') { Send-Text $stream 403 'text/plain; charset=utf-8' 'forbidden'; return }

  try {
    switch ($req.Path) {
      '/' {
        if ($IsNetwork) {
          $li = Get-LocalVersionInfo
          if ($li -ne $null -and [string]$li.version -ne $AppVersion) {
            $note = @{ from = $AppVersion; to = [string]$li.version; notes = @($li.notes); at = (Get-Date -Format 'yyyy-MM-dd HH:mm'); seen = $false }
            [IO.File]::WriteAllText($NoteFile, ($note | ConvertTo-Json -Compress -Depth 4), $Utf8)
            Write-Log ('NAS 새 버전 적용: v' + $AppVersion + ' -> v' + $li.version)
            Send-Text $stream 200 'text/html; charset=utf-8' '<!DOCTYPE html><meta charset="utf-8"><meta http-equiv="refresh" content="4"><body style="background:#141821;color:#e7eaf1;font-family:Malgun Gothic,sans-serif;display:flex;align-items:center;justify-content:center;height:90vh"><h2>새 버전으로 바꾸는 중이에요… 잠시만요</h2></body>'
            $script:Restart = $true; $script:Quit = $true
            return
          }
        }
        $html = [IO.File]::ReadAllBytes($AppFile)
        Send-Bytes $stream 200 'text/html; charset=utf-8' $html
      }
      '/api/ping' { Send-Json $stream 200 @{ ok = $true; pc = $env:COMPUTERNAME; root = $Root } }
      '/api/data' {
        if (-not (Test-DataOnline)) { Send-Json $stream 503 @{ error = ('데이터 폴더에 연결할 수 없어요: ' + $script:DataOffline + ' — NAS가 켜져 있는지, 이 PC에서 그 폴더가 열리는지 확인해 주세요.'); offline = $true; dir = $script:DataOffline }; return }
        if ($req.Method -eq 'GET') {
          if (Test-Path $DataFile) { Send-Bytes $stream 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($DataFile)) }
          else { Send-Text $stream 200 'application/json; charset=utf-8' '{"rev":0}' }
        } else {
          $base = [long]$req.Headers['x-base-rev']
          $cur = Get-FileRev
          if ($cur -ne $base) { Send-Json $stream 409 @{ error = '다른 컴퓨터에서 먼저 고쳤어요. 새로 불러올게요.'; rev = $cur }; return }
          if ((Test-Path $DataFile) -and ((Get-Date) - $script:LastAutoBackup).TotalMinutes -ge 30) { $null = Backup-Data 'auto'; $script:LastAutoBackup = Get-Date }
          $tmp = $DataFile + '.tmp'
          [IO.File]::WriteAllText($tmp, $req.Body, $Utf8)
          Move-Item $tmp $DataFile -Force
          Send-Json $stream 200 @{ ok = $true; rev = (Get-FileRev) }
        }
      }
      '/api/backup' {
        if (-not (Test-DataOnline)) { Send-Json $stream 503 @{ error = ('데이터 폴더에 연결할 수 없어요: ' + $script:DataOffline + ' — NAS가 켜져 있는지, 이 PC에서 그 폴더가 열리는지 확인해 주세요.'); offline = $true; dir = $script:DataOffline }; return }
        $name = Backup-Data (Get-QueryParam $req.Query 'reason')
        Send-Json $stream 200 @{ ok = $true; name = $name }
      }
      '/api/backups' {
        if (-not (Test-DataOnline)) { Send-Json $stream 503 @{ error = ('데이터 폴더에 연결할 수 없어요: ' + $script:DataOffline + ' — NAS가 켜져 있는지, 이 PC에서 그 폴더가 열리는지 확인해 주세요.'); offline = $true; dir = $script:DataOffline }; return }
        $files = @(Get-ChildItem $BackupDir -Filter 'silj_*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 50 | ForEach-Object { $_.Name })
        Send-Json $stream 200 @{ files = $files }
      }
      '/api/restore' {
        $name = Get-QueryParam $req.Query 'name'
        if ($name -notmatch '^silj_[\w가-힣-]+\.json$') { Send-Json $stream 400 @{ error = '잘못된 백업 이름' }; return }
        $src = Join-Path $BackupDir $name
        if (-not (Test-Path $src)) { Send-Json $stream 404 @{ error = '백업 파일이 없어요' }; return }
        $null = Backup-Data '복원전'
        Send-Bytes $stream 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($src))
      }
      '/api/cred' {
        if ($req.Method -eq 'GET') {
          $c = Load-Cred
          if ($c -eq $null) { Send-Json $stream 200 @{ saved = $false; pc = $env:COMPUTERNAME } }
          else { Send-Json $stream 200 @{ saved = $true; id = $c.id; at = $c.at; readable = ($c.pw -ne $null); pc = $env:COMPUTERNAME } }
        } else {
          $o = $req.Body | ConvertFrom-Json
          if (-not $o.id -or -not $o.pw) { Send-Json $stream 400 @{ error = '아이디와 비밀번호를 모두 넣어 주세요.' }; return }
          Save-Cred ([string]$o.id) ([string]$o.pw)
          $script:EokSession = $null
          Write-Log ('에듀OK 계정 저장: ' + $o.id)
          Send-Json $stream 200 @{ ok = $true }
        }
      }
      '/api/eok/login' {
        try { Eok-Login; Send-Json $stream 200 @{ ok = $true } }
        catch { Write-Log ('로그인 오류: ' + $_.Exception.Message); Send-Json $stream 500 @{ error = $_.Exception.Message } }
      }
      '/api/eok/students' {
        try {
          if ($script:EokSession -eq $null) { Eok-Login }
          try { $t = Eok-Students } catch { Eok-Login; $t = Eok-Students }
          Send-Text $stream 200 'text/plain; charset=utf-8' $t
        } catch { Write-Log ('재학생명부 오류: ' + $_.Exception.Message); Send-Json $stream 500 @{ error = $_.Exception.Message } }
      }
      '/api/eok/outs' {
        try {
          if ($script:EokSession -eq $null) { Eok-Login }
          try { $t = Eok-Outs } catch { Eok-Login; $t = Eok-Outs }
          Send-Text $stream 200 'text/plain; charset=utf-8' $t
        } catch { Write-Log ('퇴원생명부 오류: ' + $_.Exception.Message); Send-Json $stream 500 @{ error = $_.Exception.Message } }
      }
      '/api/version' {
        $note = $null
        if (Test-Path $NoteFile) { try { $note = [IO.File]::ReadAllText($NoteFile, $Utf8) | ConvertFrom-Json } catch {} }
        if ($note -ne $null -and -not $note.seen) { $note.seen = $true; [IO.File]::WriteAllText($NoteFile, ($note | ConvertTo-Json -Compress -Depth 4), $Utf8); $note.seen = $false }
        Send-Json $stream 200 @{ version = $AppVersion; note = $note; backups = (Get-CodeBackups); pc = $env:COMPUTERNAME; nas = $IsNetwork; root = $Root }
      }
      '/api/update/check' {
        if ($IsNetwork) { Send-Json $stream 200 @{ current = $AppVersion; latest = $AppVersion; newer = $false; nas = $true; notes = @() }; return }
        try { $info = Get-RemoteVersion; Send-Json $stream 200 @{ current = $AppVersion; latest = [string]$info.version; newer = (Is-Newer ([string]$info.version) $AppVersion); notes = @($info.notes) } }
        catch { Send-Json $stream 500 @{ error = ('업데이트 정보를 받지 못했어요: ' + $_.Exception.Message) } }
      }
      '/api/update/apply' {
        try {
          if ($IsNetwork) { Send-Json $stream 200 @{ ok = $true; same = $true }; return }
          $info = Get-RemoteVersion
          if (-not (Is-Newer ([string]$info.version) $AppVersion)) { Send-Json $stream 200 @{ ok = $true; same = $true }; return }
          Install-Update $info
          Send-Json $stream 200 @{ ok = $true; to = [string]$info.version }
          $script:Restart = $true; $script:Quit = $true
        } catch { Write-Log ('업데이트 오류: ' + $_.Exception.Message); Send-Json $stream 500 @{ error = $_.Exception.Message } }
      }
      '/api/update/rollback' {
        $v = Get-QueryParam $req.Query 'v'
        if ($v -notmatch '^v[\d.]+$') { Send-Json $stream 400 @{ error = '잘못된 버전' }; return }
        $src = Join-Path (Join-Path $LocalDir 'code_backup') $v
        if (-not (Test-Path $src)) { Send-Json $stream 404 @{ error = '그 버전 백업이 없어요' }; return }
        foreach ($f in (Get-ChildItem $src -File)) { Copy-Item $f.FullName (Join-Path $Root $f.Name) -Force }
        $cfg = Load-Config; $cfg | Add-Member -NotePropertyName skipVersion -NotePropertyValue $AppVersion -Force; Save-Config $cfg
        Write-Log ('되돌림: ' + $v)
        Send-Json $stream 200 @{ ok = $true }
        $script:Restart = $true; $script:Quit = $true
      }
      '/api/rev' {
        if (-not (Test-DataOnline)) { Send-Json $stream 503 @{ error = ('데이터 폴더에 연결할 수 없어요: ' + $script:DataOffline + ' — NAS가 켜져 있는지, 이 PC에서 그 폴더가 열리는지 확인해 주세요.'); offline = $true; dir = $script:DataOffline }; return }
        Send-Json $stream 200 @{ rev = (Get-FileRev) }
      }
      '/api/datadir' {
        if ($req.Method -eq 'GET') {
          $online = Test-DataOnline
          $conf = @()
          if ($online) { $conf = @(Get-ChildItem -LiteralPath $DataDir -Filter 'silj*.json' -File | Where-Object { $_.Name -ne 'silj.json' } | ForEach-Object { $_.Name }) }
          Send-Json $stream 200 @{ dir = $DataDir; default = (Join-Path $Root 'data'); conflicts = $conf; online = $online }
        } else {
          $o = $req.Body | ConvertFrom-Json
          $dir = ([string]$o.dir).Trim().Trim('"')
          if (-not [IO.Path]::IsPathRooted($dir)) { Send-Json $stream 400 @{ error = '전체 경로를 넣어 주세요. 예: \\NAS이름\5.보스\실적관리' }; return }
          try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { Send-Json $stream 400 @{ error = ('그 폴더를 만들거나 열 수 없어요: ' + $dir) }; return }
          $target = Join-Path $dir 'silj.json'
          $mode = 'use'
          if (-not (Test-Path -LiteralPath $target) -and $script:DataOffline -eq $null -and (Test-Path -LiteralPath $DataFile)) { Copy-Item -LiteralPath $DataFile $target; $mode = 'copied' }
          Set-DataDir $dir; $script:DataOffline = $null
          $cfg = Load-Config; $cfg | Add-Member -NotePropertyName dataDir -NotePropertyValue $dir -Force; Save-Config $cfg
          Write-Log ('데이터 폴더 변경: ' + $dir + ' (' + $mode + ')')
          Send-Json $stream 200 @{ ok = $true; dir = $dir; mode = $mode }
        }
      }
      '/api/quit' { Send-Json $stream 200 @{ ok = $true }; $script:Quit = $true }
      default { Send-Text $stream 404 'text/plain; charset=utf-8' 'not found' }
    }
  } catch {
    Write-Log ('오류: ' + $_.Exception.Message)
    try { Send-Json $stream 500 @{ error = $_.Exception.Message } } catch {}
  }
}

# ---------------- 시작 ----------------
# 켤 때 새 버전이 있으면 자동으로 설치하고 다시 켬
if (-not $NoBrowser -and -not $IsNetwork) {
  try {
    $info = Get-RemoteVersion
    $skip = [string](Load-Config).skipVersion
    $want = (Is-Newer ([string]$info.version) $AppVersion) -and (-not $skip -or (Is-Newer ([string]$info.version) $skip))
    if ($want) {
      Write-Log ('새 버전 발견: v' + $info.version)
      Install-Update $info
      Start-Self $true
      exit
    }
  } catch { Write-Log ('업데이트 확인 건너뜀: ' + $_.Exception.Message) }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$started = $false
for ($i = 0; $i -lt 20 -and -not $started; $i++) {
  try { $listener.Start(); $started = $true } catch { if ($NoBrowser) { Start-Sleep -Milliseconds 300 } else { break } }
}
if (-not $started) {
  # 이미 켜져 있으면 브라우저만 열기
  Start-Process "http://localhost:$Port/"
  exit
}
Write-Log ("실적관리 v$AppVersion 시작 (http://localhost:$Port/)  데이터: $DataDir" + $(if ($IsNetwork) { '  [NAS 모드]' } else { '' }))
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }
$script:Quit = $false
# 브라우저가 미리 열어두는 빈 연결 때문에 멈추지 않도록, 데이터가 온 연결부터 처리
$pending = New-Object System.Collections.ArrayList
while (-not $script:Quit) {
  while ($listener.Pending()) { [void]$pending.Add(@{ c = $listener.AcceptTcpClient(); t = Get-Date }) }
  $handled = $false
  foreach ($p in @($pending)) {
    if ($p.c.Available -gt 0) {
      $pending.Remove($p)
      try { Handle-Client $p.c } catch { Write-Log ('연결 오류: ' + $_.Exception.Message) } finally { $p.c.Close() }
      $handled = $true
    } elseif (((Get-Date) - $p.t).TotalSeconds -gt 20 -or -not $p.c.Connected) {
      $pending.Remove($p); try { $p.c.Close() } catch {}
    }
  }
  if (-not $handled) { Start-Sleep -Milliseconds 15 }
}
$listener.Stop()
if ($script:Restart) { Write-Log '다시 켜는 중…'; Start-Self $false; exit }
Write-Log '실적관리 종료'
