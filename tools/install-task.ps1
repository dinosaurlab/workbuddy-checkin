<#
.SYNOPSIS
    把 WorkBuddy 自动签到脚本注册为 Windows 计划任务（每天定时运行）
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Time 09:05
#>
[CmdletBinding()]
param(
    # 每天运行时间，24 小时制 HH:mm
    [string]$Time = "09:05",
    # 计划任务名称
    [string]$TaskName = "WorkBuddy每日签到",
    # 签到脚本路径
    [string]$ScriptPath = (Join-Path $PSScriptRoot "..\src\WorkBuddy-AutoCheckin.ps1")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ScriptPath)) {
    throw "找不到签到脚本: $ScriptPath"
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -WakeToRun

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "WorkBuddy 每日自动签到（脚本: $ScriptPath）" -Force | Out-Null

Write-Host "已创建计划任务 [$TaskName]，每天 $Time 运行。"
Write-Host "查看/删除: schtasks /Query /TN `"$TaskName`"   /   schtasks /Delete /TN `"$TaskName`" /F"
