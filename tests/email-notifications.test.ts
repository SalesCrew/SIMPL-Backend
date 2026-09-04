import { describe, expect, it, vi } from "vitest";
import {
  createEventDrivenEmailWorker,
  deliverEmailBatch,
  emailNotificationsConfigured,
  mailOptionsForJob,
  missingEmailEnvironment,
  readEmailConfiguration,
  type EmailConfiguration,
  type EmailJob,
  type EmailOutboxStore,
} from "../src/email-notifications.js";

const configuration: EmailConfiguration = {
  EMAIL_TRANSPORT: "smtp",
  SMTP_HOST: "smtp.example.test",
  SMTP_PORT: 587,
  SMTP_USER: "mailer@example.test",
  SMTP_PASSWORD: "test-only-secret",
  SMTP_FROM: "noreply@example.test",
  SMTP_FROM_NAME: "SIMPL",
  APP_URL: "https://get-simpl.vercel.app/path-is-ignored",
};

const job: EmailJob = {
  outbox_id: 12,
  lease_token: "10000000-0000-4000-8000-000000000001",
  notification_id: "20000000-0000-4000-8000-000000000002",
  recipient_email: "recipient@example.test",
  recipient_name: "Kilian",
  actor_name: "Anna",
  workspace_name: "Development",
  workspace_id: "30000000-0000-4000-8000-000000000003",
  project_id: "50000000-0000-4000-8000-000000000005",
  card_id: "40000000-0000-4000-8000-000000000004",
  event_type: "comment.created",
  subject: "Dashboard",
  body: "Bitte kurz prüfen.",
  event_created_at: "2026-09-04T08:00:00.000Z",
  attempt_count: 1,
};

describe("workspace email delivery", () => {
  it("requires every secret-bearing Railway setting without exposing values", () => {
    expect(missingEmailEnvironment({})).toEqual([
      "SMTP_FROM",
      "APP_URL",
      "SMTP_HOST",
      "SMTP_PORT",
      "SMTP_USER",
      "SMTP_PASSWORD",
    ]);
    expect(emailNotificationsConfigured({})).toBe(false);
    expect(readEmailConfiguration({})).toBeNull();
    expect(emailNotificationsConfigured({
      EMAIL_TRANSPORT: configuration.EMAIL_TRANSPORT,
      SMTP_HOST: configuration.SMTP_HOST,
      SMTP_PORT: String(configuration.SMTP_PORT),
      SMTP_USER: configuration.SMTP_USER,
      SMTP_PASSWORD: configuration.SMTP_PASSWORD,
      SMTP_FROM: configuration.SMTP_FROM,
      APP_URL: configuration.APP_URL,
    })).toBe(true);
  });

  it("validates the HTTPS EWS/NTLM configuration independently of SMTP", () => {
    const environment = {
      EMAIL_TRANSPORT: "ews",
      SMTP_FROM: "noreply@example.test",
      APP_URL: "https://get-simpl.vercel.app",
      OUTLOOK_PROVIDER: "ews_ntlm",
      OUTLOOK_EWS_URL: "https://mail.example.test/EWS/Exchange.asmx",
      OUTLOOK_EWS_EMAIL: "mailer@example.test",
      OUTLOOK_EWS_PASSWORD: "test-only-secret",
      OUTLOOK_EWS_CONTENT_TYPE: "text/xml; charset=utf-8",
      OUTLOOK_TIMEOUT_MS: "30000",
    };
    expect(missingEmailEnvironment(environment)).toEqual([]);
    expect(emailNotificationsConfigured(environment)).toBe(true);
    expect(readEmailConfiguration(environment)).toMatchObject({
      EMAIL_TRANSPORT: "ews",
      OUTLOOK_TIMEOUT_MS: 30000,
    });
    expect(emailNotificationsConfigured({
      ...environment,
      OUTLOOK_EWS_URL: "http://mail.example.test/EWS/Exchange.asmx",
    })).toBe(false);
  });

  it("builds a private per-recipient German email with escaped event content", () => {
    const options = mailOptionsForJob({
      ...job,
      recipient_name: "<Kilian>",
      actor_name: "<script>alert(1)</script>",
      subject: "Card & Test",
      body: "<b>Bitte</b> & prüfen",
    }, configuration);
    expect(options.to).toBe(job.recipient_email);
    expect(options.subject).toBe("SIMPL · Neuer Kommentar: Card & Test");
    expect(options.messageId).toBe(
      `<simpl-${job.notification_id}@get-simpl.vercel.app>`,
    );
    expect(options.text).toContain("In SIMPL öffnen: https://get-simpl.vercel.app");
    expect(options.html).toContain("&lt;Kilian&gt;");
    expect(options.html).toContain("&lt;b&gt;Bitte&lt;/b&gt; &amp; prüfen");
    expect(options.html).not.toContain("<script>");
    expect(options.html).toContain("<v:roundrect");
    expect(options.html).toContain("simpl<span");
    expect(options.html).not.toMatch(/simpl<span[\s\S]+<v:roundrect/);
    expect(JSON.stringify(options)).not.toContain(configuration.SMTP_PASSWORD);
  });

  it("acknowledges a job only after SMTP accepts it", async () => {
    const store: EmailOutboxStore = {
      claim: vi.fn(async () => [job]),
      finish: vi.fn(async () => {}),
    };
    const transport = { sendMail: vi.fn(async () => ({ accepted: [job.recipient_email] })) };
    expect(await deliverEmailBatch(store, transport, configuration)).toEqual({
      claimed: 1,
      succeeded: 1,
      failed: 0,
      retryAfterMs: null,
    });
    expect(transport.sendMail).toHaveBeenCalledOnce();
    expect(store.finish).toHaveBeenCalledWith(
      job.outbox_id,
      job.lease_token,
      true,
    );
  });

  it("records only a bounded SMTP error code before retrying", async () => {
    const store: EmailOutboxStore = {
      claim: vi.fn(async () => [job]),
      finish: vi.fn(async () => {}),
    };
    const failure = Object.assign(new Error("contains-sensitive-server-detail"), {
      code: "EAUTH",
      responseCode: 535,
    });
    const transport = { sendMail: vi.fn(async () => { throw failure; }) };
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await deliverEmailBatch(store, transport, configuration)).toEqual({
      claimed: 1,
      succeeded: 0,
      failed: 1,
      retryAfterMs: 30000,
    });
    expect(store.finish).toHaveBeenCalledWith(
      job.outbox_id,
      job.lease_token,
      false,
      "SMTP:EAUTH:535",
    );
    expect(JSON.stringify(logged.mock.calls)).not.toContain(
      "contains-sensitive-server-detail",
    );
    logged.mockRestore();
  });

  it("renders archived-card mail explicitly", () => {
    const options = mailOptionsForJob({
      ...job,
      event_type: "card.archived",
    }, configuration);
    expect(options.subject).toBe("SIMPL · Karte archiviert: Dashboard");
    expect(options.text).toContain("Anna hat die Karte archiviert.");
  });

  it("drains immediately when an action wakes the event-driven worker", async () => {
    const store: EmailOutboxStore = {
      claim: vi.fn(async () => [job]),
      finish: vi.fn(async () => {}),
    };
    const transport = {
      verify: vi.fn(async () => true),
      sendMail: vi.fn(async () => ({ accepted: [job.recipient_email] })),
      close: vi.fn(),
    };
    const logged = vi.spyOn(console, "log").mockImplementation(() => {});
    const worker = createEventDrivenEmailWorker(store, transport, configuration);
    await worker.wake("comment.created");
    expect(transport.verify).toHaveBeenCalledOnce();
    expect(transport.sendMail).toHaveBeenCalledOnce();
    expect(store.finish).toHaveBeenCalledWith(
      job.outbox_id,
      job.lease_token,
      true,
    );
    worker.stop();
    expect(transport.close).toHaveBeenCalledOnce();
    logged.mockRestore();
  });
});
