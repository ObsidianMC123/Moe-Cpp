$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$bin=Join-Path $root 'custom-bin'
foreach($folder in @('Lang','Icons','Templates','Help','Fonts')){
  $source=Join-Path $root $folder
  if(Test-Path $source){
    $dest=Join-Path $bin $folder
    if(!(Test-Path $dest)){New-Item -ItemType Directory -Path $dest | Out-Null}
    Copy-Item -Path (Join-Path $source '*') -Destination $dest -Recurse -Force -ErrorAction Stop
    Write-Output ('COPIED_RESOURCES='+$folder)
  }
}
$lang=Join-Path $bin 'Lang\English.lng'
if(!(Test-Path $lang)){throw 'Language pack missing'}
Write-Output ('LANG_FILE='+$lang)
Write-Output ('HASH_EQUALS_SOURCE='+((Get-FileHash $lang).Hash -eq (Get-FileHash (Join-Path $root 'Lang\English.lng')).Hash))
