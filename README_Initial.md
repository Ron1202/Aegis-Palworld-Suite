# 🛡️ Aegis Palworld Suite

A modern Windows desktop suite for managing **Palworld Dedicated
Servers** with searchable item databases, admin command generation, and
automatic database synchronization.

------------------------------------------------------------------------

# 📥 Installation Guide

## Step 1 -- Download the Latest Release

Visit:

**https://github.com/Ron1202/Aegis-Palworld-Suite**

Click **Code → Download ZIP** and download:

`Aegis-Palworld-Suite-main.zip`

`docs/images/github-download.png`

`docs/images/download-zip.png`


------------------------------------------------------------------------

## Step 2 -- Extract the ZIP

Right-click the ZIP and choose **Extract All...**

`docs/images/zip-file.png`

`docs/images/extract-all.png`

------------------------------------------------------------------------

## Step 3 -- Choose an Installation Folder

Extract to a permanent location such as:

``` text
C:\Games\Aegis-Palworld-Suite
```

or

``` text
D:\Applications\Aegis-Palworld-Suite
```

Do **not** run the application from inside the ZIP.

------------------------------------------------------------------------

## Step 4 -- Verify the Files

Ensure the folder contains:

-   Launcher.exe
-   Launcher.ps1
-   App
-   Database
-   Engine
-   Icons
-   Logs

Keep **Launcher.exe** beside those folders.



------------------------------------------------------------------------

## Step 5 -- Unblock All Files (Required)

Open **Windows PowerShell as Administrator** and run:

``` powershell
Get-ChildItem -Path "Location_of_extracted_folder" -Recurse | Unblock-File
```

Example:

``` powershell
Get-ChildItem -Path "D:\Applications\Aegis-Palworld-Suite" -Recurse | Unblock-File
```

`docs/images/unblock-file.png`

### Alternative

Right-click a blocked file → **Properties** → check **Unblock** →
**Apply**.

`docs/images/file-properties-unblock.png`

------------------------------------------------------------------------

## Step 6 -- Launch

Double-click:

``` text
Launcher.exe
```

`docs/images/launcher-exe.png`

------------------------------------------------------------------------

## Step 7 -- Enjoy

Features include:

-   Browse verified Palworld Asset IDs
-   Generate Admin Commands
-   Favorites
-   Command History
-   Database Updates
-   Repair Icons

`docs/images/main-window.png`

------------------------------------------------------------------------

# Troubleshooting

If Aegis won't start:

-   Extract the entire ZIP.
-   Run the **Unblock-File** command.
-   Keep Launcher.exe beside the App, Database, Engine, Icons, and Logs
    folders.
-   Check the Logs folder for diagnostics.

Report issues:

https://github.com/Ron1202/Aegis-Palworld-Suite/issues

------------------------------------------------------------------------

Thank you for using **Aegis Palworld Suite**!
