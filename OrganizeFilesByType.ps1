[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [switch]$Auto, [switch]$Undo, [switch]$SkipOther, [switch]$Preview,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LegacyOptions
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$categories = [ordered]@{
    Pictures = '.jpg .jpeg .png .gif .bmp .tif .tiff .webp .heic .heif .svg .ico .raw .cr2 .cr3 .nef .arw .dng .orf .rw2'
    Video = '.mp4 .mkv .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .3gp .mts .m2ts .vob'
    Audio = '.mp3 .wav .flac .aac .ogg .m4a .wma .aiff .opus .mid .midi'
    Documents = '.pdf .doc .docx .rtf .txt .odt .md .tex .epub .mobi .azw .azw3 .pages .log .wpd'
    Spreadsheets = '.xls .xlsx .xlsm .xlsb .csv .ods .numbers'
    Presentations = '.ppt .pptx .pps .ppsx .odp .key'
    Data = '.json .xml .yml .yaml .sql .db .sqlite .parquet .avro'
    Code = '.ps1 .psm1 .py .js .mjs .ts .jsx .tsx .html .htm .css .scss .sass .less .cs .java .c .cpp .h .hpp .go .rs .rb .php .sh .bat .cmd .ini .cfg .toml .reg .vbs'
    Archives = '.zip .rar .7z .tar .gz .tgz .bz2 .xz .cab .lz .zst'
    DiskImages = '.iso .img .vhd .vhdx .vmdk .dmg .bin .cue'
    Installers = '.exe .msi .msix .appx .pkg .deb .rpm .apk'
    Fonts = '.ttf .otf .woff .woff2 .fon .ttc'
    Design = '.psd .ai .indd .xd .fig .sketch .afdesign .afphoto .blend .xcf'
    CAD = '.dwg .dxf .stl .obj .fbx .step .stp .iges .igs'
    Shortcuts = '.lnk .url .webloc'
}
function Category([string]$Name) {
    $ext = [IO.Path]::GetExtension($Name).ToLowerInvariant()
    if (-not $ext) { return 'No extension' }
    foreach ($c in $categories.Keys) { if ($categories[$c].Split(' ') -contains $ext) { return $c } }
    return 'Other'
}
function Assert-PlainPath([string]$Value) {
    $p = $Value
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point refused: $p" }
        }
        $parent = [IO.Path]::GetDirectoryName($p)
        if ($parent -eq $p) { break }
        $p = $parent
    }
}
function Assert-Leaf([string]$Name) {
    if (-not $Name -or $Name -in @('.', '..') -or $Name -match '[\\/:*?"<>|\x00-\x1f]' -or $Name -match '[. ]$' -or $Name -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Unsafe filename in journal.' }
}
function Assert-Row($Row) {
    if ((@($Row.PSObject.Properties.Name) -join ',') -cne 'Version,OriginalPath,NewPath,Category,Sha256') { throw 'Unexpected journal schema; legacy journals are not accepted.' }
    if ([IO.Path]::GetFileName($Row.OriginalPath) -like '.organize-files-*' -or [IO.Path]::GetFileName($Row.NewPath) -like '.organize-files-*') { throw 'Reserved organizer filenames cannot be moved.' }
    if ($Row.Version -ne '1' -or $Row.Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unsupported or damaged journal.' }
    if (@($categories.Keys) + @('Other', 'No extension') -notcontains $Row.Category) { throw 'Unknown journal category.' }
    foreach ($p in @($Row.OriginalPath, $Row.NewPath)) {
        if ($p -notmatch '^[A-Za-z]:\\' -or $p -match '/' -or $p.Substring(2) -match ':') { throw 'Only canonical local absolute paths are accepted.' }
        foreach ($part in $p.Substring(3).Split('\')) { Assert-Leaf $part }
        if ([IO.Path]::GetFullPath($p) -cne $p) { throw 'Noncanonical journal path.' }
        Assert-PlainPath $p
        if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Expected a regular file: $p" }
    }
    if ([IO.Path]::GetDirectoryName($Row.OriginalPath) -ine $root) { throw 'Original must be an immediate root file.' }
    if ([IO.Path]::GetDirectoryName($Row.NewPath) -ine (Join-Path $root $Row.Category)) { throw 'Destination must be an immediate category file.' }
    if ((Category ([IO.Path]::GetFileName($Row.OriginalPath))) -ine $Row.Category) { throw 'Journal category does not match original extension.' }
    $dir = Join-Path $root $Row.Category
    if ((Test-Path -LiteralPath $dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'Category is not a directory.' }
}
function Assert-SafeRoot([string]$Folder) {
    if ($Folder -notmatch '^[A-Za-z]:\\' -or $Folder.TrimEnd('\') -eq [IO.Path]::GetPathRoot($Folder).TrimEnd('\')) { throw 'Refusing drive root, UNC or device path.' }
    Assert-PlainPath $Folder
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw 'Target must be a directory.' }
    foreach ($protected in @($env:WINDIR, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $PSScriptRoot)) {
        if ($protected -and ($Folder -ieq $protected.TrimEnd('\') -or $Folder.StartsWith($protected.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'Refusing protected system or organizer application folder.' }
    }
    foreach ($protected in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA)) {
        if ($protected -and $Folder -ieq $protected.TrimEnd('\')) { throw 'Refusing profile or application-data root.' }
    }
    $scan = $Folder
    while ($scan -and $scan.TrimEnd('\') -ne [IO.Path]::GetPathRoot($scan).TrimEnd('\')) {
        # A development environment in the profile root does not make every inbox a project.
        if ($scan -ine $Folder -and $scan -ieq $env:USERPROFILE) { break }
        $markers = @(Get-ChildItem -LiteralPath $scan -Force | Where-Object {
            $_.Name -in @('.git', '.hg', '.svn', 'package.json', 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Cargo.toml', 'go.mod', 'Gemfile', 'composer.json', 'pom.xml', 'build.gradle', 'CMakeLists.txt', 'Makefile', 'node_modules', '.venv', 'venv', '__pycache__', '.vs', '.idea', 'Dockerfile') -or
            $_.Name -match '\.(sln|slnx|[a-z]*proj)$' -or
            ($scan -ieq $Folder -and $_.Name -match '\.(exe|dll|deps\.json|runtimeconfig\.json)$')
        })
        if ($markers.Count) { throw "Recognizable project/application folder refused (marker: $($markers[0].Name)). Select a standalone sorting inbox, not a project or installed application." }
        $scan = [IO.Path]::GetDirectoryName($scan)
    }
}
function Confirm-Plan {
    if ($Preview) { Write-Host 'Preview only; no filesystem changes.'; return $false }
    if ($Auto) { return $true }
    return ((Read-Host 'Proceed? Type YES to continue') -ceq 'YES')
}
function Available-Path([string]$Directory, [string]$Name, [hashtable]$Reserved) {
    $candidate = Join-Path $Directory $Name
    for ($i = 1; ((Test-Path -LiteralPath $candidate) -or $Reserved.ContainsKey($candidate)); $i++) {
        if ($i -gt 9999) { throw 'No available collision-safe filename.' }
        $candidate = Join-Path $Directory ('{0} ({1}){2}' -f [IO.Path]::GetFileNameWithoutExtension($Name), $i, [IO.Path]::GetExtension($Name))
    }
    return $candidate
}
$lock = $null
try {
    if ($Path -like '/*') { $LegacyOptions = @($Path) + @($LegacyOptions); $Path = '' }
    foreach ($option in $LegacyOptions) {
        switch ($option.ToLowerInvariant()) {
            '/y' { $Auto = $true }
            '/yes' { $Auto = $true }
            '/undo' { $Undo = $true }
            '/u' { $Undo = $true }
            '/skipother' { $SkipOther = $true }
            '/preview' { $Preview = $true }
            { $_ -in @('/?', '/help') } { Write-Host 'Usage: OrganizeFilesByType.bat "folder" [/y] [/undo] [/skipother] [/preview]'; exit 0 }
            default { if (-not $Path -and $option -notlike '/*') { $Path = $option } else { throw "Unknown argument: $option" } }
        }
    }
    if (-not $Path) { $Path = Read-Host 'Folder to organize' }
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    Assert-SafeRoot $root
    $root = (Get-Item -LiteralPath $root -Force).FullName.TrimEnd('\')
    if (-not $Preview) {
        $lockPath = Join-Path $root '.organize-files-lock'
        Assert-PlainPath $lockPath
        $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    }
    $logs = @(Get-ChildItem -LiteralPath $root -Filter '.organize-files-log-*.csv' -File -Force | Where-Object { $_.Name -notlike '*.undone.csv' } | Sort-Object Name -Descending)
    if (-not $Undo -and $logs.Count) { throw 'Active recovery journal exists. Undo it or archive it outside this folder after accepting the changes.' }
    if ($Undo) {
        if (-not $logs.Count) { Write-Host 'No active journal.'; exit 0 }
        Assert-PlainPath $logs[0].FullName
        $rows = @(Import-Csv -LiteralPath $logs[0].FullName)
        if (-not $rows.Count) { throw 'Empty journal cannot be recovered automatically.' }
        $seenOriginal = @{}; $seenNew = @{}
        foreach ($row in $rows) {
            Assert-Row $row
            if ($seenOriginal.ContainsKey($row.OriginalPath) -or $seenNew.ContainsKey($row.NewPath)) { throw 'Duplicate journal paths are ambiguous.' }
            $seenOriginal[$row.OriginalPath] = $true; $seenNew[$row.NewPath] = $true
        }
        Write-Warning 'Undo restores only hash-matching files and never overwrites occupied originals. Back up before recovery.'
        foreach ($row in $rows) { Write-Host ($row.NewPath + ' -> ' + $row.OriginalPath) }
        if (-not (Confirm-Plan)) { exit 0 }
        $unresolved = 0; $restored = 0
        foreach ($row in $rows) {
            try {
                Assert-Row $row
                $originalExists = Test-Path -LiteralPath $row.OriginalPath
                $newExists = Test-Path -LiteralPath $row.NewPath
                if ($originalExists -and -not $newExists -and (Get-FileHash -LiteralPath $row.OriginalPath -Algorithm SHA256).Hash -eq $row.Sha256) {
                    # A durable intent can be unmoved, or already restored before a crash.
                    continue
                }
                if ($originalExists) { throw 'Original occupied; no file overwritten.' }
                if (-not $newExists) { throw 'Both paths missing; manual recovery required.' }
                if ((Get-FileHash -LiteralPath $row.NewPath -Algorithm SHA256).Hash -ne $row.Sha256) { throw 'Organized file changed; refusing to restore it.' }
                [IO.File]::Move($row.NewPath, $row.OriginalPath)
                $restored++
            }
            catch { $unresolved++; Write-Warning ($row.OriginalPath + ': ' + $_.Exception.Message) }
        }
        Write-Host "Restored $restored file(s); unresolved $unresolved."
        if ($unresolved) { Write-Host 'Journal remains active. Resolve conflicts, then retry -Undo.'; exit 2 }
        [IO.File]::Move($logs[0].FullName, ($logs[0].FullName -replace '\.csv$', '.undone.csv'))
        exit 0
    }
    $rows = @(); $reserved = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Force)) {
        if ($file.Name -like '.organize-files-*') { continue }
        $c = Category $file.Name
        if ($SkipOther -and $c -eq 'Other') { continue }
        $dest = Available-Path (Join-Path $root $c) $file.Name $reserved
        $reserved[$dest] = $true
        $row = [pscustomobject]@{ Version = '1'; OriginalPath = $file.FullName; NewPath = $dest; Category = $c; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        Assert-Row $row
        $rows += $row
    }
    if (-not $rows.Count) { Write-Host 'Nothing to move.'; exit 0 }
    Write-Warning 'Use a standalone sorting inbox only. Moving related files can break projects, applications and relative links. Back up first; detection is not exhaustive.'
    foreach ($row in $rows) { Write-Host ($row.OriginalPath + ' -> ' + $row.NewPath) }
    if (-not (Confirm-Plan)) { exit 0 }
    $log = Join-Path $root ('.organize-files-log-' + (Get-Date -Format 'yyyyMMddHHmmssfffffff') + '-' + [guid]::NewGuid().ToString('N') + '.csv')
    $pending = $log + '.pending'
    $bytes = (New-Object Text.UTF8Encoding($true)).GetBytes((($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n") + "`r`n")
    $stream = New-Object IO.FileStream($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($pending, $log)
    Write-Host "Journal: $log"
    foreach ($row in $rows) {
        Assert-Row $row
        if ((Get-FileHash -LiteralPath $row.OriginalPath -Algorithm SHA256).Hash -ne $row.Sha256) { throw 'Source changed after planning; journal retained.' }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($row.NewPath)) | Out-Null
        [IO.File]::Move($row.OriginalPath, $row.NewPath)
    }
    Write-Host "Moved $($rows.Count) file(s)."
    exit 0
}
catch { Write-Host ('ERROR: ' + $_.Exception.Message); exit 1 }
finally { if ($null -ne $lock) { $lock.Dispose() } }
