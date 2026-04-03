# OneDrive Synthetic Health Monitor (PowerShell)

This package contains:

- `OneDrive-Health-Synthetic.ps1`
- `Run-OneDriveHealth-CheckOnly.ps1`
- `Run-OneDriveHealth-Remediation.ps1`
- `Run-OneDriveHealth-TS.ps1`

It is designed for endpoint monitoring (for example Zabbix) and checks real OneDrive health using a synthetic transaction plus log evidence.

## What the script does (simple flow)

1. Adds a small random startup delay (1-5 seconds) to reduce endpoint spikes.
2. Verifies it is running in a real interactive user session.
   - If not, outputs `3`.
3. Checks if `OneDrive.exe` is running in the current user session.
   - If not, outputs `1`.
   - By default it launches OneDrive UI so user can sign in.
   - If `-NoUiLaunchWhenStopped` is used, it does not launch UI.
4. Checks if user is signed in to OneDrive Business (`HKCU:\Software\Microsoft\OneDrive\Accounts\Business1`).
   - If not signed in, outputs `2` (or tries one restart first if remediation switch is enabled).
5. Uses the user's OneDrive path from `$env:OneDrive`.
6. Creates/reuses `_monitor` folder under OneDrive.
7. Reuses one file only: `_monitor\health.txt`.
8. Writes current Eastern timestamp (EST/EDT) in ISO format to `health.txt`.
9. Waits a random 20-60 seconds.
10. Looks for recent OneDrive log evidence in:
   - `%LOCALAPPDATA%\Microsoft\OneDrive\logs\Business1\`
11. Searches recent logs for references to `health.txt`.
    - If found, outputs `0`.
    - If not found, outputs `2` (or tries one restart+retry first if remediation is enabled).

## Return codes

- `0` = OK (sync evidence found)
- `1` = OneDrive not running
- `2` = Not signed in to OneDrive Business, sync failure, or cannot complete synthetic check
- `3` = No user logged in / not interactive user context

Important for monitoring platforms:

- The script prints only the numeric code to stdout.
- The process exits with code `0` on purpose, so agents like Zabbix keep the item supported and use stdout value as the metric.

## Silent behavior

- Auto-remediation is **off by default**.
- By default, the script only checks and reports status (no restart attempt).
- If you run with `-EnableAutoRemediation`, restart is only attempted for an already running/signed-in instance that fails sync checks.
- If OneDrive is stopped, the script can start OneDrive with normal UI so user can sign in.
- `-NoUiLaunchWhenStopped` disables that UI launch behavior.
- Remediation restart is limited to one attempt per script run.
- Remediation restart is attempted only when a `Business1` sign-in profile already exists (prevents forcing setup/login UI for unsigned users).
- `-TsSafeMode` applies TS/FSLogix-friendly defaults (lighter log scan, wider startup jitter, and `NoUiLaunchWhenStopped` by default).

## Requirements

- Run in **user context** (not SYSTEM for the script logic itself).
- User must have OneDrive configured (`$env:OneDrive` present).
- User must be signed in to OneDrive for Business (`Business1` account profile).
- OneDrive business logs expected at `Business1` path above.

## Run examples

Read-only monitor (recommended):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\OneDriveHealth\OneDrive-Health-Synthetic.ps1"
```

Monitor + one-time remediation attempts:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\OneDriveHealth\OneDrive-Health-Synthetic.ps1" -EnableAutoRemediation
```

Quick launcher scripts (easy A/B testing):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\OneDriveHealth\Run-OneDriveHealth-CheckOnly.ps1"
```

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\OneDriveHealth\Run-OneDriveHealth-Remediation.ps1"
```

TS/FSLogix tuned launcher (recommended for shared hosts):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\OneDriveHealth\Run-OneDriveHealth-TS.ps1"
```

## Recommended deployment

Use a Scheduled Task in the logged-in user context:

- Trigger: At logon
- Trigger: Repeat every 15 or 30 minutes
- Security: Run only when user is logged on (interactive token)

Recommended script location:

- `C:\ProgramData\OneDriveHealth\OneDrive-Health-Synthetic.ps1`

## TS/FSLogix profile (40+ users)

Recommended settings for dense TS/RDS hosts:

- Use `Run-OneDriveHealth-TS.ps1` for routine checks.
- Schedule every 30 minutes (preferred over 15 for shared hosts).
- Add Task Scheduler random delay (for example 2-10 minutes).
- Keep remediation disabled by default on TS (`Run-OneDriveHealth-TS.ps1` without switches).
- If you need login prompting on stopped OneDrive in TS, run:
  - `Run-OneDriveHealth-TS.ps1 -LaunchUiIfStopped`

What `-TsSafeMode` changes:

- Startup jitter defaults to `5-25` seconds.
- Sync wait defaults to `20-45` seconds.
- Log scanning uses a lower file/byte budget to reduce FSLogix profile I/O.
- UI launch on stopped OneDrive is disabled by default.

## Zabbix integration pattern (simple)

Best practice:

1. Run the script from Scheduled Task as the user.
2. Save numeric output to `C:\ProgramData\OneDriveHealth\status.txt`.
3. Have Zabbix read `status.txt` (easy and stable when agent runs as SYSTEM).

## Troubleshooting quick checks

- Always `3`:
  - Task is likely running without an interactive user session.
- Always `1`:
  - OneDrive is not running in that user session.
- Always `2`:
  - User not signed in to OneDrive Business, `$env:OneDrive` missing, no access to OneDrive folder, or no recent log evidence in `Business1`.
- Unexpected popups:
  - Expected only when UI launch on stopped OneDrive is enabled.

## Notes on false positives and performance

- Uses one fixed file (`health.txt`) to avoid sync clutter.
- Uses randomized delays to avoid synchronized endpoint bursts.
- Adds explicit OneDrive Business sign-in validation to reduce ambiguous results.
- Uses a recent log time window and limited file scan for efficiency.
- Handles errors silently and returns health code instead of crashing.
