// What the parent app keeps, in IndexedDB. The link key and signing key are stored as
// non-extractable CryptoKeys: the browser can use them but no script can read them out.
const NAME = "tax-collector-parent";
const VERSION = 1;

let opened = null;

function promisify(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export function openDb() {
  if (opened) return opened;
  opened = new Promise((resolve, reject) => {
    const req = indexedDB.open(NAME, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains("computers")) db.createObjectStore("computers", { keyPath: "id" });
      if (!db.objectStoreNames.contains("counters")) db.createObjectStore("counters", { keyPath: "id" });
      if (!db.objectStoreNames.contains("cache")) db.createObjectStore("cache", { keyPath: "id" });
      if (!db.objectStoreNames.contains("commands")) db.createObjectStore("commands", { keyPath: "id" }).createIndex("computer", "computer");
      if (!db.objectStoreNames.contains("prefs")) db.createObjectStore("prefs", { keyPath: "key" });
    };
    req.onsuccess = () => {
      const db = req.result;
      db.onversionchange = () => db.close();
      resolve(db);
    };
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error("Close the app's other windows and try again."));
  });
  return opened;
}

async function tx(store, mode, fn) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode);
    let result;
    Promise.resolve(fn(t.objectStore(store)))
      .then((r) => (result = r))
      .catch(reject);
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error ?? new Error("Couldn't save"));
  });
}

const get = (store, key) => tx(store, "readonly", (s) => promisify(s.get(key)));
const all = (store) => tx(store, "readonly", (s) => promisify(s.getAll()));
const put = (store, value) => tx(store, "readwrite", (s) => promisify(s.put(value)));
const del = (store, key) => tx(store, "readwrite", (s) => promisify(s.delete(key)));

export const computers = {
  all: () => all("computers"),
  get: (id) => get("computers", id),
  put: (rec) => put("computers", rec),
  async delete(id) {
    await del("computers", id);
    await del("counters", id);
    await del("cache", id);
    const cmds = await commands.forComputer(id);
    await tx("commands", "readwrite", (s) => Promise.all(cmds.map((c) => promisify(s.delete(c.id)))));
  },
};

/** The command counter (§5.1), one per paired computer. */
export const counters = {
  async getCounter(id) {
    return (await get("counters", id))?.n ?? 0;
  },
  setCounter: (id, n) => put("counters", { id, n }),
};

/** The last state shown for each computer, so the app opens with news even offline. */
export const cache = {
  get: (id) => get("cache", id),
  put: (entry) => put("cache", entry),
};

/** Commands this phone sent, with where each one got to. */
export const commands = {
  forComputer: (id) => tx("commands", "readonly", (s) => promisify(s.index("computer").getAll(id))),
  put: (cmd) => put("commands", cmd),
  /** Keeps the newest `keep`. */
  async prune(id, keep = 40) {
    const list = (await commands.forComputer(id)).sort((a, b) => b.sentAt - a.sentAt);
    const drop = list.slice(keep);
    if (drop.length) await tx("commands", "readwrite", (s) => Promise.all(drop.map((c) => promisify(s.delete(c.id)))));
  },
};

export const prefs = {
  get: async (key) => (await get("prefs", key))?.value,
  set: (key, value) => put("prefs", { key, value }),
};
