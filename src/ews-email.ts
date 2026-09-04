import { NtlmClient, type AxiosInstance } from "axios-ntlm";
import type { SendMailOptions } from "nodemailer";

export interface EwsTransportConfiguration {
  OUTLOOK_EWS_URL: string;
  OUTLOOK_EWS_EMAIL: string;
  OUTLOOK_EWS_PASSWORD: string;
  OUTLOOK_EWS_CONTENT_TYPE: string;
  OUTLOOK_TIMEOUT_MS: number;
}

export interface EwsClient {
  post(
    url: string,
    data: string,
    configuration: { headers: Record<string, string> },
  ): Promise<{ data: unknown }>;
}

function xmlEscape(value: string) {
  return value
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "")
    .replace(/[&<>"']/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&apos;",
    })[character]!);
}

function oneLine(value: string) {
  return value.replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}

function ewsError(code: string) {
  return Object.assign(new Error("EWS request failed"), {
    code: `EWS:${code.replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 200)}`,
  });
}

function recipientAddress(value: unknown): string {
  if (Array.isArray(value)) {
    if (value.length !== 1) throw ewsError("INVALID_RECIPIENT_COUNT");
    return recipientAddress(value[0]);
  }
  if (typeof value === "object" && value !== null && "address" in value) {
    return recipientAddress((value as { address: unknown }).address);
  }
  if (typeof value !== "string") throw ewsError("INVALID_RECIPIENT");
  const trimmed = value.trim();
  const bracketed = trimmed.match(/<([^<>]+)>$/)?.[1]?.trim();
  const address = bracketed || trimmed;
  if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(address)) {
    throw ewsError("INVALID_RECIPIENT");
  }
  return address;
}

function textContent(value: unknown, label: string): string {
  if (typeof value === "string") return value;
  if (Buffer.isBuffer(value)) return value.toString("utf8");
  throw ewsError(`INVALID_${label}`);
}

function envelope(body: string) {
  return `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
  <s:Header><t:RequestServerVersion Version="Exchange2013" /></s:Header>
  <s:Body>${body}</s:Body>
</s:Envelope>`;
}

export function ewsVerifyEnvelope() {
  return envelope(
    "<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds><t:DistinguishedFolderId Id=\"inbox\" /></m:FolderIds></m:GetFolder>",
  );
}

export function ewsMailEnvelope(options: SendMailOptions) {
  const to = recipientAddress(options.to);
  const subject = oneLine(textContent(options.subject, "SUBJECT"));
  const html = options.html !== undefined
    ? textContent(options.html, "HTML_BODY")
    : textContent(options.text, "TEXT_BODY");
  if (!subject) throw ewsError("EMPTY_SUBJECT");

  return envelope(`<m:CreateItem MessageDisposition="SendAndSaveCopy">
    <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems" /></m:SavedItemFolderId>
    <m:Items><t:Message>
      <t:Subject>${xmlEscape(subject)}</t:Subject>
      <t:Body BodyType="HTML">${xmlEscape(html)}</t:Body>
      <t:ToRecipients><t:Mailbox><t:EmailAddress>${xmlEscape(to)}</t:EmailAddress></t:Mailbox></t:ToRecipients>
    </t:Message></m:Items>
  </m:CreateItem>`);
}

function responseCode(response: unknown) {
  const xml = typeof response === "string" ? response : String(response ?? "");
  return xml.match(/<(?:\w+:)?ResponseCode(?:\s[^>]*)?>([^<]+)</i)?.[1];
}

function ntlmIdentity(identity: string) {
  const separator = identity.indexOf("\\");
  if (separator > 0) {
    return {
      domain: identity.slice(0, separator),
      username: identity.slice(separator + 1),
    };
  }
  return { domain: "", username: identity };
}

function createClient(configuration: EwsTransportConfiguration): AxiosInstance {
  const identity = ntlmIdentity(configuration.OUTLOOK_EWS_EMAIL);
  return NtlmClient({
    ...identity,
    password: configuration.OUTLOOK_EWS_PASSWORD,
  }, {
    timeout: configuration.OUTLOOK_TIMEOUT_MS,
    maxRedirects: 0,
    responseType: "text",
    headers: { "Content-Type": configuration.OUTLOOK_EWS_CONTENT_TYPE },
  });
}

export function createEwsEmailTransport(
  configuration: EwsTransportConfiguration,
  client: EwsClient = createClient(configuration),
) {
  async function invoke(action: string, body: string) {
    try {
      const response = await client.post(configuration.OUTLOOK_EWS_URL, body, {
        headers: { SOAPAction: action },
      });
      const code = responseCode(response.data);
      if (code !== "NoError") throw ewsError(code || "MISSING_RESPONSE_CODE");
      return response;
    } catch (error) {
      const code = (error as { code?: unknown })?.code;
      if (typeof code === "string" && code.startsWith("EWS:")) throw error;
      throw ewsError(typeof code === "string" ? code : "REQUEST_FAILED");
    }
  }

  return {
    verify() {
      return invoke(
        "http://schemas.microsoft.com/exchange/services/2006/messages/GetFolder",
        ewsVerifyEnvelope(),
      );
    },
    sendMail(options: SendMailOptions) {
      return invoke(
        "http://schemas.microsoft.com/exchange/services/2006/messages/CreateItem",
        ewsMailEnvelope(options),
      );
    },
    close() {
      const axiosClient = client as AxiosInstance;
      for (const agent of [
        axiosClient.defaults.httpAgent,
        axiosClient.defaults.httpsAgent,
      ]) {
        if (typeof agent?.destroy === "function") agent.destroy();
      }
    },
  };
}
