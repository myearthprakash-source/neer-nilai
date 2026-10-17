// Neer Nilai — staff-login edge function.
// Panchayat, block and district officers sign in with mobile number + last 4 digits (or a personal PIN, later).
// POST { phone, pin, device }  →  { token_hash }  (the page turns it into a normal Supabase session with verifyOtp)
//                              →  { err: "bad" | "locked" | "device" }
// No email or SMS is ever sent: each staff member gets an auth user with an internal address, and the session is
// opened with an admin-generated one-time token. Deploy with verify_jwt off (the caller is not signed in yet).

import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return out({ err: "bad" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const phone = String(body.phone ?? "").replace(/\D/g, "").slice(-10);
    const { data: rows, error } = await admin.rpc("staff_auth", { p_phone: phone, p_pin: String(body.pin ?? ""), p_device: String(body.device ?? "") });
    if (error) { console.error(error); return out({ err: "server" }, 500); }
    const s = rows?.[0];
    if (!s || s.err) return out({ err: s?.err ?? "bad" });

    // Internal address only: nothing is ever mailed to it.
    const email = `${s.phone}@staff.neer-nilai.app`;
    if (!s.user_id) await admin.auth.admin.createUser({ email, email_confirm: true, user_metadata: { phone: s.phone, name: s.name } });   // "already registered" is fine
    const { data: link, error: e2 } = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (e2 || !link?.user) { console.error(e2); return out({ err: "server" }, 500); }
    const uid = link.user.id;

    // Keep the officers row (what row-level security reads) in step with the staff list.
    const { error: e3 } = await admin.from("officers").upsert({ id: uid, name: s.name, role: s.role, district_id: s.district_id, block_id: s.block_id, panchayat_id: s.panchayat_id, email, phone: s.phone });
    if (e3) { console.error(e3); return out({ err: "server" }, 500); }
    if (s.user_id !== uid) await admin.from("staff").update({ user_id: uid }).eq("phone", s.phone);

    return out({ token_hash: link.properties.hashed_token });
  } catch (e) {
    console.error(e);
    return out({ err: "server" }, 500);
  }
});
