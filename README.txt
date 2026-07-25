AEGIS PALWORLD SUITE 2.0 — DATABASE ENGINE PREVIEW
=====================================================

IMPORTANT
---------
This build removes the three-row demonstration database completely.

The Suite now follows one rule:

    Load a verified full database, or show an honest empty state.

It will not silently substitute Attack Pendant, Air Dash Boots, and Ingot.

START
-----
Recommended first launch:

    Update-and-Open-Aegis-Palworld-Suite.cmd

Open without updating:

    Open-Aegis-Palworld-Suite.cmd

Run only the database engine:

    Update-Database-Only.cmd

ARCHITECTURE
------------
App\
    Aegis-Palworld-Suite.ps1
    Native Windows WPF interface.

Engine\
    Update-PaldeckDatabase.ps1
    Browser-assisted Paldeck discovery and per-page Asset Name verification.

Database\
    items.json
    data.js
    aegis-palworld.sql
    aegis-palworld.db              (when sqlite3.exe is available)
    Palworld-Paldeck-Give-Commands.txt
    Palworld-Database-Audit.txt

Icons\
    Local item artwork cache.

Logs\
    Timestamped update transcripts.

DATABASE SAFETY
---------------
- Minimum accepted record count: 450
- Core validation: Ingot = CopperIngot
- Core validation: Refined Ingot = IronIngot
- URL slugs are never treated as Asset IDs
- Every item page is opened and its Asset Name field is parsed
- Database files are written to staging first
- Existing verified data is preserved when an update fails
- Partial results are never published
- The Suite rejects databases below the verification threshold

SQLITE
------
The engine always creates:

    Database\aegis-palworld.sql

When sqlite3.exe is placed in either:

    Engine\sqlite3.exe
    Tools\sqlite3.exe

the updater also creates:

    Database\aegis-palworld.db

The JSON snapshot remains the Windows PowerShell 5.1 compatibility data store
used by this preview UI.

PALDECK
-------
Paldeck is the sole online item source used by this build.


2.0.1 PATH HOTFIX
-----------------
Fixed the "Database engine is missing" message.

Cause:
The WPF application is stored inside App\, but it incorrectly treated App\ as
the Suite root. It therefore searched for:

    App\Engine\Update-PaldeckDatabase.ps1

instead of:

    Engine\Update-PaldeckDatabase.ps1

Correct path resolution:
    AppRoot  = <Suite>\App
    Root     = <Suite>
    Updater  = <Suite>\Engine\Update-PaldeckDatabase.ps1
    Database = <Suite>\Database\items.json
    Icons    = <Suite>\Icons

Also included:
- Startup folder-structure validation
- Exact missing-path diagnostics
- No stale/demo database migration
- Diagnose-Aegis-Palworld-Suite.cmd for visible error reporting

FIRST RUN
---------
Run:

    Update-and-Open-Aegis-Palworld-Suite.cmd

For troubleshooting, run:

    Diagnose-Aegis-Palworld-Suite.cmd


2.1 FUNCTIONAL UI MILESTONE
---------------------------
Implemented:
- Automatic import of a nearby verified 450+ record Aegis database.
- Safe icon-cache migration from the matching older build.
- Larger item preview artwork and taller item rows.
- Reliable fallback icon resolution.
- Functional Favorites storage and Favorites navigation.
- Functional Command History viewer.
- Functional Settings information dialog.
- Functional Help dialog.
- Glyph-based command tiles and bottom navigation.
- No import of sample or three-row demonstration databases.

Favorites are saved to:

    Database\favorites.json

Copied command history is saved to:

    Database\command-history.txt


2.1.1 ITEM ICON REPAIR
----------------------
Fixed widespread blank item thumbnails.

Causes:
1. The fallback artwork was SVG. WPF BitmapImage does not reliably render SVG.
2. A verified database could be imported without its full matching icon cache.
3. Predictable icon URLs do not resolve every Paldeck record.

Fixes:
- Replaced the SVG fallback with Icons\_fallback.png.
- Added Repair-Item-Icons.cmd.
- Added a Repair Icons button to the Suite.
- Repairs icons from nearby older Aegis icon caches first.
- Tries Paldeck's predictable item-icon URLs.
- Parses each Paldeck item page for alternate WebP and Open Graph artwork.
- Updates Database\items.json with repaired icon paths.
- Writes Database\Icon-Repair-Report.txt.

USAGE
-----
Close the Suite and run:

    Repair-Item-Icons.cmd

After it completes, reopen:

    Open-Aegis-Palworld-Suite.cmd

The repair can also be started from the Suite's Repair Icons button.


2.1.2 WPF PNG THUMBNAIL FIX
---------------------------
The cached item artwork was valid WebP, but WPF BitmapImage on some Windows
systems does not decode WebP. This caused every thumbnail frame to appear black.

This version stores all display thumbnails as PNG.

Repair process:
1. Reuses an existing PNG cache when available.
2. Finds existing WebP artwork in older Aegis folders.
3. Downloads missing WebP artwork from Paldeck.
4. Uses Chrome, Edge, or Brave in headless mode to render each WebP as PNG.
5. Updates Database\items.json to use Icons\<AssetID>.png.
6. Uses Icons\_fallback.png only when no artwork can be obtained.

Run:

    Repair-Item-Icons.cmd

Then close and reopen:

    Open-Aegis-Palworld-Suite.cmd

Update-and-Open now automatically runs PNG conversion after a successful
database update.


2.1.3 WPF IMAGE-BINDING FIX
---------------------------
Fixed empty thumbnail frames when valid PNG files already existed.

Cause:
The DataGrid Image control was bound to IconPath as a string. The automatic WPF
string-to-image converter failed silently on the affected Windows system.

Fix:
- Loads each image through FileStream into BitmapImage.
- Uses BitmapCacheOption.OnLoad.
- Freezes the decoded BitmapImage for DataGrid virtualization.
- Binds the table directly to ThumbnailImage (BitmapSource), not a path string.
- Uses the same decoded image object in the large item preview.
- Falls back to Icons\_fallback.png through the same decoder.

The lower-left status now reports:

    <count> thumbnails loaded

This confirms how many image objects WPF successfully decoded.


2.1.4 LAUNCHER AND THUMBNAIL STARTUP FIX
----------------------------------------
Fixed Open-Aegis-Palworld-Suite.cmd appearing to do nothing.

Cause:
Version 2.1.3 decoded every one of the 516 item images before showing the main
window. Since PowerShell launched hidden, the application appeared not to open.

Changes:
- Thumbnail rows now bind to absolute System.Uri objects.
- WPF loads table thumbnails on demand as rows become visible.
- Only the selected large preview is decoded through FileStream.
- Fixed the malformed thumbnail status assignment.
- Added Logs\Suite-Startup-Error.txt.
- Added Logs\Launcher-Error.txt.
- Added Open-Aegis-Visible-Diagnostics.cmd.

Normal launch:

    Open-Aegis-Palworld-Suite.cmd

Visible troubleshooting launch:

    Open-Aegis-Visible-Diagnostics.cmd


2.1.5 COMMAND BUILDER STARTUP FIX
---------------------------------
Fixed the startup error:

    The term 'SetFields' is not recognized.

Cause:
BuildSubcommands called SetFields, but the SetFields function was accidentally
omitted during the previous UI patch.

Restored behavior:
- Shows Item Amount for give commands.
- Shows Player Name for player-targeted commands.
- Shows Pal Asset ID and level for spawn/capture.
- Shows XP amount for experience commands.
- Shows coordinates for teleport.
- Shows announcement message and server hour fields.
- Shows enable/disable for flight.
- Shows a custom command field.
- Hides irrelevant controls for parameterless commands.

A startup self-check now verifies that SetFields, BuildSubcommands, and
UpdateCommand all exist before the window opens.


2.1.6 ITEM DETAIL PREVIEW ICON FIX
----------------------------------
The large item detail preview now uses the same ThumbnailUri as the icon beside
the item name in the left-hand list.

This removes the separate preview decoder path that was incorrectly showing the
default Aegis shield for items whose list thumbnails rendered correctly.


2.1.7 CLEAN ICON BACKGROUNDS
----------------------------
Fixed bright green and pixelated backgrounds around item artwork.

Cause:
The Chromium WebP-to-PNG converter captured transparent pixels with invalid
underlying RGB values. WPF then displayed those RGB values as green.

Fix:
- Removed transparent screenshot mode.
- Renders icons against the Suite's #01060B dark item-card background.
- Forces all existing PNG thumbnails to be rebuilt.
- Applies the same clean background to list thumbnails and the large preview.

Run once:

    Repair-Item-Icons.cmd

Then reopen:

    Open-Aegis-Palworld-Suite.cmd


2.1.8 EDGE-CONNECTED ICON DE-MATTING
------------------------------------
Removes the remaining gray checker/pixel backgrounds from a small number of
legacy item icons.

The cleanup is deliberately conservative:
- Starts only from the outer image border.
- Removes dark or low-saturation gray pixels connected to that border.
- Replaces them with the Suite's #01060B background.
- Preserves isolated gray/silver pixels belonging to the actual item.
- Uses 8-direction flood filling to remove checkerboard islands connected
  diagonally.

Run:

    Repair-Item-Icons.cmd

Then reopen:

    Open-Aegis-Palworld-Suite.cmd


2.2.0 UI AND DESCRIPTION UPDATE
--------------------------------
- Dark custom dropdowns.
- Icon-enhanced Export, Repair Icons, and Update Database buttons.
- Larger command tiles.
- Framed bottom navigation icons with improved selected states.
- Description extraction during database updates.
- Repair-Item-Descriptions.cmd for the existing database.


2.2.1 COMBOBOX INTERACTION FIX
------------------------------
Fixed the Category and Quick Command dropdowns not opening.

Cause:
The custom dark ComboBox template displayed the selected value and arrow, but
did not include a ToggleButton bound to IsDropDownOpen.

Fix:
- Added a clickable ToggleButton covering the full ComboBox.
- Bound ToggleButton.IsChecked to ComboBox.IsDropDownOpen.
- Preserved the dark popup, hover border, selected-item styling, and arrow.
- Applies to both Category and Quick Command dropdowns.


2.2.2 CLIPBOARD RELIABILITY FIX
-------------------------------
Fixed HRESULT 0x800401D0 (CLIPBRD_E_CANT_OPEN) when copying commands.

Changes:
- Clipboard writes retry up to 12 times.
- A temporary clipboard lock no longer terminates the Suite.
- A nonfatal warning is shown only when all retry attempts fail.
- Command history is written only after a successful clipboard copy.


2.2.3 WHITE COMBOBOX TEXT FIX
-----------------------------
- Selected values in Category and Quick Command boxes now use a TextBlock.
- Foreground is forced to #EAF2FF.
- Dark dropdown behavior and clipboard reliability fixes are preserved.


2.3.0 FULL PALDECK IMPORT ENGINE
--------------------------------
Run:

    Full-Import-All-Paldeck-Items.cmd

The importer now combines:
- Raw Paldeck HTML.
- Embedded React/Next.js application payloads.
- Normal and escaped /items/<AssetID> URLs.
- Paldeck sitemap files and sitemap indexes.
- Fully rendered infinite-scroll results.
- Every visible category.
- Ascending and descending sort passes.
- JSON/API resources loaded by the browser.
- Previously verified local Asset IDs as a no-regression safety net.

The update is rejected unless these Paldeck records are verified:
- Money
- CopperIngot
- IronIngot
- WorldTreeIngot (Paloxite Ingot)

The new database also stores:
- Paldeck numeric item number
- Type A and Type B
- Rank and rarity
- Price
- Weight
- Stack size
- Description

Clipboard update:
The Suite now uses PowerShell Set-Clipboard, which successfully works on
systems where WPF Windows.Clipboard returned CLIPBRD_E_CANT_OPEN.
