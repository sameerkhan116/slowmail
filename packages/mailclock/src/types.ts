/** A correspondent's fixed postal identity: where they are and what clock they keep. */
export interface Party {
  /** IANA time zone, e.g. "America/New_York". */
  readonly tz: string;
  readonly lat: number;
  readonly lng: number;
  /** ISO 3166-1 alpha-2, e.g. "US". */
  readonly countryCode: string;
  /** US state or commonwealth code, e.g. "AK". Only consulted for US parties. */
  readonly region?: string;
  /** US territories and APO/FPO addresses, which run slower than any zone. */
  readonly isTerritory?: boolean;
}

export interface Recipient extends Party {
  /** Seeds the recipient's carrier arrival time; stable per person. */
  readonly userId: string;
}

export interface ScheduleInput {
  /** Stable letter id. Seeds transit jitter, so it must never be reassigned. */
  readonly messageId: string;
  /** ISO-8601 instant the letter was written. */
  readonly writtenAt: string;
  readonly sender: Party;
  readonly recipient: Recipient;
}

export interface Schedule {
  /** UTC instant the letter is collected, i.e. the point of no return. */
  readonly collectedAt: string;
  /** Sender-local date stamped on the letter (YYYY-MM-DD). */
  readonly postmarkDate: string;
  /**
   * Days the rules added. Postal days for domestic mail, calendar days for
   * international. `deliveryDate` is the authoritative outcome; this field is
   * for display and debugging.
   */
  readonly transitDays: number;
  /** Recipient-local date the mail lands (YYYY-MM-DD). */
  readonly deliveryDate: string;
  /** UTC instant the carrier arrives. */
  readonly deliverAt: string;
  readonly isInternational: boolean;
}
