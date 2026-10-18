// The parent app, served from a fixed list of files (docs/parent-link-v1.md §6.3). Nothing here
// builds a file path from the URL: the URL is looked up in this table, and the files are read
// into memory once, at startup.
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

const HTML = "text/html; charset=utf-8";
const JS = "text/javascript; charset=utf-8";
const CSS = "text/css; charset=utf-8";
const PNG = "image/png";

/** [URL path, file under parent/, type]. Keep in step with PRECACHE in parent/sw.js. */
export const FILES = [
  ["/", "index.html", HTML],
  ["/app.css", "app.css", CSS],
  ["/manifest.webmanifest", "manifest.webmanifest", "application/manifest+json; charset=utf-8"],
  ["/sw.js", "sw.js", JS],
  ["/js/app.js", "js/app.js", JS],
  ["/js/ui.js", "js/ui.js", JS],
  ["/js/format.js", "js/format.js", JS],
  ["/js/phone.js", "js/phone.js", JS],
  ["/js/db.js", "js/db.js", JS],
  ["/js/linkcrypto.js", "js/linkcrypto.js", JS],
  ["/js/screens/common.js", "js/screens/common.js", JS],
  ["/js/screens/computers.js", "js/screens/computers.js", JS],
  ["/js/screens/pair.js", "js/screens/pair.js", JS],
  ["/js/screens/status.js", "js/screens/status.js", JS],
  ["/js/screens/lock.js", "js/screens/lock.js", JS],
  ["/js/screens/tasks.js", "js/screens/tasks.js", JS],
  ["/js/screens/repeats.js", "js/screens/repeats.js", JS],
  ["/js/screens/apps.js", "js/screens/apps.js", JS],
  ["/js/screens/settings.js", "js/screens/settings.js", JS],
  ["/js/screens/more.js", "js/screens/more.js", JS],
  ["/icons/icon-192.png", "icons/icon-192.png", PNG],
  ["/icons/icon-512.png", "icons/icon-512.png", PNG],
  ["/icons/maskable-512.png", "icons/maskable-512.png", PNG],
  ["/icons/apple-touch-icon.png", "icons/apple-touch-icon.png", PNG],
];

export const CSP =
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; " +
  "frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

/** Reads every listed file. Missing files are reported and left out. */
export function loadStatic(root, log = console) {
  const table = new Map();
  for (const [urlPath, file, type] of FILES) {
    let body;
    try {
      body = fs.readFileSync(path.join(root, file));
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
      log.warn("Parent app file missing: " + file);
      continue;
    }
    const etag = '"' + createHash("sha256").update(body).digest("base64url").slice(0, 22) + '"';
    table.set(urlPath, { body, type, etag });
  }
  return table;
}
