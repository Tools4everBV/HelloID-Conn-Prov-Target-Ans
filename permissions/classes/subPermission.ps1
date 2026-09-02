################################################################
# HelloID-Conn-Prov-Target-Ans-SubPermissions-Class
# PowerShell V2
################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script mapping: contract lookup key used to correlate an ANS class
$ClassLookupKey = { [string]$_.Custom.AnsExternalId } # Mandatory

# Determine all current sub-permissions
$currentPermissions = @{}

foreach ($permission in $actionContext.CurrentPermissions) {
    $currentPermissions[[string]$permission.Reference.Id] = $permission.DisplayName
}

#region functions
function Resolve-AnsError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $ErrorObject
    )

    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = "$($ErrorObject.InvocationInfo.ScriptLineNumber)"
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }

        if (-not [string]::IsNullOrEmpty($ErrorObject.Exception.Data.OriginalLine)) {
            $httpErrorObj.Line += " (while executing Line " + "$($ErrorObject.Exception.Data.OriginalScriptLineNumber): " + "$($ErrorObject.Exception.Data.OriginalLine))"
        }

        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif (
            $ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException'
        ) {
            if ($null -ne $ErrorObject.Exception.Response) {
                $responseStream = $ErrorObject.Exception.Response.GetResponseStream()
                if ($null -ne $responseStream) {
                    $streamReader = [System.IO.StreamReader]::new($responseStream)
                    $streamReaderResponse = $streamReader.ReadToEnd()
                    if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                        $httpErrorObj.ErrorDetails = $streamReaderResponse
                    }
                }
            }
        }

        $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        Write-Output $httpErrorObj
    }
}

function Get-HttpStatusCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )

    $statusCode = $null

    if ($null -ne $ErrorObject.Exception.Response) {
        try {
            $statusCode = [int]$ErrorObject.Exception.Response.StatusCode
        }
        catch {
            try {
                $statusCode = [int]$ErrorObject.Exception.Response.StatusCode.value__
            }
            catch {
                $statusCode = $null
            }
        }
    }

    return $statusCode
}

function Invoke-AnsRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Uri,

        [object] $Body,

        [string] $ContentType = 'application/json',

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary] $Headers = @{},

        [int] $MaxRetries = 5
    )

    process {
        [int]$retry = 0

        while ($retry -le $MaxRetries) {
            try {
                $splatParams = @{
                    Uri         = $Uri
                    Headers     = $Headers
                    Method      = $Method
                    ContentType = $ContentType
                    ErrorAction = 'Stop'
                }

                if ($null -ne $Body) {
                    $splatParams['Body'] = $Body
                }

                $response = Invoke-RestMethod @splatParams -Verbose:$false
                return $response
            }
            catch {
                $statusCode = Get-HttpStatusCode -ErrorObject $_

                if ($statusCode -eq 429 -and $retry -lt $MaxRetries) {
                    $retry++

                    [int]$retryAfter = -1

                    if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.Headers -and -not [string]::IsNullOrEmpty($_.Exception.Response.Headers['ratelimit-reset'])) {
                        $retryAfter = $_.Exception.Response.Headers['ratelimit-reset'] -as [int]
                        $retryAfter += 5

                        if ($retryAfter -gt 300) {
                            $retryAfter = 300
                        }
                    }

                    if ($retryAfter -le 0) {
                        $retryAfter = 10 * $retry

                        Write-Warning ("ratelimit-reset header is missing. Defaulting to retry after [$retryAfter] seconds.")
                    }

                    Write-Warning ("Received a 429 Too Many Requests response. Retrying after [$retryAfter] seconds. Attempt [$retry] of [$MaxRetries].")
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                $_.Exception.Data["OriginalLine"] = $_.InvocationInfo.Line
                $_.Exception.Data["OriginalScriptLineNumber"] = $_.InvocationInfo.ScriptLineNumber
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }
    }
}

function Get-AnsClass {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ClassId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BaseUrl
    )

    $getClassSplatParams = @{
        Uri     = "$BaseUrl/api/v2/classes/$ClassId"
        Method  = 'GET'
        Headers = $Headers
    }

    return Invoke-AnsRestMethod @getClassSplatParams
}

function Set-AnsClassMembers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ClassId,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $UserIds,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BaseUrl
    )

    # Explicitly create an array, including when it contains zero or one item.
    $classMembers = @($UserIds | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[long]$_} | Select-Object -Unique)
    $updateClassBody = @{user_ids = @($classMembers)} | ConvertTo-Json -Depth 10
    $updateClassSplatParams = @{
        Uri     = "$BaseUrl/api/v2/classes/$ClassId"
        Method  = 'PATCH'
        Headers = $Headers
        Body    = $updateClassBody
    }

    return Invoke-AnsRestMethod @updateClassSplatParams
}

#endregion functions

# Begin
try {
    $actionMessage = "verifying account reference"

    if ([string]::IsNullOrEmpty([string]$actionContext.References.Account)) {
        throw "The account reference could not be found"
    }

    # Setup connection
    $baseUrl = $actionContext.Configuration.BaseUrl.TrimEnd('/')
    $accessToken = $actionContext.Configuration.Token

    # Content-Type is set via Invoke-AnsRestMethod -ContentType to avoid a duplicate header on Windows PowerShell 5.1.
    $headers = [System.Collections.Generic.Dictionary[[string], [string]]]::new()
    $headers.Add('Authorization', "Bearer $accessToken")
    $headers.Add('Accept', 'application/json')

    Write-Information 'Verifying if a Ans account exists'
    $actionMessage = "retrieving ANS account with id [$($actionContext.References.Account)]"
    $correlatedAccount = $null

    $splatCorrelateParams = @{
        Uri     = "$baseUrl/api/v2/users/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = $headers
    }

    try {
        $correlatedAccount = Invoke-AnsRestMethod @splatCorrelateParams
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorObject $_

        if ($statusCode -eq 404) {
            $correlatedAccount = $null
        }
        else {
            throw
        }
    }

    if ($null -ne $correlatedAccount) {
        $lifecycleProcess = 'ManageSubPermissions'
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'ManageSubPermissions' {
            # Prefer the ID returned by ANS, but fall back to the stored account reference.
            $accountId = [string]$correlatedAccount.id

            if ([string]::IsNullOrEmpty($accountId)) {
                $accountId = [string]$actionContext.References.Account
            }

            $actionMessage = "retrieving ANS classes for school [$($actionContext.Configuration.SchoolId)]"

            $allClasses = @()
            $page = 1
            $limit = 100

            do {
                $splatClassesParams = @{
                    Uri     = "$baseUrl/api/v2/schools/$($actionContext.Configuration.SchoolId)/classes?limit=$limit&page=$page"
                    Method  = 'GET'
                    Headers = $headers
                }

                $classesResponse = @(Invoke-AnsRestMethod @splatClassesParams)

                Write-Information "Retrieved [$($classesResponse.Count)] ANS classes from page [$page]"

                if ($classesResponse.Count -gt 0) {
                    $allClasses += $classesResponse
                }

                $page++
            }
            while ($classesResponse.Count -eq $limit)

            Write-Information "Retrieved [$($allClasses.Count)] ANS classes in total for school [$($actionContext.Configuration.SchoolId)]"

            # Calculate desired permissions
            $actionMessage = "calculating desired permissions"
            $desiredPermissions = @{}

            if ($actionContext.Operation -ne "revoke") {
                foreach ($contract in $personContext.Person.Contracts) {
                    Write-Information "Contract: [$($contract.ExternalId)]. In condition: [$($contract.Context.InConditions)]"

                    if ($contract.Context.InConditions -or $actionContext.DryRun -eq $true) {
                        $correlationValue = [string]($contract | ForEach-Object $ClassLookupKey)

                        if ([string]::IsNullOrWhiteSpace($correlationValue)) {
                            $auditMessage = "No ANS class external_id was provided by the contract lookup key for contract [$($contract.ExternalId)]."
                            Write-Warning $auditMessage

                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = $auditMessage
                                    IsError = $true
                                })
                            continue
                        }

                        $actionMessage = "correlating ANS class where [external_id] = [$correlationValue] for contract [$($contract.ExternalId)]"
                        $matchingClasses = @($allClasses | Where-Object { [string]$_.external_id -eq $correlationValue })

                        if ($matchingClasses.Count -eq 0) {
                            $auditMessage = "No ANS class found where [external_id] = [$correlationValue] for contract [$($contract.ExternalId)]."
                            Write-Warning $auditMessage

                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = $auditMessage
                                    IsError = $true
                                })
                            continue
                        }

                        if ($matchingClasses.Count -gt 1) {
                            $matchingClassIds = @($matchingClasses.id) -join ', '
                            $auditMessage = "Multiple ANS classes found where [external_id] = [$correlationValue] for contract [$($contract.ExternalId)]. Matching class ids: [$matchingClassIds]."
                            Write-Warning $auditMessage

                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = $auditMessage
                                    IsError = $true
                                })
                            continue
                        }

                        $correlatedClass = $matchingClasses[0]
                        $classId = [string]$correlatedClass.id
                        $classDisplayName = [string]$correlatedClass.name

                        if ([string]::IsNullOrWhiteSpace($classId)) {
                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = "The ANS class with external_id [$correlationValue] does not contain an internal id."
                                    IsError = $true
                                })
                            continue
                        }

                        if ([string]::IsNullOrWhiteSpace($classDisplayName)) {
                            $classDisplayName = $correlationValue
                        }

                        $desiredPermissions[$classId] = $classDisplayName

                        Write-Information "Added desired permission: ANS class [$classDisplayName] with external_id [$correlationValue] and id [$classId]"
                    }
                }
            }

            Write-Information ("Desired Permissions: {0}" -f ($desiredPermissions.Values | ConvertTo-Json -Depth 10))
            Write-Information ("Existing Permissions: {0}" -f ($actionContext.CurrentPermissions.DisplayName | ConvertTo-Json -Depth 10))

            #####################################################
            # Report desired permissions and grant new ones
            #####################################################
            Write-Information "Starting desired permission processing for [$($desiredPermissions.Count)] permissions"

            foreach ($permission in $desiredPermissions.GetEnumerator()) {
                $classId = [string]$permission.Key
                $classDisplayName = [string]$permission.Value

                Write-Information "Processing desired permission [$classDisplayName] with id [$classId]"

                # Always return every desired permission to HelloID, including permissions that were already granted.
                $outputContext.SubPermissions.Add([PSCustomObject]@{
                        DisplayName = $classDisplayName
                        Reference   = [PSCustomObject]@{
                            Id = $classId
                        }
                    })

                if (-not $currentPermissions.ContainsKey($classId)) {
                    $actionMessage = "granting ANS class [$classDisplayName] with id [$classId] to account [$accountId]"

                    if ($actionContext.DryRun -eq $true) {
                        Write-Information "[DryRun] Would grant ANS class [$classDisplayName] with id [$classId] to account with AccountReference: [$($actionContext.References.Account)]."
                        continue
                    }

                    # Retrieve the latest complete membership immediately before patching the class.
                    try {
                        $currentClass = Get-AnsClass -ClassId $classId -Headers $headers -BaseUrl $baseUrl
                    }
                    catch {
                        $statusCode = Get-HttpStatusCode -ErrorObject $_

                        if ($statusCode -eq 404) {
                            $auditMessage = "Could not grant ANS class [$classDisplayName] with id [$classId]. Reason: The class no longer exists."
                            Write-Warning $auditMessage

                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = $auditMessage
                                    IsError = $true
                                })
                            continue
                        }
                        throw
                    }

                    $currentMembers = @(
                        $currentClass.user_ids |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                    )

                    if ($currentMembers -contains $accountId) {
                        $outputContext.AuditLogs.Add([PSCustomObject]@{
                                Action  = "GrantPermission"
                                Message = "Skipped granting ANS class [$classDisplayName] with id [$classId] to account with AccountReference: [$($actionContext.References.Account)]. Reason: The user is already a member of the class."
                                IsError = $false
                            })
                        continue
                    }

                    # ANS requires the complete list of class members.
                    $updatedMembers = @(
                        $currentMembers
                        $accountId
                    ) | Select-Object -Unique

                    $null = Set-AnsClassMembers -ClassId $classId -UserIds @($updatedMembers) -Headers $headers -BaseUrl $baseUrl

                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = "GrantPermission"
                            Message = "Granted ANS class [$classDisplayName] with id [$classId] to account with AccountReference: [$($actionContext.References.Account)]."
                            IsError = $false
                        })
                }
                else {
                    Write-Information "ANS class [$classDisplayName] with id [$classId] is already registered as a current HelloID subpermission"
                }
            }

            #####################################################
            # Revoke permissions that are no longer desired
            #####################################################
            foreach ($permission in $currentPermissions.GetEnumerator()) {
                $classId = [string]$permission.Key
                $classDisplayName = [string]$permission.Value

                if (-not $desiredPermissions.ContainsKey($classId)) {
                    $actionMessage = "revoking ANS class [$classDisplayName] with id [$classId] from account [$accountId]"

                    if ($actionContext.DryRun -eq $true) {
                        Write-Information "[DryRun] Would revoke ANS class [$classDisplayName] with id [$classId] from account with AccountReference: [$($actionContext.References.Account)]."
                        continue
                    }

                    # Retrieve the latest complete membership immediately before patching the class.
                    $currentClass = $null

                    try {
                        $currentClass = Get-AnsClass -ClassId $classId -Headers $headers -BaseUrl $baseUrl
                    }
                    catch {
                        $statusCode = Get-HttpStatusCode -ErrorObject $_

                        if ($statusCode -eq 404) {
                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Action  = "RevokePermission"
                                    Message = "Skipped revoking ANS class [$classDisplayName] with id [$classId]. Reason: The class no longer exists."
                                    IsError = $false
                                })
                            continue
                        }
                        throw
                    }

                    $currentMembers = @(
                        $currentClass.user_ids |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                    )

                    if ($currentMembers -notcontains $accountId) {
                        $outputContext.AuditLogs.Add([PSCustomObject]@{
                                Action  = "RevokePermission"
                                Message = "Skipped revoking ANS class [$classDisplayName] with id [$classId] from account with AccountReference: [$($actionContext.References.Account)]. Reason: The user is already no longer a member of the class."
                                IsError = $false
                            })
                        continue
                    }

                    # ANS requires the complete list of class members.
                    $updatedMembers = @($currentMembers | Where-Object { $_ -ne $accountId })

                    $null = Set-AnsClassMembers -ClassId $classId -UserIds @($updatedMembers) -Headers $headers -BaseUrl $baseUrl

                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = "RevokePermission"
                            Message = "Revoked ANS class [$classDisplayName] with id [$classId] from account with AccountReference: [$($actionContext.References.Account)]."
                            IsError = $false
                        })
                }
            }

            # Set Success to true only when no error audit logs were added during processing.
            if (-not ($outputContext.AuditLogs.IsError -contains $true)) {
                $outputContext.Success = $true
            }
            break
        }

        'NotFound' {
            Write-Information "Ans account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = $(if ($actionContext.Operation -eq 'revoke') { 'RevokePermission' } else { 'GrantPermission' })
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

    if ($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException' -or
        $ex.Exception.GetType().FullName -eq 'System.Net.WebException') {
        $errorObj = Resolve-AnsError -ErrorObject $ex
        $auditMessage = "Error $actionMessage. Error: $($errorObj.FriendlyMessage)."
        Write-Warning "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Error $actionMessage. Error: $($ex.Exception.Message)."
        Write-Warning "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)."
    }

    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $(if ($actionContext.Operation -eq 'revoke') { 'RevokePermission' } else { 'GrantPermission' })
            Message = $auditMessage
            IsError = $true
        })
}