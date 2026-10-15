# ============================================================================
# run_fi.ps1 - Fault-injection campaign runner (V-07) + CSV aggregation
# ----------------------------------------------------------------------------
# Usage:
#   .\run_fi.ps1 -Smoke                    # quick mechanics check (small N)
#   .\run_fi.ps1                           # full campaign: 4 cfg x 4 cls x 5
#                                          #   seeds x 1000 injections = 80k
#   .\run_fi.ps1 -Ninj 500 -Seeds 1,2      # custom subset
#
# Compiles RTL + fault_injector + tb_fi_campaign once (xelab snapshot), then
# runs every (cfg, class, seed) combination, reusing the snapshot.
# Outputs: build\fi_log.csv        one row per injection
#          build\fi_runs.txt       one FI_RUN summary line per run
#          build\fi_run_<tag>.log  full xsim log per run
#          reports\fi_results.csv  aggregated per (cfg, class) across seeds
#          reports\fi_results.md   same, human-readable
# ============================================================================
param(
    [int]$Ninj = 1000,
    [string]$Seeds = "1,2,3,4,5",
    [string]$Cfgs = "a,b,c1,c2",
    [string]$Cls = "1,2,3,4",
    [switch]$Smoke
)
$ErrorActionPreference = "Stop"
$bin   = "D:\Xilinx\2025.2\Vivado\bin"
$root  = "$PSScriptRoot\.."
$rtl   = "$root\rtl"
$tbd   = "$root\tb"
$build = "$root\build"
$rep   = "$root\reports"
Set-Location $build

if ($Smoke) {
    $Ninj  = 12
    $Seeds = "1"
    $Cfgs  = "c1,a"
    $Cls   = "1,2,3,4"
}
$seedArr = $Seeds.Split(",") | ForEach-Object { [int]$_.Trim() }
$cfgArr  = $Cfgs.Split(",")  | ForEach-Object { $_.Trim() }
$clsArr  = $Cls.Split(",")   | ForEach-Object { [int]$_.Trim() }

$rtlFiles = @("mac_unit","input_buffer","output_buffer","accelerator_core",
              "reliability_monitor","error_counter","fault_detector",
              "adaptive_controller","recovery_controller","top_module",
              "top_variant_a","top_variant_b","top_variant_c1","top_variant_c2")

# ------------------------------ compile ------------------------------------
Write-Output "=== compiling RTL + FI campaign testbench ==="
foreach ($f in $rtlFiles) {
    & "$bin\xvlog.bat" --sv "$rtl\$f.sv" *>&1 | Out-File "$build\compile_rtl.log" -Append
    if ($LASTEXITCODE -ne 0) { throw "xvlog FAILED on rtl/$f.sv (see compile_rtl.log)" }
}
Remove-Item "$build\tb_fi_campaign.compile.log" -ErrorAction SilentlyContinue
foreach ($f in @("fault_injector","tb_fi_campaign")) {
    & "$bin\xvlog.bat" --sv "$tbd\$f.sv" *>&1 |
        Out-File "$build\tb_fi_campaign.compile.log" -Append
    if ($LASTEXITCODE -ne 0) { throw "xvlog FAILED on tb/$f.sv (see tb_fi_campaign.compile.log)" }
}
& "$bin\xelab.bat" tb_fi_campaign -s fi_snap *>&1 |
    Out-File "$build\tb_fi_campaign.elab.log"
if ($LASTEXITCODE -ne 0) { throw "xelab FAILED (see tb_fi_campaign.elab.log)" }

# ------------------------------ run matrix ---------------------------------
Remove-Item "$build\fi_log.csv"    -ErrorAction SilentlyContinue
Remove-Item "$build\fi_runs.txt"   -ErrorAction SilentlyContinue
$ok = 0; $failed = @()
foreach ($cfg in $cfgArr) {
    foreach ($c in $clsArr) {
        foreach ($seed in $seedArr) {
            $tag = "${cfg}_c${c}_s${seed}"
            Write-Output "=== FI run $tag (NINJ=$Ninj) ==="
            # xsim's loader splits command-line values at '=', so the run
            # parameters reach the TB through fi_args.txt:
            # "<cfg_code> <cls> <seed> <ninj>"   0=a 1=b 2=c1 3=c2
            $cfgIdx = switch ($cfg) { "a" {0} "b" {1} "c1" {2} default {3} }
            Set-Content "$build\fi_args.txt" "$cfgIdx $c $seed $Ninj"
            $out = & "$bin\xsim.bat" fi_snap -R *>&1
            $out | Out-File "$build\fi_run_$tag.log"
            $runLine = $out | Where-Object { $_ -like "FI_RUN *" } | Select-Object -First 1
            $done    = $out | Where-Object { $_ -like "FI_CAMPAIGN: DONE*" } | Select-Object -First 1
            if ($runLine) { Add-Content "$build\fi_runs.txt" $runLine }
            if ($done)    { $ok++ } else { $failed += $tag; Write-Warning "run $tag did NOT complete" }
        }
    }
}
Write-Output "=== runs completed: $ok / $($cfgArr.Count * $clsArr.Count * $seedArr.Count) ==="
if ($failed.Count -gt 0) { Write-Warning "failed runs: $($failed -join ', ')" }

# ---------------------------- aggregation ----------------------------------
New-Item -ItemType Directory -Force -Path $rep | Out-Null
$rows = @()
if (Test-Path "$build\fi_log.csv") {
    Get-Content "$build\fi_log.csv" | ForEach-Object {
        $p = $_.Split(",")
        if ($p.Length -eq 16 -and $p[0] -ne "cfg") {
            $rows += [pscustomobject]@{
                cfg=$p[0]; cls=[int]$p[1]; seed=[int]$p[2]; inj=[int]$p[3]
                t0=[int]$p[4]; bit=[int]$p[5]; idx=[int]$p[6]; stgt=[int]$p[7]
                flag=[int]$p[8]; det_lat=[int]$p[9]; wrong=[int]$p[10]
                fw_lat=[int]$p[11]; rec_lat=[int]$p[12]; hang=[int]$p[13]
                fbw=[int]$p[14]; outcome=$p[15]
            }
        }
    }
}

$agg = @()
foreach ($g in ($rows | Group-Object cfg, cls)) {
    $n      = $g.Count
    $nop    = @($g.Group | Where-Object { $_.outcome -eq "noplace" }).Count
    $val    = $n - $nop
    $det    = @($g.Group | Where-Object { $_.flag -eq 1 }).Count
    $wrong  = @($g.Group | Where-Object { $_.wrong -gt 0 }).Count
    $dwr    = @($g.Group | Where-Object { $_.outcome -eq "detected_wrong" }).Count
    $hang   = @($g.Group | Where-Object { $_.hang -eq 1 }).Count
    $mask   = @($g.Group | Where-Object { $_.outcome -eq "masked" }).Count
    $fbw    = @($g.Group | Where-Object { $_.fbw -eq 1 }).Count
    $mt01   = if ($val -gt 0) { 100.0 * $fbw / $val } else { 0.0 }
    $dets   = @($g.Group | Where-Object { $_.det_lat -ge 0 } | ForEach-Object { $_.det_lat })
    $recs   = @($g.Group | Where-Object { $_.rec_lat -ge 0 } | ForEach-Object { $_.rec_lat })
    $avgd   = if ($dets.Count) { ($dets | Measure-Object -Average).Average } else { 0.0 }
    $avgr   = if ($recs.Count) { ($recs | Measure-Object -Average).Average } else { 0.0 }
    $parts  = $g.Name -split ",\s*"
    $agg   += [pscustomobject]@{
        cfg=$parts[0]; cls=[int]$parts[1]; n=$n; valid=$val
        MT01_pct=[math]::Round($mt01,1)
        detected=$det; wrong=$wrong; det_wrong=$dwr
        hang=$hang; masked=$mask; noplace=$nop
        avg_det_lat=[math]::Round($avgd,1); avg_rec_lat=[math]::Round($avgr,1)
    }
}
$agg = $agg | Sort-Object { $_.cfg }, { $_.cls }

$agg | Export-Csv "$rep\fi_results.csv" -NoTypeInformation
$md = @("# FI campaign results (aggregated across seeds)", "",
        "Run: ``run_fi.ps1`` - NINJ=$Ninj per (cfg,cls,seed); seeds: $Seeds", "",
        "| cfg | cls | n | valid | MT-01 % | detected | wrong | det+wrong | hang | masked | noplace | avg det_lat | avg rec_lat |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|")
foreach ($r in $agg) {
    $md += "| $($r.cfg) | $($r.cls) | $($r.n) | $($r.valid) | $($r.MT01_pct) | $($r.detected) | $($r.wrong) | $($r.det_wrong) | $($r.hang) | $($r.masked) | $($r.noplace) | $($r.avg_det_lat) | $($r.avg_rec_lat) |"
}
$md += @("", "Raw per-injection data: ``build/fi_log.csv`` (copied to ``reports/fi_raw.csv``).",
         "Class map: 1=F-01 acc flip, 2=F-02 obuf flip, 3=F-03 storage flip, 4=F-04 FSM force.",
         "MT-01 = 100 * (flags raised before first wrong delivery) / valid injections.")
Set-Content "$rep\fi_results.md" $md
Copy-Item "$build\fi_log.csv" "$rep\fi_raw.csv" -Force -ErrorAction SilentlyContinue

Write-Output "=== aggregated -> reports\fi_results.csv / fi_results.md ==="
$agg | Format-Table -AutoSize
