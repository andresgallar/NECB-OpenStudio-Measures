param(
    [string]$ZipPath,
    [string]$MeasureDirectory = (Join-Path $env:USERPROFILE 'OpenStudio\Measures\create_necb_reference')
)

# Extract directly to My Measures, without an intermediate long folder path.
# Existing files, including user-edited example OSMs, are never overwritten.
$ErrorActionPreference = 'Stop'
if (-not $ZipPath) {
    $ZipPath = Join-Path $PSScriptRoot 'create_necb_reference_openstudio_3.11.zip'
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        $ZipPath = Join-Path $PSScriptRoot '..\dist\create_necb_reference_openstudio_3.11.zip'
    }
}
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$MeasureDirectory = [IO.Path]::GetFullPath($MeasureDirectory)
$checksumPath = $ZipPath + '.sha256'
if (-not (Test-Path -LiteralPath $checksumPath)) {
    throw "Keep the release .zip.sha256 file beside the ZIP: $checksumPath"
}
$expected = (Get-Content -LiteralPath $checksumPath -Raw).Trim().Split(' ')[0]
if ((Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash -ne $expected) {
    throw 'The ZIP checksum does not match the release checksum.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
$restored = 0
try {
    foreach ($entry in $archive.Entries) {
        $prefix = 'create_necb_reference/'
        if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal)) {
            throw "Unexpected archive entry: $($entry.FullName)"
        }
        $relative = $entry.FullName.Substring($prefix.Length)
        if (-not $relative -or $entry.FullName.EndsWith('/')) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $MeasureDirectory $relative))
        if (-not $target.StartsWith($MeasureDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Archive entry escapes the measure directory: $($entry.FullName)"
        }
        if ([IO.File]::Exists($target)) { continue }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        $restored++
    }
} finally {
    $archive.Dispose()
}

$resources = Join-Path $MeasureDirectory 'resources'
$manifest = Get-Content -LiteralPath (Join-Path $resources 'dependency_manifest.json') -Raw | ConvertFrom-Json
$modified = @()
foreach ($property in $manifest.files.psobject.Properties) {
    $file = Join-Path $resources $property.Name
    if (-not [IO.File]::Exists($file)) { throw "Dependency still missing: $($property.Name)" }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $property.Value) {
        $modified += $property.Name
    }
}
Write-Output "Restored $restored missing files to $MeasureDirectory"
Write-Output "All $($manifest.files.psobject.Properties.Name.Count) bundled dependency files are present."
foreach ($file in $modified) {
    Write-Warning "Preserved an existing file that differs from the release: $file"
}
