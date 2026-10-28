/**
 * The Google Sheet end of the Debug categorization log (board card #5).
 *
 * The app POSTs one JSON object per line to this script's /exec URL; this
 * appends one row per object. Temporary, for the testing phase: the point is
 * to accumulate real "what arrived → how it was categorized" pairs so a base
 * categorizer can later be trained on them instead of on a guessed keyword
 * list.
 *
 * ── Setup, once ──────────────────────────────────────────────────────────
 *
 * 1. Open the spreadsheet → Extensions → Apps Script.
 * 2. Replace the contents of Code.gs with this file. Save.
 * 3. Deploy → New deployment → type "Web app".
 *      Execute as:      Me
 *      Who has access:  Anyone
 *    "Anyone" is required: the app sends an unauthenticated POST, with no
 *    Google account involved anywhere. It also means ANYONE HOLDING THE URL
 *    CAN APPEND ROWS — treat the /exec URL as a password, and redeploy (which
 *    issues a new URL) to rotate it.
 * 4. Copy the /exec URL. In the app: Налаштування → Дані → «Збір даних
 *    категоризації» → turn it on → paste the URL.
 * 5. Categorize something. A row should appear within a second or two.
 *
 * ── Notes ────────────────────────────────────────────────────────────────
 *
 * Container-bound on purpose. `SpreadsheetApp.getActive()` means the
 * spreadsheet's id appears nowhere in this repository — a document id
 * committed to git is a thing that outlives every later decision to keep it
 * private, which this repo has already learned once the hard way.
 *
 * A failure here must be a REAL failure: the script throws rather than
 * answering 200 with an error body, because the app counts any 2xx as
 * delivered and would otherwise report a healthy webhook that stores nothing.
 * The phone keeps its own JSONL regardless, so a dead webhook costs sheet
 * rows, never the data.
 */

/** The tab spending decisions go to — the one the owner set aside for this.
 *  Created on first POST if missing. */
const SHEET_NAME = 'Swift';

/** Product groups from scanned receipts. A SEPARATE tab, not a column on the
 *  one above: a receipt item's group is what was BOUGHT, a transaction's
 *  category is where the money WENT, and the app keeps those two namespaces
 *  apart everywhere. One shared sheet would be an invitation to join them and
 *  quietly poison both training sets. */
const PRODUCTS_SHEET_NAME = 'Swift — товари';

/**
 * Column order, and the header written into an empty sheet. The first twelve
 * are the event exactly as the app encodes it; `receivedAt` is this script's
 * own clock, which is what makes a delivery gap visible — a run of events
 * whose `at` marches on while `receivedAt` does not means the phone was
 * writing its file and failing to reach here.
 */
const COLUMNS = [
  'at',
  'source',
  'choice',
  'category',
  'merchant',
  'merchantKey',
  'mcc',
  'originalMcc',
  'sign',
  'bankId',
  'bankSuggestion',
  'was',
  'kind',
  'receivedAt',
];

/** Product-group columns, in the order they are written. */
const PRODUCT_COLUMNS = [
  'at',
  'source',
  'name',
  'guessed',
  'chosen',
  'agreed',
  'seller',
  'receivedAt',
];

/** Which tab a line belongs in.
 *
 *  Routed on an explicit `type`, not on which keys happen to be present: a
 *  schema that grows a field must not start landing rows in the wrong sheet,
 *  and a spending row that ended up among the product groups would be found
 *  months later by whoever trains on it.
 */
function planFor(event) {
  if (event && event.type === 'productGroup') {
    return { name: PRODUCTS_SHEET_NAME, columns: PRODUCT_COLUMNS };
  }
  return { name: SHEET_NAME, columns: COLUMNS };
}

function doPost(e) {
  if (!e || !e.postData || !e.postData.contents) {
    throw new Error('empty POST body');
  }

  const payload = JSON.parse(e.postData.contents);
  // One object per request today. An array is accepted too, so batching later
  // does not need a change on this side.
  const events = Array.isArray(payload) ? payload : [payload];
  if (events.length === 0) {
    return json({ ok: true, appended: 0 });
  }

  // The app fires one request per line and does not wait for the previous
  // one, so a cascade of twelve arrives concurrently. Without the lock, two
  // appends can read the same last row and one of them is lost.
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const receivedAt = new Date().toISOString();
    // Grouped by destination, so a batch carrying both kinds still costs one
    // write per tab rather than one per row.
    const byTab = {};
    events.forEach(function (event) {
      const plan = planFor(event);
      const bucket = byTab[plan.name] || (byTab[plan.name] = { plan: plan, rows: [] });
      bucket.rows.push(
        plan.columns.map(function (column) {
          if (column === 'receivedAt') return receivedAt;
          const value = event[column];
          // null and undefined both become an empty cell rather than the text
          // "null" — `mcc`, `category` and `bankSuggestion` are legitimately
          // absent, and a literal "null" would have to be cleaned out of every
          // later query.
          return value === null || value === undefined ? '' : value;
        })
      );
    });

    let appended = 0;
    Object.keys(byTab).forEach(function (name) {
      const bucket = byTab[name];
      const sheet = sheetForAppending(name, bucket.plan.columns);
      sheet
        .getRange(sheet.getLastRow() + 1, 1, bucket.rows.length, bucket.plan.columns.length)
        .setValues(bucket.rows);
      appended += bucket.rows.length;
    });
    return json({ ok: true, appended: appended });
  } finally {
    lock.releaseLock();
  }
}

/** A GET is not part of the contract; it exists so opening the URL in a
 *  browser says something useful instead of erroring. */
function doGet() {
  return json({ ok: true, message: 'POST one categorization event as JSON' });
}

function sheetForAppending(name, columns) {
  const spreadsheet = SpreadsheetApp.getActive();
  let sheet = spreadsheet.getSheetByName(name);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(name);
  }
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(columns);
    sheet.setFrozenRows(1);
    return sheet;
  }
  // Rows are written BY POSITION, so a sheet whose header predates a schema
  // change is the quiet disaster: board #56 inserted `originalMcc` in the
  // middle, and against an older header every value from `sign` rightwards
  // would land one column off — under a heading naming a different field,
  // with nothing failing. Refusing is the whole point; a 500 the owner sees
  // beats a training set that is wrong in a way no query can detect.
  //
  // The fix when this fires: add the new heading to the sheet in the same
  // position it holds in COLUMNS, then re-deploy.
  const header = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  const mismatch =
    header.length !== columns.length ||
    columns.some(function (column, i) {
      return String(header[i]).trim() !== column;
    });
  if (mismatch) {
    throw new Error(
      'sheet "' + name + '" has an out-of-date header: got [' + header.join(', ') +
        '], expected [' + columns.join(', ') + ']'
    );
  }
  return sheet;
}

function json(body) {
  return ContentService.createTextOutput(JSON.stringify(body)).setMimeType(
    ContentService.MimeType.JSON
  );
}
