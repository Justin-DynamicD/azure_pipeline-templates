param (
  [string]$githubAPI = "https://api.github.com",
  [string]$SourceGithubOwner = "Justin-DynamicD",
  [string]$SourceGithubRepo = "azure_pipeline-templates",
  [string]$TargetGithubOwner = "Justin-DynamicD",
  [string]$TargetGithubRepo = "azure_pipeline-templates"

)

# Global Settings
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

# Check Online for latest version
$releaseVersions = ((invoke-webrequest "$($githubAPI)/repos/$($SourceGithubOwner)/$($SourceGithubRepo)/tags" -UseBasicParsing).Content | ConvertFrom-Json).name
[System.Collections.ArrayList]$formattedVersions = @()
$releaseVersions | ForEach-Object {
  try {
    [version]$updatedVer = ($_).trim("v")
    $formattedVersions.add($updatedVer) | Out-Null
  }
  catch{}
}
if ($formattedVersions.Count -gt 0) {
  $releaseLatest = [string]($formattedVersions | Sort-Object -Descending)[0]
}
else { [version]$releaseLatest = '0.0.0' }
Write-Output "Latest Online: $releaseLatest"

# Two vars are set: the first works within the job scope so the correct version gets installed.
# We also update the build number of the pipeline to contain this info during tagging
Write-Output "##vso[task.setvariable variable=releaseLatest;]$releaseLatest"
Write-Output "##vso[task.setvariable variable=releaseLatest;isOutput=true]$releaseLatest"

# Check build-repo for releases
$buildVersions = ((invoke-webrequest "$($githubAPI)/repos/$($TargetGithubOwner)/$($TargetGithubRepo)/tags" -UseBasicParsing).Content | ConvertFrom-Json).name
[System.Collections.ArrayList]$formattedVersions = @()
$buildVersions | ForEach-Object {
  try {
    [version]$updatedVer = ($_).trim("v")
    $formattedVersions.add($updatedVer) | Out-Null
  }
  catch{}
}
if ($formattedVersions.Count -gt 0) {
  $buildLatest = [string]($formattedVersions | Sort-Object -Descending)[0]
}
else { [version]$buildLatest = '0.0.0' }
Write-Output "Latest built: $buildLatest"

# Set variable baed on if latest has already been built
If ($buildLatest -match $releaseLatest) {
  Write-Output "build $releaseLatest already exists"
  Write-Output "##vso[task.setvariable variable=newBuild;]$false"
  Write-Output "##vso[task.setvariable variable=newBuild;isOutput=true]$false"
}
else {
  Write-Output "New build required"
  Write-Output "##vso[task.setvariable variable=newBuild;]$true"
  Write-Output "##vso[task.setvariable variable=newBuild;isOutput=true]$true"
}