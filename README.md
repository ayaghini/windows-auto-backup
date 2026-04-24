# 🗄️ Windows → UniFi NAS Automated Backup (Robocopy + Task Scheduler)

This repository provides a **reliable, automated backup solution** for Windows machines backing up to a UniFi NAS (or any SMB share).

It uses:
- PowerShell scripts
- Robocopy (built-in, highly reliable)
- Windows Task Scheduler (for automation)

---

# 📦 Contents

| File | Description |
|------|------------|
| `Backup-RoboCopy.ps1` | Main backup engine (runs one or more backup jobs) |
| `Setup-BackupScheduledTask.ps1` | Creates and manages the scheduled task |
| `backup-config.json` | Defines what folders to back up |

---

# 🚀 Quick Start

## 1. Create Folder Structure

Recommended:

```
C:\Scripts\
    Backup-RoboCopy.ps1
    Setup-BackupScheduledTask.ps1
    backup-config.json

C:\BackupLogs\
```

---

## 2. Configure Backup Jobs

Edit `backup-config.json`:

```json
{
  "Jobs": [
    {
      "Name": "DocumentsBackup",
      "Source": "C:\\Users\\Ali\\Documents",
      "Destination": "\\\\192.168.3.106\\Backups\\WindowsPC\\Documents",
      "Mirror": false
    }
  ]
}
```

### Important:
- Always use **UNC paths**, not mapped drives:
  ```
  \\192.168.x.x\ShareName\Folder
  ```
- Avoid:
  ```
  Z:\Folder
  ```

---

## 3. Test Backup (VERY IMPORTANT)

Run manually first:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Scripts\Backup-RoboCopy.ps1" -ConfigPath "C:\Scripts\backup-config.json"
```

### Dry Run (no copying):
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Scripts\Backup-RoboCopy.ps1" -ConfigPath "C:\Scripts\backup-config.json" -WhatIfOnly
```

---

## 4. Create Scheduled Task

### Option A — Run as SYSTEM (simplest)

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Scripts\Setup-BackupScheduledTask.ps1" `
  -TaskName "UniFi NAS Backup" `
  -BackupScriptPath "C:\Scripts\Backup-RoboCopy.ps1" `
  -ConfigPath "C:\Scripts\backup-config.json" `
  -ScheduleType Daily `
  -DailyAt "23:00" `
  -LogRoot "C:\BackupLogs" `
  -RunAsSystem
```

---

### Option B — Run as specific user (recommended for SMB auth)

```powershell
$pw = Read-Host "Enter password" -AsSecureString

powershell -ExecutionPolicy Bypass -File "C:\Scripts\Setup-BackupScheduledTask.ps1" `
  -TaskName "UniFi NAS Backup" `
  -BackupScriptPath "C:\Scripts\Backup-RoboCopy.ps1" `
  -ConfigPath "C:\Scripts\backup-config.json" `
  -ScheduleType Daily `
  -DailyAt "23:00" `
  -LogRoot "C:\BackupLogs" `
  -RunAsUser "YOURPC\BackupUser" `
  -RunAsPassword $pw
```

---

## 5. Test Scheduled Task

```powershell
Start-ScheduledTask -TaskName "UniFi NAS Backup"
```

---

# ⚙️ Configuration Details

## Backup Job Fields

| Field | Description |
|------|------------|
| `Name` | Unique job name |
| `Source` | Local folder |
| `Destination` | NAS path (UNC) |
| `Mirror` | `true` = exact mirror (⚠️ deletes extra files) |
| `CopySubfolders` | Include subfolders |
| `RetryCount` | Retry attempts |
| `RetryWaitSeconds` | Wait between retries |
| `Threads` | Parallel copy threads |
| `ExcludeDirs` | Directories to skip |
| `ExcludeFiles` | File patterns to skip |

---

# ⚠️ Important Behavior (Read This)

## 🔁 Mirror Mode (`"Mirror": true`)
- Uses `/MIR`
- Deletes files from backup if deleted locally

👉 Only use if you want exact sync

---

## 🛡️ Safe Mode (`"Mirror": false`) — Recommended
- Uses `/E`
- Never deletes files from backup
- Safer for:
  - accidental deletion
  - ransomware scenarios

---

# 📊 Logging

Logs are stored here:

```
C:\BackupLogs\<JobName>\robocopy-YYYYMMDD-HHMMSS.log
```

---

# 🧠 Best Practices (Built Into Scripts)

## ✅ UNC Paths Instead of Mapped Drives
Mapped drives often fail in scheduled tasks.

---

## ✅ NAS Compatibility
Uses:
- `/FFT` → fixes timestamp mismatch issues
- `/Z` → restartable network copies

---

## ✅ Loop Prevention
Uses:
- `/XJ` → avoids infinite loops via junction points

---

## ✅ Controlled Retries
Default:
- 3 retries
- 10 seconds wait

---

## ✅ Multi-threading
Uses:
```
/MT:8
```

---

# 🔐 Credentials (Common Issue)

If backups work manually but fail in scheduler:

👉 It’s usually a **permissions issue**

Fix by:
- running task as a user with NAS access
- ensuring NAS allows that user
- avoiding SYSTEM if NAS requires authentication

---

# 🛠️ Troubleshooting

## ❌ Backup fails immediately
- Check source path exists
- Check NAS path reachable

---

## ❌ Works manually but not scheduled
- Use UNC path
- Use `RunAsUser`
- Check Task Scheduler history

---

## ❌ Slow backup speed
Possible causes:
- network bottleneck
- SMB settings
- antivirus scanning
- large number of small files

---

## ❌ Access denied
- Check NAS permissions
- Check Windows credential context

---

# 🚀 Recommended Setup Strategy

For reliability:

### Option A (Simple)
- Daily backup at night

### Option B (Better)
- Daily full backup
- Midday incremental run

---

# 🧪 Final Checklist

Before relying on this:

- [ ] Backup runs successfully manually
- [ ] Scheduled task runs successfully
- [ ] Logs are being created
- [ ] Test restore works
- [ ] NAS permissions confirmed

---

# ⚡ Summary

✔ Reliable backups  
✔ Automation  
✔ Multiple folder support  
✔ Logging + visibility  
✔ Production-grade robustness  
