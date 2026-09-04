import { describe, expect, it, vi } from "vitest";
import {
  createEwsEmailTransport,
  ewsMailEnvelope,
  type EwsClient,
  type EwsTransportConfiguration,
} from "../src/ews-email.js";

const configuration: EwsTransportConfiguration = {
  OUTLOOK_EWS_URL: "https://mail.example.test/EWS/Exchange.asmx",
  OUTLOOK_EWS_EMAIL: "DOMAIN\\mailer",
  OUTLOOK_EWS_PASSWORD: "test-only-secret",
  OUTLOOK_EWS_CONTENT_TYPE: "text/xml; charset=utf-8",
  OUTLOOK_TIMEOUT_MS: 30000,
};

describe("EWS email transport", () => {
  it("creates a single-recipient, XML-safe SendAndSaveCopy request", () => {
    const xml = ewsMailEnvelope({
      to: "recipient@example.test",
      subject: "SIMPL <Update>\r\nignored",
      html: "<p>Card & Nachricht</p>",
    });
    expect(xml).toContain('MessageDisposition="SendAndSaveCopy"');
    expect(xml).toContain("recipient@example.test");
    expect(xml).toContain("SIMPL &lt;Update&gt; ignored");
    expect(xml).toContain("&lt;p&gt;Card &amp; Nachricht&lt;/p&gt;");
    expect(xml).not.toContain("test-only-secret");
  });

  it("verifies the mailbox and sends only after EWS returns NoError", async () => {
    const post = vi.fn(async (
      _url: string,
      _data: string,
      _request: { headers: Record<string, string> },
    ) => ({ data: "<m:ResponseCode>NoError</m:ResponseCode>" }));
    const transport = createEwsEmailTransport(
      configuration,
      { post } as EwsClient,
    );
    await transport.verify();
    await transport.sendMail({
      to: "recipient@example.test",
      subject: "SIMPL Update",
      html: "<p>Alles gut.</p>",
    });
    expect(post).toHaveBeenCalledTimes(2);
    expect(post.mock.calls[0]?.[2]?.headers.SOAPAction).toContain("GetFolder");
    expect(post.mock.calls[1]?.[2]?.headers.SOAPAction).toContain("CreateItem");
    expect(JSON.stringify(post.mock.calls)).not.toContain(
      configuration.OUTLOOK_EWS_PASSWORD,
    );
  });

  it("turns EWS response and network failures into bounded safe codes", async () => {
    const responseFailure = createEwsEmailTransport(configuration, {
      post: vi.fn(async () => ({
        data: "<m:ResponseCode>ErrorAccessDenied</m:ResponseCode>",
      })),
    });
    await expect(responseFailure.verify()).rejects.toMatchObject({
      code: "EWS:ErrorAccessDenied",
    });

    const networkFailure = createEwsEmailTransport(configuration, {
      post: vi.fn(async () => {
        throw Object.assign(new Error("contains-sensitive-detail"), {
          code: "ETIMEDOUT",
        });
      }),
    });
    await expect(networkFailure.verify()).rejects.toMatchObject({
      code: "EWS:ETIMEDOUT",
    });
  });
});
