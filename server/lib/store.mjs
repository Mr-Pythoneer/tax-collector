// JSON files in the data folder. Every write goes to a temporary file that is synced and then
// renamed over the old one, so a crash or power cut leaves either the old file or the new one.
// Writes to one file run one at a time; saves made while a write is waiting are folded into it.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export class Store {
  #queues = new Map();
  #counter = 0;

  constructor(dir, { log = console } = {}) {
    this.dir = path.resolve(dir);
    this.log = log;
    fs.mkdirSync(path.join(this.dir, "channels"), { recursive: true, mode: 0o700 });
    // A crash in the middle of a write can leave a temporary file; the real file is intact.
    for (const folder of [this.dir, path.join(this.dir, "channels")]) {
      for (const name of fs.readdirSync(folder)) {
        if (/\.tmp-\d+-\d+$/.test(name)) fs.rmSync(path.join(folder, name), { force: true });
      }
    }
  }

  /** Reads and parses a file at startup. Missing → null. Unreadable → moved aside, null. */
  readJson(name) {
    const file = path.join(this.dir, name);
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch (e) {
      if (e.code === "ENOENT") return null;
      throw e;
    }
    try {
      return JSON.parse(text);
    } catch {
      const aside = file + ".unreadable-" + Date.now();
      fs.renameSync(file, aside);
      this.log.error("Couldn't read " + name + "; moved it to " + path.basename(aside));
      return null;
    }
  }

  /** Names of the files in a folder of the data folder. */
  list(folder) {
    try {
      return fs.readdirSync(path.join(this.dir, folder));
    } catch (e) {
      if (e.code === "ENOENT") return [];
      throw e;
    }
  }

  /**
   * Saves what `produce()` returns (a string; undefined deletes the file). `produce` runs when
   * the write starts, so it writes the newest data. Resolves once that's on disk.
   */
  save(name, produce) {
    let q = this.#queues.get(name);
    if (!q) {
      q = { tail: Promise.resolve(), waiting: null, produce };
      this.#queues.set(name, q);
    }
    q.produce = produce;
    if (q.waiting) return q.waiting;
    const write = q.tail.then(async () => {
      q.waiting = null;
      const data = q.produce();
      if (data === undefined) await this.#remove(name);
      else await this.#writeAtomic(name, data);
    });
    q.waiting = write;
    q.tail = write.catch((e) => this.log.error("Couldn't save " + name + ": " + e.message));
    return write;
  }

  remove(name) {
    return this.save(name, () => undefined);
  }

  /** Waits for every write that has been asked for. */
  async flush() {
    await Promise.all([...this.#queues.values()].map((q) => q.tail));
  }

  async #writeAtomic(name, text) {
    const file = path.join(this.dir, name);
    const tmp = file + ".tmp-" + process.pid + "-" + ++this.#counter;
    const fh = await fsp.open(tmp, "w", 0o600);
    try {
      await fh.writeFile(text);
      await fh.sync();
    } finally {
      await fh.close();
    }
    // Windows can refuse a rename for a moment while something else has the file open.
    for (let attempt = 0; ; attempt++) {
      try {
        await fsp.rename(tmp, file);
        break;
      } catch (e) {
        if (attempt >= 5 || !["EPERM", "EBUSY", "EACCES"].includes(e.code)) {
          await fsp.rm(tmp, { force: true });
          throw e;
        }
        await sleep(20 * (attempt + 1));
      }
    }
    await this.#syncDir(path.dirname(file));
  }

  async #remove(name) {
    await fsp.rm(path.join(this.dir, name), { force: true });
  }

  async #syncDir(dir) {
    if (process.platform === "win32") return;
    try {
      const fh = await fsp.open(dir, "r");
      try {
        await fh.sync();
      } finally {
        await fh.close();
      }
    } catch {
      // Some file systems can't sync a folder; the rename itself still happened.
    }
  }
}
