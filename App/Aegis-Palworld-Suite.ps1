param([switch]$Update)
$ErrorActionPreference = 'Stop'

$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $AppRoot

$DataFile = Join-Path $Root 'Database\items.json'
$Updater = Join-Path $Root 'Engine\Update-PaldeckDatabase.ps1'
$HistoryFile = Join-Path $Root 'Database\command-history.txt'
$FallbackIcon = Join-Path $Root 'Icons\_fallback.png'
$IconRepairEngine = Join-Path $Root 'Engine\Repair-ItemIcons.ps1'
$FavoritesFile = Join-Path $Root 'Database\favorites.json'
$SettingsFile = Join-Path $Root 'Database\settings.json'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml


function Test-DatabaseSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path $Path)) { return $false }

        $raw = [IO.File]::ReadAllText($Path)
        if ($Path.EndsWith('.js',[StringComparison]::OrdinalIgnoreCase)) {
            $raw = $raw -replace '^\s*window\.PALWORLD_DATA\s*=\s*',''
            $raw = $raw -replace ';\s*$',''
        }

        $obj = $raw | ConvertFrom-Json
        return (@($obj.records).Count -ge 450)
    }
    catch {
        return $false
    }
}

function Import-VerifiedPreviousDatabase {
    if (Test-DatabaseSnapshot $DataFile) { return $true }

    $searchRoots = New-Object Collections.Generic.List[string]
    $searchRoots.Add((Split-Path $Root -Parent))

    if ($env:USERPROFILE) {
        $downloads = Join-Path $env:USERPROFILE 'Downloads'
        if (Test-Path $downloads) { $searchRoots.Add($downloads) }
    }

    $candidates = New-Object Collections.Generic.List[object]

    foreach ($searchRoot in ($searchRoots | Select-Object -Unique)) {
        if (-not (Test-Path $searchRoot)) { continue }

        Get-ChildItem -Path $searchRoot -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -in @('items.json','data.js') -and
                $_.FullName -ne $DataFile -and
                $_.FullName -notmatch '\\\.staging\\'
            } |
            ForEach-Object {
                if (Test-DatabaseSnapshot $_.FullName) {
                    $candidates.Add($_)
                }
            }
    }

    $candidate = $candidates |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $candidate) { return $false }

    try {
        $raw = [IO.File]::ReadAllText($candidate.FullName)
        if ($candidate.Extension -eq '.js') {
            $raw = $raw -replace '^\s*window\.PALWORLD_DATA\s*=\s*',''
            $raw = $raw -replace ';\s*$',''
        }

        $obj = $raw | ConvertFrom-Json
        $records = @($obj.records)
        if ($records.Count -lt 450) { return $false }

        $normalized = [ordered]@{
            schemaVersion = 2
            generatedAt = $(if ($obj.generatedAt) { $obj.generatedAt } else { (Get-Date).ToString('s') })
            source = $(if ($obj.source) { $obj.source } else { 'https://paldeck.cc/items' })
            count = $records.Count
            records = $records
        }

        New-Item -ItemType Directory -Path (Split-Path $DataFile -Parent) -Force | Out-Null
        [IO.File]::WriteAllText(
            $DataFile,
            ($normalized | ConvertTo-Json -Depth 9),
            [Text.UTF8Encoding]::new($false)
        )

        # Copy the matching icon cache when present.
        $candidateRoot = Split-Path $candidate.DirectoryName -Parent
        $iconSources = @(
            (Join-Path $candidate.DirectoryName 'Icons'),
            (Join-Path $candidateRoot 'Icons')
        )

        foreach ($iconSource in $iconSources) {
            if (Test-Path $iconSource) {
                New-Item -ItemType Directory -Path (Join-Path $Root 'Icons') -Force | Out-Null
                Copy-Item (Join-Path $iconSource '*') (Join-Path $Root 'Icons') -Recurse -Force -ErrorAction SilentlyContinue
                break
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Read-Favorites {
    try {
        if (-not (Test-Path $FavoritesFile)) { return @() }
        return @([IO.File]::ReadAllText($FavoritesFile) | ConvertFrom-Json)
    }
    catch {
        return @()
    }
}

function Save-Favorites {
    param([string[]]$AssetIds)

    $unique = @($AssetIds | Where-Object { $_ } | Sort-Object -Unique)
    [IO.File]::WriteAllText(
        $FavoritesFile,
        ($unique | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-CommandHistory {
    param([string]$Command)

    if (-not $Command) { return }
    $entry = "{0}`t{1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),$Command
    Add-Content -Path $HistoryFile -Value $entry -Encoding UTF8
}

Import-VerifiedPreviousDatabase | Out-Null


function Get-WpfBitmap {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$FallbackPath
    )

    $candidate = $Path
    if (-not $candidate -or -not (Test-Path $candidate)) {
        $candidate = $FallbackPath
    }

    if (-not $candidate -or -not (Test-Path $candidate)) {
        return $null
    }

    try {
        # Load through a stream so the image is fully decoded immediately,
        # detached from the source file, and safe for DataGrid virtualization.
        $stream = [IO.File]::Open(
            $candidate,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )

        try {
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            $bitmap.StreamSource = $stream
            $bitmap.DecodePixelWidth = 64
            $bitmap.DecodePixelHeight = 64
            $bitmap.EndInit()
            $bitmap.Freeze()
            return $bitmap
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        if ($candidate -ne $FallbackPath -and $FallbackPath -and (Test-Path $FallbackPath)) {
            try {
                $fallbackStream = [IO.File]::Open(
                    $FallbackPath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::ReadWrite
                )

                try {
                    $fallbackBitmap = New-Object Windows.Media.Imaging.BitmapImage
                    $fallbackBitmap.BeginInit()
                    $fallbackBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                    $fallbackBitmap.StreamSource = $fallbackStream
                    $fallbackBitmap.DecodePixelWidth = 64
                    $fallbackBitmap.DecodePixelHeight = 64
                    $fallbackBitmap.EndInit()
                    $fallbackBitmap.Freeze()
                    return $fallbackBitmap
                }
                finally {
                    $fallbackStream.Dispose()
                }
            }
            catch {
                return $null
            }
        }

        return $null
    }
}

function Read-Database {
    if (-not (Test-Path $DataFile)) { return @() }

    try {
        $obj = [IO.File]::ReadAllText($DataFile) | ConvertFrom-Json
        $rows = @($obj.records)

        # Never present a sample, partial, or damaged database as complete.
        if ($rows.Count -lt 450) {
            return @()
        }

        foreach ($row in $rows) {
            $relativeIcon = if ($row.icon) {
                [string]$row.icon
            }
            else {
                "Icons/_fallback.png"
            }

            $resolvedIcon = Join-Path $Root ($relativeIcon -replace '/', '\')
            if (-not (Test-Path $resolvedIcon)) {
                $resolvedIcon = $FallbackIcon
            }

            $row | Add-Member -NotePropertyName IconPath -NotePropertyValue $resolvedIcon -Force

            $thumbnailUri = [Uri]::new(
                $resolvedIcon,
                [UriKind]::Absolute
            )

            $row | Add-Member `
                -NotePropertyName ThumbnailUri `
                -NotePropertyValue $thumbnailUri `
                -Force

            if (-not $row.description) {
                $row | Add-Member -NotePropertyName description -NotePropertyValue '' -Force
            }
        }

        return $rows
    }
    catch {
        return @()
    }
}

function Invoke-DatabaseUpdate {
    if (-not (Test-Path $Updater)) {
        [Windows.MessageBox]::Show(
            "Database engine is missing.`r`n`r`nExpected location:`r`n$Updater",
            'Aegis Palworld Suite'
        ) | Out-Null
        return
    }

    try {
        Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @(
                '-NoLogo',
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$Updater`""
            ) `
            -WorkingDirectory $Root

        if ($ui -and $ui.ContainsKey('StatusText')) {
            $ui.StatusText.Text = (
                'Database Engine opened in a separate window. ' +
                'When it reports success, close and reopen the Suite.'
            )
        }
    }
    catch {
        [Windows.MessageBox]::Show(
            "Could not start the Database Engine.`r`n`r`n$($_.Exception.Message)",
            'Aegis Palworld Suite'
        ) | Out-Null
    }
}


function Test-SuiteLayout {
    $missing = New-Object Collections.Generic.List[string]

    if (-not (Test-Path $AppRoot)) {
        $missing.Add("Application folder: $AppRoot")
    }
    if (-not (Test-Path $Updater)) {
        $missing.Add("Database engine: $Updater")
    }
    if (-not (Test-Path (Split-Path $DataFile -Parent))) {
        $missing.Add("Database folder: $(Split-Path $DataFile -Parent)")
    }
    if (-not (Test-Path (Join-Path $Root 'Icons'))) {
        $missing.Add("Icons folder: $(Join-Path $Root 'Icons')")
    }

    if ($missing.Count -gt 0) {
        $message = "The Aegis folder structure is incomplete:`r`n`r`n" +
                   (($missing | ForEach-Object { "- $_" }) -join "`r`n") +
                   "`r`n`r`nPlease extract the entire ZIP before launching."
        [Windows.MessageBox]::Show(
            $message,
            'Aegis Palworld Suite - Installation Check'
        ) | Out-Null
        return $false
    }

    return $true
}

if (-not (Test-SuiteLayout)) {
    exit 1
}


function Invoke-IconRepair {
    if (-not (Test-Path $IconRepairEngine)) {
        [Windows.MessageBox]::Show(
            "Icon repair engine is missing.`r`n`r`nExpected:`r`n$IconRepairEngine",
            'Aegis Palworld Suite'
        ) | Out-Null
        return
    }

    try {
        Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @(
                '-NoLogo',
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$IconRepairEngine`""
            ) `
            -WorkingDirectory $Root

        $ui.StatusText.Text = (
            'Icon Repair opened in a separate window. ' +
            'Close and reopen the Suite when it completes.'
        )
    }
    catch {
        [Windows.MessageBox]::Show(
            "Could not start Icon Repair.`r`n`r`n$($_.Exception.Message)",
            'Aegis Palworld Suite'
        ) | Out-Null
    }
}

$commandDefinitions=[ordered]@{
 'Give Item'=@{Types=@('Give to yourself','Give to another player');Syntax='!giveme item:amount';Help='Give the selected Paldeck item to yourself or another player.'}
 'Spawn Pal'=@{Types=@('Spawn Pal','Capture Pal');Syntax='!spawn PalAsset Level';Help='Spawn or capture a Pal using its Pal Asset ID.'}
 'Give XP'=@{Types=@('Give yourself XP','Give player XP');Syntax='!giveexp amount';Help='Grant experience to yourself or a named player.'}
 'Player'=@{Types=@('Kick Player','Ban Player','Unban Player','Slay Player','Freeze Player','Unfreeze Player');Syntax='!kick playername';Help='Player moderation and control commands.'}
 'Teleport'=@{Types=@('Teleport to Coordinates','Get Position','Unstuck');Syntax='!goto x,y,z';Help='Movement and position utilities.'}
 'Server'=@{Types=@('Announce','Set Time','Show Time');Syntax='!announce message';Help='Server-wide announcements and time controls.'}
 'Other'=@{Types=@('Fly','Spectate','Help','Custom Command');Syntax='!fly enable';Help='Additional administrative utilities.'}
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Aegis Palworld Suite 2.3.4" Width="1520" Height="960" MinWidth="1260" MinHeight="780"
 WindowStartupLocation="CenterScreen" Background="#050D18" Foreground="#F2F6FC" FontFamily="Segoe UI">
 <Window.Resources>
  <SolidColorBrush x:Key="Panel" Color="#081626"/><SolidColorBrush x:Key="Panel2" Color="#0B1B2D"/>
  <SolidColorBrush x:Key="Border" Color="#26415D"/><SolidColorBrush x:Key="Accent" Color="#0869D8"/>
  <SolidColorBrush x:Key="Muted" Color="#9BB1C8"/>
  <Style TargetType="TextBox"><Setter Property="Background" Value="#071321"/><Setter Property="Foreground" Value="#F2F6FC"/><Setter Property="CaretBrush" Value="White"/><Setter Property="BorderBrush" Value="#385875"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="11,8"/><Setter Property="FontSize" Value="14"/></Style>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#F2F6FC"/><Setter Property="Background" Value="#0C1C2E"/><Setter Property="BorderBrush" Value="#355270"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="13,8"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#143250"/><Setter TargetName="b" Property="BorderBrush" Value="#4E83B6"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#0754AF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#0756B7"/><Setter Property="BorderBrush" Value="#1785FF"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  <Style x:Key="DarkComboItem" TargetType="ComboBoxItem"><Setter Property="Foreground" Value="#EAF2FF"/><Setter Property="Background" Value="#0B1A2B"/><Setter Property="Padding" Value="10,7"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem"><Border x:Name="item" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="item" Property="Background" Value="#173754"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="item" Property="Background" Value="#0A5FC4"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ComboBox">
   <Setter Property="Foreground" Value="#EAF2FF"/>
   <Setter Property="Background" Value="#091827"/>
   <Setter Property="BorderBrush" Value="#315273"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Padding" Value="12,0"/>
   <Setter Property="ItemContainerStyle" Value="{StaticResource DarkComboItem}"/>
   <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="ComboBox">
      <Grid>
       <ToggleButton
        x:Name="DropDownToggle"
        Focusable="False"
        ClickMode="Press"
        IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
        <ToggleButton.Template>
         <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="OuterBorder"
                  Background="#091827"
                  BorderBrush="#315273"
                  BorderThickness="1"
                  CornerRadius="5">
           <Grid>
            <Grid.ColumnDefinitions>
             <ColumnDefinition Width="*"/>
             <ColumnDefinition Width="36"/>
            </Grid.ColumnDefinitions>
            <TextBlock
             Grid.Column="0"
             Margin="12,0,4,0"
             VerticalAlignment="Center"
             HorizontalAlignment="Left"
             Foreground="#EAF2FF"
             Text="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>
            <Border Grid.Column="1" Background="#0D2034" CornerRadius="0,5,5,0">
             <TextBlock Text="&#xE70D;"
                        FontFamily="Segoe MDL2 Assets"
                        FontSize="12"
                        Foreground="#CFE5FF"
                        HorizontalAlignment="Center"
                        VerticalAlignment="Center"/>
            </Border>
           </Grid>
          </Border>
          <ControlTemplate.Triggers>
           <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="OuterBorder" Property="BorderBrush" Value="#4F8DC7"/>
           </Trigger>
           <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="OuterBorder" Property="BorderBrush" Value="#1687FF"/>
            <Setter TargetName="OuterBorder" Property="Background" Value="#0D2034"/>
           </Trigger>
          </ControlTemplate.Triggers>
         </ControlTemplate>
        </ToggleButton.Template>
       </ToggleButton>

       <Popup
        x:Name="PART_Popup"
        Placement="Bottom"
        AllowsTransparency="True"
        Focusable="False"
        IsOpen="{TemplateBinding IsDropDownOpen}"
        PopupAnimation="Fade">
        <Border Margin="0,4,0,0"
                Background="#0B1A2B"
                BorderBrush="#315273"
                BorderThickness="1"
                CornerRadius="5"
                MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
         <ScrollViewer MaxHeight="360"
                       CanContentScroll="True"
                       VerticalScrollBarVisibility="Auto">
          <ItemsPresenter/>
         </ScrollViewer>
        </Border>
       </Popup>
      </Grid>
      <ControlTemplate.Triggers>
       <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Opacity" Value="0.5"/>
       </Trigger>
      </ControlTemplate.Triggers>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style TargetType="DataGrid"><Setter Property="Background" Value="#061321"/><Setter Property="Foreground" Value="#F1F5FA"/><Setter Property="BorderBrush" Value="#263F58"/><Setter Property="GridLinesVisibility" Value="All"/><Setter Property="HorizontalGridLinesBrush" Value="#20364C"/><Setter Property="VerticalGridLinesBrush" Value="#20364C"/><Setter Property="RowBackground" Value="#071624"/><Setter Property="AlternatingRowBackground" Value="#0A1B2C"/><Setter Property="HeadersVisibility" Value="Column"/><Setter Property="RowHeaderWidth" Value="0"/></Style>
  <Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#0C1D30"/><Setter Property="Foreground" Value="#F4F7FB"/><Setter Property="BorderBrush" Value="#29435E"/><Setter Property="BorderThickness" Value="0,0,1,1"/><Setter Property="Padding" Value="9,8"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  <Style TargetType="DataGridRow"><Setter Property="Foreground" Value="#F4F7FB"/><Setter Property="Height" Value="35"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#0865C7"/><Setter Property="Foreground" Value="White"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#123454"/></Trigger></Style.Triggers></Style>
  <Style TargetType="DataGridCell"><Setter Property="Foreground" Value="{Binding RelativeSource={RelativeSource AncestorType=DataGridRow},Path=Foreground}"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="7,3"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/></Trigger></Style.Triggers></Style>
  <Style x:Key="TopAction" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Padding" Value="10,0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="17" Foreground="#D3E8FC" HorizontalAlignment="Center" VerticalAlignment="Center"/><ContentPresenter Grid.Column="1" Margin="2,0,8,0" HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#143250"/><Setter TargetName="b" Property="BorderBrush" Value="#4E83B6"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#0754AF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="Tile" TargetType="RadioButton"><Setter Property="Foreground" Value="#F2F6FC"/><Setter Property="Background" Value="#0B1B2D"/><Setter Property="BorderBrush" Value="#29445F"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton"><Border x:Name="tile" Width="88" Height="88" CornerRadius="5" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><StackPanel VerticalAlignment="Center"><TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontWeight="Normal" FontSize="24" HorizontalAlignment="Center" Foreground="#D8EBFF"/><TextBlock Text="{TemplateBinding Content}" FontSize="12" Margin="2,7,2,0" HorizontalAlignment="Center"/></StackPanel></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="tile" Property="Background" Value="#0755B4"/><Setter TargetName="tile" Property="BorderBrush" Value="#1689FF"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tile" Property="BorderBrush" Value="#5796CF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="Nav" TargetType="RadioButton"><Setter Property="Background" Value="Transparent"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton"><Border x:Name="nav" CornerRadius="5" Margin="8,7" Padding="22,10" Background="{TemplateBinding Background}" BorderBrush="#162A3D" BorderThickness="1"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Border Width="34" Height="34" Background="#08192A" BorderBrush="#315273" BorderThickness="1" CornerRadius="5" Margin="0,0,11,0"><TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#E2F0FF" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="NavLabel" Text="{TemplateBinding Content}" Foreground="#DDE8F4" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/></StackPanel></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="nav" Property="Background" Value="#07469B"/><Setter TargetName="nav" Property="BorderBrush" Value="#1487FF"/><Setter TargetName="NavLabel" Property="Foreground" Value="White"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="nav" Property="Background" Value="#102944"/><Setter TargetName="nav" Property="BorderBrush" Value="#3B6A92"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Grid>
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Grid Grid.Row="0" Margin="22,18,22,12"><Grid.ColumnDefinitions><ColumnDefinition Width="74"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
   <Viewbox Width="58" Height="66"><Canvas Width="70" Height="82"><Path Fill="#0B6ACF" Stroke="#B8DFFF" StrokeThickness="3" Data="M35,2 L66,14 L61,57 Q51,73 35,80 Q19,73 9,57 L4,14 Z"/><Path Fill="White" Data="M35,17 L40,30 L54,30 L43,38 L47,52 L35,44 L23,52 L27,38 L16,30 L30,30 Z"/></Canvas></Viewbox>
   <StackPanel Grid.Column="1" VerticalAlignment="Center"><TextBlock Text="Aegis Palworld Suite" FontSize="29" FontWeight="Bold"/><TextBlock Text="Paldeck Asset IDs  |  Admin Commands 3.0.2  |  Favorites  |  Command history" Foreground="#48AEFF" FontSize="14" Margin="0,4,0,0"/></StackPanel>
  </Grid>
  <Grid Grid.Row="1" Margin="20,0,20,12"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="235"/><ColumnDefinition Width="235"/><ColumnDefinition Width="130"/><ColumnDefinition Width="135"/><ColumnDefinition Width="145"/></Grid.ColumnDefinitions>
   <Grid Grid.Column="0" Margin="0,0,12,0"><TextBox x:Name="SearchBox"/><TextBlock x:Name="SearchHint" Text="Search by name, Asset ID, command, or description..." Foreground="#8EA4BA" Margin="12,0" IsHitTestVisible="False" VerticalAlignment="Center"/></Grid>
   <ComboBox x:Name="CategoryBox" Grid.Column="1" Margin="0,0,12,0"/><ComboBox x:Name="QuickCommandBox" Grid.Column="2" Margin="0,0,12,0"/>
   <Button x:Name="ExportButton" Grid.Column="3" Style="{StaticResource TopAction}" Tag="&#xE74E;" Content="Export Items" Margin="0,0,10,0"/><Button x:Name="RepairIconsButton" Grid.Column="4" Style="{StaticResource TopAction}" Tag="&#xE72C;" Content="Repair Icons" Margin="0,0,10,0"/><Button x:Name="UpdateButton" Grid.Column="5" Style="{StaticResource TopAction}" Tag="&#xE895;" Content="Update Database"/>
  </Grid>
  <Grid Grid.Row="2" Margin="20,0,20,0"><Grid.ColumnDefinitions><ColumnDefinition Width="1.33*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
   <Border Grid.Column="0" Background="#061321" BorderBrush="#263F58" BorderThickness="1" CornerRadius="7" Margin="0,0,12,0"><Grid><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="38"/></Grid.RowDefinitions>
    <DataGrid x:Name="ItemGrid" Grid.Row="0" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow" CanUserSortColumns="True">
     <DataGrid.Columns>
      <DataGridTemplateColumn Header="Item Name" Width="2.1*"><DataGridTemplateColumn.CellTemplate><DataTemplate><StackPanel Orientation="Horizontal"><Border Width="29" Height="29" Background="#02070D" BorderBrush="#223C55" BorderThickness="1" CornerRadius="3" Margin="0,0,9,0"><Image Source="{Binding ThumbnailUri}" Width="25" Height="25" Stretch="Uniform" SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="HighQuality"/></Border><TextBlock Text="{Binding name}" VerticalAlignment="Center"/></StackPanel></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
      <DataGridTextColumn Header="Asset ID" Binding="{Binding id}" Width="1.8*"/><DataGridTextColumn Header="Category" Binding="{Binding category}" Width="1.05*"/><DataGridTextColumn Header="Example Command" Binding="{Binding command}" Width="2.2*"/>
     </DataGrid.Columns>
    </DataGrid>
    <TextBlock x:Name="StatusText" Grid.Row="1" Foreground="#43B5FF" Margin="12,0" VerticalAlignment="Center"/>
   </Grid></Border>
   <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto"><StackPanel>
    <Border Background="#071625" BorderBrush="#263F58" BorderThickness="1" CornerRadius="7" Padding="16" Margin="0,0,0,10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="262"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
     <Border Width="244" Height="238" Background="#01060B" BorderBrush="#28445F" BorderThickness="1" CornerRadius="7"><Image x:Name="PreviewImage" Width="218" Height="212" Stretch="Uniform" SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="HighQuality"/></Border>
     <StackPanel Grid.Column="1" Margin="18,0,0,0"><TextBlock x:Name="PreviewName" FontSize="24" FontWeight="Bold" TextWrapping="Wrap"/><Grid Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text="Asset ID" FontWeight="SemiBold"/><TextBlock x:Name="PreviewId" Grid.Column="1" Foreground="#55B4FF"/>
      <TextBlock Text="Category" Grid.Row="1" FontWeight="SemiBold" Margin="0,13,0,0"/><Border Grid.Row="1" Grid.Column="1" Background="#302244" CornerRadius="3" Padding="7,3" Margin="0,9,0,0" HorizontalAlignment="Left"><TextBlock x:Name="PreviewCategory" Foreground="#D9B5FF"/></Border>
      <TextBlock Text="Paldeck Page" Grid.Row="2" FontWeight="SemiBold" Margin="0,13,0,0"/><TextBlock x:Name="PageText" Grid.Row="2" Grid.Column="1" Foreground="#45AEFF" Text="Open item page" Margin="0,13,0,0" TextDecorations="Underline" Cursor="Hand"/>
      <TextBlock Text="Description" Grid.Row="3" FontWeight="SemiBold" Margin="0,13,0,0"/><TextBlock x:Name="DescriptionText" Grid.Row="3" Grid.Column="1" Margin="0,13,0,0" TextWrapping="Wrap"/>
     </Grid></StackPanel>
     <Grid Grid.ColumnSpan="2" VerticalAlignment="Bottom" Margin="0,250,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
      <Button x:Name="OpenPageButton" Grid.Column="0" Height="42" Content="Open Paldeck Page" Margin="0,0,8,0"/>
      <Button x:Name="FavoriteButton" Grid.Column="1" Height="42" Content="Add Favorite"/>
     </Grid>
    </Grid></Border>
    <Border Background="#071625" BorderBrush="#263F58" BorderThickness="1" CornerRadius="7" Padding="16"><StackPanel>
     <TextBlock Text="Admin Command Builder" FontSize="22" FontWeight="Bold" Margin="0,0,0,12"/>
     <UniformGrid Rows="1" Columns="7" Margin="0,0,0,14"><RadioButton x:Name="GiveTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Give Item" Tag="&#xE7BF;" IsChecked="True"/><RadioButton x:Name="SpawnTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Spawn Pal" Tag="&#xE91B;"/><RadioButton x:Name="XpTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Give XP" Tag="XP"/><RadioButton x:Name="PlayerTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Player" Tag="&#xE716;"/><RadioButton x:Name="TeleportTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Teleport" Tag="&#xE707;"/><RadioButton x:Name="ServerTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Server" Tag="&#xE823;"/><RadioButton x:Name="OtherTile" GroupName="CommandTile" Style="{StaticResource Tile}" Content="Other" Tag="..."/></UniformGrid>
     <TextBlock x:Name="CommandHelp" Foreground="#A6BDD3" Margin="0,0,0,10"/>
     <WrapPanel x:Name="SubcommandPanel" Margin="0,0,0,12"/>
     <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <StackPanel x:Name="PlayerField" Grid.Column="0" Margin="0,0,10,10" Visibility="Collapsed"><TextBlock Text="Player name" Margin="0,0,0,5"/><TextBox x:Name="PlayerBox"/></StackPanel>
      <StackPanel x:Name="AmountField" Grid.Column="0" Margin="0,0,10,10"><TextBlock Text="Item amount" Margin="0,0,0,5"/><TextBox x:Name="AmountBox" Text="9999"/></StackPanel>
      <StackPanel x:Name="PalField" Grid.Column="0" Margin="0,0,10,10" Visibility="Collapsed"><TextBlock Text="Pal Asset ID" Margin="0,0,0,5"/><TextBox x:Name="PalBox"/></StackPanel>
      <StackPanel x:Name="ValueField" Grid.Column="1" Margin="10,0,0,10" Visibility="Collapsed"><TextBlock x:Name="ValueLabel" Text="Value" Margin="0,0,0,5"/><TextBox x:Name="ValueBox"/></StackPanel>
      <StackPanel Grid.Column="1" Margin="10,1,0,0"><CheckBox x:Name="MaxStackBox" Content="Give max stack" IsChecked="True" Foreground="#F2F6FC" Margin="0,0,0,11"/><CheckBox x:Name="SilentBox" Content="Silent command" Foreground="#F2F6FC"/></StackPanel>
     </Grid>
     <TextBlock Text="Generated command" Margin="0,4,0,5"/><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="56"/></Grid.ColumnDefinitions><TextBox x:Name="GeneratedBox" FontFamily="Consolas" IsReadOnly="True" FontSize="15"/><Button x:Name="SmallCopyButton" Grid.Column="1" Content="COPY" Padding="4"/></Grid>
     <Button x:Name="CopyButton" Content="Copy Command" Style="{StaticResource PrimaryButton}" Height="45" Margin="0,10,0,0"/>
    </StackPanel></Border>
   </StackPanel></ScrollViewer>
  </Grid>
  <Border Grid.Row="3" Background="#050C15" BorderBrush="#263F58" BorderThickness="1,1,1,0" Margin="0,14,0,0"><UniformGrid Rows="1" Columns="6" Height="70"><RadioButton x:Name="ItemsNav" Style="{StaticResource Nav}" GroupName="Nav" IsChecked="True" Content="Items" Tag="&#xE7B8;"/><RadioButton x:Name="CommandsNav" Style="{StaticResource Nav}" GroupName="Nav" Content="Commands" Tag="&#xE756;"/><RadioButton x:Name="FavoritesNav" Style="{StaticResource Nav}" GroupName="Nav" Content="Favorites" Tag="&#xE734;"/><RadioButton x:Name="HistoryNav" Style="{StaticResource Nav}" GroupName="Nav" Content="History" Tag="&#xE81C;"/><RadioButton x:Name="SettingsNav" Style="{StaticResource Nav}" GroupName="Nav" Content="Settings" Tag="&#xE713;"/><RadioButton x:Name="HelpNav" Style="{StaticResource Nav}" GroupName="Nav" Content="Help" Tag="&#xE897;"/></UniformGrid></Border>
 </Grid>
</Window>
'@
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$names=@('SearchBox','SearchHint','CategoryBox','QuickCommandBox','ExportButton','RepairIconsButton','UpdateButton','ItemGrid','StatusText','PreviewImage','PreviewName','PreviewId','PreviewCategory','PageText','DescriptionText','OpenPageButton','FavoriteButton','GiveTile','SpawnTile','XpTile','PlayerTile','TeleportTile','ServerTile','OtherTile','CommandHelp','SubcommandPanel','PlayerField','PlayerBox','AmountField','AmountBox','PalField','PalBox','ValueField','ValueLabel','ValueBox','MaxStackBox','SilentBox','GeneratedBox','SmallCopyButton','CopyButton','ItemsNav','CommandsNav','FavoritesNav','HistoryNav','SettingsNav','HelpNav')
$ui=@{}; foreach($n in $names){$ui[$n]=$window.FindName($n)}
$records = @(Read-Database)
$databaseReady = ($records.Count -ge 450)

$activeGroup='Give Item'; $activeSub='Give to yourself'; $viewMode='Items'; $favorites=@(Read-Favorites)

function RefreshGrid {
    $term = $ui.SearchBox.Text.Trim().ToLowerInvariant()
    $cat = [string]$ui.CategoryBox.SelectedItem

    $sourceRecords = switch ($script:viewMode) {
        'Favorites' {
            @($records | Where-Object { $script:favorites -contains $_.id })
        }
        default {
            $records
        }
    }

    $filtered = @(
        $sourceRecords | Where-Object {
            ($cat -eq 'All Categories' -or $_.category -eq $cat) -and
            (
                -not $term -or
                (($_.name,$_.id,$_.category,$_.command,$_.description) -join ' ').
                    ToLowerInvariant().Contains($term)
            )
        }
    )

    $ui.ItemGrid.ItemsSource = $filtered

    if ($records.Count -lt 450) {
        $ui.StatusText.Text = 'No verified full database is installed. Click Update Database or use Update-and-Open.'
    }
    elseif ($script:viewMode -eq 'Favorites') {
        $ui.StatusText.Text = "Showing $($filtered.Count) favorite items"
    }
    else {
        $availableIconCount = @(
            $records | Where-Object {
                $_.IconPath -and (Test-Path $_.IconPath)
            }
        ).Count

        $ui.StatusText.Text = (
            "Showing {0} of {1} verified Paldeck Asset IDs | {2} icon files available" -f
            $filtered.Count,
            $records.Count,
            $availableIconCount
        )
    }

    $ui.SearchHint.Visibility = if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
}

function SelectedItem{return $ui.ItemGrid.SelectedItem}
function ShowSelected {
    $r = SelectedItem

    if (-not $r) {
        $ui.PreviewImage.Source = $null
        $ui.PreviewName.Text = 'Select an item'
        $ui.PreviewId.Text = ''
        $ui.PreviewCategory.Text = ''
        $ui.DescriptionText.Text = ''
        $ui.FavoriteButton.IsEnabled = $false
        return
    }

    $ui.FavoriteButton.IsEnabled = $true
    $ui.PreviewName.Text = $r.name
    $ui.PreviewId.Text = $r.id
    $ui.PreviewCategory.Text = $r.category
    $ui.DescriptionText.Text = if ($r.description) {
        $r.description
    }
    else {
        'No description is available in the current Paldeck snapshot.'
    }

    $ui.FavoriteButton.Content = if ($script:favorites -contains $r.id) {
        'Remove Favorite'
    }
    else {
        'Add Favorite'
    }

    # Use the exact same URI as the thumbnail shown beside the item name.
    # This keeps the list and detail preview synchronized.
    if ($r.ThumbnailUri) {
        $ui.PreviewImage.Source = $r.ThumbnailUri
    }
    else {
        $ui.PreviewImage.Source = [Uri]::new(
            $FallbackIcon,
            [UriKind]::Absolute
        )
    }

    UpdateCommand
}


function SetFields {
    param([Parameter(Mandatory)][string]$Subcommand)

    # Reset every dynamic field before enabling the controls required by the
    # selected Admin Command template.
    $ui.PlayerField.Visibility = 'Collapsed'
    $ui.AmountField.Visibility = 'Collapsed'
    $ui.PalField.Visibility = 'Collapsed'
    $ui.ValueField.Visibility = 'Collapsed'
    $ui.MaxStackBox.Visibility = 'Collapsed'
    $ui.SilentBox.Visibility = 'Visible'

    $ui.ValueLabel.Text = 'Value'
    $ui.ValueBox.IsReadOnly = $false

    switch ($Subcommand) {
        'Give to yourself' {
            $ui.AmountField.Visibility = 'Visible'
            $ui.MaxStackBox.Visibility = 'Visible'
        }

        'Give to another player' {
            $ui.PlayerField.Visibility = 'Visible'
            $ui.AmountField.Visibility = 'Visible'
            $ui.MaxStackBox.Visibility = 'Visible'
        }

        'Spawn Pal' {
            $ui.PalField.Visibility = 'Visible'
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Pal level'
            if (-not $ui.ValueBox.Text) { $ui.ValueBox.Text = '50' }
        }

        'Capture Pal' {
            $ui.PalField.Visibility = 'Visible'
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Pal level'
            if (-not $ui.ValueBox.Text) { $ui.ValueBox.Text = '50' }
        }

        'Give yourself XP' {
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Experience amount'
            if (-not $ui.ValueBox.Text) { $ui.ValueBox.Text = '10000' }
        }

        'Give player XP' {
            $ui.PlayerField.Visibility = 'Visible'
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Experience amount'
            if (-not $ui.ValueBox.Text) { $ui.ValueBox.Text = '10000' }
        }

        'Kick Player' {
            $ui.PlayerField.Visibility = 'Visible'
        }

        'Ban Player' {
            $ui.PlayerField.Visibility = 'Visible'
        }

        'Unban Player' {
            $ui.PlayerField.Visibility = 'Visible'
        }

        'Slay Player' {
            $ui.PlayerField.Visibility = 'Visible'
        }

        'Freeze Player' {
            $ui.PlayerField.Visibility = 'Visible'
        }

        'Unfreeze Player' {
            $ui.PlayerField.Visibility = 'Visible'
        }

        'Teleport to Coordinates' {
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Coordinates (x,y,z)'
            if (-not $ui.ValueBox.Text) { $ui.ValueBox.Text = '0,0,0' }
        }

        'Get Position' {
            $ui.SilentBox.Visibility = 'Collapsed'
        }

        'Unstuck' {
            $ui.SilentBox.Visibility = 'Collapsed'
        }

        'Announce' {
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Announcement message'
            if ($ui.ValueBox.Text -match '^(50|10000|0,0,0|12|enable)$') {
                $ui.ValueBox.Text = ''
            }
        }

        'Set Time' {
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Hour (0-23)'
            if (-not $ui.ValueBox.Text -or $ui.ValueBox.Text -notmatch '^\d{1,2}$') {
                $ui.ValueBox.Text = '12'
            }
        }

        'Show Time' {
            $ui.SilentBox.Visibility = 'Collapsed'
        }

        'Fly' {
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'State (enable/disable)'
            if ($ui.ValueBox.Text -notin @('enable','disable')) {
                $ui.ValueBox.Text = 'enable'
            }
        }

        'Spectate' {
            $ui.SilentBox.Visibility = 'Collapsed'
        }

        'Help' {
            $ui.SilentBox.Visibility = 'Collapsed'
        }

        'Custom Command' {
            $ui.ValueField.Visibility = 'Visible'
            $ui.ValueLabel.Text = 'Custom command'
            if (-not $ui.ValueBox.Text -or $ui.ValueBox.Text -match '^(50|10000|0,0,0|12|enable)$') {
                $ui.ValueBox.Text = '!'
            }
            $ui.SilentBox.Visibility = 'Collapsed'
        }
    }
}

function Test-CommandBuilderFunctions {
    $requiredFunctions = @(
        'SetFields',
        'BuildSubcommands',
        'UpdateCommand'
    )

    $missing = @(
        $requiredFunctions | Where-Object {
            -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue)
        }
    )

    if ($missing.Count -gt 0) {
        throw "Required command-builder function(s) are missing: $($missing -join ', ')"
    }
}

function BuildSubcommands([string]$group){
 $script:activeGroup=$group;$ui.SubcommandPanel.Children.Clear();$def=$commandDefinitions[$group];$ui.CommandHelp.Text=$def.Help
 foreach($sub in $def.Types){$rb=New-Object Windows.Controls.RadioButton;$rb.Content=$sub;$rb.GroupName='Subcommands';$rb.Foreground='#F2F6FC';$rb.Margin='0,0,18,7';$rb.IsChecked=($sub -eq $def.Types[0]);$rb.Add_Checked({$script:activeSub=[string]$this.Content;SetFields -Subcommand $script:activeSub;UpdateCommand});$ui.SubcommandPanel.Children.Add($rb)|Out-Null}
 $script:activeSub=$def.Types[0];SetFields -Subcommand $script:activeSub;UpdateCommand
}
function UpdateCommand {
    $r = SelectedItem

    $id = if ($r) {
        [string]$r.id
    }
    else {
        '<ItemAsset>'
    }

    $amount = if ($ui.MaxStackBox.IsChecked) {
        '9999'
    }
    elseif ($ui.AmountBox.Text) {
        [string]$ui.AmountBox.Text
    }
    else {
        '1'
    }

    $player = if ($ui.PlayerBox.Text) {
        [string]$ui.PlayerBox.Text
    }
    else {
        '<PlayerName>'
    }

    $pal = if ($ui.PalBox.Text) {
        [string]$ui.PalBox.Text
    }
    else {
        '<PalAsset>'
    }

    $value = if ($ui.ValueBox.Text) {
        [string]$ui.ValueBox.Text
    }
    else {
        '<Value>'
    }

    $cmd = switch ($script:activeSub) {
        'Give to yourself' {
            '!giveme {0}:{1}' -f $id,$amount
        }

        'Give to another player' {
            '!give {0} {1}:{2}' -f $player,$id,$amount
        }

        'Spawn Pal' {
            '!spawn {0} {1} false false false' -f $pal,$value
        }

        'Capture Pal' {
            '!capture {0} {1} false' -f $pal,$value
        }

        'Give yourself XP' {
            '!giveexp {0}' -f $value
        }

        'Give player XP' {
            '!exp {0} {1}' -f $player,$value
        }

        'Kick Player' {
            '!kick {0}' -f $player
        }

        'Ban Player' {
            '!ban {0}' -f $player
        }

        'Unban Player' {
            '!unban {0}' -f $player
        }

        'Slay Player' {
            '!slay {0}' -f $player
        }

        'Freeze Player' {
            '!freeze {0}' -f $player
        }

        'Unfreeze Player' {
            '!unfreeze {0}' -f $player
        }

        'Teleport to Coordinates' {
            '!goto {0}' -f $value
        }

        'Get Position' {
            '!getpos'
        }

        'Unstuck' {
            '!unstuck'
        }

        'Announce' {
            '!announce {0}' -f $value
        }

        'Set Time' {
            '!settime {0}' -f $value
        }

        'Show Time' {
            '!time'
        }

        'Fly' {
            '!fly {0}' -f $value
        }

        'Spectate' {
            '!spectate'
        }

        'Help' {
            '!help'
        }

        'Custom Command' {
            $value
        }

        default {
            ''
        }
    }

    if ($ui.SilentBox.IsChecked -and $cmd) {
        $cmd = "$cmd silent"
    }

    $ui.GeneratedBox.Text = ([string]$cmd).Trim()
}

function Select-AegisSubcommand {
    param(
        [Parameter(Mandatory)]
        [string]$Group,

        [Parameter(Mandatory)]
        [string]$Subcommand
    )

    BuildSubcommands $Group

    foreach ($control in $ui.SubcommandPanel.Children) {
        if ($control -is [Windows.Controls.RadioButton] -and
            [string]$control.Content -eq $Subcommand) {
            $control.IsChecked = $true
            return
        }
    }

    # Safe fallback if the requested option is not present.
    $script:activeSub = $Subcommand
    SetFields -Subcommand $script:activeSub
    UpdateCommand
}

$ui.CategoryBox.Items.Add('All Categories')|Out-Null;$records.category|Where-Object{$_}|Sort-Object -Unique|ForEach-Object{$ui.CategoryBox.Items.Add($_)|Out-Null};$ui.CategoryBox.SelectedIndex=0
@('Give Yourself Items','Give Player Items','Spawn Pal','Capture Pal','Give XP','Player','Teleport','Server','Other')|ForEach-Object{$ui.QuickCommandBox.Items.Add($_)|Out-Null};$ui.QuickCommandBox.SelectedIndex=0
$ui.SearchBox.Add_TextChanged({RefreshGrid});$ui.CategoryBox.Add_SelectionChanged({RefreshGrid});$ui.ItemGrid.Add_SelectionChanged({ShowSelected})
$tileMap=@{'GiveTile'='Give Item';'SpawnTile'='Spawn Pal';'XpTile'='Give XP';'PlayerTile'='Player';'TeleportTile'='Teleport';'ServerTile'='Server';'OtherTile'='Other'};foreach($k in $tileMap.Keys){$group=$tileMap[$k];$ui[$k].Add_Checked({param($s,$e) BuildSubcommands ([string]$s.Content)})}
foreach($c in @('PlayerBox','AmountBox','PalBox','ValueBox')){$ui[$c].Add_TextChanged({UpdateCommand})};$ui.MaxStackBox.Add_Checked({UpdateCommand});$ui.MaxStackBox.Add_Unchecked({UpdateCommand});$ui.SilentBox.Add_Checked({UpdateCommand});$ui.SilentBox.Add_Unchecked({UpdateCommand})

function Set-AegisClipboardText {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [int]$RetryCount = 12,
        [int]$RetryDelayMilliseconds = 125
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
        catch [System.Runtime.InteropServices.COMException] {
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
                continue
            }
        }
        catch {
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
                continue
            }
        }
    }

    return $false
}

$copyAction={
    UpdateCommand

    $commandText = [string]$ui.GeneratedBox.Text
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        $ui.StatusText.Text = 'There is no generated command to copy.'
        return
    }

    if (Set-AegisClipboardText -Text $commandText) {
        Add-CommandHistory $commandText
        $ui.StatusText.Text = 'Command copied to clipboard.'
    }
    else {
        $ui.StatusText.Text = 'Clipboard is currently busy. Please try Copy Command again.'
        [Windows.MessageBox]::Show(
            "Windows could not open the clipboard because another application is using it.`r`n`r`n" +
            "The Suite is still running. Close any clipboard manager, Remote Desktop clipboard process, " +
            "or application actively copying data, and then click Copy Command again.",
            'Aegis Palworld Suite - Clipboard Busy',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Warning
        ) | Out-Null
    }
}
$ui.CopyButton.Add_Click($copyAction)
$ui.SmallCopyButton.Add_Click($copyAction)
$ui.ItemGrid.Add_MouseDoubleClick($copyAction)
$ui.OpenPageButton.Add_Click({$r=SelectedItem;if($r.page){Start-Process $r.page}});$ui.FavoriteButton.Add_Click({
    $r = SelectedItem
    if (-not $r) { return }

    if ($script:favorites -contains $r.id) {
        $script:favorites = @($script:favorites | Where-Object { $_ -ne $r.id })
        $ui.StatusText.Text = "$($r.name) removed from Favorites."
    }
    else {
        $script:favorites = @($script:favorites + $r.id | Sort-Object -Unique)
        $ui.StatusText.Text = "$($r.name) added to Favorites."
    }

    Save-Favorites $script:favorites
    ShowSelected
    if ($script:viewMode -eq 'Favorites') { RefreshGrid }
});$ui.PageText.Add_MouseLeftButtonUp({$r=SelectedItem;if($r.page){Start-Process $r.page}})
$ui.ExportButton.Add_Click({$d=New-Object Microsoft.Win32.SaveFileDialog;$d.Filter='CSV (*.csv)|*.csv|JSON (*.json)|*.json|Text (*.txt)|*.txt';$d.FileName='Aegis-Palworld-Items.csv';if($d.ShowDialog()){switch([IO.Path]::GetExtension($d.FileName)){'.json'{$ui.ItemGrid.ItemsSource|ConvertTo-Json -Depth 5|Set-Content $d.FileName -Encoding UTF8};'.txt'{$ui.ItemGrid.ItemsSource.command|Set-Content $d.FileName -Encoding UTF8};default{$ui.ItemGrid.ItemsSource|Select-Object name,id,category,command,page|Export-Csv $d.FileName -NoTypeInformation -Encoding UTF8}}}})
$ui.RepairIconsButton.Add_Click({ Invoke-IconRepair })
$ui.UpdateButton.Add_Click({ Invoke-DatabaseUpdate })
$ui.QuickCommandBox.Add_SelectionChanged({
    switch ([string]$ui.QuickCommandBox.SelectedItem) {
        'Give Yourself Items' {
            $ui.GiveTile.IsChecked = $true
            Select-AegisSubcommand -Group 'Give Item' -Subcommand 'Give to yourself'
        }

        'Give Player Items' {
            $ui.GiveTile.IsChecked = $true
            Select-AegisSubcommand -Group 'Give Item' -Subcommand 'Give to another player'
        }

        'Spawn Pal' {
            $ui.SpawnTile.IsChecked = $true
            Select-AegisSubcommand -Group 'Spawn Pal' -Subcommand 'Spawn Pal'
        }

        'Capture Pal' {
            $ui.SpawnTile.IsChecked = $true
            Select-AegisSubcommand -Group 'Spawn Pal' -Subcommand 'Capture Pal'
        }

        'Give XP' {
            $ui.XpTile.IsChecked = $true
            Select-AegisSubcommand -Group 'Give XP' -Subcommand 'Give yourself XP'
        }

        'Player' {
            $ui.PlayerTile.IsChecked = $true
        }

        'Teleport' {
            $ui.TeleportTile.IsChecked = $true
        }

        'Server' {
            $ui.ServerTile.IsChecked = $true
        }

        'Other' {
            $ui.OtherTile.IsChecked = $true
        }
    }
})
$ui.ItemsNav.Add_Checked({
    $script:viewMode = 'Items'
    RefreshGrid
})

$ui.CommandsNav.Add_Checked({
    $script:viewMode = 'Items'
    RefreshGrid
    $ui.GiveTile.Focus() | Out-Null
    $ui.StatusText.Text = 'Admin Command Builder is ready.'
})

$ui.FavoritesNav.Add_Checked({
    $script:viewMode = 'Favorites'
    $script:favorites = @(Read-Favorites)
    RefreshGrid
})

$ui.HistoryNav.Add_Checked({
    $historyText = if (Test-Path $HistoryFile) {
        (Get-Content $HistoryFile -Tail 200) -join [Environment]::NewLine
    }
    else {
        'No commands have been copied yet.'
    }

    $historyWindow = New-Object Windows.Window
    $historyWindow.Title = 'Aegis Command History'
    $historyWindow.Width = 900
    $historyWindow.Height = 560
    $historyWindow.WindowStartupLocation = 'CenterOwner'
    $historyWindow.Owner = $window
    $historyWindow.Background = '#071321'

    $historyBox = New-Object Windows.Controls.TextBox
    $historyBox.Text = $historyText
    $historyBox.IsReadOnly = $true
    $historyBox.AcceptsReturn = $true
    $historyBox.VerticalScrollBarVisibility = 'Auto'
    $historyBox.HorizontalScrollBarVisibility = 'Auto'
    $historyBox.FontFamily = 'Consolas'
    $historyBox.FontSize = 13
    $historyBox.Margin = 14
    $historyBox.Background = '#091A2B'
    $historyBox.Foreground = '#EAF2FF'
    $historyWindow.Content = $historyBox
    $historyWindow.ShowDialog() | Out-Null
    $ui.ItemsNav.IsChecked = $true
})

$ui.SettingsNav.Add_Checked({
    $message = @"
Aegis Palworld Suite 2.3.4

Database:
$DataFile

Database Engine:
$Updater

Icons:
$(Join-Path $Root 'Icons')

Verified records:
$($records.Count)

Favorites:
$($favorites.Count)
"@
    [Windows.MessageBox]::Show(
        $message,
        'Aegis Settings and Database Information'
    ) | Out-Null
    $ui.ItemsNav.IsChecked = $true
})

$ui.HelpNav.Add_Checked({
    [Windows.MessageBox]::Show(
        "Search or filter items, select an item, choose an Admin Command category, complete its parameters, and click Copy Command.`r`n`r`nDouble-clicking an item also copies the generated command.`r`n`r`nUse Update Database to refresh the verified Paldeck snapshot.",
        'Aegis Palworld Suite Help'
    ) | Out-Null
    $ui.ItemsNav.IsChecked = $true
})

try {
    Test-CommandBuilderFunctions
    RefreshGrid
    BuildSubcommands 'Give Item'

    if ($ui.ItemGrid.Items.Count -gt 0) {
        $ui.ItemGrid.SelectedIndex = 0
    }

    $window.ShowDialog() | Out-Null
}
catch {
    $startupLog = Join-Path $Root 'Logs\Suite-Startup-Error.txt'
    New-Item -ItemType Directory -Path (Split-Path $startupLog -Parent) -Force | Out-Null

    $details = @(
        "Aegis Palworld Suite startup error",
        "===================================",
        "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Message: $($_.Exception.Message)",
        "",
        "Script stack:",
        $_.ScriptStackTrace,
        "",
        "Full error:",
        ($_ | Out-String)
    )

    [IO.File]::WriteAllLines(
        $startupLog,
        $details,
        [Text.UTF8Encoding]::new($false)
    )

    [Windows.MessageBox]::Show(
        "Aegis Palworld Suite could not open.`r`n`r`n$($_.Exception.Message)`r`n`r`nA diagnostic log was created at:`r`n$startupLog",
        'Aegis Palworld Suite Startup Error'
    ) | Out-Null
    exit 1
}
