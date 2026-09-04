param([Parameter(Mandatory=$true)][string]$Path)
$acl = Get-Acl -LiteralPath $Path
$bad = $acl.Access | Where-Object {
  $_.AccessControlType -eq 'Allow' -and
  (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadData) -ne 0) -and
  $_.IdentityReference.Value -match 'Everyone|Users|Authenticated Users'
}
if ($bad) { Write-Error 'credential file is readable by a shared Windows principal'; exit 64 }
exit 0
