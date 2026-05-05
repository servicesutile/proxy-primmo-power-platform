using namespace System.Net

param($Request, $TriggerMetadata)

function Normalize-Slug([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    return $s.Trim().ToLowerInvariant()
}

$entity  = Normalize-Slug ($Request.Params.entity  ?? $TriggerMetadata.BindingData.entity)
$envName = Normalize-Slug ($Request.Params.env     ?? $TriggerMetadata.BindingData.env)

Write-Host "[$($TriggerMetadata.InvocationId)] Received $($Request.Method) webhook for entity='$entity' env='$envName'"

# ---- 0) Validations basiques ----
if ([string]::IsNullOrWhiteSpace($entity) -or [string]::IsNullOrWhiteSpace($envName)) {
    Write-Host "[$($TriggerMetadata.InvocationId)] ERROR: Missing route params - entity='$entity' env='$envName'"
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
    Write-Host "[$($TriggerMetadata.InvocationId)] ERROR: Server misconfigured - WEBHOOK_TOKEN present=$(-not [string]::IsNullOrWhiteSpace($expectedToken)) WEBHOOK_TOKEN_HEADER present=$(-not [string]::IsNullOrWhiteSpace($tokenHeaderName))"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "Server misconfigured (WEBHOOK_TOKEN / WEBHOOK_TOKEN_HEADER)"
    })
    return
}

$receivedToken = $null
if ($Request.Headers.ContainsKey($tokenHeaderName)) {
    $receivedToken = $Request.Headers[$tokenHeaderName]
} else {
    Write-Host "[$($TriggerMetadata.InvocationId)] WARN: Token header '$tokenHeaderName' not present in request"
}

if ($receivedToken -ne $expectedToken) {
    Write-Host "[$($TriggerMetadata.InvocationId)] ERROR: Token validation failed for entity='$entity' env='$envName'"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = "Invalid token"
    })
    return
}

Write-Host "[$($TriggerMetadata.InvocationId)] Token validated OK"

# ---- 2) Mapper (entity + env) -> destination ----
# Clé attendue: ENTITY_{entity}_{env}
$destEnvKey = "ENTITY_{0}_{1}" -f $entity, $envName
$destUrl = [Environment]::GetEnvironmentVariable($destEnvKey)

Write-Host "[$($TriggerMetadata.InvocationId)] Destination lookup: key='$destEnvKey' found=$(-not [string]::IsNullOrWhiteSpace($destUrl))"

if ([string]::IsNullOrWhiteSpace($destUrl)) {
    Write-Host "[$($TriggerMetadata.InvocationId)] ERROR: No mapping found for key='$destEnvKey'"
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

Write-Host "[$($TriggerMetadata.InvocationId)] Forwarding $($forwardHeaders.Count) headers"

$body = $null
if ($Request.Method -ne "GET") {
    if ($null -ne $Request.Body -and $Request.Body -isnot [string] -and $Request.Body -isnot [byte[]]) {
        $body = ($Request.Body | ConvertTo-Json -Depth 50 -Compress)
        if (-not $forwardHeaders.ContainsKey("Content-Type")) {
            $forwardHeaders["Content-Type"] = "application/json"
        }
        Write-Host "[$($TriggerMetadata.InvocationId)] Body serialized from object: $($body.Length) chars"
    } else {
        $body = $Request.Body
        $bodySize = if ($null -eq $body) { 0 } elseif ($body -is [byte[]]) { $body.Length } else { $body.ToString().Length }
        Write-Host "[$($TriggerMetadata.InvocationId)] Body type=$($body?.GetType().Name ?? 'null') size=$bodySize"
    }
} else {
    Write-Host "[$($TriggerMetadata.InvocationId)] GET request, no body"
}

$maskedUrl = $destUrl -replace '(?<=\?|&)(sig|sv|sp)=[^&]*', '$1=***'
Write-Host "[$($TriggerMetadata.InvocationId)] Forwarding $($Request.Method) -> $maskedUrl"

try {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $resp = Invoke-WebRequest -Uri $destUrl `
                              -Method $Request.Method `
                              -Headers $forwardHeaders `
                              -Body $body `
                              -TimeoutSec 30 `
                              -UseBasicParsing

    $stopwatch.Stop()

    $contentType = $resp.Headers["Content-Type"]
    $responseSize = if ($resp.Content -is [byte[]]) { $resp.Content.Length } else { $resp.Content?.Length ?? 0 }

    Write-Host "[$($TriggerMetadata.InvocationId)] Upstream responded $($resp.StatusCode) in $($stopwatch.ElapsedMilliseconds)ms content-type='$contentType' size=$responseSize"

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

    Write-Host "[$($TriggerMetadata.InvocationId)] ERROR: Upstream $statusCode for entity='$entity' env='$envName' exception='$($_.Exception.GetType().Name)' message='$($_.Exception.Message)'"
    Write-Host "[$($TriggerMetadata.InvocationId)] Upstream response body: $upstreamBody"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]$statusCode
        Body       = $upstreamBody
    })
}
