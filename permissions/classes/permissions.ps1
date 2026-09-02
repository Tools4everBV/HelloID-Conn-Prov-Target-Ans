############################################################
# HelloID-Conn-Prov-Target-Ans-Permissions-Class
# PowerShell V2
############################################################

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
function Invoke-AnsImportWebRequest {
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
        $Resultdata = $null
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
                $resultData = Invoke-WebRequest @splatParams -Verbose:$false  -UseBasicParsing                                                

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
#endregion

try {

    Write-Information 'Retrieving permissions'   
    $accessToken = $actionContext.Configuration.Token
    $pageSize = 50
    [int] $pageNumber = 1
    [int] $totalPages = 1  
    do { 
        $splatImportParams = @{           
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/schools/$($actionContext.Configuration.SchoolId)/classes?page=$pageNumber&limit=$pageSize"        
            Method  = 'GET'
            Headers = @{
                Authorization = "Bearer $accessToken"
            }           
        }
        $requestResult = Invoke-AnsImportWebRequest @splatImportParams         
        if ([string]::IsNullOrEmpty($requestResult.Content)) {
           break;
        }

        $FoundClasses = $requestResult.content | ConvertFrom-Json
        foreach ($class in $FoundClasses) {
          
            # Make sure the displayName has a value
            $displayName = "$($class.name)"
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = $class.Id
            }      
            $outputContext.Permissions.Add(
                @{
                    DisplayName    = $displayName
                    Identification = @{
                        Reference = $class.Id
                    }
                }
            )       
        }        
        
        $pageNumber++
        if ($null -ne $requestResult.headers."total-pages") {
           $totalPages = [int]::Parse($requestResult.headers."total-pages")
        }
    } while ($pageNumber -le $totalPages)   
   
   
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-AnsError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
}
