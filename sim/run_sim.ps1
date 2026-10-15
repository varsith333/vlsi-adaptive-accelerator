# ============================================================================
# run_sim.ps1 — Compile RTL + a testbench, elaborate, run simulation
# Usage:  .\run_sim.ps1 -Tb tb_mac_unit
#         .\run_sim.ps1 -Tb tb_top_module -XsimArgs @("+CFG=2")
# Logs:   build\<Tb>.compile.log, build\<Tb>.elab.log, build\<Tb>.run.log
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Tb,
    [string[]]$XsimArgs = @(),
    [switch]$NoRtl,
    [string]$SaifPath = ""
)
$ErrorActionPreference = "Stop"
$bin   = "D:\Xilinx\2025.2\Vivado\bin"
$root  = "$PSScriptRoot\.."          # vlsi-adaptive-accelerator
$rtlDir = "$root\rtl"
$tbDir  = "$root\tb"
$build  = "$root\build"
Set-Location $build

$rtlFiles = @("mac_unit","input_buffer","output_buffer","accelerator_core",
              "reliability_monitor","error_counter","fault_detector",
              "adaptive_controller","recovery_controller","top_module",
              "top_variant_a","top_variant_b","top_variant_c1","top_variant_c2")

if (-not $NoRtl) {
    foreach ($f in $rtlFiles) {
        & "$bin\xvlog.bat" --sv "$rtlDir\$f.sv" *>&1 |
            Out-File "$build\compile_rtl.log" -Append
        if ($LASTEXITCODE -ne 0) { throw "xvlog FAILED on rtl/$f.sv (see compile_rtl.log)" }
    }
}
& "$bin\xvlog.bat" --sv "$tbDir\$Tb.sv" *>&1 | Out-File "$build\$Tb.compile.log"
if ($LASTEXITCODE -ne 0) { throw "xvlog FAILED on tb/$Tb.sv (see $Tb.compile.log)" }

# SAIF dumping needs full signal visibility -> elaborate with -debug all when
# a SAIF trace was requested (otherwise keep the fast default snapshot).
$debugArgs = if ($SaifPath -ne "") { @("-debug", "all") } else { @() }
& "$bin\xelab.bat" $Tb -s "${Tb}_snap" @debugArgs *>&1 | Out-File "$build\$Tb.elab.log"
if ($LASTEXITCODE -ne 0) { throw "xelab FAILED (see $Tb.elab.log)" }

# Optional SAIF capture for MT-09 power analysis: runs the same snapshot with
# a tcl batch that opens/closes the SAIF dump around the whole run.
# xsim loads -tclbatch via an unquoted `source <path>`: backslashes are eaten
# by tcl and the first space splits the command, so the batch file must sit at
# a space-free forward-slash path (the project dir has spaces).
if ($SaifPath -ne "") {
    $sp = $SaifPath -replace '\\', '/'
    $saifDir = Split-Path $sp -Parent
    if ($saifDir -and -not (Test-Path $saifDir)) { New-Item -ItemType Directory -Force -Path $saifDir | Out-Null }
    $saifTcl = (($env:LOCALAPPDATA -replace '\\', '/') + "/Temp/opencode/saif/saif_run.tcl")
    # UG900: a bare pattern logs only that scope's own signals; the recursive
    # form [get_objects -r *] is required to dump the whole hierarchy.
    @("open_saif {$sp}", "log_saif [get_objects -r *]", "run all", "close_saif") |
        Out-File ($saifTcl -replace '/', '\') -Encoding ascii
    & "$bin\xsim.bat" "${Tb}_snap" -tclbatch $saifTcl @XsimArgs *>&1 | Tee-Object "$build\$Tb.run.log"
    if (-not (Test-Path $SaifPath) -or (Get-Item $SaifPath).Length -lt 1024) {
        throw "SAIF file missing or empty: $SaifPath (see $Tb.run.log)"
    }
    Write-Output "=== SAIF written: $SaifPath ($((Get-Item $SaifPath).Length) bytes) ==="
} else {
    & "$bin\xsim.bat" "${Tb}_snap" -R @XsimArgs *>&1 | Tee-Object "$build\$Tb.run.log"
}
if ($LASTEXITCODE -ne 0) { throw "xsim FAILED (see $Tb.run.log)" }
Write-Output "=== run_sim.ps1 done: $Tb ==="
