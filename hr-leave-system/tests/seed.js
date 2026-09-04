// Seed the page with a plausible in-memory db, bypassing Supabase.
window.__seed = function (opts) {
  opts = opts || {};
  const dom = opts.emailDomain === undefined ? "shanghai-uniforms.com" : opts.emailDomain;
  const emps = [
    { id: "e1", name: "Alice Tan", title: "HR", dept: "Admin", gender: "F", role: "admin",
      email: "alice@shanghai-uniforms.com", joinDate: "2020-01-06", approver1: null, approver2: null,
      empNo: "001", alias: "", mobile: "", hasLogin: true, twoLevel: false, annualBase: 14,
      active: true, lastDay: null, worksSat: false, carryCap: 5 },
    { id: "e2", name: "Barbie Girl", title: "Sales", dept: "Sales", gender: "F", role: "employee",
      email: "barbie@shanghai-uniforms.com", joinDate: "2022-03-01", approver1: "e1", approver2: null,
      empNo: "002", alias: "", mobile: "", hasLogin: true, twoLevel: false, annualBase: 14,
      active: true, lastDay: null, worksSat: false, carryCap: 10 }
  ];
  const types = [
    { code: "annual", en: "Annual Leave", zh: "年假", mc: false, gender: "", noDeduct: false,
      days: 14, allowHalf: true, sort: 1, note: "" },
    { code: "oil", en: "Off-in-Lieu", zh: "补休", mc: false, gender: "", noDeduct: false,
      days: 0, allowHalf: true, sort: 2, note: "" },
    { code: "sick", en: "Sick Leave", zh: "病假", mc: true, gender: "", noDeduct: false,
      days: 14, allowHalf: false, sort: 3, note: "" },
    { code: "hosp", en: "Hospitalisation Leave", zh: "住院假", mc: true, gender: "", noDeduct: false,
      days: 60, allowHalf: false, sort: 4, note: "" },
    { code: "maternity", en: "Maternity Leave", zh: "产假", mc: false, gender: "F", noDeduct: false,
      days: 112, allowHalf: false, sort: 5, note: "" }
  ];
  const ph = ["2026-01-01", "2026-12-25"].concat(opts.with2027 ? ["2027-01-01", "2027-02-06", "2027-12-25"] : []);
  db = {
    org: { company: "Shanghai School Uniforms", emailDomain: dom, country: "SG",
           defaultAnnualBase: 14, prorateCap: null, annualCap: 21, accrualMode: "annual",
           defaultCarryCap: 5, carryExpiryMonths: opts.carryMonths === undefined ? 12 : opts.carryMonths,
           // v24: the expiry is a day + month that repeats every year. Defaults to
           // 31 December, which is what carryExpiryMonths: 12 always meant.
           // v36: off-in-lieu gets the same pair. Default null/null = never expires,
           // which is what every existing company keeps until HR picks a month.
           oilExpiryMonth: opts.oilMD === undefined ? null : (opts.oilMD && opts.oilMD[0]),
           oilExpiryDay:   opts.oilMD === undefined ? null : (opts.oilMD && opts.oilMD[1]),
           carryExpiryMonth: opts.carryMD === undefined ? 12 : (opts.carryMD && opts.carryMD[0]),
           carryExpiryDay:   opts.carryMD === undefined ? 31 : (opts.carryMD && opts.carryMD[1]),
           // v28: who notification email is limited to while testing. "" = everyone.
           notifyOnlyEmp: opts.notifyOnly === undefined ? "" : opts.notifyOnly },
    departments: ["Admin", "Sales"], deptSat: { Admin: false, Sales: false },
    employees: emps, leaveTypes: types,
    publicHolidays: ph.slice().sort(),
    phNames: Object.fromEntries(ph.map(d => [d, "Holiday"])),
    ledger: [],
    applications: [
      { id: "a1", empId: "e2", type: "annual", start: "2026-08-13", end: "2026-09-04",
        sh: "full", eh: "full", halfDays: [], days: 17, reason: "Home leave", att: "",
        status: "approved", cur: 0, backdated: false, createdAt: Date.parse("2026-07-01"),
        steps: [{ order: 1, approverId: "e1", status: "approved", comment: "", ts: Date.parse("2026-07-02") }] },
      { id: "a2", empId: "e2", type: "annual", start: "2027-01-11", end: "2027-01-12",
        sh: "full", eh: "full", halfDays: [], days: 2, reason: "Trip", att: "",
        status: "approved", cur: 0, backdated: false, createdAt: Date.parse("2026-07-01"),
        steps: [{ order: 1, approverId: "e1", status: "approved", comment: "", ts: Date.parse("2026-07-02") }] }
    ],
    events: [
      { appId: 'a1', actor: 'e2', action: 'Auto-approved', comment: 'No approver required', ts: Date.parse('2026-07-02') },
      { appId: 'a1', actor: 'e2', action: 'Cancelled automatically', comment: 'No approver required', ts: Date.parse('2026-08-01') }
    ], calendar: [], outbox: [], balCache: {},
    empExtra: true, ltHalf: true, hasSat: true, hasPhWhen: true, orgProrate: true, orgV14: true,
    orgV16: opts.noV16 ? false : true,
    orgV18: (opts.noV16 || opts.noV18) ? false : true,
    orgV24: (opts.noV16 || opts.noV24) ? false : true,
    orgV36: opts.noV36 ? false : true,
    orgV28: (opts.noV16 || opts.noV28) ? false : true,
    amendments: opts.amendments || [],
    allCarry: opts.allCarry || [],
    annualCarry: opts.carry === undefined
      ? { year: 2026, carry_in: 5, remaining: 2, expires_on: opts.carryMonths === null ? null : "2026-06-30" }
      : opts.carry,
    announcements: [], carry: null
  };
  me = opts.asHr ? emps[0] : emps[1];
  // v24: emps[0] is already an Owner, so `asHr` gives an Owner by default. A test that
  // needs a plain HR Admin -- who may not grant Owner -- has to say so.
  if (opts.asPlainHr) { me.role = "hr"; }
  booting = false; view = opts.view || "myapps"; vp = {};
  if (opts.hrTab) { view = "hr"; hrTab = opts.hrTab; }
  render();
};
