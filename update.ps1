#################################################
# HelloID-Conn-Prov-Target-Ans-Update
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
function Invoke-AnsRestMethod {
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
        $MaxRetries = 5
    )

    process {
        [int] $retry = 0
        while ($retry -le $MaxRetries) {
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
                    $retry++
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
        [AllowNull()]
        [PSCustomObject] $AnsAccountObject
    )
    process {
        # Route null (e.g. after a swallowed 404 from Invoke-AnsRestMethod) back to the caller so it can enter the NotFound branch.
        if ($null -eq $AnsAccountObject) { return $null }

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
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }
    if ($actionContext.AccountCorrelated){
            # When the user is reboarded, de alumni status is set to $false, indicating that it is again an active account managed by HelloID.
            $actionContext.Data | Add-Member -MemberType NoteProperty -Name "alumni" -Value $false
            $outputContext.Data | Add-Member -MemberType NoteProperty -Name "alumni" -Value $false
    }  

    Write-Information 'Verifying if a Ans account exists'
    $accessToken = $actionContext.Configuration.Token

    $splatCorrelateParams = @{           
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/users/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = @{
            Authorization = "Bearer $accessToken"
        }           
    }

    $correlationResult = Invoke-AnsRestMethod @splatCorrelateParams 
    $correlatedAccount = ConvertTo-HelloIDAccountObject -AnsAccountObject $correlationResult[0]
 
    if ($null -ne $correlatedAccount) {

        $outputContext.PreviousData = $correlatedAccount

              
       
        if ($actionContext.Data.PSObject.Properties.Name -contains 'student_number' -and $actionContext.Configuration.UseStudentNumberPadding) {
            $actionContext.Data.student_number = $actionContext.Data.student_number.PadLeft($actionContext.Configuration.StudentNumberLength, '0')
        }
        $splatCompareProperties = @{
            ReferenceObject  = @($correlatedAccount.PSObject.Properties)
            DifferenceObject = @($actionContext.Data.PSObject.Properties)
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }
        if ($propertiesChanged) {
            $lifecycleProcess = 'UpdateAccount'
        }
        else {
            $lifecycleProcess = 'NoChanges'
        }
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'UpdateAccount' {
            Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Updating Ans account with accountReference: [$($actionContext.References.Account)]"

                $Body = @{}                   
                foreach ($property in $propertiesChanged) {
                    $Body | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
                }                
                $splatUpdateParams = @{                
                   Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/users/$($actionContext.References.Account)"
                    Method  = 'PATCH'
                    Body    = $Body | ConvertTo-Json 
                    Headers = @{
                        Authorization = "Bearer $accessToken"
                    }
                } 
                $updateResult = Invoke-AnsRestMethod @splatUpdateParams         
            }
            else {
                Write-Information "[DryRun] Update Ans account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

           
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'UpdateAccount'
                    Message = "Updated Ans account with AccountReference: [$($actionContext.References.Account)]. Property(s) updated: [$($propertiesChanged.Name -join ', ')]."
                    IsError = $false
                })
            break
        }

        'NoChanges' {
            Write-Information "No changes to Ans account with accountReference: [$($actionContext.References.Account)]"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'UpdateAccount'
                    Message = "Skipped updating Ans account with AccountReference: [$($actionContext.References.Account)]. Reason: No changes required."
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Ans account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'UpdateAccount'
                    Message = "Ans account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted."
                    IsError = $true
                })
            break
        }
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-AnsError -ErrorObject $ex
        $auditLogMessage = "Could not update Ans account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage)."
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not update Ans account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message)."
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)."
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = 'UpdateAccount'
            Message = $auditLogMessage
            IsError = $true
        })
}
