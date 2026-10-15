# ============================================================================
# run_synth.ps1 -- Phase 8: synthesis + implementation of all 4 variants
# ----------------------------------------------------------------------------
# Usage:
#   .\run_synth.ps1                 # all variants: a, b, c1, c2
#   .\run_synth.ps1 -Variants "a"   # subset
#
# IMPORTANT: this project lives under ".../Default Project/" and Vivado's file
# commands truncate paths at spaces (verified: read_verilog fails with
# "File 'C:/Users/user/Documents/Default' does not exist").  Therefore the
# whole Vivado workspace is STAGED into a space-free temp directory, Vivado
# runs there, and the reports/checkpoints are copied back into the project.
#
# Flow per variant: read 14 RTL files -> constraints (100 MHz) -> synth ->
# opt -> place -> route -> reports -> checkpoint (non-project batch, UG835).
# Part: xc7a35ticsg324-1L (Arty A7-35T).
#
# Outputs (copied back into the project):
#   build/vivado_run_<v>.out     console log per variant
#   reports/util_<v>.rpt         utilization report
#   reports/timing_<v>.rpt       timing summary
#   reports/drc_<v>.rpt          DRC report
#   build/top_variant_<v>.dcp    post-route checkpoint
#   reports/synth_results.csv    aggregated: LUT/FF/BRAM/DSP/WNS/TNS/path/Fmax
#   reports/synth_results.md     same, human-readable
# ============================================================================
param(
    [string]$Variants = "a,b,c1,c2",
    [string]$PeriodTag = "100"     # "100" = 10 ns target, "75" = 13.333 ns signoff
)
$ErrorActionPreference = "Stop"
$bin   = "D:\Xilinx\2025.2\Vivado\bin"
$sim   = $PSScriptRoot
$root  = "$sim\.."
$rep   = "$root\reports"
$bld   = "$root\build"
$stage = "$env:LOCALAPPDATA\Temp\opencode\vlsi_synth"
$sfx   = if ($PeriodTag -eq "100") { "" } else { "_p$PeriodTag" }

# --------------------------- stage a clean workspace -----------------------
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$stage\sim" | Out-Null
New-Item -ItemType Directory -Force -Path "$stage\rtl" | Out-Null
Copy-Item "$root\rtl\*.sv" "$stage\rtl\"
Copy-Item "$sim\synth_impl.tcl"    "$stage\sim\"
Copy-Item "$sim\constraints_100mhz.xdc" "$stage\sim\"
Copy-Item "$sim\constraints_75mhz.xdc"  "$stage\sim\"
if (-not (Test-Path "$stage\rtl\mac_unit.sv")) { throw "staging failed" }
New-Item -ItemType Directory -Force -Path $rep | Out-Null
New-Item -ItemType Directory -Force -Path $bld | Out-Null
Write-Output "=== staged workspace: $stage ==="

$results = @()
Push-Location $stage     # vivado.log / vivado.jou land here (space-free)
try {
    foreach ($v in ($Variants.Split(",") | ForEach-Object { $_.Trim() })) {
        Write-Output "=== synth+impl: top_variant_$v @ ${PeriodTag} MHz-tag ==="
        & "$bin\vivado.bat" -mode batch -source "$stage\sim\synth_impl.tcl" -tclargs $v $PeriodTag 2>&1 |
            Tee-Object -FilePath "$bld\vivado_run_$v$sfx.out"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "vivado FAILED for variant $v (see build\vivado_$v$sfx.out)"
            continue
        }
        $sum = Select-String -Path "$bld\vivado_run_$v$sfx.out" -Pattern "SYNTH_SUM .*" |
               ForEach-Object { $_.Line } | Select-Object -Last 1
        if (-not $sum) {
            Write-Warning "no SYNTH_SUM line for variant $v"
            continue
        }
        $f = @{}
        foreach ($kv in ($sum -split "\s+" | Where-Object { $_ -match "=" })) {
            $p = $kv.Split("=")
            $f[$p[0]] = $p[1]
        }
        if ($f["lut"] -eq "NA") {
            Write-Warning "utilization parse failed for variant $v"
            continue
        }
        $wns   = [double]$f["wns"]
        $dpath = [double]$f["dpath"]      # = period - wns (critical path delay, ns)
        $fmax  = if ($dpath -gt 0) { [math]::Round(1000.0 / $dpath, 1) } else { 0.0 }
        $results += [pscustomobject]@{
            variant   = $f["variant"]
            period_ns = if ($PeriodTag -eq "75") { 13.333 } else { 10.0 }
            lut       = $f["lut"]
            ff        = $f["ff"]
            bram      = $f["bram"]
            dsp       = $f["dsp"]
            wns_ns    = [math]::Round($wns, 3)
            tns_ns    = [math]::Round([double]$f["tns"], 3)
            path_ns   = [math]::Round($dpath, 3)
            fmax_mhz  = $fmax
            crit_from = $f["crit_from"]
            crit_to   = $f["crit_to"]
        }
    }
}
finally {
    Pop-Location
}

# --------------------- copy artifacts back into the project ----------------
if (Test-Path "$stage\reports") {
    Copy-Item "$stage\reports\*" $rep -Force -ErrorAction SilentlyContinue
}
if (Test-Path "$stage\build") {
    Copy-Item "$stage\build\*.dcp" $bld -Force -ErrorAction SilentlyContinue
}

if ($results.Count -gt 0) {
    $results | Export-Csv "$rep\synth_results$sfx.csv" -NoTypeInformation
    $md = @("# Synthesis + implementation results (Phase 8)", "",
            "Part: xc7a35ticsg324-1L (Arty A7-35T), constraint tag $PeriodTag,",
            "non-project batch flow, post-route numbers.", "",
            "| variant | period (ns) | LUT | FF | BRAM | DSP | WNS (ns) | TNS (ns) | critical path (ns) | max freq (MHz) | critical path from | to |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|")
    foreach ($r in $results) {
        $md += "| $($r.variant) | $($r.period_ns) | $($r.lut) | $($r.ff) | $($r.bram) | $($r.dsp) | $($r.wns_ns) | $($r.tns_ns) | $($r.path_ns) | $($r.fmax_mhz) | $($r.crit_from) | $($r.crit_to) |"
    }
    $md += @("", "WNS/TNS from post-route setup analysis; max freq = 1000 / critical path delay.",
             "Detailed reports: reports/util_<v>.rpt, reports/timing_<v>.rpt, reports/timing_path_<v>.rpt, reports/drc_<v>.rpt.")
    Set-Content "$rep\synth_results$sfx.md" $md
    Write-Output "=== aggregated -> reports\synth_results$sfx.csv / synth_results$sfx.md ==="
    $results | Format-Table -AutoSize
} else {
    Write-Warning "no successful variant runs - nothing aggregated"
}
