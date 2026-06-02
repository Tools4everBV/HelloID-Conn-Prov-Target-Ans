#################################################################
# HelloID-Conn-Prov-Target-Ans-RevokePermission-Class
# PowerShell V2
#################################################################

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

#endregion

# Begin
try {
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    Write-Information 'Verifying if a Ans account exists'
    $access_token = $actionContext.Configuration.token
    $splatCorrelateParams = @{           
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/users/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = @{
            Authorization = "Bearer $access_token"
        }           
    }

    $correlationResult = Invoke-AnsRestMethod @splatCorrelateParams 
    $correlatedAnsAccount = $correlationResult[0]
    

    if ($null -ne $correlatedAnsAccount) {
        $lifecycleProcess = 'RevokePermission'
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'RevokePermission' {

            
            #get the current users in this class 
            $splatReadParams = @{           
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/classes/$($actionContext.References.Permission.Reference)"
                Method  = 'GET'
                Headers = @{
                    Authorization = "Bearer $access_token"
                }           
            }
            $classCorrelationResult = Invoke-AnsRestMethod @splatReadParams 
            $correlatedClass = $classCorrelationResult[0]
            if ($null -eq $correlatedClass) {
                Write-Information "Ans class: [$($actionContext.References.Permission.Reference)] could not be found, indicating that it may have been deleted"
                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Ans class: [$($actionContext.References.Permission.Reference)] could not be found, indicating that it may have been deleted"
                        IsError = $false
                    })               
                break   
            }
            $currentMembers = $correlatedClass.user_ids
          
            if ($currentMembers -contains $correlatedAnsAccount.Id) {
                $newMembers = [system.collections.generic.list[string]]::new()
                $currentMembers | Where-Object { $_ -ne $correlatedAnsAccount.Id } | ForEach-Object { $newMembers.Add($_) }

                $body = @{
                    user_ids = $newMembers
                }   
                Write-Information "Revoking Ans permission: [$($actionContext.PermissionDisplayName)] - [$($actionContext.References.Permission.Reference)]"      
                $splatUpdateParams = @{                
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/classes/$($actionContext.References.Permission.Reference)"
                    Method  = 'PATCH'
                    Body    = $body | ConvertTo-Json 
                    Headers = @{
                        Authorization = "Bearer $access_token"
                    }
                } 

                if (-not($actionContext.DryRun -eq $true)) {             

                    $revokeResult = Invoke-AnsRestMethod @splatUpdateParams               
                }
                else {
                    Write-Information "[DryRun] Revoke Ans permission: [$($actionContext.PermissionDisplayName)] - [$($actionContext.References.Permission.Reference)], will be executed during enforcement"
                }
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Revoke permission: [$($actionContext.PermissionDisplayName)] from [$($actionContext.References.Account)] was successful. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Ans account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Ans account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-AnsError -ErrorObject $ex
        $auditLogMessage = "Could not revoke Ans permission for account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not revoke Ans permission for account: [$($actionContext.References.Account)]. Error: $($_.Exception.Message). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}