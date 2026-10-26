// Chaabi AI Expert: answers about land, plots, construction, house condition and price,
// with photos. Calls the Anthropic API from the server so the key never reaches the app.
// Secrets: ANTHROPIC_API_KEY (required), AI_MODEL (optional), AI_DAILY_LIMIT (optional, default 20)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const SYSTEM = `You are "Chaabi AI Expert" inside the Chaabi.com property app (Pakistan first, also worldwide).
You are an expert in: land and plot measurement (marla, kanal, sq ft, sq yd; marla standards differ: 225, 250 or 272.25 sq ft),
Pakistani property documents (fard, intiqal, registry, allotment letter, NOC, approved map), housing society approval checks
(CDA, RDA, LDA and other authorities), construction (grey structure, finishing, materials, cost per sq ft), house condition
(cracks, seepage, damp, roof, wiring, plumbing, drainage) and rent or price estimation from comparable properties.
Rules:
1. Reply in the user's language and script. Roman Urdu gets Roman Urdu, Urdu script gets Urdu script, otherwise English.
2. For photos: first list only what is actually visible, then what cannot be confirmed from a photo. Never invent hidden defects and never claim certainty you do not have.
3. For prices and costs: give a range with the assumptions (area, location, quality, date) and say what local data would narrow it. Never present an estimate as a confirmed value.
4. Never state the legal status of a specific society or document as fact; name the official list or office that confirms it.
5. Short headings and bullet points. Practical. End with the next step, such as a Chaabi.com Ghar Health Check, Document Check or a site measurement when confirmation is needed.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "off" }, 503);

  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Not signed in" }, 401);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const limit = Number(Deno.env.get("AI_DAILY_LIMIT") ?? "20");
  const today = new Date().toISOString().slice(0, 10);
  const { data: use } = await admin.from("ai_usage").select("count").eq("user_id", user.id).eq("day", today).maybeSingle();
  if ((use?.count ?? 0) >= limit) return json({ error: "limit" }, 429);

  let body: { messages?: { role: string; content: string }[]; images?: { media_type: string; data: string }[] };
  try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  const history = (body.messages ?? []).filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
    .slice(-12).map((m) => ({ role: m.role, content: m.content.slice(0, 4000) }));
  if (!history.length || history[history.length - 1].role !== "user") return json({ error: "Bad request" }, 400);
  const images = (body.images ?? []).slice(0, 4).filter((i) => /^image\/(jpeg|png|webp|gif)$/.test(i.media_type) && i.data.length < 2_800_000);
  const last = history.pop()!;
  const messages = [...history, {
    role: "user",
    content: [...images.map((i) => ({ type: "image", source: { type: "base64", media_type: i.media_type, data: i.data } })),
      { type: "text", text: last.content }],
  }];

  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: Deno.env.get("AI_MODEL") ?? "claude-sonnet-5-5", max_tokens: 1500, system: SYSTEM, messages }),
  });
  if (!r.ok) return json({ error: "upstream", status: r.status }, 502);
  const out = await r.json();
  const text = (out.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("\n").trim();

  if (use) await admin.from("ai_usage").update({ count: use.count + 1 }).eq("user_id", user.id).eq("day", today);
  else await admin.from("ai_usage").insert({ user_id: user.id, day: today, count: 1 });
  return json({ text });
});
