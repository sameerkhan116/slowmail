import type { Party } from "./types.js";

/** Non-contiguous US states and commonwealths always price as the far zone. */
const NON_CONTIGUOUS = new Set(["AK", "HI", "PR"]);

/**
 * Base domestic transit in postal days, before jitter.
 *
 * The bands come from USPS First-Class service standards. Distance is measured
 * between the two parties' home coordinates, which is a stand-in for the real
 * origin/destination facility pair.
 */
export function baseDomesticTransitDays(miles: number, sender: Party, recipient: Party): number {
  if (sender.isTerritory === true || recipient.isTerritory === true) return 7;
  if (isNonContiguous(sender) || isNonContiguous(recipient)) return 5;
  if (miles <= 50) return 1;
  if (miles <= 300) return 2;
  if (miles <= 1000) return 3;
  if (miles <= 1800) return 4;
  return 5;
}

function isNonContiguous(party: Party): boolean {
  return party.region !== undefined && NON_CONTIGUOUS.has(party.region);
}
