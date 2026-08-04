param(
    [string]$CsFile = (Join-Path $PSScriptRoot "..\src\WorkBuddyApp.cs"),
    [string]$EnginePs1 = (Join-Path $PSScriptRoot "..\src\WorkBuddy-AutoCheckin.ps1"),
    [string]$OutExe = (Join-Path $PSScriptRoot "..\dist\WorkBuddy-AutoCheckin-App.exe"),
    [string]$Icon = (Join-Path $PSScriptRoot "..\assets\workbuddy.ico")
)

$ErrorActionPreference = "Stop"
$CsFile = (Resolve-Path $CsFile).Path
$EnginePs1 = (Resolve-Path $EnginePs1).Path

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw "找不到 csc.exe" }

& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    "/out:$OutExe" `
    "/win32icon:$Icon" `
    "/resource:$EnginePs1,WorkBuddyEngine.ps1" `
    "/resource:$Icon,WorkBuddyIcon.ico" `
    /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll `
    $CsFile

if ($LASTEXITCODE -eq 0) {
    Write-Output "BUILD_OK $OutExe"
}
else {
    Write-Output "BUILD_FAILED code=$LASTEXITCODE"
}
