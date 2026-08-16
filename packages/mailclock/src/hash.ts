/**
 * Deterministic hashing.
 *
 * Every "random" quantity in this package (transit jitter, a carrier's arrival
 * time) must be stable forever: the same letter has to produce the same answer
 * on every device, in every process, for as long as the letter exists. So these
 * are seeded hashes, never a PRNG, and the algorithm is pinned by the fixtures.
 */

/** FNV-1a, 32-bit. Chosen for being trivially portable to Swift and SQL. */
export function fnv1a(input: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    // 32-bit FNV prime (16777619) via shifts, to stay inside Number's safe range.
    hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
  }
  return hash >>> 0;
}

/**
 * A hash namespaced by purpose. Without this, the jitter draw and the arrival
 * draw would be perfectly correlated for any letter whose id equals a user id.
 */
export function seededHash(namespace: string, ...parts: string[]): number {
  return fnv1a(`${namespace}\u0000${parts.join("\u0000")}`);
}

/** Uniform in [0, 1). */
export function seededUnit(namespace: string, ...parts: string[]): number {
  return seededHash(namespace, ...parts) / 0x100000000;
}

/** Uniform integer in [min, max], inclusive at both ends. */
export function seededIntInRange(
  min: number,
  max: number,
  namespace: string,
  ...parts: string[]
): number {
  if (max < min) throw new RangeError(`empty range: [${min}, ${max}]`);
  const span = max - min + 1;
  return min + (seededHash(namespace, ...parts) % span);
}
