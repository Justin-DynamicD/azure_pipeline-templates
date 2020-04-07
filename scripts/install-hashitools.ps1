param (
  [string]$TargetPath = ".\",
  [switch]$AddToPath,
  [switch]$AddToPipelinePath,
  [string]$VersionControlFile = "modules.json",
  [string]$HashiURL = "https://releases.hashicorp.com",
  [System.Collections.ArrayList]$HashiTools = @(
    [PSCustomObject]@{
      Name = "packer"
      #Version = "1.4.2" #optionally supported verison here, must be a string
    }
    [PSCustomObject]@{ 
      Name = "terraform"
    }
    [PSCustomObject]@{ 
      Name = "vault"
    }
    [PSCustomObject]@{ 
      Name = "consul"
    }
    [PSCustomObject]@{ 
      Name = "nomad"
    }
  ),

  [System.Collections.ArrayList]$ExtraModules = @(
    [PSCustomObject]@{ 
      Owner = "rgl" 
      Repo = "packer-provisioner-windows-update"
      FileName = "packer-provisioner-windows-update.exe"
      DownloadName = "packer-provisioner-windows-update-windows.zip"
      Unzip = $true
    }
    [PSCustomObject]@{ 
      Owner = "gruntwork-io" 
      Repo = "terragrunt"
      FileName = "terragrunt.exe"
      DownloadName = "terragrunt_windows_amd64.exe"
      Unzip = $false
      #Mode = "remove" # mode allows uninstall to occur for depricated modules, "replace" forces repalcement, "upgrade" only rolls forward
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
    $toolCurr = & $toolPath --version
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

# there is no version control in most modules, so to combat this, this module
# maintains a json file in the install path with versions installed.
# This means outside tampering can lead to inaccurate versions installed,
# as such 'mode' can be set to replace in order to force updates or changes
# or remove to delete legacy entires.

$trackedModules = New-Object -TypeName "System.Collections.ArrayList"

# import file if it exists, else start with an empty list
$versionPath = "$($TargetPath.Trim("\"))\$($VersionControlFile)"
if (Test-Path -Path $versionPath -type leaf) {
  [System.Collections.ArrayList]$existingModules = Get-Content $versionPath | ConvertFrom-Json
}
else {
  $existingModules = New-Object -TypeName "System.Collections.ArrayList"
}

# looping all the defined modules
foreach ($module in $ExtraModules) {

  # If existing module is defined, grab its version
  $oldModule = ($existingModules | Where-Object { $_.Repo -eq $module.Repo })

  $availableVersions = (invoke-webrequest "https://api.github.com/repos/$($module.Owner)/$($module.Repo)/releases" -UseBasicParsing).Content | ConvertFrom-Json | Select-Object tag_name

  # If the mode is undefined, set to 'upgrade'
  if ($module.Mode) {
    $mode = $module.Mode.tolower()
  }
  else {
    $mode = "upgrade"
    $Module | Add-Member -Name 'Mode' -Type NoteProperty -Value "upgrade"
  }

  #If the version is undefined, set to latest
  Write-Output "Latest $($module.Repo) version: $($availableVersions.tag_name[0])"
  if ($module.Version) {
    If ($module.Version.tolower() -eq "latest" ) {
      $versionURL = "latest"
      $module.Version = $availableVersions.tag_name[0]
    }
    else {$versionURL = "tags/$($module.Version)"}
  }
  else {
    $versionURL = "latest"
    $Module | Add-Member -Name 'Version' -Type NoteProperty -Value $availableVersions.tag_name[0]
  }
  Write-Output "Requested $($module.Repo) version: $($module.Version)"
  Write-Output "Discovered $($module.Repo) version: $($oldmodule.Version)"
  #upgrade only
  If ($oldModule.Version -ne $module.Version) {
    [int]$intOld = [array]::indexof($availableVersions.tag_name,$oldModule.Version)
    [int]$intNew = [array]::indexof($availableVersions.tag_name,$Module.Version)
    If (($intNew -lt $intOld) -or $intOld -eq -1) {
      Write-Output "Existing version is older than desired, removing existing $($TargetPath)\$($module.FileName)"
      Remove-Item "$($TargetPath)\$($module.FileName)" -Force -ErrorAction SilentlyContinue | Out-Null
    }
  }
  
  # If a File is found, and a remove/replace is set, remove it
  $moduleName = $module.FileName
  if ((Test-Path "$($TargetPath)\$($moduleName)" -PathType Leaf) -and ("remove", "replace" -eq $mode)) {
    Write-Output "Mode is set to '$mode', removing existing $($TargetPath)\$($moduleName)"
    Remove-Item "$($TargetPath)\$($moduleName)" -Force
  }

  if ((!(Test-Path "$($TargetPath)\$($moduleName)" -PathType Leaf)) -and ($mode -ne "remove")) {  
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

  # Add module to json
  if ($mode -ne "remove") {
    $trackedModules += $module
  }
}

#save module list to json
$trackedModules | ConvertTo-Json | out-file $versionPath -Force