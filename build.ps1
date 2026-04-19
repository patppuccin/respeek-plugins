#!/usr/bin/env pwsh
# respeek plugin build and release script

# Scipt Globals
$IsCI = $env:CI -eq "true"

# Helper functions
function Write-LogMessage {
    param(
        [ValidateSet("INF", "WRN", "ERR", "DBG")][string]$Level = "INF",
        [string]$Message
    )

    $ColorMap = @{
        "DBG" = "DarkGray"
        "INF" = "Blue"
        "WRN" = "Yellow"
        "ERR" = "Red"
    }

    Write-Host "$Level " -NoNewline -ForegroundColor $ColorMap[$Level]
    Write-Host $Message
}

# Execution Entrypoint

# Step 1: Perform pre-flight checks
$Missing = @()
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { $Missing += "cargo" }
if (-not (Get-Command go -ErrorAction SilentlyContinue)) { $Missing += "go" }
if (-not (Get-Command oras -ErrorAction SilentlyContinue)) { $Missing += "oras" }

if ($Missing.Count -gt 0) {
    Write-LogMessage -Level "ERR" -Message "Missing required tools: $($Missing -join ', ')"
    exit 1
}

# Step 2: Ensure registry.json exists
if (-not (Test-Path registry.json)) {
    '{"plugins":[]}' | Set-Content registry.json
}

# Step 3: Fetch the list of plugins from repo and registry

# Step 3.1: Fetch plugins list from registry
$Registry = Get-Content registry.json | ConvertFrom-Json
$RegistryPluginsList = $Registry.plugins | Select-Object -ExpandProperty name

# Step 3.2: Fetch plugins list from repo
$CurrentPluginsList = Get-ChildItem plugins -Directory | Select-Object -ExpandProperty Name

# Step 4: Identify dangling plugins and mark them as suspended

# Step 4.1: Build a list of plugin names from repo using plugin.json
$CurrentPluginNames = $CurrentPluginsList | ForEach-Object {
    $ManifestPath = "plugins/$_/plugin.json"
    if (Test-Path $ManifestPath) {
        (Get-Content $ManifestPath | ConvertFrom-Json).name
    }
}

# Step 4.2: Mark the plugins missing in the repo as suspended
foreach ($Name in $RegistryPluginsList) {
    if ($Name -notin $CurrentPluginNames) {
        $Entry = $Registry.plugins | Where-Object { $_.name -eq $Name }
        $Entry | Add-Member -NotePropertyName "status" -NotePropertyValue "suspended" -Force
        Write-LogMessage -Level "WRN" -Message "Plugin $Name no longer on disk — marking as suspended"
    }
}

# Step 5: Process plugins on the repo
foreach ($Plugin in $CurrentPluginsList) {    
    $PluginDir = "plugins/$Plugin"
    $ManifestPath = "$PluginDir/plugin.json"

    # Step 5.1: Skip processing if no plugin manifest exists
    if (-not (Test-Path $ManifestPath)) {
        Write-LogMessage -Level "WRN" -Message "No plugin.json found in $PluginDir, skipping"
        continue
    }

    # Step 5.2: Read the plugin manifest
    $Meta = Get-Content $ManifestPath | ConvertFrom-Json
    $Image = "ghcr.io/patppuccin/respeek-plugins/$($Meta.name)"

    # Step 5.3: Validate manifest fields & values
    $RequiredFields = @("name", "description", "version", "author", "license", "status")
    $MissingFields = @()
    foreach ($Field in $RequiredFields) {
        if (-not $Meta.$Field) { $MissingFields += $Field }
    }

    if ($MissingFields.Count -gt 0) {
        Write-LogMessage -Level "ERR" -Message "Plugin $Plugin missing required fields: $($MissingFields -join ', ')"
        continue
    }

    $ValidStatuses = @("active", "deprecated", "suspended", "beta", "experimental")
    if ($Meta.status -notin $ValidStatuses) {
        Write-LogMessage -Level "ERR" -Message "Plugin $Plugin has invalid status: $($Meta.status)"
        continue
    }

    # Step 5.4: Skip processing if version already released
    if ($IsCI) {
        oras manifest fetch "${Image}:$($Meta.version)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage -Level "DBG" -Message "Plugin $($Meta.name)@$($Meta.version) already in GHCR, skipping"
            continue
        }
    }
    else {
        $ExistingEntry = $Registry.plugins | Where-Object { $_.name -eq $Meta.name }
        if ($ExistingEntry -and $ExistingEntry.version -eq $Meta.version) {
            Write-LogMessage -Level "DBG" -Message "Plugin $($Meta.name)@$($Meta.version) already released, skipping"
            continue
        }
    }

    # Step 5.5: Update registry entry
    $Url = "ghcr.io/patppuccin/respeek-plugins/$($Meta.name):$($Meta.version)"
    $Meta | Add-Member -NotePropertyName "url" -NotePropertyValue $Url -Force
    $Registry.plugins = @($Registry.plugins | Where-Object { $_.name -ne $Meta.name }) + $Meta

    # step 5.6: Skip build process if status is suspended (only update registry)
    if ($Meta.status -eq "suspended") {
        Write-LogMessage -Level "WRN" -Message "Plugin $Plugin is suspended — updating registry only"
        continue
    }

    # Step 5.7: Build and push the plugin
    Write-LogMessage -Message "Building $Plugin@$($Meta.version)..."
    Push-Location $PluginDir
    try {
        # Step 5.7.1: Build the plugin
        if (Test-Path "Cargo.toml") {
            $env:RESPEEK_PLUGIN_VERSION = $Meta.version
            cargo build --target wasm32-wasip1 --release
            Copy-Item "target/wasm32-wasip1/release/$($Meta.name).wasm" "$($Meta.name).wasm"
        }
        elseif (Test-Path "go.mod") {
            $env:GOOS = "wasip1"
            $env:GOARCH = "wasm"
            go build -ldflags "-X main.version=$($Meta.version)" -o "$($Meta.name).wasm" .
        }
        else {
            Write-LogMessage -Level "ERR" -Message "No supported build file found in $PluginDir"
            continue
        }

        # Step 5.7.2: Push the plugin to GHCR
        if ($IsCI) {
            $Annotations = @(
                "--annotation", "org.opencontainers.image.title=$($Meta.name)",
                "--annotation", "org.opencontainers.image.description=$($Meta.description)",
                "--annotation", "org.opencontainers.image.version=$($Meta.version)",
                "--annotation", "org.opencontainers.image.licenses=$($Meta.license)",
                "--annotation", "org.opencontainers.image.vendor=$($Meta.author)",
                "--annotation", "org.opencontainers.image.source=https://github.com/patppuccin/respeek-plugins"
            )
            oras push @Annotations "${Image}:$($Meta.version)" "$($Meta.name).wasm:application/vnd.respeek.plugin.wasm"
            oras push @Annotations "${Image}:latest" "$($Meta.name).wasm:application/vnd.respeek.plugin.wasm"
            Write-LogMessage -Message "Released $($Meta.name)@$($Meta.version)"
        }
        else {
            Write-LogMessage -Level "DBG" -Message "Skipping GHCR push for $($Meta.name)@$($Meta.version) — not in CI"
        }
    }
    finally {
        Pop-Location
    }
}

# Step 6: Update the registry
$Registry | ConvertTo-Json -Depth 10 | Set-Content registry.json
Write-LogMessage -Message "Registry synced."