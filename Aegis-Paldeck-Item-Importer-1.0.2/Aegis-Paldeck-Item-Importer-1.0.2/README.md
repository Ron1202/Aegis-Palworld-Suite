# Aegis Paldeck Item Importer 1.0.2

This package builds a complete Aegis-compatible Palworld item database from the **2,466 unique Paldeck item-detail URLs** in `Input\Items.txt`.

## Quick start

1. Extract the ZIP to a writable folder, such as `D:\Downloads\Aegis-Paldeck-Item-Importer-1.0.2`.
2. Double-click **Run-Importer.cmd**.
3. Leave the PowerShell window open. The first complete run can take a while because it visits every item page and downloads icons.
4. Results appear under `Output`.

The importer creates a local HTML cache. Interrupted runs resume from `Output\checkpoint-items.json` and reuse downloaded pages.

## Main outputs

- `Output\aegis-items.json` — streamlined launcher database.
- `Output\items.json` — full metadata database.
- `Output\technologyids.json` — name/ID/category/icon mapping.
- `Output\items.csv` — spreadsheet-friendly export.
- `Output\give-commands.txt` — `!give AssetId:9999`.
- `Output\giveme-commands.txt` — `!giveme AssetId:9999`.
- `Output\Icons` — downloaded item thumbnails.
- `Output\failed-items.json` — pages that could not be imported.
- `Output\import-audit.json` — run summary.
- `Logs` — detailed importer logs.

## Retry failures

After the first run, double-click **Retry-Failed-Items.cmd**. It processes only URLs recorded in `Output\failed-items.json`.

## Faster metadata-only run

Double-click **Run-Importer-No-Icons.cmd** to build the database without downloading thumbnails.

## Refresh everything

Run this from PowerShell inside the package folder:

```powershell
.\Build-Paldeck-Database.ps1 -DownloadIcons -RefreshCache
```

## Use in Aegis Palworld Suite

The preferred source file for the launcher is:

```text
Output\aegis-items.json
```

Copy it into the Suite's database folder and either rename it to the filename expected by the current Suite build or update the Suite's database path to point at it.

## Operational notes

- The importer uses Windows PowerShell 5.1-compatible commands.
- It throttles requests and retries transient failures.
- It does not depend on Python, Node.js, Selenium, or Chrome automation.
- Paldeck can change its HTML structure. Failed parsing is recorded rather than silently discarding records.
