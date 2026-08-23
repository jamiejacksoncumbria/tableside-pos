import {randomBytes} from "node:crypto";
import {getApps, initializeApp} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall, onRequest} from "firebase-functions/v2/https";
import {defineString} from "firebase-functions/params";
import {setGlobalOptions} from "firebase-functions/v2";

if (getApps().length === 0) {
  initializeApp();
}

const auth = getAuth();
const db = getFirestore();
const region = "europe-west2";
const initialPlatformAdminEmail = defineString("INITIAL_PLATFORM_ADMIN_EMAIL");
const supportedTimeZones = Object.freeze(Intl.supportedValuesOf("timeZone"));
const supportedTimeZoneSet = new Set(supportedTimeZones);
const supportedCurrencyCodes = Object.freeze(Intl.supportedValuesOf("currency"));
const supportedCurrencyCodeSet = new Set(supportedCurrencyCodes);

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
      return {
        ...line,
        productName: typeof product.name === "string" ? product.name : "Menu item",
        unitPriceMinor,
        productionArea,
        trackStock: product.trackStock === true,
        stockPerSale,
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

    const tableLabel = tableRef == null
      ? null
      : (typeof table.data().label === "string" ? table.data().label : tableId);
    const priorLines = Array.isArray(existingOrder.data()?.lines) ? existingOrder.data().lines : [];
    const priorLineIds = new Set(
      priorLines.map((line) => (typeof line?.id === "string" ? line.id : "")),
    );
    const newOrderLines = canonicalLines
      .filter((line) => !priorLineIds.has(line.id))
      .map((line) => ({
        id: line.id,
        productId: line.productId,
        productName: line.productName,
        quantity: line.quantity,
        unitPriceMinor: line.unitPriceMinor,
        productionArea: line.productionArea,
        trackStock: line.trackStock,
        stockPerSale: line.stockPerSale,
        isSentToProduction: true,
      }));
    transaction.set(orderRef, {
      venueId,
      tableId,
      tabName,
      tableLabel,
      status: "sent",
      openedAt: existingOrder.data()?.openedAt ?? FieldValue.serverTimestamp(),
      lastTicketReleasedAt: FieldValue.serverTimestamp(),
      createdByActor: existingOrder.data()?.createdByActor ?? actor,
      lines: [...priorLines, ...newOrderLines],
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
    for (const ticket of ticketEntries) {
      if (existingTicketIds.has(ticket.ticketId)) continue;
      transaction.create(ticket.ref, {
        venueId,
        orderId,
        reference: orderId.split("-").at(-1) ?? orderId,
        tableLabel,
        tabName,
        productionArea: ticket.area,
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
      for (const line of ticket.lines.filter((item) => item.trackStock)) {
        const quantity = line.quantity * line.stockPerSale;
        stockTotals.set(line.productId, (stockTotals.get(line.productId) ?? 0) + quantity);
        const movementRef = tenantRef.collection("stockMovements")
          .doc(`${ticket.ticketId}_${line.productId}`);
        transaction.create(movementRef, {
          venueId,
          orderId,
          ticketId: ticket.ticketId,
          productId: line.productId,
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
      stockOverride,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {ticketIds: ticketEntries.map((ticket) => ticket.ticketId), stockOverride};
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
    case "createTable":
      return createTableFor(caller, data);
    case "updateTable":
      return updateTableFor(caller, data);
    case "deleteTable":
      return deleteTableFor(caller, data);
    case "sendOrderToProduction":
      return sendOrderToProductionFor(caller, data);
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

function httpStatusFor(error) {
  switch (error.code) {
    case "invalid-argument": return 400;
    case "unauthenticated": return 401;
    case "permission-denied": return 403;
    case "not-found": return 404;
    case "already-exists": return 409;
    case "failed-precondition": return 412;
    default: return 500;
  }
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
  try {
    if (request.method !== "POST") {
      response.status(405).json({error: {code: "method-not-allowed", message: "Use POST."}});
      return;
    }
    const body = requireObject(request.body);
    const action = requiredText(body, "action", 80);
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
    console.error("Unexpected POS command error", error);
    response.status(500).json({
      error: {code: "internal", message: "The POS action could not be completed."},
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
export const updateProductionTicket = onCall((request) =>
  updateProductionTicketFor(callerFromCall(request), request.data));
export const openNamedTab = onCall((request) =>
  openNamedTabFor(callerFromCall(request), request.data));
export const createTable = onCall((request) =>
  createTableFor(callerFromCall(request), request.data));
export const updateTable = onCall((request) =>
  updateTableFor(callerFromCall(request), request.data));
export const deleteTable = onCall((request) =>
  deleteTableFor(callerFromCall(request), request.data));
