// Neer Nilai — notify edge function
// Two entry points:
//   1. Database webhook on `reports` (INSERT/UPDATE): alert officers when delivered = false.
//   2. Scheduled call with {"type":"digest"}: noon digest of "No" and "not reported" per block.
//
// Secrets (supabase secrets set ...):
//   RESEND_API_KEY   email via Resend (free tier 3,000/month). Sender must be a verified domain.
//   FROM_EMAIL       e.g. "Neer Nilai <alerts@yourdomain.in>"
//   WA_TOKEN         WhatsApp Cloud API permanent token (optional)
//   WA_PHONE_ID      WhatsApp Cloud API phone number id (optional)
//   WA_TEMPLATE      approved utility template name, default "water_not_delivered"
//   APP_URL          dashboard link put in messages

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const APP_URL = Deno.env.get("APP_URL") ?? "";

type Officer = {
  id: string; name: string; role: string; email: string; phone: string | null;
  alert_email: boolean; alert_whatsapp: boolean; alert_digest: boolean;
  district_id: number | null; block_id: number | null;
};

Deno.serve(async (req) => {
  const body = await req.json().catch(() => ({}));
  try {
    if (body.type === "digest") return json(await runDigest());
    if (body.type === "INSERT" || body.type === "UPDATE") return json(await onReport(body.record));
    return json({ ok: true, ignored: true });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e) }, 500);
  }
});

// ------------------------------------------------------------------ "No" alert
async function onReport(record: { id: number; panchayat_id: number; delivered: boolean; reason: string | null; comment: string | null; report_date: string }) {
  if (record.delivered) return { ok: true, skipped: "delivered" };

  const { data: p } = await supabase
    .from("panchayats")
    .select("id, code, name, name_ta, block:blocks(id, name, district_id, district:districts(id, name))")
    .eq("id", record.panchayat_id).single();
  if (!p) return { ok: false, error: "panchayat not found" };

  const { data: reason } = await supabase.from("reasons").select("label_en, label_ta").eq("code", record.reason ?? "").maybeSingle();

  // Escalate to district if yesterday was also "No".
  const y = new Date(record.report_date); y.setDate(y.getDate() - 1);
  const { data: prev } = await supabase.from("reports").select("delivered")
    .eq("panchayat_id", p.id).eq("report_date", y.toISOString().slice(0, 10)).maybeSingle();
  const consecutive = prev && prev.delivered === false;

  const block = p.block as any;
  const officers = await officersFor(block.district_id, block.id, consecutive ? ["block", "district", "state"] : ["block", "state"]);

  const subject = `Water NOT delivered: ${p.name} (${block.name})${consecutive ? " — 2nd day" : ""}`;
  const text = [
    `Panchayat: ${p.name} / ${p.name_ta ?? ""} (${p.code})`,
    `Block: ${block.name}, District: ${block.district?.name}`,
    `Date: ${record.report_date}`,
    `Reason: ${reason?.label_en ?? record.reason ?? "-"}`,
    record.comment ? `Comment: ${record.comment}` : null,
    consecutive ? `Second consecutive day without water.` : null,
    APP_URL ? `Dashboard: ${APP_URL}` : null,
  ].filter(Boolean).join("\n");

  const results = [];
  for (const o of officers) {
    if (o.alert_email) results.push(await sendEmail(o, subject, text, record.id, "no_delivery"));
    if (o.alert_whatsapp && o.phone) results.push(await sendWhatsApp(o, [p.name, block.name, reason?.label_en ?? "-", record.report_date], record.id, "no_delivery"));
  }
  return { ok: true, sent: results };
}

// ------------------------------------------------------------------ noon digest
async function runDigest() {
  const { data: rows, error } = await supabase.from("v_today")
    .select("district_id, district, block_id, block, panchayat, code, status, reason");
  if (error) throw error;

  const { data: officers } = await supabase.from("officers").select("*").eq("alert_digest", true);
  const results = [];
  for (const o of (officers ?? []) as Officer[]) {
    const mine = rows!.filter((r) =>
      o.role === "state" || (o.role === "district" && r.district_id === o.district_id) || (o.role === "block" && r.block_id === o.block_id));
    const no = mine.filter((r) => r.status === "no");
    const silent = mine.filter((r) => r.status === "not_reported");
    const yes = mine.length - no.length - silent.length;
    if (no.length === 0 && silent.length === 0) continue;

    const subject = `Water status 12:00 — ${no.length} not delivered, ${silent.length} not reported`;
    const text = [
      `Delivered: ${yes}   Not delivered: ${no.length}   Not reported: ${silent.length}   (of ${mine.length})`,
      "",
      no.length ? "NOT DELIVERED" : null,
      ...no.map((r) => `  ${r.block} / ${r.panchayat} — ${r.reason ?? ""}`),
      silent.length ? "\nNOT REPORTED BY NOON" : null,
      ...silent.map((r) => `  ${r.block} / ${r.panchayat} (${r.code})`),
      APP_URL ? `\nDashboard: ${APP_URL}` : null,
    ].filter((l) => l !== null).join("\n");

    if (o.alert_email) results.push(await sendEmail(o, subject, text, null, "digest"));
  }
  return { ok: true, sent: results.length };
}

// ------------------------------------------------------------------ helpers
async function officersFor(districtId: number, blockId: number, roles: string[]) {
  const { data } = await supabase.from("officers").select("*");
  return ((data ?? []) as Officer[]).filter((o) =>
    roles.includes(o.role) && (
      o.role === "state" ||
      (o.role === "district" && o.district_id === districtId) ||
      (o.role === "block" && o.block_id === blockId)));
}

async function sendEmail(o: Officer, subject: string, text: string, reportId: number | null, kind: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  let status = "skipped", detail = "RESEND_API_KEY not set";
  if (key) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: Deno.env.get("FROM_EMAIL") ?? "Neer Nilai <onboarding@resend.dev>", to: [o.email], subject, text }),
    });
    status = res.ok ? "sent" : "failed";
    detail = res.ok ? "" : await res.text();
  }
  await supabase.from("notifications").insert({ report_id: reportId, officer_id: o.id, channel: "email", kind, status, detail });
  return { officer: o.email, channel: "email", status };
}

// WhatsApp Cloud API utility template with 4 body parameters:
// {{1}} panchayat, {{2}} block, {{3}} reason, {{4}} date
async function sendWhatsApp(o: Officer, params: string[], reportId: number | null, kind: string) {
  const token = Deno.env.get("WA_TOKEN"), phoneId = Deno.env.get("WA_PHONE_ID");
  let status = "skipped", detail = "WA_TOKEN/WA_PHONE_ID not set";
  if (token && phoneId) {
    const res = await fetch(`https://graph.facebook.com/v20.0/${phoneId}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp", to: o.phone!.replace(/^\+/, ""), type: "template",
        template: {
          name: Deno.env.get("WA_TEMPLATE") ?? "water_not_delivered",
          language: { code: "en" },
          components: [{ type: "body", parameters: params.map((text) => ({ type: "text", text })) }],
        },
      }),
    });
    status = res.ok ? "sent" : "failed";
    detail = res.ok ? "" : await res.text();
  }
  await supabase.from("notifications").insert({ report_id: reportId, officer_id: o.id, channel: "whatsapp", kind, status, detail });
  return { officer: o.phone, channel: "whatsapp", status };
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}
