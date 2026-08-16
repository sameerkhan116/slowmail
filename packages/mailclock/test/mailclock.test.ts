import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { DateTime } from "luxon";

import {
  ARRIVAL_WINDOW_END_HOUR,
  ARRIVAL_WINDOW_START_HOUR,
  addPostalDays,
  baseDomesticTransitDays,
  carrierArrival,
  fnv1a,
  internationalBand,
  isPostalDay,
  nextCollection,
  observedHolidays,
  schedule,
  transitJitter,
} from "../src/index.js";
import type { Party, Recipient } from "../src/index.js";

const fixturesPath = fileURLToPath(new URL("../../../fixtures/mailclock-cases.json", import.meta.url));
const fixtures = JSON.parse(readFileSync(fixturesPath, "utf8")) as Fixtures;

interface Fixtures {
  parties: Record<string, Party & Partial<Recipient>>;
  hashVectors: { input: string; fnv1a: number }[];
  observedHolidays2026: string[];
  postalDays: { date: string; isPostalDay: boolean; why: string }[];
  transitBands: { miles: number; days: number }[];
  internationalBands: { countryCode: string; min: number; max: number }[];
  jitterBranches: { messageId: string; jitter: number }[];
  collection: { name: string; writtenAt: string; tz: string; postmarkDate: string; collectedAt: string }[];
  schedule: {
    name: string;
    input: { messageId: string; writtenAt: string; sender: string; recipient: string };
    expected: Record<string, unknown>;
  }[];
}

const party = (key: string): Party => fixtures.parties[key] as Party;
const recipient = (key: string): Recipient => fixtures.parties[key] as Recipient;

describe("fnv1a", () => {
  it.each(fixtures.hashVectors)("matches the published vector for $input", ({ input, fnv1a: want }) => {
    expect(fnv1a(input)).toBe(want);
  });

  it("agrees with a literal big-integer implementation of the spec", () => {
    const PRIME = 16777619n;
    const MOD = 4294967296n;
    const reference = (s: string): number => {
      let h = 2166136261n;
      for (let i = 0; i < s.length; i++) {
        h ^= BigInt(s.charCodeAt(i));
        h = (h * PRIME) % MOD;
      }
      return Number(h);
    };
    for (let i = 0; i < 500; i++) {
      const sample = `letter-${i}-${(i * 7919) % 104729}`;
      expect(fnv1a(sample)).toBe(reference(sample));
    }
  });
});

describe("observed federal holidays", () => {
  it("computes 2026 from the rules", () => {
    expect([...observedHolidays(2026)].sort()).toEqual([...fixtures.observedHolidays2026].sort());
  });

  it.each(fixtures.postalDays)("$date is postal=$isPostalDay because $why", ({ date, isPostalDay: want }) => {
    expect(isPostalDay(date)).toBe(want);
  });

  it("never treats a Sunday as a postal day, across four years", () => {
    let cursor = DateTime.fromISO("2026-01-01", { zone: "utc" });
    while (cursor.year < 2030) {
      if (cursor.weekday === 7) expect(isPostalDay(cursor.toISODate()!)).toBe(false);
      cursor = cursor.plus({ days: 1 });
    }
  });
});

describe("collection", () => {
  it.each(fixtures.collection)("$name", ({ writtenAt, tz, postmarkDate, collectedAt }) => {
    const result = nextCollection(writtenAt, tz);
    expect(result.postmarkDate).toBe(postmarkDate);
    expect(result.at).toBe(collectedAt);
  });

  it("always lands on a postal day at 17:00 local, sampled across a year", () => {
    for (let day = 0; day < 365; day++) {
      const written = DateTime.fromISO("2026-01-01T12:00:00", { zone: "America/Chicago" }).plus({ days: day });
      const { at, postmarkDate } = nextCollection(written.toISO()!, "America/Chicago");
      expect(isPostalDay(postmarkDate)).toBe(true);
      const local = DateTime.fromISO(at, { zone: "America/Chicago" });
      expect(local.hour).toBe(17);
      expect(local.minute).toBe(0);
      expect(local.toISODate()).toBe(postmarkDate);
    }
  });

  it("is never earlier than the moment of writing", () => {
    for (let hour = 0; hour < 24; hour++) {
      const written = DateTime.fromObject(
        { year: 2026, month: 8, day: 15, hour },
        { zone: "America/New_York" },
      );
      expect(nextCollection(written.toISO()!, "America/New_York").at >= written.toUTC().toISO()!).toBe(true);
    }
  });
});

describe("distance bands", () => {
  const domestic: Party = { tz: "America/New_York", lat: 0, lng: 0, countryCode: "US" };

  it.each(fixtures.transitBands)("$miles miles is $days days", ({ miles, days }) => {
    expect(baseDomesticTransitDays(miles, domestic, domestic)).toBe(days);
  });

  it("is monotonic in distance", () => {
    let previous = 0;
    for (let miles = 0; miles <= 4000; miles += 7) {
      const days = baseDomesticTransitDays(miles, domestic, domestic);
      expect(days).toBeGreaterThanOrEqual(previous);
      previous = days;
    }
  });
});

describe("international bands", () => {
  it.each(fixtures.internationalBands)("$countryCode is $min-$max days", ({ countryCode, min, max }) => {
    expect(internationalBand(countryCode)).toEqual({ min, max });
  });
});

describe("transit jitter", () => {
  it.each(fixtures.jitterBranches)("$messageId jitters by $jitter", ({ messageId, jitter }) => {
    expect(transitJitter(messageId)).toBe(jitter);
  });

  it("is stable across repeated calls", () => {
    for (let i = 0; i < 200; i++) {
      const id = `stability-${i}`;
      expect(transitJitter(id)).toBe(transitJitter(id));
    }
  });

  it("distributes roughly 20% late and 10% early", () => {
    const counts = { late: 0, early: 0, onTime: 0 };
    const sampleSize = 20000;
    for (let i = 0; i < sampleSize; i++) {
      const j = transitJitter(`dist-${i}`);
      if (j === 1) counts.late++;
      else if (j === -1) counts.early++;
      else counts.onTime++;
    }
    expect(counts.late / sampleSize).toBeGreaterThan(0.18);
    expect(counts.late / sampleSize).toBeLessThan(0.22);
    expect(counts.early / sampleSize).toBeGreaterThan(0.08);
    expect(counts.early / sampleSize).toBeLessThan(0.12);
  });
});

describe("carrier arrival", () => {
  it("always falls inside the delivery window, in the recipient's zone", () => {
    for (const tz of ["America/New_York", "Asia/Tokyo", "Europe/London", "America/Anchorage", "Pacific/Guam"]) {
      for (let day = 0; day < 120; day++) {
        const date = DateTime.fromISO("2026-01-05", { zone: "utc" }).plus({ days: day }).toISODate()!;
        const local = DateTime.fromISO(carrierArrival("u-window", date, tz), { zone: tz });
        expect(local.toISODate()).toBe(date);
        expect(local.hour).toBeGreaterThanOrEqual(ARRIVAL_WINDOW_START_HOUR);
        expect(local.hour).toBeLessThan(ARRIVAL_WINDOW_END_HOUR);
      }
    }
  });

  it("gives every letter due the same day the same instant", () => {
    const a = carrierArrival("u-bundle", "2026-08-20", "America/Denver");
    const b = carrierArrival("u-bundle", "2026-08-20", "America/Denver");
    expect(a).toBe(b);
  });

  it("is only one instant if the zone is one zone", () => {
    // Passing the same zone twice asserts nothing the seed doesn't already
    // guarantee. The property callers actually need is that they resolved the
    // recipient's zone once — because if they didn't, this is what they get,
    // and it is the recipient watching the post arrive twice in a day.
    const date = "2026-11-01";
    const east = carrierArrival("u-moved", date, "America/New_York");
    const west = carrierArrival("u-moved", date, "America/Los_Angeles");
    expect(east).not.toBe(west);
    const gap = Math.abs(Date.parse(west) - Date.parse(east)) / 3_600_000;
    expect(gap).toBe(3);

    // Same wall clock, though — the seeded minute did not move.
    for (const [iso, tz] of [[east, "America/New_York"], [west, "America/Los_Angeles"]] as const) {
      expect(DateTime.fromISO(iso, { zone: tz }).toFormat("HH:mm")).toBe(
        DateTime.fromISO(east, { zone: "America/New_York" }).toFormat("HH:mm"),
      );
    }
  });

  it("differs between people on the same day", () => {
    const mine = carrierArrival("u-one", "2026-08-20", "America/Denver");
    const theirs = carrierArrival("u-two", "2026-08-20", "America/Denver");
    expect(mine).not.toBe(theirs);
  });
});

describe("postal day arithmetic", () => {
  it("counts only days the mail moves", () => {
    expect(addPostalDays("2026-08-14", 1)).toBe("2026-08-15");
    expect(addPostalDays("2026-08-14", 2)).toBe("2026-08-17");
    expect(addPostalDays("2026-09-04", 2)).toBe("2026-09-08");
  });

  it("returns the same date when advancing zero days", () => {
    expect(addPostalDays("2026-08-14", 0)).toBe("2026-08-14");
  });
});

describe("schedule", () => {
  it.each(fixtures.schedule)("$name", ({ input, expected }) => {
    const result = schedule({
      messageId: input.messageId,
      writtenAt: input.writtenAt,
      sender: party(input.sender),
      recipient: recipient(input.recipient),
    });
    expect(result).toEqual(expected);
  });

  it("is deterministic: the same letter always schedules identically", () => {
    const input = {
      messageId: "letter-0010",
      writtenAt: "2026-08-20T10:00:00-04:00",
      sender: party("nyc"),
      recipient: recipient("philly"),
    };
    expect(schedule(input)).toEqual(schedule(input));
  });

  it("never delivers before it collects, over a year of writing times and every party pair", () => {
    const senders = ["nyc", "tokyo"];
    const recipients = ["philly", "anchorage", "guam", "london", "la"];
    for (const s of senders) {
      for (const r of recipients) {
        for (let day = 0; day < 365; day += 11) {
          const writtenAt = DateTime.fromISO("2026-01-01T13:00:00Z").plus({ days: day }).toISO()!;
          const result = schedule({
            messageId: `sweep-${s}-${r}-${day}`,
            writtenAt,
            sender: party(s),
            recipient: recipient(r),
          });
          expect(result.deliverAt > result.collectedAt).toBe(true);
          expect(result.deliverAt > writtenAt).toBe(true);
          expect(result.transitDays).toBeGreaterThanOrEqual(1);
        }
      }
    }
  });

  it("never delivers domestic mail on a Sunday or a holiday", () => {
    for (let day = 0; day < 365; day += 3) {
      const writtenAt = DateTime.fromISO("2026-01-01T13:00:00Z").plus({ days: day }).toISO()!;
      const result = schedule({
        messageId: `dom-${day}`,
        writtenAt,
        sender: party("nyc"),
        recipient: recipient("philly"),
      });
      expect(isPostalDay(result.deliveryDate)).toBe(true);
    }
  });

  it("never delivers international mail on a Sunday", () => {
    for (let day = 0; day < 365; day += 3) {
      const writtenAt = DateTime.fromISO("2026-01-01T13:00:00Z").plus({ days: day }).toISO()!;
      const result = schedule({
        messageId: `intl-${day}`,
        writtenAt,
        sender: party("nyc"),
        recipient: recipient("london"),
      });
      expect(DateTime.fromISO(result.deliveryDate, { zone: "utc" }).weekday).not.toBe(7);
    }
  });
});
