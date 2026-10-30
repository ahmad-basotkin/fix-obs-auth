#requires -version 5.1
[CmdletBinding()]
param(
    [switch]$Relay,
    [int]$Port = 0,
    [string]$UpHost,
    [int]$UpPort = 0,
    [string]$UpUser,
    [string]$UpPass,
    [string]$LogPath,
    [string]$ListPath,
    [switch]$NoLaunch,
    [switch]$Test,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$Script:Host0 = 'auth.obsproject.com'
$Script:TmpDir = Join-Path $env:TEMP 'obs-auth-proxy'
$Script:StateFile = Join-Path $Script:TmpDir 'state.json'
$Script:RelayLog = Join-Path $Script:TmpDir 'relay.log'
$Script:RelayPidFile = Join-Path $Script:TmpDir 'relay.pid'
New-Item -ItemType Directory -Force -Path $Script:TmpDir | Out-Null

$Script:PublicLimit   = 30
$Script:PublicTimeout = 5000

$Script:CSharp = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class ObsAuthRelay
{
    private static string _upHost;
    private static int _upPort;
    private static string _auth;
    private static string _log;
    private static readonly object _logLock = new object();

    public static void Run(int port, string upHost, int upPort, string user, string pass, string logPath)
    {
        _upHost = upHost;
        _upPort = upPort;
        _auth = String.IsNullOrEmpty(user) ? null : "Basic " + Convert.ToBase64String(Encoding.ASCII.GetBytes(user + ":" + pass));
        _log = logPath;
        Log("start listen=127.0.0.1:" + port + " upstream=" + upHost + ":" + upPort + (_auth == null ? " (no auth)" : " (auth)"));
        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Log("listening");
        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            TcpClient captured = client;
            Thread th = new Thread(delegate() { Handle(captured); });
            th.IsBackground = true;
            th.Start();
        }
    }

    private static void Log(string message)
    {
        if (String.IsNullOrEmpty(_log)) return;
        try
        {
            lock (_logLock)
            {
                File.AppendAllText(_log, DateTime.Now.ToString("HH:mm:ss") + " " + message + "\r\n");
            }
        }
        catch { }
    }

    private static bool IsUpstreamHost(string host)
    {
        if (String.IsNullOrEmpty(host)) return false;
        host = host.TrimEnd('.').ToLowerInvariant();
        return host == "obsproject.com" || host.EndsWith(".obsproject.com", StringComparison.Ordinal);
    }

    private static void ParseHostPort(string text, out string host, out int port)
    {
        host = text;
        port = 443;
        if (text.StartsWith("["))
        {
            int close = text.IndexOf(']');
            if (close > 0)
            {
                host = text.Substring(1, close - 1);
                int p2;
                if (text.Length > close + 2 && Int32.TryParse(text.Substring(close + 2), out p2)) port = p2;
            }
            return;
        }
        int colon = text.LastIndexOf(':');
        if (colon > 0)
        {
            host = text.Substring(0, colon);
            int p;
            if (Int32.TryParse(text.Substring(colon + 1), out p)) port = p;
        }
    }

    private static byte[] ReadHead(Stream stream)
    {
        MemoryStream ms = new MemoryStream();
        int b;
        while ((b = stream.ReadByte()) >= 0)
        {
            ms.WriteByte((byte)b);
            int n = (int)ms.Length;
            if (n >= 4)
            {
                byte[] buf = ms.GetBuffer();
                if (buf[n - 4] == 13 && buf[n - 3] == 10 && buf[n - 2] == 13 && buf[n - 1] == 10) break;
            }
            if (n > 65536) break;
        }
        if (ms.Length == 0) return null;
        return ms.ToArray();
    }

    private static void WriteAscii(Stream stream, string text)
    {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    private static TcpClient OpenUpstream(string host, int port)
    {
        try
        {
            TcpClient up = new TcpClient();
            up.Connect(_upHost, _upPort);
            NetworkStream s = up.GetStream();
            string req = "CONNECT " + host + ":" + port + " HTTP/1.1\r\n"
                       + "Host: " + host + ":" + port + "\r\n"
                       + (_auth != null ? "Proxy-Authorization: " + _auth + "\r\n" : "")
                       + "Proxy-Connection: keep-alive\r\n\r\n";
            byte[] bytes = Encoding.ASCII.GetBytes(req);
            s.Write(bytes, 0, bytes.Length);
            s.ReadTimeout = 10000;
            byte[] head = ReadHead(s);
            s.ReadTimeout = Timeout.Infinite;
            if (head == null) { up.Close(); return null; }
            string resp = Encoding.ASCII.GetString(head);
            if (resp.IndexOf(" 200", StringComparison.Ordinal) < 0)
            {
                Log("upstream refused: " + resp.Split('\n')[0].Trim());
                up.Close();
                return null;
            }
            return up;
        }
        catch (Exception e)
        {
            Log("upstream error: " + e.Message);
            return null;
        }
    }

    private static void Tunnel(NetworkStream clientStream, NetworkStream remoteStream, TcpClient client, TcpClient remote)
    {
        Thread th = new Thread(delegate()
        {
            try { clientStream.CopyTo(remoteStream); } catch { }
            try { client.Close(); } catch { }
            try { remote.Close(); } catch { }
        });
        th.IsBackground = true;
        th.Start();
        try { remoteStream.CopyTo(clientStream); } catch { }
        try { client.Close(); } catch { }
        try { remote.Close(); } catch { }
    }

    private static void Handle(TcpClient client)
    {
        TcpClient upstream = null;
        try
        {
            NetworkStream cs = client.GetStream();
            byte[] head = ReadHead(cs);
            if (head == null) { client.Close(); return; }

            string text = Encoding.ASCII.GetString(head);
            int idx = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            string headers = idx >= 0 ? text.Substring(0, idx) : text;
            int bodyStart = idx >= 0 ? idx + 4 : text.Length;
            byte[] rest = new byte[head.Length - bodyStart];
            if (rest.Length > 0) Buffer.BlockCopy(head, bodyStart, rest, 0, rest.Length);

            string[] lines = headers.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length == 0 || lines[0].Length == 0) { client.Close(); return; }
            string[] req = lines[0].Split(new char[] { ' ' }, 3);
            if (req.Length < 2) { client.Close(); return; }
            string method = req[0];
            string target = req[1];

            if (method.Equals("CONNECT", StringComparison.OrdinalIgnoreCase))
            {
                string host;
                int port;
                ParseHostPort(target, out host, out port);
                bool viaUpstream = IsUpstreamHost(host);
                Log("CONNECT " + host + ":" + port + (viaUpstream ? " via upstream" : " direct"));

                if (viaUpstream)
                {
                    upstream = OpenUpstream(host, port);
                }
                else
                {
                    try
                    {
                        upstream = new TcpClient();
                        upstream.Connect(host, port);
                    }
                    catch (Exception e)
                    {
                        Log("direct error: " + e.Message);
                        upstream = null;
                    }
                }

                if (upstream == null)
                {
                    WriteAscii(cs, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
                    client.Close();
                    return;
                }

                WriteAscii(cs, "HTTP/1.1 200 Connection Established\r\n\r\n");
                if (rest.Length > 0) upstream.GetStream().Write(rest, 0, rest.Length);
                Tunnel(cs, upstream.GetStream(), client, upstream);
                return;
            }

            Uri uri;
            if (!Uri.TryCreate(target, UriKind.Absolute, out uri) || uri.Host.Length == 0)
            {
                WriteAscii(cs, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
                client.Close();
                return;
            }

            bool viaUp = IsUpstreamHost(uri.Host);
            Log(method + " " + uri.Host + (viaUp ? " via upstream" : " direct"));

            StringBuilder sb = new StringBuilder();
            sb.Append(method).Append(' ').Append(viaUp ? uri.AbsoluteUri : uri.PathAndQuery).Append(" HTTP/1.1\r\n");
            for (int i = 1; i < lines.Length; i++)
            {
                string line = lines[i];
                if (line.Length == 0) continue;
                if (line.StartsWith("Proxy-", StringComparison.OrdinalIgnoreCase)) continue;
                sb.Append(line).Append("\r\n");
            }
            if (viaUp && _auth != null) sb.Append("Proxy-Authorization: ").Append(_auth).Append("\r\n");
            sb.Append("\r\n");
            byte[] payload = Encoding.ASCII.GetBytes(sb.ToString());
            int dstPort = uri.Port > 0 ? uri.Port : 80;

            if (viaUp)
            {
                upstream = OpenUpstream(uri.Host, dstPort);
            }
            else
            {
                try
                {
                    upstream = new TcpClient();
                    upstream.Connect(uri.Host, dstPort);
                }
                catch (Exception e)
                {
                    Log("direct error: " + e.Message);
                    upstream = null;
                }
            }

            if (upstream == null)
            {
                WriteAscii(cs, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
                client.Close();
                return;
            }

            NetworkStream us = upstream.GetStream();
            us.Write(payload, 0, payload.Length);
            if (rest.Length > 0) us.Write(rest, 0, rest.Length);
            Tunnel(cs, us, client, upstream);
        }
        catch (Exception e)
        {
            Log("ERR " + e.GetType().Name + ": " + e.Message);
            try { client.Close(); } catch { }
            try { if (upstream != null) upstream.Close(); } catch { }
        }
    }
}
'@

function Write-Info($text) { Write-Host ('  ' + $text) -ForegroundColor Gray }
function Write-Ok($text)   { Write-Host ('  ' + $text) -ForegroundColor Green }
function Write-Warn($text) { Write-Host ('  ' + $text) -ForegroundColor Yellow }
function Write-Err($text)  { Write-Host ('  ' + $text) -ForegroundColor Red }

if ($Relay) {
    if ($UpHost -and $UpPort -gt 0 -and $Port -gt 0) {
        if (-not $LogPath) { $LogPath = $Script:RelayLog }
        Add-Type -TypeDefinition $Script:CSharp -Language CSharp -ErrorAction Stop
        [ObsAuthRelay]::Run($Port, $UpHost, $UpPort, $UpUser, $UpPass, $LogPath)
    }
    return
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $p = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $p
}

function Test-LocalPort([int]$p, [int]$timeoutMs = 300) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Read-YesNo([string]$question) {
    while ($true) {
        $answer = (Read-Host ('  ' + $question + ' (y/n)')).Trim()
        if ($answer -match '^(y|yes|д|да)$') { return $true }
        if ($answer -match '^(n|no|н|нет|т)$') { return $false }
    }
}

function Invoke-Notify {
    if (-not ('WinInetNotify' -as [type])) {
        $sig = @'
using System;
using System.Runtime.InteropServices;
public static class WinInetNotify {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@
        Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue
    }
    try {
        [WinInetNotify]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        [WinInetNotify]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch { }
}

$Script:Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Save-ProxyState([int]$relayPid, [int]$relayPort) {
    $cur = Get-ItemProperty -Path $Script:Key -ErrorAction SilentlyContinue
    $state = [ordered]@{
        ProxyEnable   = if ($null -ne $cur.ProxyEnable) { [int]$cur.ProxyEnable } else { 0 }
        ProxyServer   = [string]$cur.ProxyServer
        ProxyOverride = [string]$cur.ProxyOverride
        AutoConfigURL = [string]$cur.AutoConfigURL
        RelayPid      = $relayPid
        RelayPort     = $relayPort
    }
    ($state | ConvertTo-Json) | Set-Content -LiteralPath $Script:StateFile -Encoding UTF8
}

function Restore-ProxyState([switch]$Quiet) {
    if (Test-Path -LiteralPath $Script:StateFile) {
        try {
            $st = Get-Content -LiteralPath $Script:StateFile -Raw | ConvertFrom-Json
        } catch { $st = $null }
        if ($st) {
            Set-ItemProperty -Path $Script:Key -Name ProxyEnable -Value ([int]$st.ProxyEnable) -Type DWord
            if ($st.ProxyServer) { Set-ItemProperty -Path $Script:Key -Name ProxyServer -Value ([string]$st.ProxyServer) -Type String }
            else { Remove-ItemProperty -Path $Script:Key -Name ProxyServer -ErrorAction SilentlyContinue }
            if ($st.ProxyOverride) { Set-ItemProperty -Path $Script:Key -Name ProxyOverride -Value ([string]$st.ProxyOverride) -Type String }
            else { Remove-ItemProperty -Path $Script:Key -Name ProxyOverride -ErrorAction SilentlyContinue }
            if ($st.AutoConfigURL) { Set-ItemProperty -Path $Script:Key -Name AutoConfigURL -Value ([string]$st.AutoConfigURL) -Type String }
            else { Remove-ItemProperty -Path $Script:Key -Name AutoConfigURL -ErrorAction SilentlyContinue }
            if ($st.RelayPid) { Stop-Process -Id ([int]$st.RelayPid) -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $Script:StateFile -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $Script:RelayPidFile) {
        $rp = Get-Content -LiteralPath $Script:RelayPidFile -ErrorAction SilentlyContinue
        if ($rp) { Stop-Process -Id ([int]$rp) -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $Script:RelayPidFile -Force -ErrorAction SilentlyContinue
    }
    Invoke-Notify
    if (-not $Quiet) { Write-Ok 'Настройки прокси Windows возвращены как были.' }
}

function Set-SystemProxyToRelay([int]$relayPort) {
    Set-ItemProperty -Path $Script:Key -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $Script:Key -Name ProxyServer -Value ('127.0.0.1:' + $relayPort) -Type String
    Set-ItemProperty -Path $Script:Key -Name ProxyOverride -Value '<local>;127.0.0.1;localhost' -Type String
    Remove-ItemProperty -Path $Script:Key -Name AutoConfigURL -ErrorAction SilentlyContinue
    Invoke-Notify
}

function Test-ProxyRoute([string]$proxyUrl, [int]$maxTime = 12) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & curl.exe -s -o NUL -w '%{http_code}' --connect-timeout 6 --max-time $maxTime --proxy $proxyUrl ('https://' + $Script:Host0 + '/') 2>$null
    $sw.Stop()
    $code = ($out | Out-String).Trim()
    return [pscustomobject]@{ Ok = ($code -and $code -ne '000'); Code = $code; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
}

function Get-ObsExe {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\obs-studio\bin\64bit\obs64.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    try {
        $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\OBS Studio' -ErrorAction Stop).'(default)'
        if ($inst) {
            $p = Join-Path $inst 'bin\64bit\obs64.exe'
            if (Test-Path -LiteralPath $p) { return $p }
        }
    } catch { }
    $u = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio' -ErrorAction SilentlyContinue
    if ($u -and $u.DisplayIcon) {
        $p = ($u.DisplayIcon -replace '"', '').Trim()
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Read-ProxyList {
    param([string]$Path, [string[]]$Lines)
    $items = @()
    if ($Lines) { $source = $Lines } else { $source = Get-Content -LiteralPath $Path -ErrorAction Stop }
    foreach ($line in $source) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^(\d{1,3}(?:\.\d{1,3}){3}):(\d+):([^:]+):(.+)$') {
            $items += [pscustomobject]@{
                Raw = $t; Host = $Matches[1]; Port = [int]$Matches[2]
                User = $Matches[3]; Pass = $Matches[4]; Auth = $true
            }
            continue
        }
        if ($t -match '^(?:https?://)?(\d{1,3}(?:\.\d{1,3}){3}):(\d+)$') {
            $items += [pscustomobject]@{
                Raw = $t; Host = $Matches[1]; Port = [int]$Matches[2]
                User = ''; Pass = ''; Auth = $false
            }
        }
    }
    return $items
}

function Get-PublicProxies([int]$Limit = 30, [int]$TimeoutMs = 5000) {
    $url = 'https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&proxy_format=protocolipport&format=text&protocol=http&timeout=' + $TimeoutMs
    try {
        $raw = & curl.exe -fsSL --connect-timeout 8 --max-time 20 $url 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
        $lines = @($raw -split "`n" | Where-Object { $_.Trim() })
        $parsed = Read-ProxyList -Lines $lines
        return @($parsed | Select-Object -First $Limit)
    } catch {
        return @()
    }
}

if ($Restore) {
    Restore-ProxyState
    return
}

Write-Host ''
Write-Host '  FIX OBS AUTH' -ForegroundColor Cyan
Write-Host '  Вход в Twitch через OBS, когда auth.obsproject.com заблокирован' -ForegroundColor Gray
Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

if (Test-Path -LiteralPath $Script:StateFile) {
    $prev = $null
    try { $prev = Get-Content -LiteralPath $Script:StateFile -Raw | ConvertFrom-Json } catch { }
    $prevAlive = $false
    if ($prev -and $prev.RelayPid) { $prevAlive = [bool](Get-Process -Id ([int]$prev.RelayPid) -ErrorAction SilentlyContinue) }
    if ($prevAlive) {
        Write-Warn 'Скрипт уже запущен в другом окне.'
        Write-Info 'Если это не так, выполни: obs-auth.bat -Restore'
        return
    }
    Restore-ProxyState -Quiet
}

$obsExe = Get-ObsExe
if (-not $obsExe) {
    Write-Err 'OBS Studio не найден. Установи его и запусти файл снова.'
    exit 1
}

if (-not $Test -and -not $NoLaunch) {
    $obsRunning = @(Get-Process -Name obs64 -ErrorAction SilentlyContinue)
    if ($obsRunning.Count -gt 0) {
        Write-Warn 'OBS сейчас запущен. Чтобы он начал работать через прокси, его нужно перезапустить.'
        if (-not (Read-YesNo 'Выключить OBS?')) {
            Write-Host ''
            Write-Warn 'OBS остался открытым. Закрой его сам и запусти файл снова.'
            return
        }
        Write-Info 'Закрываю OBS...'
        foreach ($proc in $obsRunning) { $null = $proc.CloseMainWindow() }
        $null = $obsRunning | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
        if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) {
            Stop-Process -Name obs64 -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        Write-Ok 'OBS закрыт.'
        Write-Host ''
    }
}

if (-not $ListPath) {
    $ListPath = Join-Path $PSScriptRoot 'proxies.txt'
}

Write-Info 'Собираю список прокси...'
$proxies = @()
$ownCount = 0
if (Test-Path -LiteralPath $ListPath) {
    $proxies = @(Read-ProxyList -Path $ListPath)
    $ownCount = $proxies.Count
} else {
    Write-Info 'Файл proxies.txt не найден, использую только публичные прокси.'
}

$public = @(Get-PublicProxies -Limit $Script:PublicLimit -TimeoutMs $Script:PublicTimeout)
$publicCount = 0
if ($public.Count -gt 0) {
    $seen = @{}
    foreach ($p in $proxies) { $seen[$p.Host + ':' + $p.Port] = $true }
    foreach ($p in $public) {
        if (-not $seen.ContainsKey($p.Host + ':' + $p.Port)) {
            $seen[$p.Host + ':' + $p.Port] = $true
            $proxies += $p
            $publicCount++
        }
    }
} else {
    Write-Warn 'Публичные прокси скачать не удалось, проверяю только свои.'
}

if ($proxies.Count -eq 0) {
    Write-Err 'Нет ни одного прокси для проверки.'
    Write-Info 'Положи proxies.txt рядом с этим файлом или проверь интернет.'
    exit 1
}
Write-Ok ('Прокси в списке: ' + $proxies.Count + ' (своих: ' + $ownCount + ', публичных: ' + $publicCount + ')')
Write-Host ''

Write-Info 'Ищу рабочий прокси...'
$relayProc = $null
$relayPort = 0
$seconds = 0
$n = 0
foreach ($p in $proxies) {
    $n++
    Write-Host ("`r  Проверяю: " + $n + ' из ' + $proxies.Count + '   ') -NoNewline -ForegroundColor Gray
    if ($p.Auth) {
        $url = 'http://' + $p.User + ':' + $p.Pass + '@' + $p.Host + ':' + $p.Port
    } else {
        $url = 'http://' + $p.Host + ':' + $p.Port
    }
    $r = Test-ProxyRoute $url
    if (-not $r.Ok) { continue }

    $tryPort = Get-FreePort
    $relayArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-Relay',
        '-Port', $tryPort,
        '-UpHost', $p.Host,
        '-UpPort', $p.Port,
        '-LogPath', ('"' + $Script:RelayLog + '"')
    )
    if ($p.Auth) {
        $relayArgs += @('-UpUser', $p.User, '-UpPass', $p.Pass)
    }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relayArgs -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $Script:RelayPidFile -Value $proc.Id -Encoding ASCII

    $ready = $false
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-LocalPort $tryPort 300) { $ready = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    $good = $false
    if ($ready) {
        $self = Test-ProxyRoute ('http://127.0.0.1:' + $tryPort) 20
        $good = $self.Ok
    }
    if ($good) {
        $relayProc = $proc
        $relayPort = $tryPort
        $seconds = $r.Seconds
        break
    }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:RelayPidFile -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if (-not $relayProc) {
    Write-Err ('Ни один прокси не открывает ' + $Script:Host0 + '.')
    Write-Info 'Попробуй позже или обнови список в proxies.txt.'
    Write-Info ('Подробности в логе: ' + $Script:RelayLog)
    exit 1
}
Write-Ok ('Рабочий прокси найден, отклик ' + $seconds + ' с.')
Write-Ok 'Локальный мост запущен.'

Save-ProxyState -relayPid $relayProc.Id -relayPort $relayPort
Set-SystemProxyToRelay -relayPort $relayPort
Write-Info 'Системный прокси Windows временно переключён. Через прокси идёт только obsproject.com.'

if ($Test) {
    $check = $null
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'obs-auth-check')
        $null = $wc.DownloadString('https://' + $Script:Host0 + '/')
        $check = 'ok'
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $check = 'ok' } else { $check = $_.Exception.Message }
    } catch { $check = $_.Exception.Message }
    Write-Host ''
    if ($check -eq 'ok') { Write-Ok ('Проверка пройдена: ' + $Script:Host0 + ' открывается.') }
    else { Write-Warn ('Проверка не пройдена: ' + $check) }
    Restore-ProxyState
    return
}

$env:HTTP_PROXY = 'http://127.0.0.1:' + $relayPort
$env:HTTPS_PROXY = $env:HTTP_PROXY
$env:ALL_PROXY = $env:HTTP_PROXY
$env:NO_PROXY = 'localhost,127.0.0.1,::1'

if (-not $NoLaunch) {
    Write-Info 'Запускаю OBS...'
    Start-Process -FilePath $obsExe -WorkingDirectory (Split-Path -Parent $obsExe) | Out-Null
    Start-Sleep -Seconds 2
}

Write-Host ''
Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
if ($NoLaunch) { Write-Ok 'Прокси включён. Запусти OBS вручную.' }
else { Write-Ok 'OBS запущен и готов.' }
Write-Host ''
Write-Host '  Что делать дальше:' -ForegroundColor White
Write-Host '    1. В OBS: Настройки -> Трансляция -> Twitch -> "Привязать аккаунт".' -ForegroundColor White
Write-Host '    2. В окне откроется страница входа. Войди в Twitch как обычно.' -ForegroundColor White
Write-Host '    3. Когда аккаунт подключится, вернись сюда и нажми Enter.' -ForegroundColor White
Write-Host ''
Write-Host '  Twitch открывается напрямую с твоего IP.' -ForegroundColor Gray
Write-Host ''
$null = Read-Host '  Аккаунт подключён? Нажми Enter'

Write-Host ''
Restore-ProxyState
Write-Ok 'Готово. Это окно можно закрыть, OBS закрывать не нужно.'
