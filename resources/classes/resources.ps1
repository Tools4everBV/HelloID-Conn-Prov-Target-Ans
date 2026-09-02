##########################################################
# HelloID-Conn-Prov-Target-Ans-Resources-class
# PowerShell V2
##########################################################
$actionContext.DryRun = $True

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-AnsError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = "$($ErrorObject.InvocationInfo.ScriptLineNumber)"
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.Exception.Data.OriginalLine)) {
            $httpErrorObj.Line += " (while executing Line $($ErrorObject.Exception.Data.OriginalScriptLineNumber): $($ErrorObject.Exception.Data.OriginalLine))"
        }
      
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails 
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            Write-Warning $_.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}
function invoke-AnsImportWebRequest {
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [object]
        $Body,

        [string]
        $ContentType = 'application/json',

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]
        $Headers = @{},

        [int]
        $Maxretries = 5
    )
    process {

        [int] $retry = 0
        $Resultdata = $null
        while ($retry++ -le $Maxretries) {
            try {
                $splatParams = @{
                    Uri         = $Uri
                    Headers     = $headers
                    Method      = $Method
                    ContentType = $ContentType
                }

                if ($Body) {
                    $splatParams['Body'] = $Body
                }               
                $resultData = Invoke-WebRequest @splatParams -Verbose:$false  -UseBasicParsing                                                

                break
            }
            catch {                
                
                if ($_.Exception.Response.StatusCode -eq 429) {
                    [int] $retryAfter = -1
                    if ( -not [string]::IsNullOrEmpty($_.Exception.Response.Headers['ratelimit-reset'])) {                    
                        $retryAfter = $_.Exception.Response.Headers['ratelimit-reset'] -as [int]
                        $retryAfter += 5 # Adding a buffer of 5 seconds to ensure the rate limit has reset before retrying
                        if ($retryAfter -gt 300) {
                            $retryAfter = 300 # Set a maximum retry after of 5 minutes to prevent excessively long wait times
                        }
                    } 
                    Write-Warning "Received a 429 Too Many Requests response. Retrying after $retryAfter seconds..."
                    if ($retryAfter -le 0) {
                        $retryAfter = 10 * $retry # Default retry after with an incremental backoff strategy if the header is not provided
                        Write-Warning "ratelimit-reset header is missing. Defaulting to retry after $retryAfter seconds."  
                    }
                    Start-Sleep -Seconds $retryAfter  
                    Continue                
                    
                }
                elseif ($_.Exception.Response.StatusCode -eq 404) { 
                    $resultdata = $null                                              
                    break;
                }

                $_.Exception.Data["OriginalLine"] = $_.InvocationInfo.Line
                $_.Exception.Data["OriginalScriptLineNumber"] = $_.InvocationInfo.ScriptLineNumber                
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }

        Return  $resultdata
    }       
} 
function invoke-AnsRestMethod {
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [object]
        $Body,

        [string]
        $ContentType = 'application/json',

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]
        $Headers = @{},

        [int]
        $Maxretries = 5
    )

    process {
        [int] $retry = 0
        while ($retry++ -le $Maxretries) {
            try {
                $splatParams = @{
                    Uri         = $Uri
                    Headers     = $headers
                    Method      = $Method
                    ContentType = $ContentType
                }

                if ($Body) {
                    $splatParams['Body'] = $Body
                }
                $Result = Invoke-RestMethod @splatParams -Verbose:$false
                break
            }
            catch {                
                if ($_.Exception.Response.StatusCode -eq 429) {
                    [int] $retryAfter = -1
                    if ( -not [string]::IsNullOrEmpty($_.Exception.Response.Headers['ratelimit-reset'])) {                    
                        $retryAfter = $_.Exception.Response.Headers['ratelimit-reset'] -as [int]
                        $retryAfter += 5 # Adding a buffer of 5 seconds to ensure the rate limit has reset before retrying
                        if ($retryAfter -gt 300) {
                            $retryAfter = 300 # Set a maximum retry after of 5 minutes to prevent excessively long wait times
                        }
                    } 
                    Write-Warning "Received a 429 Too Many Requests response. Retrying after $retryAfter seconds..."
                    if ($retryAfter -le 0) {
                        $retryAfter = 10 * $retry # Default retry after with an incremental backoff strategy if the header is not provided
                        Write-Warning "ratelimit-reset header is missing. Defaulting to retry after $retryAfter seconds."  
                    }
                    Start-Sleep -Seconds $retryAfter  
                    Continue         
                }
                elseif ($_.Exception.Response.StatusCode -eq '404') {
                    break;
                }
                else {   
                    $_.Exception.Data["OriginalLine"] = $_.InvocationInfo.Line
                    $_.Exception.Data["OriginalScriptLineNumber"] = $_.InvocationInfo.ScriptLineNumber                
                    $PSCmdlet.ThrowTerminatingError($_)
                }
            }
        }
        Return , $Result
    }   
} 

#endregion

try {
    # School year rolls over on September 1st: months >= 9 use current year, otherwise previous year
    $today = Get-Date
    $currentSchoolYear = if ($today.Month -ge 9) { $today.Year } else { $today.Year - 1 }

    $resources = $resourceContext.SourceData | Select-Object -Property AnsName,AnsExternalId,AnsYear,AnsStudy
    $resources = $resources | Where-Object {
        ($null -ne $_.AnsName) -and
        ($null -ne $_.AnsYear) -and
        ([int]::Parse($_.AnsYear) -eq $currentSchoolYear)
    }
    Write-Information "Creating [$($resources.Count)] classes for school year [$currentSchoolYear]"
    #Write-Information ($resources | ConvertTo-Json)

    $access_token = $actionContext.Configuration.token
    $pageSize = 50
    [int] $pageNumber = 1
    [int] $totalPages = 1  
    $foundClasses = [System.Collections.Generic.SortedList[string, object]]::new()
    do { 
        $splatImportParams = @{           
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/schools/$($actionContext.Configuration.SchoolId)/classes?page=$pageNumber&limit=$pageSize"        
            Method  = 'GET'
            Headers = @{
                Authorization = "Bearer $access_token"
            }           
        }
        $requestResult = Invoke-AnsImportWebRequest @splatImportParams         
        if ([string]::IsNullOrEmpty($requestResult.Content)) {
            break;
        }
        $tmpFoundClasses = $requestResult.content | ConvertFrom-Json
        foreach ($class in $tmpFoundClasses) {
            # Composite key: name + year, because ANS reuses class names across school years
            $key = "$($class.name)|$($class.year)"
            if ($foundClasses.ContainsKey($key)) {
                Write-Warning "Duplicate class found in ANS for name [$($class.name)] year [$($class.year)] (id [$($class.id)]); keeping first occurrence."
                continue
            }
            $foundClasses.Add($key, $class)
        }        
        $pageNumber++
        if ($null -ne $requestResult.headers."total-pages") {
            $totalPages = [int]::Parse($requestResult.headers."total-pages")
        }
        
    } while ($pageNumber -le $totalPages)   
   
    foreach ($resource in $resources) {
        try {
            <# Resource creation preview uses a timeout of 30 seconds while actual run has timeout of 10 minutes #>
            Write-Information  "Ans resource [$($resource.AnsExternalId)][$($resource.AnsName)][$($resource.AnsYear)]"
            if ($null -eq $resource.AnsExternalId -or $null -eq $resource.AnsName -or $null -eq $resource.AnsYear) {
                Write-Warning "Resource [$($resource.AnsExternalId)][$($resource.AnsName)][$($resource.AnsYear)] is missing required fields. Skipping."
                continue
            }

            $body = @{
                name        = $resource.AnsName
                external_id = $resource.AnsExternalId
                year        = [int]::Parse($resource.AnsYear)
                study       = $resource.AnsStudy
            }

            $resourceKey = "$($resource.AnsName)|$([int]::Parse($resource.AnsYear))"

            $splatCreateParams = @{                
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/schools/$($actionContext.Configuration.SchoolId)/classes"
                Method  = 'POST'
                Body    = $body | ConvertTo-Json
                Headers = @{
                    Authorization = "Bearer $access_token"
                }
            }
            
            # If resource does not exist
            if (-not $foundClasses.ContainsKey($resourceKey)) {
                
                if (-not ($actionContext.DryRun -eq $True)) {
                    Write-Information "Create [$($resource.AnsName)] Ans resource"
                    $createResult = Invoke-AnsRestMethod @splatCreateParams
                    $foundClasses.Add($resourceKey, $createResult[0]) # Add the newly created resource to the list of found resources to prevent duplicate creation in the same run

                }
                else {
                    Write-Information "[DryRun] Create Ans [$($resource.AnsName)] resource, will be executed during enforcement"
                }

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Action  = 'CreateResource'
                        Message = "Created resource: [$($resource.AnsName)]"
                        IsError = $false
                    })
            }
            else {
                # class already exist, check if an update is needed based on the external id, as name + year form the unique identifier
                if ($foundClasses[$resourceKey].external_id -ne $resource.AnsExternalId) {

                    $splatUpdateParams = @{                
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/classes/$($foundClasses[$resourceKey].id)"
                        Method  = 'PATCH'
                        Body    = $body | ConvertTo-Json
                        Headers = @{
                            Authorization = "Bearer $access_token"
                        }
                    }     
                    
                    if (-not ($actionContext.DryRun -eq $True)) {
                        Write-Information "Update [$($resource.AnsName)] Ans resource"
                        $updateResult = Invoke-AnsRestMethod @splatUpdateParams
                        $foundClasses[$resourceKey] = $updateResult[0] # Update the resource in the list of found resources to prevent duplicate update in the same run
                    }
                    else {
                        Write-Information "[DryRun] Update Ans [$($resource.AnsName)] resource, will be executed during enforcement"
                    }

                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = 'UpdateResource'
                            Message = "Updated resource: [$($resource.AnsName)]"
                            IsError = $false
                        })

                    Write-Information "Resource [$($resource.AnsName)] Updated. new external id: [$($resource.AnsExternalId)], new year: [$($resource.AnsYear)]"
                }           
            }
        }
        catch {
            $outputContext.Success = $false
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-AnsError -ErrorObject $ex
                $auditLogMessage = "Could not create Ans resource. Error: $($errorObj.FriendlyMessage)"
                Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditLogMessage = "Could not create Ans resource. Error: $($ex.Exception.Message)"
                Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $auditLogMessage
                    IsError = $true
                })
        }        
    } 
    $outputContext.Success = $true 
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-AnsError -ErrorObject $ex
        $auditLogMessage = "Could not create Ans resource. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not create Ans resource. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}

