// Chaabi.com proof email: a dated record of every request, reply and deal step,
// sent to BOTH people separately (nobody sees the other's address) from your Gmail.
// Secrets (Supabase > Edge Functions > Secrets): GMAIL_USER, GMAIL_APP_PASSWORD
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import nodemailer from "npm:nodemailer@6.9.16";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const num = (n: number) => Math.round(n).toLocaleString("en-PK");
const when = (d: string | Date) =>
  new Date(d).toLocaleString("en-PK", { timeZone: "Asia/Karachi", dateStyle: "medium", timeStyle: "short" }) + " PKT";

const KIND: Record<string, string> = {
  message: "Message", visit: "Visit request", offer: "Offer", token: "Token payment record", deal: "Final deal record",
};
const INQ_EVENTS: Record<string, string> = {
  created: "New request", accepted: "Accepted", declined: "Declined", completed: "Completed", cancelled: "Cancelled",
};
const DEAL_EVENTS: Record<string, string> = {
  deal_created: "Deal created", buyer_joined: "Buyer joined the deal", bayana_recorded: "Bayana recorded",
  bayana_confirmed: "Bayana receipt confirmed", seller_signed: "Seller signed the iqrarnama",
  buyer_signed: "Buyer signed the iqrarnama", deal_completed: "Deal completed", deal_cancelled: "Deal cancelled",
};
// What the deal must look like for each event to be real
const DEAL_OK: Record<string, (d: any) => boolean> = {
  deal_created: () => true,
  buyer_joined: (d) => !!d.buyer_id,
  bayana_recorded: (d) => !!d.bayana_amount,
  bayana_confirmed: (d) => !!d.bayana_confirmed_at,
  seller_signed: (d) => !!d.seller_sign,
  buyer_signed: (d) => !!d.buyer_sign,
  deal_completed: (d) => d.stage === "completed",
  deal_cancelled: (d) => d.stage === "cancelled",
};

function page(title: string, rows: [string, string][], footer: string) {
  return `<!doctype html><html><body style="margin:0;background:#F8F3EA;font-family:Arial,sans-serif;color:#12302E">
<div style="max-width:560px;margin:0 auto;padding:24px">
<div style="background:#0F5A55;color:#fff;border-radius:14px 14px 0 0;padding:18px 22px;font-size:20px;font-weight:bold">chaabi<span style="color:#E0B25A">.com</span></div>
<div style="background:#fff;border:1px solid #D9CDB4;border-top:0;border-radius:0 0 14px 14px;padding:22px">
<p style="margin:0 0 6px;font-size:13px;color:#55665F">Proof record</p>
<h1 style="margin:0 0 16px;font-size:20px">${esc(title)}</h1>
<table style="width:100%;border-collapse:collapse;font-size:14px">${rows.map(([k, v]) =>
    `<tr><td style="padding:8px 0;border-bottom:1px solid #EFE6D3;color:#55665F;width:40%">${esc(k)}</td><td style="padding:8px 0;border-bottom:1px solid #EFE6D3;font-weight:bold">${esc(v)}</td></tr>`).join("")}</table>
<p style="font-size:13px;color:#55665F;margin:18px 0 0">${esc(footer)}</p>
</div></div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const gmailUser = Deno.env.get("GMAIL_USER");
  const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!gmailUser || !gmailPass) return json({ error: "Email is not configured" }, 500);

  const userClient = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Not signed in" }, 401);

  let body: { inquiry_id?: string; deal_id?: string; event?: string };
  try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  const { inquiry_id, deal_id, event } = body;
  if (!event || (!inquiry_id && !deal_id)) return json({ error: "Bad request" }, 400);

  const admin = createClient(url, service);
  let partyIds: string[] = [];
  let title = "";
  let rows: [string, string][] = [];
  let subject = "";
  let logKey: Record<string, string> = {};

  if (inquiry_id) {
    if (!(event in INQ_EVENTS)) return json({ error: "Bad request" }, 400);
    const { data: inq } = await admin.from("inquiries")
      .select("*, listing:listings(title, area, city, country, price, mode, currency)").eq("id", inquiry_id).maybeSingle();
    if (!inq) return json({ error: "Not found" }, 404);
    if (user.id !== inq.sender_id && user.id !== inq.owner_id) return json({ error: "Forbidden" }, 403);
    if (event !== "created" && inq.status !== event) return json({ error: "Status does not match" }, 409);
    const { data: profs } = await admin.from("profiles").select("id, full_name, phone").in("id", [inq.sender_id, inq.owner_id]);
    const P = (id: string) => profs?.find((p) => p.id === id) ?? { full_name: "", phone: null };
    const showPhones = ["accepted", "completed"].includes(inq.status);
    const l = inq.listing ?? {};
    rows = [["Reference", inq.ref_code], ["Event", INQ_EVENTS[event]], ["Request", KIND[inq.kind] ?? inq.kind],
      ["Listing", `${l.title ?? ""} (${l.area ?? ""}, ${l.city ?? ""})`]];
    if (inq.amount) rows.push(["Amount", `${l.currency ?? "PKR"} ${num(inq.amount)}`]);
    if (inq.visit_at) rows.push(["Visit time", when(inq.visit_at)]);
    if (inq.message) rows.push(["Message", inq.message]);
    const s = P(inq.sender_id), o = P(inq.owner_id);
    rows.push(["From", s.full_name + (showPhones && s.phone ? ` · ${s.phone}` : "")]);
    rows.push(["To (listing owner)", o.full_name + (showPhones && o.phone ? ` · ${o.phone}` : "")]);
    title = `${INQ_EVENTS[event]}: ${KIND[inq.kind]}`;
    subject = `Chaabi.com proof · ${INQ_EVENTS[event]} · ${KIND[inq.kind]} · ${inq.ref_code}`;
    partyIds = [inq.sender_id, inq.owner_id];
    logKey = { inquiry_id };
  } else {
    if (!(event in DEAL_EVENTS)) return json({ error: "Bad request" }, 400);
    const { data: d } = await admin.from("deals")
      .select("*, listing:listings(title, area, city, country, address, mode)").eq("id", deal_id).maybeSingle();
    if (!d) return json({ error: "Not found" }, 404);
    if (user.id !== d.seller_id && user.id !== d.buyer_id) return json({ error: "Forbidden" }, 403);
    if (!DEAL_OK[event](d)) return json({ error: "Status does not match" }, 409);
    const l = d.listing ?? {};
    const cur = d.currency ?? "PKR";
    rows = [["Deal code", d.code], ["Event", DEAL_EVENTS[event]],
      ["Property", `${l.title ?? ""} (${l.address ?? [l.area, l.city, l.country].filter(Boolean).join(", ")})`],
      [l.mode === "rent" ? "Monthly rent" : "Agreed price", `${cur} ${num(d.price)}`]];
    if (d.bayana_amount) rows.push(["Bayana", `${cur} ${num(d.bayana_amount)}${d.bayana_confirmed_at ? " (receipt confirmed)" : ""}`]);
    if (d.balance_due_date) rows.push(["Balance due by", d.balance_due_date]);
    if (event === "deal_completed") {
      rows.push(["Chaabi.com commission", `${cur} ${num(Math.round(d.price * 0.02))} from each side`]);
      rows.push(["Verified Deal", d.verified ? "Yes" : "Pending document and society checks"]);
    }
    title = DEAL_EVENTS[event];
    subject = `Chaabi.com proof · ${DEAL_EVENTS[event]} · ${d.code}`;
    partyIds = [d.seller_id, d.buyer_id].filter(Boolean);
    logKey = { deal_id: deal_id! };
  }
  rows.push(["Recorded at", when(new Date())]);

  const { error: dup } = await admin.from("proof_emails").insert({ ...logKey, event, status: "sending" });
  if (dup) return json({ ok: true, duplicate: true });
  const del = () => admin.from("proof_emails").delete().match({ ...logKey, event });

  try {
    const users = await Promise.all(partyIds.map((id) => admin.auth.admin.getUserById(id)));
    const to = users.map((u) => u.data.user?.email).filter(Boolean) as string[];
    const footer = "Keep this email as your record. Both sides received the same details. Chaabi.com records steps between users; have a lawyer review legal documents.";
    const html = page(title, rows, footer);
    const text = rows.map(([k, v]) => `${k}: ${v}`).join("\n") + "\n\n" + footer;
    // Gmail over SSL port 465 (Supabase blocks outbound ports 25 and 587).
    const mailer = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: gmailUser, pass: gmailPass } });
    for (const addr of to) await mailer.sendMail({ from: `"Chaabi.com" <${gmailUser}>`, to: addr, subject, html, text });
    await admin.from("proof_emails").update({ status: "sent", sent_at: new Date().toISOString() }).match({ ...logKey, event });
    return json({ ok: true, sent: to.length });
  } catch (e) {
    await del();
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
