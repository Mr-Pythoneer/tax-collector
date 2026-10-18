// Per-address limits (docs/parent-link-v1.md §6.3), as token buckets that refill over a minute.
import net from "node:net";

export class RateLimiter {
  #buckets = new Map();

  constructor(perMinute, { now = Date.now, maxKeys = 20_000 } = {}) {
    this.perMinute = perMinute;
    this.now = now;
    this.maxKeys = maxKeys;
  }

  /** Takes one request from `key`'s bucket. Returns 0 if allowed, or seconds to wait. */
  take(key) {
    const now = this.now();
    let b = this.#buckets.get(key);
    if (!b) {
      if (this.#buckets.size >= this.maxKeys) this.prune(true);
      b = { tokens: this.perMinute, at: now };
      this.#buckets.set(key, b);
    }
    b.tokens = Math.min(this.perMinute, b.tokens + ((now - b.at) * this.perMinute) / 60_000);
    b.at = now;
    if (b.tokens >= 1) {
      b.tokens -= 1;
      return 0;
    }
    return Math.max(1, Math.ceil(((1 - b.tokens) * 60_000) / this.perMinute / 1000));
  }

  /** Forgets buckets that have refilled. With `hard`, also the oldest half when there are too many. */
  prune(hard = false) {
    const now = this.now();
    for (const [key, b] of this.#buckets) {
      if (b.tokens + ((now - b.at) * this.perMinute) / 60_000 >= this.perMinute) this.#buckets.delete(key);
    }
    if (hard && this.#buckets.size >= this.maxKeys) {
      const drop = [...this.#buckets.entries()].sort((a, b) => a[1].at - b[1].at).slice(0, this.maxKeys >> 1);
      for (const [key] of drop) this.#buckets.delete(key);
    }
  }

  get size() {
    return this.#buckets.size;
  }
}

const PRIVATE = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7"];
const unmap = (ip) => (ip.startsWith("::ffff:") && net.isIPv4(ip.slice(7)) ? ip.slice(7) : ip);

/**
 * Which proxies to believe about the client's address (TC_TRUST_PROXY). "loopback" (the default:
 * a proxy on this machine, like Tailscale Funnel), "private" (also private networks, for Docker's
 * port mapping), "0" or "off" (nobody), or a comma-separated list of addresses and CIDR ranges
 * (believed as well as loopback). true and false mean "loopback" and "off". Returns ip → boolean.
 */
export function proxyTrust(setting = "loopback") {
  if (typeof setting === "function") return setting;
  const s = setting === true ? "loopback" : setting === false ? "off" : String(setting).trim().toLowerCase();
  if (["0", "off", "false", "no", "none", ""].includes(s)) return () => false;
  const list = new net.BlockList();
  list.addSubnet("127.0.0.0", 8, "ipv4");
  list.addAddress("::1", "ipv6");
  const ranges = ["1", "on", "true", "yes", "loopback"].includes(s) ? [] : s === "private" ? PRIVATE : s.split(",").map((x) => x.trim()).filter(Boolean);
  for (const range of ranges) {
    const [address, bits, extra] = range.split("/");
    const type = net.isIPv4(address) ? "ipv4" : net.isIPv6(address) ? "ipv6" : null;
    const prefix = Number(bits);
    if (!type || extra !== undefined || (bits !== undefined && !(Number.isInteger(prefix) && prefix >= 0 && prefix <= (type === "ipv4" ? 32 : 128)))) {
      throw new Error(`TC_TRUST_PROXY: "${range}" isn't an address or a range like 172.17.0.0/16`);
    }
    if (bits === undefined) list.addAddress(address, type);
    else list.addSubnet(address, prefix, type);
  }
  return (ip) => {
    const v = unmap(ip ?? "");
    const type = net.isIPv4(v) ? "ipv4" : net.isIPv6(v) ? "ipv6" : null;
    return type !== null && list.check(v, type);
  };
}

/**
 * The address limits apply to. A proxy we believe (Tailscale Funnel or Serve, on this machine)
 * appends the real client to X-Forwarded-For, so only that last entry counts: anything before it
 * came from the client and could be made up.
 */
export function clientAddress(req, trusts) {
  let ip = req.socket.remoteAddress ?? "unknown";
  if (trusts(ip)) {
    const forwarded = req.headers["x-forwarded-for"];
    const last = typeof forwarded === "string" ? forwarded.split(",").pop().trim() : "";
    if (net.isIP(last)) ip = last;
  }
  return limitKey(ip);
}

/** IPv4 as is; IPv6 by its /64, since one home or phone gets a whole /64. */
export function limitKey(ip) {
  if (ip.startsWith("::ffff:") && net.isIPv4(ip.slice(7))) return ip.slice(7);
  if (!net.isIPv6(ip)) return ip;
  const [head, tail = ""] = ip.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = ip.includes("::") ? [...left, ...Array(8 - left.length - right.length).fill("0"), ...right] : left;
  return groups.slice(0, 4).map((g) => g.toLowerCase().replace(/^0+(?=.)/, "")).join(":") + "::/64";
}
