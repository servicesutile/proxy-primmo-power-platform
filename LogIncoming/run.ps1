using namespace System.Net

param($Request, $TriggerMetadata)

$body = $Request.Body

if ($null -eq $body) {
    Write-Host "LogIncoming: received POST with no body"
} elseif ($body -is [string]) {
    Write-Host "LogIncoming: $body"
} else {
    Write-Host "LogIncoming: $(ConvertTo-Json $body -Depth 10 -Compress)"
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ""
})
