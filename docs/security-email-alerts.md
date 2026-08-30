# Security email alerts

When three wrong PINs lock a staff account, TableSide records a security alert
and writes an email job to Firestore's top-level `mail` collection for every
active owner and manager of that restaurant.

To deliver those messages, install and configure Firebase's official **Trigger
Email** extension for this project. Configure its collection path as `mail`
and connect your SMTP provider. The extension is deliberately external to the
app because Firebase Admin cannot send SMTP mail by itself, and SMTP/API keys
must never be bundled in Flutter or committed to Git.

Until the extension is installed, lock events remain recorded under
`tenants/{tenantId}/securityAlerts`, but email delivery will not occur.
