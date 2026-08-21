param(
    [string]$TargetTest = "All"
)

function Get-Report-LegacyFullRAM {
    param(
        [string]$reportName,
        [int]$period,
        [bool]$betaVersion,
        [string]$format = "application/json",
        [string]$accessToken,
        [System.IO.FileInfo]$tempFile
    )

    try {
        $uriReport = "https://graph.microsoft.com/v1.0/reports/${reportName}(period='D$period')?`$format=$format"
        $currentUri = $uriReport
        
        if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force }

        # Create an empty List to hold all data
        $allData = [System.Collections.Generic.List[object]]::new()

        do {
            $response = Invoke-WebRequest -Method Get -Uri $currentUri -Headers @{ "Authorization" = "Bearer $accessToken" } -ErrorAction Stop
            $parsedData = $response.Content | ConvertFrom-Json
            
            if ($null -ne $parsedData.value) {
                $allData.AddRange($parsedData.value)
            }
            
            $currentUri = $parsedData.'@odata.nextLink'
            
        } while (-not [string]::IsNullOrWhiteSpace($currentUri))
        
        # The critical moment: convert 300,000 objects into a single JSON blob, then write to file
        $allData | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $tempFile -Encoding utf8
        
        return $null
    }
    catch {
        Write-Warning "Legacy Full RAM Error: $($_.Exception.Message)"
    }
}

function Get-Report-Legacy {
    param(
        [string]$reportName,
        [int]$period,
        [bool]$betaVersion,
        [string]$format = "application/json",
        [string]$accessToken,
        [System.IO.FileInfo]$tempFile
    )

    try {
        $uriReport = "https://graph.microsoft.com/v1.0/reports/${reportName}(period='D$period')?`$format=$format"
        $currentUri = $uriReport
        
        if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force }

        "[" | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
        $isFirstPage = $true

        do {
            $response = Invoke-WebRequest -Method Get -Uri $currentUri -Headers @{ "Authorization" = "Bearer $accessToken" } -ErrorAction Stop
            $parsedData = $response.Content | ConvertFrom-Json
            
            if ($null -ne $parsedData.value) {
                $jsonChunk = $parsedData.value | ConvertTo-Json -Depth 10 -Compress
                
                if ($jsonChunk -match '^\[(.*)\]$') {
                    $jsonChunk = $matches[1]
                }

                if (-not [string]::IsNullOrWhiteSpace($jsonChunk)) {
                    if (-not $isFirstPage) {
                        "," | Out-File -FilePath $tempFile -Append -Encoding utf8 -NoNewline
                    }
                    $jsonChunk | Out-File -FilePath $tempFile -Append -Encoding utf8 -NoNewline
                    $isFirstPage = $false
                }
            }
            $currentUri = $parsedData.'@odata.nextLink'
            
        } while (-not [string]::IsNullOrWhiteSpace($currentUri))
        
        "]" | Out-File -FilePath $tempFile -Append -Encoding utf8 -NoNewline
        return $null
    }
    catch {
        Write-Warning "Legacy Error: $($_.Exception.Message)"
    }
}

function Get-Report {
    param(
        [string]$reportName,
        [int]$period,
        [bool]$betaVersion,
        [ValidateSet("text/csv", "application/json", "csv", "json")]
        [string]$format = "text/csv",
        [string]$accessToken,
        [System.IO.FileInfo]$tempFile
    )

    try {
        $graphVersion = if ($betaVersion) { "beta" } else { "v1.0" }
        $apiFormat = if ($format -in @("json", "application/json")) { "application/json" } else { "text/csv" }
        $uriReport = "https://graph.microsoft.com/$graphVersion/reports/${reportName}(period='D$period')?`$format=$apiFormat"
        $headers = @{ "Authorization" = "Bearer $accessToken" }

        Write-Information "Getting report from: $uriReport"
        if ($format -in @("json", "application/json")) {
            Write-Information "Output format: JSON"
            $currentUri = $uriReport
            $isSuccess = $false
            $errorMessage = ""
            $httpStatusCode = 200
            $maxRetries = 5

            $fileStream = $null
            $jsonWriter = $null
            try {
                $fileStream = [System.IO.FileStream]::new($tempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 65536)
                $jsonWriter = [System.Text.Json.Utf8JsonWriter]::new($fileStream)
            
                $jsonWriter.WriteStartArray()

                do {
                    $response = $null
                    $retryCount = 0
                    $requestSuccess = $false

                    while (-not $requestSuccess) {
                        try {
                            $response = Invoke-WebRequest -Method Get -Uri $currentUri -Headers $headers -ErrorAction Stop
                            $requestSuccess = $true
                        }
                        catch {
                            $rawErrorMessage = if ($null -ne $_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
                            $apiErrorMessage = "No additional details."

                            if (-not [string]::IsNullOrWhiteSpace($rawErrorMessage)) {
                                try {
                                    $parsedError = $rawErrorMessage | ConvertFrom-Json -ErrorAction Stop
                                    if ($null -ne $parsedError.error) {
                                        $apiErrorMessage = "[$($parsedError.error.code)] $($parsedError.error.message)"
                                    }
                                    else {
                                        $apiErrorMessage = $rawErrorMessage
                                    }
                                }
                                catch {
                                    $apiErrorMessage = $rawErrorMessage
                                }
                            }

                            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 500 }

                            if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599)) {
                                if ($retryCount -ge $maxRetries) {
                                    $errorMessage = "Max retries reached. Graph API Error: $apiErrorMessage"
                                    $httpStatusCode = 502
                                    break 
                                }

                                $retryCount++
                                $retryAfterHeader = $_.Exception.Response.Headers.RetryAfter
                                $waitTime = if ($null -ne $retryAfterHeader -and $null -ne $retryAfterHeader.Delta) { [int]$retryAfterHeader.Delta.Value.TotalSeconds } else { [math]::Pow(2, $retryCount) }
                    
                                Write-Warning "Transient error ($statusCode). Retrying in $waitTime seconds..."
                                Start-Sleep -Seconds $waitTime
                            }
                            else {
                                $errorMessage = "Graph API Failed with HTTP $statusCode. Details: $apiErrorMessage"
                                $httpStatusCode = $statusCode
                                break
                            }
                        }
                    }

                    if (-not $requestSuccess) {
                        break
                    }

                    if ($response.StatusCode -eq 200) {
                        $doc = $null
                        try {
                            $doc = [System.Text.Json.JsonDocument]::Parse($response.Content)
                            $root = $doc.RootElement

                            foreach ($prop in $root.EnumerateObject()) {
                                if ($prop.Name -eq "value" -and $prop.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                                    foreach ($item in $prop.Value.EnumerateArray()) {
                                        $item.WriteTo($jsonWriter)
                                    }
                                    $jsonWriter.Flush()
                                    break
                                }
                            }

                            $currentUri = $null
                            foreach ($prop in $root.EnumerateObject()) {
                                if ($prop.Name -eq "@odata.nextLink") {
                                    $currentUri = $prop.Value.GetString()
                                    Write-Information "Next link found: $currentUri"
                                    break
                                }
                            }
                        }
                        catch {
                            $errorMessage = "Failed to parse API response or write data: $($_.Exception.Message)"
                            $httpStatusCode = 500
                            Write-Warning $errorMessage
                            break
                        }
                        finally {
                            if ($null -ne $doc) { 
                                $doc.Dispose() 
                            }
                        }
                    }
                    else {
                        $errorMessage = "Unexpected Success Response: $($response.StatusCode)"
                        $httpStatusCode = 500
                        break
                    }
                } while (-not [string]::IsNullOrWhiteSpace($currentUri))
    
                if ([string]::IsNullOrEmpty($errorMessage)) {
                    $jsonWriter.WriteEndArray()
                    $jsonWriter.Flush()
                    $isSuccess = $true
                }
            }
            catch {
                $errorMessage = "Internal error while processing the report: $($_.Exception.Message)"
                $httpStatusCode = 500
                Write-Warning "Error in Get-Report: $errorMessage"
            }
            finally {
                if ($null -ne $jsonWriter) { $jsonWriter.Dispose() }
                if ($null -ne $fileStream) { $fileStream.Dispose() }

                if (-not $isSuccess -and (Test-Path $tempFile)) {
                    Write-Warning "Process incomplete. Attempting to delete malformed file: $tempFile"
                    try {
                        Remove-Item -Path $tempFile -Force -ErrorAction Stop
                    }
                    catch {
                        Write-Warning "Could not delete temp file (it may be locked): $($_.Exception.Message)"
                    }
                }
            }

            if ($isSuccess) {
                Write-Information "Report successfully downloaded to: $tempFile"
                return $null
            }
            else {
                Write-Warning "Failed to download report after $maxRetries attempts. Last error: $errorMessage"
                return [ordered]@{
                    errorcode = "Exception in get report data"
                    message   = $errorMessage
                    status    = $httpStatusCode
                }
            }
        }
        else {
            Write-Information "Output format: CSV"
            Invoke-WebRequest -Method Get -Uri $uriReport -Headers $headers -OutFile $tempFile -ErrorAction Stop
            return $null
        }
    }
    catch {
        $ex = $_.Exception
        Write-warning "Error in getting report"
        Write-Information $ex
        $statusCode = if ($null -ne $ex.Response) { [int]$ex.Response.StatusCode } else { 500 }
        Write-Warning "HTTP Status: $statusCode"
        $return = [ordered]@{
            errorcode = "Exception in get report data"
            message   = "$ex"
            status    = $statusCode
        }
        return $return
    }
}

# 1. Function to create a fake error with the exact same structure as Microsoft Graph
function MockWebErrorToThrow {
    param([int]$StatusCode, [string]$JsonMessage, [int]$RetryAfter = 0)
    
    $responseObj = [PSCustomObject]@{
        StatusCode = $StatusCode
        Headers    = [PSCustomObject]@{
            RetryAfter = [PSCustomObject]@{
                Delta = [PSCustomObject]@{ TotalSeconds = $RetryAfter }
            }
        }
    }
    
    $ex = [System.Exception]::new("Mock Web Error")
    $ex | Add-Member -MemberType NoteProperty -Name "Response" -Value $responseObj
    
    $errorRecord = [System.Management.Automation.ErrorRecord]::new($ex, "MockError", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($JsonMessage)
    
    throw $errorRecord
}

# 2. Impersonate the system's Invoke-WebRequest
function Invoke-WebRequest {
    param($Method, $Uri, $Headers, $ErrorAction, $OutFile)
    
    $global:MockCallCount++
    # Suppress per-call Mock API output in Stress Test mode to avoid cluttering and slowing down the console
    if ($global:MockScenario -ne "StressTest") {
        Write-Host "[MOCK API] Called count $global:MockCallCount (URI: $Uri)" -ForegroundColor DarkGray
    }

    switch ($global:MockScenario) {
        "HappyPath" {
            if ($global:MockCallCount -eq 1) {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": [{"name": "User 1"}], "@odata.nextLink": "mock://page2"}' }
            }
            else {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": [{"name": "User 2"}]}' }
            }
        }
        "Retry429" {
            if ($global:MockCallCount -le 2) {
                MockWebErrorToThrow -StatusCode 429 -JsonMessage '{"error":{"code":"Throttled","message":"Too many requests"}}' -RetryAfter 1
            }
            else {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": [{"name": "User Success after Retry"}]}' }
            }
        }
        "Fatal401" {
            MockWebErrorToThrow -StatusCode 401 -JsonMessage '{"error":{"code":"InvalidToken","message":"Lifetime validation failed"}}'
        }
        "BadJson" {
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": [ This is broken and unreadable JSON. ]}' }
        }
        "CSV_Success" {
            Set-Content -Path $OutFile -Value "Name,Email`nMockUser,mock@abc.com"
            return $null
        }
        "RetryFail" {
            MockWebErrorToThrow -StatusCode 502 -JsonMessage '{"error":{"code":"BadGateway","message":"Server is busy"}}'
        }
        "CSV_Fail" {
            MockWebErrorToThrow -StatusCode 403 -JsonMessage '{"error":{"code":"Forbidden","message":"Access Denied"}}'
        }
        "FileSystemFail" {
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": [{"name": "User 1"}]}' }
        }
        "StressTest" {
            # Simulate 1 page (1000 records) of about 100KB
            $mockItem = '{"reportRefreshDate":"2026-08-16","userPrincipalName":"MSCloud1@domain-brabrabra-qa.com","displayName":"MSCloud1","isDeleted":false,"deletedDate":null,"hasExchangeLicense":false,"hasOneDriveLicense":false,"hasSharePointLicense":false,"hasSkypeForBusinessLicense":false,"hasYammerLicense":false,"hasTeamsLicense":false,"exchangeLastActivityDate":null,"oneDriveLastActivityDate":null,"sharePointLastActivityDate":null,"skypeForBusinessLastActivityDate":null,"yammerLastActivityDate":null,"teamsLastActivityDate":null,"exchangeLicenseAssignDate":null,"oneDriveLicenseAssignDate":null,"sharePointLicenseAssignDate":null,"skypeForBusinessLicenseAssignDate":null,"yammerLicenseAssignDate":null,"teamsLicenseAssignDate":null,"assignedProducts":[]}'
            $mockArray = 1..100 | ForEach-Object { $mockItem }
            $jsonContent = "[" + ($mockArray -join ",") + "]"
            
            # Loop through 300 pages = simulate 300,000 records (file size approx 30MB+)
            if ($global:MockCallCount -lt 3000) {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": ' + $jsonContent + ', "@odata.nextLink": "mock://page' + ($global:MockCallCount + 1) + '"}' }
            }
            else {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value": ' + $jsonContent + '}' }
            }
        }
    }
}

# Helper function to measure time and memory, clearing garbage before running
function Measure-MockTest {
    param([scriptblock]$TestBlock)
    
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    
    # Capture values before starting
    $startMem = $process.WorkingSet64
    $startCpu = $process.TotalProcessorTime
    $gc0Start = [System.GC]::CollectionCount(0)
    
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    & $TestBlock
    $timer.Stop()
    
    # Must refresh Process data after the run finishes, otherwise the CPU value will be stale
    $process.Refresh() 
    
    # Capture values after finishing
    $endMem = $process.WorkingSet64
    $endCpu = $process.TotalProcessorTime
    $gc0End = [System.GC]::CollectionCount(0)
    
    $memDiffMB = [math]::Round(($endMem - $startMem) / 1MB, 2)
    $cpuTimeMs = [math]::Round(($endCpu - $startCpu).TotalMilliseconds, 2)
    
    return @{ 
        TimeMs    = $timer.ElapsedMilliseconds; 
        MemDiffMB = $memDiffMB;
        CpuTimeMs = $cpuTimeMs;
        GC0       = ($gc0End - $gc0Start)
    }
}

# ======================================================================
# 3. Runner system (controls isolated process execution)
# ======================================================================
if ($TargetTest -eq "All" -and $false) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Starting Isolated Process test run (guarantees net RAM measurement)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $scriptPath = $PSCommandPath
    $psExe = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh" } else { "powershell" }

    $legacyResultFile = "$env:TEMP\benchmark_legacy.json"
    $streamResultFile = "$env:TEMP\benchmark_stream.json"
    $fullRamResultFile = "$env:TEMP\benchmark_fullram.json"
    
    if (Test-Path $legacyResultFile) { Remove-Item $legacyResultFile -Force }
    if (Test-Path $streamResultFile) { Remove-Item $streamResultFile -Force }
    if (Test-Path $fullRamResultFile) { Remove-Item $fullRamResultFile -Force }

    # Run the scripts
    & $psExe -NoProfile -File $scriptPath -TargetTest "Basic"
    & $psExe -NoProfile -File $scriptPath -TargetTest "Legacy"
    & $psExe -NoProfile -File $scriptPath -TargetTest "FullRAM"
    & $psExe -NoProfile -File $scriptPath -TargetTest "Stream"
    
    # ---------------------------------------------------------
    # Summarize performance comparison results
    # ---------------------------------------------------------
    if ((Test-Path $legacyResultFile) -and (Test-Path $streamResultFile) -and (Test-Path $fullRamResultFile)) {
        $legacyData = Get-Content $legacyResultFile | ConvertFrom-Json
        $streamData = Get-Content $streamResultFile | ConvertFrom-Json
        $fullRamData = Get-Content $fullRamResultFile | ConvertFrom-Json

        Write-Host "`n=====================================================================" -ForegroundColor Cyan
        Write-Host " Performance Comparison Summary (All Metrics)" -ForegroundColor Cyan
        Write-Host "=====================================================================" -ForegroundColor Cyan
        
        # --- 1. สร้างตารางสรุปภาพรวม (Summary Table) ---
        $summaryTable = @(
            [PSCustomObject]@{
                Method = "[1] Legacy (Append)"
                Time_ms = $legacyData.Time_ms
                RAM_MB = $legacyData.Mem_MB
                CPU_ms = $legacyData.Cpu_ms
                GC_Count = $legacyData.GC0
            },
            [PSCustomObject]@{
                Method = "[2] Legacy (Full RAM)"
                Time_ms = $fullRamData.Time_ms
                RAM_MB = $fullRamData.Mem_MB
                CPU_ms = $fullRamData.Cpu_ms
                GC_Count = $fullRamData.GC0
            },
            [PSCustomObject]@{
                Method = "[3] Stream (New)"
                Time_ms = $streamData.Time_ms
                RAM_MB = $streamData.Mem_MB
                CPU_ms = $streamData.Cpu_ms
                GC_Count = $streamData.GC0
            }
        )
        
        # แสดงตาราง
        $summaryTable | Format-Table -AutoSize
        
        # --- 2. คำนวณสัดส่วนเปรียบเทียบ โดยใช้ Stream เป็นตัวตั้งฐาน ---
        # Speed
        $speedUpAppend = [math]::Round($legacyData.Time_ms / $streamData.Time_ms, 2)
        $speedUpFullRam = [math]::Round($fullRamData.Time_ms / $streamData.Time_ms, 2)
        
        # RAM
        $memTimesFullRam = [math]::Round($fullRamData.Mem_MB / $streamData.Mem_MB, 2)
        $memTimesAppend = [math]::Round($legacyData.Mem_MB / $streamData.Mem_MB, 2)
        $memPctFullRam = [math]::Round((($fullRamData.Mem_MB - $streamData.Mem_MB) / $fullRamData.Mem_MB) * 100, 2)
        
        # CPU
        $cpuTimesFullRam = [math]::Round($fullRamData.Cpu_ms / $streamData.Cpu_ms, 2)
        $cpuPctFullRam = [math]::Round((($fullRamData.Cpu_ms - $streamData.Cpu_ms) / $fullRamData.Cpu_ms) * 100, 2)
        $cpuTimesAppend = [math]::Round($legacyData.Cpu_ms / $streamData.Cpu_ms, 2)
        $cpuPctAppend = [math]::Round((($legacyData.Cpu_ms - $streamData.Cpu_ms) / $legacyData.Cpu_ms) * 100, 2)
        
        # GC
        $gcTimesFullRam = if ($streamData.GC0 -gt 0) { [math]::Round($fullRamData.GC0 / $streamData.GC0, 2) } else { 0 }
        $gcPctFullRam = if ($fullRamData.GC0 -gt 0) { [math]::Round((($fullRamData.GC0 - $streamData.GC0) / $fullRamData.GC0) * 100, 2) } else { 0 }
        $gcTimesAppend = if ($streamData.GC0 -gt 0) { [math]::Round($legacyData.GC0 / $streamData.GC0, 2) } else { 0 }
        $gcPctAppend = if ($legacyData.GC0 -gt 0) { [math]::Round((($legacyData.GC0 - $streamData.GC0) / $legacyData.GC0) * 100, 2) } else { 0 }

        # --- 3. พิมพ์ข้อความสรุปวิเคราะห์ (Key Takeaways) ---
        Write-Host "Key Takeaways:" -ForegroundColor Yellow
        Write-Host "-> Speed : Stream is $speedUpAppend`x faster than Append, and $speedUpFullRam`x faster than Full RAM." -ForegroundColor Green
        Write-Host "-> Memory: Full RAM consumes $memTimesFullRam`x more RAM than Stream (Stream saved $memPctFullRam%)." -ForegroundColor Green
        Write-Host "-> CPU   : Append burns $cpuTimesAppend`x more CPU time than Stream (Stream reduced CPU load by $cpuPctAppend%)." -ForegroundColor Green
        Write-Host "-> GC    : Append forces the GC to run $gcTimesAppend`x more often than Stream (Stream reduced GC load by $gcPctAppend%)." -ForegroundColor Green

        Remove-Item $legacyResultFile, $streamResultFile, $fullRamResultFile -Force
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Performance testing complete" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    exit
}

# ======================================================================
# 3. Runner system (controls isolated process execution)
# ======================================================================
if ($TargetTest -eq "All") {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Starting Isolated Process test run (guarantees net RAM measurement)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $scriptPath = $PSCommandPath
    $psExe = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh" } else { "powershell" }

    $legacyResultFile = "$env:TEMP\benchmark_legacy.json"
    $streamResultFile = "$env:TEMP\benchmark_stream.json"
    $fullRamResultFile = "$env:TEMP\benchmark_fullram.json"
    
    if (Test-Path $legacyResultFile) { Remove-Item $legacyResultFile -Force }
    if (Test-Path $streamResultFile) { Remove-Item $streamResultFile -Force }
    if (Test-Path $fullRamResultFile) { Remove-Item $fullRamResultFile -Force }

    # Run the scripts
    & $psExe -NoProfile -File $scriptPath -TargetTest "Basic"
    & $psExe -NoProfile -File $scriptPath -TargetTest "Legacy"
    & $psExe -NoProfile -File $scriptPath -TargetTest "FullRAM"
    & $psExe -NoProfile -File $scriptPath -TargetTest "Stream"
    
    # ---------------------------------------------------------
    # Summarize performance comparison results
    # ---------------------------------------------------------
    if ((Test-Path $legacyResultFile) -and (Test-Path $streamResultFile) -and (Test-Path $fullRamResultFile)) {
        $legacyData = Get-Content $legacyResultFile | ConvertFrom-Json
        $streamData = Get-Content $streamResultFile | ConvertFrom-Json
        $fullRamData = Get-Content $fullRamResultFile | ConvertFrom-Json

        Write-Host "`n=====================================================================" -ForegroundColor Cyan
        Write-Host " Performance Comparison Summary (All Metrics)" -ForegroundColor Cyan
        Write-Host "=====================================================================" -ForegroundColor Cyan
        
        # --- 1. Create Summary Data ---
        $summaryTable = @(
            [PSCustomObject]@{ Method = "[1] Legacy (Append)"; Time_ms = $legacyData.Time_ms; RAM_MB = $legacyData.Mem_MB; CPU_ms = $legacyData.Cpu_ms; GC_Count = $legacyData.GC0 }
            [PSCustomObject]@{ Method = "[2] Legacy (Full RAM)"; Time_ms = $fullRamData.Time_ms; RAM_MB = $fullRamData.Mem_MB; CPU_ms = $fullRamData.Cpu_ms; GC_Count = $fullRamData.GC0 }
            [PSCustomObject]@{ Method = "[3] Stream (New)"; Time_ms = $streamData.Time_ms; RAM_MB = $streamData.Mem_MB; CPU_ms = $streamData.Cpu_ms; GC_Count = $streamData.GC0 }
        )
        
        # --- 1.1 Find Minimum Values for Highlighting ---
        $minTime = ($summaryTable | Measure-Object Time_ms -Minimum).Minimum
        $minRam  = ($summaryTable | Measure-Object RAM_MB -Minimum).Minimum
        $minCpu  = ($summaryTable | Measure-Object CPU_ms -Minimum).Minimum
        $minGc   = ($summaryTable | Measure-Object GC_Count -Minimum).Minimum

        # --- 1.2 Draw Table with ANSI Colors ---
        $ESC = [char]27
        $CG = "$ESC[92m" # Bright Green
        $CR = "$ESC[0m"  # Reset Color

        $hMethod = "Method".PadRight(24)
        $hTime   = "Time_ms".PadLeft(10)
        $hRam    = "RAM_MB".PadLeft(12)
        $hCpu    = "CPU_ms".PadLeft(12)
        $hGc     = "GC_Count".PadLeft(12)
        
        Write-Host "$hMethod $hTime $hRam $hCpu $hGc" -ForegroundColor DarkCyan
        Write-Host "$('-'*6)".PadRight(24) "$('-'*7)".PadLeft(10) "$('-'*6)".PadLeft(12) "$('-'*6)".PadLeft(12) "$('-'*8)".PadLeft(12) -ForegroundColor DarkCyan

        foreach ($row in $summaryTable) {
            $colMethod = $row.Method.PadRight(24)

            $valTime = $row.Time_ms.ToString()
            $strTime = $valTime.PadLeft(10)
            if ($row.Time_ms -eq $minTime) { $strTime = $strTime.Replace($valTime, "${CG}${valTime}${CR}") }

            $valRam = "{0:N2}" -f $row.RAM_MB
            $strRam = $valRam.PadLeft(12)
            if ($row.RAM_MB -eq $minRam) { $strRam = $strRam.Replace($valRam, "${CG}${valRam}${CR}") }

            $valCpu = "{0:N2}" -f $row.CPU_ms
            $strCpu = $valCpu.PadLeft(12)
            if ($row.CPU_ms -eq $minCpu) { $strCpu = $strCpu.Replace($valCpu, "${CG}${valCpu}${CR}") }

            $valGc = $row.GC_Count.ToString()
            $strGc = $valGc.PadLeft(12)
            if ($row.GC_Count -eq $minGc) { $strGc = $strGc.Replace($valGc, "${CG}${valGc}${CR}") }

            Write-Host "$colMethod $strTime $strRam $strCpu $strGc"
        }
        Write-Host ""

        # --- 2. Calculate Proportions ---
        $speedUpAppend = [math]::Round($legacyData.Time_ms / $streamData.Time_ms, 2)
        $speedUpFullRam = [math]::Round($fullRamData.Time_ms / $streamData.Time_ms, 2)
        
        $memTimesFullRam = [math]::Round($fullRamData.Mem_MB / $streamData.Mem_MB, 2)
        $memPctFullRam = [math]::Round((($fullRamData.Mem_MB - $streamData.Mem_MB) / $fullRamData.Mem_MB) * 100, 2)
        
        $cpuTimesAppend = [math]::Round($legacyData.Cpu_ms / $streamData.Cpu_ms, 2)
        $cpuPctAppend = [math]::Round((($legacyData.Cpu_ms - $streamData.Cpu_ms) / $legacyData.Cpu_ms) * 100, 2)
        
        $gcTimesAppend = if ($streamData.GC0 -gt 0) { [math]::Round($legacyData.GC0 / $streamData.GC0, 2) } else { 0 }
        $gcPctAppend = if ($legacyData.GC0 -gt 0) { [math]::Round((($legacyData.GC0 - $streamData.GC0) / $legacyData.GC0) * 100, 2) } else { 0 }

        # --- 3. Key Takeaways ---
        Write-Host "Key Takeaways:" -ForegroundColor Yellow
        Write-Host "-> Speed : Stream is $speedUpAppend`x faster than Append, and $speedUpFullRam`x faster than Full RAM." -ForegroundColor Green
        Write-Host "-> Memory: Full RAM consumes $memTimesFullRam`x more RAM than Stream (Stream saved $memPctFullRam%)." -ForegroundColor Green
        Write-Host "-> CPU   : Append burns $cpuTimesAppend`x more CPU time than Stream (Stream reduced CPU load by $cpuPctAppend%)." -ForegroundColor Green
        Write-Host "-> GC    : Append forces the GC to run $gcTimesAppend`x more often than Stream (Stream reduced GC load by $gcPctAppend%)." -ForegroundColor Green

        Remove-Item $legacyResultFile, $streamResultFile, $fullRamResultFile -Force
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Performance testing complete" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    exit
}

$testResults = @()

# ==========================================
# Block 1: Test 1-8 
# ==========================================
if ($TargetTest -eq "Basic") {
    Write-Host "`n--- [Process 1] Running basic function Test 1-8 ---" -ForegroundColor DarkGray
    
    $tempFile1 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test1.json")
    $global:MockScenario = "HappyPath"; $global:MockCallCount = 0
    $m1 = Measure-MockTest { $global:result1 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile1 }
    $status = if (Test-Path $tempFile1) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "1. Happy Path"; Status = $status; Time_ms = $m1.TimeMs; Mem_MB = $m1.MemDiffMB }

    $tempFile2 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test2.json")
    $global:MockScenario = "Retry429"; $global:MockCallCount = 0
    $m2 = Measure-MockTest { $global:result2 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile2 }
    $status = if (Test-Path $tempFile2) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "2. Retry Handling"; Status = $status; Time_ms = $m2.TimeMs; Mem_MB = $m2.MemDiffMB }

    $tempFile3 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test3.json")
    $global:MockScenario = "Fatal401"; $global:MockCallCount = 0
    $m3 = Measure-MockTest { $global:result3 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile3 }
    $status = if (-not (Test-Path $tempFile3) -and $result3.status -eq 401) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "3. Fatal Error (401)"; Status = $status; Time_ms = $m3.TimeMs; Mem_MB = $m3.MemDiffMB }

    $tempFile4 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test4.json")
    $global:MockScenario = "BadJson"; $global:MockCallCount = 0
    $m4 = Measure-MockTest { $global:result4 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile4 }
    $status = if (-not (Test-Path $tempFile4) -and ($result4.message -match "Failed to parse")) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "4. Corrupted JSON"; Status = $status; Time_ms = $m4.TimeMs; Mem_MB = $m4.MemDiffMB }

    $tempCsv5 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test5.csv")
    $global:MockScenario = "CSV_Success"; $global:MockCallCount = 0
    $m5 = Measure-MockTest { $global:result5 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "csv" -accessToken "mock" -tempFile $tempCsv5 }
    $status = if (Test-Path $tempCsv5) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "5. CSV Mode"; Status = $status; Time_ms = $m5.TimeMs; Mem_MB = $m5.MemDiffMB }

    $tempFile6 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test6.json")
    $global:MockScenario = "RetryFail"; $global:MockCallCount = 0
    $m6 = Measure-MockTest { $global:result6 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile6 }
    $status = if (-not (Test-Path $tempFile6) -and $result6.status -eq 502) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "6. Max Retries"; Status = $status; Time_ms = $m6.TimeMs; Mem_MB = $m6.MemDiffMB }

    $tempCsv7 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test7.csv")
    $global:MockScenario = "CSV_Fail"; $global:MockCallCount = 0
    $m7 = Measure-MockTest { $global:result7 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "csv" -accessToken "mock" -tempFile $tempCsv7 }
    $status = if ($result7.status -eq 403) { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "7. CSV Mode Error"; Status = $status; Time_ms = $m7.TimeMs; Mem_MB = $m7.MemDiffMB }

    $tempFile8 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test8.json")
    $global:MockScenario = "FileSystemFail"; $global:MockCallCount = 0
    $lockedFile = [System.IO.File]::Open($tempFile8.FullName, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $m8 = Measure-MockTest { try { $global:result8 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile8 } finally { $lockedFile.Dispose() } }
    $status = if ($result8.message -match "Internal error while processing") { "Passed" } else { "Failed" }
    $testResults += [PSCustomObject]@{ TestName = "8. File System Lock"; Status = $status; Time_ms = $m8.TimeMs; Mem_MB = $m8.MemDiffMB }

    $testResults | Format-Table -Property TestName, Status, Time_ms, Mem_MB -AutoSize
}

# ==========================================
# Block 2: Test 9 (Legacy Append Stress Test)
# ==========================================
if ($TargetTest -eq "Legacy") {
    Write-Host "`n--- [Process 2] Loading 300,000 records (Legacy Append Method) ---" -ForegroundColor DarkGray
    $tempFile9 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test9.json")
    $global:MockScenario = "StressTest"; $global:MockCallCount = 0

    $m9 = Measure-MockTest { $global:result9 = Get-Report-Legacy -reportName "test" -period 7 -betaVersion $false -accessToken "mock" -tempFile $tempFile9 }
    
    $status = if (Test-Path $tempFile9) { "Passed" } else { "Failed" }
    $fileSize = if (Test-Path $tempFile9) { "$([math]::Round(((Get-Item $tempFile9).Length / 1MB), 2)) MB" } else { "N/A" }
    $testResults += [PSCustomObject]@{ TestName = "9. Legacy Append (300k)"; Status = $status; Time_ms = $m9.TimeMs; Mem_MB = $m9.MemDiffMB; Details = "File: $fileSize" }
    
    [PSCustomObject]@{ Time_ms = $m9.TimeMs; Mem_MB = $m9.MemDiffMB; Cpu_ms = $m9.CpuTimeMs; GC0 = $m9.GC0 } | ConvertTo-Json | Out-File "$env:TEMP\benchmark_legacy.json" -Encoding utf8
    # [PSCustomObject]@{ Time_ms = $m9.TimeMs; Mem_MB = $m9.MemDiffMB } | ConvertTo-Json | Out-File "$env:TEMP\benchmark_legacy.json" -Encoding utf8
    $testResults | Format-Table -Property TestName, Status, Time_ms, Mem_MB, Details -AutoSize
}

# ==========================================
# Block 3: Test 10 (Legacy Full RAM Stress Test)
# ==========================================
if ($TargetTest -eq "FullRAM") {
    Write-Host "`n--- [Process 3] Loading 300,000 records (Legacy Full RAM Method) ---" -ForegroundColor DarkGray
    Write-Host "Warning: this process may consume massive amounts of memory and ConvertTo-Json may take a very long time..." -ForegroundColor Yellow
    $tempFile11 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test11.json")
    $global:MockScenario = "StressTest"; $global:MockCallCount = 0

    $m11 = Measure-MockTest { $global:result11 = Get-Report-LegacyFullRAM -reportName "test" -period 7 -betaVersion $false -accessToken "mock" -tempFile $tempFile11 }
    
    $status = if (Test-Path $tempFile11) { "Passed" } else { "Failed" }
    $fileSize = if (Test-Path $tempFile11) { "$([math]::Round(((Get-Item $tempFile11).Length / 1MB), 2)) MB" } else { "N/A" }
    $testResults += [PSCustomObject]@{ TestName = "10. Legacy Full RAM (300k)"; Status = $status; Time_ms = $m11.TimeMs; Mem_MB = $m11.MemDiffMB; Details = "File: $fileSize" }
    
    [PSCustomObject]@{ Time_ms = $m11.TimeMs; Mem_MB = $m11.MemDiffMB; Cpu_ms = $m11.CpuTimeMs; GC0 = $m11.GC0 } | ConvertTo-Json | Out-File "$env:TEMP\benchmark_fullram.json" -Encoding utf8
    # [PSCustomObject]@{ Time_ms = $m11.TimeMs; Mem_MB = $m11.MemDiffMB } | ConvertTo-Json | Out-File "$env:TEMP\benchmark_fullram.json" -Encoding utf8
    $testResults | Format-Table -Property TestName, Status, Time_ms, Mem_MB, Details -AutoSize
}

# ==========================================
# Block 4: Test 11 (Stream Stress Test)
# ==========================================
if ($TargetTest -eq "Stream") {
    Write-Host "`n--- [Process 4] Loading 300,000 records (New Stream Method) ---" -ForegroundColor DarkGray
    $tempFile10 = [System.IO.FileInfo]::new("$env:TEMP\mock_report_test10.json")
    $global:MockScenario = "StressTest"; $global:MockCallCount = 0

    $m10 = Measure-MockTest { $global:result10 = Get-Report -reportName "test" -period 7 -betaVersion $false -format "json" -accessToken "mock" -tempFile $tempFile10 }
    
    $status = if (Test-Path $tempFile10) { "Passed" } else { "Failed" }
    $fileSize = if (Test-Path $tempFile10) { "$([math]::Round(((Get-Item $tempFile10).Length / 1MB), 2)) MB" } else { "N/A" }
    $testResults += [PSCustomObject]@{ TestName = "11. Stream Method (300k)"; Status = $status; Time_ms = $m10.TimeMs; Mem_MB = $m10.MemDiffMB; Details = "File: $fileSize" }
    
    [PSCustomObject]@{ Time_ms = $m10.TimeMs; Mem_MB = $m10.MemDiffMB; Cpu_ms = $m10.CpuTimeMs; GC0 = $m10.GC0 } | ConvertTo-Json | Out-File "$env:TEMP\benchmark_stream.json" -Encoding utf8
    # [PSCustomObject]@{ Time_ms = $m10.TimeMs; Mem_MB = $m10.MemDiffMB } | ConvertTo-Json | Out-File "$env:TEMP\benchmark_stream.json" -Encoding utf8
    $testResults | Format-Table -Property TestName, Status, Time_ms, Mem_MB, Details -AutoSize
}