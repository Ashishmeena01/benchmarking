$ErrorActionPreference = "Stop"

# ==================================================
# CONFIGURATION
# ==================================================

$Root = $PSScriptRoot
$Port = 8080

$ConcurrencyLevels = @(10, 50, 100, 250, 500, 1000)
$Runs = 3
$Duration = "15s"

$ResultsDir = Join-Path $Root "results"
$BenchmarkJs = Join-Path $Root "benchmark.js"

# Leave null to detect k6 automatically.
# Or set the exact path, for example:
# $K6 = "C:\Program Files\k6\k6.exe"
$K6 = "C:\Program Files\k6\k6.exe"

# Go
$GoDir = Join-Path $Root "go-server"
$GoExe = Join-Path $GoDir "go-server.exe"

# Rust
$RustDir = Join-Path $Root "rust-server"
$RustExe = Join-Path $RustDir "target\release\rust-server.exe"

# C++
$CppDir = Join-Path $Root "cpp-server"
$CppSource = Join-Path $CppDir "iocp_server.cpp"
$CppExe = Join-Path $CppDir "cpp-server.exe"

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# ==================================================
# FIND / VALIDATE K6
# ==================================================

if (-not $K6) {
    $k6Command = Get-Command k6.exe -ErrorAction SilentlyContinue
    if (-not $k6Command) {
        $k6Command = Get-Command k6 -ErrorAction SilentlyContinue
    }
    if ($k6Command) {
        $K6 = $k6Command.Source
    }
}

if (-not $K6 -or -not (Test-Path $K6)) {
    throw "k6.exe not found. Set the absolute path in the `$K6 configuration variable."
}

Write-Host "Using k6: $K6" -ForegroundColor Green

# ==================================================
# CHECK REQUIRED TOOLS AND FILES
# ==================================================

foreach ($program in @("go", "cargo", "g++")) {
    if (-not (Get-Command $program -ErrorAction SilentlyContinue)) {
        throw "$program is missing from PATH."
    }
}

foreach ($path in @($BenchmarkJs, $GoDir, $RustDir, $CppDir, $CppSource)) {
    if (-not (Test-Path $path)) {
        throw "Required path not found: $path"
    }
}

# Ensure port is available before starting.
$listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listeners) {
    throw "Port $Port is already in use. Stop the existing server first."
}

# ==================================================
# BUILD SERVERS
# ==================================================

Write-Host "`n========== BUILDING SERVERS ==========" -ForegroundColor Cyan

Write-Host "`nBuilding Go..." -ForegroundColor Yellow
Push-Location $GoDir
try {
    & go build -o $GoExe .
    if ($LASTEXITCODE -ne 0) {
        throw "Go build failed."
    }
}
finally {
    Pop-Location
}
Write-Host "Go build successful." -ForegroundColor Green

Write-Host "`nBuilding Rust..." -ForegroundColor Yellow
& cargo build --release --manifest-path (Join-Path $RustDir "Cargo.toml")
if ($LASTEXITCODE -ne 0) {
    throw "Rust build failed."
}
Write-Host "Rust build successful." -ForegroundColor Green

Write-Host "`nBuilding C++ using MinGW..." -ForegroundColor Yellow
& g++ -O2 -std=c++20 -pthread $CppSource -lws2_32 -o $CppExe
if ($LASTEXITCODE -ne 0) {
    throw "C++ build failed."
}
Write-Host "C++ build successful." -ForegroundColor Green

foreach ($exe in @($GoExe, $RustExe, $CppExe)) {
    if (-not (Test-Path $exe)) {
        throw "Executable missing after build: $exe"
    }
}

# ==================================================
# BENCHMARK FUNCTION
# ==================================================

$script:Summary = @()

function Run-ServerBenchmark {
    param(
        [string]$Name,
        [string]$Executable,
        [string]$WorkingDirectory
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BENCHMARKING $Name" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    for ($run = 1; $run -le $Runs; $run++) {
        foreach ($concurrency in $ConcurrencyLevels) {

            Write-Host "`n$Name | Run $run | VUs $concurrency" -ForegroundColor Yellow

            $TestName = "$Name-vus-$concurrency-run-$run"
            $Stdout = Join-Path $ResultsDir "$TestName-server-output.log"
            $Stderr = Join-Path $ResultsDir "$TestName-server-error.log"
            $JsonFile = Join-Path $ResultsDir "$TestName.json"
            $LogFile = Join-Path $ResultsDir "$TestName.log"
            $K6ErrorLog = Join-Path $ResultsDir "$TestName-k6-error.log"

            # Remove stale output from an earlier run.
            foreach ($file in @($Stdout, $Stderr, $JsonFile, $LogFile, $K6ErrorLog)) {
                if (Test-Path $file) {
                    Remove-Item $file -Force
                }
            }

            $serverProcess = $null

            try {
                # Start the server.
                $serverProcess = Start-Process `
                    -FilePath $Executable `
                    -WorkingDirectory $WorkingDirectory `
                    -PassThru `
                    -RedirectStandardOutput $Stdout `
                    -RedirectStandardError $Stderr

                # Wait for HTTP readiness.
                $ready = $false

                for ($i = 0; $i -lt 50; $i++) {
                    if ($serverProcess.HasExited) {
                        throw "$Name server exited unexpectedly. Check $Stderr"
                    }

                    try {
                        $response = Invoke-WebRequest `
                            -Uri "http://127.0.0.1:$Port/" `
                            -TimeoutSec 2 `
                            -UseBasicParsing

                        if (
                            $response.StatusCode -eq 200 -and
                            $response.Content.Trim() -eq "Hello World"
                        ) {
                            $ready = $true
                            break
                        }
                    }
                    catch {
                        Start-Sleep -Milliseconds 200
                    }
                }

                if (-not $ready) {
                    throw "$Name server did not become ready. Check $Stdout and $Stderr"
                }

                Write-Host "Server ready." -ForegroundColor Green

                # Build one quoted command-line string for Start-Process.
                # This avoids PowerShell treating k6 stderr warnings as terminating errors.
                $k6ArgumentLine = 'run -e VUS={0} -e DURATION={1} --summary-export="{2}" "{3}"' -f `
                    $concurrency, $Duration, $JsonFile, $BenchmarkJs

                $k6Process = Start-Process `
                    -FilePath $K6 `
                    -ArgumentList $k6ArgumentLine `
                    -WorkingDirectory $Root `
                    -NoNewWindow `
                    -Wait `
                    -PassThru `
                    -RedirectStandardOutput $LogFile `
                    -RedirectStandardError $K6ErrorLog

                $k6ExitCode = $k6Process.ExitCode

                if ($k6ExitCode -ne 0) {
                    Write-Warning "k6 exited with code $k6ExitCode. See $K6ErrorLog"
                }

                if (-not (Test-Path $JsonFile)) {
                    Write-Warning "No k6 summary was generated for $TestName. Skipping this result."
                    continue
                }

                # Read k6 summary.
                $data = Get-Content $JsonFile -Raw | ConvertFrom-Json

                $requests = $data.metrics.http_reqs
                $latency = $data.metrics.http_req_duration

                if (-not $requests -or -not $latency) {
                    Write-Warning "Required k6 metrics are missing in $JsonFile. Skipping this result."
                    continue
                }

                $failedRequestRate = 0.0
                if ($data.metrics.http_req_failed) {
                    $failedRequestRate = [double]$data.metrics.http_req_failed.value
                }

                $checkFailures = 0
                if ($data.metrics.checks) {
                    $checkFailures = [int]$data.metrics.checks.fails
                }

                $result = [PSCustomObject]@{
                    Server            = $Name
                    Run               = $run
                    Concurrency       = $concurrency
                    Requests          = [long]$requests.count
                    RPS               = [math]::Round($requests.rate, 2)
                    Avg_ms            = [math]::Round($latency.avg, 3)
                    Median_ms         = [math]::Round($latency.med, 3)
                    P90_ms            = [math]::Round($latency.'p(90)', 3)
                    P95_ms            = [math]::Round($latency.'p(95)', 3)
                    P99_ms            = [math]::Round($latency.'p(99)', 3)
                    Max_ms            = [math]::Round($latency.max, 3)
                    FailedRequest_pct = [math]::Round($failedRequestRate * 100, 3)
                    CheckFailures     = $checkFailures
                    K6ExitCode        = $k6ExitCode
                }

                $script:Summary += $result

                Write-Host "`nResult:" -ForegroundColor Green
                $result | Format-List

                if ($failedRequestRate -gt 0 -or $checkFailures -gt 0) {
                    Write-Warning "This run had failed HTTP requests or failed checks. Do not treat it as a clean performance result."
                }

                if ($serverProcess.HasExited) {
                    Write-Warning "$Name server exited during the test. Inspect $Stderr"
                }
            }
            finally {
                # Always stop the server after each test.
                if ($serverProcess -and -not $serverProcess.HasExited) {
                    Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
                    $serverProcess.WaitForExit()
                }

                Start-Sleep -Seconds 2
            }
        }
    }
}

# ==================================================
# RUN ALL BENCHMARKS
# ==================================================

Run-ServerBenchmark -Name "Go" -Executable $GoExe -WorkingDirectory $GoDir
Run-ServerBenchmark -Name "Rust" -Executable $RustExe -WorkingDirectory $RustDir
Run-ServerBenchmark -Name "Cpp" -Executable $CppExe -WorkingDirectory $CppDir

# ==================================================
# EXPORT RESULTS
# ==================================================

$CsvFile = Join-Path $ResultsDir "all-results.csv"

$script:Summary |
    Export-Csv -Path $CsvFile -NoTypeInformation

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "BENCHMARKS FINISHED" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

$script:Summary |
    Format-Table Server, Run, Concurrency, Requests, RPS, Avg_ms, P95_ms, P99_ms, FailedRequest_pct, CheckFailures -AutoSize

Write-Host "`nCSV saved at:" -ForegroundColor Green
Write-Host $CsvFile

Write-Host "`nIndividual JSON results and logs saved in:" -ForegroundColor Green
Write-Host $ResultsDir
