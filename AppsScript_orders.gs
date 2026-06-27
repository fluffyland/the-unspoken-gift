/**
 * The Unspoken Gift — order logger (Google Apps Script Web App)
 * Columns: Order No / Status / Time / Items / Qty /
 *          Name / Phone / Recipient Name / Recipient Phone / Email /
 *          Address / Postal / Delivery Date / Delivery Time /
 *          Subtotal / Card Message / Notes
 */

const TOKEN = 'ug-7f3a9c2e';   // must match ORDER_TOKEN on the website

const STATUS_OPTIONS = [
  'Pending Confirmation 待确认',
  'Payment Confirmed 已付款',
  'Preparing 备货中',
  'Shipped 已发货',
  'Completed 已完成',
  'Cancelled 已取消',
  'Refunded 已退款'
];

// Bilingual two-line headers (中文 on top, English below)
const HEADERS = [
  '订单号\nOrder No',
  '状态\nStatus',
  '时间\nTime',
  '商品明细\nOrdered Items',
  '数量\nQty',
  '姓名\nName',
  '电话\nPhone',
  '收礼人姓名\nRecipient Name',
  '收礼人电话\nRecipient Phone',
  '邮件\nEmail',
  '地址\nAddress',
  '邮编\nPostal',
  '送达日期\nDelivery Date',
  '送达时段\nDelivery Time',
  '小计\nSubtotal',
  '贺卡留言\nCard Message',
  '备注\nNotes'
];

// columns that must stay TEXT (phone/postal) so + and leading 0 survive, no green triangle
const TEXT_COLS = { 7: 'phone', 9: 'recipientPhone', 12: 'postal' };
const WRAP_COLS = [4, 16];   // Items + Card Message (they hold multi-line content)

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    if (data.token !== TOKEN) return out({ ok: false, error: 'bad token' });

    const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0];
    ensureHeaders(sheet);

    const phone = data.phone || data.contact || '';
    const orderNo = uniqueOrderNo(sheet, String(data.orderNo || ''));

    const row = [
      esc(orderNo),
      data.status || STATUS_OPTIONS[0],
      esc(data.ts || ''),
      esc(data.items || ''),
      num(data.qty),
      esc(data.name || ''),
      esc(phone),
      esc(data.recipientName || ''),
      esc(data.recipientPhone || ''),
      esc(data.email || ''),
      esc(data.address || ''),
      esc(data.postal || ''),
      esc(data.date || ''),
      esc(data.time || ''),
      num(data.subtotal),
      esc(data.giftcard || ''),
      esc(data.notes || '')
    ];

    sheet.appendRow(row);
    const r = sheet.getLastRow();
    formatRow(sheet, r, data, phone);

    return out({ ok: true, orderNo: orderNo, row: r });
  } catch (err) {
    return out({ ok: false, error: String(err) });
  }
}

function formatRow(sheet, r, data, phone) {
  sheet.getRange(r, 1, 1, HEADERS.length)
       .setHorizontalAlignment('left')
       .setVerticalAlignment('top');

  WRAP_COLS.forEach(function (c) { sheet.getRange(r, c).setWrap(true); });

  // phone-like cells → force text format then write the raw value (kills #ERROR + green triangle)
  setText(sheet, r, 7, phone);
  setText(sheet, r, 9, data.recipientPhone || '');
  setText(sheet, r, 12, data.postal || '');

  // status dropdown
  const rule = SpreadsheetApp.newDataValidation()
    .requireValueInList(STATUS_OPTIONS, true)
    .setAllowInvalid(true)
    .build();
  sheet.getRange(r, 2).setDataValidation(rule);
}

function setText(sheet, r, col, val) {
  sheet.getRange(r, col).setNumberFormat('@').setValue(String(val == null ? '' : val));
}

function ensureHeaders(sheet) {
  if (sheet.getRange(1, 1).getValue() !== '') return;   // already has a header row
  sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS])
       .setFontWeight('bold')
       .setHorizontalAlignment('left')
       .setVerticalAlignment('middle')
       .setWrap(true);
  sheet.setFrozenRows(1);
}

function uniqueOrderNo(sheet, orderNo) {
  if (!orderNo) return orderNo;
  const last = sheet.getLastRow();
  if (last < 2) return orderNo;
  const col = sheet.getRange(2, 1, last - 1, 1).getValues().map(function (x) { return String(x[0]); });
  if (col.indexOf(orderNo) < 0) return orderNo;
  let i = 2;
  while (col.indexOf(orderNo + '-' + i) >= 0) i++;
  return orderNo + '-' + i;
}

// keep numbers numeric; apostrophe-escape anything Sheets would treat as a formula
function esc(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number') return v;
  const s = String(v);
  return /^[=+\-@]/.test(s) ? "'" + s : s;
}

function num(v) {
  return (v === 0 || (v && !isNaN(v))) ? Number(v) : '';
}

function out(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
