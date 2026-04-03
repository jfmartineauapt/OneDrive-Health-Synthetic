# OneDrive Health Monitor (Deploy Guide)

Use this deployment set:

- `OneDrive-Health-Synthetic-Deploy.ps1` (main script)
- `Run-OneDriveHealth-CheckOnly.ps1`
- `Run-OneDriveHealth-Remediation.ps1`
- `Run-OneDriveHealth-TS.ps1`

The launcher scripts are already configured to call `OneDrive-Health-Synthetic-Deploy.ps1`.

## Return codes

- `0` = OK
- `1` = OneDrive not running
- `2` = Sync/sign-in failure
- `3` = No interactive user logged in

## What this version checks

1. Interactive user session is present.
2. OneDrive process is running in the same user session.
3. OneDrive business sign-in context is present.
4. Synthetic transaction:
   - write/update `$env:OneDrive\_monitor\health.txt`
   - wait random delay
   - confirm OneDrive business logs changed after the write (log churn evidence)

If log churn is not observable on a healthy endpoint, the script uses a production fallback
to core health signals (process running, signed-in context, successful synthetic write).
Use strict mode if you want to require log churn.

This version is designed to be deployable and stable in production, including TS/FSLogix environments.

## Status output for Zabbix

Default status files:

- `C:\AT\logs\status.txt`
- `C:\AT\logs\status\<DOMAIN>_<USER>.txt`

Folders are created if missing (`C:\AT\logs` and `C:\AT\logs\status`).  
No ACL modifications are attempted.

## Common runs

Check-only:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\AT\OneDriveHealth\Run-OneDriveHealth-CheckOnly.ps1"
```

Conservative remediation:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\AT\OneDriveHealth\Run-OneDriveHealth-Remediation.ps1"
```

Aggressive remediation (restart running client if needed):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\AT\OneDriveHealth\Run-OneDriveHealth-Remediation.ps1" -RestartRunningClient
```

Strict log-churn mode (no fallback):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\AT\OneDriveHealth\OneDrive-Health-Synthetic-Deploy.ps1" -RequireLogChurnEvidence
```

TS/FSLogix recommended:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\AT\OneDriveHealth\Run-OneDriveHealth-TS.ps1"
```

TS + UI prompt when stopped:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\AT\OneDriveHealth\Run-OneDriveHealth-TS.ps1" -LaunchUiIfStopped
```

## Scheduling recommendations

- Run as user scheduled task (interactive token).
- Interval: every 30 minutes.
- Random delay: 2 to 10 minutes.
- Trigger alerts on `<> 0` with 2-3 consecutive failures.
