param([string]$NewName)

$ErrorActionPreference = 'Stop'

$OldName = 'CleanTemplate'
$OldContainerPrefix = 'clean-architecture'
$OldJwtName = 'ReminderService'
$RenameScripts = @('rename.sh', 'rename.ps1')
$ExcludeScripts = @(':!rename.sh', ':!rename.ps1')

if ($NewName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    [Console]::Error.WriteLine('Usage: powershell -ExecutionPolicy Bypass -File rename.ps1 <NewName>    e.g. ... rename.ps1 Acme.Billing')
    [Console]::Error.WriteLine("Renames the solution, then replaces the git history with a fresh 'git init'.")
    exit 1
}

Set-Location $PSScriptRoot

git grep -q $OldName '--' . $ExcludeScripts
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("No '$OldName' left to rename.")
    exit 1
}

if ("$(git status --porcelain '--' . $ExcludeScripts)$(git log --branches --not --remotes --oneline)$(git stash list)") {
    [Console]::Error.WriteLine('Commit and push all changes, and drop any stashes, first: the git history gets replaced.')
    exit 1
}

$NewContainerPrefix = $NewName.ToLowerInvariant()

if (Test-Path artifacts) {
    Remove-Item artifacts -Recurse -Force
}

$utf8WithoutAddedBom = New-Object System.Text.UTF8Encoding $false
foreach ($file in git grep -l -e $OldName -e $OldContainerPrefix -e $OldJwtName '--' . $ExcludeScripts) {
    $path = Join-Path $PSScriptRoot $file
    $text = $utf8WithoutAddedBom.GetString([IO.File]::ReadAllBytes($path))
    $text = $text.Replace($OldName, $NewName).Replace($OldContainerPrefix, $NewContainerPrefix).Replace($OldJwtName, $NewName)
    [IO.File]::WriteAllBytes($path, $utf8WithoutAddedBom.GetBytes($text))
}

Get-ChildItem -Recurse -Force -Filter "*$OldName*" |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object { Rename-Item -LiteralPath $_.FullName -NewName $_.Name.Replace($OldName, $NewName) }

dotnet format "$NewName.slnx" --diagnostics SA1210
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

foreach ($script in $RenameScripts) {
    if (Test-Path $script) {
        Remove-Item $script -Force
    }
}
Remove-Item .git -Recurse -Force
git init -q -b main

Write-Host "Renamed $OldName to $NewName and started a fresh git repository."
$manualNext = "Next: git add -A; git commit -m 'chore: initial commit'; git remote add origin <your-repo-url>"

if ([Console]::IsInputRedirected -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host $manualNext
    exit 0
}

$answer = Read-Host 'Create the initial commit and push to GitHub with the gh CLI? [y/N]'
if ($answer -notmatch '^[Yy]$') {
    Write-Host $manualNext
    exit 0
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    gh auth login
}

Write-Host "GitHub account: $(gh api user --jq .login)"

git add -A
git commit -q -m 'chore: initial commit'
gh repo create --source=. --remote=origin --push
