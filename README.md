


# update-python.ps1

PowerShell script for Windows to:

- find all Python installs (including Conda envs)
- list outdated pip packages
- optionally update Python, pip packages, Conda packages, and VS Code

---

## What it does

- Discovers Python from:
  - `py -0p`
  - `PATH`
  - registry uninstall entries
  - common folders + optional extra roots / deep search
- Detects Conda / Anaconda / Miniconda and their envs.
- For each interpreter/env:
  - `python -m pip list` and `--outdated`
  - Conda: `conda list`, plus pip list/outdated via `conda run -p <env> python -m pip ...`
- Uses `winget` (if available) to check/update:
  - Python
  - VS Code
- Asks you what to update:
  - all
  - only Python (winget)
  - only packages (pip/Conda)
  - nothing (inventory only)
- Logs all steps and errors to a log file.

---

## Requirements

- Windows PowerShell or PowerShell 7
- Python installed
- Optional:
  - Conda / Anaconda / Miniconda
  - `winget` for Python / VS Code upgrades

---

## Usage

Save as:

```text
update-python.ps1
```

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\update-python.ps1
```

Optional:

```powershell
.\update-python.ps1 -ExtraSearchRoots "E:\Tools","F:\PortableApps"
.\update-python.ps1 -DeepSearch
.\update-python.ps1 -LogFile ".\python_update_log.txt"
```

The script will:

1. Show found Python interpreters and Conda envs plus outdated counts.
2. Ask: `A` (all) / `P` (only Python) / `G` (only packages) / `N` (nothing).
3. Ask whether to include VS Code update (if found).
4. Optionally update Conda and pip packages per env.
5. Re-check outdated packages and print the log path.
