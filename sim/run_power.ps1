# ============================================================================
# run_power.ps1 -- Phase 9: MT-09 power per variant (post-route, SAIF)
# ----------------------------------------------------------------------------
# Usage:
#   .\run_power.ps1                  # SAIF from tb_top golden run (preferred)
#   .\run_power.ps1 -DefaultActivity # fallback: Vivado default toggle rates
#   .\run_power.ps1 -Suffix _p75     # checkpoint set (default: _p75 signoff)
#
# SAIF source: sim\run_sim.ps1 -Tb tb_top_module -SaifPath <...>\tb_top.saif
# (whole golden regression trace: 4 variants driven with identical vectors).
#
# Outputs:
#   reports/power_<v><sfx>.rpt   raw report_power per variant
#   reports/power_results.csv/md dynamic/static/total mW + MT-05 overhead %
# ============================================================================
param(
    [switch]$DefaultActivity,
    [string]$Suffix = "_p75",
    [string]$Saif = "$env:LOCALAPPDATA\Temp\opencode\saif\tb_top.saif"
)
$ErrorActionPreference = "Stop"
$bin   = "D:\Xilinx\2025.2\Vivado\bin"
$sim   = $PSScriptRoot
$root  = "$sim\.."
$rep   = "$root\reports"
$stage = "$env:LOCALAPPDATA\Temp\opencode\vlsi_power"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item "$sim\power.tcl" $stage
foreach ($v in @("a","b","c1","c2")) {
    Copy-Item "$root\build\top_variant_$v$Suffix.dcp" $stage
}
if (-not (Test-Path "$stage\power.tcl")) { throw "staging failed" }

# Strip path: testbench instance path down to the variant wrapper, per UG900
# (read_saif -strip_path). Vivado's SAIF reader normalizes xsim's escaped
# generate/instance dot ("gA\.u_v") to a plain dot, so use the plain form.
# Empirically verified: this yields relative sim paths (u_top/...) and the
# highest net match count; the [Power 33-395] strip_path warning is cosmetic.
$strip = @{ a = "tb_top_module/h_A/gA.u_v"
            b = "tb_top_module/h_B/gB.u_v"
            c1 = "tb_top_module/h_C1/gC1.u_v"
            c2 = "tb_top_module/h_C2/gC2.u_v" }
$saifArg = if ($DefaultActivity) { "DEFAULT" } else { $Saif }
if (-not $DefaultActivity -and -not (Test-Path $Saif)) {
    throw "SAIF file not found: $Saif (run run_sim.ps1 -Tb tb_top_module -SaifPath ... first, or use -DefaultActivity)"
}

$rows = @()
Push-Location $stage
try {
    foreach ($v in @("a","b","c1","c2")) {
        Write-Output "=== power: variant $v (saif=$saifArg) ==="
        & "$bin\vivado.bat" -mode batch -nojournal -nolog -source power.tcl `
            -tclargs $v $strip[$v] $saifArg $Suffix 2>&1 |
            Tee-Object -FilePath "$root\build\vivado_power_$v$Suffix.out"
        if ($LASTEXITCODE -ne 0) { Write-Warning "power FAILED for $v"; continue }
        $log = Get-Content "$root\build\vivado_power_$v$Suffix.out" -Raw
        $applied = if ($log -match "SAIF_APPLIED v=$v applied=1") { "saif" }
                   elseif ($log -match "SAIF_APPLIED v=$v applied=0") { "default" }
                   else { "unknown" }
        # Honest annotation accounting: how many design nets the SAIF actually
        # hit (post-synth net-name absorption leaves the rest probabilistic).
        $annot = if ($log -match '(\d+)% of nets annotated') { [int]$Matches[1] } else { -1 }
        $matched = if ($log -match 'Design nets matched = (\d+) of (\d+)') {
                        "$($Matches[1])/$($Matches[2])" } else { "NA" }
        if (-not (Test-Path "$stage\power_$v$Suffix.rpt")) { Write-Warning "no power report for $v"; continue }
        Copy-Item "$stage\power_$v$Suffix.rpt" "$rep\" -Force
        $txt = Get-Content "$rep\power_$v$Suffix.rpt" -Raw
        # report_power summary labels: "Total On-Chip Power (W)" (no bare
        # "Total (W)" row exists in Vivado 2025.2 output).
        $dyn = if ($txt -match 'Dynamic \(W\)\s*\|\s*([0-9.Ee+-]+)') { [double]$Matches[1] } else { $null }
        $sta = if ($txt -match 'Device Static \(W\)\s*\|\s*([0-9.Ee+-]+)') { [double]$Matches[1] } else { $null }
        $tot = if ($txt -match 'Total On-Chip Power \(W\)\s*\|\s*([0-9.Ee+-]+)') { [double]$Matches[1] } else { $null }
        if ($null -eq $dyn -or $null -eq $tot) { Write-Warning "power parse failed for $v"; continue }
        $rows += [pscustomobject]@{
            variant    = $v
            activity   = $applied
            saif_annot_pct = $annot
            saif_matched   = $matched
            dynamic_mw = [math]::Round(1000.0*$dyn, 3)
            static_mw  = [math]::Round(1000.0*$sta, 3)
            total_mw   = [math]::Round(1000.0*$tot, 3)
        }
    }
}
finally { Pop-Location }

if ($rows.Count -gt 0) {
    $base = ($rows | Where-Object { $_.variant -eq "a" }).total_mw
    $out = foreach ($r in $rows) {
        $r | Add-Member -NotePropertyName overhead_pct -NotePropertyValue `
            ([math]::Round(100.0*($r.total_mw - $base)/$base, 1)) -PassThru
    }
    $out | Export-Csv "$rep\power_results$Suffix.csv" -NoTypeInformation
    Write-Output "=== power results ==="
    $out | Format-Table -AutoSize
} else {
    Write-Warning "no power results produced"
}
