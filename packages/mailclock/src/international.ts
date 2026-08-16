import { seededIntInRange } from "./hash.js";

/**
 * International mail has no published service standard, so these bands are
 * observed ranges rather than commitments. A letter draws one value from its
 * band and keeps it.
 */
interface Band {
  readonly min: number;
  readonly max: number;
  readonly countries: readonly string[];
}

const BANDS: readonly Band[] = [
  { min: 7, max: 10, countries: ["CA", "MX"] },
  {
    min: 8,
    max: 14,
    countries: ["GB", "IE", "FR", "DE", "NL", "BE", "LU", "CH", "AT", "ES", "PT", "IT", "DK", "SE", "NO", "FI", "IS"],
  },
  {
    min: 10,
    max: 16,
    countries: ["PL", "CZ", "SK", "HU", "SI", "HR", "EE", "LV", "LT", "RO", "BG", "GR", "JP", "KR", "SG", "AU", "NZ"],
  },
  {
    min: 12,
    max: 21,
    countries: ["BR", "AR", "CL", "CO", "PE", "UY", "CR", "PA", "AE", "SA", "IL", "TR", "QA", "KW", "IN", "CN", "TH", "VN", "MY", "PH", "ID", "TW", "HK"],
  },
  {
    min: 14,
    max: 25,
    countries: ["ZA", "NG", "KE", "EG", "MA", "GH", "TZ", "UG", "ET", "SN", "FJ", "PG", "WS", "TO", "VU", "SB", "MV", "SC", "MU"],
  },
];

/** Everything unrecognised gets the broad middle band rather than a guess. */
const FALLBACK: Band = { min: 12, max: 21, countries: [] };

const BY_COUNTRY = new Map<string, Band>();
for (const band of BANDS) {
  for (const country of band.countries) BY_COUNTRY.set(country, band);
}

export function internationalBand(countryCode: string): { min: number; max: number } {
  const band = BY_COUNTRY.get(countryCode.toUpperCase()) ?? FALLBACK;
  return { min: band.min, max: band.max };
}

export function internationalTransitDays(messageId: string, destinationCountry: string): number {
  const { min, max } = internationalBand(destinationCountry);
  return seededIntInRange(min, max, "intl-transit", messageId);
}
