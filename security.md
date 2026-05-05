Plan: Secure Proxy → Power Automate with Managed Identity (Option B)
Context
The webhook proxy currently forwards sensitive data to Power Automate HTTP triggers configured as "Anyone" — meaning anyone who knows the URL can trigger the flow. The destination URLs (which contain SAS tokens) are stored in App Settings and are never exposed to callers, but this is security through obscurity. Since this data is sensitive, we need proper Azure AD authentication: the Function App authenticates as itself using its Managed Identity, and Power Automate verifies that identity before accepting the request.

What Changes
Phase 1 — Azure Portal (manual, before deploying code)
Enable System-assigned Managed Identity on the Function App proxy-primmo-power-platform
→ Azure Portal → Function App → Settings → Identity → System assigned → On
→ Copy the Object (Principal) ID that appears

For each Power Automate flow, open the HTTP trigger settings:

Change "Who can trigger the flow" from Anyone to Specific users in my tenant
Paste the Managed Identity's Object ID into the allowed users field
Save → copy the updated trigger URL (it may regenerate)
Update App Settings (ENTITY\_\* variables) with the new trigger URLs
→ If using Key Vault references, update the secrets there instead

Note: Power Automate is migrating all flows off logic.azure.com URLs to api.powerplatform.com by November 30, 2026. If any ENTITY\_\* URLs still use the old domain, update them now while you're in the trigger settings.

Phase 2 — Code changes (3 files)
requirements.psd1
Add Az.Accounts (the only Az submodule needed — provides Connect-AzAccount and Get-AzAccessToken, avoids loading the entire Az suite to keep cold-start overhead low):

@{
'Az.Accounts' = '5.\*'
}
profile.ps1
Restore the MSI bootstrap block (runs once per cold start):

if ($env:MSI_SECRET) {
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null
}
Disable-AzContextAutosave prevents Az from writing context to disk (not available in Azure Functions file system). Connect-AzAccount -Identity loads the Managed Identity credential into the session. Both were in the original Azure Functions template before we removed them.

WebhookRelay/run.ps1
After the token validation block (step 1) and before the destination lookup (step 2), acquire a Power Automate Bearer token and inject it into the forwarded headers:

# ---- 1b) Acquire Managed Identity token for Power Automate ----

if ($env:MSI_SECRET) {
    try {
        $flowToken = (Get-AzAccessToken -ResourceUrl 'https://service.flow.microsoft.com/').Token
        $forwardHeaders["Authorization"] = "Bearer $flowToken"
        Write-Host "[$($TriggerMetadata.InvocationId)] Power Automate token acquired OK"
    } catch {
        Write-Host "[$($TriggerMetadata.InvocationId)] ERROR: Failed to acquire Power Automate token: $($\_.Exception.Message)"
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
StatusCode = [HttpStatusCode]::InternalServerError
Body = "Failed to authenticate to downstream service"
})
return
}
}
The if ($env:MSI_SECRET) guard means local dev continues to work without MSI (Power Automate will reject the unauthenticated call in that case, but the function itself won't crash). The token is cached internally by Az.Accounts and is reused across invocations within the same worker process — Get-AzAccessToken only makes a network call when the token is near expiry (~5 min before).

Security note: The token value must never appear in logs. The existing $maskedUrl pattern already masks SAS params; no changes needed there since tokens travel in headers, not the URL.

Files Modified
File Change
requirements.psd1 Add 'Az.Accounts' = '5.\*'
profile.ps1 Restore Disable-AzContextAutosave + Connect-AzAccount -Identity
WebhookRelay/run.ps1 Add token acquisition block between step 1 and step 2
Verification
Deploy to Azure and confirm cold-start log shows Connect-AzAccount succeeded (no error in Application Insights)
Send a test webhook with a valid WEBHOOK_TOKEN → expect 200 from Power Automate
Send a test webhook without the token header → expect 401 from the proxy (unchanged behaviour)
Temporarily remove the Managed Identity's Object ID from the flow's allowed users → resend → expect 401 from Power Automate (proxy returns 502 wrapping it)
Confirm Application Insights logs show Power Automate token acquired OK and that no Bearer token value appears in any log line
