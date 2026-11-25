# CADENAS NX File Organizer V4.1
# Metadata-driven organizer. Uses PartInfo metadata (NB + ProjectPath) to map
# flat Members .prt files to the exact CADENAS catalog component folder.
# Safe behavior: preview/log matching first; never overwrite; ambiguous matches are skipped.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
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
$script:MainForm.Text = 'CADENAS Organizer - Standard Status'
$script:MainForm.ClientSize = New-Object System.Drawing.Size(894, 760)
$script:MainForm.MinimumSize = New-Object System.Drawing.Size(900, 690)
$script:MainForm.StartPosition = 'CenterScreen'
$script:MainForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'CADENAS NX File Organizer'
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


# Secondary window: operation controls and activity log. No file operation on open.
$moveForm = New-Object System.Windows.Forms.Form
$moveForm.Text = 'Analyze and Move - CADENAS Organizer'
$moveForm.ClientSize = New-Object System.Drawing.Size(894, 570)
$moveForm.MinimumSize = New-Object System.Drawing.Size(760, 470)
$moveForm.StartPosition = 'CenterParent'
$moveForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$moveForm.ShowInTaskbar = $false
$moveTitle = New-Object System.Windows.Forms.Label
$moveTitle.Text = 'Analyze and Move'
$moveTitle.Location = New-Object System.Drawing.Point(22, 16)
$moveTitle.Size = New-Object System.Drawing.Size(840, 30)
$moveTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$moveTitle.Anchor = 'Top,Left,Right'
$moveForm.Controls.Add($moveTitle)
$moveSourceLabel = New-Object System.Windows.Forms.Label
$moveSourceLabel.Text = 'Source Members folder:'
$moveSourceLabel.Location = New-Object System.Drawing.Point(22, 53)
$moveSourceLabel.Size = New-Object System.Drawing.Size(840, 19)
$moveForm.Controls.Add($moveSourceLabel)
$moveSource = New-Object System.Windows.Forms.TextBox
$moveSource.Location = New-Object System.Drawing.Point(22, 74)
$moveSource.Size = New-Object System.Drawing.Size(850, 25)
$moveSource.ReadOnly = $true
$moveSource.Anchor = 'Top,Left,Right'
$moveForm.Controls.Add($moveSource)
$moveTargetLabel = New-Object System.Windows.Forms.Label
$moveTargetLabel.Text = 'Target catalog category folder:'
$moveTargetLabel.Location = New-Object System.Drawing.Point(22, 108)
$moveTargetLabel.Size = New-Object System.Drawing.Size(840, 19)
$moveForm.Controls.Add($moveTargetLabel)
$moveTarget = New-Object System.Windows.Forms.TextBox
$moveTarget.Location = New-Object System.Drawing.Point(22, 129)
$moveTarget.Size = New-Object System.Drawing.Size(850, 25)
$moveTarget.ReadOnly = $true
$moveTarget.Anchor = 'Top,Left,Right'
$moveForm.Controls.Add($moveTarget)

$processButton = New-Object System.Windows.Forms.Button
$processButton.Text = 'Analyze and move matched files'
$processButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$processButton.Location = New-Object System.Drawing.Point(22, 170)
$processButton.Size = New-Object System.Drawing.Size(260, 40)
$moveForm.Controls.Add($processButton)
$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = 'Clear log'
$clearButton.Location = New-Object System.Drawing.Point(295, 175)
$clearButton.Size = New-Object System.Drawing.Size(100, 30)
$moveForm.Controls.Add($clearButton)
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready'
$statusLabel.Location = New-Object System.Drawing.Point(22, 219)
$statusLabel.Size = New-Object System.Drawing.Size(840, 22)
$statusLabel.Anchor = 'Top,Left,Right'
$statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
$moveForm.Controls.Add($statusLabel)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Activity log:'
$logLabel.Location = New-Object System.Drawing.Point(22, 244)
$logLabel.Size = New-Object System.Drawing.Size(150, 22)
$moveForm.Controls.Add($logLabel)
$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location = New-Object System.Drawing.Point(22, 267)
$script:LogBox.Size = New-Object System.Drawing.Size(850, 280)
$script:LogBox.Anchor = 'Top,Bottom,Left,Right'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$moveForm.Controls.Add($script:LogBox)

$closeMoveButton = New-Object System.Windows.Forms.Button
$closeMoveButton.Text = 'Close'
$closeMoveButton.Location = New-Object System.Drawing.Point(772, 175)
$closeMoveButton.Size = New-Object System.Drawing.Size(100, 30)
$closeMoveButton.Anchor = 'Top,Right'
$moveForm.Controls.Add($closeMoveButton)
$moveForm.CancelButton = $closeMoveButton
$closeMoveButton.Add_Click({ $moveForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
$clearButton.Add_Click({ $script:LogBox.Clear() })
# Write-Log pumps the message queue, so do not close a running move operation.
$moveForm.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $processButton.Enabled) { $eventArgs.Cancel = $true }
})
$processButton.Add_EnabledChanged({
    $closeMoveButton.Enabled = $processButton.Enabled
    $clearButton.Enabled = $processButton.Enabled
})

$heading = New-Object System.Windows.Forms.Label
$heading.Text = 'Standard: not scanned'
$heading.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$heading.Location = New-Object System.Drawing.Point(20, 206)
$heading.Size = New-Object System.Drawing.Size(600, 28)
$heading.Anchor = 'Top,Left,Right'
$script:MainForm.Controls.Add($heading)

$percentLabel = New-Object System.Windows.Forms.Label
$percentLabel.Location = New-Object System.Drawing.Point(20, 250)
$percentLabel.Size = New-Object System.Drawing.Size(850, 25)
$percentLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$percentLabel.Anchor = 'Top,Left,Right'
$percentLabel.Text = 'Completion: -'
$script:MainForm.Controls.Add($percentLabel)

# A custom-painted WinForms panel shows all three status proportions.
# Store a snapshot on the control so repainting never depends on the scan's scope.
$progress = New-Object System.Windows.Forms.Panel
$progress.Location = New-Object System.Drawing.Point(20, 279)
$progress.Size = New-Object System.Drawing.Size(850, 18)
$progress.Anchor = 'Top,Left,Right'
$progress.Tag = [long[]]@(0, 0, 0)
$progress.AccessibleName = 'Component status distribution'
$progress.AccessibleDescription = 'Status not scanned'
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
$script:MainForm.Controls.Add($progress)

$partsLabel = New-Object System.Windows.Forms.Label
$partsLabel.Location = New-Object System.Drawing.Point(20, 306)
$partsLabel.Size = New-Object System.Drawing.Size(850, 22)
$partsLabel.Anchor = 'Top,Left,Right'
$partsLabel.Text = 'No scan yet'
$script:MainForm.Controls.Add($partsLabel)

# Color-coded legend for the segmented bar, in the existing summary row.
$countsLegend = New-Object System.Windows.Forms.TableLayoutPanel
$countsLegend.Location = New-Object System.Drawing.Point(20, 333)
$countsLegend.Size = New-Object System.Drawing.Size(850, 24)
$countsLegend.Anchor = 'Top,Left,Right'
$countsLegend.ColumnCount = 3
$countsLegend.RowCount = 1
$countsLegend.GrowStyle = 'FixedSize'
$legendTexts = @('Completed: -', 'Incompleted: -', 'Missing: -')
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
$script:MainForm.Controls.Add($countsLegend)

$tree = New-Object System.Windows.Forms.TreeView
$tree.Location = New-Object System.Drawing.Point(20, 390)
$tree.Size = New-Object System.Drawing.Size(850, 348)
$tree.Anchor = 'Top,Bottom,Left,Right'
$tree.HideSelection = $false
$tree.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:MainForm.Controls.Add($tree)

# Icon-only refresh button; no additional image asset is required.
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = [string][char]0x21BB
$refreshButton.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 14)
$refreshButton.Location = New-Object System.Drawing.Point(838, 204)
$refreshButton.Size = New-Object System.Drawing.Size(32, 32)
$refreshButton.Anchor = 'Top,Right'
$refreshButton.AccessibleName = 'Refresh Standard Status'
$refreshButton.AccessibleDescription = 'Rescan the current catalog and update all component statuses.'
$script:MainForm.Controls.Add($refreshButton)
$refreshToolTip = New-Object System.Windows.Forms.ToolTip
$refreshToolTip.SetToolTip($refreshButton, 'Refresh Standard Status')


# The main dashboard owns the status controls for the lifetime of the application.
$openMoveButton = New-Object System.Windows.Forms.Button
$openMoveButton.Text = 'Analyze and Move'
$openMoveButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$openMoveButton.Location = New-Object System.Drawing.Point(648, 204)
$openMoveButton.Size = New-Object System.Drawing.Size(180, 32)
$openMoveButton.Anchor = 'Top,Right'
$script:MainForm.Controls.Add($openMoveButton)
$scanStatusLabel = New-Object System.Windows.Forms.Label
$scanStatusLabel.Location = New-Object System.Drawing.Point(20, 362)
$scanStatusLabel.Size = New-Object System.Drawing.Size(850, 22)
$scanStatusLabel.Anchor = 'Top,Left,Right'
$scanStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
$scanStatusLabel.Text = 'Select a source folder and refresh to view its catalog.'
$script:MainForm.Controls.Add($scanStatusLabel)

# V4.1 presentation layer only. Keep the same controls, events and dashboard state.
# Native Windows Forms controls remain responsible for input, focus and accessibility.
function Get-OrganizerUiColor {
    param([string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Set-OrganizerRoundedRegion {
    param([System.Windows.Forms.Control]$Control, [int]$Radius = 8)
    $w = $Control.ClientSize.Width
    $h = $Control.ClientSize.Height
    $d = [int][Math]::Min(2 * $Radius, [Math]::Min($w, $h))
    if ($d -lt 2) { return }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc(($w - $d), 0, $d, $d, 270, 90)
        $path.AddArc(($w - $d), ($h - $d), $d, $d, 0, 90)
        $path.AddArc(0, ($h - $d), $d, $d, 90, 90)
        $path.CloseFigure()
        $Control.Region = New-Object System.Drawing.Region -ArgumentList $path
    } finally {
        $path.Dispose()
    }
}

function Add-OrganizerUiSurface {
    param([System.Windows.Forms.Form]$Owner, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    $surface = New-Object System.Windows.Forms.Panel
    $surface.Location = New-Object System.Drawing.Point($X, $Y)
    $surface.Size = New-Object System.Drawing.Size($Width, $Height)
    $surface.Anchor = 'Top,Left,Right'
    $surface.BackColor = [System.Drawing.Color]::White
    $surface.TabStop = $false
    $Owner.Controls.Add($surface)
    $surface.SendToBack()
    Set-OrganizerRoundedRegion -Control $surface -Radius 10
    $surface.Add_SizeChanged({ param($sender, $eventArgs) Set-OrganizerRoundedRegion -Control $sender -Radius 10 })
}

function Set-OrganizerUiButton {
    param([System.Windows.Forms.Button]$Button, [switch]$Primary)
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.UseVisualStyleBackColor = $false
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $Button.BackColor = Get-OrganizerUiColor '#1261D5'
        $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderSize = 0
        $Button.FlatAppearance.MouseOverBackColor = Get-OrganizerUiColor '#0C51BA'
        $Button.FlatAppearance.MouseDownBackColor = Get-OrganizerUiColor '#08439D'
        Set-OrganizerRoundedRegion -Control $Button -Radius 6
        $Button.Add_SizeChanged({ param($sender, $eventArgs) Set-OrganizerRoundedRegion -Control $sender -Radius 6 })
    } else {
        $Button.BackColor = [System.Drawing.Color]::White
        $Button.ForeColor = Get-OrganizerUiColor '#263B55'
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = Get-OrganizerUiColor '#CBD5E1'
        $Button.FlatAppearance.MouseOverBackColor = Get-OrganizerUiColor '#E8F1FF'
        $Button.FlatAppearance.MouseDownBackColor = Get-OrganizerUiColor '#D8E8FF'
    }
}

$uiBackground = Get-OrganizerUiColor '#EFF3F8'
$uiText = Get-OrganizerUiColor '#172B45'
$uiMuted = Get-OrganizerUiColor '#52657B'
$uiBlue = Get-OrganizerUiColor '#1261D5'
$uiWhite = [System.Drawing.Color]::White
$script:MainForm.BackColor = $uiBackground
$moveForm.BackColor = $uiBackground
$script:MainForm.ForeColor = $uiText
$moveForm.ForeColor = $uiText

# Main window: folder settings, status card and full-width catalog tree.
$title.Font = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(22, 16)
$title.Size = New-Object System.Drawing.Size(850, 38)
$title.Anchor = 'Top,Left,Right'
$title.ForeColor = $uiText
$title.BackColor = $uiBackground
$title.TextAlign = 'MiddleLeft'
Add-OrganizerUiSurface -Owner $script:MainForm -X 20 -Y 70 -Width 854 -Height 136
Add-OrganizerUiSurface -Owner $script:MainForm -X 20 -Y 218 -Width 854 -Height 185

$srcLabel.Location = New-Object System.Drawing.Point(36, 81)
$srcLabel.Size = New-Object System.Drawing.Size(710, 22)
$sourceText.Location = New-Object System.Drawing.Point(36, 107)
$sourceText.Size = New-Object System.Drawing.Size(710, 25)
$srcBrowse.Location = New-Object System.Drawing.Point(756, 104)
$srcBrowse.Size = New-Object System.Drawing.Size(102, 30)
$tgtLabel.Location = New-Object System.Drawing.Point(36, 143)
$tgtLabel.Size = New-Object System.Drawing.Size(710, 22)
$targetText.Location = New-Object System.Drawing.Point(36, 169)
$targetText.Size = New-Object System.Drawing.Size(710, 25)
$tgtBrowse.Location = New-Object System.Drawing.Point(756, 166)
$tgtBrowse.Size = New-Object System.Drawing.Size(102, 30)
foreach ($label in @($srcLabel, $tgtLabel)) {
    $label.Anchor = 'Top,Left,Right'
    $label.BackColor = $uiWhite
    $label.ForeColor = $uiMuted
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
}
foreach ($inputBox in @($sourceText, $targetText, $moveSource, $moveTarget)) {
    $inputBox.BorderStyle = 'FixedSingle'
    $inputBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $inputBox.ForeColor = $uiText
    $inputBox.BackColor = $uiWhite
}

$heading.Location = New-Object System.Drawing.Point(36, 230)
$heading.Size = New-Object System.Drawing.Size(565, 35)
$heading.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$heading.ForeColor = $uiText
$heading.TextAlign = 'MiddleLeft'
$openMoveButton.Location = New-Object System.Drawing.Point(612, 230)
$openMoveButton.Size = New-Object System.Drawing.Size(197, 36)
$openMoveButton.Text = ([string][char]0x25B6) + '  Analyze and Move'
$openMoveButton.AccessibleName = 'Analyze and Move'
$refreshButton.Location = New-Object System.Drawing.Point(820, 230)
$refreshButton.Size = New-Object System.Drawing.Size(38, 36)
$refreshButton.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 16)
$percentLabel.Location = New-Object System.Drawing.Point(36, 272)
$percentLabel.Size = New-Object System.Drawing.Size(822, 26)
$percentLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$percentLabel.ForeColor = $uiBlue
$progress.Location = New-Object System.Drawing.Point(36, 302)
$progress.Size = New-Object System.Drawing.Size(822, 21)
$progress.BackColor = $uiWhite
$partsLabel.Location = New-Object System.Drawing.Point(36, 329)
$partsLabel.Size = New-Object System.Drawing.Size(822, 21)
$partsLabel.ForeColor = $uiText
$countsLegend.Location = New-Object System.Drawing.Point(36, 352)
$countsLegend.Size = New-Object System.Drawing.Size(822, 23)
$countsLegend.BackColor = $uiWhite
foreach ($legendLabel in $legendLabels) {
    $legendLabel.BackColor = $uiWhite
    $legendLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
}
$scanStatusLabel.Location = New-Object System.Drawing.Point(36, 377)
$scanStatusLabel.Size = New-Object System.Drawing.Size(822, 23)
foreach ($label in @($heading, $percentLabel, $partsLabel, $scanStatusLabel)) {
    $label.BackColor = $uiWhite
}
$tree.Location = New-Object System.Drawing.Point(20, 415)
$tree.Size = New-Object System.Drawing.Size(854, 323)
$tree.BackColor = $uiWhite
$tree.ForeColor = $uiText
$tree.BorderStyle = 'FixedSingle'
$tree.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$tree.ItemHeight = 23

# Secondary window: same file operation and log, styled consistently.
$moveTitle.Font = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Bold)
$moveTitle.Location = New-Object System.Drawing.Point(22, 16)
$moveTitle.Size = New-Object System.Drawing.Size(850, 38)
$moveTitle.BackColor = $uiBackground
$moveTitle.ForeColor = $uiText
$moveTitle.TextAlign = 'MiddleLeft'
Add-OrganizerUiSurface -Owner $moveForm -X 20 -Y 70 -Width 854 -Height 136
$moveSourceLabel.Text = 'Source Members folder (read-only):'
$moveTargetLabel.Text = 'Target catalog category folder (read-only):'
$moveSourceLabel.Location = New-Object System.Drawing.Point(36, 81)
$moveSourceLabel.Size = New-Object System.Drawing.Size(822, 22)
$moveSource.Location = New-Object System.Drawing.Point(36, 107)
$moveSource.Size = New-Object System.Drawing.Size(822, 25)
$moveTargetLabel.Location = New-Object System.Drawing.Point(36, 143)
$moveTargetLabel.Size = New-Object System.Drawing.Size(822, 22)
$moveTarget.Location = New-Object System.Drawing.Point(36, 169)
$moveTarget.Size = New-Object System.Drawing.Size(822, 25)
foreach ($label in @($moveSourceLabel, $moveTargetLabel)) {
    $label.Anchor = 'Top,Left,Right'
    $label.BackColor = $uiWhite
    $label.ForeColor = $uiMuted
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
}
$moveSource.BackColor = $uiBackground
$moveTarget.BackColor = $uiBackground
$processButton.Location = New-Object System.Drawing.Point(20, 222)
$processButton.Size = New-Object System.Drawing.Size(286, 40)
$processButton.Text = ([string][char]0x25B6) + '  Analyze and move matched files'
$processButton.AccessibleName = 'Analyze and move matched files'
$clearButton.Location = New-Object System.Drawing.Point(318, 222)
$clearButton.Size = New-Object System.Drawing.Size(105, 40)
$closeMoveButton.Location = New-Object System.Drawing.Point(769, 222)
$closeMoveButton.Size = New-Object System.Drawing.Size(105, 40)
$statusLabel.Location = New-Object System.Drawing.Point(20, 273)
$statusLabel.Size = New-Object System.Drawing.Size(854, 23)
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.BackColor = $uiBackground
$logLabel.Location = New-Object System.Drawing.Point(20, 301)
$logLabel.Size = New-Object System.Drawing.Size(854, 22)
$logLabel.Anchor = 'Top,Left,Right'
$logLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$logLabel.ForeColor = $uiText
$logLabel.BackColor = $uiBackground
$script:LogBox.Location = New-Object System.Drawing.Point(20, 326)
$script:LogBox.Size = New-Object System.Drawing.Size(854, 221)
$script:LogBox.BackColor = $uiWhite
$script:LogBox.ForeColor = $uiText
$script:LogBox.BorderStyle = 'FixedSingle'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 10)

foreach ($button in @($srcBrowse, $tgtBrowse, $refreshButton, $clearButton, $closeMoveButton)) {
    Set-OrganizerUiButton -Button $button
}
Set-OrganizerUiButton -Button $openMoveButton -Primary
Set-OrganizerUiButton -Button $processButton -Primary
$refreshButton.ForeColor = $uiBlue

$script:DashboardState = [pscustomobject]@{
    Viewer = $script:MainForm; Tree = $tree; StandardRoot = ''
    TargetCategoryPath = ''; SourceMembersPath = ''
    PercentLabel = $percentLabel; PartsLabel = $partsLabel
    Progress = $progress; LegendLabels = $legendLabels
    StatusLabel = $scanStatusLabel; Heading = $heading
    RootNode = $null; TargetNode = $null; Percentage = 0; Busy = $false
}
$refreshButton.Tag = $script:DashboardState

# Read from the current input fields each time, so changing standards is supported.
# All catalog inventory, rendering and branch-expansion functions are reused unchanged.
function Update-MainStandardStatus {
    param([switch]$Quiet)
    $state = $script:DashboardState
    if ($state.Busy) { return }
    $sourceMembersPath = $sourceText.Text.Trim()
    $targetCategoryPath = $targetText.Text.Trim()
    $state.Busy = $true
    $refreshButton.Enabled = $false
    $openMoveButton.Enabled = $false
    $sourceText.Enabled = $false
    $targetText.Enabled = $false
    $srcBrowse.Enabled = $false
    $tgtBrowse.Enabled = $false
    $state.Viewer.UseWaitCursor = $true
    $state.StatusLabel.ForeColor = [System.Drawing.Color]::DimGray
    $state.StatusLabel.Text = 'Locating and scanning the CADENAS catalog...'
    try {
        if ([string]::IsNullOrWhiteSpace($sourceMembersPath) -or
            -not (Test-Path -LiteralPath $sourceMembersPath -PathType Container)) {
            $state.StatusLabel.Text = 'Source folder not available. Select an existing Members folder and refresh. Previous results, if any, are not current.'
            if (-not $Quiet) {
                [void][System.Windows.Forms.MessageBox]::Show($state.Viewer, 'Select an existing source Members folder.', 'Source Members folder required')
            }
            return
        }
        Save-Config
        $rootDirectory = Resolve-StandardCatalogRoot -SourceMembersPath $sourceMembersPath
        $standardRoot = [string]$rootDirectory.FullName
        if ([string]::IsNullOrWhiteSpace($standardRoot)) {
            throw "Could not resolve a valid catalog path from: $sourceMembersPath"
        }
        $warnings = New-Object 'System.Collections.Generic.List[string]'
        $inventory = Get-StandardCatalogInventory -CatalogPath $standardRoot -Warnings $warnings
        # Do not replace the previous inventory until the new scan succeeds.
        $state.StandardRoot = $standardRoot
        $state.TargetCategoryPath = $targetCategoryPath
        $state.SourceMembersPath = $sourceMembersPath
        Set-StandardStatusViewerInventory -State $state -Inventory $inventory
        $state.Heading.Text = "Standard: $($rootDirectory.Name)"
        $counts = $inventory.Counts
        foreach ($warning in $warnings) { Write-Log "Standard Status: $warning" 'DarkOrange' }
        if ($counts.Total -eq 0) {
            Write-Log 'No component preview images were found in the local catalog. The full online catalog total is not known.' 'DarkOrange'
        }
        $state.StatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        $state.StatusLabel.Text = "Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "Standard Status refreshed: $standardRoot - Completed $($counts.Completed); Incompleted $($counts.Incompleted); Missing $($counts.Missing); Total component images $($counts.Total); Completion $($state.Percentage)%." 'Blue'
    } catch {
        $scanError = $_
        $state.StatusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        $state.StatusLabel.Text = 'Standard scan failed - see Activity log in Analyze and Move. Previous results may be out of date.'
        Write-Log "Standard Status scan failed: $($scanError.Exception.Message)" 'Red'
        if ($scanError.InvocationInfo.PositionMessage) { Write-Log "Scan error location: $($scanError.InvocationInfo.PositionMessage)" 'Red' }
        if ($scanError.ScriptStackTrace) { Write-Log "Scan call stack: $($scanError.ScriptStackTrace)" 'Red' }
        if (-not $Quiet) {
            [void][System.Windows.Forms.MessageBox]::Show($state.Viewer, $scanError.Exception.Message, 'Standard Status scan failed')
        }
    } finally {
        $state.Viewer.UseWaitCursor = $false
        $state.Busy = $false
        $refreshButton.Enabled = $true
        $openMoveButton.Enabled = $true
        $sourceText.Enabled = $true
        $targetText.Enabled = $true
        $srcBrowse.Enabled = $true
        $tgtBrowse.Enabled = $true
    }
}

$refreshButton.Add_Click({ Update-MainStandardStatus })
$script:MainForm.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:DashboardState.Busy) { $eventArgs.Cancel = $true }
})
$srcBrowse.Add_Click({
    $chosen = Browse-Folder 'Select the Members folder containing downloaded NX .prt files' $sourceText.Text
    if ($chosen) { $sourceText.Text = $chosen; Save-Config; Update-MainStandardStatus }
})
$tgtBrowse.Add_Click({
    $chosen = Browse-Folder 'Select the target catalog category folder' $targetText.Text
    if ($chosen) { $targetText.Text = $chosen; Save-Config; Update-MainStandardStatus }
})
$sourceText.Add_Leave({ if (-not $script:DashboardState.Busy) { Save-Config } })
$targetText.Add_Leave({ if (-not $script:DashboardState.Busy) { Save-Config } })
$sourceText.Add_TextChanged({
    if (-not $script:DashboardState.Busy) {
        $scanStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
        $scanStatusLabel.Text = 'Source changed. Click Refresh to update the displayed status.'
    }
})
$targetText.Add_TextChanged({
    if (-not $script:DashboardState.Busy) {
        $scanStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
        $scanStatusLabel.Text = 'Target changed. Click Refresh to focus the selected category.'
    }
})
$openMoveButton.Add_Click({
    if ($script:DashboardState.Busy) { return }
    # Opening the operation window never moves files. The existing inner button does.
    $moveSource.Text = $sourceText.Text.Trim()
    $moveTarget.Text = $targetText.Text.Trim()
    $statusLabel.Text = 'Ready'
    $moveForm.DialogResult = [System.Windows.Forms.DialogResult]::None
    try {
        [void]$moveForm.ShowDialog($script:MainForm)
    } finally {
        # Refresh the current catalog after returning, including partially completed moves.
        Update-MainStandardStatus -Quiet
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

$script:MainForm.Add_Shown({
    Update-MainStandardStatus -Quiet
})
try {
    [void]$script:MainForm.ShowDialog()
} finally {
    $refreshToolTip.Dispose()
    $moveForm.Dispose()
    $script:MainForm.Dispose()
}
