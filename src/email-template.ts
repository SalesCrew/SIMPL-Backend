export interface SimplEmailTemplateData {
  recipientName: string;
  eventLabel: string;
  eventIcon: string;
  headline: string;
  message: string;
  workspace: string;
  card: string;
  timestamp: string;
  actionUrl: string;
  commentBody?: string;
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

function multiline(value: string) {
  return escapeHtml(value).replace(/\r?\n/g, "<br>");
}

export function renderSimplEmailHtml(data: SimplEmailTemplateData): string {
  const comment = data.commentBody?.trim() || "";
  const estimatedCommentLines = comment
    ? Math.min(6, Math.max(1, Math.ceil(comment.length / 64)))
    : 0;
  const commentHeight = comment ? 48 + estimatedCommentLines * 20 : 0;
  const cardHeight = 540 + commentHeight;
  const commentHtml = comment ? `
                <tr><td colspan="3" height="22" style="height:22px;font-size:0;line-height:0;">&nbsp;</td></tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;">
                    <table role="presentation" width="524" cellspacing="0" cellpadding="0" border="0" bgcolor="#f6f8f3" style="width:100%;background-color:#f6f8f3;border-collapse:separate;">
                      <tr>
                        <td width="3" bgcolor="#91a882" style="width:3px;background-color:#91a882;font-size:0;line-height:0;">&nbsp;</td>
                        <td style="padding:14px 16px;color:#526451;font-size:14px;line-height:20px;">${multiline(comment)}</td>
                      </tr>
                    </table>
                  </td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>` : "";

  return `<!doctype html>
<html lang="de" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="x-apple-disable-message-reformatting">
  <title>SIMPL · ${escapeHtml(data.headline)}</title>
  <!--[if mso]>
  <xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml>
  <style>
    td, a, div { font-family:Arial,Helvetica,sans-serif !important; }
    .simpl-card { background:transparent !important; border:0 !important; }
    .simpl-details { background:#ffffff !important; border-left:0 !important; border-right:0 !important; }
  </style>
  <![endif]-->
</head>
<body style="margin:0;padding:0;background-color:#f3f6f1;color:#263d31;font-family:Arial,Helvetica,sans-serif;">
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${escapeHtml(data.message)}</div>
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#f3f6f1" style="width:100%;background-color:#f3f6f1;">
    <tr>
      <td align="center" style="padding:40px 16px;">
        <table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" style="width:100%;max-width:600px;font-family:Arial,Helvetica,sans-serif;">
          <tr>
            <td>
              <!--[if mso]>
              <v:roundrect arcsize="5%" fillcolor="#ffffff" strokecolor="#dfe7db" strokeweight="1px" style="width:600px;height:${cardHeight}px;v-text-anchor:top;">
                <w:anchorlock/>
                <v:textbox inset="0,0,0,0">
              <![endif]-->
              <table class="simpl-card" role="presentation" width="600" height="${cardHeight}" cellspacing="0" cellpadding="0" border="0" bgcolor="#ffffff" style="width:100%;max-width:600px;height:${cardHeight}px;background-color:#ffffff;border:1px solid #dfe7db;border-radius:18px;border-collapse:separate;overflow:hidden;font-family:Arial,Helvetica,sans-serif;">
                <tr>
                  <td width="38" height="26" style="width:38px;height:26px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" height="26" style="width:524px;height:26px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="38" height="26" style="width:38px;height:26px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;">
                    <div style="font-family:Arial,Helvetica,sans-serif;font-size:26px;line-height:32px;font-weight:700;letter-spacing:-1px;color:#294737;">simpl<span style="color:#83a06f;">.</span></div>
                  </td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>
                <tr><td colspan="3" height="24" style="height:24px;font-size:0;line-height:0;">&nbsp;</td></tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;">
                    <table role="presentation" cellspacing="0" cellpadding="0" border="0">
                      <tr>
                        <!--[if !mso]><!-- -->
                        <td width="42" height="42" align="center" valign="middle" bgcolor="#edf3e9" style="width:42px;height:42px;border-radius:21px;background-color:#edf3e9;color:#517044;font-size:21px;line-height:42px;font-weight:700;">${escapeHtml(data.eventIcon)}</td>
                        <!--<![endif]-->
                        <!--[if mso]>
                        <td width="28" height="42" align="left" valign="middle" style="width:28px;height:42px;color:#517044;font-size:22px;line-height:42px;font-weight:700;">${escapeHtml(data.eventIcon)}</td>
                        <![endif]-->
                        <td width="14" style="width:14px;font-size:0;line-height:0;">&nbsp;</td>
                        <td valign="middle" style="color:#6d8168;font-size:11px;line-height:16px;font-weight:700;letter-spacing:1.3px;">${escapeHtml(data.eventLabel)}</td>
                      </tr>
                    </table>
                  </td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>
                <tr><td colspan="3" height="24" style="height:24px;font-size:0;line-height:0;">&nbsp;</td></tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;font-size:30px;line-height:38px;font-weight:700;letter-spacing:-0.7px;color:#263d31;">${escapeHtml(data.headline)}</td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>
                <tr><td colspan="3" height="14" style="height:14px;font-size:0;line-height:0;">&nbsp;</td></tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;font-size:16px;line-height:26px;color:#5e6f59;">Hallo ${escapeHtml(data.recipientName)},<br>${escapeHtml(data.message)}</td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>${commentHtml}
                <tr><td colspan="3" height="30" style="height:30px;font-size:0;line-height:0;">&nbsp;</td></tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;">
                    <table class="simpl-details" role="presentation" width="524" cellspacing="0" cellpadding="0" border="0" bgcolor="#f7f9f5" style="width:100%;background-color:#f7f9f5;border:1px solid #e5ebe1;border-radius:12px;border-collapse:separate;overflow:hidden;">
                      <tr>
                        <td width="112" valign="top" style="padding:18px 12px 11px 18px;color:#81907b;font-size:11px;line-height:17px;font-weight:700;letter-spacing:.8px;">KARTE</td>
                        <td valign="top" style="padding:16px 18px 11px 0;color:#2f4638;font-size:16px;line-height:22px;font-weight:700;">${escapeHtml(data.card)}</td>
                      </tr>
                      <tr><td colspan="2" height="1" style="height:1px;background-color:#e5ebe1;font-size:0;line-height:0;">&nbsp;</td></tr>
                      <tr>
                        <td width="112" valign="top" style="padding:13px 12px 10px 18px;color:#81907b;font-size:11px;line-height:17px;font-weight:700;letter-spacing:.8px;">WORKSPACE</td>
                        <td valign="top" style="padding:11px 18px 10px 0;color:#435747;font-size:14px;line-height:22px;">${escapeHtml(data.workspace)}</td>
                      </tr>
                      <tr><td colspan="2" height="1" style="height:1px;background-color:#e5ebe1;font-size:0;line-height:0;">&nbsp;</td></tr>
                      <tr>
                        <td width="112" valign="top" style="padding:13px 12px 16px 18px;color:#81907b;font-size:11px;line-height:17px;font-weight:700;letter-spacing:.8px;">ZEITPUNKT</td>
                        <td valign="top" style="padding:11px 18px 16px 0;color:#435747;font-size:14px;line-height:22px;">${escapeHtml(data.timestamp)}</td>
                      </tr>
                    </table>
                  </td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>
                <tr><td colspan="3" height="30" style="height:30px;font-size:0;line-height:0;">&nbsp;</td></tr>
                <tr>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                  <td width="524" style="width:524px;">
                    <!--[if !mso]><!-- -->
                    <table role="presentation" cellspacing="0" cellpadding="0" border="0">
                      <tr><td bgcolor="#334f3d" style="background-color:#334f3d;border-radius:9px;"><a href="${escapeHtml(data.actionUrl)}" style="display:inline-block;padding:13px 19px;color:#ffffff;font-size:14px;line-height:18px;font-weight:700;text-decoration:none;">In SIMPL öffnen&nbsp;&nbsp;→</a></td></tr>
                    </table>
                    <!--<![endif]-->
                    <!--[if mso]>
                    <a href="${escapeHtml(data.actionUrl)}" style="color:#334f3d;font-size:14px;line-height:20px;font-weight:700;text-decoration:underline;">In SIMPL öffnen&nbsp;&nbsp;→</a>
                    <![endif]-->
                  </td>
                  <td width="38" style="width:38px;font-size:0;line-height:0;">&nbsp;</td>
                </tr>
                <tr><td colspan="3" height="38" style="height:38px;font-size:0;line-height:0;">&nbsp;</td></tr>
              </table>
              <!--[if mso]>
                </v:textbox>
              </v:roundrect>
              <![endif]-->
            </td>
          </tr>
          <tr>
            <td style="padding:20px 5px 0 5px;color:#879582;font-size:12px;line-height:19px;">Du erhältst diese Nachricht entsprechend deinen persönlichen E-Mail-Einstellungen.<br>SIMPL · Ein Board. Ein Team.</td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}
