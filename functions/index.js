import {randomBytes} from "node:crypto";
import {getApps, initializeApp} from "firebase-admin/app";
import {getAppCheck} from "firebase-admin/app-check";
import {getAuth} from "firebase-admin/auth";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import {HttpsError, onCall, onRequest} from "firebase-functions/v2/https";
import {defineBoolean, defineString} from "firebase-functions/params";
import {setGlobalOptions} from "firebase-functions/v2";

if (getApps().length === 0) {
  initializeApp();
}

const auth = getAuth();
const appCheck = getAppCheck();
const db = getFirestore();
const region = "europe-west2";
const initialPlatformAdminEmail = defineString("INITIAL_PLATFORM_ADMIN_EMAIL");
// Monitor first: old Windows/web clients must not be locked out while their
// attestation provider is being registered and verified.
const requireAppCheck = defineBoolean("REQUIRE_APP_CHECK", {default: false});
const supportedTimeZones = Object.freeze(Intl.supportedValuesOf("timeZone"));
const supportedTimeZoneSet = new Set(supportedTimeZones);
const supportedCurrencyCodes = Object.freeze(Intl.supportedValuesOf("currency"));
const supportedCurrencyCodeSet = new Set(supportedCurrencyCodes);
// CBRT is the official Central Bank of the Republic of Türkiye source. It
// publishes a daily XML bulletin without an API key. Its ForexBuying rate is
// an indicative starting point when a venue receives foreign physical cash;
// a manager must still review or override it at checkout.
const cbrtDailyRatesUrl = "https://www.tcmb.gov.tr/kurlar/today.xml";
const cbrtRateCacheTtlMs = 15 * 60 * 1000;
let cbrtRateCache = null;

setGlobalOptions({region, maxInstances: 10});

function callerFromCall(request) {
  if (request.auth == null) {
    throw new HttpsError("unauthenticated", "Sign in before calling this action.");
  }
  return request.auth;
}

async function isPlatformAdmin(caller) {
  if (caller.token.platformAdmin === true) return true;
  // The record is written only by this trusted Admin SDK code.  It is a safe
  // fallback when a native client has not yet received a refreshed custom
  // claim token.
  const record = await db.doc(`platformAdmins/${caller.uid}`).get();
  return record.exists;
}

async function requirePlatformAdmin(caller) {
  if (!(await isPlatformAdmin(caller))) {
    throw new HttpsError(
      "permission-denied",
      "This action is restricted to TableSide platform administrators.",
    );
  }
  return caller;
}

async function requireTenantOperationalMember(caller, tenantId) {
  const membership = await db.doc(`tenants/${tenantId}/members/${caller.uid}`).get();
  if (!membership.exists || membership.data().active === false) {
    throw new HttpsError(
      "permission-denied",
      "You do not have active access to this restaurant.",
    );
  }
  const roles = Array.isArray(membership.data().roles) ? membership.data().roles : [];
  if (!roles.some((role) => ["owner", "manager", "waiter", "cashier"].includes(role))) {
    throw new HttpsError(
      "permission-denied",
      "Your role cannot send orders to production.",
    );
  }
  return {membership: membership.data(), roles};
}

function requireObject(value) {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "A data object is required.");
  }
  return value;
}

function requiredText(data, name, maxLength = 160) {
  const value = data[name];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  const text = value.trim();
  if (text.length > maxLength) {
    throw new HttpsError("invalid-argument", `${name} is too long.`);
  }
  return text;
}

function optionalText(data, name, maxLength = 500) {
  const value = data[name];
  if (value == null) return "";
  if (typeof value !== "string" || value.trim().length > maxLength) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return value.trim();
}

function requiredPositiveInteger(value, name, maximum = 1000) {
  if (!Number.isInteger(value) || value <= 0 || value > maximum) {
    throw new HttpsError("invalid-argument", `${name} must be a positive whole number.`);
  }
  return value;
}

function validProductionLine(value, index) {
  const data = requireObject(value);
  return {
    id: requiredText(data, "id", 180),
    productId: requiredText(data, "productId", 180),
    quantity: requiredPositiveInteger(data.quantity, `lines[${index}].quantity`, 100),
  };
}

function requiredNonNegativeInteger(value, label, maximum = 100000000) {
  if (!Number.isInteger(value) || value < 0 || value > maximum) {
    throw new HttpsError(
      "invalid-argument",
      `${label} must be a whole number from 0 to ${maximum}.`,
    );
  }
  return value;
}

function validRoles(value) {
  const supported = new Set([
    "owner", "manager", "waiter", "cashier", "kitchen", "printer",
  ]);
  if (!Array.isArray(value) || value.length === 0) {
    throw new HttpsError("invalid-argument", "At least one role is required.");
  }
  const roles = [...new Set(value)];
  if (roles.some((role) => typeof role !== "string" || !supported.has(role))) {
    throw new HttpsError("invalid-argument", "One or more roles are invalid.");
  }
  return roles;
}

function validCurrencyCode(data) {
  const currencyCode = (optionalText(data, "currencyCode", 3) || "GBP").toUpperCase();
  if (!supportedCurrencyCodeSet.has(currencyCode)) {
    throw new HttpsError(
      "invalid-argument",
      "currencyCode must be selected from the supported ISO currency list.",
    );
  }
  return currencyCode;
}

function xmlElementText(xml, tagName) {
  const match = new RegExp(
    `<${tagName}\\b[^>]*>\\s*([^<]*?)\\s*</${tagName}>`,
    "i",
  ).exec(xml);
  return match == null ? "" : match[1].trim();
}

function decimalTextToScaled(value, label) {
  const text = String(value).trim();
  if (!/^\d+(?:\.\d+)?$/.test(text)) {
    throw new HttpsError("unavailable", `${label} was not present in the official rate feed.`);
  }
  const [whole, rawFraction = ""] = text.split(".");
  let scaled = (BigInt(whole) * 1000000n) +
    BigInt(rawFraction.slice(0, 6).padEnd(6, "0"));
  // The POS rate has six decimal places. Round the published value once if
  // CBRT adds additional precision in a future bulletin.
  if (rawFraction.length > 6 && Number(rawFraction.charAt(6)) >= 5) scaled += 1n;
  if (scaled <= 0n) {
    throw new HttpsError("unavailable", `${label} was not a positive official rate.`);
  }
  return scaled;
}

function formatScaledExchangeRate(scaled) {
  const whole = scaled / 1000000n;
  const fraction = (scaled % 1000000n).toString().padStart(6, "0").replace(/0+$/, "");
  return fraction.length === 0 ? whole.toString() : `${whole}.${fraction}`;
}

function parseCbrtDailyRates(xml) {
  const publicationDate = /<Tarih_Date\b[^>]*\bDate\s*=\s*["']([^"']+)["']/i
    .exec(xml)?.[1]
    ?.trim();
  if (publicationDate == null || publicationDate.length === 0) {
    throw new HttpsError("unavailable", "The official rate feed did not include its publication date.");
  }

  const tryPerCurrency = new Map([["TRY", 1000000n]]);
  const currencyMatcher = /<Currency\b([^>]*)>([\s\S]*?)<\/Currency>/gi;
  for (const match of xml.matchAll(currencyMatcher)) {
    const currencyCode = /\bCurrencyCode\s*=\s*["']([^"']+)["']/i
      .exec(match[1])?.[1]
      ?.trim()
      .toUpperCase();
    if (currencyCode == null || !/^[A-Z]{3}$/.test(currencyCode)) continue;
    const unitText = xmlElementText(match[2], "Unit");
    const forexBuyingText = xmlElementText(match[2], "ForexBuying");
    if (!/^\d+$/.test(unitText) || forexBuyingText.length === 0) continue;
    const unit = BigInt(unitText);
    if (unit <= 0n) continue;
    const quotedTryScaled = decimalTextToScaled(
      forexBuyingText,
      `The official ${currencyCode} ForexBuying value`,
    );
    // The CBRT bulletin may quote (for example) 100 JPY. Store every entry
    // as Turkish lira for one major unit of its currency.
    tryPerCurrency.set(
      currencyCode,
      (quotedTryScaled + (unit / 2n)) / unit,
    );
  }
  return {publicationDate, tryPerCurrency};
}

async function currentCbrtDailyRates() {
  const now = Date.now();
  if (cbrtRateCache != null && cbrtRateCache.expiresAt > now) {
    return cbrtRateCache.feed;
  }
  let response;
  try {
    response = await fetch(cbrtDailyRatesUrl, {
      headers: {accept: "application/xml,text/xml;q=0.9,*/*;q=0.1"},
      signal: AbortSignal.timeout(10000),
    });
  } catch (error) {
    console.warn("Could not download the CBRT daily rate feed.", error);
    throw new HttpsError(
      "unavailable",
      "The official exchange-rate service is unavailable. Enter a manager rate manually.",
    );
  }
  if (!response.ok) {
    console.warn(`CBRT daily rate feed returned HTTP ${response.status}.`);
    throw new HttpsError(
      "unavailable",
      "The official exchange-rate service is unavailable. Enter a manager rate manually.",
    );
  }
  const xml = await response.text();
  if (xml.length === 0 || xml.length > 1024 * 1024) {
    throw new HttpsError(
      "unavailable",
      "The official exchange-rate response was invalid. Enter a manager rate manually.",
    );
  }
  const feed = parseCbrtDailyRates(xml);
  cbrtRateCache = {feed, expiresAt: now + cbrtRateCacheTtlMs};
  return feed;
}

async function lookupExchangeRateFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tenderCurrencyCode = requiredText(data, "tenderCurrencyCode", 3).toUpperCase();
  if (!supportedCurrencyCodeSet.has(tenderCurrencyCode)) {
    throw new HttpsError("invalid-argument", "tenderCurrencyCode must be a supported ISO currency code.");
  }
  await requireTenantOperationalMember(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const [tenant, venue] = await Promise.all([tenantRef.get(), venueRef.get()]);
  if (!tenant.exists) throw new HttpsError("not-found", "The restaurant was not found.");
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const baseCurrencyCode = String(tenant.data().currencyCode ?? "GBP").toUpperCase();
  if (!supportedCurrencyCodeSet.has(baseCurrencyCode)) {
    throw new HttpsError("failed-precondition", "The restaurant has an invalid reporting currency.");
  }
  const fetchedAt = new Date().toISOString();
  if (tenderCurrencyCode === baseCurrencyCode) {
    return {
      tenderCurrencyCode,
      baseCurrencyCode,
      exchangeRateToBase: "1",
      source: "No conversion required",
      publishedDate: null,
      fetchedAt,
    };
  }

  const feed = await currentCbrtDailyRates();
  const tenderTryScaled = feed.tryPerCurrency.get(tenderCurrencyCode);
  const baseTryScaled = feed.tryPerCurrency.get(baseCurrencyCode);
  if (tenderTryScaled == null || baseTryScaled == null) {
    throw new HttpsError(
      "unavailable",
      `The official CBRT daily bulletin does not provide a ${tenderCurrencyCode}/${baseCurrencyCode} rate. Enter a manager rate manually.`,
    );
  }
  // one tender-currency major unit = X base-currency major units
  const exchangeRateScaled = ((tenderTryScaled * 1000000n) +
    (baseTryScaled / 2n)) / baseTryScaled;
  if (exchangeRateScaled <= 0n) {
    throw new HttpsError("unavailable", "The official rate calculation was invalid. Enter a manager rate manually.");
  }
  console.info(
    `Official CBRT rate loaded for ${tenantId}/${venueId}: ${tenderCurrencyCode}/${baseCurrencyCode}.`,
  );
  return {
    tenderCurrencyCode,
    baseCurrencyCode,
    exchangeRateToBase: formatScaledExchangeRate(exchangeRateScaled),
    source: "CBRT daily indicative rate (Forex buying)",
    publishedDate: feed.publicationDate,
    fetchedAt,
  };
}

function validTimeZone(data) {
  const timeZone = optionalText(data, "timeZone", 80) || "Europe/London";
  if (!supportedTimeZoneSet.has(timeZone)) {
    throw new HttpsError(
      "invalid-argument",
      "timeZone must be selected from the supported IANA time-zone list.",
    );
  }
  return timeZone;
}

function venueNameKey(name) {
  return name
    .normalize("NFKC")
    .replace(/\s+/g, " ")
    .trim()
    .toLocaleLowerCase("en-GB");
}

function throwIfVenueNameExists(venues, nameKey, ignoredVenueId = null) {
  const duplicate = venues.docs.find((document) => {
    const storedName = document.data().name;
    return document.id !== ignoredVenueId
      && typeof storedName === "string"
      && venueNameKey(storedName) === nameKey;
  });
  if (duplicate != null) {
    throw new HttpsError(
      "already-exists",
      "A venue with that name already exists in this restaurant.",
    );
  }
}

function actorSnapshot(user) {
  // Retain a minimal immutable attribution record on business data. The Auth
  // user may later be retired, but this UID/name pair remains meaningful.
  return {
    uid: user.uid,
    displayName: user.displayName ?? "",
  };
}

async function createOrUpdateStaffProfile(user, actorUid, status = "active") {
  const profileRef = db.doc(`staffProfiles/${user.uid}`);
  const existing = await profileRef.get();
  const updates = {
    uid: user.uid,
    displayName: user.displayName ?? "",
    email: user.email ?? "",
    status,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  };
  if (!existing.exists) {
    updates.createdAt = FieldValue.serverTimestamp();
    updates.createdBy = actorUid;
  }
  await profileRef.set(updates, {merge: true});
}

async function revokeMembershipsFor(userUid, actorUid) {
  const memberships = await db.collectionGroup("members")
    .where("userId", "==", userUid)
    .get();

  // A Firestore batch may contain at most 500 writes. Chunks keep retirement
  // safe even if a staff member is assigned to many restaurant companies.
  const documents = memberships.docs;
  for (let start = 0; start < documents.length; start += 450) {
    const batch = db.batch();
    for (const document of documents.slice(start, start + 450)) {
      batch.set(document.ref, {
        active: false,
        retiredAt: FieldValue.serverTimestamp(),
        retiredBy: actorUid,
      }, {merge: true});
    }
    await batch.commit();
  }
  return documents.length;
}

async function writeAudit(callerUid, action, target, details = {}) {
  await db.collection("platformAdminAudit").add({
    callerUid,
    action,
    target,
    details,
    createdAt: FieldValue.serverTimestamp(),
  });
}

async function bootstrapPlatformAdminFor(caller) {
  const configuredEmail = initialPlatformAdminEmail.value().trim().toLowerCase();
  const callerEmail = typeof caller.token.email === "string"
    ? caller.token.email.toLowerCase()
    : "";

  if (configuredEmail.length === 0 || callerEmail !== configuredEmail) {
    throw new HttpsError("permission-denied", "This account cannot bootstrap the platform.");
  }

  const existingAdmins = await db.collection("platformAdmins").limit(1).get();
  if (!existingAdmins.empty && !existingAdmins.docs.some((item) => item.id === caller.uid)) {
    throw new HttpsError("failed-precondition", "A platform administrator already exists.");
  }

  const user = await auth.getUser(caller.uid);
  await auth.setCustomUserClaims(caller.uid, {
    ...(user.customClaims ?? {}),
    platformAdmin: true,
  });
  await db.doc(`platformAdmins/${caller.uid}`).set({
    email: user.email ?? callerEmail,
    createdAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  await createOrUpdateStaffProfile(user, caller.uid);
  await writeAudit(caller.uid, "bootstrapPlatformAdmin", caller.uid);
  return {claimUpdated: true};
}

async function listAuthUsersFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const pageToken = optionalText(data, "pageToken", 2000) || undefined;
  const page = await auth.listUsers(100, pageToken);
  return {
    users: page.users.map((user) => ({
      uid: user.uid,
      email: user.email ?? "",
      displayName: user.displayName ?? "",
      disabled: user.disabled,
      platformAdmin: user.customClaims?.platformAdmin === true,
    })),
    nextPageToken: page.pageToken ?? null,
  };
}

async function listTenantsFor(caller) {
  await requirePlatformAdmin(caller);
  const snapshot = await db.collection("tenants").orderBy("displayName").limit(200).get();
  return {
    tenants: snapshot.docs.map((document) => ({
      id: document.id,
      displayName: document.data().displayName ?? "Unnamed restaurant",
      legalName: document.data().legalName ?? "",
      currencyCode: document.data().currencyCode ?? "GBP",
    })),
  };
}

async function listSupportedTimeZonesFor(caller) {
  await requirePlatformAdmin(caller);
  return {timeZones: supportedTimeZones};
}

async function listSupportedCurrenciesFor(caller) {
  await requirePlatformAdmin(caller);
  return {currencyCodes: supportedCurrencyCodes};
}

async function listTenantVenuesFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tenant = await tenantRef.get();
  if (!tenant.exists) {
    throw new HttpsError("not-found", "The restaurant was not found.");
  }
  const snapshot = await tenantRef.collection("venues").orderBy("name").limit(200).get();
  return {
    venues: snapshot.docs.map((document) => ({
      id: document.id,
      name: document.data().name ?? "Unnamed venue",
      timeZone: document.data().timeZone ?? "Europe/London",
    })),
  };
}

async function listUserMembershipsFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const userUid = requiredText(data, "userUid", 128);
  const snapshot = await db.collectionGroup("members")
    .where("userId", "==", userUid)
    .get();
  return {
    memberships: snapshot.docs
      .filter((document) => document.data().active !== false)
      .map((document) => ({
        tenantId: document.ref.parent.parent.id,
        roles: Array.isArray(document.data().roles) ? document.data().roles : [],
        defaultVenueId: document.data().defaultVenueId ?? null,
      })),
  };
}

async function createTenantFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const displayName = requiredText(data, "displayName");
  const legalName = optionalText(data, "legalName");
  const currencyCode = validCurrencyCode(data);
  const venueName = requiredText(data, "venueName");
  const timeZone = validTimeZone(data);
  const ownerUid = requiredText(data, "ownerUid", 128);
  const [owner, creator] = await Promise.all([
    auth.getUser(ownerUid),
    auth.getUser(caller.uid),
  ]);
  if (owner.disabled) {
    throw new HttpsError("failed-precondition", "A retired user cannot own a restaurant.");
  }
  const creatorSnapshot = actorSnapshot(creator);
  const tenantRef = db.collection("tenants").doc();
  const venueRef = tenantRef.collection("venues").doc();
  const memberRef = tenantRef.collection("members").doc(ownerUid);

  await db.runTransaction(async (transaction) => {
    transaction.create(tenantRef, {
      displayName,
      legalName,
      currencyCode,
      createdAt: FieldValue.serverTimestamp(),
      createdBy: caller.uid,
      createdByActor: creatorSnapshot,
    });
    transaction.create(venueRef, {
      name: venueName,
      nameKey: venueNameKey(venueName),
      timeZone,
      notificationRetentionSeconds: 5,
      status: "active",
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(memberRef, {
      userId: owner.uid,
      roles: ["owner"],
      defaultVenueId: venueRef.id,
      email: owner.email ?? "",
      active: true,
      createdAt: FieldValue.serverTimestamp(),
      createdBy: caller.uid,
      createdByActor: creatorSnapshot,
    });
  });

  await createOrUpdateStaffProfile(owner, caller.uid);

  await writeAudit(caller.uid, "createTenant", tenantRef.id, {ownerUid, venueId: venueRef.id});
  return {tenantId: tenantRef.id, venueId: venueRef.id};
}

async function updateTenantFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const displayName = requiredText(data, "displayName");
  const legalName = optionalText(data, "legalName");
  const currencyCode = validCurrencyCode(data);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tenant = await tenantRef.get();
  if (!tenant.exists) {
    throw new HttpsError("not-found", "The restaurant was not found.");
  }
  const currentCurrencyCode = String(tenant.data().currencyCode ?? "GBP").toUpperCase();
  if (currencyCode !== currentCurrencyCode) {
    // Currency is picked while creating a restaurant and then immutable. A
    // price is stored as a bare integer in the currency's minor units, so an
    // apparently harmless later change can reinterpret money created during
    // a concurrent menu edit. A new restaurant is the safe migration path.
    throw new HttpsError(
      "failed-precondition",
      "The functional currency is permanent once a restaurant is created. Create a new restaurant company for a different trading currency; existing amounts are never converted automatically.",
    );
  }
  await tenantRef.set({
    displayName,
    legalName,
    currencyCode,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: caller.uid,
  }, {merge: true});
  await writeAudit(caller.uid, "updateTenant", tenantId);
  return {updated: true};
}

async function createVenueFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const name = requiredText(data, "name");
  const nameKey = venueNameKey(name);
  const timeZone = validTimeZone(data);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc();
  await db.runTransaction(async (transaction) => {
    const [tenant, venues] = await Promise.all([
      transaction.get(tenantRef),
      transaction.get(tenantRef.collection("venues")),
    ]);
    if (!tenant.exists) {
      throw new HttpsError("not-found", "The restaurant was not found.");
    }
    throwIfVenueNameExists(venues, nameKey);
    transaction.create(venueRef, {
      name,
      nameKey,
      timeZone,
      notificationRetentionSeconds: 5,
      status: "active",
      createdAt: FieldValue.serverTimestamp(),
      createdBy: caller.uid,
    });
  });
  await writeAudit(caller.uid, "createVenue", venueRef.id, {tenantId});
  return {id: venueRef.id, name, timeZone};
}

async function updateVenueFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const name = requiredText(data, "name");
  const nameKey = venueNameKey(name);
  const timeZone = validTimeZone(data);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = db.doc(`tenants/${tenantId}/venues/${venueId}`);
  await db.runTransaction(async (transaction) => {
    const [venue, venues] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(tenantRef.collection("venues")),
    ]);
    if (!venue.exists) {
      throw new HttpsError("not-found", "The venue was not found.");
    }
    if (venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "This venue is currently being deleted.");
    }
    throwIfVenueNameExists(venues, nameKey, venueId);
    transaction.set(venueRef, {
      name,
      nameKey,
      timeZone,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: caller.uid,
    }, {merge: true});
  });
  await writeAudit(caller.uid, "updateVenue", venueId, {tenantId});
  return {id: venueId, name, timeZone};
}

// Any future tenant-root collection that stores a venueId must be added here
// before it is deployed, so deleting a venue never leaves orphaned records.
const venueDependencyCollections = Object.freeze([
  "tables",
  "orders",
  "productionTickets",
  "stockMovements",
  "bills",
  "paymentRequests",
  "devices",
  "printJobs",
]);

async function clearDefaultVenuePointers(memberships) {
  const documents = memberships.docs;
  for (let start = 0; start < documents.length; start += 450) {
    const batch = db.batch();
    for (const document of documents.slice(start, start + 450)) {
      batch.set(document.ref, {defaultVenueId: FieldValue.delete()}, {merge: true});
    }
    await batch.commit();
  }
  return documents.length;
}

async function deleteVenueFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  // The transaction makes the deletion lock exclusive. The status then makes
  // security rules reject new venue-bound client writes while the dependency
  // check runs, closing the gap between checking and deleting.
  await db.runTransaction(async (transaction) => {
    const venue = await transaction.get(venueRef);
    if (!venue.exists) {
      throw new HttpsError("not-found", "The venue was not found.");
    }
    if (venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "This venue is already being deleted.");
    }
    transaction.set(venueRef, {
      status: "deleting",
      deletionRequestedAt: FieldValue.serverTimestamp(),
      deletionRequestedBy: caller.uid,
    }, {merge: true});
  });

  let deleted = false;
  try {
    const venues = await tenantRef.collection("venues").limit(2).get();
    if (venues.size < 2) {
      throw new HttpsError(
        "failed-precondition",
        "A restaurant must retain at least one venue. Add another venue before deleting this one.",
      );
    }
    const [memberships, ...dependencies] = await Promise.all([
      tenantRef.collection("members")
        .where("defaultVenueId", "==", venueId)
        .get(),
      ...venueDependencyCollections.map(async (collectionName) => ({
        collectionName,
        snapshot: await tenantRef.collection(collectionName)
          .where("venueId", "==", venueId)
          .limit(1)
          .get(),
      })),
    ]);
    const blockers = dependencies
      .filter((dependency) => !dependency.snapshot.empty)
      .map((dependency) => dependency.collectionName);
    if (blockers.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        `The venue cannot be deleted because it still has ${blockers.join(", ")} data.`,
      );
    }

    const clearedDefaultVenuePointers = await clearDefaultVenuePointers(memberships);
    await venueRef.delete();
    deleted = true;
    try {
      await writeAudit(caller.uid, "deleteVenue", venueId, {
        tenantId,
        clearedDefaultVenuePointers,
      });
    } catch (auditError) {
      // The delete has already completed safely. Log a failed audit write
      // without incorrectly telling the caller that the venue still exists.
      console.error("Could not write deleteVenue audit record", auditError);
    }
    return {deleted: true, clearedDefaultVenuePointers};
  } catch (error) {
    if (!deleted) {
      await venueRef.set({
        status: "active",
        deletionRequestedAt: FieldValue.delete(),
        deletionRequestedBy: FieldValue.delete(),
      }, {merge: true});
    }
    throw error;
  }
}

async function createStaffUserFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const email = requiredText(data, "email", 320).toLowerCase();
  const displayName = optionalText(data, "displayName");
  // The person must use the app's reset-password action before their first sign-in.
  const user = await auth.createUser({
    email,
    displayName: displayName || undefined,
    password: randomBytes(32).toString("base64url"),
  });
  await createOrUpdateStaffProfile(user, caller.uid);
  await writeAudit(caller.uid, "createStaffUser", user.uid, {email});
  return {uid: user.uid, email: user.email ?? email};
}

async function assignUserToTenantFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const userUid = requiredText(data, "userUid", 128);
  const roles = validRoles(data.roles);
  const defaultVenueId = optionalText(data, "defaultVenueId", 128) || null;
  const [tenant, user] = await Promise.all([
    db.doc(`tenants/${tenantId}`).get(),
    auth.getUser(userUid),
  ]);
  if (!tenant.exists) {
    throw new HttpsError("not-found", "The restaurant was not found.");
  }
  if (user.disabled) {
    throw new HttpsError("failed-precondition", "A retired user cannot be assigned access.");
  }

  await db.doc(`tenants/${tenantId}/members/${user.uid}`).set({
    userId: user.uid,
    roles,
    defaultVenueId,
    email: user.email ?? "",
    active: true,
    retiredAt: FieldValue.delete(),
    retiredBy: FieldValue.delete(),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: caller.uid,
  }, {merge: true});
  await createOrUpdateStaffProfile(user, caller.uid);
  await writeAudit(caller.uid, "assignUserToTenant", user.uid, {tenantId, roles});
  return {assigned: true};
}

async function retireStaffUserFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const userUid = requiredText(data, "userUid", 128);
  const [user, platformAdmin] = await Promise.all([
    auth.getUser(userUid),
    db.doc(`platformAdmins/${userUid}`).get(),
  ]);

  // The master account remains the recovery route for the whole SaaS. Never
  // permit retirement through either the durable record or custom claim.
  if (platformAdmin.exists || user.customClaims?.platformAdmin === true) {
    throw new HttpsError(
      "failed-precondition",
      "A platform administrator cannot be deleted or retired.",
    );
  }

  const membershipsRevoked = await revokeMembershipsFor(userUid, caller.uid);
  await auth.updateUser(userUid, {disabled: true});
  await auth.revokeRefreshTokens(userUid);
  await createOrUpdateStaffProfile(user, caller.uid, "retired");
  await db.doc(`staffProfiles/${userUid}`).set({
    retiredAt: FieldValue.serverTimestamp(),
    retiredBy: caller.uid,
  }, {merge: true});
  await writeAudit(caller.uid, "retireStaffUser", userUid, {membershipsRevoked});
  return {retired: true, membershipsRevoked};
}

async function setPlatformAdminFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const userUid = requiredText(data, "userUid", 128);
  const enabled = data.enabled === true;
  const user = await auth.getUser(userUid);

  if (!enabled && caller.uid === userUid) {
    const admins = await db.collection("platformAdmins").limit(2).get();
    if (admins.size < 2) {
      throw new HttpsError("failed-precondition", "Keep at least one platform administrator.");
    }
  }

  await auth.setCustomUserClaims(userUid, {
    ...(user.customClaims ?? {}),
    platformAdmin: enabled,
  });
  const ref = db.doc(`platformAdmins/${userUid}`);
  if (enabled) {
    await ref.set({
      email: user.email ?? "",
      grantedBy: caller.uid,
      createdAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    await createOrUpdateStaffProfile(user, caller.uid);
  } else {
    await ref.delete();
  }
  await writeAudit(caller.uid, "setPlatformAdmin", userUid, {enabled});
  return {updated: true};
}

async function requireTenantManager(caller, tenantId) {
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only an owner or manager can change tables.");
  }
  return roles;
}

async function requireTenantOwner(caller, tenantId) {
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.includes("owner")) {
    throw new HttpsError(
      "permission-denied",
      "Only a company owner can change this venue setting.",
    );
  }
  return roles;
}

function tableLabelKey(label) {
  return venueNameKey(label);
}

function tableLabelRegistryRef(tenantId, venueId, labelKey) {
  const encoded = Buffer.from(`${venueId}\u0000${labelKey}`).toString("base64url");
  return db.doc(`tenants/${tenantId}/tableLabels/${encoded}`);
}

function openTabRegistryRef(tenantId, venueId, tabName) {
  const key = venueNameKey(tabName);
  const encoded = Buffer.from(`${venueId}\u0000${key}`).toString("base64url");
  return db.doc(`tenants/${tenantId}/openTabNames/${encoded}`);
}

async function openNamedTabFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tabName = requiredText(data, "tabName", 80);
  await requireTenantOperationalMember(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tabRef = openTabRegistryRef(tenantId, venueId, tabName);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  const result = await db.runTransaction(async (transaction) => {
    const [venue, currentTab] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(tabRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (currentTab.exists) {
      const currentOrderId = currentTab.data().orderId;
      const currentOrder = typeof currentOrderId === "string"
        ? await transaction.get(tenantRef.collection("orders").doc(currentOrderId))
        : null;
      if (currentOrder?.exists
          && currentOrder.data().venueId === venueId
          && currentOrder.data().status !== "closed") {
        return {orderId: currentOrderId, reopened: true};
      }
      // A later bill-close command normally removes this reservation. Clean up
      // a stale one defensively so a missing/closed historic order cannot
      // permanently block a customer name.
      transaction.delete(tabRef);
    }
    const orderRef = tenantRef.collection("orders").doc();
    transaction.create(orderRef, {
      venueId,
      tabName,
      tabNameKey: venueNameKey(tabName),
      status: "open",
      openedAt: FieldValue.serverTimestamp(),
      createdByActor: actor,
      lines: [],
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tabRef, {
      venueId,
      tabName,
      tabNameKey: venueNameKey(tabName),
      orderId: orderRef.id,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "openNamedTab",
      venueId,
      tabName,
      orderId: orderRef.id,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {orderId: orderRef.id, reopened: false};
  });
  return result;
}

// Draft lines are deliberately written by this trusted API rather than by the
// client directly.  They are visible to every till straight away, but remain
// harmless until sendOrderToProductionFor creates the ticket and stock move.
async function addOrderDraftLineFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  const tableId = optionalText(data, "tableId", 180) || null;
  const tabName = optionalText(data, "tabName", 80) || null;
  if ((tableId == null) === (tabName == null)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose either a table or a named tab for the order.",
    );
  }
  const line = validProductionLine(data.line, 0);
  await requireTenantOperationalMember(caller, tenantId);

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
  const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  const productRef = tenantRef.collection("products").doc(line.productId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [venue, table, namedTab, existingOrder, product] = await Promise.all([
      transaction.get(venueRef),
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
      transaction.get(orderRef),
      transaction.get(productRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (tableRef != null && (!table.exists || table.data().venueId !== venueId)) {
      throw new HttpsError("failed-precondition", "The selected table is not available at this venue.");
    }
    if (tableRef != null) {
      const currentOrderId = table.data().currentOrderId;
      if (typeof currentOrderId === "string" && currentOrderId !== orderId) {
        throw new HttpsError(
          "failed-precondition",
          "This table already has a different open order. Reopen that bill instead.",
        );
      }
    }
    if (tabRef != null && (!namedTab.exists || namedTab.data().orderId !== orderId)) {
      throw new HttpsError(
        "failed-precondition",
        "A different open tab already uses this name. Reopen it instead.",
      );
    }
    if (existingOrder.exists) {
      const current = existingOrder.data();
      if (current.venueId !== venueId || current.status === "closed") {
        throw new HttpsError("failed-precondition", "This order is no longer open at this venue.");
      }
      if ((current.tableId ?? null) !== tableId || (current.tabName ?? null) !== tabName) {
        throw new HttpsError("failed-precondition", "This order belongs to a different table or named tab.");
      }
      const priorLines = Array.isArray(current.lines) ? current.lines : [];
      // A lost HTTP response must never result in the same tap being added
      // twice. Line IDs are generated once by the client and are idempotent.
      if (priorLines.some((item) => item?.id === line.id)) {
        return {orderId, saved: true, alreadyPresent: true};
      }
    }
    if (!product.exists || product.data().venueId !== venueId) {
      throw new HttpsError("not-found", "A selected menu product no longer exists at this venue.");
    }
    const productData = product.data();
    if (productData.isAvailable === false) {
      throw new HttpsError("failed-precondition", "This product is currently unavailable.");
    }
    const unitPriceMinor = Number(productData.priceMinor);
    const stockPerSale = Number(productData.stockPerSale ?? 1);
    if (!Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0
        || !Number.isFinite(stockPerSale) || stockPerSale <= 0) {
      throw new HttpsError("failed-precondition", "This product has invalid saved sale details.");
    }
    if (productData.trackStock === true) {
      const onHand = Number(productData.stockOnHand ?? 0);
      if (!Number.isFinite(onHand) || onHand < line.quantity * stockPerSale) {
        throw new HttpsError(
          "failed-precondition",
          "This tracked product is sold out. A manager can only override stock when sending the order.",
        );
      }
    }
    const productionArea = productData.productionArea === "bar"
      ? "bar"
      : productData.productionArea === "dessert"
        ? "dessert"
        : "kitchen";
    const taxRateBasisPoints = validTaxRateBasisPoints(
      productData.taxRateBasisPoints,
    );
    const canonicalLine = {
      id: line.id,
      productId: line.productId,
      productName: typeof productData.name === "string" ? productData.name : "Menu item",
      quantity: line.quantity,
      unitPriceMinor,
      productionArea,
      trackStock: productData.trackStock === true,
      stockPerSale,
      taxRateBasisPoints,
      taxRateId: typeof productData.taxRateId === "string" ? productData.taxRateId : null,
      taxRateName: typeof productData.taxRateName === "string"
        ? productData.taxRateName
        : "Zero rate",
      isSentToProduction: false,
    };
    const current = existingOrder.exists ? existingOrder.data() : null;
    const priorLines = Array.isArray(current?.lines) ? current.lines : [];
    const tableLabel = tableRef == null
      ? null
      : (typeof table.data().label === "string" ? table.data().label : tableId);
    transaction.set(orderRef, {
      venueId,
      tableId,
      tabName,
      tableLabel,
      status: current?.status === "sent" ? "sent" : "open",
      openedAt: current?.openedAt ?? FieldValue.serverTimestamp(),
      createdByActor: current?.createdByActor ?? actor,
      lines: [...priorLines, canonicalLine],
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    }, {merge: true});
    if (tableRef != null) {
      transaction.update(tableRef, {
        currentOrderId: orderId,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "addOrderDraftLine",
      venueId,
      orderId,
      tableId,
      tabName,
      lineId: line.id,
      productId: line.productId,
      quantity: line.quantity,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {orderId, saved: true, alreadyPresent: false};
  });
}

async function updateOrderDraftLineFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  const tableId = optionalText(data, "tableId", 180) || null;
  const tabName = optionalText(data, "tabName", 80) || null;
  if ((tableId == null) === (tabName == null)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose either a table or a named tab for the order.",
    );
  }
  const lineId = requiredText(data, "lineId", 180);
  const quantity = requiredNonNegativeInteger(data.quantity, "quantity", 100);
  await requireTenantOperationalMember(caller, tenantId);

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
  const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [venue, table, namedTab, order] = await Promise.all([
      transaction.get(venueRef),
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
      transaction.get(orderRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (!order.exists || order.data().venueId !== venueId || order.data().status === "closed") {
      throw new HttpsError("failed-precondition", "This order is no longer open at this venue.");
    }
    if ((order.data().tableId ?? null) !== tableId || (order.data().tabName ?? null) !== tabName) {
      throw new HttpsError("failed-precondition", "This order belongs to a different table or named tab.");
    }
    if (tableRef != null && (!table.exists || table.data().venueId !== venueId
        || table.data().currentOrderId !== orderId)) {
      throw new HttpsError("failed-precondition", "The selected table no longer has this open order.");
    }
    if (tabRef != null && (!namedTab.exists || namedTab.data().orderId !== orderId)) {
      throw new HttpsError("failed-precondition", "This named tab is no longer open.");
    }
    const priorLines = Array.isArray(order.data().lines) ? order.data().lines : [];
    const target = priorLines.find((item) => item?.id === lineId);
    if (target == null) {
      throw new HttpsError("not-found", "The draft item is no longer on this order.");
    }
    if (target.isSentToProduction === true) {
      throw new HttpsError("failed-precondition", "Printed items cannot be changed. Use a cancellation or refund.");
    }
    const nextLines = quantity === 0
      ? priorLines.filter((item) => item?.id !== lineId)
      : priorLines.map((item) => item?.id === lineId ? {...item, quantity} : item);
    const hasSentLines = nextLines.some((item) => item?.isSentToProduction === true);
    if (nextLines.length === 0 && tableRef != null) {
      transaction.delete(orderRef);
      transaction.update(tableRef, {
        currentOrderId: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    } else {
      transaction.update(orderRef, {
        status: hasSentLines ? "sent" : "open",
        lines: nextLines,
        updatedAt: FieldValue.serverTimestamp(),
        updatedByActor: actor,
      });
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: quantity === 0 ? "removeOrderDraftLine" : "updateOrderDraftLine",
      venueId,
      orderId,
      tableId,
      tabName,
      lineId,
      quantity,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {orderId, saved: true, removedOrder: nextLines.length === 0 && tableRef != null};
  });
}

async function createTableFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const label = requiredText(data, "label", 80).trim();
  const seats = requiredNonNegativeInteger(data.seats ?? 0, "seats", 1000);
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tenantRef.collection("tables").doc();
  const labelRef = tableLabelRegistryRef(tenantId, venueId, tableLabelKey(label));
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const [venue, registeredLabel] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(labelRef),
    ]);
    // Older venues created before the status field was introduced remain
    // operational. Only an explicitly deleting venue is unavailable.
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (registeredLabel.exists) {
      throw new HttpsError("already-exists", "A table with this name already exists at the venue.");
    }
    transaction.create(tableRef, {
      venueId,
      label,
      normalizedLabel: tableLabelKey(label),
      seats,
      createdAt: FieldValue.serverTimestamp(),
      createdByActor: actor,
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.create(labelRef, {
      venueId,
      tableId: tableRef.id,
      label,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "createTable",
      venueId,
      tableId: tableRef.id,
      label,
      seats,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {id: tableRef.id, label, seats};
}

async function updateTableFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tableId = requiredText(data, "tableId", 128);
  const label = requiredText(data, "label", 80).trim();
  const seats = requiredNonNegativeInteger(data.seats ?? 0, "seats", 1000);
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tableRef = tenantRef.collection("tables").doc(tableId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const table = await transaction.get(tableRef);
    if (!table.exists || table.data().venueId !== venueId) {
      throw new HttpsError("not-found", "The table was not found at this venue.");
    }
    const oldKey = typeof table.data().normalizedLabel === "string"
      ? table.data().normalizedLabel
      : tableLabelKey(table.data().label ?? tableId);
    const newKey = tableLabelKey(label);
    const newLabelRef = tableLabelRegistryRef(tenantId, venueId, newKey);
    if (newKey !== oldKey) {
      const registered = await transaction.get(newLabelRef);
      if (registered.exists && registered.data().tableId !== tableId) {
        throw new HttpsError("already-exists", "A table with this name already exists at the venue.");
      }
      transaction.set(newLabelRef, {
        venueId,
        tableId,
        label,
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.delete(tableLabelRegistryRef(tenantId, venueId, oldKey));
    }
    transaction.update(tableRef, {
      label,
      normalizedLabel: newKey,
      seats,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "updateTable",
      venueId,
      tableId,
      label,
      seats,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {updated: true};
}

async function deleteTableFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tableId = requiredText(data, "tableId", 128);
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tableRef = tenantRef.collection("tables").doc(tableId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const table = await transaction.get(tableRef);
    if (!table.exists || table.data().venueId !== venueId) {
      throw new HttpsError("not-found", "The table was not found at this venue.");
    }
    if (typeof table.data().currentOrderId === "string") {
      throw new HttpsError("failed-precondition", "Close or move the active order before deleting this table.");
    }
    const key = typeof table.data().normalizedLabel === "string"
      ? table.data().normalizedLabel
      : tableLabelKey(table.data().label ?? tableId);
    transaction.delete(tableRef);
    transaction.delete(tableLabelRegistryRef(tenantId, venueId, key));
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "deleteTable",
      venueId,
      tableId,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {deleted: true};
}

async function updateVenueNotificationSettingsFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const notificationRetentionSeconds = requiredPositiveInteger(
    data.notificationRetentionSeconds,
    "notificationRetentionSeconds",
    60,
  );
  await requireTenantOwner(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const venue = await transaction.get(venueRef);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    transaction.update(venueRef, {
      notificationRetentionSeconds,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "updateVenueNotificationSettings",
      venueId,
      notificationRetentionSeconds,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {notificationRetentionSeconds};
}

function currencyDecimalDigits(currencyCode) {
  switch (currencyCode) {
    case "BIF": case "CLP": case "DJF": case "GNF": case "JPY":
    case "KMF": case "KRW": case "PYG": case "RWF": case "UGX":
    case "VND": case "VUV": case "XAF": case "XOF": case "XPF":
      return 0;
    case "BHD": case "IQD": case "JOD": case "KWD": case "LYD":
    case "OMR": case "TND":
      return 3;
    case "CLF": case "UYW":
      return 4;
    default:
      return 2;
  }
}

function tenToBigInt(power) {
  return 10n ** BigInt(power);
}

/// The rate is recorded as: one major unit of tender currency equals this
/// many major units of the tenant's permanent reporting currency. Keeping the
/// original decimal text plus fixed-scale integer arithmetic avoids floating
/// point errors in historic sales data.
function validExchangeRate(value) {
  if (typeof value !== "string" ||
      !/^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$/.test(value.trim())) {
    throw new HttpsError(
      "invalid-argument",
      "exchangeRateToBase must be a positive decimal with up to six decimal places.",
    );
  }
  const text = value.trim();
  const [whole, fraction = ""] = text.split(".");
  const scaled = (BigInt(whole) * 1000000n) + BigInt(fraction.padEnd(6, "0"));
  if (scaled <= 0n) {
    throw new HttpsError("invalid-argument", "exchangeRateToBase must be greater than zero.");
  }
  return {text, scaled};
}

// Percentages are stored as basis points, so 2,000 represents 20.00%.
// Products from before tax support are safely treated as zero-rated until a
// manager sets their rate in Menu management.
function validTaxRateBasisPoints(value) {
  if (value == null) return 0;
  const basisPoints = Number(value);
  if (!Number.isSafeInteger(basisPoints) || basisPoints < 0 || basisPoints > 100000) {
    throw new HttpsError(
      "failed-precondition",
      "A product has an invalid saved tax rate and cannot be sold.",
    );
  }
  return basisPoints;
}

function inclusiveTaxMinor(grossMinor, taxRateBasisPoints) {
  // Prices are tax-inclusive. Half-up rounding keeps gross = net + tax at
  // the bill currency's minor-unit precision.
  return Math.floor(
    ((grossMinor * taxRateBasisPoints) + ((10000 + taxRateBasisPoints) / 2)) /
      (10000 + taxRateBasisPoints),
  );
}

function convertedBaseMinor({amountMinor, tenderCurrencyCode, baseCurrencyCode, exchangeRate}) {
  if (tenderCurrencyCode === baseCurrencyCode) return amountMinor;
  const numerator = BigInt(amountMinor) * exchangeRate.scaled *
    tenToBigInt(currencyDecimalDigits(baseCurrencyCode));
  const denominator = tenToBigInt(currencyDecimalDigits(tenderCurrencyCode)) * 1000000n;
  // Rounds once, half-up, at the reporting currency's minor unit. The rate
  // and converted result are both snapshotted on the bill for auditability.
  const result = (numerator + (denominator / 2n)) / denominator;
  if (result <= 0n || result > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new HttpsError("failed-precondition", "The converted payment amount is outside the supported range.");
  }
  return Number(result);
}

function validClosePayment(value, index, baseCurrencyCode) {
  const payment = requireObject(value);
  const method = requiredText(payment, "method", 40);
  if (!["cash", "cardTerminal"].includes(method)) {
    throw new HttpsError(
      "invalid-argument",
      `payments[${index}].method must be cash or cardTerminal.`,
    );
  }
  const tenderedAmountMinor = requiredPositiveInteger(
    payment.amountMinor,
    `payments[${index}].amountMinor`,
    100000000,
  );
  const cashChangeBaseMinor = payment.cashChangeBaseMinor == null
    ? 0
    : requiredNonNegativeInteger(
      payment.cashChangeBaseMinor,
      `payments[${index}].cashChangeBaseMinor`,
      100000000,
    );
  const tenderedCurrencyCode = requiredText(payment, "currencyCode", 3).toUpperCase();
  if (!supportedCurrencyCodeSet.has(tenderedCurrencyCode)) {
    throw new HttpsError(
      "invalid-argument",
      `payments[${index}].currencyCode must be a supported ISO currency code.`,
    );
  }
  const terminalLabel = optionalText(payment, "terminalLabel", 120) || null;
  const exchangeRateSource = optionalText(payment, "exchangeRateSource", 160) || null;
  const exchangeRatePublishedDate =
    optionalText(payment, "exchangeRatePublishedDate", 80) || null;
  const exchangeRateFetchedAt = optionalText(payment, "exchangeRateFetchedAt", 80) || null;
  if (exchangeRateFetchedAt != null && Number.isNaN(Date.parse(exchangeRateFetchedAt))) {
    throw new HttpsError("invalid-argument", `payments[${index}].exchangeRateFetchedAt is invalid.`);
  }
  if (method === "cardTerminal" && tenderedCurrencyCode !== baseCurrencyCode) {
    throw new HttpsError(
      "failed-precondition",
      "Card terminal payments must use the tenant reporting currency. Foreign tender is recorded as cash.",
    );
  }
  if (method === "cardTerminal" && payment.cardPaymentApproved !== true) {
    throw new HttpsError(
      "failed-precondition",
      "Confirm the card terminal approved this payment before recording it.",
    );
  }
  const exchangeRate = tenderedCurrencyCode === baseCurrencyCode
    ? {text: "1", scaled: 1000000n}
    : validExchangeRate(payment.exchangeRateToBase);
  const tenderedBaseAmountMinor = convertedBaseMinor({
    amountMinor: tenderedAmountMinor,
    tenderCurrencyCode: tenderedCurrencyCode,
    baseCurrencyCode,
    exchangeRate,
  });
  if (method !== "cash" && cashChangeBaseMinor !== 0) {
    throw new HttpsError(
      "invalid-argument",
      `payments[${index}].cashChangeBaseMinor is only valid for cash.`,
    );
  }
  if (cashChangeBaseMinor >= tenderedBaseAmountMinor) {
    throw new HttpsError(
      "failed-precondition",
      "Cash change must be less than the converted cash tender.",
    );
  }
  const baseAmountMinor = tenderedBaseAmountMinor - cashChangeBaseMinor;
  return {
    method,
    tenderedAmountMinor,
    tenderedCurrencyCode,
    exchangeRateToBase: exchangeRate.text,
    tenderedBaseAmountMinor,
    cashChangeBaseMinor,
    baseAmountMinor,
    terminalLabel,
    exchangeRateSource,
    exchangeRatePublishedDate,
    exchangeRateFetchedAt,
    cardPaymentApproved: method === "cardTerminal",
  };
}

function billBusinessDate(timeZone, cutoffMinutes, now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const value = (type) => parts.find((part) => part.type === type)?.value;
  const year = Number(value("year"));
  const month = Number(value("month"));
  const day = Number(value("day"));
  const hour = Number(value("hour"));
  const minute = Number(value("minute"));
  if (![year, month, day, hour, minute].every(Number.isFinite)) {
    throw new HttpsError("failed-precondition", "The venue business date could not be calculated.");
  }
  const localDate = new Date(Date.UTC(year, month - 1, day));
  if ((hour * 60) + minute < cutoffMinutes) {
    localDate.setUTCDate(localDate.getUTCDate() - 1);
  }
  return localDate.toISOString().slice(0, 10);
}

/// Closes an entire open order against verified payment allocations. Splits
/// will create child bills later; this foundation keeps every tender allocation
/// and its conversion inside one transaction so an accidental double tap
/// cannot create two sales or free a table before its record exists.
async function closeOrderFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  if (data.printReceipt != null && typeof data.printReceipt !== "boolean") {
    throw new HttpsError("invalid-argument", "printReceipt must be true or false.");
  }
  const printReceipt = data.printReceipt === true;
  const rawPayments = data.payments;
  if (!Array.isArray(rawPayments) || rawPayments.length === 0 || rawPayments.length > 8) {
    throw new HttpsError(
      "invalid-argument",
      "One to eight payment allocations are required.",
    );
  }
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  // A deterministic bill ID makes a lost HTTP response safe to retry.
  const billRef = tenantRef.collection("bills").doc(orderId);
  const receiptRouteRef = printReceipt
    ? tenantRef.collection("printerRoutes").doc(`${venueId}_receipt`)
    : null;
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [tenant, venue, order, existingBill, receiptRoute] = await Promise.all([
      transaction.get(tenantRef),
      transaction.get(venueRef),
      transaction.get(orderRef),
      transaction.get(billRef),
      receiptRouteRef == null ? Promise.resolve(null) : transaction.get(receiptRouteRef),
    ]);
    if (!tenant.exists) {
      throw new HttpsError("not-found", "The restaurant was not found.");
    }
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (existingBill.exists) {
      const existing = existingBill.data();
      if (existing.venueId !== venueId || existing.orderId !== orderId) {
        throw new HttpsError("failed-precondition", "This bill ID belongs to different sale data.");
      }
      return {
        billId: existingBill.id,
        totalMinor: existing.totalMinor,
        currencyCode: existing.currencyCode,
        receiptNumber: typeof existing.receiptNumber === "string"
          ? existing.receiptNumber
          : existingBill.id,
        receiptPrintRequested: existing.receiptPrintRequested === true,
        receiptPrintQueued: existing.receiptPrintQueued === true,
        alreadyClosed: true,
      };
    }
    if (!order.exists || order.data().venueId !== venueId || order.data().status === "closed") {
      throw new HttpsError("failed-precondition", "This order is no longer open at this venue.");
    }
    const orderData = order.data();
    const rawLines = Array.isArray(orderData.lines) ? orderData.lines : [];
    if (rawLines.length === 0) {
      throw new HttpsError("failed-precondition", "An empty order cannot be closed.");
    }
    if (rawLines.some((line) => line?.isSentToProduction !== true)) {
      throw new HttpsError(
        "failed-precondition",
        "Send or remove every draft item before closing the bill.",
      );
    }
    const lines = rawLines.map((line, index) => {
      const quantity = Number(line?.quantity);
      const unitPriceMinor = Number(line?.unitPriceMinor);
      if (!Number.isInteger(quantity) || quantity <= 0 ||
          !Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0) {
        throw new HttpsError("failed-precondition", `Order line ${index + 1} has invalid saved sale data.`);
      }
      const taxRateBasisPoints = validTaxRateBasisPoints(
        line?.taxRateBasisPoints,
      );
      const taxRateId = typeof line?.taxRateId === "string" ? line.taxRateId : null;
      const taxRateName = typeof line?.taxRateName === "string" &&
          line.taxRateName.trim().length > 0
        ? line.taxRateName.trim()
        : "Zero rate";
      const lineTotalMinor = quantity * unitPriceMinor;
      const taxMinor = inclusiveTaxMinor(lineTotalMinor, taxRateBasisPoints);
      return {
        id: typeof line.id === "string" ? line.id : "",
        productId: typeof line.productId === "string" ? line.productId : "",
        productName: typeof line.productName === "string" ? line.productName : "Menu item",
        quantity,
        unitPriceMinor,
        lineTotalMinor,
        taxRateBasisPoints,
        taxRateId,
        taxRateName,
        taxMinor,
        netMinor: lineTotalMinor - taxMinor,
        productionArea: typeof line.productionArea === "string" ? line.productionArea : "kitchen",
      };
    });
    const totalMinor = lines.reduce((total, line) => total + line.lineTotalMinor, 0);
    if (!Number.isSafeInteger(totalMinor) || totalMinor <= 0) {
      throw new HttpsError("failed-precondition", "This order has no payable total.");
    }
    const taxByRate = new Map();
    for (const line of lines) {
      const taxKey = line.taxRateId ?? `${line.taxRateName}_${line.taxRateBasisPoints}`;
      const current = taxByRate.get(taxKey) ?? {
        taxRateId: line.taxRateId,
        taxRateName: line.taxRateName,
        taxRateBasisPoints: line.taxRateBasisPoints,
        grossMinor: 0,
        netMinor: 0,
        taxMinor: 0,
      };
      current.grossMinor += line.lineTotalMinor;
      current.netMinor += line.netMinor;
      current.taxMinor += line.taxMinor;
      taxByRate.set(taxKey, current);
    }
    const taxBreakdown = [...taxByRate.values()].sort(
      (left, right) => left.taxRateBasisPoints - right.taxRateBasisPoints,
    );
    const taxTotalMinor = taxBreakdown.reduce(
      (total, entry) => total + entry.taxMinor,
      0,
    );
    const netTotalMinor = totalMinor - taxTotalMinor;
    const currencyCode = String(tenant.data().currencyCode ?? "GBP").toUpperCase();
    const payments = rawPayments.map((payment, index) =>
      validClosePayment(payment, index, currencyCode));
    if (payments.some((payment) => payment.tenderedCurrencyCode !== currencyCode) &&
        !roles.some((role) => role === "owner" || role === "manager")) {
      throw new HttpsError(
        "permission-denied",
        "A manager must enter or approve a foreign-currency exchange rate.",
      );
    }
    const paidMinor = payments.reduce((total, payment) => total + payment.baseAmountMinor, 0);
    if (paidMinor !== totalMinor) {
      throw new HttpsError(
        "failed-precondition",
        "The payment amount must exactly equal the current bill total.",
      );
    }

    const tableId = typeof orderData.tableId === "string" ? orderData.tableId : null;
    const tabName = typeof orderData.tabName === "string" ? orderData.tabName : null;
    const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
    const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
    const [table, namedTab] = await Promise.all([
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
    ]);
    const timeZone = typeof venue.data().timeZone === "string"
      ? venue.data().timeZone
      : "Europe/London";
    const configuredCutoff = Number(venue.data().businessDayCutoffMinutes ?? 240);
    const cutoffMinutes = Number.isInteger(configuredCutoff) && configuredCutoff >= 0 && configuredCutoff < 1440
      ? configuredCutoff
      : 240;
    const businessDate = billBusinessDate(timeZone, cutoffMinutes);
    const receiptNumber = `${businessDate.replaceAll("-", "")}-${orderId.slice(-6).toUpperCase()}`;
    const receiptLines = lines.map((line) => ({...line}));
    const receiptTargetDeviceId = receiptRoute?.exists &&
        typeof receiptRoute.data().primaryDeviceId === "string"
      ? receiptRoute.data().primaryDeviceId
      : null;
    const receiptDeviceRef = receiptTargetDeviceId == null
      ? null
      : tenantRef.collection("devices").doc(receiptTargetDeviceId);
    // Reads must happen before the transaction writes. This separately-routed
    // device is the only printer allowed to receive paid bill totals.
    const receiptDevice = receiptDeviceRef == null
      ? null
      : await transaction.get(receiptDeviceRef);
    const receiptPrintQueued = printReceipt &&
      receiptTargetDeviceId != null &&
      activeRouteDevice(receiptDevice, venueId, "receipt");
    const receiptPrintJobId = receiptPrintQueued
      ? `receipt_${orderId}_${receiptTargetDeviceId}`
      : null;

    transaction.create(billRef, {
      venueId,
      orderId,
      status: "closed",
      receiptNumber,
      tableId,
      tableLabel: typeof orderData.tableLabel === "string" ? orderData.tableLabel : null,
      tabName,
      currencyCode,
      businessDate,
      businessDayCutoffMinutes: cutoffMinutes,
      venueTimeZone: timeZone,
      totalMinor,
      grossTotalMinor: totalMinor,
      netTotalMinor,
      taxTotalMinor,
      taxBreakdown,
      payments,
      receiptPrintRequested: printReceipt,
      receiptPrintQueued,
      receiptPrintJobId,
      lines: receiptLines,
      openedAt: orderData.openedAt ?? null,
      closedAt: FieldValue.serverTimestamp(),
      closedByActor: actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    if (receiptPrintQueued) {
      transaction.create(tenantRef.collection("printJobs").doc(receiptPrintJobId), {
        venueId,
        targetDeviceId: receiptTargetDeviceId,
        fallbackDeviceId: typeof receiptRoute.data().fallbackDeviceId === "string"
          ? receiptRoute.data().fallbackDeviceId
          : null,
        orderId,
        ticketId: `receipt_${orderId}`,
        productionArea: "receipt",
        status: "queued",
        attempts: 0,
        idempotencyKey: receiptPrintJobId,
        payload: {
          type: "receipt",
          receiptNumber,
          restaurantName: typeof tenant.data().displayName === "string"
            ? tenant.data().displayName
            : "TABLESIDE POS",
          currencyCode,
          businessDate,
          tableLabel: typeof orderData.tableLabel === "string"
            ? orderData.tableLabel
            : null,
          tabName,
          totalMinor,
          netTotalMinor,
          taxTotalMinor,
          taxBreakdown,
          lines: receiptLines,
          payments,
        },
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.update(orderRef, {
      status: "closed",
      closedAt: FieldValue.serverTimestamp(),
      closedByActor: actor,
      billId: billRef.id,
      businessDate,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    if (tableRef != null && table?.exists && table.data().currentOrderId === orderId) {
      transaction.update(tableRef, {
        currentOrderId: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    if (tabRef != null && namedTab?.exists && namedTab.data().orderId === orderId) {
      transaction.delete(tabRef);
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "closeBill",
      venueId,
      orderId,
      billId: billRef.id,
      receiptNumber,
      totalMinor,
      netTotalMinor,
      taxTotalMinor,
      receiptPrintRequested: printReceipt,
      receiptPrintQueued,
      receiptPrintJobId,
      currencyCode,
      paymentMethods: payments.map((payment) => payment.method),
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      billId: billRef.id,
      totalMinor,
      currencyCode,
      receiptNumber,
      receiptPrintRequested: printReceipt,
      receiptPrintQueued,
      alreadyClosed: false,
    };
  });
}

function activeRouteDevice(device, venueId, productionArea) {
  if (!device?.exists) return false;
  const data = device.data();
  return data.venueId === venueId
    && data.active === true
    && Array.isArray(data.productionAreas)
    && data.productionAreas.includes(productionArea);
}

// A ticket is deliberately queued to one device at a time.  The original
// device gets three attempts (managed by the client worker); only then does
// this server-side trigger create a separate, idempotent fallback job.  That
// prevents the same ticket printing at both locations while a printer is just
// temporarily slow to connect.
export const enqueueFallbackPrintJob = onDocumentUpdated(
  "tenants/{tenantId}/printJobs/{jobId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before == null || after == null) {
      return;
    }

    const tenantId = event.params.tenantId;
    const jobId = event.params.jobId;
    // A fallback completing proves the original ticket was delivered. Store
    // that fact on the failed primary so all tills can stream unresolved jobs
    // only and immediately clear the alarm rather than retaining a false
    // failed-print notification forever.
    if (before.status !== "printed" && after.status === "printed" &&
        typeof after.fallbackFromJobId === "string" && after.fallbackFromJobId.length > 0) {
      const primaryRef = db.doc(`tenants/${tenantId}/printJobs/${after.fallbackFromJobId}`);
      const primary = await primaryRef.get();
      if (primary.exists) {
        await primaryRef.update({
          fallbackDeliveryStatus: "printed",
          fallbackPrintedAt: FieldValue.serverTimestamp(),
        });
      }
      console.info("Fallback print job completed", {
        tenantId,
        jobId,
        failedJobId: after.fallbackFromJobId,
      });
      return;
    }
    if (before.status === "failed" || after.status !== "failed") {
      return;
    }

    const venueId = typeof after.venueId === "string" ? after.venueId : "";
    const productionArea = typeof after.productionArea === "string" ? after.productionArea : "";
    const primaryDeviceId = typeof after.targetDeviceId === "string" ? after.targetDeviceId : "";
    const fallbackDeviceId = typeof after.fallbackDeviceId === "string" ? after.fallbackDeviceId : "";
    if (!venueId || !productionArea || !fallbackDeviceId || fallbackDeviceId === primaryDeviceId) {
      return;
    }

    const tenantRef = db.doc(`tenants/${tenantId}`);
    const fallbackDevice = await tenantRef.collection("devices").doc(fallbackDeviceId).get();
    if (!activeRouteDevice(fallbackDevice, venueId, productionArea)) {
      console.warn("Skipping invalid fallback print device", {
        tenantId,
        jobId,
        venueId,
        productionArea,
        fallbackDeviceId,
      });
      return;
    }

    const fallbackJobId = `${jobId}_fallback`;
    const fallbackRef = tenantRef.collection("printJobs").doc(fallbackJobId);
    const auditRef = tenantRef.collection("auditEvents").doc(`printFallback_${jobId}`);
    const batch = db.batch();
    batch.create(fallbackRef, {
      venueId,
      targetDeviceId: fallbackDeviceId,
      fallbackDeviceId: null,
      orderId: after.orderId,
      ticketId: after.ticketId,
      productionArea,
      status: "queued",
      attempts: 0,
      idempotencyKey: fallbackJobId,
      payload: after.payload ?? {},
      fallbackFromJobId: jobId,
      createdAt: FieldValue.serverTimestamp(),
    });
    batch.create(auditRef, {
      action: "queueFallbackPrintJob",
      venueId,
      orderId: after.orderId ?? null,
      ticketId: after.ticketId ?? null,
      productionArea,
      failedJobId: jobId,
      fallbackJobId,
      primaryDeviceId,
      fallbackDeviceId,
      createdAt: FieldValue.serverTimestamp(),
    });
    try {
      await batch.commit();
      console.info("Queued fallback print job", {
        tenantId,
        jobId,
        fallbackJobId,
        fallbackDeviceId,
      });
    } catch (error) {
      // Firestore triggers are at-least-once. The deterministic document IDs
      // mean an already-created fallback is a successful previous delivery.
      if (error?.code === 6 || error?.code === "already-exists") return;
      throw error;
    }
  },
);

async function sendOrderToProductionFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  const tableId = optionalText(data, "tableId", 180) || null;
  const tabName = optionalText(data, "tabName", 80) || null;
  if ((tableId == null) === (tabName == null)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose either a table or a named tab for the order.",
    );
  }
  const rawLines = data.lines;
  if (!Array.isArray(rawLines) || rawLines.length === 0 || rawLines.length > 100) {
    throw new HttpsError("invalid-argument", "One to one hundred new order lines are required.");
  }
  const lines = rawLines.map(validProductionLine);
  if (new Set(lines.map((line) => line.id)).size !== lines.length) {
    throw new HttpsError("invalid-argument", "Each new order line needs a unique ID.");
  }
  const stockOverride = data.stockOverride === true;
  if (data.printRequired != null && typeof data.printRequired !== "boolean") {
    throw new HttpsError("invalid-argument", "printRequired must be true or false.");
  }
  // Older app builds retain their existing behaviour and print by default.
  const printRequired = data.printRequired !== false;
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (stockOverride && !roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only a manager can override unavailable stock.");
  }

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
  const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  const productRefs = new Map(
    [...new Set(lines.map((line) => line.productId))].map((productId) => [
      productId,
      tenantRef.collection("products").doc(productId),
    ]),
  );
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  const tenant = await tenantRef.get();
  const restaurantName = tenant.exists && typeof tenant.data().displayName === "string"
    ? tenant.data().displayName
    : "TABLESIDE POS";

  const result = await db.runTransaction(async (transaction) => {
    const [venue, table, namedTab, existingOrder, ...products] = await Promise.all([
      transaction.get(venueRef),
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
      transaction.get(orderRef),
      ...[...productRefs.values()].map((ref) => transaction.get(ref)),
    ]);
    // Older venues created before the status field was introduced remain
    // operational. Only an explicitly deleting venue is unavailable.
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (tableRef != null && (!table.exists || table.data().venueId !== venueId)) {
      throw new HttpsError("failed-precondition", "The selected table is not available at this venue.");
    }
    const currentOrderId = tableRef == null ? null : table.data().currentOrderId;
    if (tableRef != null && typeof currentOrderId === "string" && currentOrderId !== orderId) {
      throw new HttpsError(
        "failed-precondition",
        "This table already has a different open order. Reopen that bill instead.",
      );
    }
    if (tabRef != null && (!namedTab.exists || namedTab.data().orderId !== orderId)) {
      throw new HttpsError(
        "failed-precondition",
        "A different open tab already uses this name. Reopen it instead.",
      );
    }
    const productById = new Map();
    for (const snapshot of products) {
      if (!snapshot.exists) {
        throw new HttpsError("not-found", "A selected menu product no longer exists.");
      }
      if (snapshot.data().venueId !== venueId) {
        throw new HttpsError(
          "failed-precondition",
          "A selected menu product does not belong to this venue.",
        );
      }
      productById.set(snapshot.id, snapshot.data());
    }

    const canonicalLines = lines.map((line) => {
      const product = productById.get(line.productId);
      if (product.isAvailable === false) {
        throw new HttpsError("failed-precondition", "A selected product is unavailable.");
      }
      const unitPriceMinor = Number(product.priceMinor);
      if (!Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0) {
        throw new HttpsError(
          "failed-precondition",
          "A selected product has an invalid stored price and cannot be sold.",
        );
      }
      const stockPerSale = Number(product.stockPerSale ?? 1);
      if (!Number.isFinite(stockPerSale) || stockPerSale <= 0) {
        throw new HttpsError(
          "failed-precondition",
          "A selected product has an invalid stock quantity per sale.",
        );
      }
      const productionArea = product.productionArea === "bar"
        ? "bar"
        : product.productionArea === "dessert"
          ? "dessert"
          : "kitchen";
      const taxRateBasisPoints = validTaxRateBasisPoints(
        product.taxRateBasisPoints,
      );
      return {
        ...line,
        productName: typeof product.name === "string" ? product.name : "Menu item",
        unitPriceMinor,
        productionArea,
        trackStock: product.trackStock === true,
        stockPerSale,
        taxRateBasisPoints,
        taxRateId: typeof product.taxRateId === "string" ? product.taxRateId : null,
        taxRateName: typeof product.taxRateName === "string"
          ? product.taxRateName
          : "Zero rate",
        showOnOrderFlow: product.showOnOrderFlow !== false,
      };
    });
    const groups = new Map();
    for (const line of canonicalLines) {
      const group = groups.get(line.productionArea) ?? [];
      group.push(line);
      groups.set(line.productionArea, group);
    }
    const ticketEntries = [...groups.entries()].map(([area, areaLines]) => {
      const ticketId = `${orderId}_${area}_${areaLines.map((line) => line.id).join("_")}`;
      return {area, lines: areaLines, ticketId, ref: tenantRef.collection("productionTickets").doc(ticketId)};
    });
    const existingTickets = await Promise.all(
      ticketEntries.map((ticket) => transaction.get(ticket.ref)),
    );
    const existingTicketIds = new Set(
      existingTickets.filter((ticket) => ticket.exists).map((ticket) => ticket.id),
    );
    // Route records are read before any transaction writes. A route is only
    // accepted when its target is an active printer device at this same venue.
    const routeEntries = printRequired ? ticketEntries.map((ticket) => ({
      area: ticket.area,
      ref: tenantRef.collection("printerRoutes").doc(`${venueId}_${ticket.area}`),
    })) : [];
    const routeSnapshots = await Promise.all(
      routeEntries.map((route) => transaction.get(route.ref)),
    );
    const routeByArea = new Map(
      routeSnapshots
        .map((snapshot, index) => [routeEntries[index].area, snapshot])
        .filter(([, snapshot]) => snapshot.exists),
    );
    const targetDeviceIds = [...new Set(
      [...routeByArea.values()]
        .map((route) => route.data().primaryDeviceId)
        .filter((deviceId) => typeof deviceId === "string" && deviceId.length > 0),
    )];
    const targetDeviceRefs = new Map(targetDeviceIds.map((deviceId) => [
      deviceId,
      tenantRef.collection("devices").doc(deviceId),
    ]));
    const targetDevices = await Promise.all(
      [...targetDeviceRefs.values()].map((ref) => transaction.get(ref)),
    );
    const deviceById = new Map(
      targetDevices.map((device) => [device.id, device]),
    );

    const tableLabel = tableRef == null
      ? null
      : (typeof table.data().label === "string" ? table.data().label : tableId);
    const priorLines = Array.isArray(existingOrder.data()?.lines) ? existingOrder.data().lines : [];
    const priorLineIds = new Set(
      priorLines.map((line) => (typeof line?.id === "string" ? line.id : "")),
    );
    const canonicalById = new Map(canonicalLines.map((line) => [line.id, line]));
    const sentOrderLine = (line) => ({
      id: line.id,
      productId: line.productId,
      productName: line.productName,
      quantity: line.quantity,
      unitPriceMinor: line.unitPriceMinor,
      productionArea: line.productionArea,
      trackStock: line.trackStock,
      stockPerSale: line.stockPerSale,
      taxRateBasisPoints: line.taxRateBasisPoints,
      taxRateId: line.taxRateId,
      taxRateName: line.taxRateName,
      isSentToProduction: true,
    });
    // Draft lines already exist on the order so every device can see them.
    // Sending must promote those same lines to sent rather than treating them
    // as duplicates and silently creating no ticket.
    const mergedOrderLines = [
      ...priorLines.map((line) => {
        const canonical = canonicalById.get(line?.id);
        return canonical == null ? line : sentOrderLine(canonical);
      }),
      ...canonicalLines
        .filter((line) => !priorLineIds.has(line.id))
        .map(sentOrderLine),
    ];
    const hasPriorSentLines = priorLines.some((line) => line?.isSentToProduction === true);
    transaction.set(orderRef, {
      venueId,
      tableId,
      tabName,
      tableLabel,
      status: "sent",
      openedAt: existingOrder.data()?.openedAt ?? FieldValue.serverTimestamp(),
      lastTicketReleasedAt: FieldValue.serverTimestamp(),
      createdByActor: existingOrder.data()?.createdByActor ?? actor,
      lines: mergedOrderLines,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    }, {merge: true});
    if (tableRef != null) {
      transaction.update(tableRef, {
        currentOrderId: orderId,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    const stockTotals = new Map();
    const printJobIds = [];
    const queuedProductionAreas = new Set();
    const unroutedProductionAreas = new Set();
    for (const ticket of ticketEntries) {
      if (existingTicketIds.has(ticket.ticketId)) continue;
      transaction.create(ticket.ref, {
        venueId,
        orderId,
        reference: orderId.split("-").at(-1) ?? orderId,
        tableLabel,
        tabName,
        productionArea: ticket.area,
        printRequired,
        flowStatus: "newOrder",
        ticketReleasedAt: FieldValue.serverTimestamp(),
        productionItems: ticket.lines.map((line) => ({
          name: line.productName,
          quantity: line.quantity,
        })),
        orderFlowItems: ticket.lines
          .filter((line) => line.showOnOrderFlow)
          .map((line) => ({
            name: line.productName,
            quantity: line.quantity,
          })),
        showOnOrderFlow: ticket.lines.some((line) => line.showOnOrderFlow),
        hasAllergyAlert: false,
        isDelayed: false,
        createdByActor: actor,
        idempotencyKey: ticket.ticketId,
        createdAt: FieldValue.serverTimestamp(),
      });
      if (printRequired) {
        const route = routeByArea.get(ticket.area);
        const targetDeviceId = route?.data().primaryDeviceId;
        const targetDevice = typeof targetDeviceId === "string"
          ? deviceById.get(targetDeviceId)
          : null;
        if (typeof targetDeviceId === "string"
            && activeRouteDevice(targetDevice, venueId, ticket.area)) {
          const jobId = `${ticket.ticketId}_${targetDeviceId}`;
          transaction.create(tenantRef.collection("printJobs").doc(jobId), {
            venueId,
            targetDeviceId,
            fallbackDeviceId: typeof route.data().fallbackDeviceId === "string"
              ? route.data().fallbackDeviceId
              : null,
            orderId,
            ticketId: ticket.ticketId,
            productionArea: ticket.area,
            status: "queued",
            attempts: 0,
            idempotencyKey: jobId,
            payload: {
              type: "production",
              ticketId: ticket.ticketId,
              restaurantName,
              reference: orderId.split("-").at(-1) ?? orderId,
              productionArea: ticket.area,
              tableLabel,
              tabName,
              isAddition: hasPriorSentLines,
              createdByName: actor.displayName ?? actor.email ?? "",
              lines: ticket.lines.map((line) => ({
                name: line.productName,
                quantity: line.quantity,
              })),
            },
            createdAt: FieldValue.serverTimestamp(),
          });
          printJobIds.push(jobId);
          queuedProductionAreas.add(ticket.area);
        } else {
          unroutedProductionAreas.add(ticket.area);
        }
      }
      // The till deliberately keeps every tap as its own order line so staff
      // can see the latest addition. Several lines can therefore represent
      // the same tracked product on one ticket. Aggregate before creating
      // stock movements: Firestore correctly rejects two `create` writes to
      // the same ticket/product movement document in one transaction.
      const ticketStockTotals = new Map();
      for (const line of ticket.lines.filter((item) => item.trackStock)) {
        const quantity = line.quantity * line.stockPerSale;
        ticketStockTotals.set(
          line.productId,
          (ticketStockTotals.get(line.productId) ?? 0) + quantity,
        );
      }
      for (const [productId, quantity] of ticketStockTotals.entries()) {
        stockTotals.set(productId, (stockTotals.get(productId) ?? 0) + quantity);
        const movementRef = tenantRef.collection("stockMovements")
          .doc(`${ticket.ticketId}_${productId}`);
        transaction.create(movementRef, {
          venueId,
          orderId,
          ticketId: ticket.ticketId,
          productId,
          quantity: -quantity,
          reason: "productionTicketReleased",
          createdByActor: actor,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
    }
    for (const [productId, quantity] of stockTotals.entries()) {
      const product = productById.get(productId);
      const onHand = Number(product.stockOnHand ?? 0);
      if (onHand < quantity && !stockOverride) {
        throw new HttpsError(
          "failed-precondition",
          "One or more tracked products are sold out. A manager may record an audited stock override.",
        );
      }
      transaction.update(productRefs.get(productId), {
        stockOnHand: FieldValue.increment(-quantity),
        lastStockMovementAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "sendOrderToProduction",
      venueId,
      orderId,
      ticketIds: ticketEntries.map((ticket) => ticket.ticketId),
      printJobIds,
      queuedProductionAreas: [...queuedProductionAreas],
      unroutedProductionAreas: [...unroutedProductionAreas],
      stockOverride,
      printRequired,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      ticketIds: ticketEntries.map((ticket) => ticket.ticketId),
      printJobIds,
      queuedProductionAreas: [...queuedProductionAreas],
      unroutedProductionAreas: [...unroutedProductionAreas],
      stockOverride,
      printRequired,
    };
  });
  return result;
}

const permittedOrderFlowTransitions = Object.freeze({
  newOrder: ["newOrder", "preparing"],
  preparing: ["preparing", "ready"],
  ready: ["ready", "collected"],
  collected: ["collected", "served"],
  served: ["served"],
  cancelled: ["cancelled"],
  voided: ["voided"],
});

async function updateProductionTicketFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const ticketId = requiredText(data, "ticketId", 300);
  const flowStatus = requiredText(data, "flowStatus", 32);
  if (!Object.hasOwn(permittedOrderFlowTransitions, flowStatus)) {
    throw new HttpsError("invalid-argument", "The production status is not recognised.");
  }
  if (typeof data.isDelayed !== "boolean") {
    throw new HttpsError("invalid-argument", "isDelayed must be true or false.");
  }
  const membership = await db.doc(`tenants/${tenantId}/members/${caller.uid}`).get();
  const roles = membership.exists && Array.isArray(membership.data().roles)
    ? membership.data().roles
    : [];
  if (!membership.exists || membership.data().active === false
      || !roles.some((role) => ["owner", "manager", "waiter", "cashier", "kitchen"].includes(role))) {
    throw new HttpsError("permission-denied", "Your role cannot update production tickets.");
  }
  const ticketRef = db.doc(`tenants/${tenantId}/productionTickets/${ticketId}`);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  return db.runTransaction(async (transaction) => {
    const ticket = await transaction.get(ticketRef);
    if (!ticket.exists || ticket.data().venueId !== venueId) {
      throw new HttpsError("not-found", "The production ticket was not found at this venue.");
    }
    const currentStatus = typeof ticket.data().flowStatus === "string"
      ? ticket.data().flowStatus
      : "newOrder";
    const permitted = permittedOrderFlowTransitions[currentStatus] ?? [];
    if (!permitted.includes(flowStatus)) {
      throw new HttpsError(
        "failed-precondition",
        "This ticket must move through the normal production sequence.",
      );
    }
    transaction.update(ticketRef, {
      flowStatus,
      isDelayed: data.isDelayed,
      flowUpdatedAt: FieldValue.serverTimestamp(),
      flowUpdatedByActor: actor,
    });
    transaction.create(db.doc(`tenants/${tenantId}/auditEvents/${ticketId}_${Date.now()}`), {
      action: "updateProductionTicket",
      venueId,
      ticketId,
      fromStatus: currentStatus,
      toStatus: flowStatus,
      isDelayed: data.isDelayed,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {updated: true};
  });
}

async function invokePlatformAction(action, caller, data) {
  switch (action) {
    case "bootstrapPlatformAdmin":
      return bootstrapPlatformAdminFor(caller);
    case "listAuthUsers":
      return listAuthUsersFor(caller, data);
    case "listTenants":
      return listTenantsFor(caller);
    case "listSupportedTimeZones":
      return listSupportedTimeZonesFor(caller);
    case "listSupportedCurrencies":
      return listSupportedCurrenciesFor(caller);
    case "listTenantVenues":
      return listTenantVenuesFor(caller, data);
    case "listUserMemberships":
      return listUserMembershipsFor(caller, data);
    case "createTenant":
      return createTenantFor(caller, data);
    case "updateTenant":
      return updateTenantFor(caller, data);
    case "createVenue":
      return createVenueFor(caller, data);
    case "updateVenue":
      return updateVenueFor(caller, data);
    case "deleteVenue":
      return deleteVenueFor(caller, data);
    case "createStaffUser":
      return createStaffUserFor(caller, data);
    case "assignUserToTenant":
      return assignUserToTenantFor(caller, data);
    case "retireStaffUser":
      return retireStaffUserFor(caller, data);
    case "setPlatformAdmin":
      return setPlatformAdminFor(caller, data);
    default:
      throw new HttpsError("not-found", "That platform action does not exist.");
  }
}

async function invokePosAction(action, caller, data) {
  switch (action) {
    case "openNamedTab":
      return openNamedTabFor(caller, data);
    case "addOrderDraftLine":
      return addOrderDraftLineFor(caller, data);
    case "updateOrderDraftLine":
      return updateOrderDraftLineFor(caller, data);
    case "createTable":
      return createTableFor(caller, data);
    case "updateTable":
      return updateTableFor(caller, data);
    case "deleteTable":
      return deleteTableFor(caller, data);
    case "updateVenueNotificationSettings":
      return updateVenueNotificationSettingsFor(caller, data);
    case "lookupExchangeRate":
      return lookupExchangeRateFor(caller, data);
    case "sendOrderToProduction":
      return sendOrderToProductionFor(caller, data);
    case "closeOrder":
      return closeOrderFor(caller, data);
    case "updateProductionTicket":
      return updateProductionTicketFor(caller, data);
    default:
      throw new HttpsError("not-found", "That POS action does not exist.");
  }
}

async function callerFromHttpRequest(request) {
  const header = request.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    throw new HttpsError("unauthenticated", "A Firebase ID token is required.");
  }
  try {
    const token = await auth.verifyIdToken(header.substring(7));
    return {uid: token.uid, token};
  } catch (_) {
    throw new HttpsError("unauthenticated", "The Firebase ID token is invalid or expired.");
  }
}

// Verifies App Check for TableSide's custom HTTP APIs. Firestore and Storage
// have their own App Check enforcement in the Firebase console. Monitor mode
// provides server-side evidence before enforcement rejects older clients.
async function verifyAppCheckFromHttpRequest(request, endpointName) {
  const token = request.get("X-Firebase-AppCheck") ?? "";
  if (token.trim().length === 0) {
    console.warn(`App Check missing for ${endpointName}.`);
    if (requireAppCheck.value()) {
      throw new HttpsError("unauthenticated", "A valid Firebase App Check token is required.");
    }
    return null;
  }
  try {
    const claims = await appCheck.verifyToken(token);
    console.info(`App Check verified for ${endpointName}.`);
    return claims;
  } catch (error) {
    console.warn(`App Check verification failed for ${endpointName}.`, error);
    if (requireAppCheck.value()) {
      throw new HttpsError("unauthenticated", "The Firebase App Check token is invalid.");
    }
    return null;
  }
}

function httpStatusFor(error) {
  switch (error.code) {
    case "invalid-argument": return 400;
    case "unauthenticated": return 401;
    case "permission-denied": return 403;
    case "not-found": return 404;
    case "already-exists": return 409;
    case "failed-precondition": return 412;
    case "unavailable": return 503;
    default: return 500;
  }
}

function diagnosticErrorMessage(error) {
  // Preserve a concise, actionable message for authenticated debug clients.
  // Stacks remain server-only, but swallowing the message turns every server
  // fault into an indistinguishable HTTP 500 and makes safe POS recovery
  // impossible for staff.
  if (error != null && typeof error === "object" &&
      typeof error.message === "string" && error.message.trim().length > 0) {
    return error.message.trim().slice(0, 300);
  }
  return "An unexpected server error occurred.";
}

// This endpoint is used by the Flutter app because the FlutterFire Functions
// plugin does not yet support Windows. It verifies the Firebase ID token on
// every call, then uses exactly the same handlers as the callable functions.
export const platformAdminApi = onRequest({cors: true}, async (request, response) => {
  try {
    if (request.method !== "POST") {
      response.status(405).json({error: {code: "method-not-allowed", message: "Use POST."}});
      return;
    }
    await verifyAppCheckFromHttpRequest(request, "platformAdminApi");
    const body = requireObject(request.body);
    const action = requiredText(body, "action", 80);
    const data = requireObject(body.data ?? {});
    const caller = await callerFromHttpRequest(request);
    const result = await invokePlatformAction(action, caller, data);
    response.status(200).json({data: result});
  } catch (error) {
    if (error instanceof HttpsError) {
      response.status(httpStatusFor(error)).json({
        error: {code: error.code, message: error.message},
      });
      return;
    }
    console.error("Unexpected platform administration error", error);
    response.status(500).json({
      error: {code: "internal", message: "The platform action could not be completed."},
    });
  }
});

// Privileged POS mutations use this small authenticated HTTP surface for the
// same Windows-compatible reason as platformAdminApi.  It treats all client
// prices, stock and printer-facing data as untrusted and derives the canonical
// values from Firestore inside the command handler.
export const posApi = onRequest({cors: true}, async (request, response) => {
  let action = "unknown";
  try {
    if (request.method !== "POST") {
      response.status(405).json({error: {code: "method-not-allowed", message: "Use POST."}});
      return;
    }
    await verifyAppCheckFromHttpRequest(request, "posApi");
    const body = requireObject(request.body);
    action = requiredText(body, "action", 80);
    const data = requireObject(body.data ?? {});
    const caller = await callerFromHttpRequest(request);
    const result = await invokePosAction(action, caller, data);
    response.status(200).json({data: result});
  } catch (error) {
    if (error instanceof HttpsError) {
      response.status(httpStatusFor(error)).json({
        error: {code: error.code, message: error.message},
      });
      return;
    }
    const message = diagnosticErrorMessage(error);
    console.error("Unexpected POS command error", {
      action,
      code: error != null && typeof error === "object" ? error.code ?? null : null,
      message,
      stack: error != null && typeof error === "object" ? error.stack ?? null : null,
    });
    response.status(500).json({
      error: {
        code: "internal",
        message: `The POS action could not be completed: ${message}`,
      },
    });
  }
});

// Callable variants remain available for non-Windows clients and tests.
export const bootstrapPlatformAdmin = onCall((request) =>
  bootstrapPlatformAdminFor(callerFromCall(request)));
export const listAuthUsers = onCall((request) =>
  listAuthUsersFor(callerFromCall(request), request.data));
export const listTenants = onCall((request) =>
  listTenantsFor(callerFromCall(request)));
export const listSupportedTimeZones = onCall((request) =>
  listSupportedTimeZonesFor(callerFromCall(request)));
export const listSupportedCurrencies = onCall((request) =>
  listSupportedCurrenciesFor(callerFromCall(request)));
export const listTenantVenues = onCall((request) =>
  listTenantVenuesFor(callerFromCall(request), request.data));
export const listUserMemberships = onCall((request) =>
  listUserMembershipsFor(callerFromCall(request), request.data));
export const createTenant = onCall((request) =>
  createTenantFor(callerFromCall(request), request.data));
export const updateTenant = onCall((request) =>
  updateTenantFor(callerFromCall(request), request.data));
export const createVenue = onCall((request) =>
  createVenueFor(callerFromCall(request), request.data));
export const updateVenue = onCall((request) =>
  updateVenueFor(callerFromCall(request), request.data));
export const deleteVenue = onCall((request) =>
  deleteVenueFor(callerFromCall(request), request.data));
export const createStaffUser = onCall((request) =>
  createStaffUserFor(callerFromCall(request), request.data));
export const assignUserToTenant = onCall((request) =>
  assignUserToTenantFor(callerFromCall(request), request.data));
export const retireStaffUser = onCall((request) =>
  retireStaffUserFor(callerFromCall(request), request.data));
export const setPlatformAdmin = onCall((request) =>
  setPlatformAdminFor(callerFromCall(request), request.data));
export const sendOrderToProduction = onCall((request) =>
  sendOrderToProductionFor(callerFromCall(request), request.data));
export const closeOrder = onCall((request) =>
  closeOrderFor(callerFromCall(request), request.data));
export const updateProductionTicket = onCall((request) =>
  updateProductionTicketFor(callerFromCall(request), request.data));
export const openNamedTab = onCall((request) =>
  openNamedTabFor(callerFromCall(request), request.data));
export const addOrderDraftLine = onCall((request) =>
  addOrderDraftLineFor(callerFromCall(request), request.data));
export const updateOrderDraftLine = onCall((request) =>
  updateOrderDraftLineFor(callerFromCall(request), request.data));
export const updateVenueNotificationSettings = onCall((request) =>
  updateVenueNotificationSettingsFor(callerFromCall(request), request.data));
export const lookupExchangeRate = onCall((request) =>
  lookupExchangeRateFor(callerFromCall(request), request.data));
export const createTable = onCall((request) =>
  createTableFor(callerFromCall(request), request.data));
export const updateTable = onCall((request) =>
  updateTableFor(callerFromCall(request), request.data));
export const deleteTable = onCall((request) =>
  deleteTableFor(callerFromCall(request), request.data));
