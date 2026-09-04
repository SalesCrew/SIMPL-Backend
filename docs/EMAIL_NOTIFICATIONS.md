# SIMPL workspace email

SIMPL sends email for four committed workspace events:

- a new card;
- a new comment;
- a card marked as read;
- a card marked as completed.

The existing `private.publish_workspace_notification` function determines the recipients. It includes every active profile that can currently access the workspace and excludes the actor. The email outbox mirrors those per-recipient notification rows, so workspace isolation and pairwise NDA blocks are not reimplemented in application code.

Before each delivery, `claim_email_outbox` checks the recipient's active state and workspace access again. If access was removed after the event, the job is discarded without revealing its content. Jobs use leases, retry with exponential backoff and stop after eight failed attempts. Terminal delivery records are retained for 30 days.

Production uses Exchange Web Services with NTLM over HTTPS because outbound SMTP is unavailable on Railway plans below Pro. The worker verifies the mailbox with `GetFolder` and sends one message with `CreateItem` / `SendAndSaveCopy`. SMTP remains available as a configuration fallback. EWS sends from the authenticated Exchange mailbox; `SMTP_FROM` is used only by the SMTP transport and remains part of the shared rendering configuration.

## Railway variables

Add these service variables to the existing SIMPL backend service:

| Variable | Value |
| --- | --- |
| `EMAIL_TRANSPORT` | `ews` |
| `OUTLOOK_PROVIDER` | `ews_ntlm` |
| `OUTLOOK_EWS_URL` | HTTPS EWS endpoint |
| `OUTLOOK_EWS_EMAIL` | Existing Exchange account identity |
| `OUTLOOK_EWS_PASSWORD` | Existing Exchange account password |
| `OUTLOOK_EWS_CONTENT_TYPE` | `text/xml; charset=utf-8` |
| `OUTLOOK_TIMEOUT_MS` | `30000` |
| `SMTP_FROM` | Approved sender address for the SMTP fallback |
| `SMTP_FROM_NAME` | `SIMPL` |
| `APP_URL` | `https://get-simpl.vercel.app` |

When `EMAIL_TRANSPORT=smtp`, configure the SMTP fallback instead:

| Variable | Value |
| --- | --- |
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | `587` for STARTTLS |
| `SMTP_USER` | SMTP-out account username |
| `SMTP_PASSWORD` | SMTP-out account password |

`EMAIL_POLL_INTERVAL_MS` is optional and defaults to `10000`. Keep `SUPABASE_URL` and `SUPABASE_SECRET_KEY` configured as before. Never add EWS or SMTP credentials to Git, frontend variables, logs or browser code.

`GET /api/health` reports `emailConfigured: true` only when the selected transport's required variables are present and valid. Railway logs `SIMPL email worker ready.` after it verifies the EWS mailbox or SMTP connection. It logs only bounded error codes, never credentials or message bodies.
