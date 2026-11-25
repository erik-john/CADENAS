# CADENAS NX File Organizer V3.2.13
# Metadata-driven organizer. Uses PartInfo metadata (NB + ProjectPath) to map
# flat Members .prt files to the exact CADENAS catalog component folder.
# Safe behavior: preview/log matching first; never overwrite; ambiguous matches are skipped.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$DefaultSource = Join-Path $env:LOCALAPPDATA 'CADENAS Library\Members\gb_standards'
$ConfigDir = Join-Path $env:USERPROFILE 'Documents\CADENAS_Organizer'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$LogPath = Join-Path $ConfigDir 'Organizer_Log.txt'
if (-not (Test-Path -LiteralPath $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}
$config = @{ Source = $DefaultSource; Target = '' }
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($loaded.Source) { $config.Source = [string]$loaded.Source }
        if ($loaded.Target) { $config.Target = [string]$loaded.Target }
    } catch { }
}

function Save-Config {
    @{ Source = $sourceText.Text.Trim(); Target = $targetText.Text.Trim() } |
        ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}
function Write-Log {
    param([string]$Message, [string]$Color = 'Black')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.SelectionLength = 0
    $script:LogBox.SelectionColor = [System.Drawing.Color]::FromName($Color)
    $script:LogBox.AppendText($line + [Environment]::NewLine)
    $script:LogBox.SelectionColor = $script:LogBox.ForeColor
    Add-Content -LiteralPath $LogPath -Value $line
    [System.Windows.Forms.Application]::DoEvents()
}
# CADENAS may suffix split component files with either _PART1/_PART2 or -1/-2.
# Strip either suffix so all files map to the original PartInfo NB.
function Normalize-Name {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $v = $Text -replace '(?i)(?:_PART\d+|-\d+)$', ''
    $v = $v -replace '[^A-Za-z0-9]+', ' '
    return (($v.Trim() -replace '\s+', ' ').ToLowerInvariant())
}
function Get-GroupName {
    param([string]$BaseName)
    return ($BaseName -replace '(?i)(?:_PART\d+|-\d+)$', '')
}
function Browse-Folder {
    param([string]$Description, [string]$CurrentPath)
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $false
    if (-not [string]::IsNullOrWhiteSpace($CurrentPath) -and
        (Test-Path -LiteralPath $CurrentPath -PathType Container)) {
        $dialog.SelectedPath = $CurrentPath
    }
    if ($dialog.ShowDialog($script:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

# Read PartInfo metadata recursively. A catalog folder can contain PartInfo.txt
# or a file named simply PartInfo (Windows may hide the .txt extension).
function Get-CatalogMappings {
    param([string]$TargetRoot)
    $records = New-Object System.Collections.Generic.List[object]
    $metadataFiles = @(Get-ChildItem -LiteralPath $TargetRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^PartInfo(?:\.txt)?$' })
    foreach ($meta in $metadataFiles) {
        try {
            $raw = Get-Content -LiteralPath $meta.FullName -Raw
            $data = $raw | ConvertFrom-Json
            $entries = @()
            if ($data.PartInfos) { $entries = @($data.PartInfos) }
            elseif ($data.NB -or $data.ProjectPath) { $entries = @($data) }
            foreach ($entry in $entries) {
                $nb = [string]$entry.NB
                $project = [string]$entry.ProjectPath
                if ([string]::IsNullOrWhiteSpace($project) -and $data.ProjectPath) {
                    $project = [string]$data.ProjectPath
                }
                if ([string]::IsNullOrWhiteSpace($nb) -or [string]::IsNullOrWhiteSpace($project)) { continue }

                # ProjectPath commonly ends with a .prj filename, while the
                # actual NX destination is a folder named after that project.
                # Example:
                # gb_standards/bearings/gb_t_5800_1_2012/gb_t_5800_1_2012.prj
                # must resolve to:
                # <TargetRoot>\gb_t_5800_1_2012\gb_t_5800_1_2012
                $parts = @(
                    $project -split '[/\\]' |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
                $categoryName = (Get-Item -LiteralPath $TargetRoot).Name
                $catIndex = -1
                for ($i = 0; $i -lt $parts.Count; $i++) {
                    if ([string]::Equals([string]$parts[$i], [string]$categoryName,
                        [StringComparison]::OrdinalIgnoreCase)) {
                        $catIndex = $i
                    }
                }

                $dest = $null
                if ($catIndex -ge 0 -and $catIndex -lt ($parts.Count - 1)) {
                    $dest = $TargetRoot

                    # Add intermediate directory segments after category,
                    # excluding the final .prj filename.
                    for ($i = $catIndex + 1; $i -lt ($parts.Count - 1); $i++) {
                        $segment = [string]$parts[$i]
                        if ($segment -eq '.' -or $segment -eq '..' -or
                            $segment -match '[:*?"<>|]') {
                            $dest = $null
                            break
                        }
                        $dest = Join-Path $dest $segment
                    }

                    # The .prj filename stem is itself the final component folder.
                    if ($dest) {
                        $projectFile = [string]$parts[$parts.Count - 1]
                        $projectStem = [IO.Path]::GetFileNameWithoutExtension($projectFile)
                        if ([string]::IsNullOrWhiteSpace($projectStem) -or
                            $projectStem -match '[:*?"<>|]' -or
                            $projectStem -eq '.' -or $projectStem -eq '..') {
                            $dest = $null
                        }
                        else {
                            $dest = Join-Path $dest $projectStem
                        }
                    }
                }

                # Use metadata's own directory only when it exactly matches
                # the fully resolved expected destination. Never fall back
                # to its parent folder, which caused the previous misplacement.
                if ($dest -and -not (Test-Path -LiteralPath $dest -PathType Container)) {
                    if ([string]::Equals(
                        [IO.Path]::GetFullPath($meta.Directory.FullName).TrimEnd('\'),
                        [IO.Path]::GetFullPath($dest).TrimEnd('\'),
                        [StringComparison]::OrdinalIgnoreCase)) {
                        $dest = $meta.Directory.FullName
                    }
                }
                if ($dest -and -not (Test-Path -LiteralPath $dest -PathType Container)) {
                    Write-Log "UNRESOLVED destination for NB '$nb'. ProjectPath='$project'; Expected='$dest'" 'DarkOrange'
                    $dest = $null
                }
                if ($dest -and (Test-Path -LiteralPath $dest -PathType Container)) {
                    $records.Add([pscustomobject]@{
                        NB = $nb
                        Key = (Normalize-Name $nb)
                        ProjectPath = $project
                        Destination = $dest
                        Metadata = $meta.FullName
                    })
                }
            }
        } catch {
            Write-Log "Could not parse metadata '$($meta.FullName)': $($_.Exception.Message)" 'DarkOrange'
        }
    }
    # Return the List contents as a plain object[]; avoid PowerShell 5.1's
    # collection adapter issue with @($genericList), which can throw
    # System.ArgumentException: "Argument types do not match".
    return $records.ToArray()
}

# Main window
$script:MainForm = New-Object System.Windows.Forms.Form
$script:MainForm.Text = 'CADENAS Organizer V3.2.13 - Standard Status Viewer'
$script:MainForm.Size = New-Object System.Drawing.Size(900, 710)
$script:MainForm.MinimumSize = New-Object System.Drawing.Size(900, 710)
$script:MainForm.StartPosition = 'CenterScreen'
$script:MainForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'CADENAS NX File Organizer V3.2.13'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 16)
$title.Size = New-Object System.Drawing.Size(800, 32)
$script:MainForm.Controls.Add($title)

$srcLabel = New-Object System.Windows.Forms.Label
$srcLabel.Text = 'Source Members folder containing downloaded NX .prt files:'
$srcLabel.Location = New-Object System.Drawing.Point(22, 62)
$srcLabel.Size = New-Object System.Drawing.Size(650, 22)
$script:MainForm.Controls.Add($srcLabel)
$sourceText = New-Object System.Windows.Forms.TextBox
$sourceText.Text = $config.Source
$sourceText.Location = New-Object System.Drawing.Point(22, 86)
$sourceText.Size = New-Object System.Drawing.Size(735, 25)
$sourceText.Anchor = 'Top,Left,Right'
$script:MainForm.Controls.Add($sourceText)
$srcBrowse = New-Object System.Windows.Forms.Button
$srcBrowse.Text = 'Browse...'
$srcBrowse.Location = New-Object System.Drawing.Point(767, 84)
$srcBrowse.Size = New-Object System.Drawing.Size(105, 29)
$srcBrowse.Anchor = 'Top,Right'
$script:MainForm.Controls.Add($srcBrowse)

$tgtLabel = New-Object System.Windows.Forms.Label
$tgtLabel.Text = 'Target catalog category folder (e.g. gb_standards\bearings):'
$tgtLabel.Location = New-Object System.Drawing.Point(22, 127)
$tgtLabel.Size = New-Object System.Drawing.Size(650, 22)
$script:MainForm.Controls.Add($tgtLabel)
$targetText = New-Object System.Windows.Forms.TextBox
$targetText.Text = $config.Target
$targetText.Location = New-Object System.Drawing.Point(22, 151)
$targetText.Size = New-Object System.Drawing.Size(735, 25)
$targetText.Anchor = 'Top,Left,Right'
$script:MainForm.Controls.Add($targetText)
$tgtBrowse = New-Object System.Windows.Forms.Button
$tgtBrowse.Text = 'Browse...'
$tgtBrowse.Location = New-Object System.Drawing.Point(767, 149)
$tgtBrowse.Size = New-Object System.Drawing.Size(105, 29)
$tgtBrowse.Anchor = 'Top,Right'
$script:MainForm.Controls.Add($tgtBrowse)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'V3.2.13: Standard Status counts catalog component images, including components without local folders.'
$hint.ForeColor = [System.Drawing.Color]::DimGray
$hint.Location = New-Object System.Drawing.Point(22, 184)
$hint.Size = New-Object System.Drawing.Size(840, 22)
$script:MainForm.Controls.Add($hint)

$processButton = New-Object System.Windows.Forms.Button
$processButton.Text = 'Analyze and move matched files'
$processButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$processButton.Location = New-Object System.Drawing.Point(22, 218)
$processButton.Size = New-Object System.Drawing.Size(260, 40)
$script:MainForm.Controls.Add($processButton)
$standardStatusButton = New-Object System.Windows.Forms.Button
$standardStatusButton.Text = 'Standard Status'
$standardStatusButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$standardStatusButton.Location = New-Object System.Drawing.Point(415, 218)
$standardStatusButton.Size = New-Object System.Drawing.Size(180, 40)
$script:MainForm.Controls.Add($standardStatusButton)
$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = 'Clear log'
$clearButton.Location = New-Object System.Drawing.Point(295, 223)
$clearButton.Size = New-Object System.Drawing.Size(100, 30)
$script:MainForm.Controls.Add($clearButton)
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready'
$statusLabel.Location = New-Object System.Drawing.Point(22, 267)
$statusLabel.Size = New-Object System.Drawing.Size(840, 22)
$statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
$script:MainForm.Controls.Add($statusLabel)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Activity log:'
$logLabel.Location = New-Object System.Drawing.Point(22, 292)
$logLabel.Size = New-Object System.Drawing.Size(150, 22)
$script:MainForm.Controls.Add($logLabel)
$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location = New-Object System.Drawing.Point(22, 317)
$script:LogBox.Size = New-Object System.Drawing.Size(850, 310)
$script:LogBox.Anchor = 'Top,Bottom,Left,Right'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:MainForm.Controls.Add($script:LogBox)

$srcBrowse.Add_Click({
    $chosen = Browse-Folder 'Select the Members folder containing downloaded NX .prt files' $sourceText.Text
    if ($chosen) { $sourceText.Text = $chosen; Save-Config }
})
$tgtBrowse.Add_Click({
    $chosen = Browse-Folder 'Select the target catalog category folder' $targetText.Text
    if ($chosen) { $targetText.Text = $chosen; Save-Config }
})
$sourceText.Add_Leave({ Save-Config })
$targetText.Add_Leave({ Save-Config })
$clearButton.Add_Click({ $script:LogBox.Clear() })

# Read-only integrity check: scan every descendant component folder. Each folder's
# TXT (NB field) or PS3 (NB attribute) identifies the expected NX file.
# The matching .prt is searched recursively inside the selected catalog folder only.
function Get-ComponentNBFromMetadata {
    param([string]$FolderPath)
    $names = New-Object System.Collections.Generic.List[string]

    # PartInfo.txt is the primary source. Also accept other .txt files that
    # expose an NB property, because CADENAS installations can vary by catalog.
    $txtFiles = @(Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction Stop |
        Where-Object { $_.Extension -ieq '.txt' -or $_.Name -ieq 'PartInfo' })
    foreach ($txt in $txtFiles) {
        try {
            $raw = Get-Content -LiteralPath $txt.FullName -Raw -ErrorAction Stop
            try {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($obj.NB) { $names.Add(([string]$obj.NB).Trim()) }
                foreach ($entry in @($obj.PartInfos)) {
                    if ($entry -and $entry.NB) { $names.Add(([string]$entry.NB).Trim()) }
                }
            } catch {
                $m = [regex]::Match($raw, '(?is)\bNB\s*[=:]\s*["''](?<v>[^"'']+)["'']')
                if ($m.Success) { $names.Add($m.Groups['v'].Value.Trim()) }
            }
        } catch { }
    }

    # PS3 files commonly store the component name in an NB attribute.
    $ps3Files = @(Get-ChildItem -LiteralPath $FolderPath -File -Filter '*.ps3' -ErrorAction Stop)
    foreach ($ps3 in $ps3Files) {
        try {
            $raw = Get-Content -LiteralPath $ps3.FullName -Raw -ErrorAction Stop
            $matches = [regex]::Matches($raw, '(?is)\bNB\s*[=:]\s*["''](?<v>[^"'']+)["'']')
            foreach ($m in $matches) { $names.Add($m.Groups['v'].Value.Trim()) }
            if ($matches.Count -eq 0) {
                $m = [regex]::Match($raw, '(?is)<NB>\s*(?<v>.*?)\s*</NB>')
                if ($m.Success) { $names.Add($m.Groups['v'].Value.Trim()) }
            }
        } catch { }
    }

    return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}


# Resolve the actual catalog tree using the selected Source Members path.
# Example source: ...\\CADENAS Library\\Members\\gb_standards
# Standard name is read from the final path segment (gb_standards), while
# the tree is read from ...\\CADENAS Library\\gb_standards, never from Members.
function Resolve-StandardCatalogRoot {
    param([string]$SourceMembersPath)

    $sourceItem = Get-Item -LiteralPath $SourceMembersPath -ErrorAction Stop
    $standardName = $sourceItem.Name
    if ([string]::IsNullOrWhiteSpace($standardName) -or
        $standardName -ieq 'Members') {
        throw "The Source Members Folder must identify a standard subfolder, for example ...\\Members\\gb_standards. Current value: $SourceMembersPath"
    }

    # Find the CADENAS library root by locating the nearest ancestor named Members.
    $cursor = $sourceItem
    $membersDirectory = $null
    while ($null -ne $cursor) {
        if ($cursor.Name -ieq 'Members') {
            $membersDirectory = $cursor
            break
        }
        $cursor = $cursor.Parent
    }
    if ($null -eq $membersDirectory) {
        throw "Could not find a 'Members' directory in the Source Members Folder path: $SourceMembersPath"
    }

    $libraryRoot = $membersDirectory.Parent
    if ($null -eq $libraryRoot) {
        throw "Could not determine the CADENAS Library root from: $SourceMembersPath"
    }

    # Fast path: the standard is normally a direct child of CADENAS Library.
    $directCandidate = Join-Path $libraryRoot.FullName $standardName
    if (Test-Path -LiteralPath $directCandidate -PathType Container) {
        return (Get-Item -LiteralPath $directCandidate -ErrorAction Stop)
    }

    # Fallback: search the library tree for the exact standard folder name,
    # explicitly pruning Members so the flat downloaded-file area is never scanned.
    $matches = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push($libraryRoot)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Name -ieq 'Members') { continue }
            if ($child.Name -ieq $standardName) {
                $matches.Add($child)
            } else {
                $pending.Push($child)
            }
        }
    }

    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if ($matches.Count -gt 1) {
        $paths = @($matches | ForEach-Object { $_.FullName })
        throw "Found more than one '$standardName' folder outside Members. Please check the CADENAS Library structure: $($paths -join '; ')"
    }
    throw "Could not find the real '$standardName' catalog folder under '$($libraryRoot.FullName)'. The Members folder was excluded from the search."
}

# Standard Status inventory (read-only; independent of WinForms).
# Group sibling preview images by exact basename, case-insensitively.
# One image = one component; two images = category, never a part.
# The component folder is checked directly, not traversed as a category.
function Get-LeafPartStatus {
    param([string]$FolderPath)

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        throw 'Component status scan received an empty folder path.'
    }
    if (-not [System.IO.Directory]::Exists($FolderPath)) {
        return 'Missing'
    }
    try {
        foreach ($filePath in [System.IO.Directory]::GetFiles($FolderPath)) {
            if ([System.IO.Path]::GetExtension($filePath) -ieq '.prt') {
                return 'Completed'
            }
        }
    } catch {
        throw "Cannot scan component folder '$FolderPath': $($_.Exception.Message)"
    }
    return 'Incompleted'
}

function Get-StandardCatalogInventory {
    param(
        [string]$CatalogPath,
        [System.Collections.Generic.List[string]]$Warnings
    )

    # Use explicit filesystem paths throughout recursion, not DirectoryInfo
    # arguments that may be empty or converted by PowerShell parameter binding.
    if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
        throw 'Catalog inventory received an empty directory path.'
    }
    $CatalogPath = [System.IO.Path]::GetFullPath($CatalogPath)
    $catalogDirectory = New-Object System.IO.DirectoryInfo -ArgumentList $CatalogPath
    if (-not $catalogDirectory.Exists) {
        throw "Catalog folder does not exist or cannot be accessed: '$CatalogPath'"
    }

    $counts = @{ Completed = 0; Incompleted = 0; Missing = 0; Total = 0 }
    $children = New-Object 'System.Collections.Generic.List[object]'
    $imageCounts = @{}
    $directories = @{}
    $linkedDirectories = @{}
    $extensions = @('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff', '.webp', '.ico')

    # Read a concrete directory via .NET, independent of the PowerShell
    # filesystem provider. Empty folders yield an empty array, not a null path.
    try {
        $entries = $catalogDirectory.GetFileSystemInfos()
    } catch {
        throw "Cannot enumerate catalog folder '$CatalogPath': $($_.Exception.Message)"
    }
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        # Preserve the original non-hidden catalog inventory scan.
        if ($entry.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) { continue }
        if ($entry -is [System.IO.DirectoryInfo]) {
            $directories[$entry.Name] = [string]$entry.FullName
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $linkedDirectories[$entry.Name] = $true
            }
        } elseif ($extensions -contains $entry.Extension) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            # Catalog copyright artwork is not a component preview.
            if ($name -ieq 'copyright') { continue }
            if (-not $imageCounts.ContainsKey($name)) { $imageCounts[$name] = 0 }
            $imageCounts[$name]++
        }
    }

    # Catalog names such as "keys" can shadow Hashtable.Keys in PowerShell.
    # Enumerate actual entries so a filename cannot change the collection being scanned.
    foreach ($imageEntry in ($imageCounts.GetEnumerator() | Sort-Object -Property Key)) {
        $name = [string]$imageEntry.Key
        $itemPath = [System.IO.Path]::Combine($CatalogPath, [string]$name)
        if ($directories.ContainsKey($name)) {
            $itemPath = [string]$directories[$name]
        }
        $imageCount = [int]$imageEntry.Value
        if ($imageCount -eq 1) {
            $status = Get-LeafPartStatus -FolderPath $itemPath
            $partCounts = @{ Completed = 0; Incompleted = 0; Missing = 0; Total = 1 }
            $partCounts[$status] = 1
            $children.Add([pscustomobject]@{
                Name = $name; FullPath = $itemPath; Kind = 'Component'
                Status = $status; Counts = $partCounts; Children = @()
            })
        } else {
            if ($imageCount -gt 2) {
                $Warnings.Add("Ambiguous preview group ($imageCount images): $itemPath. Treated as a category, not a component.")
            }
            if ($directories.ContainsKey($name) -and -not $linkedDirectories.ContainsKey($name)) {
                $branch = Get-StandardCatalogInventory -CatalogPath $itemPath -Warnings $Warnings
                $children.Add($branch)
            } else {
                $Warnings.Add("Category folder missing or not traversable: $itemPath. Its descendants cannot be counted.")
                $children.Add([pscustomobject]@{
                    Name = $name; FullPath = $itemPath; Kind = 'Category'
                    Status = $null; Counts = @{ Completed = 0; Incompleted = 0; Missing = 0; Total = 0 }; Children = @()
                })
            }
        }
    }

    # Search structural folders that have no preview at their parent.
    foreach ($directoryEntry in ($directories.GetEnumerator() | Sort-Object -Property Key)) {
        $name = [string]$directoryEntry.Key
        if ($imageCounts.ContainsKey($name)) { continue }
        $subdirectoryPath = [string]$directoryEntry.Value
        if ($linkedDirectories.ContainsKey($name)) {
            $Warnings.Add("Skipped linked structural folder: $subdirectoryPath")
            continue
        }
        $branch = Get-StandardCatalogInventory -CatalogPath $subdirectoryPath -Warnings $Warnings
        if ($branch.Children.Count -gt 0) { $children.Add($branch) }
    }

    $orderedChildren = @($children.ToArray() | Sort-Object Name)
    foreach ($child in $orderedChildren) {
        foreach ($key in @('Completed', 'Incompleted', 'Missing', 'Total')) {
            $counts[$key] += $child.Counts[$key]
        }
    }
    return [pscustomobject]@{
        Name = $catalogDirectory.Name; FullPath = $CatalogPath; Kind = 'Category'
        Status = $null; Counts = $counts; Children = $orderedChildren
    }
}

# Render the same inventory used for the counts: image-only components are
# real tree nodes, even when there is no corresponding directory on disk.
function Add-StandardTreeNode {
    param(
        [System.Windows.Forms.TreeNode]$ParentNode,
        [pscustomobject]$Item,
        [switch]$ShowBranchCounts
    )

    $nodeText = $Item.Name
    $nodeColor = [System.Drawing.Color]::Black
    if ($Item.Kind -eq 'Component') {
        switch ($Item.Status) {
            'Completed' {
                $nodeText = [string][char]0x2713 + ' ' + $Item.Name
                $nodeColor = [System.Drawing.Color]::ForestGreen
            }
            'Missing' {
                $nodeText = [string][char]0x2717 + ' ' + $Item.Name
                $nodeColor = [System.Drawing.Color]::Firebrick
            }
            'Incompleted' {
                $nodeText = [string][char]0x25CB + ' ' + $Item.Name
                $nodeColor = [System.Drawing.Color]::DimGray
            }
        }
    } elseif ($ShowBranchCounts) {
        $nodeText = "$nodeText  [Completed: $($Item.Counts.Completed) | Incompleted: $($Item.Counts.Incompleted) | Missing: $($Item.Counts.Missing)]"
    }

    $node = New-Object System.Windows.Forms.TreeNode($nodeText)
    $node.Name = $Item.FullPath
    $node.ForeColor = $nodeColor
    # The inventory already aggregates counts across every descendant.
    $node.Tag = [bool](($Item.Counts.Incompleted -gt 0) -or ($Item.Counts.Missing -gt 0))
    [void]$ParentNode.Nodes.Add($node)
    foreach ($child in $Item.Children) {
        Add-StandardTreeNode -ParentNode $node -Item $child
    }
}

# Expand the selected category itself, then reveal only unfinished branches.
# Keep completed and empty subfolders available for manual expansion.
function Expand-UnfinishedStandardBranches {
    param([System.Windows.Forms.TreeNode]$Node)

    $Node.Expand()
    foreach ($childNode in $Node.Nodes) {
        if ($childNode.Nodes.Count -eq 0) { continue }
        if ($childNode.Tag -eq $true) {
            Expand-UnfinishedStandardBranches -Node $childNode
        } else {
            $childNode.Collapse()
        }
    }
}

# Apply a fresh, read-only inventory to the existing Standard Status window.
# Both initial display and manual refresh use the same rendering and expansion rules.
function Set-StandardStatusViewerInventory {
    param([pscustomobject]$State, [pscustomobject]$Inventory)

    $tree = $State.Tree
    $standardRoot = $State.StandardRoot
    $counts = $Inventory.Counts
    # Build the replacement tree before removing the previous one.
    $rootNode = New-Object System.Windows.Forms.TreeNode($Inventory.Name)
    $rootNode.Name = $Inventory.FullPath
    $rootNode.ForeColor = [System.Drawing.Color]::DarkSlateBlue
    foreach ($item in $Inventory.Children) {
        Add-StandardTreeNode -ParentNode $rootNode -Item $item -ShowBranchCounts
    }

    if ($counts.Total -gt 0) {
        $percentage = [int][Math]::Round(($counts.Completed / [double]$counts.Total) * 100)
    } else {
        $percentage = 0
    }

    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        [void]$tree.Nodes.Add($rootNode)
        # Find the exact TreeView node for the current Target Category by its
        # full directory path. Then expand only unfinished branches beneath it.
        # This avoids relying on relative path traversal or displayed node text.
        $tree.CollapseAll()
        $targetCategoryPath = $State.TargetCategoryPath
        $targetNode = $null

        if (-not [string]::IsNullOrWhiteSpace($targetCategoryPath) -and
            (Test-Path -LiteralPath $targetCategoryPath -PathType Container)) {
            $targetFullPath = [System.IO.Path]::GetFullPath($targetCategoryPath).TrimEnd([char[]]@('\', '/'))
            $standardFullPath = [System.IO.Path]::GetFullPath($standardRoot).TrimEnd([char[]]@('\', '/'))

            if ($targetFullPath.Equals($standardFullPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                $targetFullPath.StartsWith($standardFullPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $nodeStack = New-Object 'System.Collections.Generic.Stack[System.Windows.Forms.TreeNode]'
                $nodeStack.Push($rootNode)
                while ($nodeStack.Count -gt 0) {
                    $candidate = $nodeStack.Pop()
                    if (-not [string]::IsNullOrWhiteSpace($candidate.Name)) {
                        $candidatePath = [System.IO.Path]::GetFullPath($candidate.Name).TrimEnd([char[]]@('\', '/'))
                        if ($candidatePath.Equals($targetFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $targetNode = $candidate
                            break
                        }
                    }
                    foreach ($childNode in $candidate.Nodes) {
                        $nodeStack.Push($childNode)
                    }
                }
            }
        }

        if ($null -ne $targetNode) {
            Expand-UnfinishedStandardBranches -Node $targetNode
            $tree.SelectedNode = $targetNode
            $targetNode.EnsureVisible()
        } else {
            $rootNode.Expand()
            $tree.SelectedNode = $rootNode
        }

        $State.RootNode = $rootNode
        $State.TargetNode = $targetNode
    } finally {
        $tree.EndUpdate()
    }

    $State.PercentLabel.Text = "Completion: $percentage%"
    $State.PartsLabel.Text = "$($counts.Completed) in $($counts.Total) parts"
    $State.Progress.Tag = [long[]]@($counts.Completed, $counts.Incompleted, $counts.Missing)
    $State.Progress.AccessibleDescription = "Completed: $($counts.Completed); Incompleted: $($counts.Incompleted); Missing: $($counts.Missing)"
    $State.Progress.Invalidate()
    $State.LegendLabels[0].Text = "Completed: $($counts.Completed)"
    $State.LegendLabels[1].Text = "Incompleted: $($counts.Incompleted)"
    $State.LegendLabels[2].Text = "Missing: $($counts.Missing)"
    $State.Percentage = $percentage
}

$standardStatusButton.Add_Click({
    $sourceMembersPath = $sourceText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($sourceMembersPath) -or
        -not (Test-Path -LiteralPath $sourceMembersPath -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Select the current standard source folder in the Source Members Folder field, for example ...\\Members\\gb_standards.',
            'Source Members folder required'
        ) | Out-Null
        return
    }

    Save-Config
    $standardStatusButton.Enabled = $false
    $statusLabel.Text = 'Locating and scanning the real CADENAS catalog...'
    try {
        $rootDirectory = Resolve-StandardCatalogRoot -SourceMembersPath $sourceMembersPath
        $standardRoot = [string]$rootDirectory.FullName
        if ([string]::IsNullOrWhiteSpace($standardRoot)) {
            throw "Could not resolve a valid catalog path from: $sourceMembersPath"
        }
        $scanWarnings = New-Object 'System.Collections.Generic.List[string]'
        $inventory = Get-StandardCatalogInventory -CatalogPath $standardRoot -Warnings $scanWarnings
        $counts = $inventory.Counts
        foreach ($warning in $scanWarnings) { Write-Log "Standard Status: $warning" 'DarkOrange' }
        if ($counts.Total -eq 0) {
            Write-Log 'No component preview images were found in the local catalog. The full online catalog total is not known.' 'DarkOrange'
        }

        $viewer = New-Object System.Windows.Forms.Form
        $viewer.Text = "Standard Status - $($rootDirectory.Name)"
        $viewer.Size = New-Object System.Drawing.Size(850, 720)
        $viewer.MinimumSize = New-Object System.Drawing.Size(650, 500)
        $viewer.StartPosition = 'CenterParent'
        $viewer.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = "Standard: $($rootDirectory.Name)"
        $heading.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
        $heading.Location = New-Object System.Drawing.Point(18, 15)
        $heading.Size = New-Object System.Drawing.Size(745, 28)
        $heading.Anchor = 'Top,Left,Right'
        $viewer.Controls.Add($heading)

        $percentLabel = New-Object System.Windows.Forms.Label
        $percentLabel.Location = New-Object System.Drawing.Point(20, 53)
        $percentLabel.Size = New-Object System.Drawing.Size(790, 25)
        $percentLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $percentLabel.Anchor = 'Top,Left,Right'
        $viewer.Controls.Add($percentLabel)

        # A custom-painted WinForms panel shows all three status proportions.
        # Store a snapshot on the control so repainting never depends on the scan's scope.
        $progress = New-Object System.Windows.Forms.Panel
        $progress.Location = New-Object System.Drawing.Point(20, 82)
        $progress.Size = New-Object System.Drawing.Size(790, 18)
        $progress.Anchor = 'Top,Left,Right'
        $progress.Tag = [long[]]@($counts.Completed, $counts.Incompleted, $counts.Missing)
        $progress.AccessibleName = 'Component status distribution'
        $progress.AccessibleDescription = "Completed: $($counts.Completed); Incompleted: $($counts.Incompleted); Missing: $($counts.Missing)"
        $progress.Add_Resize({ param($sender, $eventArgs) $sender.Invalidate() })
        $progress.Add_Paint({
            param($sender, $eventArgs)
            $width = $sender.ClientSize.Width
            $height = $sender.ClientSize.Height
            if ($width -le 0 -or $height -le 0) { return }

            $values = $sender.Tag
            $total = [long]$values[0] + [long]$values[1] + [long]$values[2]
            $graphics = $eventArgs.Graphics
            $graphicsState = $graphics.Save()
            $outline = New-Object System.Drawing.Drawing2D.GraphicsPath
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(229, 231, 235))
            try {
                # Rounded outer corners; status segments meet without gaps.
                $diameter = [int][Math]::Min(12, [Math]::Min($width, $height))
                if ($diameter -gt 1) {
                    $outline.AddArc(0, 0, $diameter, $diameter, 180, 90)
                    $outline.AddArc(($width - $diameter), 0, $diameter, $diameter, 270, 90)
                    $outline.AddArc(($width - $diameter), ($height - $diameter), $diameter, $diameter, 0, 90)
                    $outline.AddArc(0, ($height - $diameter), $diameter, $diameter, 90, 90)
                    $outline.CloseFigure()
                } else {
                    $outline.AddRectangle((New-Object System.Drawing.Rectangle(0, 0, $width, $height)))
                }
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $graphics.FillPath($brush, $outline)
                $graphics.SetClip($outline, [System.Drawing.Drawing2D.CombineMode]::Intersect)
                if ($total -gt 0) {
                    $colors = @(
                        [System.Drawing.Color]::FromArgb(22, 163, 74)
                        [System.Drawing.Color]::FromArgb(156, 163, 175)
                        [System.Drawing.Color]::FromArgb(220, 38, 38)
                    )
                    $left = 0
                    $cumulative = [long]0
                    for ($i = 0; $i -lt 3; $i++) {
                        $cumulative += [long]$values[$i]
                        $right = [int][Math]::Round(($cumulative / [double]$total) * $width)
                        if ($right -gt $left) {
                            $brush.Color = $colors[$i]
                            $graphics.FillRectangle($brush, $left, 0, ($right - $left), $height)
                        }
                        $left = $right
                    }
                }
            } finally {
                $graphics.Restore($graphicsState)
                $brush.Dispose()
                $outline.Dispose()
            }
        })
        $viewer.Controls.Add($progress)

        $partsLabel = New-Object System.Windows.Forms.Label
        $partsLabel.Location = New-Object System.Drawing.Point(20, 108)
        $partsLabel.Size = New-Object System.Drawing.Size(790, 22)
        $partsLabel.Anchor = 'Top,Left,Right'
        $viewer.Controls.Add($partsLabel)

        # Color-coded legend for the segmented bar, in the existing summary row.
        $countsLegend = New-Object System.Windows.Forms.TableLayoutPanel
        $countsLegend.Location = New-Object System.Drawing.Point(20, 135)
        $countsLegend.Size = New-Object System.Drawing.Size(790, 24)
        $countsLegend.Anchor = 'Top,Left,Right'
        $countsLegend.ColumnCount = 3
        $countsLegend.RowCount = 1
        $countsLegend.GrowStyle = 'FixedSize'
        $legendTexts = @("Completed: $($counts.Completed)", "Incompleted: $($counts.Incompleted)", "Missing: $($counts.Missing)")
        $legendColors = @([System.Drawing.Color]::ForestGreen, [System.Drawing.Color]::DimGray, [System.Drawing.Color]::Firebrick)
        $legendLabels = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Label]'
        for ($column = 0; $column -lt 3; $column++) {
            [void]$countsLegend.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [single](100.0 / 3))))
            $legendLabel = New-Object System.Windows.Forms.Label
            $legendLabel.Text = $legendTexts[$column]
            $legendLabel.ForeColor = $legendColors[$column]
            $legendLabel.Dock = 'Fill'
            $legendLabel.TextAlign = 'MiddleLeft'
            $legendLabel.Margin = New-Object System.Windows.Forms.Padding(0)
            $countsLegend.Controls.Add($legendLabel, $column, 0)
            $legendLabels.Add($legendLabel)
        }
        $viewer.Controls.Add($countsLegend)

        $tree = New-Object System.Windows.Forms.TreeView
        $tree.Location = New-Object System.Drawing.Point(20, 170)
        $tree.Size = New-Object System.Drawing.Size(790, 485)
        $tree.Anchor = 'Top,Bottom,Left,Right'
        $tree.HideSelection = $false
        $tree.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $viewer.Controls.Add($tree)

        # Icon-only refresh button; no additional image asset is required.
        $refreshButton = New-Object System.Windows.Forms.Button
        $refreshButton.Text = [string][char]0x21BB
        $refreshButton.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 14)
        $refreshButton.Location = New-Object System.Drawing.Point(778, 12)
        $refreshButton.Size = New-Object System.Drawing.Size(32, 32)
        $refreshButton.Anchor = 'Top,Right'
        $refreshButton.AccessibleName = 'Refresh Standard Status'
        $refreshButton.AccessibleDescription = 'Rescan the current catalog and update all component statuses.'
        $viewer.Controls.Add($refreshButton)
        $refreshToolTip = New-Object System.Windows.Forms.ToolTip
        $refreshToolTip.SetToolTip($refreshButton, 'Refresh Standard Status')

        # Explicit state avoids relying on transient PowerShell event-handler scope.
        $viewerState = [pscustomobject]@{
            Viewer = $viewer; Tree = $tree; StandardRoot = $standardRoot
            TargetCategoryPath = $targetText.Text.Trim()
            PercentLabel = $percentLabel; PartsLabel = $partsLabel
            Progress = $progress; LegendLabels = $legendLabels
            StatusLabel = $statusLabel; SourceMembersPath = $sourceMembersPath
            RootNode = $null; TargetNode = $null; Percentage = 0; Busy = $false
        }
        $viewer.Tag = $viewerState
        $refreshButton.Tag = $viewerState
        Set-StandardStatusViewerInventory -State $viewerState -Inventory $inventory

        # Repeat the initial expansion after the dialog has been displayed.
        $viewer.Add_Shown({
            param($sender, $eventArgs)
            $state = $sender.Tag
            if ($null -ne $state.TargetNode) {
                Expand-UnfinishedStandardBranches -Node $state.TargetNode
                $state.Tree.SelectedNode = $state.TargetNode
                $state.TargetNode.EnsureVisible()
            } else {
                $state.RootNode.Expand()
            }
            [void]$state.Tree.Focus()
        })
        # Logging pumps the message queue, so prevent closing during a refresh.
        $viewer.Add_FormClosing({
            param($sender, $eventArgs)
            if ($sender.Tag.Busy) { $eventArgs.Cancel = $true }
        })
        $refreshButton.Add_Click({
            param($sender, $eventArgs)
            $state = $sender.Tag
            if ($state.Busy) { return }
            $state.Busy = $true
            $sender.Enabled = $false
            $state.Viewer.UseWaitCursor = $true
            $state.StatusLabel.Text = 'Refreshing Standard Status...'
            try {
                # Scan the same standard from disk; do not move or modify files.
                $warnings = New-Object 'System.Collections.Generic.List[string]'
                $newInventory = Get-StandardCatalogInventory -CatalogPath $state.StandardRoot -Warnings $warnings
                # A failed filesystem scan never clears the previous displayed tree.
                Set-StandardStatusViewerInventory -State $state -Inventory $newInventory
                $newCounts = $newInventory.Counts
                foreach ($warning in $warnings) { Write-Log "Standard Status refresh: $warning" 'DarkOrange' }
                if ($newCounts.Total -eq 0) {
                    Write-Log 'No component preview images were found in the local catalog. The full online catalog total is not known.' 'DarkOrange'
                }
                $state.StatusLabel.Text = "Standard scan complete - $($newCounts.Completed) in $($newCounts.Total) parts ($($state.Percentage)%)"
                Write-Log "Standard Status refreshed: $($state.StandardRoot) - Completed $($newCounts.Completed); Incompleted $($newCounts.Incompleted); Missing $($newCounts.Missing); Total component images $($newCounts.Total); Completion $($state.Percentage)%." 'Blue'
            } catch {
                $refreshError = $_
                $state.StatusLabel.Text = 'Standard refresh failed - see log'
                Write-Log "Standard Status refresh failed: $($refreshError.Exception.Message)" 'Red'
                if ($refreshError.InvocationInfo.PositionMessage) {
                    Write-Log "Refresh error location: $($refreshError.InvocationInfo.PositionMessage)" 'Red'
                }
                if ($refreshError.ScriptStackTrace) {
                    Write-Log "Refresh call stack: $($refreshError.ScriptStackTrace)" 'Red'
                }
                [void][System.Windows.Forms.MessageBox]::Show($state.Viewer, $refreshError.Exception.Message, 'Standard Status refresh failed')
            } finally {
                $state.Viewer.UseWaitCursor = $false
                $sender.Enabled = $true
                $state.Busy = $false
            }
        })

        $percentage = $viewerState.Percentage
        $statusLabel.Text = "Standard scan complete - $($counts.Completed) in $($counts.Total) parts ($percentage%)"
        Write-Log "Standard Status (real catalog; source parameter: $sourceMembersPath): $($rootDirectory.FullName) - Completed $($counts.Completed); Incompleted $($counts.Incompleted); Missing $($counts.Missing); Total component images $($counts.Total); Completion $percentage%." 'Blue'
        try {
            [void]$viewer.ShowDialog($script:MainForm)
        } finally {
            $refreshToolTip.Dispose()
            $viewer.Dispose()
        }
    } catch {
        $statusLabel.Text = 'Standard scan failed - see log'
        $scanError = $_
        Write-Log "Standard Status scan failed: $($scanError.Exception.Message)" 'Red'
        if ($scanError.InvocationInfo.PositionMessage) {
            Write-Log "Scan error location: $($scanError.InvocationInfo.PositionMessage)" 'Red'
        }
        if ($scanError.ScriptStackTrace) {
            Write-Log "Scan call stack: $($scanError.ScriptStackTrace)" 'Red'
        }
        [System.Windows.Forms.MessageBox]::Show(
            $scanError.Exception.Message, 'Standard Status scan failed'
        ) | Out-Null
    } finally {
        $standardStatusButton.Enabled = $true
    }
})

$processButton.Add_Click({
    $sourceRoot = $sourceText.Text.Trim()
    $targetRoot = $targetText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($sourceRoot) -or
        -not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('Select an existing source folder.', 'Source folder required') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($targetRoot) -or
        -not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('Select an existing target category folder.', 'Target folder required') | Out-Null
        return
    }
    Save-Config
    $processButton.Enabled = $false
    $statusLabel.Text = 'Reading metadata...'
    Write-Log "Source: $sourceRoot" 'Blue'
    Write-Log "Target category: $targetRoot" 'Blue'
    $moved = 0; $skipped = 0; $errors = 0
    try {
        $mappings = @(Get-CatalogMappings -TargetRoot $targetRoot)
        Write-Log "Catalog metadata records loaded: $($mappings.Count)" 'Blue'
        if ($mappings.Count -eq 0) {
            Write-Log 'No usable PartInfo metadata was found under the target category. No files were moved.' 'DarkOrange'
            $statusLabel.Text = 'No metadata found'
            return
        }

        # Only direct .prt files in the selected source folder are considered.
        $prtFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File -Filter '*.prt')
        if ($prtFiles.Count -eq 0) {
            Write-Log 'No .prt files found directly in the source folder.' 'DarkOrange'
            $statusLabel.Text = 'No NX files found'
            return
        }

        $groups = @($prtFiles | Group-Object { Get-GroupName $_.BaseName })
        foreach ($group in $groups) {
            $componentName = [string]$group.Name
            $key = Normalize-Name $componentName
            $matches = @($mappings | Where-Object { $_.Key -eq $key } |
                Sort-Object Destination, ProjectPath -Unique)

            if ($matches.Count -eq 0) {
                Write-Log "SKIP: No PartInfo NB match for '$componentName'." 'DarkOrange'
                $skipped++
                continue
            }
            $destinations = @($matches | Select-Object -ExpandProperty Destination -Unique)
            if ($destinations.Count -ne 1) {
                Write-Log "SKIP: '$componentName' matches multiple catalog destinations: $($destinations -join '; ')" 'DarkOrange'
                $skipped++
                continue
            }
            $destination = $destinations[0]
            if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
                Write-Log "SKIP: Destination does not exist: $destination" 'DarkOrange'
                $skipped++
                continue
            }

            # Preflight the whole group: do not partially move a family if any
            # destination filename already exists or a source file is unavailable.
            $conflict = $false
            foreach ($file in $group.Group) {
                $destFile = Join-Path $destination $file.Name
                if (Test-Path -LiteralPath $destFile) {
                    Write-Log "SKIP: Destination file already exists: $destFile" 'DarkOrange'
                    $conflict = $true
                }
                try {
                    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                    $stream.Close()
                } catch {
                    Write-Log "SKIP: Source file is locked or inaccessible: $($file.FullName)" 'DarkOrange'
                    $conflict = $true
                }
            }
            if ($conflict) { $skipped++; continue }

            try {
                foreach ($file in $group.Group) {
                    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name) -ErrorAction Stop
                    Write-Log "MOVED: $($file.Name) -> $destination" 'DarkGreen'
                    $moved++
                }
            } catch {
                Write-Log "ERROR moving group '$componentName': $($_.Exception.Message)" 'Red'
                $errors++
            }
        }
        Write-Log "Finished. Files moved: $moved; groups skipped: $skipped; errors: $errors." 'Blue'
        $statusLabel.Text = "Finished - moved $moved file(s), skipped $skipped group(s), errors $errors"
    } catch {
        $err = $_
        Write-Log "FATAL ERROR TYPE: $($err.Exception.GetType().FullName)" 'Red'
        Write-Log "FATAL ERROR: $($err.Exception.Message)" 'Red'
        Write-Log "SCRIPT LINE: $($err.InvocationInfo.ScriptLineNumber)" 'Red'
        Write-Log "STATEMENT: $($err.InvocationInfo.Line)" 'Red'
        Write-Log "POSITION: $($err.InvocationInfo.PositionMessage)" 'Red'
        Write-Log "STACK: $($err.ScriptStackTrace)" 'Red'
        $statusLabel.Text = 'Error - see log'
    } finally {
        $processButton.Enabled = $true
    }
})
$script:MainForm.Add_Shown({ Write-Log 'Ready. V3.2.13 counts component preview images (Completed, Incompleted, Missing) and groups CADENAS split files (_PARTn and -n) with their base component before matching PartInfo NB metadata.' 'Blue' })
[void]$script:MainForm.ShowDialog()
