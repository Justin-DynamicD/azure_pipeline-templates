param (
  [string]$TargetPath = ".\",
  [switch]$AddToPath,
  [switch]$AddToPipelinePath,
  [string]$HashiURL = "https://releases.hashicorp.com",
  [Array]$HashiTools = @(
    [PSCustomObject]@{
      Name = "packer"
      Version = "1.4.2"
    }
    [PSCustomObject]@{ 
      Name = "terraform"
      Version = "0.12.5"
    }
  ),

  [Array]$ExtraModules = @(
    [PSCustomObject]@{ 
      Owner = "jetbrains-infra" 
      Repo = "packer-builder-vsphere"
      FileName = "packer-builder-vsphere-iso.exe"
      DownloadName = "packer-builder-vsphere-iso.exe"
      Unzip = $false
      Version = "v2.3"
    }
    [PSCustomObject]@{ 
      Owner = "jetbrains-infra" 
      Repo = "packer-builder-vsphere"
      FileName = "packer-builder-vsphere-clone.exe"
      DownloadName = "packer-builder-vsphere-clone.exe"
      Unzip = $false
      Version = "v2.3"
    }
    [PSCustomObject]@{ 
      Owner = "rgl" 
      Repo = "packer-provisioner-windows-update"
      FileName = "packer-provisioner-windows-update.exe"
      DownloadName = "packer-provisioner-windows-update-windows.zip"
      Unzip = $true
      Version = "v0.7.1"
    }
    [PSCustomObject]@{ 
      Owner = "gruntwork-io" 
      Repo = "terragrunt"
      FileName = "terragrunt.exe"
      DownloadName = "terragrunt_windows_amd64.exe"
      Unzip = $false
      Version = "v0.19.11"
    }
  )
)

# Global Settings
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

###
#
# Configure Working Directory
#
###

If (!(Test-Path -Path $TargetPath)) {
  New-Item $TargetPath -ItemType Directory | Out-Null
}

$array = $env:Path.split(";").trimend("\")
If (($array -notcontains $TargetPath.trimend("\")) -and $AddToPath) {
  Write-Output "AddToPath is set, updating system path"
  $CurrentPath = (Get-Itemproperty -path 'hklm:\system\currentcontrolset\control\session manager\environment' -Name Path).Path
  $NewPath = $CurrentPath + ";$TargetPath"
  Set-ItemProperty -path 'hklm:\system\currentcontrolset\control\session manager\environment' -Name Path -Value $NewPath
  $env:path = $env:path.trimend(";") + ";$TargetPath"
}

If (($array -notcontains $TargetPath.trimend("\")) -and $AddToPipelinePath) {
  Write-Output "AddToPipelinePath is set, updating environment vars"
  Write-Output "##vso[task.prependpath]$TargetPath"
  $env:path = $env:path.trimend(";") + ";$TargetPath"
}

###
#
# Core Tools Download
#
###

foreach ($tool in $HashiTools) {

  # Check for packer versions online and compare with requested version if provided
  $toolUrl = "$($HashiURL)/$($tool.Name)"
  $results = (Invoke-WebRequest $toolUrl -UseBasicParsing).links
  $toolVersions = ($results.href | Where-Object { $_ -like "/$($tool.Name)/*" })
  $trimmedVersions = ($toolVersions | Sort-object -Descending).TrimStart("/$($tool.Name)/").TrimEnd("/")
  [System.Collections.ArrayList]$formattedVersions = @()
  $trimmedVersions | ForEach-Object {
    try {
      $formattedVersions.add([version]$_) | Out-Null
    }
    catch{}
  }
  $toolLatest = [string]($formattedVersions | Sort-Object -Descending)[0]
  Write-Output "Latest $($tool.Name) version: $toolLatest"
  if ($tool.Version) {
    if ($toolVersions -notcontains "/$($tool.Name)/$($tool.Version)/") {
      Write-Error "Desired version $($tool.Version) does not exist online!" -ErrorAction stop
    }
    $toolReq = $tool.Version
  }
  else {
    $toolReq = $toolLatest
  }
  Write-Output "Requested $($tool.Name) version: $toolReq"

  #Check for the locally installed tool and validate version
  $toolPath = "$($TargetPath)\$($tool.Name).exe"
  if (Test-Path $toolPath -PathType Leaf) {
    $toolCurr = & $toolPath -version
    $toolCurr = $toolCurr.split('\n')[0] # grab only the first line
    $toolCurr = $toolCurr.split('(')[0].trim() # drop hash info nomad uses
    $toolCurr = $toolCurr.split("v")[-1] # split by version, grab the last entry
    Write-Output "Discovered $($tool.Name): $toolCurr"
    $toolInst = $true
  }
  Else {
    Write-Output "$($tool.Name) not Found"
    $toolInst = $false
  }

  #Download and expand if needed
  if (!$toolInst -or ($toolInst -and ($toolCurr -ne $toolReq))) {
    $zipName = "$($tool.Name)_$($toolReq)_windows_amd64.zip"
    Write-Output "Downloading zip: $zipName"
    Invoke-WebRequest "$($toolUrl)/$($toolReq)/$zipName" -UseBasicParsing -OutFile ".\$zipName"
    Write-Output "Extracting $($tool.Name)"
    Expand-Archive ".\$zipName" -DestinationPath $TargetPath -Force
    Remove-Item ".\$($zipName)" -Force
  }
}

###
#
# Extra Module Download
#
###

# looping all the defined modules
foreach ($module in $ExtraModules) {

  #If the version is undefined, set to latest
  if ($module.Version) {
    $versionURL = "tags/$($module.Version)"
  }
  else {
    $versionURL = "latest"
  }

  # there is no version control in most modules, so the best we can do is see if a file exists
  $moduleName = $module.FileName
  if (!(Test-Path "$($TargetPath)\$($moduleName)" -PathType Leaf)) {  
    try {
      $results = (invoke-webrequest "https://api.github.com/repos/$($module.Owner)/$($module.Repo)/releases/$($versionURL)" -UseBasicParsing).Content | ConvertFrom-Json
      $asset = $results.assets | Where-Object { $_.name -eq $module.DownloadName }
      Write-Output "Downloading asset: $($asset.name)"
      Invoke-WebRequest $asset.browser_download_url -UseBasicParsing -OutFile $asset.name
      if ($module.Unzip) {
        Write-Output "Extracting Zip"
        Expand-Archive ".\$($asset.name)" -DestinationPath $TargetPath -Force
        Remove-Item ".\$($asset.name)" -Force
      }
      else {
        Write-Output "Moving file"
        Move-Item -Path ".\$($asset.name)" -Destination "$($TargetPath)\$($moduleName)"
      }
    }
    catch {
      Write-Error "unable to find $($module.Repo) version $($module.Version)" -ErrorAction Stop
    }
  }
}
