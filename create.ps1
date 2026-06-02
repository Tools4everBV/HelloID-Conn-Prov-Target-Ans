#################################################
# HelloID-Conn-Prov-Target-Ans-Create
# PowerShell V2
#################################################

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

function ConvertTo-HelloIDAccountObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $AnsAccountObject
    )
    process {
        # Making sure only fieldMapping fields are imported
        $helloidAccountObject = [PSCustomObject]@{} 
        $null = $outputContext.Data.PSObject.Properties.foreach{
            $helloidAccountObject | Add-Member -MemberType NoteProperty -Name $($_.Name) -Value  ($AnsAccountObject.$($_.Name) -as $_.TypeNameOfValue)
        }         
        Write-Output $helloidAccountObject
    }
}
#endregion

try {
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    $access_token = $actionContext.Configuration.token

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue
           
        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrWhiteSpace($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        $correlationValue = $correlationValue.Trim() 
        if ($correlationField -eq 'student_number') {
            $correlationValue = $correlationValue.PadLeft($actionContext.Configuration.StudentNumberLength, '0') # Pad the student number with zeros based on the configured length
        }    

        # Determine if a user needs to be [created] or [correlated]
        Write-Information "Verifying if a Ans account exists where $correlationField is: [$correlationValue]"

        $splatcorrelationParams = @{           
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/search/users?query=school_id:`"$($actionContext.Configuration.SchoolId)`" $($correlationField):`"$correlationValue`""        
            Method  = 'GET'
            Headers = @{
                Authorization = "Bearer $access_token"
            }           
        }

        $correlatedAccount = Invoke-AnsRestMethod @splatcorrelationParams         
    }

    if ($correlatedAccount.Count -eq 0) {
        $lifecycleProcess = 'CreateAccount'
    }
    elseif ($correlatedAccount.Count -eq 1) {
        $lifecycleProcess = 'CorrelateAccount'
    }
    elseif ($correlatedAccount.Count -gt 1) {
        throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
    }

    # Process
    switch ($lifecycleProcess) {

        'CreateAccount' {

            $actionContext.Data | Add-Member -MemberType NoteProperty -Name 'active' -Value $false
            $splatCreateParams = @{                
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/schools/$($actionContext.Configuration.SchoolId)/users"
                Method  = 'POST'
                Body    = $actionContext.Data | ConvertTo-Json
                Headers = @{
                    Authorization = "Bearer $access_token"
                }
            } 

            
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating Ans account'           

                $createResult = Invoke-AnsRestMethod @splatCreateParams
                $createdHelloIDAccount = ConvertTo-HelloIDAccountObject -AnsAccountObject $createResult[0]

                $outputContext.Data = $createdHelloIDAccount
                $outputContext.AccountReference = $createdHelloIDAccount.Id 
            }
            else {
                Write-Information '[DryRun] Create and correlate Ans account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Ans account'
            $outputContext.AccountReference = $correlatedAccount[0].Id
            $correlatedHelloIDAccount = ConvertTo-HelloIDAccountObject -AnsAccountObject $correlatedAccount[0]
            $outputContext.Data = $correlatedHelloIDAccount                   
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $lifecycleProcess
            Message = $auditLogMessage
            IsError = $false
        })  
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-AnsError -ErrorObject $ex
        $auditLogMessage = "Could not create or correlate Ans account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not create or correlate Ans account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}