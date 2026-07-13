// LeaveDesk SG — 公共假期自动同步 Edge Function
// 数据源：data.gov.sg「Singapore Public Holidays」collection（由 MOM 维护，机读、稳定，
// 比抓取 mom.gov.sg 网页可靠）。每次运行拉取「今年 + 明年」的假期，交给数据库函数
// apply_holiday_sync() 做对账（新增/改名/移除）、写审计日志、有变更则发全员站内公告。
//
// 部署： supabase functions deploy sync-holidays --no-verify-jwt
// 定时： 见 SETUP.md —— 用 pg_cron + pg_net 每月（3-5 月每周）调用本函数 URL；
//        或 Dashboard → Edge Functions → Schedules 里挂 cron。
// 手动跑一次： curl -X POST "https://<project>.functions.supabase.co/sync-holidays"
//
// 无需任何用户密钥：SUPABASE_SERVICE_ROLE_KEY 由 Supabase 平台自动注入到函数环境，
// 不是被吊销的那把用户 secret。

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const COLLECTION_ID = "691"; // data.gov.sg「Singapore Public Holidays」collection

const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

// 带超时的 JSON 拉取
async function fetchJson(url: string, ms = 15000): Promise<any> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    const res = await fetch(url, { signal: ctrl.signal, headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText} @ ${url}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

// 从任意 JSON 里挖出形如 d_xxxx 的 datasetId 数组（对 API 结构小改动更稳）
function findDatasetIds(obj: any): string[] {
  const ids = new Set<string>();
  const walk = (v: any) => {
    if (typeof v === "string") { if (/^d_[0-9a-f]+$/i.test(v)) ids.add(v); }
    else if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === "object") Object.values(v).forEach(walk);
  };
  walk(obj);
  return [...ids];
}

// 拉某个 dataset 的记录 → [{holiday, name}]
async function fetchHolidays(datasetId: string): Promise<Array<{ holiday: string; name: string }>> {
  const j = await fetchJson(
    `https://data.gov.sg/api/action/datastore_search?resource_id=${datasetId}&limit=200`,
  );
  const records: any[] = j?.result?.records ?? [];
  return records
    .map((r) => ({ holiday: String(r.date ?? "").trim(), name: String(r.holiday ?? "").trim() }))
    .filter((h) => /^\d{4}-\d{2}-\d{2}$/.test(h.holiday) && h.name.length > 0);
}

Deno.serve(async (_req) => {
  const now = new Date();
  const thisYear = now.getUTCFullYear();
  const targetYears = [thisYear, thisYear + 1];

  try {
    // 1) collection → 所有子数据集 id
    const coll = await fetchJson(
      `https://api-production.data.gov.sg/v2/public/api/collections/${COLLECTION_ID}/metadata`,
    );
    const datasetIds = findDatasetIds(coll);
    if (datasetIds.length === 0) throw new Error("collection 里没找到任何 datasetId");

    // 2) 每个数据集的名称含年份（"Public Holidays for YYYY"）→ 建 year→id
    const yearToId = new Map<number, string>();
    for (const id of datasetIds) {
      try {
        const meta = await fetchJson(
          `https://api-production.data.gov.sg/v2/public/api/datasets/${id}/metadata`,
        );
        const name: string = meta?.data?.name ?? meta?.data?.datasetMetadata?.name ?? "";
        const m = name.match(/\b(20\d{2})\b/);
        if (m) {
          const y = Number(m[1]);
          if (targetYears.includes(y)) yearToId.set(y, id);
        }
      } catch (_) { /* 单个数据集元数据失败不致命，跳过 */ }
    }

    // 3) 只对「真正拿到权威数据」的年份对账（拿不到明年 = 明年还没公布，不动明年）
    const gotYears: number[] = [];
    let holidays: Array<{ holiday: string; name: string }> = [];
    for (const y of targetYears) {
      const id = yearToId.get(y);
      if (!id) continue;
      const hs = await fetchHolidays(id);
      if (hs.length > 0) { holidays = holidays.concat(hs); gotYears.push(y); }
    }

    if (gotYears.length === 0) {
      // 什么都没拉到 —— 记一条 error 日志，返回 500 让监控/cron 察觉，但绝不改数据
      await supabase.from("holiday_sync_log").insert({
        source: "data.gov.sg", years: [], status: "error",
        message: `未能从 data.gov.sg 取到 ${targetYears.join("/")} 的假期数据`,
      });
      return new Response(JSON.stringify({ ok: false, reason: "no data fetched" }), {
        status: 500, headers: { "Content-Type": "application/json" },
      });
    }

    // 4) 交给数据库对账（新增/改名/移除 + 审计日志 + 有变更发公告）
    const { data, error } = await supabase.rpc("apply_holiday_sync", {
      p_holidays: holidays, p_years: gotYears, p_source: "data.gov.sg",
    });
    if (error) throw error;

    return new Response(JSON.stringify({ ok: true, years: gotYears, seen: holidays.length, result: data }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // best-effort 错误日志（拉取/对账失败时数据保持原样）
    await supabase.from("holiday_sync_log").insert({
      source: "data.gov.sg", years: [], status: "error", message: msg,
    }).then(() => {}, () => {});
    return new Response(JSON.stringify({ ok: false, error: msg }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
