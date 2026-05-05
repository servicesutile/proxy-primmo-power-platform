using namespace System.Net

param($Request, $TriggerMetadata)

function Normalize-Slug([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    return $s.Trim().ToLowerInvariant()
}

$entity  = Normalize-Slug ($Request.Params.entity  ?? $TriggerMetadata.BindingData.entity)
$envName = Normalize-Slug ($Request.Params.env     ?? $TriggerMetadata.BindingData.env)

Write-Host "Received webhook for entity='$entity' env='$envName'"

# ---- 0) Validations basiques ----
if ([string]::IsNullOrWhiteSpace($entity) -or [string]::IsNullOrWhiteSpace($envName)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Missing route params (env/entity)"
    })
    return
}

# ---- 1) Vérifier le token ----
$expectedToken = $env:WEBHOOK_TOKEN
$tokenHeaderName = $env:WEBHOOK_TOKEN_HEADER

if ([string]::IsNullOrWhiteSpace($expectedToken) -or [string]::IsNullOrWhiteSpace($tokenHeaderName)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "Server misconfigured (WEBHOOK_TOKEN / WEBHOOK_TOKEN_HEADER)"
    })
    return
}

$receivedToken = $null
if ($Request.Headers.ContainsKey($tokenHeaderName)) {
    $receivedToken = $Request.Headers[$tokenHeaderName]
}

if ($receivedToken -ne $expectedToken) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = "Invalid token"
    })
    return
}

# ---- 2) Mapper (entity + env) -> destination ----
# Clé attendue: ENTITY_{entity}_{env}
$destEnvKey = "ENTITY_{0}_{1}" -f $entity, $envName
$destUrl = [Environment]::GetEnvironmentVariable($destEnvKey)

if ([string]::IsNullOrWhiteSpace($destUrl)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body       = "No mapping for: $destEnvKey"
    })
    return
}

# ---- 3) Forward request ----
$forwardHeaders = @{}
foreach ($kvp in $Request.Headers.GetEnumerator()) {
    $k = $kvp.Key.ToLowerInvariant()
    if ($k -in @("host","content-length","connection")) { continue }
    $forwardHeaders[$kvp.Key] = $kvp.Value
}

# Ajouts utiles (optionnels)
$forwardHeaders["X-Webhook-Entity"] = $entity
$forwardHeaders["X-Webhook-Env"] = $envName

$body = $null
if ($Request.Method -ne "GET") {
    if ($null -ne $Request.Body -and $Request.Body -isnot [string] -and $Request.Body -isnot [byte[]]) {
        $body = ($Request.Body | ConvertTo-Json -Depth 50 -Compress)
        if (-not $forwardHeaders.ContainsKey("Content-Type")) {
            $forwardHeaders["Content-Type"] = "application/json"
        }
    } else {
        $body = $Request.Body
    }
}

try {
    $resp = Invoke-WebRequest -Uri $destUrl `
                              -Method $Request.Method `
                              -Headers $forwardHeaders `
                              -Body $body `
                              -TimeoutSec 30 `
                              -UseBasicParsing

    $contentType = $resp.Headers["Content-Type"]

    $outHeaders = @{}
    if ($contentType) { $outHeaders["Content-Type"] = $contentType }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]$resp.StatusCode
        Headers    = $outHeaders
        Body       = $resp.Content
    })
}
catch {
    $statusCode = 502
    $upstreamBody = $_.ErrorDetails.Message
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ([string]::IsNullOrWhiteSpace($upstreamBody)) {
        $upstreamBody = "Upstream error: $($_.Exception.Message)"
    }

    Write-Host "Upstream $statusCode for entity='$entity' env='$envName': $upstreamBody"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]$statusCode
        Body       = $upstreamBody
    })
}
