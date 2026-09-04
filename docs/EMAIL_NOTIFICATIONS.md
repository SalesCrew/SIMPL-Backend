# SIMPL workspace email

SIMPL sends email for four committed workspace events:

- a new card;
- a new comment;
- a card marked as read;
- a card marked as completed.

The existing `private.publish_workspace_notification` function determines the recipients. It includes every active profile that can currently access the workspace and excludes the actor. The email outbox mirrors those per-recipient notification rows, so workspace isolation and pairwise NDA blocks are not reimplemented in application code.

Before each delivery, `claim_email_outbox` checks the recipient's active state and workspace access again. If access was removed after the event, the job is discarded without revealing its content. Jobs use leases, retry with exponential backoff and stop after eight failed attempts. A stable Message-ID reduces duplicate presentation if SMTP succeeds but the worker loses its database acknowledgement. Terminal delivery records are retained for 30 days.

## Railway variables

Add these service variables to the existing SIMPL backend service:

| Variable | Value |
| --- | --- |
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | `587` for STARTTLS |
| `SMTP_USER` | SMTP-out account username |
| `SMTP_PASSWORD` | SMTP-out account password |
| `SMTP_FROM` | Approved sender address |
| `SMTP_FROM_NAME` | `SIMPL` |
| `APP_URL` | `https://get-simpl.vercel.app` |

`EMAIL_POLL_INTERVAL_MS` is optional and defaults to `10000`. Keep `SUPABASE_URL` and `SUPABASE_SECRET_KEY` configured as before. Never add SMTP credentials to Git, frontend variables, logs or browser code.

`GET /api/health` reports `emailConfigured: true` only when the required SMTP variables are present and valid. Railway logs `SIMPL email worker ready.` after the server verifies the SMTP connection. It logs only bounded error codes, never credentials or message bodies.
