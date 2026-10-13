// LeaveDesk — the words that go in the notification emails.
//
// Deliberately a plain ESM module with no Deno or Supabase imports: the Edge Function
// imports it to send, and the test suite imports the SAME file to check every sentence.
// If the wording could only be checked by sending real email, it would never be checked.

const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function fmtDay(iso) {
  const [y, m, d] = String(iso).split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return `${DOW[dt.getUTCDay()]} ${d} ${MON[m - 1]} ${y}`;
}
// One day reads as one day. "Mon 15 Dec 2026 to Mon 15 Dec 2026" is how software talks.
export function fmtRange(start, end) {
  return start === end ? fmtDay(start) : `${fmtDay(start)} to ${fmtDay(end)}`;
}
export function fmtDays(n) {
  const v = Number(n) || 0;
  return Number.isInteger(v) ? String(v) : String(v);          // 0.5 stays 0.5
}
const firstName = (n) => String(n || "").trim().split(/\s+/)[0] || "there";

// The details block every email shares. Aligned so it reads on a phone.
function block(rows) {
  const w = Math.max(...rows.map(([k]) => k.length));
  // A spacer row is a blank line, not a line of padding -- trailing spaces render as
  // stray whitespace in some mail clients and look like a bug.
  return rows.map(([k, v]) => (k === "" && v === "") ? "" : `  ${k.padEnd(w + 4)}${v}`).join("\n");
}

function body(greetName, lead, rows, tail, ctx) {
  return `Hi ${firstName(greetName)},\n\n${lead}\n\n${block(rows)}\n\n${tail}\n\n— LeaveDesk, ${ctx.company}`;
}

/* Every email this system can send, built from one application record.
   Returns [{ to, subject, text }]. An event nobody needs to hear about returns []. */
export function buildMails(ctx) {
  const { event, app, employee, actor, leaveType, nextApprover, firstApprover,
          balanceAfter, appUrl, company } = ctx;
  const c = { company: company || "LeaveDesk" };
  const range = fmtRange(app.start_date, app.end_date);
  const days = fmtDays(app.days);
  const dayWord = Number(app.days) === 1 ? "day" : "days";
  const link = appUrl ? `\n${appUrl}` : "";
  const base = [["Leave type", leaveType], ["Dates", range], ["Working days", days]];
  const withReason = app.reason ? base.concat([["Reason", app.reason]]) : base;
  const out = [];
  const bal = () => balanceAfter == null ? [] : [["", ""], [`${leaveType} left`, `${fmtDays(balanceAfter)} days`]];

  switch (event) {
    case "submitted":
    case "resubmitted":
      if (nextApprover) out.push({
        to: nextApprover.email,
        subject: `${employee.name} has applied for leave — your approval is needed`,
        text: body(nextApprover.name,
          `${employee.name} has applied for leave and it is waiting for you.`,
          withReason, `Approve or reject it here:${link}`, c) });
      out.push({
        to: employee.email,
        subject: `We have received your leave request`,
        text: body(employee.name,
          nextApprover ? `We have received your leave request. It is now with ${nextApprover.name} for approval.`
                       : `We have received your leave request.`,
          withReason,
          `We will email you as soon as there is a decision.${link}`, c) });
      break;

    case "step_approved":
      if (nextApprover) out.push({
        to: nextApprover.email,
        subject: `${employee.name} has applied for leave — your final approval is needed`,
        text: body(nextApprover.name,
          `${actor.name} has already approved this. It needs your final approval.`,
          withReason, `Approve or reject it here:${link}`, c) });
      out.push({
        to: employee.email,
        subject: `${actor.name} has approved your leave — one more to go`,
        text: body(employee.name,
          `${actor.name} has approved your leave. It now needs${nextApprover ? ` ${nextApprover.name}'s` : " one more"} final approval.`,
          base, `We will email you when it is decided.${link}`, c) });
      break;

    case "approved":
      out.push({
        to: employee.email,
        subject: `Your leave has been approved`,
        text: body(employee.name,
          `Good news — ${actor.name} has approved your leave.`,
          base.concat(bal()), `Enjoy your time off.`, c) });
      break;

    case "auto_approved":
      out.push({
        to: employee.email,
        subject: `Your leave has been recorded and approved`,
        text: body(employee.name,
          `Your leave has been recorded and approved. Nobody else needed to approve it.`,
          base.concat(bal()), `Enjoy your time off.`, c) });
      break;

    case "rejected":
      out.push({
        to: employee.email,
        subject: `Your leave request was not approved`,
        text: body(employee.name,
          `${actor.name} has not approved your leave request.`,
          withReason.concat(app.comment ? [["", ""], ["They said", app.comment]] : []),
          `Your days have not been deducted. Speak to ${actor.name} if you would like to discuss it.${link}`, c) });
      break;

    case "returned":
      out.push({
        to: employee.email,
        subject: `Your leave request needs a bit more information`,
        text: body(employee.name,
          `${actor.name} has sent your leave request back to you.`,
          base.concat(app.comment ? [["", ""], ["They asked for", app.comment]] : []),
          `Open LeaveDesk, make the change and send it again.${link}`, c) });
      break;

    case "withdrawn":
      if (nextApprover) out.push({
        to: nextApprover.email,
        subject: `${employee.name} has withdrawn their leave request`,
        text: body(nextApprover.name,
          `${employee.name} has withdrawn the leave request that was waiting for you. There is nothing for you to do.`,
          base, `No days have been deducted.`, c) });
      break;

    case "cancel_requested":
      if (firstApprover) out.push({
        to: firstApprover.email,
        subject: `${employee.name} wants to cancel approved leave`,
        text: body(firstApprover.name,
          `${employee.name} is asking to cancel leave that was already approved.`,
          base, `Confirm it in LeaveDesk and the days go back to them.${link}`, c) });
      break;

    case "cancelled":
      out.push({
        to: employee.email,
        subject: `Your leave has been cancelled and the days returned`,
        text: body(employee.name,
          `Your leave has been cancelled, and the days are back in your balance.`,
          [["Leave type", leaveType], ["Dates", range], ["Days returned", days]].concat(bal()),
          `Nothing else to do.`, c) });
      break;

    case "cancel_denied":
      out.push({
        to: employee.email,
        subject: `Your leave has not been cancelled`,
        text: body(employee.name,
          `${actor.name} has not agreed to cancel this leave, so it still stands.`,
          base.concat(app.comment ? [["", ""], ["They said", app.comment]] : []),
          `The ${days} ${dayWord} remain deducted.${link}`, c) });
      break;

    case "hr_on_behalf":
      out.push({
        to: employee.email,
        subject: `HR has recorded leave for you`,
        text: body(employee.name,
          `${actor.name} has recorded this leave for you and approved it.`,
          base.concat(bal()),
          `If anything looks wrong, tell HR.${link}`, c) });
      break;
  }
  return out;
}

/* Test mode. While an employee is named, only mail addressed to THEM goes out — nobody
   else in the company can receive anything by accident. Blank = everyone, which is how it
   is left once you are happy. */
export function applyTestMode(mails, onlyEmail) {
  if (!onlyEmail) return mails;
  const t = String(onlyEmail).trim().toLowerCase();
  return mails.filter(m => String(m.to || "").trim().toLowerCase() === t);
}
