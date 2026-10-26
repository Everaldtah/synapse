<#
.SYNOPSIS
  Creates (or refreshes) "synapse-sandbox", the WSL distro Synapse Bridge runs shell commands, file conversions and
  (optionally) a Claude Code harness in.

.DESCRIPTION
  - Downloads the official Ubuntu Base 24.04 amd64 rootfs from cdimage.ubuntu.com and checks its SHA256 against
    the published SHA256SUMS before importing it as its own WSL 2 distro under
    %USERPROFILE%\.synapse-bridge\wsl\synapse-sandbox. Your other distros are not touched.
  - Cuts it off from Windows: /etc/wsl.conf turns off drive mounts (no /mnt/c) and Windows interop (it cannot
    start .exe files), and a boot script detaches the WSLg display/audio/clipboard sockets so a sandboxed
    process can't reach the host GUI. (DNS, which WSL serves through /mnt/wsl/resolv.conf, is left in place.)
  - Users: "agent" (uid 1000) runs every command the bridge sends; the workspace is /home/agent/work and uploads
    land in /home/agent/work/files. Root could still mount C:\ by hand inside WSL 2, so nothing runs as root;
    there is no sudo for agent and root's password is locked.
  - With -WithHarness: user "claude" (home 700) gets Claude Code from the official native installer and its own
    login. Its shell commands run as "agent" (sudo rule claude -> agent only), and root-owned managed settings
    deny Claude's file tools any access to /home/claude, so commands and prompt-injected text can't read the login.
  - Installs tools for reading and converting files (pandoc, poppler, tesseract, LibreOffice, ffmpeg, Python with
    pandas/openpyxl/python-docx, ...).

  Re-running is safe: the import is skipped when the distro exists; config, users, packages and Claude Code (with
  -WithHarness: updated to the latest release) are re-applied.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File bridge\sandbox\setup-wsl-sandbox.ps1 -WithHarness
#>
[CmdletBinding()]
param(
  [string]$Name = 'synapse-sandbox',
  [string]$InstallDir = (Join-Path $env:USERPROFILE '.synapse-bridge\wsl\synapse-sandbox'),
  [switch]$WithHarness,
  [switch]$SkipPackages
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest many times slower on 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$env:WSL_UTF8 = '1'                        # wsl.exe prints UTF-16 unless asked for UTF-8
$env:WSLENV = ''                           # pass no Windows environment variables into the distro

$ReleaseUrl = 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/'
$Packages = @(
  'ca-certificates', 'curl', 'wget', 'git', 'jq', 'file', 'binutils', 'unzip', 'zip', 'xz-utils',
  'python3', 'python3-pip', 'python3-venv', 'python3-openpyxl', 'python3-docx', 'python3-pandas',
  'pandoc', 'poppler-utils', 'tesseract-ocr', 'tesseract-ocr-eng', 'ffmpeg',
  'libreoffice-writer-nogui', 'libreoffice-calc-nogui', 'libreoffice-impress-nogui',
  # plumbing for the users and the harness
  'sudo', 'acl', 'procps'
)

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Get-Distros {
  $ErrorActionPreference = 'Continue'   # on 5.1 a redirected native stderr line would otherwise throw
  $out = & wsl.exe -l -q 2>$null
  # Older wsl.exe builds ignore WSL_UTF8 and print UTF-16, which arrives here with NULs between the letters.
  (($out -join "`n") -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Runs a bash script inside the distro. The script travels as base64 so no Windows quoting can touch it.
function Invoke-InDistro([string]$Script, [string]$User = 'root') {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Script -replace "`r`n", "`n"))
  $b64 = [Convert]::ToBase64String($bytes)
  $tmp = '/tmp/synapse-setup-' + [Guid]::NewGuid().ToString('N') + '.sh'
  # Out-Host keeps the script's output on screen instead of in this function's return value.
  & wsl.exe -d $Name -u $User --cd / -e bash -c "echo $b64 | base64 -d > $tmp && bash $tmp < /dev/null; rc=`$?; rm -f $tmp; exit `$rc" | Out-Host
  return $LASTEXITCODE
}

function Assert-Ok([int]$rc, [string]$what) { if ($rc -ne 0) { throw "$what failed (exit $rc)" } }

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw 'WSL is not installed. Run "wsl --install --no-distribution" as administrator, reboot, then run this again.'
}

# ── 1. import Ubuntu Base (once) ──────────────────────────────────────────────────────────────────────────────
if ((Get-Distros) -contains $Name) {
  Step "$Name already exists - skipping the download and import"
} else {
  Step 'Finding the current Ubuntu Base 24.04 release'
  $sums = (Invoke-WebRequest -UseBasicParsing -Uri ($ReleaseUrl + 'SHA256SUMS')).Content
  if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
  $best = $null
  foreach ($line in ($sums -split "`r?`n")) {
    if ($line -match '^([0-9a-f]{64}) \*?(ubuntu-base-24\.04(?:\.(\d+))?-base-amd64\.tar\.gz)$') {
      $point = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
      if (-not $best -or $point -gt $best.Point) { $best = @{ Hash = $Matches[1]; File = $Matches[2]; Point = $point } }
    }
  }
  if (-not $best) { throw "No amd64 tarball listed in $($ReleaseUrl)SHA256SUMS" }
  Write-Host "    $($best.File)  sha256 $($best.Hash)"

  $cacheDir = Join-Path $env:USERPROFILE '.synapse-bridge\wsl\download'
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $tar = Join-Path $cacheDir $best.File
  if (-not (Test-Path $tar) -or (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLower() -ne $best.Hash) {
    Step "Downloading $($best.File)"
    Invoke-WebRequest -UseBasicParsing -Uri ($ReleaseUrl + $best.File) -OutFile $tar
  }
  $got = (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLower()
  if ($got -ne $best.Hash) {
    Remove-Item -Force $tar
    throw "SHA256 mismatch for $($best.File): expected $($best.Hash), got $got. The download was deleted."
  }
  Write-Host '    SHA256 verified'

  Step "Importing as WSL 2 distro '$Name' into $InstallDir"
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  & wsl.exe --import $Name $InstallDir $tar --version 2
  if ($LASTEXITCODE -ne 0) { throw "wsl --import failed ($LASTEXITCODE)" }
  Remove-Item -Force $tar
}

# ── 2. cut it off from Windows ────────────────────────────────────────────────────────────────────────────────
Step 'Writing /etc/wsl.conf and the boot script (no drives, no interop, no WSLg, no GPU)'
Assert-Ok (Invoke-InDistro @'
set -e
cat > /etc/wsl.conf <<'EOF'
# Written by Synapse Bridge's setup-wsl-sandbox.ps1. This distro must not see or start anything on Windows.
[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=root

[network]
hostname=synapse-sandbox

[boot]
systemd=false
command=/usr/local/sbin/synapse-boot.sh
EOF

cat > /usr/local/sbin/synapse-boot.sh <<'EOF'
#!/bin/sh
# Runs as root each time the distro starts (wsl.conf [boot] command), after WSL has set up its mounts.
# automount=false already keeps /mnt/c empty and interop=false stops Windows .exe files from running. On top of
# that, detach WSLg's display/audio/clipboard sockets so a sandboxed process can't reach the host GUI. Do it in
# this distro's own mount namespace only (private first, so nothing propagates to the user's other distros).
# /mnt/wsl is left mounted: it carries the generated resolv.conf, so removing it would break DNS.
mount --make-rprivate / 2>/dev/null
for m in /tmp/.X11-unix /mnt/wslg/doc /mnt/wslg/versions.txt /mnt/wslg/distro /mnt/wslg; do
  umount -l "$m" 2>/dev/null
done
touch /run/synapse-boot-done            # the bridge waits for this before running commands
EOF
chmod 755 /usr/local/sbin/synapse-boot.sh
echo "    wsl.conf + /usr/local/sbin/synapse-boot.sh written"
'@) 'Writing wsl.conf'
& wsl.exe --terminate $Name | Out-Null   # wsl.conf is read when the distro starts

# ── 3. packages ───────────────────────────────────────────────────────────────────────────────────────────────
if (-not $SkipPackages) {
  Step 'Installing packages (a few hundred MB the first time)'
  Assert-Ok (Invoke-InDistro (@'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
have=""; missing=""
for p in __LIST__; do
  if apt-cache show "$p" >/dev/null 2>&1; then have="$have $p"; else missing="$missing $p"; fi
done
[ -n "$missing" ] && echo "    NOT AVAILABLE on $(. /etc/os-release; echo $VERSION_CODENAME), skipped:$missing"
apt-get install -y -q --no-install-recommends $have
apt-get clean
rm -rf /var/lib/apt/lists/*
'@ -replace '__LIST__', ($Packages -join ' '))) 'Installing packages'
}

# ── 4. users and the shared workspace ─────────────────────────────────────────────────────────────────────────
Step 'Users: agent (runs commands), claude (runs Claude Code), group work, /home/agent/work'
Assert-Ok (Invoke-InDistro @'
set -e
# An earlier version of this script used a user "sandbox" and /root/work.
if id sandbox >/dev/null 2>&1; then userdel sandbox 2>/dev/null || true; groupdel sandbox 2>/dev/null || true; fi
rm -rf /root/work; chmod 700 /root

getent group work >/dev/null || groupadd work
id agent  >/dev/null 2>&1 || useradd --uid 1000 --create-home --user-group --shell /bin/bash agent
id claude >/dev/null 2>&1 || useradd --create-home --user-group --shell /bin/bash claude
usermod -aG work agent; usermod -aG work claude
passwd -l root >/dev/null 2>&1 || true
passwd -l agent >/dev/null 2>&1 || true
passwd -l claude >/dev/null 2>&1 || true

# claude may only pass through /home/agent to the workspace; nobody but claude may enter /home/claude.
chown agent:work /home/agent && chmod 710 /home/agent
chmod 700 /home/claude
mkdir -p /home/agent/work/files
chown -R agent:work /home/agent/work
chmod 2775 /home/agent/work /home/agent/work/files
# Whatever either user creates in the workspace stays in group work and group-writable, whatever the umask.
setfacl -R -m g:work:rwX -m d:g:work:rwX -m d:u::rwX -m d:o::rX /home/agent/work

cat > /etc/profile.d/synapse.sh <<'EOF'
export LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8
umask 002
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
EOF

# claude may run commands as agent (that is how Claude Code's Bash tool runs), and nothing else. agent: no sudo.
cat > /etc/sudoers.d/synapse <<'EOF'
# Synapse Bridge: Claude Code (user claude) runs its shell commands as the unprivileged user agent.
Defaults:claude !use_pty, !lecture, umask=0002, env_reset
claude ALL=(agent) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/synapse
visudo -cf /etc/sudoers.d/synapse >/dev/null

cat > /home/agent/work/CLAUDE.md <<'EOF'
# Synapse sandbox workspace

You are working inside an isolated Linux sandbox (Ubuntu 24.04, WSL 2) on the user's PC, in /home/agent/work.

- Files the user attached from the Synapse app are in `files/` (/home/agent/work/files). Put anything you create
  for the user in this folder or below it.
- Shell commands run as the unprivileged user `agent`, with no sudo. Windows and its drives are not reachable.
- Installed tools: python3 (pandas, openpyxl, python-docx), pandoc, pdftotext/pdftoppm (poppler), tesseract
  (OCR, English), LibreOffice (headless: `soffice --headless --convert-to ...`), ffmpeg, jq, git, curl, wget,
  zip/unzip, file. `pip install --user --break-system-packages <pkg>` or a venv for anything else.
- Use the WebSearch and WebFetch tools for anything online.
EOF
chown agent:work /home/agent/work/CLAUDE.md; chmod 664 /home/agent/work/CLAUDE.md
echo "    $(id agent)"
echo "    $(id claude)"
'@) 'Creating users'

# ── 5. Claude Code harness ────────────────────────────────────────────────────────────────────────────────────
if ($WithHarness) {
  Step 'Claude Code harness: managed settings, shell prefix'
  Assert-Ok (Invoke-InDistro @'
set -e
# Claude Code wraps every shell command it starts in this prefix ($1 = the whole command line it assembled).
cat > /usr/local/bin/synapse-as-agent <<'EOF'
#!/bin/sh
# CLAUDE_CODE_SHELL_PREFIX for user claude: run the command as the unprivileged user agent, with a clean
# environment (sudo env_reset), so commands can't read claude's home (700) or anything in its environment.
exec sudo -n -H -u agent -- /bin/bash -c "$1"
EOF
chmod 755 /usr/local/bin/synapse-as-agent

# Root-owned policy that Claude can't edit and no user/project/CLI setting can override.
mkdir -p /etc/claude-code
cat > /etc/claude-code/managed-settings.json <<'EOF'
{
  "env": {
    "CLAUDE_CODE_SHELL_PREFIX": "/usr/local/bin/synapse-as-agent",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_AUTOUPDATER": "1"
  },
  "permissions": {
    "deny": [
      "Read(//home/claude/**)", "Edit(//home/claude/**)",
      "Read(~/**)", "Edit(~/**)",
      "Read(//proc/**)", "Read(//sys/**)", "Read(//root/**)",
      "Read(//etc/sudoers*)", "Read(//etc/shadow*)",
      "Edit(//etc/**)", "Edit(//usr/**)",
      "Edit(//home/agent/work/.claude/**)", "Edit(//home/agent/work/.mcp.json)"
    ],
    "disableAutoMode": "disable"
  },
  "allowManagedPermissionRulesOnly": false,
  "allowManagedHooksOnly": true,
  "disableAllHooks": true,
  "allowManagedMcpServersOnly": true
}
EOF
chmod 755 /etc/claude-code; chmod 644 /etc/claude-code/managed-settings.json
# "claude" on PATH for the login command (works only for user claude, whose home this points into).
printf '#!/bin/sh\nexec /home/claude/.local/bin/claude "$@"\n' > /usr/local/bin/claude
chmod 755 /usr/local/bin/claude
echo "    /etc/claude-code/managed-settings.json, /usr/local/bin/synapse-as-agent"
'@) 'Writing managed settings'

  Step 'Installing Claude Code for user claude (official native installer)'
  Assert-Ok (Invoke-InDistro @'
set -e
cd ~
curl -fsSL https://claude.ai/install.sh | bash
rm -f ~/.claude/.credentials.json.example 2>/dev/null || true
echo "    claude $(~/.local/bin/claude --version)"
'@ 'claude') 'Installing Claude Code'
}

# ── 6. prove the isolation ────────────────────────────────────────────────────────────────────────────────────
Step 'Checking the configuration (as agent, the user the bridge runs commands as)'
Invoke-InDistro @'
say() { printf '    %-40s %s\n' "$1" "$2"; }
for i in $(seq 50); do [ -e /run/synapse-boot-done ] && break; sleep 0.1; done
[ -e /run/synapse-boot-done ] && say "boot script" "ran (ok)" || say "boot script" "DID NOT RUN"
if [ -n "$(ls -A /mnt/c 2>/dev/null)" ]; then say "/mnt/c" "HAS FILES (bad)"; else say "/mnt/c" "absent or empty (ok)"; fi
for d in /mnt/wslg /tmp/.X11-unix; do
  if grep -q " $d " /proc/mounts; then say "$d (host GUI)" "MOUNTED (bad)"; else say "$d (host GUI)" "not mounted (ok)"; fi
done
cmd.exe /c ver >/dev/null 2>&1 && say "cmd.exe /c ver" "RAN (bad)" || say "cmd.exe /c ver" "fails (ok)"
/mnt/c/Windows/System32/cmd.exe /c ver >/dev/null 2>&1 && say "/mnt/c/Windows/System32/cmd.exe" "RAN (bad)" || say "/mnt/c/Windows/System32/cmd.exe" "fails (ok)"
ls /home/claude >/dev/null 2>&1 && say "list /home/claude" "possible (bad)" || say "list /home/claude" "denied (ok)"
sudo -n true 2>/dev/null && say "sudo" "ALLOWED (bad)" || say "sudo" "none (ok)"
'@ 'agent' | Out-Null

Step 'Tools available to the bridge:'
Invoke-InDistro 'for t in bash python3 pandoc pdftotext pdftoppm tesseract soffice ffmpeg file unzip jq git curl; do command -v $t >/dev/null 2>&1 && printf "%s " $t; done; echo' 'agent' | Out-Null

if ($WithHarness) {
  Write-Host ''
  Step 'Last step - sign Claude Code in the sandbox in to your Claude account (once):'
  Write-Host ''
  Write-Host "    wsl -d $Name -u claude -- claude auth login" -ForegroundColor Yellow
  Write-Host ''
  Write-Host '    Open the link it prints in your browser and paste the code back. This is a separate login from'
  Write-Host '    the Claude Code on Windows; nothing is copied from it.'
}
