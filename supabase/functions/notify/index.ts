// Neer Nilai — notify edge function (GLR level)
// Two entry points:
//   1. Database webhook on `reports` (INSERT/UPDATE): alert staff when status is 'partial' or 'no'.
//        partial → panchayat officer;  no → panchayat + block officers;  2nd consecutive day → district added.
//   2. Scheduled call with {"type":"digest"}: noon digest of Partial / No / not-reported GLRs per officer's scope.
//
// Secrets (supabase secrets set ...):
//   RESEND_API_KEY   email via Resend (free tier 3,000/month). Sender must be a verified domain.
//   FROM_EMAIL       e.g. "Neer Nilai <alerts@yourdomain.in>"
//   WA_TOKEN         WhatsApp Cloud API permanent token (optional)
//   WA_PHONE_ID      WhatsApp Cloud API phone number id (optional)
//   WA_TEMPLATE      approved utility template name, default "water_supply_issue"
//   APP_URL          dashboard link put in messages

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = Deno.env.get("APP_URL") ?? "";

type Officer = {
  id: string; name: string; role: "state" | "district" | "block" | "panchayat"; email: string; phone: string | null;
  alert_email: boolean; alert_whatsapp: boolean; alert_digest: boolean;
  district_id: number | null; block_id: number | null; panchayat_id: number | null;
};
type Glr = { glr_id: number; code: string; glr: string; glr_ta: string | null; habitation: string; panchayat_id: number; panchayat: string; block_id: number; block: string; district_id: number; district: string };
type Report = { id: number; glr_id: number; status: "yes" | "partial" | "no"; source_ok: string | null; pump_ok: string | null; glr_filled: string | null; problem: string | null; remarks: string | null; report_date: string };

Deno.serve(async (req) => {
  const body = await req.json().catch(() => ({}));
  try {
    if (body.type === "digest") return json(await runDigest());
    if (body.type === "INSERT" || body.type === "UPDATE") return json(await onReport(body.record as Report));
    return json({ ok: true, ignored: true });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e) }, 500);
  }
});

function inScope(o: Officer, g: Glr) {
  return o.role === "state"
    || (o.role === "district" && o.district_id === g.district_id)
    || (o.role === "block" && o.block_id === g.block_id)
    || (o.role === "panchayat" && o.panchayat_id === g.panchayat_id);
}

// ------------------------------------------------------------------ issue alert
async function onReport(record: Report) {
  if (record.status === "yes") return { ok: true, skipped: "normal supply" };
  const partial = record.status === "partial";

  const { data: g } = await supabase.from("v_glr").select("*").eq("glr_id", record.glr_id).single();
  if (!g) return { ok: false, error: "glr not found" };
  const { data: problem } = await supabase.from("problems").select("label_en").eq("code", record.problem ?? "").maybeSingle();

  // Escalate if yesterday was also not normal.
  const y = new Date(record.report_date); y.setDate(y.getDate() - 1);
  const { data: prev } = await supabase.from("reports").select("status").eq("glr_id", g.glr_id).eq("report_date", y.toISOString().slice(0, 10)).maybeSingle();
  const consecutive = !!prev && prev.status !== "yes";

  const roles: Officer["role"][] = partial ? ["panchayat"] : ["panchayat", "block"];
  if (consecutive) roles.push("block", "district");
  roles.push("state");
  const { data: all } = await supabase.from("officers").select("*");
  const officers = ((all ?? []) as Officer[]).filter((o) => roles.includes(o.role) && inScope(o, g as Glr));

  const subject = `${partial ? "PARTIAL water supply" : "NO water supply"}: ${g.glr}, ${g.panchayat} (${g.block})${consecutive ? " — 2nd day" : ""}`;
  const dl = (v: string | null) => v === "yes" ? "Yes" : v === "no" ? "No" : v === "unknown" ? "Don't know" : "-";
  const text = [
    `Status: ${partial ? "Partial (less than normal)" : "Not supplied"}`,
    `GLR: ${g.glr} / ${g.glr_ta ?? ""} (${g.code})`,
    `Habitation: ${g.habitation}, Panchayat: ${g.panchayat}, Block: ${g.block}, District: ${g.district}`,
    `Date: ${record.report_date}`,
    `Source sufficient: ${dl(record.source_ok)}   Pump normal: ${dl(record.pump_ok)}   GLR filled: ${dl(record.glr_filled)}`,
    `Problem: ${problem?.label_en ?? record.problem ?? "-"}`,
    record.remarks ? `Action taken / remarks: ${record.remarks}` : null,
    consecutive ? `Second consecutive day with a supply problem.` : null,
    APP_URL ? `Dashboard: ${APP_URL}` : null,
  ].filter(Boolean).join("\n");

  const results = [];
  for (const o of officers) {
    if (o.alert_email) results.push(await sendEmail(o, subject, text, record.id, "issue"));
    if (o.alert_whatsapp && o.phone) results.push(await sendWhatsApp(o, [`${g.glr} (${g.panchayat})`, g.block, `${partial ? "Partial: " : ""}${problem?.label_en ?? "-"}`, record.report_date], record.id, "issue"));
  }
  return { ok: true, sent: results };
}

// ------------------------------------------------------------------ noon digest
async function runDigest() {
  // v_today is scoped by auth.uid(); with the service role we read the unscoped pieces instead.
  const { data: glrs, error } = await supabase.from("v_glr").select("*").eq("active", true);
  if (error) throw error;
  const today = new Date(Date.now() + 5.5 * 3600 * 1000).toISOString().slice(0, 10);
  const { data: reps } = await supabase.from("reports").select("glr_id, status, problem, review_status").eq("report_date", today);
  const byGlr = new Map((reps ?? []).map((r) => [r.glr_id, r]));
  const rows = (glrs as Glr[]).map((g) => ({ ...g, ...(byGlr.get(g.glr_id) ?? { status: "not_reported", problem: null, review_status: null }) }));

  const { data: officers } = await supabase.from("officers").select("*").eq("alert_digest", true);
  const results = [];
  for (const o of (officers ?? []) as Officer[]) {
    const mine = rows.filter((r) => inScope(o, r));
    const no = mine.filter((r) => r.status === "no"), partial = mine.filter((r) => r.status === "partial"), silent = mine.filter((r) => r.status === "not_reported");
    const yes = mine.length - no.length - partial.length - silent.length;
    if (no.length === 0 && partial.length === 0 && silent.length === 0) continue;

    const line = (r: typeof rows[number]) => `  ${r.panchayat} / ${r.habitation} / ${r.glr} — ${r.problem ?? ""}${r.review_status && r.review_status !== "pending" ? ` [${r.review_status}]` : ""}`;
    const subject = `Water status 12:00 — ${no.length} not supplied, ${partial.length} partial, ${silent.length} not reported`;
    const text = [
      `Normal: ${yes}   Partial: ${partial.length}   Not supplied: ${no.length}   Not reported: ${silent.length}   (of ${mine.length} GLRs)`,
      "",
      no.length ? "NOT SUPPLIED" : null, ...no.map(line),
      partial.length ? "\nPARTIAL SUPPLY" : null, ...partial.map(line),
      silent.length ? "\nNOT REPORTED BY NOON" : null, ...silent.map((r) => `  ${r.panchayat} / ${r.habitation} / ${r.glr} (${r.code})`),
      APP_URL ? `\nDashboard: ${APP_URL}` : null,
    ].filter((l) => l !== null).join("\n");

    if (o.alert_email) results.push(await sendEmail(o, subject, text, null, "digest"));
  }
  return { ok: true, sent: results.length };
}

// ------------------------------------------------------------------ channels
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

// WhatsApp Cloud API utility template with 4 body parameters: {{1}} GLR (panchayat), {{2}} block, {{3}} problem, {{4}} date
async function sendWhatsApp(o: Officer, params: string[], reportId: number | null, kind: string) {
  const token = Deno.env.get("WA_TOKEN"), phoneId = Deno.env.get("WA_PHONE_ID");
  let status = "skipped", detail = "WA_TOKEN/WA_PHONE_ID not set";
  if (token && phoneId) {
    const res = await fetch(`https://graph.facebook.com/v20.0/${phoneId}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp", to: o.phone!.replace(/^\+/, ""), type: "template",
        template: { name: Deno.env.get("WA_TEMPLATE") ?? "water_supply_issue", language: { code: "en" },
          components: [{ type: "body", parameters: params.map((text) => ({ type: "text", text })) }] },
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
