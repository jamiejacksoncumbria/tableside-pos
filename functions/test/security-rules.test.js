import {after, before, beforeEach, describe, test} from "node:test";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  Timestamp,
  doc,
  getDoc,
  setDoc,
} from "firebase/firestore";
import {
  get,
  ref,
  set,
} from "firebase/database";

const directory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(directory, "..", "..");
const projectId = "demo-tableside-security";
const [firestoreHost, firestorePort] = emulatorAddress(
  process.env.FIRESTORE_EMULATOR_HOST,
  8080,
);
const [databaseHost, databasePort] = emulatorAddress(
  process.env.FIREBASE_DATABASE_EMULATOR_HOST,
  9000,
);

let environment;

before(async () => {
  environment = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: firestoreHost,
      port: firestorePort,
      rules: fs.readFileSync(
        path.join(projectRoot, "firebase", "firestore.rules"),
        "utf8",
      ),
    },
    database: {
      host: databaseHost,
      port: databasePort,
      rules: fs.readFileSync(
        path.join(projectRoot, "firebase", "database.rules.json"),
        "utf8",
      ),
    },
  });
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.clearDatabase();
});

after(async () => {
  await environment?.cleanup();
});

describe("Firestore staff PIN boundary", () => {
  test("host membership alone cannot read operational data", async () => {
    await seedFirestore({includeWaiterAuthorization: false});
    const firestore = environment.authenticatedContext("host-waiter").firestore();

    await assertFails(getDoc(doc(firestore, productPath("product-a"))));
  });

  test("active waiter lease reads only its selected venue", async () => {
    await seedFirestore();
    const firestore = environment.authenticatedContext("host-waiter").firestore();

    await assertSucceeds(getDoc(doc(firestore, productPath("product-a"))));
    await assertFails(getDoc(doc(firestore, productPath("product-b"))));
  });

  test("expired, locked and version-stale leases fail closed", async (context) => {
    for (const scenario of ["expired", "locked", "pinChanged", "accessChanged"]) {
      await context.test(scenario, async () => {
        await environment.clearFirestore();
        await seedFirestore({scenario});
        const firestore = environment
          .authenticatedContext("host-waiter")
          .firestore();
        await assertFails(getDoc(doc(firestore, productPath("product-a"))));
      });
    }
  });

  test("retired host or selected staff loses access immediately", async (context) => {
    for (const scenario of ["retiredHost", "retiredStaff"]) {
      await context.test(scenario, async () => {
        await environment.clearFirestore();
        await seedFirestore({scenario});
        const firestore = environment
          .authenticatedContext("host-waiter")
          .firestore();
        await assertFails(getDoc(doc(firestore, productPath("product-a"))));
      });
    }
  });

  test("waiters cannot read financial manager data", async () => {
    await seedFirestore();
    const waiter = environment.authenticatedContext("host-waiter").firestore();
    const manager = environment.authenticatedContext("host-manager").firestore();

    await assertFails(getDoc(doc(waiter, tenantPath("bills/bill-a"))));
    await assertSucceeds(getDoc(doc(manager, tenantPath("bills/bill-a"))));
  });

  test("driver-only lease reads assigned orders but not other jobs", async () => {
    await seedFirestore();
    const driver = environment.authenticatedContext("host-driver").firestore();

    await assertSucceeds(getDoc(doc(driver, tenantPath("orders/order-driver"))));
    await assertFails(getDoc(doc(driver, tenantPath("orders/order-other"))));
  });

  test("all direct operational writes remain server-only", async () => {
    await seedFirestore();
    const manager = environment.authenticatedContext("host-manager").firestore();

    await assertFails(setDoc(doc(manager, productPath("new-product")), {
      venueId: "venue-a",
      name: "Injected product",
    }));
    await assertFails(setDoc(doc(manager, tenantPath("orders/injected-order")), {
      venueId: "venue-a",
      status: "open",
    }));
    await assertFails(setDoc(doc(manager, tenantPath("refunds/injected-refund")), {
      venueId: "venue-a",
      amountMinor: 100,
    }));
  });

  test("platform claim is not a blanket restaurant data export", async () => {
    await seedFirestore();
    const platform = environment.authenticatedContext("platform-admin", {
      platformAdmin: true,
    }).firestore();

    await assertFails(getDoc(doc(platform, productPath("product-a"))));
    await assertFails(getDoc(doc(platform, tenantPath("bills/bill-a"))));
  });
});

describe("Realtime Database scoped control-plane identities", () => {
  test("hub may publish only its authorised venue and epoch", async () => {
    await seedRealtimeAuthorities();
    const validHub = environment.authenticatedContext("hub", {
      tablesideHub: true,
      tenantId: "tenant-a",
      venueId: "venue-a",
      deviceId: "hub-a",
      hubEpoch: 7,
    }).database();
    const wrongHub = environment.authenticatedContext("wrong-hub", {
      tablesideHub: true,
      tenantId: "tenant-a",
      venueId: "venue-b",
      deviceId: "hub-a",
      hubEpoch: 7,
    }).database();
    const payload = {online: true, hubEpoch: 7, lastReadyAt: 1234};

    await assertSucceeds(set(
      ref(validHub, "hubPresence/tenant-a/venue-a/hub-a"),
      payload,
    ));
    await assertFails(set(
      ref(wrongHub, "hubPresence/tenant-a/venue-a/hub-a"),
      payload,
    ));
  });

  test("POS presence read is venue scoped", async () => {
    await seedRealtimeAuthorities();
    const pos = environment.authenticatedContext("pos", {
      tablesidePos: true,
      tenantId: "tenant-a",
      venueId: "venue-a",
      hostUid: "host-waiter",
      staffId: "staff-waiter",
    }).database();

    await assertSucceeds(get(ref(pos, "hubPresence/tenant-a/venue-a/hub-a")));
    await assertFails(get(ref(pos, "hubPresence/tenant-a/venue-b/hub-b")));
  });

  test("printer may publish only its own presence", async () => {
    await seedRealtimeAuthorities();
    const printer = environment.authenticatedContext("printer", {
      tablesidePrinter: true,
      tenantId: "tenant-a",
      venueId: "venue-a",
      deviceId: "printer-a",
    }).database();

    await assertSucceeds(set(
      ref(printer, "printerPresence/tenant-a/venue-a/printer-a"),
      {online: true, lastReadyAt: 1234},
    ));
    await assertFails(set(
      ref(printer, "printerPresence/tenant-a/venue-a/printer-b"),
      {online: true, lastReadyAt: 1234},
    ));
  });
});

async function seedFirestore({
  scenario = "valid",
  includeWaiterAuthorization = true,
} = {}) {
  await environment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    const future = Timestamp.fromMillis(Date.now() + 30 * 60 * 1000);
    const past = Timestamp.fromMillis(Date.now() - 60 * 1000);
    const documents = {
      "tenants/tenant-a": {displayName: "Tenant A"},
      "tenants/tenant-a/members/host-waiter": {
        userId: "host-waiter", roles: ["printer"],
        active: scenario !== "retiredHost",
      },
      "tenants/tenant-a/members/host-manager": {
        userId: "host-manager", roles: ["printer"], active: true,
      },
      "tenants/tenant-a/members/host-driver": {
        userId: "host-driver", roles: ["printer"], active: true,
      },
      "tenants/tenant-a/members/staff-waiter": {
        userId: "staff-waiter", roles: ["waiter"],
        active: scenario !== "retiredStaff",
        membershipVersion: scenario === "accessChanged" ? 2 : 1,
      },
      "tenants/tenant-a/members/staff-manager": {
        userId: "staff-manager", roles: ["manager"], active: true,
        membershipVersion: 1,
      },
      "tenants/tenant-a/members/staff-driver": {
        userId: "staff-driver", roles: ["driver"], active: true,
        membershipVersion: 1,
      },
      "tenants/tenant-a/staffPins/venue-a_staff-waiter": {
        venueId: "venue-a", userId: "staff-waiter",
        locked: scenario === "locked",
        pinVersion: scenario === "pinChanged" ? 2 : 1,
      },
      "tenants/tenant-a/staffPins/venue-a_staff-manager": {
        venueId: "venue-a", userId: "staff-manager",
        locked: false, pinVersion: 1,
      },
      "tenants/tenant-a/staffPins/venue-a_staff-driver": {
        venueId: "venue-a", userId: "staff-driver",
        locked: false, pinVersion: 1,
      },
      "tenants/tenant-a/staffPinAuthorizations/host-manager": authorization({
        userId: "staff-manager", roles: ["manager"], expiresAt: future,
      }),
      "tenants/tenant-a/staffPinAuthorizations/host-driver": authorization({
        userId: "staff-driver", roles: ["driver"], expiresAt: future,
      }),
      "tenants/tenant-a/products/product-a": {
        venueId: "venue-a", name: "Venue A product",
      },
      "tenants/tenant-a/products/product-b": {
        venueId: "venue-b", name: "Venue B product",
      },
      "tenants/tenant-a/bills/bill-a": {
        venueId: "venue-a", totalMinor: 1000,
      },
      "tenants/tenant-a/orders/order-driver": {
        venueId: "venue-a", assignedDriverId: "staff-driver", status: "open",
      },
      "tenants/tenant-a/orders/order-other": {
        venueId: "venue-a", assignedDriverId: "someone-else", status: "open",
      },
    };
    if (includeWaiterAuthorization) {
      documents["tenants/tenant-a/staffPinAuthorizations/host-waiter"] =
        authorization({
          userId: "staff-waiter", roles: ["waiter"],
          expiresAt: scenario === "expired" ? past : future,
        });
    }
    await Promise.all(Object.entries(documents).map(([documentPath, data]) =>
      setDoc(doc(firestore, documentPath), data)));
  });
}

function authorization({userId, roles, expiresAt}) {
  return {
    userId,
    venueId: "venue-a",
    sessionId: `session-${userId}`,
    roles,
    pinVersion: 1,
    membershipVersion: 1,
    expiresAt,
  };
}

async function seedRealtimeAuthorities() {
  await environment.withSecurityRulesDisabled(async (context) => {
    const database = context.database();
    await Promise.all([
      set(ref(database, "hubAuthorities/tenant-a/venue-a"), {
        enabled: true, deviceId: "hub-a", hubEpoch: 7,
      }),
      set(ref(database, "hubPresence/tenant-a/venue-b/hub-b"), {
        online: true, hubEpoch: 1, lastReadyAt: 1234,
      }),
      set(ref(database, "printerAuthorities/tenant-a/venue-a/printer-a"), {
        active: true,
      }),
    ]);
  });
}

function tenantPath(suffix) {
  return `tenants/tenant-a/${suffix}`;
}

function productPath(productId) {
  return tenantPath(`products/${productId}`);
}

function emulatorAddress(value, fallbackPort) {
  if (!value) return ["127.0.0.1", fallbackPort];
  const separator = value.lastIndexOf(":");
  return [value.substring(0, separator), Number(value.substring(separator + 1))];
}
