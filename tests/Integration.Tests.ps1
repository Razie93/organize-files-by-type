param([string]$Case = '*')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$project = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $project 'OrganizeFilesByType.ps1'
# Never use the system temp directory: all fixtures stay in Hermes scratch.
$scratch = if ($env:ORG_TEST_TEMP) { $env:ORG_TEST_TEMP } else { Join-Path $env:LOCALAPPDATA 'hermes\cache\scratch' }
$base = Join-Path $scratch ('organizer-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($base) | Out-Null
$script:passed = 0; $script:failed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
function Fixture { $p = Join-Path $base ([guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($p) | Out-Null; return $p }
function Put([string]$Path, [string]$Text = 'original') { [IO.File]::WriteAllText($Path, $Text) }
function Run([string]$Root, [string[]]$Options = @()) {
    $text = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath -Path $Root -Auto @Options 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}
function Run-Batch([string]$Bat, [string]$Root, [string]$Flags) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /v:off /s /c ""{0}" "{1}" {2}"' -f $Bat, $Root, $Flags
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $text = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $result = [pscustomobject]@{ Code = $process.ExitCode; Text = $text }; $process.Dispose(); return $result
}
function Journal([string]$Root, [string]$Original, [string]$New, [string]$Category = 'Documents', [string]$Hash = ('0' * 64)) {
    $log = Join-Path $Root '.organize-files-log-202601010000000000000-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.csv'
    [pscustomobject]@{ Version = '1'; OriginalPath = $Original; NewPath = $New; Category = $Category; Sha256 = $Hash } | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
    return $log
}
function Test([string]$Name, [scriptblock]$Body) {
    if ($Name -notlike $Case) { return }
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $_" }
}
try {
    Test 'organize and undo real files' {
        Assert (Test-Path -LiteralPath $scriptPath -PathType Leaf) 'PowerShell entrypoint is missing'
        $r = Fixture; Put (Join-Path $r 'sample.txt')
        $result = Run $r
        Assert ($result.Code -eq 0) $result.Text
        Assert (Test-Path -LiteralPath (Join-Path $r 'Documents\sample.txt')) 'file was not organized'
        $result = Run $r @('-Undo')
        Assert ($result.Code -eq 0) $result.Text
        Assert ([IO.File]::ReadAllText((Join-Path $r 'sample.txt')) -eq 'original') 'undo did not restore bytes'
    }
    Test 'reject untrusted undo paths before any move' {
        foreach ($variant in @('outside-original', 'outside-new', 'traversal', 'nested-original', 'nested-new', 'unknown-category', 'directory-source', 'directory-original', 'ads', 'relative')) {
            $r = Fixture; $outside = Fixture
            [IO.Directory]::CreateDirectory((Join-Path $r 'Documents')) | Out-Null
            $o = Join-Path $r 'a.txt'; $n = Join-Path $r 'Documents\a.txt'; $c = 'Documents'
            Put $n; Put (Join-Path $outside 'a.txt')
            switch ($variant) {
                'outside-original' { $o = Join-Path $outside 'restored.txt' }
                'outside-new' { $n = Join-Path $outside 'a.txt' }
                'traversal' { $o = Join-Path $r 'Documents\..\a.txt' }
                'nested-original' { $o = Join-Path $r 'nested\a.txt' }
                'nested-new' { $n = Join-Path $r 'Documents\nested\a.txt' }
                'unknown-category' { $c = 'evil' }
                'directory-source' { Remove-Item -LiteralPath $n; [IO.Directory]::CreateDirectory($n) | Out-Null }
                'directory-original' { [IO.Directory]::CreateDirectory($o) | Out-Null }
                'ads' { $o += ':stream' }
                'relative' { $o = 'a.txt' }
            }
            $log = Journal $r $o $n $c
            $before = @(Get-ChildItem -LiteralPath $r -Recurse -Force | Select-Object -ExpandProperty FullName) -join "`n"
            $result = Run $r @('-Undo')
            Assert ($result.Code -ne 0) "accepted $variant : $($result.Text)"
            Assert (Test-Path -LiteralPath $log) "journal completed for $variant"
            $after = @(Get-ChildItem -LiteralPath $r -Recurse -Force | Select-Object -ExpandProperty FullName) -join "`n"
            Assert ($before -eq $after) "tree changed for $variant"
            Assert ([IO.File]::ReadAllText((Join-Path $outside 'a.txt')) -eq 'original') 'outside file changed'
        }
    }
    Test 'write-ahead journal survives blocked first move' {
        $r = Fixture; $o = Join-Path $r 'locked.txt'; Put $o
        $handle = [IO.File]::Open($o, 'Open', 'Read', 'Read')
        try { $result = Run $r } finally { $handle.Dispose() }
        Assert ($result.Code -ne 0) 'locked file unexpectedly moved'
        $logs = @(Get-ChildItem -LiteralPath $r -Filter '.organize-files-log-*.csv' -File)
        Assert ($logs.Count -eq 1) 'durable intent journal missing after failed move'
        $rows = @(Import-Csv -LiteralPath $logs[0].FullName)
        Assert ($rows.Count -eq 1 -and $rows[0].OriginalPath -eq $o) 'intent missing source'
        Assert ($rows[0].Sha256 -eq (Get-FileHash -LiteralPath $o).Hash) 'intent missing source hash'
    }
    Test 'undo refuses changed content and retries partial work' {
        $r = Fixture; Put (Join-Path $r 'a.txt'); Put (Join-Path $r 'b.txt')
        Assert ((Run $r).Code -eq 0) 'organize failed'
        Put (Join-Path $r 'Documents\a.txt') 'changed'
        $result = Run $r @('-Undo')
        Assert ($result.Code -eq 2) "expected partial exit 2: $($result.Text)"
        Assert (Test-Path -LiteralPath (Join-Path $r 'b.txt')) 'independent row not restored'
        Assert (-not (Test-Path -LiteralPath (Join-Path $r 'a.txt'))) 'changed file restored'
        Assert (@(Get-ChildItem -LiteralPath $r -Filter '*.undone.csv').Count -eq 0) 'partial journal marked done'
        Put (Join-Path $r 'Documents\a.txt')
        Assert ((Run $r @('-Undo')).Code -eq 0) 'retry failed'
        Assert (@(Get-ChildItem -LiteralPath $r -Filter '*.undone.csv').Count -eq 1) 'completed retry not marked'
    }
    Test 'block recognizable projects and applications' {
        foreach ($marker in @('.git', 'package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'app.sln', 'app.csproj', 'app.exe', 'engine.dll', 'node_modules', '.venv')) {
            $r = Fixture; Put (Join-Path $r 'keep.txt')
            if ($marker -in @('.git', 'node_modules', '.venv')) { [IO.Directory]::CreateDirectory((Join-Path $r $marker)) | Out-Null }
            else { Put (Join-Path $r $marker) }
            $result = Run $r
            Assert ($result.Code -eq 1) "did not block $marker : $($result.Text)"
            Assert (Test-Path -LiteralPath (Join-Path $r 'keep.txt')) "moved file beside $marker"
            Assert ($result.Text -like '*project*' -or $result.Text -like '*application*') "missing safety explanation for $marker"
        }
        $r = Fixture; Put (Join-Path $r 'package.json'); $nested = Join-Path $r 'assets'; [IO.Directory]::CreateDirectory($nested) | Out-Null; Put (Join-Path $nested 'a.txt')
        Assert ((Run $nested).Code -eq 1) 'project descendant not blocked'
    }
    Test 'reject malformed and ambiguous journals atomically' {
        foreach ($kind in @('empty', 'duplicate', 'extra-column', 'old-format', 'reserved-source', 'duplicate-new')) {
            $r = Fixture; [IO.Directory]::CreateDirectory((Join-Path $r 'Documents')) | Out-Null
            $n = Join-Path $r 'Documents\a.txt'; Put $n
            $hash = (Get-FileHash -LiteralPath $n).Hash
            $log = Journal $r (Join-Path $r 'a.txt') $n 'Documents' $hash
            switch ($kind) {
                'empty' { Put $log '"Version","OriginalPath","NewPath","Category","Sha256"' }
                'duplicate' { $rows = @(Import-Csv -LiteralPath $log); @($rows[0], $rows[0]) | Export-Csv -LiteralPath $log -NoTypeInformation }
                'duplicate-new' { $rows = @(Import-Csv -LiteralPath $log); $second = $rows[0].PSObject.Copy(); $second.OriginalPath = Join-Path $r 'b.txt'; @($rows[0], $second) | Export-Csv -LiteralPath $log -NoTypeInformation }
                'extra-column' { Import-Csv -LiteralPath $log | Select-Object *, @{ n = 'Unexpected'; e = { 'value' } } | Export-Csv -LiteralPath ($log + '.tmp') -NoTypeInformation; [IO.File]::Delete($log); [IO.File]::Move(($log + '.tmp'), $log) }
                'old-format' { [pscustomobject]@{ OriginalPath = (Join-Path $r 'a.txt'); NewPath = $n; Category = 'Documents' } | Export-Csv -LiteralPath $log -NoTypeInformation }
                'reserved-source' { $log = Journal $r (Join-Path $r '.organize-files-lock') $n 'No extension' $hash }
            }
            $result = Run $r @('-Undo')
            Assert ($result.Code -eq 1) "accepted $kind : $($result.Text)"
            Assert (Test-Path -LiteralPath $n) "moved a file from invalid $kind journal"
            Assert (Test-Path -LiteralPath $log) "completed invalid $kind journal"
        }
    }
    Test 'preview is read only and collisions get unique names' {
        $r = Fixture; Put (Join-Path $r 'a[1],100%.txt'); Put (Join-Path $r 'unknown.wibble'); Put (Join-Path $r 'README')
        [IO.Directory]::CreateDirectory((Join-Path $r 'Documents')) | Out-Null
        Put (Join-Path $r 'Documents\a[1],100%.txt') 'existing'
        $before = @(Get-ChildItem -LiteralPath $r -Force -Recurse | ForEach-Object { $_.FullName }) -join "`n"
        $result = Run $r @('-Preview', '-SkipOther')
        Assert ($result.Code -eq 0) $result.Text
        $after = @(Get-ChildItem -LiteralPath $r -Force -Recurse | ForEach-Object { $_.FullName }) -join "`n"
        Assert ($before -eq $after) 'preview modified filesystem'
        Assert ($result.Text -like '*a[[]1]*' -and $result.Text -like '*WARNING*') 'preview missing plan or warning'
        $result = Run $r @('-SkipOther')
        Assert ($result.Code -eq 0) $result.Text
        Assert ([IO.File]::ReadAllText((Join-Path $r 'Documents\a[1],100%.txt')) -eq 'existing') 'collision overwritten'
        Assert (Test-Path -LiteralPath (Join-Path $r 'Documents\a[1],100% (1).txt')) 'collision not renamed'
        Assert (Test-Path -LiteralPath (Join-Path $r 'unknown.wibble')) 'SkipOther ignored'
        Assert (Test-Path -LiteralPath (Join-Path $r 'No extension\README')) 'extensionless not categorized'
        Assert ((Run $r @('-Undo')).Code -eq 0) 'collision undo failed'
    }
    Test 'batch entrypoint supports legacy flags and clears inherited ORG state' {
        $bat = Join-Path $project 'OrganizeFilesByType.bat'
        Assert (Test-Path -LiteralPath $bat -PathType Leaf) 'batch entrypoint missing'
        $r = Join-Path (Fixture) 'spaces & bang! [box]'; [IO.Directory]::CreateDirectory($r) | Out-Null; Put (Join-Path $r 'a.txt')
        $env:ORG_PATH = Join-Path $r 'do-not-use'; $env:ORG_AUTO = '1'; $env:ORG_UNDO = '1'; $env:ORG_SKIPOTHER = '1'
        try {
            $output = Run-Batch $bat $r '/y'
            Assert ($output.Code -eq 0) $output.Text
            Assert (Test-Path -LiteralPath (Join-Path $r 'Documents\a.txt')) 'legacy /y failed or inherited undo used'
            $output = Run-Batch $bat $r '/undo /y'
            Assert ($output.Code -eq 0) $output.Text
            Assert (Test-Path -LiteralPath (Join-Path $r 'a.txt')) 'legacy undo failed'
        } finally { Remove-Item Env:ORG_PATH, Env:ORG_AUTO, Env:ORG_UNDO, Env:ORG_SKIPOTHER -ErrorAction SilentlyContinue }
        $text = [IO.File]::ReadAllText($bat)
        Assert ($text -notmatch '(?im)^\s*call\b|\biex\b|Invoke-Expression') 'batch contains CALL or expression evaluation'
    }
    Test 'active recovery blocks new organize runs' {
        $r = Fixture; Put (Join-Path $r 'a.txt'); Assert ((Run $r).Code -eq 0) 'organize failed'
        Put (Join-Path $r 'b.txt')
        $result = Run $r
        Assert ($result.Code -eq 1) 'new run allowed while recovery journal active'
        Assert (Test-Path -LiteralPath (Join-Path $r 'b.txt')) 'new file moved despite active recovery'
        Assert (@(Get-ChildItem -LiteralPath $r -Filter '.organize-files-log-*.csv').Count -eq 1) 'created competing journal'
    }
    Test 'exclusive lock blocks overlapping runs' {
        $r = Fixture; Put (Join-Path $r 'a.txt')
        $handle = [IO.File]::Open((Join-Path $r '.organize-files-lock'), 'CreateNew', 'ReadWrite', 'None')
        try {
            $result = Run $r
            Assert ($result.Code -eq 1) 'overlapping writer was allowed'
            Assert (Test-Path -LiteralPath (Join-Path $r 'a.txt')) 'overlapping writer moved file'
        } finally { $handle.Dispose() }
    }
    Test 'planned collisions cannot share a destination' {
        $r = Fixture; [IO.Directory]::CreateDirectory((Join-Path $r 'Documents')) | Out-Null
        Put (Join-Path $r 'Documents\a.txt') 'existing'; Put (Join-Path $r 'a.txt') 'first'; Put (Join-Path $r 'a (1).txt') 'second'
        $result = Run $r
        Assert ($result.Code -eq 0) $result.Text
        $rows = @(Import-Csv -LiteralPath @(Get-ChildItem -LiteralPath $r -Filter '.organize-files-log-*.csv')[0].FullName)
        Assert (@($rows.NewPath | Select-Object -Unique).Count -eq 2) 'plan contains duplicate destination'
        Assert ((Run $r @('-Undo')).Code -eq 0) 'planned collision recovery failed'
        Assert ([IO.File]::ReadAllText((Join-Path $r 'a.txt')) -eq 'first') 'first bytes changed'
        Assert ([IO.File]::ReadAllText((Join-Path $r 'a (1).txt')) -eq 'second') 'second bytes changed'
    }
    Test 'reparse points cannot redirect root category or undo' {
        foreach ($mode in @('root', 'category', 'undo-category', 'ancestor')) {
            $r = Fixture; $outside = Fixture; Put (Join-Path $outside 'sentinel.txt') 'outside'
            $junction = Join-Path $r 'junction'
            if ($mode -eq 'category' -or $mode -eq 'undo-category') { $junction = Join-Path $r 'Documents' }
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            try {
                switch ($mode) {
                    'root' { $target = $junction; $opts = @() }
                    'ancestor' { $target = Join-Path $junction 'nested'; [IO.Directory]::CreateDirectory($target) | Out-Null; Put (Join-Path $target 'a.txt'); $opts = @() }
                    'category' { $target = $r; Put (Join-Path $r 'a.txt'); $opts = @() }
                    'undo-category' { $target = $r; $opts = @('-Undo'); $null = Journal $r (Join-Path $r 'sentinel.txt') (Join-Path $junction 'sentinel.txt') 'Documents' ((Get-FileHash -LiteralPath (Join-Path $outside 'sentinel.txt')).Hash) }
                }
                $result = Run $target $opts
                Assert ($result.Code -eq 1) "accepted junction $mode : $($result.Text)"
                Assert ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -eq 'outside') 'outside content changed'
                Assert (-not (Test-Path -LiteralPath (Join-Path $r 'sentinel.txt'))) 'outside file restored through junction'
            } finally { [IO.Directory]::Delete($junction) }
        }
    }
    Test 'intent recovery distinguishes unmoved restored missing and occupied files' {
        foreach ($state in @('unmoved', 'restored', 'occupied', 'both-identical', 'missing', 'changed-original')) {
            $r = Fixture; [IO.Directory]::CreateDirectory((Join-Path $r 'Documents')) | Out-Null
            $o = Join-Path $r 'a.txt'; $n = Join-Path $r 'Documents\a.txt'; Put $o
            $log = Journal $r $o $n 'Documents' ((Get-FileHash -LiteralPath $o).Hash)
            switch ($state) {
                'occupied' { Put $n; Put $o 'new occupant' }
                'both-identical' { Put $n }
                'missing' { [IO.File]::Delete($o) }
                'changed-original' { Put $o 'changed' }
            }
            $result = Run $r @('-Undo')
            if ($state -in @('unmoved', 'restored')) {
                Assert ($result.Code -eq 0) $result.Text
                Assert ([IO.File]::ReadAllText($o) -eq 'original') 'unmoved source changed'
            } else {
                Assert ($result.Code -eq 2) "state $state not held for retry: $($result.Text)"
                Assert (Test-Path -LiteralPath $log) "state $state journal completed prematurely"
                if ($state -eq 'occupied') { Assert ([IO.File]::ReadAllText($o) -eq 'new occupant') 'original clobbered' }
                if ($state -eq 'both-identical') { Assert (Test-Path -LiteralPath $n) 'unmoved intent incorrectly restored existing destination' }
            }
        }
    }
    Test 'unicode literal filenames and hidden files round trip' {
        $r = Fixture
        $names = @(('file-' + [char]0x4e2d + [char]0x6587 + '.txt'), '=formula.txt', "quote'and,comma.txt", 'plus+at@.txt', '.hidden.txt')
        foreach ($name in $names) { Put (Join-Path $r $name) $name }
        (Get-Item -LiteralPath (Join-Path $r '.hidden.txt')).Attributes = [IO.FileAttributes]::Hidden
        $result = Run $r; Assert ($result.Code -eq 0) $result.Text
        $result = Run $r @('-Undo'); Assert ($result.Code -eq 0) $result.Text
        foreach ($name in $names) { Assert ([IO.File]::ReadAllText((Join-Path $r $name)) -eq $name) 'literal name or content changed' }
        Assert (((Get-Item -LiteralPath (Join-Path $r '.hidden.txt') -Force).Attributes -band [IO.FileAttributes]::Hidden) -ne 0) 'hidden attribute lost'
    }
    Test 'declining confirmation changes nothing' {
        $r = Fixture; Put (Join-Path $r 'a.txt')
        $text = 'NO' | & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Path $r 2>&1 | Out-String
        Assert ($LASTEXITCODE -eq 0) $text
        Assert (Test-Path -LiteralPath (Join-Path $r 'a.txt')) 'cancelled file moved'
        Assert (@(Get-ChildItem -LiteralPath $r -Force).Count -eq 1) 'cancel left artifacts'
    }
    Test 'killed process recovers moved and unmoved intents from durable journal' {
        $r = Fixture
        foreach ($i in 1..120) { Put (Join-Path $r ('item-{0:D3}.txt' -f $i)) ('bytes-' + $i) }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = (Join-Path $PSHOME 'powershell.exe')
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Path "{1}" -Auto' -f $scriptPath, $r
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(90)
            $dir = Join-Path $r 'Documents'
            while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                if ([IO.Directory]::Exists($dir) -and [IO.Directory]::GetFiles($dir).Length -gt 0) { $process.Kill(); break }
                Start-Sleep -Milliseconds 5
            }
            if (-not $process.HasExited) { $process.Kill() }
            $process.WaitForExit()
            $moved = @([IO.Directory]::GetFiles($dir)).Count
            Assert ($moved -gt 0 -and $moved -lt 120) "did not terminate mid-move; moved=$moved"
            $logs = @(Get-ChildItem -LiteralPath $r -Filter '.organize-files-log-*.csv' -File)
            Assert ($logs.Count -eq 1) 'crash lost journal'
            Assert (@(Import-Csv -LiteralPath $logs[0].FullName).Count -eq 120) 'durable plan incomplete at crash'
            $result = Run $r @('-Undo'); Assert ($result.Code -eq 0) $result.Text
            foreach ($i in 1..120) { Assert ([IO.File]::ReadAllText((Join-Path $r ('item-{0:D3}.txt' -f $i))) -eq ('bytes-' + $i)) "lost bytes after crash: $i" }
            Assert (-not (Test-Path -LiteralPath (Join-Path $r '.organize-files-lock'))) 'crash left stale lock'
        } finally { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
    }
    Test 'all categories preserve representative bytes' {
        $r = Fixture
        $samples = [ordered]@{ 'photo.PNG' = 'Pictures'; 'clip.mp4' = 'Video'; 'song.flac' = 'Audio'; 'paper.pdf' = 'Documents'; 'table.csv' = 'Spreadsheets'; 'slides.pptx' = 'Presentations'; 'values.json' = 'Data'; 'standalone.py' = 'Code'; 'bundle.zip' = 'Archives'; 'disk.iso' = 'DiskImages'; 'setup.msi' = 'Installers'; 'font.ttf' = 'Fonts'; 'design.psd' = 'Design'; 'model.stl' = 'CAD'; 'link.url' = 'Shortcuts'; 'mystery.wibble' = 'Other'; 'extensionless' = 'No extension' }
        foreach ($name in $samples.Keys) { Put (Join-Path $r $name) $name }
        $result = Run $r; Assert ($result.Code -eq 0) $result.Text
        foreach ($name in $samples.Keys) { Assert ([IO.File]::ReadAllText((Join-Path (Join-Path $r $samples[$name]) $name)) -eq $name) "wrong category: $name" }
        $result = Run $r @('-Undo'); Assert ($result.Code -eq 0) $result.Text
        foreach ($name in $samples.Keys) { Assert ([IO.File]::ReadAllText((Join-Path $r $name)) -eq $name) "wrong recovery: $name" }
    }
    Test 'protected roots files and organizer itself are refused' {
        $r = Fixture; $file = Join-Path $r 'a.txt'; Put $file
        foreach ($target in @($file, [IO.Path]::GetPathRoot($r), $project, $env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, $env:APPDATA, $env:LOCALAPPDATA)) {
            if (-not $target) { continue }
            $result = Run $target @('-Preview')
            Assert ($result.Code -eq 1) "protected target accepted: $($result.Text)"
        }
        Assert ([IO.File]::ReadAllText($file) -eq 'original') 'fixture file changed'
    }
}
finally { Remove-Item -LiteralPath $base -Recurse -Force }
Write-Host "RESULT: $script:passed passed; $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
