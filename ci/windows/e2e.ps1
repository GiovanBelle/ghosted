# End-to-end check of type-keys.ps1: type into another process's console and read back what it received.
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:RUNNER_TEMP 'typed.json'
Remove-Item $out -ErrorAction SilentlyContinue
$reader = Start-Process node -ArgumentList @("$PSScriptRoot\reader.js", $out) -PassThru
Start-Sleep -Seconds 3
$steps = '[[0.3,"\u0003"],[0.3,"/compact hi"],[0.5,"\r"],[0.5,"\r"]]'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($steps))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\..\hooks\type-keys.ps1" -Steps $b64 -Pids "$($reader.Id)"
if ($LASTEXITCODE -ne 0) { throw "type-keys.ps1 exited $LASTEXITCODE (could not attach to the console)" }
$reader.WaitForExit(20000) | Out-Null
$got = Get-Content $out -Raw | ConvertFrom-Json
Write-Host "received: $([Text.RegularExpressions.Regex]::Escape($got))"
if ($got -ne "$([char]3)/compact hi`r`r") { throw "unexpected input: $got" }
Write-Host "type-keys.ps1 ok"

# The whole path a task switch takes, started by the prompt hook as Claude Code runs it (/ghosted test-keys):
# once in a normal console, once in a pseudo console like the one Windows OpenSSH (sshd) gives a session.
foreach ($host_ in 'console', 'conpty') {
    $data = Join-Path $env:RUNNER_TEMP "ghosted-$host_"
    New-Item -ItemType Directory -Force $data | Out-Null
    $res = Join-Path $data 'result.json'
    $node = (Get-Command node).Source
    $child = "`"$node`" `"$PSScriptRoot\hook-child.js`" `"$res`" `"$data`""
    if ($host_ -eq 'console') {
        $p = Start-Process $node -ArgumentList @("$PSScriptRoot\hook-child.js", $res, $data) -PassThru
        $p.WaitForExit(60000) | Out-Null
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\conpty.ps1" -Command $child
    }
    Write-Host "[$host_] result: $(Get-Content $res -Raw -ErrorAction SilentlyContinue)"
    Write-Host "[$host_] events: $(Get-Content (Join-Path $data 'events.jsonl') -Raw -ErrorAction SilentlyContinue)"
    Write-Host "[$host_] type-keys: $(Get-Content (Join-Path $data 'type-keys.log') -Raw -ErrorAction SilentlyContinue)"
    Write-Host "[$host_] debug: $(Get-Content (Join-Path $data 'debug.log') -Raw -ErrorAction SilentlyContinue)"
    $r = Get-Content $res -Raw | ConvertFrom-Json
    if ($r.code -ne 0) { throw "[$host_] the hook's typing never arrived" }
    # type-keys.ps1 logs after the last key event: give it a moment, then expect a successful line
    $log = Join-Path $data 'events.jsonl'
    for ($i = 0; $i -lt 20 -and -not ((Test-Path $log) -and (Select-String -Path $log -Pattern '"kind":"type"' -Quiet)); $i++) { Start-Sleep -Milliseconds 500 }
    $line = Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '"kind":"type"' } | Select-Object -Last 1
    Write-Host "[$host_] logged: $line"
    if (-not ($line -match '"ok":true')) { throw "[$host_] type-keys.ps1 did not log a successful run" }
    Write-Host "[$host_] ok"
}
