# Take repo.csv as input and output the result to success.csv and fail.csv
# !! Header is required !!
# !! This script is NOT fully tested, use this at you own risk !!
# Sample csv content with one repo:
# RepoName,fromPath,toPath
# Sample Repo,group/sample-repo.git,new_group/sample-repo.git

# edit these values
$global:private_token = ""
$global:fromServerUrl = ""
$global:toServerUrl = ""

function Git-RetryOnFail {
    param (
        $Cmd,
        $MaxRetry = 5
    )

    if ($Cmd -eq $null) {
        Get-Command -Name Git-RetryOnFail -Syntax
        throw "Invalid usage on Git-RetryOnFail"
    }

    if ($MaxRetry -le 0) {
        $MaxRetry = 1
    }

    $RetryCount = 0

    while ($RetryCount -le $MaxRetry) {
        if ($RetryCount -gt 0) {
            Write-Host "Attempt Retry $RetryCount/$MaxRetry..."
        }
        Invoke-Expression $Cmd
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Success ($LASTEXITCODE)"
            return
        }
        $RetryCount += 1
    }
    Write-Host "Fail ($LASTEXITCODE), Cmd=($Cmd)"
    throw "Max Retry reached"
}

function GetOrCreateGroup {
    param (
        $groupNameSpace
    )

    if ([string]::IsNullOrEmpty($groupNameSpace)) {
        return
    }

    # check if group name space exist
    $(Invoke-RestMethod -Uri "$toServerUrl/api/v4/groups?search=$groupNameSpace&private_token=$global:private_token" -Method GET) |
    ForEach {
        if ($_.full_path -eq $groupNameSpace) {
            Write-Host "Found "$_.full_path", id="$_.id
            $groupId = $_.id
        }
    }

    # new group to create
    if ([string]::IsNullOrEmpty($groupId)) {
        # check parent group
        $parentGroupId = $null
        $parentGroupName = $(Split-Path $groupNameSpace -Parent).Replace("\", "/")
        if (![string]::IsNullOrEmpty($parentGroupName)) {
            $parentGroupId = GetOrCreateGroup $parentGroupName
        }

        $groupNameBase = Split-Path $groupNameSpace -Leaf
        $body = @{
            name = $groupNameBase
            path = $groupNameBase 
        }
        if (![string]::IsNullOrEmpty($parentGroupId)) {
            $body.parent_id = [int]$parentGroupId
        }

        if ([string]::IsNullOrEmpty($groupId)) {
            Write-Host "Creating group $groupNameSpace"
            $groupId = $(Invoke-RestMethod -Uri "$toServerUrl/api/v4/groups?private_token=$global:private_token" -Method POST -Body $body).id
        }
    }
    return $groupId
}

function GetOrCreateProject {
    param (
        $projectPath
    )

    if ([string]::IsNullOrEmpty($projectPath)) {
        return
    }

    Write-Host "Creating project $projectPath"

    $projectPathBase = [System.IO.Path]::GetFileNameWithoutExtension($projectPath)
    $group = $null
    $group = $(Split-Path $projectPath -Parent).Replace("\", "/")

    if (![string]::IsNullOrEmpty($group)) {
        $groupId = GetOrCreateGroup $group
    }

    $projectNamespace = $(Join-Path -Path $group -ChildPath $projectPathBase).Replace("\", "/")
    $projectId = $(Invoke-RestMethod -Uri "$toServerUrl/api/v4/projects?search=$projectNamespace&search_namespaces=true&private_token=$global:private_token" -Method GET).id

    if ([string]::IsNullOrEmpty($projectId)) {
        Invoke-RestMethod -Uri "$toServerUrl/api/v4/projects?private_token=$global:private_token" -Method POST -Body @{
            path = $projectPathBase
            namespace_id = [int]$groupId
        }
        Write-Host "Project create success"
    }
    else {
        Write-Host "Existing project found"
    }
}

function MigrateRepo {
    param (
        $RepoName,
        $fromPath,
        $toPath,
        $fromServerUrl,
        $toServerUrl
    )
    
    $item = "" | Select-Object RepoName,fromPath,toPath
    $item.RepoName = $RepoName
    $item.fromPath = $fromPath
    $item.toPath = $toPath

    $fromUrl = "$global:fromServerUrl$fromPath"
    $toUrl = "$global:toServerUrl$toPath"

    try {
        Write-Host "Migrate [$RepoName]..." -ForegroundColor black -BackgroundColor green
        Write-Host "From: $fromUrl"
        Write-Host "To: $toUrl"

        # Check if folder already exist
        $folderPath = Split-Path $fromUrl -leaf
        if (!$(Test-Path -Path $folderPath)) {
            Git-RetryOnFail "git clone --bare $fromUrl"
        }
        cd $folderPath
        Git-RetryOnFail "git fetch --all"
        Git-RetryOnFail "git lfs fetch --all"
        
        GetOrCreateProject $toPath > $null
        Git-RetryOnFail "git config http.version HTTP/1.1"
        try {
            # push only when there are lfs files
            if (![string]::IsNullOrEmpty($(git lfs ls-files))) {
                Git-RetryOnFail "git lfs push --all $toUrl"
            }
        }
        catch {
            Write-Host "Error when pusing lfs to mirror host ($LASTEXITCODE). Will push to mirror anyway as it may fix the problem for next iteration."
        }
        finally {
            Git-RetryOnFail "git push --mirror $toUrl"
        }
        
        Write-Host "Migrate Process Complete Successfully" -ForegroundColor green -BackgroundColor white

        $global:SuccessList += $item
    }
    catch {
        Write-Warning $Error[0]
        Write-Host "Migrate Process Terminated ($LASTEXITCODE)" -ForegroundColor red -BackgroundColor white
        $global:FailList += $item
    }
}

$global:SuccessList = @()
$global:FailList = @()
$progressCount = 0
$oriWindowTitle = $host.ui.RawUI.WindowTitle

$repoList = Import-Csv -Path '.\repoList.csv' | Select-Object
$totalCount = $repoList.Count
Write-Host "Total Repo: $totalCount"

$root_dir = $(pwd).path
try {
    $repoList | ForEach {
        $progressCount += 1
        # uncomment this part to test one line
        #if ($progressCount -gt 1) {
        #    throw "end test"
        #}
        $host.ui.RawUI.WindowTitle = “Migrating...$progressCount/$totalCount”
        MigrateRepo $_.RepoName $_.fromPath $_.toPath
        Write-Host "Batch Process Complete Successfully" -ForegroundColor green -BackgroundColor white
        cd $root_dir
    }
}
catch {
    cd $root_dir
    $host.ui.RawUI.WindowTitle = $oriWindowTitle
    Write-Warning $Error[0]
    Write-Host "Batch Process Terminated ($LASTEXITCODE)" -ForegroundColor red -BackgroundColor white
}

$successCount = $global:SuccessList.Count
$failCount = $global:FailList.Count
Write-Host "Success $successCount/$totalCount"
Write-Host "Fail $failCount/$totalCount"

$global:SuccessList | Select-Object | ConvertTo-CSV -NoTypeInformation -Delimiter "," | % {$_ -replace '"',''} | Out-File -FilePath "$root_dir\success.csv"
$global:FailList | Select-Object | ConvertTo-CSV -NoTypeInformation -Delimiter "," | % {$_ -replace '"',''} | Out-File -FilePath "$root_dir\fail.csv"
