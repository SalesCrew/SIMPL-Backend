import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import nodemailer, { type SendMailOptions, type Transporter } from "nodemailer";
import { z } from "zod";
import { createEwsEmailTransport } from "./ews-email.js";

const commonEmailConfigurationSchema = z.object({
  SMTP_FROM: z.string().trim().email(),
  SMTP_FROM_NAME: z.string().trim().min(1).max(100).default("SIMPL"),
  APP_URL: z.string().trim().url(),
});

const smtpEmailConfigurationSchema = commonEmailConfigurationSchema.extend({
  EMAIL_TRANSPORT: z.literal("smtp"),
  SMTP_HOST: z.string().trim().min(1),
  SMTP_PORT: z.coerce.number().int().min(1).max(65535),
  SMTP_USER: z.string().trim().min(1),
  SMTP_PASSWORD: z.string().min(1),
});

const ewsEmailConfigurationSchema = commonEmailConfigurationSchema.extend({
  EMAIL_TRANSPORT: z.literal("ews"),
  OUTLOOK_PROVIDER: z.literal("ews_ntlm"),
  OUTLOOK_EWS_URL: z.string().trim().url().refine(
    (value) => new URL(value).protocol === "https:",
    "EWS must use HTTPS",
  ),
  OUTLOOK_EWS_EMAIL: z.string().trim().min(1),
  OUTLOOK_EWS_PASSWORD: z.string().min(1),
  OUTLOOK_EWS_CONTENT_TYPE: z.string().trim().regex(
    /^text\/xml\s*;\s*charset=utf-8$/i,
  ),
  OUTLOOK_TIMEOUT_MS: z.coerce.number().int().min(1_000).max(120_000),
});

const emailConfigurationSchema = z.discriminatedUnion("EMAIL_TRANSPORT", [
  smtpEmailConfigurationSchema,
  ewsEmailConfigurationSchema,
]);

const emailJobSchema = z.object({
  outbox_id: z.coerce.number().int().positive(),
  lease_token: z.string().uuid(),
  notification_id: z.string().uuid(),
  recipient_email: z.string().email(),
  recipient_name: z.string().min(1),
  actor_name: z.string().min(1),
  workspace_name: z.string().min(1),
  workspace_id: z.string().uuid(),
  card_id: z.string().uuid().nullable(),
  event_type: z.enum([
    "comment.created",
    "card.created",
    "card.reviewed",
    "card.completed",
  ]),
  subject: z.string().min(1),
  body: z.string(),
  event_created_at: z.string().datetime({ offset: true }),
  attempt_count: z.coerce.number().int().min(1).max(8),
});

export type EmailConfiguration = z.infer<typeof emailConfigurationSchema>;
export type SmtpEmailConfiguration = z.infer<typeof smtpEmailConfigurationSchema>;
export type EwsEmailConfiguration = z.infer<typeof ewsEmailConfigurationSchema>;
export type EmailJob = z.infer<typeof emailJobSchema>;

export interface EmailOutboxStore {
  claim(limit: number): Promise<EmailJob[]>;
  finish(
    id: number,
    lease: string,
    succeeded: boolean,
    error?: string,
  ): Promise<void>;
}

export interface EmailTransport {
  verify(): Promise<unknown>;
  sendMail(options: SendMailOptions): Promise<unknown>;
  close(): void;
}

const requiredCommonEmailEnvironment = [
  "SMTP_FROM",
  "APP_URL",
] as const;

const requiredSmtpEmailEnvironment = [
  "SMTP_HOST",
  "SMTP_PORT",
  "SMTP_USER",
  "SMTP_PASSWORD",
] as const;

const requiredEwsEmailEnvironment = [
  "OUTLOOK_PROVIDER",
  "OUTLOOK_EWS_URL",
  "OUTLOOK_EWS_EMAIL",
  "OUTLOOK_EWS_PASSWORD",
  "OUTLOOK_EWS_CONTENT_TYPE",
  "OUTLOOK_TIMEOUT_MS",
] as const;

function selectedEmailTransport(environment: NodeJS.ProcessEnv) {
  return environment.EMAIL_TRANSPORT?.trim().toLowerCase() || "smtp";
}

function normalizedEmailEnvironment(environment: NodeJS.ProcessEnv) {
  return {
    ...environment,
    EMAIL_TRANSPORT: selectedEmailTransport(environment),
  };
}

export function missingEmailEnvironment(
  environment: NodeJS.ProcessEnv = process.env,
): string[] {
  const transportEnvironment = selectedEmailTransport(environment) === "ews"
    ? requiredEwsEmailEnvironment
    : requiredSmtpEmailEnvironment;
  return [...requiredCommonEmailEnvironment, ...transportEnvironment].filter(
    (name) => !environment[name]?.trim(),
  );
}

export function emailNotificationsConfigured(
  environment: NodeJS.ProcessEnv = process.env,
): boolean {
  if (missingEmailEnvironment(environment).length) return false;
  return emailConfigurationSchema.safeParse(
    normalizedEmailEnvironment(environment),
  ).success;
}

export function readEmailConfiguration(
  environment: NodeJS.ProcessEnv = process.env,
): EmailConfiguration | null {
  if (missingEmailEnvironment(environment).length) return null;
  return emailConfigurationSchema.parse(normalizedEmailEnvironment(environment));
}

function oneLine(value: string) {
  return value.replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#039;",
  })[character]!);
}

function compactBody(value: string, limit = 1200) {
  const body = value.trim();
  return body.length > limit ? `${body.slice(0, limit - 1).trimEnd()}…` : body;
}

const eventCopy: Record<EmailJob["event_type"], {
  subject: string;
  sentence: (actor: string) => string;
}> = {
  "card.created": {
    subject: "Neue Karte",
    sentence: (actor) => `${actor} hat eine neue Karte erstellt.`,
  },
  "comment.created": {
    subject: "Neuer Kommentar",
    sentence: (actor) => `${actor} hat einen Kommentar geschrieben.`,
  },
  "card.reviewed": {
    subject: "Karte gelesen",
    sentence: (actor) => `${actor} hat die Karte als gelesen markiert.`,
  },
  "card.completed": {
    subject: "Karte erledigt",
    sentence: (actor) => `${actor} hat die Karte als erledigt markiert.`,
  },
};

export function mailOptionsForJob(
  job: EmailJob,
  configuration: EmailConfiguration,
): SendMailOptions {
  const copy = eventCopy[job.event_type];
  const actor = oneLine(job.actor_name);
  const workspace = oneLine(job.workspace_name);
  const card = oneLine(job.subject);
  const eventBody = job.event_type === "comment.created"
    ? compactBody(job.body)
    : "";
  const appUrl = new URL(configuration.APP_URL).origin;
  const occurred = new Intl.DateTimeFormat("de-AT", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Europe/Vienna",
  }).format(new Date(job.event_created_at));
  const bodyText = eventBody ? `\n\n„${eventBody}“` : "";
  const bodyHtml = eventBody
    ? `<blockquote style="margin:20px 0 0;padding:14px 16px;border-left:3px solid #91a882;background:#f6f8f3;color:#425346;white-space:pre-wrap">${escapeHtml(eventBody)}</blockquote>`
    : "";

  return {
    from: {
      name: oneLine(configuration.SMTP_FROM_NAME),
      address: configuration.SMTP_FROM,
    },
    to: job.recipient_email,
    subject: `SIMPL · ${copy.subject}: ${card}`.slice(0, 180),
    messageId: `<simpl-${job.notification_id}@${new URL(appUrl).hostname}>`,
    headers: {
      "X-SIMPL-Event": job.event_type,
      "X-SIMPL-Notification": job.notification_id,
    },
    text: [
      `Hallo ${oneLine(job.recipient_name)},`,
      "",
      copy.sentence(actor) + bodyText,
      "",
      `Workspace: ${workspace}`,
      `Karte: ${card}`,
      `Zeitpunkt: ${occurred}`,
      "",
      `In SIMPL öffnen: ${appUrl}`,
      "",
      "Du erhältst diese Nachricht, weil du Zugriff auf diesen Workspace hast.",
    ].join("\n"),
    html: `<!doctype html><html><body style="margin:0;background:#f6f8f3;color:#263d31;font-family:Arial,sans-serif"><div style="max-width:620px;margin:0 auto;padding:36px 20px"><div style="font-size:24px;font-weight:700;margin-bottom:28px">simpl</div><div style="background:#fff;border:1px solid #e3e9df;border-radius:16px;padding:28px"><p style="margin:0 0 18px">Hallo ${escapeHtml(oneLine(job.recipient_name))},</p><h1 style="margin:0 0 12px;font-size:21px;line-height:1.35">${escapeHtml(copy.subject)}</h1><p style="margin:0;color:#53624e;line-height:1.65">${escapeHtml(copy.sentence(actor))}</p>${bodyHtml}<dl style="margin:24px 0;color:#53624e;font-size:14px;line-height:1.7"><dt style="font-weight:700">Workspace</dt><dd style="margin:0 0 8px">${escapeHtml(workspace)}</dd><dt style="font-weight:700">Karte</dt><dd style="margin:0 0 8px">${escapeHtml(card)}</dd><dt style="font-weight:700">Zeitpunkt</dt><dd style="margin:0">${escapeHtml(occurred)}</dd></dl><a href="${escapeHtml(appUrl)}" style="display:inline-block;padding:11px 16px;border-radius:9px;background:#334f3d;color:#fff;text-decoration:none;font-size:14px;font-weight:700">In SIMPL öffnen</a></div><p style="margin:18px 4px 0;color:#82907c;font-size:12px;line-height:1.6">Du erhältst diese Nachricht, weil du Zugriff auf diesen Workspace hast.</p></div></body></html>`,
  };
}

export function createEmailOutboxStore(
  admin: SupabaseClient,
): EmailOutboxStore {
  return {
    async claim(limit) {
      const result = await admin.rpc("claim_email_outbox", { p_limit: limit });
      if (result.error) throw result.error;
      return emailJobSchema.array().parse(result.data || []);
    },
    async finish(id, lease, succeeded, error) {
      const result = await admin.rpc("finish_email_outbox", {
        p_id: id,
        p_lease: lease,
        p_succeeded: succeeded,
        p_error: error || null,
      });
      if (result.error) throw result.error;
      if (!result.data) throw new Error("EMAIL_OUTBOX_LEASE_LOST");
    },
  };
}

function errorCode(error: unknown) {
  const details = error as { code?: unknown; responseCode?: unknown };
  const code = typeof details?.code === "string" ? details.code : "DELIVERY_FAILED";
  if (code.startsWith("EWS:")) return code.slice(0, 500);
  const responseCode = Number.isInteger(details?.responseCode)
    ? String(details.responseCode)
    : "";
  return ["SMTP", code, responseCode].filter(Boolean).join(":").slice(0, 500);
}

export async function deliverEmailBatch(
  store: EmailOutboxStore,
  transport: Pick<EmailTransport, "sendMail">,
  configuration: EmailConfiguration,
  limit = 20,
): Promise<number> {
  const jobs = await store.claim(limit);
  for (const job of jobs) {
    try {
      await transport.sendMail(mailOptionsForJob(job, configuration));
    } catch (error) {
      const code = errorCode(error);
      console.error("SIMPL email delivery failed", {
        outboxId: job.outbox_id,
        code,
      });
      await store.finish(job.outbox_id, job.lease_token, false, code);
      continue;
    }
    await store.finish(job.outbox_id, job.lease_token, true);
  }
  return jobs.length;
}

export function createSmtpEmailTransport(
  configuration: SmtpEmailConfiguration,
): Transporter {
  return nodemailer.createTransport({
    host: configuration.SMTP_HOST,
    port: configuration.SMTP_PORT,
    secure: configuration.SMTP_PORT === 465,
    requireTLS: configuration.SMTP_PORT !== 465,
    auth: {
      user: configuration.SMTP_USER,
      pass: configuration.SMTP_PASSWORD,
    },
    tls: { minVersion: "TLSv1.2" },
    pool: true,
    maxConnections: 3,
    maxMessages: 100,
  });
}

export function createEmailTransport(
  configuration: EmailConfiguration,
): EmailTransport {
  return configuration.EMAIL_TRANSPORT === "ews"
    ? createEwsEmailTransport(configuration)
    : createSmtpEmailTransport(configuration);
}

export function startEmailNotificationWorker(
  environment: NodeJS.ProcessEnv = process.env,
) {
  const configuration = readEmailConfiguration(environment);
  if (!configuration) {
    console.log("SIMPL email worker disabled: email configuration incomplete.");
    return { stop() {} };
  }
  const activeConfiguration = configuration;
  const url = environment.SUPABASE_URL;
  const secret = environment.SUPABASE_SECRET_KEY;
  if (!url || !secret) {
    console.log("SIMPL email worker disabled: Supabase server configuration incomplete.");
    return { stop() {} };
  }

  const admin = createClient(url, secret, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const store = createEmailOutboxStore(admin);
  const transport = createEmailTransport(activeConfiguration);
  const intervalMs = Math.max(
    5_000,
    Number(environment.EMAIL_POLL_INTERVAL_MS || 10_000) || 10_000,
  );
  let stopped = false;
  let running = false;
  let verified = false;

  async function tick() {
    if (stopped || running) return;
    running = true;
    try {
      if (!verified) {
        await transport.verify();
        verified = true;
        console.log("SIMPL email worker ready.");
      }
      for (let batch = 0; batch < 5; batch += 1) {
        const delivered = await deliverEmailBatch(
          store,
          transport,
          activeConfiguration,
        );
        if (delivered < 20) break;
      }
    } catch (error) {
      console.error("SIMPL email worker unavailable", { code: errorCode(error) });
    } finally {
      running = false;
    }
  }

  const timer = setInterval(() => void tick(), intervalMs);
  timer.unref();
  void tick();
  return {
    stop() {
      stopped = true;
      clearInterval(timer);
      transport.close();
    },
  };
}
