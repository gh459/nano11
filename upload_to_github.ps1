# ============================================================================
# nano11 GitHub Uploader Script
# Uploads updated nano11builder.ps1, autounattend.xml, and README.md
# to https://github.com/gh459/nano11 via GitHub REST API
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Token,

    [string]$Owner = "gh459",
    [string]$Repo = "nano11",
    [string]$Branch = "main",
    [string]$CommitMessage = "fix: completely disable User Account Control (UAC) prompts (ConsentPromptBehaviorAdmin = 0)"
)

$ErrorActionPreference = 'Stop'

# 1. Resolve Token
if (-not $Token) {
    if ($env:GITHUB_PERSONAL_ACCESS_TOKEN) {
        $Token = $env:GITHUB_PERSONAL_ACCESS_TOKEN
    } else {
        $mcpConfig = "C:\Users\User\.gemini\config\mcp_config.json"
        if (Test-Path -LiteralPath $mcpConfig) {
            try {
                $json = Get-Content -LiteralPath $mcpConfig -Raw | ConvertFrom-Json
                if ($json.mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN) {
                    $Token = $json.mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN
                }
            } catch {}
        }
    }
}

if (-not $Token) {
    Write-Host ""
    Write-Host "[ERROR] GitHub Personal Access Token (PAT) is required." -ForegroundColor Red
    Write-Host "Please provide the token using one of the following methods:" -ForegroundColor Yellow
    Write-Host "  1. .\upload_to_github.ps1 -Token 'ghp_xxxxxxxxxxxx'" -ForegroundColor Cyan
    Write-Host "  2. `$env:GITHUB_PERSONAL_ACCESS_TOKEN = 'ghp_xxxxxxxxxxxx'" -ForegroundColor Cyan
    Write-Host "  3. Set 'GITHUB_PERSONAL_ACCESS_TOKEN' in C:\Users\User\.gemini\config\mcp_config.json" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$headers = @{
    "Authorization" = "Bearer $Token"
    "Accept"        = "application/vnd.github.v3+json"
    "User-Agent"    = "nano11-uploader"
}

Write-Host "Connecting to GitHub repository: $Owner/$Repo (branch: $Branch)..." -ForegroundColor Cyan

# 2. Get latest commit on target branch
try {
    $refUrl = "https://api.github.com/repos/$Owner/$Repo/git/ref/heads/$Branch"
    $refData = Invoke-RestMethod -Uri $refUrl -Headers $headers -Method Get
    $latestCommitSha = $refData.object.sha
    Write-Host "Current HEAD commit: $latestCommitSha" -ForegroundColor Gray
} catch {
    Write-Host "[ERROR] Failed to query repository: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 3. Create Blobs for updated files
$filesToUpload = @("nano11builder.ps1", "autounattend.xml", "README.md", "upload_to_github.ps1")
$treeEntries = [System.Collections.Generic.List[object]]::new()

foreach ($fileName in $filesToUpload) {
    $filePath = Join-Path -Path $scriptDir -ChildPath $fileName
    if (-not (Test-Path -LiteralPath $filePath)) {
        Write-Host "[WARNING] File not found: $filePath (skipping)" -ForegroundColor Yellow
        continue
    }

    Write-Host "Uploading blob: $fileName..." -ForegroundColor Cyan
    $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
    $base64Content = [System.Convert]::ToBase64String($fileBytes)

    $blobBody = @{
        content  = $base64Content
        encoding = "base64"
    } | ConvertTo-Json

    $blobUrl = "https://api.github.com/repos/$Owner/$Repo/git/blobs"
    $blobResponse = Invoke-RestMethod -Uri $blobUrl -Headers $headers -Method Post -Body $blobBody -ContentType "application/json"
    
    $treeEntries.Add(@{
        path = $fileName
        mode = "100644"
        type = "blob"
        sha  = $blobResponse.sha
    })
    Write-Host "  - Blob SHA: $($blobResponse.sha)" -ForegroundColor Green
}

if ($treeEntries.Count -eq 0) {
    Write-Host "[ERROR] No valid files found to upload." -ForegroundColor Red
    exit 1
}

# 4. Create Git Tree (with base_tree to preserve other files like LICENSE, oscdimg.exe)
Write-Host "Creating Git tree with base_tree: $latestCommitSha..." -ForegroundColor Cyan
$treeBody = @{
    base_tree = $latestCommitSha
    tree      = $treeEntries
} | ConvertTo-Json -Depth 5

$treeUrl = "https://api.github.com/repos/$Owner/$Repo/git/trees"
$treeResponse = Invoke-RestMethod -Uri $treeUrl -Headers $headers -Method Post -Body $treeBody -ContentType "application/json"
$newTreeSha = $treeResponse.sha
Write-Host "New Tree SHA: $newTreeSha" -ForegroundColor Green

# 5. Create Commit
Write-Host "Creating new commit..." -ForegroundColor Cyan
$commitBody = @{
    message = $CommitMessage
    tree    = $newTreeSha
    parents = @($latestCommitSha)
} | ConvertTo-Json

$commitUrl = "https://api.github.com/repos/$Owner/$Repo/git/commits"
$commitResponse = Invoke-RestMethod -Uri $commitUrl -Headers $headers -Method Post -Body $commitBody -ContentType "application/json"
$newCommitSha = $commitResponse.sha
Write-Host "New Commit SHA: $newCommitSha" -ForegroundColor Green

# 6. Update Branch Ref (Fast-forward push)
Write-Host "Updating branch ref '$Branch'..." -ForegroundColor Cyan
$updateRefBody = @{
    sha   = $newCommitSha
    force = $false
} | ConvertTo-Json

$updateRefUrl = "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/$Branch"
$updateRefResponse = Invoke-RestMethod -Uri $updateRefUrl -Headers $headers -Method Patch -Body $updateRefBody -ContentType "application/json"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "   Upload successful! Changes pushed to GitHub!          " -ForegroundColor Green
Write-Host "   Repository: https://github.com/$Owner/$Repo           " -ForegroundColor Green
Write-Host "   Commit:     https://github.com/$Owner/$Repo/commit/$newCommitSha" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
