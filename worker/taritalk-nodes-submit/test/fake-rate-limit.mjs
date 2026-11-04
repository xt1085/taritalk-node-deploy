// A deterministic stand-in for the Workers Rate Limiting binding, for tests:
// limit({ key }) -> { success } with a fixed window per key, driven by a
// clock the test controls. It records every key it was asked about.
export function createFakeRateLimiter({ limit = 1, period = 60, now = () => 0 } = {}) {
  const windows = new Map();
  const calls = [];
  return {
    calls,
    async limit({ key }) {
      if (typeof key !== "string") throw new TypeError("rate limit key must be a string");
      calls.push(key);
      const time = now();
      let window = windows.get(key);
      if (!window || time - window.start >= period) {
        window = { start: time, count: 0 };
        windows.set(key, window);
      }
      window.count += 1;
      return { success: window.count <= limit };
    },
  };
}
