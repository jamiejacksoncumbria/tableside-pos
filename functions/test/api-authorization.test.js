import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  scryptSync,
  sign as signMessage,
} from "node:crypto";
import {after, before, beforeEach, describe, test} from "node:test";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {initializeTestEnvironment} from "@firebase/rules-unit-testing";
import {
  Timestamp,
  doc,
  getDoc,
  setDoc,
} from "firebase/firestore";
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
const printerCredentialA = "printer-credential-a";
const printerCredentialB = "printer-credential-b";
const hubCredentialId = "credential-a";
const hubDeviceId = "hub-a";
const hubEpoch = 7;
const hubKeys = generateKeyPairSync("ed25519");
const hubPublicKeyBase64 = hubKeys.publicKey.export({
  format: "der",
  type: "spki",
}).subarray(-32).toString("base64url");

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

describe("venue hub cloud reconciliation", () => {
  test("projects a signed sale exactly once into orders, bills, stock and production", async () => {
    const createdAt = new Date().toISOString();
    const events = [
      hubEvent(1, "event-open", "", "hash-open", "order.opened", {
        orderId: "order-cloud-a",
        channel: "dineIn",
        tableId: "table-a",
      }, createdAt),
      hubEvent(2, "event-item", "hash-open", "hash-item", "order.itemAdded", {
        orderId: "order-cloud-a",
        lineId: "line-curry",
        productId: "menu-curry",
        productName: "House Curry",
        quantity: 1,
        unitPriceMinor: 1500,
        taxRateBasisPoints: 2000,
        currencyCode: "GBP",
        productionArea: "kitchen",
        showOnOrderFlow: true,
        trackStock: true,
        stockComponents: [{
          productId: "stock-curry",
          productName: "Curry Portion",
          quantityPerSale: 2,
          stockUnit: "portion",
        }],
      }, createdAt),
      hubEvent(3, "event-sent", "hash-item", "hash-sent", "order.sent", {
        orderId: "order-cloud-a",
        lineIds: ["line-curry"],
        printRequired: true,
      }, createdAt),
      hubEvent(4, "event-paid", "hash-sent", "hash-paid", "payment.recorded", {
        orderId: "order-cloud-a",
        paymentId: "payment-cloud-a",
        method: "cash",
        currencyCode: "GBP",
        tenderedAmountMinor: 2000,
        baseAmountMinor: 1500,
        exchangeRateToBase: "1",
        cashChangeBaseMinor: 500,
      }, createdAt),
      hubEvent(5, "event-close", "hash-paid", "hash-close", "order.closed", {
        orderId: "order-cloud-a",
        receiptNumber: "R-CLOUD-1",
      }, createdAt),
    ];

    const first = await callPos("ingestOfflineHubEvents", signedHubUpload(events, "nonce-a"));
    assert.equal(first.status, 200, JSON.stringify(first.body));
    assert.deepEqual(first.body.data.acknowledgedEventIds, events.map((event) => event.id));

    await assertCloudSaleProjection();

    // A lost acknowledgement can make a hub upload the identical immutable
    // events again. A fresh signed nonce must acknowledge that replay without
    // duplicating stock, tickets, bills, payments, or order lines.
    const replay = await callPos(
      "ingestOfflineHubEvents",
      signedHubUpload(events, "nonce-b"),
    );
    assert.equal(replay.status, 200, JSON.stringify(replay.body));
    assert.deepEqual(replay.body.data.acknowledgedEventIds, events.map((event) => event.id));

    await assertCloudSaleProjection();
  });
});

describe("financial integrity", () => {
  test("mixed tender, voucher redemption and refund retain immutable totals", async () => {
    await seedFinancialOrder("order-financial");

    const voucherIssue = await callPos("manageVoucher", {
      ...managerSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      operation: "issue",
      amountMinor: 1000,
      chargeable: true,
      issueReason: "Customer gift voucher purchase",
      paymentMethod: "cash",
      expiresAtMillis: Date.now() + 30 * 24 * 60 * 60 * 1000,
    });
    assert.equal(voucherIssue.status, 200, JSON.stringify(voucherIssue.body));
    const voucher = voucherIssue.body.data;

    const partialRequest = {
      ...managerSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      orderId: "order-financial",
      requestId: "payment-financial-partial",
      printReceipt: false,
      payments: [{
        method: "cash",
        amountMinor: 1000,
        currencyCode: "EUR",
        exchangeRateToBase: "0.8",
        cashChangeBaseMinor: 0,
        exchangeRateSource: "Test fixed rate",
        exchangeRatePublishedDate: "2026-10-25",
        exchangeRateFetchedAt: new Date().toISOString(),
      }],
    };
    const partial = await callPos("closeOrder", partialRequest);
    assert.equal(partial.status, 200, JSON.stringify(partial.body));
    assert.equal(partial.body.data.orderClosed, false);
    assert.equal(partial.body.data.paidThisTimeMinor, 800);
    assert.equal(partial.body.data.balanceDueMinor, 2200);

    const finalRequest = {
      ...managerSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      orderId: "order-financial",
      requestId: "payment-financial-final",
      printReceipt: false,
      payments: [
        {
          method: "voucher",
          amountMinor: 1000,
          currencyCode: "GBP",
          voucherCode: voucher.code,
        },
        {
          method: "cash",
          amountMinor: 1200,
          currencyCode: "GBP",
          cashChangeBaseMinor: 0,
        },
      ],
    };
    const finalPayment = await callPos("closeOrder", finalRequest);
    const finalReplay = await callPos("closeOrder", finalRequest);
    assert.equal(finalPayment.status, 200, JSON.stringify(finalPayment.body));
    assert.equal(finalReplay.status, 200, JSON.stringify(finalReplay.body));
    assert.equal(finalPayment.body.data.orderClosed, true);
    assert.equal(finalPayment.body.data.paidTotalMinor, 3000);
    assert.equal(finalPayment.body.data.balanceDueMinor, 0);
    assert.equal(finalReplay.body.data.receiptNumber, finalPayment.body.data.receiptNumber);

    const refundRequest = {
      ...managerSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      billId: "order-financial",
      requestId: "refund-financial-a",
      managerPin: "123456",
      reason: "Customer returned one meal",
      printReceipt: false,
      lines: [{lineId: "line-food", quantity: 1}],
    };
    const refund = await callPos("createRefund", refundRequest);
    const refundReplay = await callPos("createRefund", refundRequest);
    assert.equal(refund.status, 200, JSON.stringify(refund.body));
    assert.equal(refundReplay.status, 200, JSON.stringify(refundReplay.body));
    assert.equal(refund.body.data.totalMinor, 1000);
    assert.equal(refund.body.data.stockAdjustmentRequired, true);
    assert.equal(refundReplay.body.data.alreadyRefunded, true);

    const overRefund = await callPos("createRefund", {
      ...refundRequest,
      requestId: "refund-financial-over",
      lines: [{lineId: "line-food", quantity: 2}],
    });
    assert.equal(overRefund.status, 412);

    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      const [order, bill, refundDoc, voucherDoc, stock] = await Promise.all([
        getDoc(doc(firestore, "tenants/tenant-a/orders/order-financial")),
        getDoc(doc(firestore, "tenants/tenant-a/bills/order-financial")),
        getDoc(doc(firestore, "tenants/tenant-a/refunds/refund-financial-a")),
        getDoc(doc(firestore, `tenants/tenant-a/vouchers/${voucher.id}`)),
        getDoc(doc(firestore, "tenants/tenant-a/products/stock-curry")),
      ]);
      assert.equal(order.data().status, "closed");
      assert.equal(order.data().payments.length, 3);
      assert.equal(bill.data().grossTotalMinor, 3000);
      assert.equal(bill.data().taxTotalMinor, 424);
      assert.equal(bill.data().netTotalMinor, 2576);
      assert.equal(bill.data().lines.length, 2);
      assert.equal(bill.data().payments[0].tenderedCurrencyCode, "EUR");
      assert.equal(bill.data().payments[0].exchangeRateToBase, "0.8");
      assert.equal(refundDoc.data().grossMinor, 1000);
      assert.equal(refundDoc.data().taxMinor, 167);
      assert.equal(refundDoc.data().netMinor, 833);
      assert.deepEqual(
        refundDoc.data().paymentAllocations.map((value) => value.baseAmountMinor),
        [800, 200],
      );
      assert.equal(voucherDoc.data().remainingValueMinor, 200);
      assert.equal(voucherDoc.data().status, "active");
      assert.equal(stock.data().stockOnHand, 18);
      assert.equal(refundDoc.data().stockRestored, false);
      assert.equal(
        bill.data().grossTotalMinor - refundDoc.data().grossMinor,
        2000,
      );
      assert.equal(
        bill.data().taxTotalMinor - refundDoc.data().taxMinor,
        257,
      );
    });
  });

  test("split bill preserves value and is idempotent", async () => {
    await seedFinancialOrder("order-split");
    const request = {
      ...managerSession(),
      tenantId: "tenant-a",
      venueId: "venue-a",
      orderId: "order-split",
      splitOrderId: "order-split-child",
      splitLines: [{lineId: "line-food", quantity: 1}],
    };
    const first = await callPos("splitOrder", request);
    const replay = await callPos("splitOrder", request);
    assert.equal(first.status, 200, JSON.stringify(first.body));
    assert.equal(replay.status, 200, JSON.stringify(replay.body));
    assert.equal(first.body.data.splitTotalMinor, 1000);
    assert.equal(first.body.data.remainingTotalMinor, 2000);
    assert.equal(replay.body.data.alreadySplit, true);

    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      const [parent, child, table] = await Promise.all([
        getDoc(doc(firestore, "tenants/tenant-a/orders/order-split")),
        getDoc(doc(firestore, "tenants/tenant-a/orders/order-split-child")),
        getDoc(doc(firestore, "tenants/tenant-a/tables/table-a")),
      ]);
      const parentTotal = orderLinesTotal(parent.data().lines);
      const childTotal = orderLinesTotal(child.data().lines);
      assert.equal(parentTotal, 2000);
      assert.equal(childTotal, 1000);
      assert.equal(parentTotal + childTotal, 3000);
      assert.deepEqual(parent.data().openSplitOrderIds, ["order-split-child"]);
      assert.equal(child.data().splitFromOrderId, "order-split");
      assert.equal(table.data().currentOrderId, "order-split");
    });
  });
});

describe("printer delivery reliability", () => {
  test("PIN-independent claims are device isolated and terminal acknowledgements are idempotent", async () => {
    await seedPrinterFixture();

    const firstClaim = await callPos("claimDevicePrintJob", printerRequest(
      "printer-a", printerCredentialA,
    ));
    const repeatedClaim = await callPos("claimDevicePrintJob", printerRequest(
      "printer-a", printerCredentialA,
    ));
    const otherClaim = await callPos("claimDevicePrintJob", printerRequest(
      "printer-b", printerCredentialB,
    ));
    assert.equal(firstClaim.status, 200, JSON.stringify(firstClaim.body));
    assert.equal(repeatedClaim.status, 200, JSON.stringify(repeatedClaim.body));
    assert.equal(otherClaim.status, 200, JSON.stringify(otherClaim.body));
    assert.equal(firstClaim.body.data.job.id, "print-primary");
    assert.equal(repeatedClaim.body.data.job.id, "print-primary");
    assert.equal(repeatedClaim.body.data.job.attempts, 1);
    assert.equal(otherClaim.body.data.job.id, "print-secondary");

    const invalidCredential = await callPos("claimDevicePrintJob", printerRequest(
      "printer-a", "wrong-printer-credential",
    ));
    assert.equal(invalidCredential.status, 403);

    const completion = {
      ...printerRequest("printer-a", printerCredentialA),
      jobId: "print-primary",
      printed: true,
    };
    const completed = await callPos("completeDevicePrintJob", completion);
    const repeatedCompletion = await callPos("completeDevicePrintJob", completion);
    assert.equal(completed.status, 200, JSON.stringify(completed.body));
    assert.equal(repeatedCompletion.status, 200, JSON.stringify(repeatedCompletion.body));

    const noMoreWork = await callPos("claimDevicePrintJob", printerRequest(
      "printer-a", printerCredentialA,
    ));
    assert.equal(noMoreWork.status, 200, JSON.stringify(noMoreWork.body));
    assert.equal(noMoreWork.body.data.job, null);

    await environment.withSecurityRulesDisabled(async (context) => {
      const job = await getDoc(doc(
        context.firestore(),
        "tenants/tenant-a/printJobs/print-primary",
      ));
      assert.equal(job.data().status, "printed");
      assert.equal(job.data().attempts, 1);
      assert.equal(job.data().claimedByDeviceId, "printer-a");
    });
  });

  test("third failure creates one fallback that clears the primary alarm after printing", async () => {
    await seedPrinterFixture({primaryStatus: "claimed", primaryAttempts: 3});
    const failure = {
      ...printerRequest("printer-a", printerCredentialA),
      jobId: "print-primary",
      printed: false,
      failureReason: "Printer is unavailable",
    };
    const failed = await callPos("completeDevicePrintJob", failure);
    const repeatedFailure = await callPos("completeDevicePrintJob", failure);
    assert.equal(failed.status, 200, JSON.stringify(failed.body));
    assert.equal(repeatedFailure.status, 200, JSON.stringify(repeatedFailure.body));

    const fallback = await readDocument(
      "tenants/tenant-a/printJobs/print-primary_fallback",
    );
    assert.equal(fallback.status, "queued");
    assert.equal(fallback.targetDeviceId, "printer-b");
    assert.equal(fallback.fallbackFromJobId, "print-primary");

    // The fallback device already has an older queued ticket, which must keep
    // FIFO priority. Completing it should expose the fallback next without
    // losing or jumping either job.
    const earlierClaim = await callPos("claimDevicePrintJob", printerRequest(
      "printer-b", printerCredentialB,
    ));
    assert.equal(earlierClaim.status, 200, JSON.stringify(earlierClaim.body));
    assert.equal(earlierClaim.body.data.job.id, "print-secondary");
    const earlierCompleted = await callPos("completeDevicePrintJob", {
      ...printerRequest("printer-b", printerCredentialB),
      jobId: "print-secondary",
      printed: true,
    });
    assert.equal(earlierCompleted.status, 200, JSON.stringify(earlierCompleted.body));

    const claim = await callPos("claimDevicePrintJob", printerRequest(
      "printer-b", printerCredentialB,
    ));
    assert.equal(claim.status, 200, JSON.stringify(claim.body));
    assert.equal(claim.body.data.job.id, "print-primary_fallback");
    const completed = await callPos("completeDevicePrintJob", {
      ...printerRequest("printer-b", printerCredentialB),
      jobId: "print-primary_fallback",
      printed: true,
    });
    assert.equal(completed.status, 200, JSON.stringify(completed.body));

    const primary = await readDocument(
      "tenants/tenant-a/printJobs/print-primary",
    );
    assert.equal(primary.status, "failed");
    assert.equal(primary.fallbackDeliveryStatus, "printed");
  });

  test("manager recovery protects active claims and bounds historical reprints", async () => {
    await seedPrinterFixture({includeQueueJobs: false});
    const now = Date.now();
    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      await Promise.all([
        setDoc(doc(firestore, "tenants/tenant-a/printJobs/active-claim"), {
          ...printJob("printer-a", "claimed", now),
          claimedByDeviceId: "printer-a",
          claimedAt: Timestamp.fromMillis(now),
        }),
        setDoc(doc(firestore, "tenants/tenant-a/printJobs/stale-claim"), {
          ...printJob("printer-a", "claimed", now - 10 * 60 * 1000),
          claimedByDeviceId: "printer-a",
          claimedAt: Timestamp.fromMillis(now - 10 * 60 * 1000),
        }),
        setDoc(doc(firestore, "tenants/tenant-a/printJobs/recent-print"), {
          ...printJob("printer-a", "printed", now - 60 * 60 * 1000),
          completedAt: Timestamp.fromMillis(now - 60 * 60 * 1000),
        }),
        setDoc(doc(firestore, "tenants/tenant-a/printJobs/expired-print"), {
          ...printJob("printer-a", "printed", now - 6 * 24 * 60 * 60 * 1000),
          completedAt: Timestamp.fromMillis(now - 6 * 24 * 60 * 60 * 1000),
        }),
      ]);
    });

    const activeClear = await callPos("cancelPrintJob", {
      ...managerSession(), tenantId: "tenant-a", venueId: "venue-a",
      jobId: "active-claim", reason: "Testing active claim protection",
    });
    assert.equal(activeClear.status, 412);
    const staleClear = await callPos("cancelPrintJob", {
      ...managerSession(), tenantId: "tenant-a", venueId: "venue-a",
      jobId: "stale-claim", reason: "Printer lost power during testing",
    });
    assert.equal(staleClear.status, 200, JSON.stringify(staleClear.body));

    const waiterReprint = await callPos("reprintPrintedJob", {
      ...waiterSession(), tenantId: "tenant-a", venueId: "venue-a",
      jobId: "recent-print",
    });
    assert.equal(waiterReprint.status, 403);
    const recentReprint = await callPos("reprintPrintedJob", {
      ...managerSession(), tenantId: "tenant-a", venueId: "venue-a",
      jobId: "recent-print",
    });
    assert.equal(recentReprint.status, 200, JSON.stringify(recentReprint.body));
    const expiredReprint = await callPos("reprintPrintedJob", {
      ...managerSession(), tenantId: "tenant-a", venueId: "venue-a",
      jobId: "expired-print",
    });
    assert.equal(expiredReprint.status, 412);

    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      const [active, stale, original, reprint] = await Promise.all([
        getDoc(doc(firestore, "tenants/tenant-a/printJobs/active-claim")),
        getDoc(doc(firestore, "tenants/tenant-a/printJobs/stale-claim")),
        getDoc(doc(firestore, "tenants/tenant-a/printJobs/recent-print")),
        getDoc(doc(
          firestore,
          `tenants/tenant-a/printJobs/${recentReprint.body.data.jobId}`,
        )),
      ]);
      assert.equal(active.data().status, "claimed");
      assert.equal(stale.data().status, "cancelled");
      assert.equal(original.data().status, "printed");
      assert.equal(reprint.data().status, "queued");
      assert.equal(reprint.data().payload.isReprint, true);
      assert.equal(reprint.data().reprintOfJobId, "recent-print");
    });
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
        timeZone: "Europe/London",
        businessDayCutoffMinutes: 240,
        offlineHub: {
          enabled: true,
          deviceId: hubDeviceId,
          credentialId: hubCredentialId,
          epoch: hubEpoch,
        },
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
      [`tenants/tenant-a/offlineDeviceCredentials/${hubCredentialId}`]: {
        active: true,
        venueId: "venue-a",
        deviceId: hubDeviceId,
        algorithm: "Ed25519",
        publicKeyBase64: hubPublicKeyBase64,
      },
      "tenants/tenant-a/products/stock-curry": {
        venueId: "venue-a",
        name: "Curry Portion",
        trackStock: true,
        stockOnHand: 20,
        stockUnit: "portion",
      },
      "tenants/tenant-a/tables/table-a": {
        venueId: "venue-a",
        label: "Table 1",
        currentOrderId: "order-cloud-a",
        hasOpenOrder: true,
      },
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
  const salt = `test-salt-${userId}`;
  return {
    userId,
    venueId: "venue-a",
    locked: false,
    failedAttempts: 0,
    pinVersion: 1,
    salt,
    pinHash: scryptSync("123456", salt, 32).toString("base64"),
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

function hubEvent(sequence, id, previousHash, eventHash, type, payload, createdAtUtc) {
  return {
    id,
    sequence,
    tenantId: "tenant-a",
    venueId: "venue-a",
    hubEpoch,
    previousHash,
    eventHash,
    type,
    payload,
    staffId: identities.manager.localId,
    deviceId: hubDeviceId,
    createdAtUtc,
  };
}

function signedHubUpload(events, nonce) {
  const body = {events};
  const bodyHash = createHash("sha256")
    .update(JSON.stringify(canonicalJsonValue(body)))
    .digest("base64url");
  const envelope = {
    tenantId: "tenant-a",
    venueId: "venue-a",
    credentialId: hubCredentialId,
    deviceId: hubDeviceId,
    staffId: identities.manager.localId,
    method: "POST",
    path: "/v1/cloud-sync",
    hubEpoch,
    sentAtUtcMillis: Date.now(),
    nonce,
    bodyHash,
  };
  const canonicalHeaders = [
    "v1",
    envelope.credentialId,
    envelope.tenantId,
    envelope.venueId,
    envelope.deviceId,
    envelope.staffId,
    envelope.method,
    envelope.path,
    envelope.hubEpoch,
    envelope.sentAtUtcMillis,
    envelope.nonce,
    envelope.bodyHash,
  ].join("\n");
  envelope.signature = signMessage(
    null,
    Buffer.from(canonicalHeaders, "utf8"),
    hubKeys.privateKey,
  ).toString("base64url");
  return {envelope, body};
}

function canonicalJsonValue(value) {
  if (Array.isArray(value)) return value.map(canonicalJsonValue);
  if (value != null && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [
      key,
      canonicalJsonValue(value[key]),
    ]));
  }
  return value;
}

async function assertCloudSaleProjection() {
  await environment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    const [order, bill, product, movement, ticket, table] = await Promise.all([
      getDoc(doc(firestore, "tenants/tenant-a/orders/order-cloud-a")),
      getDoc(doc(firestore, "tenants/tenant-a/bills/offline-order-cloud-a")),
      getDoc(doc(firestore, "tenants/tenant-a/products/stock-curry")),
      getDoc(doc(
        firestore,
        "tenants/tenant-a/stockMovements/offline_event-sent_stock-curry",
      )),
      getDoc(doc(
        firestore,
        "tenants/tenant-a/productionTickets/offline_event-sent_kitchen",
      )),
      getDoc(doc(firestore, "tenants/tenant-a/tables/table-a")),
    ]);
    assert.equal(order.data().status, "closed");
    assert.equal(order.data().lines.length, 1);
    assert.equal(order.data().payments.length, 1);
    assert.equal(order.data().payments[0].cashChangeBaseMinor, 500);
    assert.equal(bill.data().receiptNumber, "R-CLOUD-1");
    assert.equal(bill.data().grossTotalMinor, 1500);
    assert.equal(bill.data().payments.length, 1);
    assert.equal(product.data().stockOnHand, 18);
    assert.equal(movement.data().quantity, -2);
    assert.equal(ticket.data().orderId, "order-cloud-a");
    assert.equal(ticket.data().productionItems[0].name, "House Curry");
    assert.equal(table.data().hasOpenOrder, false);
    assert.equal(table.data().currentOrderId, null);
  });
}

async function seedFinancialOrder(orderId) {
  await environment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    await Promise.all([
      setDoc(doc(firestore, `tenants/tenant-a/orders/${orderId}`), {
        venueId: "venue-a",
        tableId: "table-a",
        tableLabel: "Table 1",
        channel: "dineIn",
        status: "sent",
        openedAt: Timestamp.now(),
        payments: [],
        openSplitOrderIds: [],
        lines: [
          {
            id: "line-food",
            productId: "stock-curry",
            productName: "House Curry",
            quantity: 2,
            unitPriceMinor: 1000,
            taxRateId: "tax-standard",
            taxRateName: "Standard 20%",
            taxRateBasisPoints: 2000,
            productionArea: "kitchen",
            isSentToProduction: true,
          },
          {
            id: "line-drink",
            productId: "drink-a",
            productName: "Soft Drink",
            quantity: 1,
            unitPriceMinor: 1000,
            taxRateId: "tax-reduced",
            taxRateName: "Reduced 10%",
            taxRateBasisPoints: 1000,
            productionArea: "bar",
            isSentToProduction: true,
          },
        ],
      }),
      setDoc(doc(firestore, "tenants/tenant-a/tables/table-a"), {
        venueId: "venue-a",
        label: "Table 1",
        currentOrderId: orderId,
        hasOpenOrder: true,
      }),
      setDoc(doc(firestore, "tenants/tenant-a/products/stock-curry"), {
        venueId: "venue-a",
        name: "Curry Portion",
        trackStock: true,
        stockOnHand: 18,
        stockUnit: "portion",
      }),
      setDoc(doc(firestore, "tenants/tenant-a/products/drink-a"), {
        venueId: "venue-a",
        name: "Soft Drink",
        trackStock: false,
        stockOnHand: null,
        stockUnit: "each",
      }),
    ]);
  });
}

async function seedPrinterFixture({
  primaryStatus = "queued",
  primaryAttempts = 0,
  includeQueueJobs = true,
} = {}) {
  await environment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    const writes = [
      setDoc(doc(firestore, "tenants/tenant-a/devices/printer-a"), {
        venueId: "venue-a",
        name: "Kitchen printer",
        active: true,
        platform: "windows",
        productionAreas: ["kitchen", "receipt"],
        credentialHash: createHash("sha256")
          .update(printerCredentialA).digest("base64"),
      }),
      setDoc(doc(firestore, "tenants/tenant-a/devices/printer-b"), {
        venueId: "venue-a",
        name: "Fallback printer",
        active: true,
        platform: "windows",
        productionAreas: ["kitchen", "receipt"],
        credentialHash: createHash("sha256")
          .update(printerCredentialB).digest("base64"),
      }),
    ];
    if (includeQueueJobs) {
      writes.push(
        setDoc(doc(firestore, "tenants/tenant-a/printJobs/print-primary"), {
          ...printJob("printer-a", primaryStatus, Date.now()),
          attempts: primaryAttempts,
          fallbackDeviceId: "printer-b",
          ...(primaryStatus === "claimed" ? {
            claimedByDeviceId: "printer-a",
            claimedAt: Timestamp.now(),
          } : {}),
        }),
        setDoc(doc(firestore, "tenants/tenant-a/printJobs/print-secondary"),
          printJob("printer-b", "queued", Date.now() + 1)),
      );
    }
    await Promise.all(writes);
  });
}

function printJob(targetDeviceId, status, createdAtMillis) {
  return {
    venueId: "venue-a",
    targetDeviceId,
    fallbackDeviceId: null,
    orderId: "order-print-test",
    ticketId: "ticket-print-test",
    productionArea: "kitchen",
    status,
    attempts: 0,
    idempotencyKey: `print-${targetDeviceId}-${createdAtMillis}`,
    payload: {type: "production", lines: [{name: "Test meal", quantity: 1}]},
    createdAt: Timestamp.fromMillis(createdAtMillis),
  };
}

function printerRequest(printerDeviceId, deviceCredential) {
  return {
    tenantId: "tenant-a",
    venueId: "venue-a",
    deviceId: printerDeviceId,
    deviceCredential,
  };
}

async function readDocument(documentPath) {
  let value;
  await environment.withSecurityRulesDisabled(async (context) => {
    const snapshot = await getDoc(doc(context.firestore(), documentPath));
    assert.equal(snapshot.exists(), true, `${documentPath} was not created.`);
    value = snapshot.data();
  });
  return value;
}

function orderLinesTotal(lines) {
  return lines.reduce((total, line) =>
    total + Number(line.quantity) * Number(line.unitPriceMinor), 0);
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
