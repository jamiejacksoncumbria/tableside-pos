import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {after, before, beforeEach, describe, test} from "node:test";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {initializeTestEnvironment} from "@firebase/rules-unit-testing";
import {Timestamp, doc, getDoc, setDoc} from "firebase/firestore";
import {ref, set} from "firebase/database";

const directory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(directory, "..", "..");
const projectId = "demo-tableside-security";
const [firestoreHost, firestorePort] = emulatorAddress(
  process.env.FIRESTORE_EMULATOR_HOST,
  51080,
);
const [databaseHost, databasePort] = emulatorAddress(
  process.env.FIREBASE_DATABASE_EMULATOR_HOST,
  51000,
);
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:51099";
const functionsHost = process.env.FUNCTIONS_EMULATOR_HOST ?? "127.0.0.1:51102";
const posApiUrl = `http://${functionsHost}/${projectId}/europe-west2/posApi`;

const waiterToken = "waiter-session-token";
const managerToken = "manager-session-token";
const deviceId = "device-a";

let environment;
let identities;

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
  identities = {
    host: await createAuthUser("api-host@tableside.test"),
    waiter: await createAuthUser("api-waiter@tableside.test"),
    manager: await createAuthUser("api-manager@tableside.test"),
    target: await createAuthUser("api-target@tableside.test"),
  };
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.clearDatabase();
  await seedAuthorisationFixture();
});

after(async () => {
  await environment?.cleanup();
});

describe("POS HTTP authentication boundary", () => {
  test("rejects a request without a Firebase ID token", async () => {
    const response = await callPos("listVenuePinStaff", {
      tenantId: "tenant-a",
      venueId: "venue-a",
    }, null);

    assert.equal(response.status, 401);
    assert.equal(response.body.error.code, "unauthenticated");
  });

  test("every non-bootstrap action requires a staff PIN session", async (context) => {
    const source = fs.readFileSync(path.join(projectRoot, "functions", "index.js"), "utf8");
    const invokeStart = source.indexOf("async function invokePosAction");
    const invokeEnd = source.indexOf("async function callerFromHttpRequest", invokeStart);
    assert.ok(invokeStart >= 0 && invokeEnd > invokeStart);
    const invokeSource = source.slice(invokeStart, invokeEnd);
    const bootstrapMatch = invokeSource.match(
      /const sessionBootstrapActions = new Set\(\[([\s\S]*?)\]\);/u,
    );
    assert.ok(bootstrapMatch);
    const bootstrapActions = new Set(
      [...bootstrapMatch[1].matchAll(/"([^"]+)"/gu)].map((match) => match[1]),
    );
    assert.deepEqual([...bootstrapActions].sort(), approvedBootstrapActions().sort());

    const actions = [...invokeSource.matchAll(/case "([^"]+)":/gu)]
      .map((match) => match[1])
      .filter((action) => !bootstrapActions.has(action));
    assert.ok(actions.length >= 30, "Expected the operational action matrix to be discovered.");

    for (const action of actions) {
      await context.test(action, async () => {
        const response = await callPos(action, {
          tenantId: "tenant-a",
          venueId: "venue-a",
        });
        assert.equal(response.status, 401);
        assert.equal(response.body.error.code, "unauthenticated");
      });
    }
  });

  test("accepts a valid device-bound scoped staff session", async () => {
    const response = await callPos("updateOwnThemePreference", {
      ...waiterSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      themeMode: "dark",
    });

    assert.equal(response.status, 200);
    assert.equal(response.body.data.updated, true);
    await environment.withSecurityRulesDisabled(async (context) => {
      const preference = await getDoc(
        doc(context.firestore(), `userPreferences/${identities.waiter.localId}`),
      );
      assert.equal(preference.data().updatedFromVenueId, "venue-a");
    });
  });

  test("rejects a PIN session replayed from another device", async () => {
    const response = await callPos("updateOwnThemePreference", {
      ...waiterSession({device: "device-b"}),
      tenantId: "tenant-a",
      venueId: "venue-a",
      themeMode: "dark",
    });

    assert.equal(response.status, 401);
    assert.equal(response.body.error.code, "unauthenticated");
  });

  test("rejects cross-venue and cross-tenant session substitution", async (context) => {
    for (const [label, scope] of Object.entries({
      crossVenue: {tenantId: "tenant-a", venueId: "venue-b"},
      crossTenant: {tenantId: "tenant-b", venueId: "venue-a"},
    })) {
      await context.test(label, async () => {
        const response = await callPos("updateOwnThemePreference", {
          ...waiterSession(),
          ...scope,
          themeMode: "dark",
        });
        assert.equal(response.status, 403);
        assert.equal(response.body.error.code, "permission-denied");
      });
    }
  });

  test("rejects stale PIN and membership versions", async (context) => {
    for (const scenario of ["pinVersion", "membershipVersion"]) {
      await context.test(scenario, async () => {
        await environment.withSecurityRulesDisabled(async (admin) => {
          const firestore = admin.firestore();
          if (scenario === "pinVersion") {
            await setDoc(doc(
              firestore,
              `tenants/tenant-a/staffPins/venue-a_${identities.waiter.localId}`,
            ), {pinVersion: 2}, {merge: true});
          } else {
            await setDoc(doc(
              firestore,
              `tenants/tenant-a/members/${identities.waiter.localId}`,
            ), {membershipVersion: 2}, {merge: true});
          }
        });
        const response = await callPos("updateOwnThemePreference", {
          ...waiterSession(),
          tenantId: "tenant-a",
          venueId: "venue-a",
          themeMode: "dark",
        });
        assert.equal(response.status, 401);
        assert.equal(response.body.error.code, "unauthenticated");
      });
    }
  });

  test("enforces staff and host-device venue assignments", async (context) => {
    for (const principal of ["staff", "host"]) {
      await context.test(principal, async () => {
        await environment.withSecurityRulesDisabled(async (admin) => {
          const userId = principal === "staff"
            ? identities.waiter.localId
            : identities.host.localId;
          await setDoc(doc(
            admin.firestore(),
            `tenants/tenant-a/members/${userId}`,
          ), {venueIds: ["venue-b"]}, {merge: true});
        });
        const response = await callPos("updateOwnThemePreference", {
          ...waiterSession(),
          tenantId: "tenant-a",
          venueId: "venue-a",
          themeMode: "dark",
        });
        assert.equal(response.status, 403);
        assert.equal(response.body.error.code, "permission-denied");
      });
    }
  });
});

describe("POS role and replay protection", () => {
  test("waiter cannot run manager-only PIN administration", async () => {
    const response = await callPos("unlockStaffPin", {
      ...waiterSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      userId: identities.target.localId,
    });

    assert.equal(response.status, 403);
    assert.equal(response.body.error.code, "permission-denied");
  });

  test("manager can run the same manager-only operation", async () => {
    const response = await callPos("unlockStaffPin", {
      ...managerSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      userId: identities.target.localId,
    });

    assert.equal(response.status, 200);
    assert.equal(response.body.data.unlocked, true);
  });

  test("remote command retries are idempotent and altered replays are rejected", async () => {
    const command = {
      ...waiterSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      commandId: "command-a",
      idempotencyKey: "retry-a",
      eventType: "order.opened",
      hubEpoch: 7,
      payload: {orderId: "order-a", channel: "dineIn"},
    };
    const first = await callPos("submitRemoteHubCommand", command);
    const retry = await callPos("submitRemoteHubCommand", command);
    const altered = await callPos("submitRemoteHubCommand", {
      ...command,
      payload: {orderId: "order-b", channel: "dineIn"},
    });

    assert.equal(first.status, 200);
    assert.equal(retry.status, 200);
    assert.equal(altered.status, 409);
    assert.equal(altered.body.error.code, "already-exists");
  });
});

function approvedBootstrapActions() {
  return [
    "listVenuePinStaff", "setOwnStaffPin", "verifyStaffPin",
    "recoverOwnStaffPin", "heartbeatPrinterDevice", "claimDevicePrintJob",
    "completeDevicePrintJob", "issueRealtimePrinterSession", "getTrustedTime",
    "getOfflineHubBootstrap", "ingestOfflineHubEvents",
    "reconcileOfflineHubClosedOrders", "getOfflineHubSnapshot",
    "claimRemoteHubCommands", "issueRealtimeHubSession",
    "completeRemoteHubCommand",
  ];
}

function waiterSession({device = deviceId} = {}) {
  return sessionData("session-waiter", waiterToken, device);
}

function managerSession({device = deviceId} = {}) {
  return sessionData("session-manager", managerToken, device);
}

function sessionData(sessionId, sessionToken, device) {
  return {
    staffPinSessionId: sessionId,
    staffPinSessionToken: sessionToken,
    staffPinSessionDeviceId: device,
    staffPinSessionTenantId: "tenant-a",
    staffPinSessionVenueId: "venue-a",
  };
}

async function seedAuthorisationFixture() {
  const future = Timestamp.fromMillis(Date.now() + 30 * 60 * 1000);
  await environment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    const documents = {
      "tenants/tenant-a": {displayName: "Tenant A", currencyCode: "GBP"},
      "tenants/tenant-a/venues/venue-a": {
        name: "Venue A",
        status: "active",
        offlineHub: {enabled: true, deviceId: "hub-a", epoch: 7},
      },
      "tenants/tenant-a/venues/venue-b": {name: "Venue B", status: "active"},
      "tenants/tenant-b": {displayName: "Tenant B", currencyCode: "GBP"},
      "tenants/tenant-b/venues/venue-a": {name: "Other Tenant", status: "active"},
      [`tenants/tenant-a/members/${identities.host.localId}`]: membership(
        identities.host.localId,
        ["printer"],
      ),
      [`tenants/tenant-a/members/${identities.waiter.localId}`]: membership(
        identities.waiter.localId,
        ["waiter"],
      ),
      [`tenants/tenant-a/members/${identities.manager.localId}`]: membership(
        identities.manager.localId,
        ["manager"],
      ),
      [`tenants/tenant-a/members/${identities.target.localId}`]: membership(
        identities.target.localId,
        ["waiter"],
      ),
      [`tenants/tenant-a/staffPins/venue-a_${identities.waiter.localId}`]: pin(
        identities.waiter.localId,
      ),
      [`tenants/tenant-a/staffPins/venue-a_${identities.manager.localId}`]: pin(
        identities.manager.localId,
      ),
      [`tenants/tenant-a/staffPins/venue-a_${identities.target.localId}`]: {
        ...pin(identities.target.localId),
        locked: true,
        failedAttempts: 3,
      },
      "tenants/tenant-a/staffPinSessions/session-waiter": session(
        identities.host.localId,
        identities.waiter.localId,
        waiterToken,
        future,
      ),
      "tenants/tenant-a/staffPinSessions/session-manager": session(
        identities.host.localId,
        identities.manager.localId,
        managerToken,
        future,
      ),
    };
    await Promise.all(Object.entries(documents).map(([documentPath, data]) =>
      setDoc(doc(firestore, documentPath), data)));
    await set(ref(context.database(), "hubPresence/tenant-a/venue-a/hub-a"), {
      online: true,
      hubEpoch: 7,
      lastReadyAt: Date.now(),
    });
  });
}

function membership(userId, roles) {
  return {
    userId,
    roles,
    active: true,
    venueIds: ["venue-a"],
    membershipVersion: 1,
  };
}

function pin(userId) {
  return {
    userId,
    venueId: "venue-a",
    locked: false,
    failedAttempts: 0,
    pinVersion: 1,
  };
}

function session(hostUserId, userId, token, expiresAt) {
  return {
    hostUserId,
    userId,
    venueId: "venue-a",
    deviceId,
    pinVersion: 1,
    membershipVersion: 1,
    tokenHash: createHash("sha256").update(token).digest("base64"),
    expiresAt,
  };
}

async function createAuthUser(email) {
  const response = await fetch(
    `http://${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({email, password: "Test-password-123!", returnSecureToken: true}),
    },
  );
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  return body;
}

async function callPos(action, data, idToken = identities?.host?.idToken) {
  const headers = {"content-type": "application/json"};
  if (idToken != null) headers.authorization = `Bearer ${idToken}`;
  const response = await fetch(posApiUrl, {
    method: "POST",
    headers,
    body: JSON.stringify({action, data}),
  });
  return {status: response.status, body: await response.json()};
}

function emulatorAddress(value, fallbackPort) {
  if (typeof value !== "string" || value.length === 0) {
    return ["127.0.0.1", fallbackPort];
  }
  const separator = value.lastIndexOf(":");
  return [value.slice(0, separator), Number(value.slice(separator + 1))];
}
